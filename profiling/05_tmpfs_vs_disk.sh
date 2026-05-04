#!/usr/bin/env bash
# profiling/05_tmpfs_vs_disk.sh
# tmpfs vs. 磁盘存储性能对比实验
#
# 测量指标：execs/sec、写入 I/O 字节数
# 对比维度：
#   - 磁盘（默认 /tmp）：受磁盘 I/O 延迟影响
#   - tmpfs（内存文件系统）：直接读写内存，延迟极低
#
# 实验流程：
#   1. 在普通磁盘目录运行 afl-fuzz，记录 execs/sec 和 /proc/io 字节数
#   2. 挂载 tmpfs，在 tmpfs 上运行 afl-fuzz，记录同样指标
#   3. 对比两者差异
#
# 注意：挂载 tmpfs 需要 sudo 权限。若无 sudo，脚本将对比两个磁盘路径
#       以展示方法论，并在结果中注明。
#
# 输出：/tmp/afl-profiling/tmpfs_vs_disk/results.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AFL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_BASE="/tmp/afl-profiling"
OUTDIR="$RESULTS_BASE/tmpfs_vs_disk"
CONF="$RESULTS_BASE/env.conf"

info()  { echo -e "\033[1;34m[TMP ]\033[0m  $*"; }
ok()    { echo -e "\033[0;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }

if [[ ! -f "$CONF" ]]; then
    echo "未找到 $CONF，请先运行 setup.sh" >&2; exit 1
fi
# shellcheck source=/dev/null
source "$CONF"

AFL_FUZZ="$AFL_ROOT/afl-fuzz"
PERSIST_TARGET="$AFL_ROOT/profiling/test-instr-persist"
INDIR="$RESULTS_BASE/in"

FUZZ_DURATION="${FUZZ_DURATION:-30}"
RUNS="${RUNS:-3}"

mkdir -p "$OUTDIR"
cd "$OUTDIR"

info "====== 实验 5: tmpfs vs. 磁盘存储性能对比 ======"
info "每次运行: ${FUZZ_DURATION}s  |  重复次数: ${RUNS}"
echo ""

# ── 辅助函数：运行一次并采集指标 ─────────────────────────────────────────────
run_once() {
    local label="$1"
    local outdir_run="$2"
    local run_idx="$3"

    rm -rf "$outdir_run"
    mkdir -p "$outdir_run"

    # 启动 afl-fuzz（后台，以便同时读取 /proc/io）
    AFL_NO_UI=1 \
    AFL_DISABLE_TRIM=1 \
    AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
    AFL_FAST_CAL=1 \
    "$AFL_FUZZ" \
        -i "$INDIR" \
        -o "$outdir_run" \
        -s 123 \
        -V "$FUZZ_DURATION" \
        "$PERSIST_TARGET" \
        &>/dev/null &
    local pid=$!

    # 等待 fork server 就绪后记录 /proc/io 起始值
    sleep 2
    local io_start_write=0
    if [[ -f "/proc/$pid/io" ]]; then
        io_start_write=$(awk '/^write_bytes:/{print $2}' "/proc/$pid/io" 2>/dev/null || echo 0)
    fi

    wait "$pid" 2>/dev/null || true

    # 读取 fuzzer_stats
    local stats="$outdir_run/0/fuzzer_stats"
    local eps=0 execs=0
    if [[ -f "$stats" ]]; then
        eps=$(grep "^execs_per_sec" "$stats" | awk '{print $3}')
        execs=$(grep "^execs_done" "$stats" | awk '{print $3}')
    fi

    echo "${eps:-0}:${execs:-0}:${io_start_write:-0}"
}

# ── 1. 磁盘模式（/tmp — 通常为磁盘或 OS 默认临时目录）──────────────────────
DISK_DIR="$OUTDIR/disk_out"
info "▶ 磁盘模式测试（输出目录: $DISK_DIR）..."
DISK_EPS_LIST=(); DISK_EXECS_LIST=()
for i in $(seq 1 "$RUNS"); do
    result=$(run_once "disk" "$DISK_DIR/run${i}" "$i")
    eps=$(echo "$result" | cut -d: -f1)
    execs=$(echo "$result" | cut -d: -f2)
    DISK_EPS_LIST+=("$eps")
    DISK_EXECS_LIST+=("$execs")
    info "  run $i/$RUNS → execs/sec=$eps  execs_done=$execs"
done

# ── 2. tmpfs 模式 ─────────────────────────────────────────────────────────────
TMPFS_DIR="$OUTDIR/tmpfs_mount"
TMPFS_REAL=false
if command -v mount &>/dev/null && [[ "$(id -u)" -eq 0 ]]; then
    info "▶ 挂载 tmpfs (root 权限)..."
    mkdir -p "$TMPFS_DIR"
    mount -t tmpfs -o size=512m tmpfs "$TMPFS_DIR"
    TMPFS_REAL=true
    trap 'umount "$TMPFS_DIR" 2>/dev/null || true' EXIT
elif sudo -n mount --version &>/dev/null 2>&1; then
    info "▶ 使用 sudo 挂载 tmpfs..."
    mkdir -p "$TMPFS_DIR"
    sudo mount -t tmpfs -o size=512m tmpfs "$TMPFS_DIR"
    TMPFS_REAL=true
    trap 'sudo umount "$TMPFS_DIR" 2>/dev/null || true' EXIT
else
    warn "无 root/sudo 权限，无法挂载真实 tmpfs"
    warn "改用 /dev/shm（Linux 默认 tmpfs）作为替代..."
    TMPFS_DIR="/dev/shm/afl-profiling-tmpfs-$$"
    mkdir -p "$TMPFS_DIR"
    TMPFS_REAL=false
fi

info "▶ tmpfs 模式测试（输出目录: $TMPFS_DIR）..."
TMPFS_EPS_LIST=(); TMPFS_EXECS_LIST=()
for i in $(seq 1 "$RUNS"); do
    result=$(run_once "tmpfs" "$TMPFS_DIR/run${i}" "$i")
    eps=$(echo "$result" | cut -d: -f1)
    execs=$(echo "$result" | cut -d: -f2)
    TMPFS_EPS_LIST+=("$eps")
    TMPFS_EXECS_LIST+=("$execs")
    info "  run $i/$RUNS → execs/sec=$eps  execs_done=$execs"
done

# 清理 tmpfs
if [[ "$TMPFS_REAL" == "true" ]]; then
    umount "$TMPFS_DIR" 2>/dev/null || sudo umount "$TMPFS_DIR" 2>/dev/null || true
elif [[ "$TMPFS_DIR" == /dev/shm/* ]]; then
    rm -rf "$TMPFS_DIR"
fi

# ── 计算统计并保存 JSON ───────────────────────────────────────────────────────
python3 - <<PYEOF
import json, pathlib, statistics

disk_vals   = [float(x) for x in "${DISK_EPS_LIST[*]}".split()]
tmpfs_vals  = [float(x) for x in "${TMPFS_EPS_LIST[*]}".split()]
tmpfs_real  = ${TMPFS_REAL}

disk_avg  = statistics.mean(disk_vals)
tmpfs_avg = statistics.mean(tmpfs_vals)
speedup   = tmpfs_avg / disk_avg if disk_avg > 0 else 0.0

print()
print("  ┌──────────────────────────────────────────────────┐")
print("  │          tmpfs vs. 磁盘 结果                     │")
print("  ├──────────────────────────────────────────────────┤")
print(f"  │  磁盘 均值 execs/sec  : {disk_avg:>14.1f}         │")
print(f"  │  tmpfs 均值 execs/sec : {tmpfs_avg:>14.1f}         │")
print(f"  │  speedup (tmpfs/disk) : {speedup:>14.3f}×        │")
print("  └──────────────────────────────────────────────────┘")
if not tmpfs_real:
    print("  注：本次使用 /dev/shm 代替真实 tmpfs 挂载")

result = {
    "experiment": "tmpfs_vs_disk",
    "duration_s": ${FUZZ_DURATION},
    "runs": ${RUNS},
    "tmpfs_real_mount": bool(tmpfs_real),
    "disk": {
        "execs_per_sec_runs": disk_vals,
        "execs_per_sec_avg": round(disk_avg, 2),
        "execs_per_sec_stdev": round(statistics.stdev(disk_vals) if len(disk_vals) > 1 else 0, 2),
    },
    "tmpfs": {
        "execs_per_sec_runs": tmpfs_vals,
        "execs_per_sec_avg": round(tmpfs_avg, 2),
        "execs_per_sec_stdev": round(statistics.stdev(tmpfs_vals) if len(tmpfs_vals) > 1 else 0, 2),
    },
    "speedup_ratio": round(speedup, 3),
}
out = pathlib.Path("${OUTDIR}/results.json")
out.write_text(json.dumps(result, indent=2))
print(f"\n  results.json: {out}")
PYEOF

echo ""
ok "====== 实验 5 完成 ======"
echo "  输出目录: $OUTDIR"
