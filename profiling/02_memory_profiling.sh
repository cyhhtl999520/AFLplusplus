#!/usr/bin/env bash
# profiling/02_memory_profiling.sh
# 内存分析：使用 Valgrind Massif 追踪 afl-fuzz 的堆内存使用随时间的增长趋势。
#
# 分析目标：
#   - 测量 afl-fuzz 堆内存峰值及增长曲线
#   - 识别主要内存消耗点（位图 bitmap、queue 管理、覆盖率位图等）
#   - 量化 afl_realloc 自定义分配器的开销
#
# 依赖：valgrind（含 massif）、ms_print
# 输出：/tmp/afl-profiling/memory/
#   ├── massif.out.<pid>    Massif 原始数据
#   ├── massif_report.txt   ms_print 渲染的内存快照报告
#   └── results.json        摘要数据（峰值内存等）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AFL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_BASE="/tmp/afl-profiling"
OUTDIR="$RESULTS_BASE/memory"
CONF="$RESULTS_BASE/env.conf"

info()  { echo -e "\033[1;34m[MEM ]\033[0m  $*"; }
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

# Massif 运行时长（秒）；Valgrind 本身会大幅降低速度，因此 30s 即可采集足够快照
FUZZ_DURATION="${FUZZ_DURATION:-30}"

mkdir -p "$OUTDIR"
cd "$OUTDIR"

info "====== 实验 2: 内存分析（Valgrind Massif）======"
info "运行时长: ${FUZZ_DURATION}s  |  目标: $FORK_TARGET"
info "注意: Valgrind 会大幅降低执行速度（约 10-50×），这是正常现象"
echo ""

# ── 检查 valgrind ─────────────────────────────────────────────────────────────
if ! command -v valgrind &>/dev/null; then
    warn "valgrind 未安装，跳过内存分析。安装方法: apt install valgrind"
    exit 0
fi

# ── 运行 Massif ───────────────────────────────────────────────────────────────
MASSIF_OUT="$OUTDIR/massif.out"
info "启动 valgrind --tool=massif ..."

# 使用 fork mode 目标（非 persistent），确保 Valgrind 能完整追踪堆
# AFL_NO_FORKSRV=1 避免 fork server 干扰内存采样
AFL_NO_UI=1 \
AFL_NO_FORKSRV=1 \
AFL_DISABLE_TRIM=1 \
AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
AFL_FAST_CAL=1 \
timeout "$((FUZZ_DURATION + 60))" \
valgrind \
    --tool=massif \
    --pages-as-heap=yes \
    --massif-out-file="$MASSIF_OUT" \
    --time-unit=ms \
    --detailed-freq=5 \
    "$AFL_FUZZ" \
        -i "$INDIR" \
        -o "$OUTDIR/fuzz_out" \
        -s 123 \
        -V "$FUZZ_DURATION" \
        "$FORK_TARGET" \
    2>"$OUTDIR/valgrind_stderr.txt" || true

ok "Massif 采样完成"

# ── 生成文本报告 ──────────────────────────────────────────────────────────────
if [[ -f "$MASSIF_OUT" ]]; then
    info "使用 ms_print 渲染报告..."
    if command -v ms_print &>/dev/null; then
        ms_print "$MASSIF_OUT" > "$OUTDIR/massif_report.txt" 2>/dev/null
        ok "Massif 报告: $OUTDIR/massif_report.txt"

        # 打印内存峰值摘要
        echo ""
        info "── 内存使用摘要（前 50 行）──"
        head -50 "$OUTDIR/massif_report.txt" || true
        echo ""

        # 提取峰值内存（单位 KB）
        PEAK_KB=$(grep -m1 "total heap usage" "$OUTDIR/massif_report.txt" \
                  | grep -oP '[0-9,]+(?= bytes allocated)' \
                  | tr -d ',' \
                  | awk '{printf "%.0f", $1/1024}' 2>/dev/null || echo "N/A")
    else
        warn "ms_print 未找到，原始 Massif 数据已保存: $MASSIF_OUT"
        PEAK_KB="N/A"
    fi
else
    warn "massif.out 未生成，请检查 valgrind 输出: $OUTDIR/valgrind_stderr.txt"
    PEAK_KB="N/A"
fi

# ── 解析 Massif 快照数据生成 Python 可读 JSON ─────────────────────────────────
if [[ -f "$MASSIF_OUT" ]]; then
    python3 - <<'PYEOF'
import re, json, pathlib, sys

massif_file = pathlib.Path("/tmp/afl-profiling/memory/massif.out")
if not massif_file.exists():
    print("  massif.out 不存在，跳过 JSON 解析")
    sys.exit(0)

snapshots = []
current = {}
for line in massif_file.read_text(errors="replace").splitlines():
    if line.startswith("snapshot="):
        if current:
            snapshots.append(current)
        current = {"snapshot": int(line.split("=")[1])}
    elif line.startswith("time="):
        current["time_ms"] = int(line.split("=")[1])
    elif line.startswith("mem_heap_B="):
        current["heap_bytes"] = int(line.split("=")[1])
    elif line.startswith("mem_heap_extra_B="):
        current["heap_extra_bytes"] = int(line.split("=")[1])
    elif line.startswith("mem_stacks_B="):
        current["stacks_bytes"] = int(line.split("=")[1])
if current:
    snapshots.append(current)

if snapshots:
    peak = max(s.get("heap_bytes", 0) + s.get("heap_extra_bytes", 0) for s in snapshots)
    out = {
        "experiment": "memory_profiling",
        "snapshots": snapshots,
        "peak_heap_bytes": peak,
        "peak_heap_kb": round(peak / 1024, 2),
        "peak_heap_mb": round(peak / 1024 / 1024, 2),
        "snapshot_count": len(snapshots),
    }
    result_path = pathlib.Path("/tmp/afl-profiling/memory/results.json")
    result_path.write_text(json.dumps(out, indent=2))
    print(f"  peak_heap_mb  : {out['peak_heap_mb']} MB")
    print(f"  snapshots     : {out['snapshot_count']}")
    print(f"  results.json  : {result_path}")
else:
    print("  未解析到有效快照数据")
PYEOF
fi

echo ""
ok "====== 实验 2 完成 ======"
echo "  输出目录: $OUTDIR"
echo "  后续: 查看 massif_report.txt 中的内存增长曲线，"
echo "        关注堆内存峰值及 malloc 调用栈"
