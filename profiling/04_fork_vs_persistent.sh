#!/usr/bin/env bash
# profiling/04_fork_vs_persistent.sh
# Fork mode vs. Persistent mode 对比实验
#
# 测量指标：execs/sec（每秒执行次数）
# 对比维度：
#   - fork mode    ：每次执行均通过 fork() 创建子进程（进程创建开销高）
#   - persistent mode：子进程内循环运行，避免重复 fork（开销低）
#
# 实验流程：
#   1. 用 test-instr-fork        运行 RUNS 次，各取 execs/sec，计算均值
#   2. 用 test-instr-persist     运行 RUNS 次，各取 execs/sec，计算均值
#   3. 计算性能比（persistent/fork），量化 fork 开销
#
# 输出：/tmp/afl-profiling/fork_vs_persistent/results.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AFL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_BASE="/tmp/afl-profiling"
OUTDIR="$RESULTS_BASE/fork_vs_persistent"
CONF="$RESULTS_BASE/env.conf"

info()  { echo -e "\033[1;34m[FvP ]\033[0m  $*"; }
ok()    { echo -e "\033[0;32m[ OK ]\033[0m  $*"; }

if [[ ! -f "$CONF" ]]; then
    echo "未找到 $CONF，请先运行 setup.sh" >&2; exit 1
fi
# shellcheck source=/dev/null
source "$CONF"

AFL_FUZZ="$AFL_ROOT/afl-fuzz"
FORK_TARGET="$AFL_ROOT/profiling/test-instr-fork"
PERSIST_TARGET="$AFL_ROOT/profiling/test-instr-persist"
INDIR="$RESULTS_BASE/in"

FUZZ_DURATION="${FUZZ_DURATION:-30}"   # 每次运行时长（秒）
RUNS="${RUNS:-3}"                       # 重复运行次数（取均值）

mkdir -p "$OUTDIR"
cd "$OUTDIR"

info "====== 实验 4: Fork Mode vs. Persistent Mode ======"
info "每次运行: ${FUZZ_DURATION}s  |  重复次数: ${RUNS}"
echo ""

# ── 辅助函数：运行一次 afl-fuzz，返回 execs/sec ──────────────────────────────
run_once() {
    local mode="$1"     # "fork" 或 "persistent"
    local target="$2"
    local run_idx="$3"
    local outdir_run="$OUTDIR/out_${mode}_run${run_idx}"

    rm -rf "$outdir_run"

    AFL_NO_UI=1 \
    AFL_DISABLE_TRIM=1 \
    AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
    AFL_FAST_CAL=1 \
    "$AFL_FUZZ" \
        -i "$INDIR" \
        -o "$outdir_run" \
        -s 123 \
        -V "$FUZZ_DURATION" \
        "$target" \
        &>/dev/null

    local stats="$outdir_run/0/fuzzer_stats"
    if [[ -f "$stats" ]]; then
        grep "^execs_per_sec" "$stats" | awk '{print $3}'
    else
        echo "0"
    fi
}

# ── 运行 fork mode ────────────────────────────────────────────────────────────
info "▶ 测试 fork mode (target: test-instr-fork) ..."
FORK_RESULTS=()
for i in $(seq 1 "$RUNS"); do
    EPS=$(run_once "fork" "$FORK_TARGET" "$i")
    FORK_RESULTS+=("$EPS")
    info "  run $i/$RUNS → execs/sec = $EPS"
done

# ── 运行 persistent mode ──────────────────────────────────────────────────────
info "▶ 测试 persistent mode (target: test-instr-persist) ..."
PERSIST_RESULTS=()
for i in $(seq 1 "$RUNS"); do
    EPS=$(run_once "persistent" "$PERSIST_TARGET" "$i")
    PERSIST_RESULTS+=("$EPS")
    info "  run $i/$RUNS → execs/sec = $EPS"
done

# ── 计算统计值并保存 JSON ─────────────────────────────────────────────────────
python3 - <<PYEOF
import json, pathlib, statistics

fork_vals    = [float(x) for x in "${FORK_RESULTS[*]}".split()]
persist_vals = [float(x) for x in "${PERSIST_RESULTS[*]}".split()]

fork_avg    = statistics.mean(fork_vals)
persist_avg = statistics.mean(persist_vals)
speedup     = persist_avg / fork_avg if fork_avg > 0 else 0.0

print()
print("  ┌──────────────────────────────────────────────────┐")
print("  │          Fork vs. Persistent Mode 结果           │")
print("  ├──────────────────────────────────────────────────┤")
print(f"  │  fork mode     均值 execs/sec : {fork_avg:>12.1f}       │")
print(f"  │  persistent    均值 execs/sec : {persist_avg:>12.1f}       │")
print(f"  │  speedup 倍率  (persist/fork) : {speedup:>12.2f}×      │")
print("  └──────────────────────────────────────────────────┘")

result = {
    "experiment": "fork_vs_persistent",
    "duration_s": ${FUZZ_DURATION},
    "runs": ${RUNS},
    "fork": {
        "execs_per_sec_runs": fork_vals,
        "execs_per_sec_avg": round(fork_avg, 2),
        "execs_per_sec_stdev": round(statistics.stdev(fork_vals) if len(fork_vals) > 1 else 0, 2),
    },
    "persistent": {
        "execs_per_sec_runs": persist_vals,
        "execs_per_sec_avg": round(persist_avg, 2),
        "execs_per_sec_stdev": round(statistics.stdev(persist_vals) if len(persist_vals) > 1 else 0, 2),
    },
    "speedup_ratio": round(speedup, 3),
    "fork_overhead_pct": round((1 - fork_avg / persist_avg) * 100, 1) if persist_avg > 0 else 0,
}
out = pathlib.Path("${OUTDIR}/results.json")
out.write_text(json.dumps(result, indent=2))
print(f"\n  results.json: {out}")
PYEOF

echo ""
ok "====== 实验 4 完成 ======"
echo "  输出目录: $OUTDIR"
echo "  后续: 查看 results.json，speedup_ratio 即为"
echo "        persistent mode 相对于 fork mode 的性能倍率"
