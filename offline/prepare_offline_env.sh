#!/bin/bash
#
# prepare_offline_env.sh — AFL++ 离线依赖下载脚本
#
# 【用途】在有网络的 Ubuntu 20.04 机器（或 Docker 容器）上运行，
#         将 AFL++ 所有编译/运行依赖下载到 offline/ 子目录中，
#         以便整体拷贝至 U 盘后在无网环境安装。
#
# 【用法】
#   # 普通模式（仅源码插桩，推荐）：
#   sudo bash offline/prepare_offline_env.sh
#
#   # 完整模式（源码插桩 + QEMU + Frida + Unicorn/Rust）：
#   sudo bash offline/prepare_offline_env.sh --full
#
# 【Docker 一键运行（推荐，保证下载全量依赖）】
#   docker run --rm \
#     -v "$(pwd)":/afl -w /afl \
#     ubuntu:20.04 \
#     bash offline/prepare_offline_env.sh [--full]
#
# 注意：脚本需要以 root 权限运行（或在容器内）。
#

set -euo pipefail

# --------------------------------------------------------------------------- #
# 辅助函数
# --------------------------------------------------------------------------- #
info()  { echo "[*] $*"; }
warn()  { echo "[!] $*" >&2; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "请以 root 权限运行：sudo bash $0"
}

# --------------------------------------------------------------------------- #
# 参数解析
# --------------------------------------------------------------------------- #
BUILD_MODE="source-only"
for arg in "$@"; do
  case $arg in
    --full)        BUILD_MODE="full" ;;
    --source-only) BUILD_MODE="source-only" ;;
    -h|--help)
      grep '^#' "$0" | head -30 | sed 's/^# //' | sed 's/^#//'
      exit 0 ;;
    *) die "未知参数：$arg（可用：--source-only | --full）" ;;
  esac
done

need_root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APT_DIR="$SCRIPT_DIR/apt_packages"
RUST_DIR="$SCRIPT_DIR/rust"
FRIDA_DIR="$SCRIPT_DIR/frida"

info "=========================================================="
info " AFL++ 离线依赖下载脚本"
info "=========================================================="
info "构建模式  : $BUILD_MODE"
info "脚本目录  : $SCRIPT_DIR"
info "仓库根目录: $REPO_ROOT"
info ""

# --------------------------------------------------------------------------- #
# 检查操作系统版本
# --------------------------------------------------------------------------- #
if [ -f /etc/os-release ]; then
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ]; then
    warn "当前系统不是 Ubuntu，脚本仅在 Ubuntu 20.04 上测试过。"
  elif [ "${VERSION_ID:-}" != "20.04" ]; then
    warn "当前系统是 Ubuntu ${VERSION_ID}，脚本针对 Ubuntu 20.04 设计，可能需要调整包名。"
  fi
fi

# --------------------------------------------------------------------------- #
# 获取架构
# --------------------------------------------------------------------------- #
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64)  ARCH_DEB="amd64";  RUST_TARGET="x86_64-unknown-linux-gnu";   FRIDA_ARCH="x86_64" ;;
  aarch64) ARCH_DEB="arm64";  RUST_TARGET="aarch64-unknown-linux-gnu";  FRIDA_ARCH="arm64"  ;;
  *)       die "暂不支持的架构：$ARCH_RAW（支持 x86_64 / aarch64）" ;;
esac
info "系统架构: $ARCH_RAW ($ARCH_DEB)"

# --------------------------------------------------------------------------- #
# 检测 GCC 版本
# --------------------------------------------------------------------------- #
if command -v gcc &>/dev/null; then
  GCC_VER=$(gcc --version | head -n1 | grep -oP '\d+\.\d+\.\d+' | head -1 | cut -d. -f1)
else
  GCC_VER="9"   # Ubuntu 20.04 默认
fi
info "GCC 版本: $GCC_VER"

# --------------------------------------------------------------------------- #
# 安装下载工具（本机临时使用）
# --------------------------------------------------------------------------- #
info "更新 apt 索引并安装下载工具..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget curl gnupg ca-certificates apt-utils dpkg-dev

