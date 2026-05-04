#!/usr/bin/env bash
# profiling/01_cpu_profiling.sh
# CPU 热点分析：使用 perf record 对 afl-fuzz 进行函数级采样，并生成火焰图 SVG。
#
# 分析目标：
#   - 识别 afl-fuzz 主循环中耗时最多的函数（classify_counts、has_new_bits 等）
#   - 量化 fork server、变异策略（havoc/splicing）的 CPU 占比
#
# 依赖：perf、flamegraph（或 stackcollapse-perf.pl + flamegraph.pl）
# 输出：/tmp/afl-profiling/cpu/
#   ├── perf.data           perf 原始采样数据
#   ├── perf_report.txt     top 函数列表（文本）
#   ├── out_folded.txt      折叠后的调用栈（用于火焰图）
#   └── flamegraph.svg      交互式火焰图

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AFL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_BASE="/tmp/afl-profiling"
OUTDIR="$RESULTS_BASE/cpu"
CONF="$RESULTS_BASE/env.conf"

info()  { echo -e "\033[1;34m[CPU ]\033[0m  $*"; }
ok()    { echo -e "\033[0;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
skip()  { echo -e "\033[0;35m[SKIP]\033[0m  $*"; }

# ── 加载环境配置 ──────────────────────────────────────────────────────────────
if [[ ! -f "$CONF" ]]; then
    echo "未找到 $CONF，请先运行 setup.sh" >&2; exit 1
fi
# shellcheck source=/dev/null
source "$CONF"

AFL_FUZZ="$AFL_ROOT/afl-fuzz"
PERSIST_TARGET="$AFL_ROOT/profiling/test-instr-persist"
INDIR="$RESULTS_BASE/in"

# 单次 profiling 运行时长（秒）；可通过环境变量覆盖
FUZZ_DURATION="${FUZZ_DURATION:-30}"

mkdir -p "$OUTDIR"
cd "$OUTDIR"

info "====== 实验 1: CPU 热点分析 ======"
info "运行时长: ${FUZZ_DURATION}s  |  目标: $PERSIST_TARGET"
info "输出目录: $OUTDIR"
echo ""

# ── 检查 perf ─────────────────────────────────────────────────────────────────
if ! command -v perf &>/dev/null; then
    warn "perf 未安装，跳过 CPU 采样。安装方法: apt install linux-perf"
    exit 0
fi

# ── 权限提示 ──────────────────────────────────────────────────────────────────
PERF_PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "3")
if [[ "$PERF_PARANOID" -gt 1 ]]; then
    warn "perf_event_paranoid=$PERF_PARANOID，可能导致采样权限不足。"
    warn "如采样失败，请执行: echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid"
fi

# ── 启动 afl-fuzz（后台）─────────────────────────────────────────────────────
info "启动 afl-fuzz (persistent mode, ${FUZZ_DURATION}s)..."
AFL_NO_UI=1 \
AFL_DISABLE_TRIM=1 \
AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
AFL_FAST_CAL=1 \
"$AFL_FUZZ" \
    -i "$INDIR" \
    -o "$OUTDIR/fuzz_out" \
    -s 123 \
    -V "$FUZZ_DURATION" \
    "$PERSIST_TARGET" \
    &>/dev/null &
AFL_PID=$!
info "afl-fuzz PID: $AFL_PID"

# 等待 fork server 就绪
sleep 3

# ── perf record ───────────────────────────────────────────────────────────────
info "perf record 开始采样 (频率 99Hz, 持续 ${FUZZ_DURATION}s)..."
perf record \
    -F 99 \
    -p "$AFL_PID" \
    -g \
    --call-graph dwarf \
    -o "$OUTDIR/perf.data" \
    -- sleep "$FUZZ_DURATION" \
    2>/dev/null || true

# 等待 afl-fuzz 自然退出
wait "$AFL_PID" 2>/dev/null || true
ok "afl-fuzz 已退出"

