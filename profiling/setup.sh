#!/usr/bin/env bash
# profiling/setup.sh
# 环境准备脚本：编译带调试符号的 AFL++，并构建用于 profiling 的测试目标。
# 用法：bash profiling/setup.sh [AFL++ 源码根目录]
#
# 脚本执行内容：
#   1. 检查并报告所需依赖工具
#   2. 使用 DEBUG=1 编译 AFL++ 以保留符号信息
#   3. 用 afl-clang-fast 编译 fork mode 测试目标（test-instr）
#   4. 用 afl-clang-fast 编译 persistent mode 测试目标（test-instr-persist-shmem）
#   5. 创建 profiling 结果输出目录树

set -euo pipefail

# ── 路径配置 ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AFL_ROOT="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULTS_BASE="/tmp/afl-profiling"

# ── 颜色输出 ──────────────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[0;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

# ── 依赖检查 ──────────────────────────────────────────────────────────────────
info "检查依赖工具..."

REQUIRED_TOOLS=(make gcc clang strace python3)
OPTIONAL_TOOLS=(perf valgrind ms_print flamegraph stackcollapse-perf.pl)

for t in "${REQUIRED_TOOLS[@]}"; do
    if command -v "$t" &>/dev/null; then
        ok "$t 已安装"
    else
        error "缺少必需工具: $t  →  请先安装后重试"
        exit 1
    fi
done

for t in "${OPTIONAL_TOOLS[@]}"; do
    if command -v "$t" &>/dev/null; then
        ok "$t 已安装（可选）"
    else
        warn "$t 未安装（部分实验将跳过该工具）"
    fi
done

# ── Python 包检查 ─────────────────────────────────────────────────────────────
info "检查 Python 依赖..."
python3 -c "import matplotlib, pandas" 2>/dev/null \
    && ok "matplotlib 和 pandas 已安装" \
    || { warn "matplotlib/pandas 未安装，将尝试自动安装（--user）..."; pip3 install --user --quiet matplotlib pandas; }

# ── 编译 AFL++ (DEBUG=1) ──────────────────────────────────────────────────────
info "编译 AFL++ (DEBUG=1)，源码目录: $AFL_ROOT ..."
cd "$AFL_ROOT"
make clean -s 2>/dev/null || true
# DEBUG=1 保留调试符号（-g -O0），便于 perf/valgrind 精确定位源码行
make -j"$(nproc)" DEBUG=1 2>&1 | tail -5
ok "AFL++ 编译完成"

# ── 检查编译产物 ──────────────────────────────────────────────────────────────
for bin in afl-fuzz afl-cc; do
    if [[ -x "$AFL_ROOT/$bin" ]]; then
        ok "$bin 已就绪"
    else
        error "$bin 未找到，请检查编译日志"
        exit 1
    fi
done

# ── 编译 fork mode 测试目标 ───────────────────────────────────────────────────
FORK_TARGET="$AFL_ROOT/profiling/test-instr-fork"
info "编译 fork mode 测试目标: $FORK_TARGET ..."
"$AFL_ROOT/afl-cc" \
    -o "$FORK_TARGET" \
    "$AFL_ROOT/test-instr.c" \
    2>&1 | tail -3
ok "fork mode 目标编译完成: $FORK_TARGET"

# ── 编译 persistent mode 测试目标 ─────────────────────────────────────────────
PERSIST_TARGET="$AFL_ROOT/profiling/test-instr-persist"
info "编译 persistent mode 测试目标: $PERSIST_TARGET ..."
"$AFL_ROOT/afl-cc" \
    -o "$PERSIST_TARGET" \
    "$AFL_ROOT/utils/persistent_mode/test-instr.c" \
    2>&1 | tail -3
ok "persistent mode 目标编译完成: $PERSIST_TARGET"

# ── 创建输出目录树 ────────────────────────────────────────────────────────────
info "创建 profiling 输出目录: $RESULTS_BASE ..."
mkdir -p \
    "$RESULTS_BASE/cpu" \
    "$RESULTS_BASE/memory" \
    "$RESULTS_BASE/io" \
    "$RESULTS_BASE/fork_vs_persistent" \
    "$RESULTS_BASE/tmpfs_vs_disk" \
    "$RESULTS_BASE/bitmap_size" \
    "$RESULTS_BASE/multicore" \
    "$RESULTS_BASE/report"

# 创建种子输入文件
mkdir -p "$RESULTS_BASE/in"
echo "FUZZ_INPUT_SEED" > "$RESULTS_BASE/in/seed.txt"
ok "种子输入已写入 $RESULTS_BASE/in/seed.txt"

# ── 保存本次编译信息 ──────────────────────────────────────────────────────────
{
    echo "afl_root=$AFL_ROOT"
    echo "fork_target=$FORK_TARGET"
    echo "persist_target=$PERSIST_TARGET"
    echo "results_base=$RESULTS_BASE"
    echo "cpu_count=$(nproc)"
    echo "afl_version=$("$AFL_ROOT/afl-fuzz" --version 2>&1 | head -1 || true)"
} > "$RESULTS_BASE/env.conf"
ok "环境配置已保存至 $RESULTS_BASE/env.conf"

echo ""
ok "====== 环境准备完成，可开始运行各项 profiling 实验 ======"
echo ""
echo "  测试目标（fork mode）    : $FORK_TARGET"
echo "  测试目标（persistent）   : $PERSIST_TARGET"
echo "  结果输出目录             : $RESULTS_BASE"
echo ""
echo "  下一步："
echo "    bash profiling/01_cpu_profiling.sh"
