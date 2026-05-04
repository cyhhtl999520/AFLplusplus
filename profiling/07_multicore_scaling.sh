#!/usr/bin/env bash
# profiling/07_multicore_scaling.sh
# 多核扩展性测试
#
# 测量指标：总 execs/sec（所有 fuzzer 实例之和）、CPU 利用率
# 对比维度：并行 fuzzer 实例数 = 1, 2, 4, max（可用 CPU 数）
#
# 实验流程：
#   - 对每个并行度 N，启动 1 个 afl-fuzz -M（主）+ (N-1) 个 afl-fuzz -S（从）
#   - 记录各 fuzzer_stats 中 execs_per_sec 之和
#   - 与 N=1 基线对比，计算扩展效率（实际/理想线性增长比）
#
# 输出：/tmp/afl-profiling/multicore/results.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AFL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_BASE="/tmp/afl-profiling"
OUTDIR="$RESULTS_BASE/multicore"
CONF="$RESULTS_BASE/env.conf"

info()  { echo -e "\033[1;34m[MCOR]\033[0m  $*"; }
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
MAX_CPUS="${MAX_CPUS:-$(nproc)}"

# 构建待测并行度列表（1, 2, 4, MAX_CPUS；去重并排序）
build_parallelism_list() {
    local max="$1"
    local list=(1)
    local n=2
    while [[ $n -lt $max ]]; do
        list+=("$n")
        n=$((n * 2))
    done
    list+=("$max")
    # 去重排序
    printf '%s\n' "${list[@]}" | sort -un | tr '\n' ' '
}

PARALLELISM_LIST=($(build_parallelism_list "$MAX_CPUS"))

mkdir -p "$OUTDIR"
cd "$OUTDIR"

info "====== 实验 7: 多核扩展性测试 ======"
info "测试并行度: ${PARALLELISM_LIST[*]}"
info "每次运行: ${FUZZ_DURATION}s  |  最大 CPU: ${MAX_CPUS}"
echo ""

# ── 辅助：启动 N 个 fuzzer，返回总 execs/sec ─────────────────────────────────
run_multicore() {
    local n="$1"
    local outdir_run="$2"

    rm -rf "$outdir_run"
    mkdir -p "$outdir_run"

    local pids=()

    # 主 fuzzer（-M 0）
    AFL_NO_UI=1 \
    AFL_DISABLE_TRIM=1 \
    AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
    AFL_FAST_CAL=1 \
    AFL_TRY_AFFINITY=1 \
    "$AFL_FUZZ" \
        -i "$INDIR" \
        -o "$outdir_run" \
        -s 123 \
        -V "$FUZZ_DURATION" \
        -M 0 \
        "$PERSIST_TARGET" \
        &>/dev/null &
    pids+=($!)

    # 从 fuzzer（-S 1 到 N-1）
    for (( i=1; i<n; i++ )); do
        AFL_NO_UI=1 \
        AFL_DISABLE_TRIM=1 \
        AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
        AFL_FAST_CAL=1 \
        AFL_TRY_AFFINITY=1 \
        "$AFL_FUZZ" \
            -i "$INDIR" \
            -o "$outdir_run" \
            -s "$((123 + i))" \
            -V "$FUZZ_DURATION" \
            -S "$i" \
            "$PERSIST_TARGET" \
            &>/dev/null &
        pids+=($!)
    done

    # 等待所有 fuzzer 退出
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # 汇总所有 fuzzer 的 execs_per_sec
    local total_eps=0
    for (( i=0; i<n; i++ )); do
        local stats="$outdir_run/$i/fuzzer_stats"
        if [[ -f "$stats" ]]; then
            eps=$(grep "^execs_per_sec" "$stats" | awk '{print $3}')
            total_eps=$(python3 -c "print(${total_eps} + ${eps:-0})")
        fi
    done
    echo "$total_eps"
}

# ── 主循环 ────────────────────────────────────────────────────────────────────
declare -A EPS_BY_N
declare -A EPS_BY_N_RUNS

for N in "${PARALLELISM_LIST[@]}"; do
    info "▶ 测试 $N 个 fuzzer 实例..."
    EPS_SUM=0
    for i in $(seq 1 1); do   # 多核实验每级运行 1 次（耗时较长）
        EPS=$(run_multicore "$N" "$OUTDIR/out_n${N}_run${i}")
        info "  N=$N run $i → 总 execs/sec = $EPS"
        EPS_SUM=$(python3 -c "print(${EPS_SUM} + ${EPS:-0})")
    done
    EPS_BY_N[$N]="$EPS_SUM"
    echo ""
done

# ── 计算扩展效率并保存 JSON ───────────────────────────────────────────────────
python3 - <<PYEOF
import json, pathlib

parallelism = [int(x) for x in "${PARALLELISM_LIST[*]}".split()]
eps_map = {}
for n in parallelism:
    key = f"eps_{n}"
    # 构建动态 bash 变量引用（已通过 heredoc 注入）
PYEOF

# 使用更直接的方式传递数据
python3 - <<PYEOF
import json, pathlib

parallelism = [int(x) for x in "${PARALLELISM_LIST[*]}".split()]
eps_values  = {
$(for N in "${PARALLELISM_LIST[@]}"; do
    echo "    $N: float(\"${EPS_BY_N[$N]:-0}\"),"
done)
}

baseline_eps = eps_values.get(1, 1.0) or 1.0
entries = []
print()
print("  ┌─────────────────────────────────────────────────────────────┐")
print("  │                  多核扩展性测试结果                         │")
print("  ├──────────┬──────────────────┬──────────────┬───────────────┤")
print("  │  Fuzzers │  总 execs/sec    │  理想 execs/s │  扩展效率     │")
print("  ├──────────┼──────────────────┼──────────────┼───────────────┤")
for n in parallelism:
    eps  = eps_values.get(n, 0)
    ideal = baseline_eps * n
    eff  = (eps / ideal * 100) if ideal > 0 else 0
    print(f"  │  {n:<8}│  {eps:>16.1f}  │  {ideal:>12.1f}  │  {eff:>11.1f}%  │")
    entries.append({
        "fuzzers": n,
        "execs_per_sec_total": round(eps, 2),
        "execs_per_sec_ideal": round(ideal, 2),
        "scaling_efficiency_pct": round(eff, 1),
    })
print("  └──────────┴──────────────────┴──────────────┴───────────────┘")

result = {
    "experiment": "multicore_scaling",
    "duration_s": ${FUZZ_DURATION},
    "baseline_eps_single": round(baseline_eps, 2),
    "max_cpus": ${MAX_CPUS},
    "results": entries,
}
out = pathlib.Path("${OUTDIR}/results.json")
out.write_text(json.dumps(result, indent=2))
print(f"\n  results.json: {out}")
PYEOF

echo ""
ok "====== 实验 7 完成 ======"
echo "  输出目录: $OUTDIR"
echo "  后续: 查看 scaling_efficiency_pct，"
echo "        理想扩展效率为 100%，实际值反映并行化的边际效益递减"