# ── perf report（文本 Top 函数）─────────────────────────────────────────────
if [[ -f "$OUTDIR/perf.data" ]]; then
    info "生成 Top 函数报告..."
    perf report \
        -i "$OUTDIR/perf.data" \
        --stdio \
        --no-pager \
        -n \
        --sort symbol \
        2>/dev/null \
        > "$OUTDIR/perf_report.txt" || true
    ok "Top 函数报告: $OUTDIR/perf_report.txt"

    # 打印前 20 行供快速查看
    echo ""
    info "── Top 函数（前 20 条）──"
    head -40 "$OUTDIR/perf_report.txt" || true
    echo ""
else
    warn "perf.data 未生成，采样可能因权限不足而失败"
fi

# ── 火焰图生成 ────────────────────────────────────────────────────────────────
# 尝试多种火焰图工具链
FLAMEGRAPH_PL=""
for candidate in \
    flamegraph \
    /usr/bin/flamegraph \
    /usr/share/flamegraph/flamegraph.pl \
    flamegraph.pl; do
    if command -v "$candidate" &>/dev/null; then
        FLAMEGRAPH_PL="$candidate"
        break
    fi
done

STACKCOLLAPSE_PL=""
for candidate in \
    stackcollapse-perf \
    stackcollapse-perf.pl \
    /usr/share/flamegraph/stackcollapse-perf.pl; do
    if command -v "$candidate" &>/dev/null; then
        STACKCOLLAPSE_PL="$candidate"
        break
    fi
done

if [[ -f "$OUTDIR/perf.data" ]] && [[ -n "$STACKCOLLAPSE_PL" ]] && [[ -n "$FLAMEGRAPH_PL" ]]; then
    info "生成火焰图 SVG..."
    perf script -i "$OUTDIR/perf.data" 2>/dev/null \
        | "$STACKCOLLAPSE_PL" \
        > "$OUTDIR/out_folded.txt" 2>/dev/null || true

    if [[ -s "$OUTDIR/out_folded.txt" ]]; then
        "$FLAMEGRAPH_PL" \
            --title "AFL++ afl-fuzz CPU Flamegraph" \
            --width 1400 \
            "$OUTDIR/out_folded.txt" \
            > "$OUTDIR/flamegraph.svg" 2>/dev/null
        ok "火焰图已生成: $OUTDIR/flamegraph.svg"
        ok "（可用浏览器打开 flamegraph.svg 进行交互式分析）"
    else
        warn "折叠调用栈为空，火焰图生成跳过"
    fi
elif [[ -f "$OUTDIR/perf.data" ]]; then
    skip "未找到 stackcollapse-perf.pl 或 flamegraph.pl，跳过火焰图生成"
    skip "安装方法: apt install flamegraph  或  git clone https://github.com/brendangregg/FlameGraph"
fi

# ── 读取 fuzzer_stats 记录基线 exec/sec ───────────────────────────────────────
STATS_FILE="$OUTDIR/fuzz_out/0/fuzzer_stats"
if [[ -f "$STATS_FILE" ]]; then
    EXECS_PER_SEC=$(grep "^execs_per_sec" "$STATS_FILE" | awk '{print $3}')
    EXECS_DONE=$(grep "^execs_done" "$STATS_FILE" | awk '{print $3}')
    info "── fuzzer_stats 摘要 ──"
    echo "  execs_per_sec : $EXECS_PER_SEC"
    echo "  execs_done    : $EXECS_DONE"

    # 保存 JSON 供后续分析
    python3 - <<EOF
import json, pathlib
data = {
    "experiment": "cpu_profiling",
    "mode": "persistent",
    "duration_s": ${FUZZ_DURATION},
    "execs_per_sec": float("${EXECS_PER_SEC:-0}"),
    "execs_done": int("${EXECS_DONE:-0}"),
    "perf_report": "${OUTDIR}/perf_report.txt",
    "flamegraph": "${OUTDIR}/flamegraph.svg",
}
out = pathlib.Path("${OUTDIR}/results.json")
out.write_text(json.dumps(data, indent=2))
print(f"  results.json  : {out}")
EOF
fi

echo ""
ok "====== 实验 1 完成 ======"
echo "  输出目录: $OUTDIR"
echo "  后续: 用浏览器打开 flamegraph.svg，"
echo "        关注 classify_counts / has_new_bits / common_fuzz_stuff 等函数占比"
