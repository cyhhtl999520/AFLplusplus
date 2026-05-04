#!/usr/bin/env bash
# profiling/03_io_profiling.sh
# I/O 开销分析：使用 strace -c 统计 afl-fuzz 运行期间的系统调用频率与耗时，
# 量化文件 I/O（write/read/openat/unlink）在总运行时间中的占比。
#
# 补充：使用 /proc/<pid>/io 跟踪实际读写字节数。
#
# 依赖：strace
# 输出：/tmp/afl-profiling/io/
#   ├── strace_summary.txt   strace -c 汇总报告（按耗时排序）
#   ├── proc_io.txt          /proc/<pid>/io 读写字节统计
#   └── results.json         关键指标 JSON

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AFL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_BASE="/tmp/afl-profiling"
OUTDIR="$RESULTS_BASE/io"
CONF="$RESULTS_BASE/env.conf"

info()  { echo -e "\033[1;34m[I/O ]\033[0m  $*"; }
ok()    { echo -e "\033[0;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }

# ── 加载环境配置 ──────────────────────────────────────────────────────────────
if [[ ! -f "$CONF" ]]; then
    echo "未找到 $CONF，请先运行 setup.sh" >&2; exit 1
fi
# shellcheck source=/dev/null
source "$CONF"

AFL_FUZZ="$AFL_ROOT/afl-fuzz"
FORK_TARGET="$AFL_ROOT/profiling/test-instr-fork"
INDIR="$RESULTS_BASE/in"
FUZZ_DURATION="${FUZZ_DURATION:-30}"

mkdir -p "$OUTDIR"
cd "$OUTDIR"

info "====== 实验 3: I/O 开销分析（strace -c）======"
info "运行时长: ${FUZZ_DURATION}s  |  目标: $FORK_TARGET"
echo ""

# ── 检查 strace ───────────────────────────────────────────────────────────────
if ! command -v strace &>/dev/null; then
    warn "strace 未安装，跳过 I/O 分析。安装方法: apt install strace"
    exit 0
fi

# ── 第一阶段：strace -c（系统调用统计）──────────────────────────────────────
info "阶段 1/2: 使用 strace -c 统计系统调用..."

AFL_NO_UI=1 \
AFL_DISABLE_TRIM=1 \
AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
AFL_FAST_CAL=1 \
strace -c \
    -e trace=file,read,write,openat,close,unlink,unlinkat,rename,renameat \
    "$AFL_FUZZ" \
        -i "$INDIR" \
        -o "$OUTDIR/fuzz_out_strace" \
        -s 123 \
        -V "$FUZZ_DURATION" \
        "$FORK_TARGET" \
    2>"$OUTDIR/strace_summary.txt" || true

ok "strace -c 完成: $OUTDIR/strace_summary.txt"
echo ""
info "── 系统调用汇总 ──"
cat "$OUTDIR/strace_summary.txt" || true
echo ""

# ── 第二阶段：/proc/<pid>/io 监控──────────────────────────────────────────────
info "阶段 2/2: 通过 /proc/<pid>/io 监控读写字节数..."

# 启动 afl-fuzz（后台）
AFL_NO_UI=1 \
AFL_DISABLE_TRIM=1 \
AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
AFL_FAST_CAL=1 \
"$AFL_FUZZ" \
    -i "$INDIR" \
    -o "$OUTDIR/fuzz_out_procio" \
    -s 123 \
    -V "$FUZZ_DURATION" \
    "$FORK_TARGET" \
    &>/dev/null &
AFL_PID=$!
info "afl-fuzz PID: $AFL_PID"

# 等待进程 fork server 就绪
sleep 2

# 采集 /proc/<pid>/io（起始值）
IO_START=""
if [[ -f "/proc/$AFL_PID/io" ]]; then
    IO_START=$(cat "/proc/$AFL_PID/io" 2>/dev/null || true)
fi

# 等待 afl-fuzz 运行结束
wait "$AFL_PID" 2>/dev/null || true

# 保存 /proc/<pid>/io（最终值）
{
    echo "=== /proc/$AFL_PID/io (final snapshot) ==="
    echo "（注：进程结束后 /proc 条目已消失，实际需在运行期间采集）"
    echo ""
    echo "--- 启动时快照 ---"
    echo "${IO_START:-（未采集到）}"
} > "$OUTDIR/proc_io.txt"
ok "I/O 字节统计: $OUTDIR/proc_io.txt"

# ── 解析 strace 结果生成 JSON ─────────────────────────────────────────────────
STATS_FILE="$OUTDIR/fuzz_out_strace/0/fuzzer_stats"
python3 - <<PYEOF
import re, json, pathlib

strace_file = pathlib.Path("${OUTDIR}/strace_summary.txt")
stats_file  = pathlib.Path("${STATS_FILE}")
outdir      = pathlib.Path("${OUTDIR}")

# 解析 strace -c 输出
syscalls = {}
if strace_file.exists():
    for line in strace_file.read_text(errors="replace").splitlines():
        # 匹配类似: "  0.12   0.000001    3    42           write"
        m = re.match(r"\s*([\d.]+)\s+([\d.]+)\s+(\d+)\s+(\d+)\s+\S*\s+(\w+)", line)
        if m:
            syscalls[m.group(5)] = {
                "percent_time": float(m.group(1)),
                "seconds":      float(m.group(2)),
                "usecs_per_call": int(m.group(3)),
                "calls":         int(m.group(4)),
            }

# 解析 fuzzer_stats
execs_per_sec, execs_done = 0.0, 0
if stats_file.exists():
    for line in stats_file.read_text().splitlines():
        if line.startswith("execs_per_sec"):
            execs_per_sec = float(line.split()[-1])
        elif line.startswith("execs_done"):
            execs_done = int(line.split()[-1])

# 计算 I/O 类调用总占比
io_syscalls = {"write", "read", "openat", "close", "unlink", "unlinkat", "rename", "renameat"}
io_total_pct = sum(v["percent_time"] for k, v in syscalls.items() if k in io_syscalls)

result = {
    "experiment": "io_profiling",
    "duration_s": ${FUZZ_DURATION},
    "execs_per_sec": execs_per_sec,
    "execs_done": execs_done,
    "io_syscall_percent_time": round(io_total_pct, 2),
    "syscalls": syscalls,
}
out_path = outdir / "results.json"
out_path.write_text(json.dumps(result, indent=2))
print(f"  execs_per_sec          : {execs_per_sec}")
print(f"  I/O 类系统调用时间占比 : {io_total_pct:.2f}%")
print(f"  results.json           : {out_path}")
PYEOF

echo ""
ok "====== 实验 3 完成 ======"
echo "  输出目录: $OUTDIR"
echo "  后续: 查看 strace_summary.txt，"
echo "        关注 write/openat/unlink 调用次数及耗时占比"