# --------------------------------------------------------------------------- #
# 添加 LLVM 14 apt 仓库（用于下载最新 LLVM 包）
# --------------------------------------------------------------------------- #
info "添加 LLVM 14 apt 仓库..."
LLVM_VER=14
LLVM_KEY_URL="https://apt.llvm.org/llvm-snapshot.gpg.key"
LLVM_KEY_FILE="/etc/apt/trusted.gpg.d/llvm-snapshot.gpg"

if [ ! -f "$LLVM_KEY_FILE" ]; then
  wget -qO- "$LLVM_KEY_URL" | gpg --dearmor -o "$LLVM_KEY_FILE"
fi
LLVM_LIST="/etc/apt/sources.list.d/llvm-${LLVM_VER}.list"
if [ ! -f "$LLVM_LIST" ]; then
  echo "deb http://apt.llvm.org/focal/ llvm-toolchain-focal-${LLVM_VER} main" > "$LLVM_LIST"
fi
apt-get update -qq

# --------------------------------------------------------------------------- #
# 定义需要下载的包列表
# --------------------------------------------------------------------------- #
BASE_PKGS=(
  build-essential
  python3-dev
  python3-pip
  python3-venv
  python3-setuptools
  automake
  cmake
  git
  flex
  bison
  libglib2.0-dev
  dpkg-dev
  pkg-config
)

LLVM_PKGS=(
  "clang-${LLVM_VER}"
  "clang-tools-${LLVM_VER}"
  "libc++-${LLVM_VER}-dev"
  "libc++abi-${LLVM_VER}-dev"
  "libclang-${LLVM_VER}-dev"
  "libclang-common-${LLVM_VER}-dev"
  "libclang-cpp${LLVM_VER}-dev"
  "liblld-${LLVM_VER}-dev"
  "libllvm${LLVM_VER}"
  "libomp-${LLVM_VER}-dev"
  "libomp5-${LLVM_VER}"
  "lld-${LLVM_VER}"
  "llvm-${LLVM_VER}"
  "llvm-${LLVM_VER}-dev"
  "llvm-${LLVM_VER}-runtime"
  "llvm-${LLVM_VER}-tools"
  "gcc-${GCC_VER}-plugin-dev"
  "libstdc++-${GCC_VER}-dev"
)

QEMU_PKGS=(
  meson
  ninja-build
  libpixman-1-dev
  cpio
)

# --------------------------------------------------------------------------- #
# 下载 apt 包到 offline/apt_packages/
# --------------------------------------------------------------------------- #
info "创建 apt 包缓存目录: $APT_DIR"
mkdir -p "$APT_DIR"

_download_pkgs() {
  local label="$1"; shift
  info "下载 $label 包..."
  apt-get clean
  # --download-only：仅下载，不安装；-y：自动确认
  apt-get install -y --download-only "$@" 2>&1 | grep -E "^\(|^Get|^Ign|^\[" || true
  find /var/cache/apt/archives/ -maxdepth 1 -name "*.deb" -exec cp -n {} "$APT_DIR/" \;
  apt-get clean
}

_download_pkgs "基础构建工具" "${BASE_PKGS[@]}"
_download_pkgs "LLVM ${LLVM_VER}" "${LLVM_PKGS[@]}"

if [ "$BUILD_MODE" = "full" ]; then
  _download_pkgs "QEMU 模式依赖" "${QEMU_PKGS[@]}"
fi

# 保存 LLVM GPG 密钥（安装时使用）
info "保存 LLVM GPG 密钥..."
cp "$LLVM_KEY_FILE" "$APT_DIR/llvm-snapshot.gpg"

# --------------------------------------------------------------------------- #
# 生成本地 apt 仓库索引（Packages.gz）
# --------------------------------------------------------------------------- #
info "生成本地 apt 仓库索引 Packages.gz..."
cd "$APT_DIR"
dpkg-scanpackages --multiversion . > Packages 2>/dev/null
gzip -k -f Packages
DEB_COUNT=$(ls *.deb 2>/dev/null | wc -l)
info "已下载 ${DEB_COUNT} 个 .deb 包"

