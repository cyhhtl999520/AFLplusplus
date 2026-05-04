#!/usr/bin/env bash
# profiling/06_bitmap_size_comparison.sh
# Bitmap 大小对比实验
#
# 测量指标：execs/sec、perf cache-miss 率
# 对比维度：AFL_MAP_SIZE = 65536（64KB）、1048576（1MB）、8388608（8MB，默认）
#
# 原理：
#   - 位图越小，越容易驻留在 CPU L1/L2 缓存，cache miss 率低
#   - 位图越大，cache miss 增加，classify_counts / has_new_bits 变慢
#   - AFL_MAP_SIZE 环境变量在运行时覆盖默认值
#
# 输出：/tmp/afl-profiling/bitmap_size/results.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AFL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_BASE="/tmp/afl-profiling"
OUTDIR="$RESULTS_BASE/bitmap_size"
CONF="$RESULTS_BASE/env.conf"

info()  { echo -e "\033[1;34m[BMP ]\033[0m  $*"; }
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

# 待测试的位图大小（字节）
MAP_SIZES=(65536 1048576 8388608)
MAP_LABELS=("64KB" "1MB" "8MB(default)")

mkdir -p "$OUTDIR"
cd "$OUTDIR"

info "====== 实验 6: Bitmap 大小对比 ======"
info "待测大小: ${MAP_LABELS[*]}"
info "每次运行: ${FUZZ_DURATION}s  |  重复次数: ${RUNS}"
echo ""

# ── 辅助：运行一次 afl-fuzz，采集 execs/sec ──────────────────────────────────
run_once() {
    local map_size="$1"
    local outdir_run="$2"

    rm -rf "$outdir_run"

    AFL_NO_UI=1 \
    AFL_DISABLE_TRIM=1 \
    AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
    AFL_FAST_CAL=1 \
    AFL_MAP_SIZE="$map_size" \
    "$AFL_FUZZ" \
        -i "$INDIR" \
        -o "$outdir_run" \
        -s 123 \
        -V "$FUZZ_DURATION" \
        "$PERSIST_TARGET" \
        &>/dev/null

    local stats="$outdir_run/0/fuzzer_stats"
    if [[ -f "$stats" ]]; then
        grep "^execs_per_sec" "$stats" | awk '{print $3}'
    else
        echo "0"
    fi
}

# ── 辅助：用 perf stat 测量 cache-miss 率 ─────────────────────────────────────
measure_cache_miss() {
    local map_size="$1"
    local outdir_run="$2"

    rm -rf "$outdir_run"

    if ! command -v perf &>/dev/null; then
        echo "N/A"
        return
    fi

    local perf_out
    perf_out=$(
        AFL_NO_UI=1 \
        AFL_DISABLE_TRIM=1 \
        AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
        AFL_FAST_CAL=1 \
        AFL_MAP_SIZE="$map_size" \
        perf stat \
            -e cache-references,cache-misses \
            "$AFL_FUZZ" \
                -i "$INDIR" \
                -o "$outdir_run" \
                -s 123 \
                -V "$FUZZ_DURATION" \
                "$PERSIST_TARGET" \
            2>&1 | grep -E "cache-miss" || echo "N/A"
    )
    echo "$perf_out"
}

# ── 主循环：对每个 map size 运行实验 ──────────────────────────────────────────
declare -A EPS_AVGS
declare -A CACHE_MISS_RATES

for idx in "${!MAP_SIZES[@]}"; do
    MAP_SIZE="${MAP_SIZES[$idx]}"
    LABEL="${MAP_LABELS[$idx]}"

    info "▶ 测试 AFL_MAP_SIZE=${MAP_SIZE} (${LABEL}) ..."
    EPS_LIST=()
    for i in $(seq 1 "$RUNS"); do
        EPS=$(run_once "$MAP_SIZE" "$OUTDIR/out_${MAP_SIZE}_run${i}")
        EPS_LIST+=("$EPS")
        info "  run $i/$RUNS → execs/sec = $EPS"
    done

    # 计算均值（Python）
    AVG=$(python3 -c "
import statistics
vals = [float(x) for x in '${EPS_LIST[*]}'.split()]
print(round(statistics.mean(vals), 2))
")
    EPS_AVGS[$MAP_SIZE]="$AVG"

    # cache-miss 测量（单次，仅供参考）
    info "  测量 cache-miss 率（单次）..."
    CACHE_INFO=$(measure_cache_miss "$MAP_SIZE" "$OUTDIR/out_${MAP_SIZE}_cachemiss")
    CACHE_MISS_RATES[$MAP_SIZE]="$CACHE_INFO"
    info "  cache-miss 信息: $CACHE_INFO"
    echo ""
done

# ── 保存 JSON 结果 ────────────────────────────────────────────────────────────
python3 - <<PYEOF
import json, pathlib

map_sizes  = [65536, 1048576, 8388608]
map_labels = ["64KB", "1MB", "8MB(default)"]
eps_avgs   = {
    65536:   float("${EPS_AVGS[65536]:-0}"),
    1048576: float("${EPS_AVGS[1048576]:-0}"),
    8388608: float("${EPS_AVGS[8388608]:-0}"),
}
cache_miss = {
    65536:   "${CACHE_MISS_RATES[65536]:-N/A}",
    1048576: "${CACHE_MISS_RATES[1048576]:-N/A}",
    8388608: "${CACHE_MISS_RATES[8388608]:-N/A}",
}

print()
print("  ┌────────────────────────────────────────────────────────┐")
print("  │              Bitmap 大小对比结果                       │")
print("  ├──────────────┬───────────────────┬────────────────────┤")
print("  │  Map Size    │  均值 execs/sec   │  cache-miss 信息   │")
print("  ├──────────────┼───────────────────┼────────────────────┤")
for sz, lbl in zip(map_sizes, map_labels):
    print(f"  │  {lbl:<12}│  {eps_avgs[sz]:>17.1f}  │  {str(cache_miss[sz])[:18]:<18}  │")
print("  └──────────────┴───────────────────┴────────────────────┘")

entries = []
for sz, lbl in zip(map_sizes, map_labels):
    entries.append({
        "map_size_bytes": sz,
        "map_size_label": lbl,
        "execs_per_sec_avg": eps_avgs[sz],
        "cache_miss_info": cache_miss[sz],
    })

result = {
    "experiment": "bitmap_size_comparison",
    "duration_s": ${FUZZ_DURATION},
    "runs": ${RUNS},
    "results": entries,
}
out = pathlib.Path("${OUTDIR}/results.json")
out.write_text(json.dumps(result, indent=2))
print(f"\n  results.json: {out}")
PYEOF

echo ""
ok "====== 实验 6 完成 ======"
echo "  输出目录: $OUTDIR"
echo "  后续: 比较不同 AFL_MAP_SIZE 下的 execs/sec，"
echo "        观察位图大小对 CPU 缓存效率的影响"