# --------------------------------------------------------------------------- #
# 初始化 git 子模块（确保子模块源码已检出）
# --------------------------------------------------------------------------- #
info "初始化 git 子模块（qemuafl / unicornafl / 等）..."
cd "$REPO_ROOT"
git submodule update --init --recursive
info "子模块初始化完成。"

# --------------------------------------------------------------------------- #
# 完整模式：下载 Frida devkit
# --------------------------------------------------------------------------- #
if [ "$BUILD_MODE" = "full" ]; then
  info "下载 Frida GumJS devkit..."
  mkdir -p "$FRIDA_DIR"
  FRIDA_VER=$(grep "^GUM_DEVKIT_VERSION" "$REPO_ROOT/frida_mode/GNUmakefile" | cut -d= -f2 | tr -d ' ')
  FRIDA_FILE="frida-gumjs-devkit-${FRIDA_VER}-linux-${FRIDA_ARCH}.tar.xz"
  FRIDA_URL="https://github.com/frida/frida/releases/download/${FRIDA_VER}/${FRIDA_FILE}"

  if [ -f "$FRIDA_DIR/$FRIDA_FILE" ]; then
    info "Frida devkit 已存在，跳过下载。"
  else
    wget -O "$FRIDA_DIR/$FRIDA_FILE" "$FRIDA_URL" || \
      curl -L -o "$FRIDA_DIR/$FRIDA_FILE" "$FRIDA_URL"
  fi
  echo "$FRIDA_VER"      > "$FRIDA_DIR/VERSION"
  echo "$FRIDA_ARCH"     > "$FRIDA_DIR/ARCH"
  echo "linux-${FRIDA_ARCH}" > "$FRIDA_DIR/OS_ARCH"
  info "Frida devkit 版本: $FRIDA_VER，文件: $FRIDA_FILE"
fi

# --------------------------------------------------------------------------- #
# 完整模式：下载 Rust 独立安装包（unicorn_mode 需要 rustc >= 1.87.0）
# --------------------------------------------------------------------------- #
if [ "$BUILD_MODE" = "full" ]; then
  info "下载 Rust 独立安装包（适用于离线安装）..."
  mkdir -p "$RUST_DIR"

  # 从 channel 文件获取当前 stable 版本号
  RUST_VERSION=$(wget -qO- "https://static.rust-lang.org/dist/channel-rust-stable.toml" \
    | grep '^version = ' | head -1 | cut -d'"' -f2)
  info "Rust stable 版本: $RUST_VERSION"

  RUST_ARCHIVE="rust-${RUST_VERSION}-${RUST_TARGET}.tar.xz"
  RUST_URL="https://static.rust-lang.org/dist/${RUST_ARCHIVE}"

  if [ -f "$RUST_DIR/$RUST_ARCHIVE" ]; then
    info "Rust 安装包已存在，跳过下载。"
  else
    wget -O "$RUST_DIR/$RUST_ARCHIVE" "$RUST_URL" || \
      curl -L -o "$RUST_DIR/$RUST_ARCHIVE" "$RUST_URL"
  fi
  echo "$RUST_VERSION" > "$RUST_DIR/VERSION"
  echo "$RUST_TARGET"  > "$RUST_DIR/TARGET"
  info "Rust 安装包: $RUST_ARCHIVE"
fi

# --------------------------------------------------------------------------- #
# 打印汇总
# --------------------------------------------------------------------------- #
echo ""
echo "=========================================================="
echo " 离线依赖准备完成！"
echo "=========================================================="
echo ""
echo "  apt 包目录  : $APT_DIR（共 ${DEB_COUNT} 个 .deb）"
if [ "$BUILD_MODE" = "full" ]; then
  echo "  Frida 目录  : $FRIDA_DIR"
  echo "  Rust 目录   : $RUST_DIR"
fi
echo ""
echo "  整体大小：$(du -sh "$SCRIPT_DIR" 2>/dev/null | cut -f1)"
echo ""
echo "【下一步】"
echo "  1. 将整个仓库目录拷贝到 U 盘"
echo "  2. 在离线 Ubuntu 20.04 机器上执行："
echo "     sudo bash offline/install_offline.sh [--full]"
echo ""
