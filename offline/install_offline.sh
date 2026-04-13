#!/bin/bash
#
# install_offline.sh — AFL++ 离线安装脚本
#
# 【用途】在无网络的 Ubuntu 20.04 目标机器上运行。
#         从 offline/ 目录读取预下载的依赖包，完成安装并编译 AFL++。
#
# 【前提条件】
#   1. 已在联网机器上运行 prepare_offline_env.sh，生成了 offline/apt_packages/ 等目录。
#   2. 整个仓库（含 offline/ 子目录）已拷贝到本机。
#   3. 以 root 权限运行本脚本。
#
# 【用法】
#   # 源码插桩模式（推荐，只需 make source-only）：
#   sudo bash offline/install_offline.sh
#
#   # 完整模式（源码 + QEMU + Frida + Unicorn/Rust）：
#   sudo bash offline/install_offline.sh --full
#
# 安装完成后，参考 offline/README.md 进行目标程序插桩和 Fuzzing。
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
      grep '^#' "$0" | head -25 | sed 's/^# //' | sed 's/^#//'
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
info " AFL++ 离线安装脚本"
info "=========================================================="
info "构建模式  : $BUILD_MODE"
info "脚本目录  : $SCRIPT_DIR"
info "仓库根目录: $REPO_ROOT"
info ""

# --------------------------------------------------------------------------- #
# 检查 apt 包目录
# --------------------------------------------------------------------------- #
[ -d "$APT_DIR" ] || die "找不到 $APT_DIR，请先在联网机器上运行 prepare_offline_env.sh"
[ -f "$APT_DIR/Packages.gz" ] || die "找不到 $APT_DIR/Packages.gz，请重新运行 prepare_offline_env.sh"

DEB_COUNT=$(ls "$APT_DIR"/*.deb 2>/dev/null | wc -l)
info "发现 ${DEB_COUNT} 个本地 .deb 包"

# --------------------------------------------------------------------------- #
# 获取架构
# --------------------------------------------------------------------------- #
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64)  FRIDA_ARCH="x86_64" ;;
  aarch64) FRIDA_ARCH="arm64"  ;;
  *)       warn "架构 $ARCH_RAW 未经测试。" ;;
esac

export DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------------------------- #
# 建立本地 apt 仓库
# --------------------------------------------------------------------------- #
info "建立本地 apt 仓库..."
LOCAL_REPO="/opt/offline-afl-pkgs"
mkdir -p "$LOCAL_REPO"
cp "$APT_DIR"/*.deb "$LOCAL_REPO/"
cp "$APT_DIR/Packages.gz" "$LOCAL_REPO/"

# 导入 LLVM GPG 密钥（已保存到 apt_packages/ 目录）
if [ -f "$APT_DIR/llvm-snapshot.gpg" ]; then
  cp "$APT_DIR/llvm-snapshot.gpg" /etc/apt/trusted.gpg.d/llvm-snapshot.gpg
  info "LLVM GPG 密钥已导入。"
fi

# 屏蔽默认联网 apt 源，避免在断网环境下 apt-get update 访问外网报错
info "屏蔽默认 Ubuntu apt 源（离线模式不需要联网）..."
truncate -s 0 /etc/apt/sources.list
if [ -d /etc/apt/sources.list.d/ ]; then
  find /etc/apt/sources.list.d/ -name "*.list" \
    ! -name "local-offline-afl.list" \
    -exec mv {} {}.disabled \; || warn "屏蔽部分 apt 源文件失败，继续..."
fi

# 写入本地离线源配置
cat > /etc/apt/sources.list.d/local-offline-afl.list <<EOF
deb [trusted=yes] file://${LOCAL_REPO} ./
EOF
info "本地 apt 源：file://$LOCAL_REPO"
# 移除 -qq 以便能看到 apt update 的实际错误
apt-get update 2>&1 | grep -vE '^(Hit|Ign|Get):' | head -20 || warn "apt-get update 遇到问题，继续..."

# --------------------------------------------------------------------------- #
# 安装依赖包
# --------------------------------------------------------------------------- #
LLVM_VER=14
GCC_VER=$(gcc --version 2>/dev/null | head -n1 | grep -oP '\d+\.\d+\.\d+' | head -1 | cut -d. -f1 || echo "9")

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

info "安装基础构建工具..."
apt-get install -y --allow-unauthenticated "${BASE_PKGS[@]}" 2>&1 | tail -5 || \
  warn "部分基础包安装失败，继续尝试..."

info "安装 LLVM ${LLVM_VER} 工具链..."
apt-get install -y --allow-unauthenticated "${LLVM_PKGS[@]}" 2>&1 | tail -5 || \
  warn "部分 LLVM 包安装失败，继续尝试..."

if [ "$BUILD_MODE" = "full" ]; then
  info "安装 QEMU 模式依赖..."
  apt-get install -y --allow-unauthenticated "${QEMU_PKGS[@]}" 2>&1 | tail -5 || \
    warn "部分 QEMU 依赖安装失败，继续尝试..."
fi

# 如果 make 仍不可用（apt 安装失败），用 dpkg 直接安装所有离线包作为兜底
if ! command -v make &>/dev/null; then
  warn "make 未找到（apt 安装可能不完整），使用 dpkg 直接安装所有离线包..."
  dpkg -i --force-depends "$LOCAL_REPO"/*.deb 2>&1 | tail -20 || true
  dpkg --configure -a 2>&1 | tail -10 || true
  # 第二遍：修复依赖顺序问题
  dpkg -i "$LOCAL_REPO"/*.deb 2>&1 | tail -5 || true
  dpkg --configure -a 2>&1 | tail -5 || true
  # 尝试用 apt-get -f 修复残余的损坏依赖
  apt-get install -f -y --allow-unauthenticated 2>&1 | tail -10 || true
fi

# --------------------------------------------------------------------------- #
# 配置 clang/llvm update-alternatives（使 afl-clang-fast 能找到正确版本）
# --------------------------------------------------------------------------- #
info "配置 LLVM ${LLVM_VER} 为系统默认..."
for tool in clang clang++ llvm-config llvm-ar llvm-nm llvm-ranlib \
            llvm-objcopy llvm-objdump llvm-strip lld ld.lld; do
  src="/usr/bin/${tool}-${LLVM_VER}"
  dst="/usr/bin/${tool}"
  if [ -f "$src" ]; then
    update-alternatives --install "$dst" "$tool" "$src" 100 2>/dev/null || \
      ln -sf "$src" "$dst" 2>/dev/null || true
  fi
done
info "LLVM 版本链接配置完成。"

# --------------------------------------------------------------------------- #
# 完整模式：安装 Rust（unicorn_mode 需要 rustc >= 1.87.0）
# --------------------------------------------------------------------------- #
if [ "$BUILD_MODE" = "full" ] && [ -d "$RUST_DIR" ]; then
  if command -v rustc &>/dev/null; then
    INSTALLED_RUST=$(rustc --version | awk '{print $2}')
    info "Rust 已安装：$INSTALLED_RUST，跳过。"
  else
    info "安装 Rust（从本地离线包）..."
    RUST_VERSION=$(cat "$RUST_DIR/VERSION" 2>/dev/null || die "找不到 $RUST_DIR/VERSION")
    RUST_TARGET=$(cat "$RUST_DIR/TARGET"   2>/dev/null || die "找不到 $RUST_DIR/TARGET")
    RUST_ARCHIVE="$RUST_DIR/rust-${RUST_VERSION}-${RUST_TARGET}.tar.xz"

    [ -f "$RUST_ARCHIVE" ] || die "找不到 Rust 安装包：$RUST_ARCHIVE"

    RUST_TMP=$(mktemp -d)
    info "解压 $RUST_ARCHIVE 到 $RUST_TMP ..."
    tar xf "$RUST_ARCHIVE" -C "$RUST_TMP"
    RUST_DIR_EXTRACTED=$(ls "$RUST_TMP")
    info "运行 Rust install.sh..."
    "$RUST_TMP/$RUST_DIR_EXTRACTED/install.sh" --prefix=/usr/local
    rm -rf "$RUST_TMP"
    info "Rust 安装完成：$(rustc --version)"
  fi
elif [ "$BUILD_MODE" = "full" ] && [ ! -d "$RUST_DIR" ]; then
  warn "找不到 $RUST_DIR，unicorn_mode 将被跳过。"
  warn "如需 unicorn_mode，请重新运行 prepare_offline_env.sh --full"
fi

# --------------------------------------------------------------------------- #
# 完整模式：放置 Frida devkit 到正确构建目录（避免构建时联网下载）
# --------------------------------------------------------------------------- #
if [ "$BUILD_MODE" = "full" ] && [ -d "$FRIDA_DIR" ]; then
  FRIDA_VER=$(cat "$FRIDA_DIR/VERSION" 2>/dev/null || echo "")
  FRIDA_OS_ARCH=$(cat "$FRIDA_DIR/OS_ARCH" 2>/dev/null || echo "linux-${FRIDA_ARCH}")
  if [ -n "$FRIDA_VER" ]; then
    FRIDA_FILE="frida-gumjs-devkit-${FRIDA_VER}-${FRIDA_OS_ARCH}.tar.xz"
    FRIDA_SRC="$FRIDA_DIR/$FRIDA_FILE"
    FRIDA_DEST="$REPO_ROOT/frida_mode/build/frida"
    if [ -f "$FRIDA_SRC" ]; then
      info "预置 Frida devkit 到 $FRIDA_DEST..."
      mkdir -p "$FRIDA_DEST"
      cp "$FRIDA_SRC" "$FRIDA_DEST/$FRIDA_FILE"
    else
      warn "找不到 $FRIDA_SRC，frida_mode 构建时将尝试联网下载。"
    fi
  fi
elif [ "$BUILD_MODE" = "full" ] && [ ! -d "$FRIDA_DIR" ]; then
  warn "找不到 $FRIDA_DIR，frida_mode 将被跳过（构建时 NO_FRIDA=1）。"
fi

# --------------------------------------------------------------------------- #
# 编译 AFL++
# --------------------------------------------------------------------------- #
info "开始编译 AFL++..."
cd "$REPO_ROOT"

export LLVM_CONFIG="llvm-config-${LLVM_VER}"

if [ "$BUILD_MODE" = "source-only" ]; then
  info "执行 make source-only（源码插桩模式）..."
  make source-only -j"$(nproc)" 2>&1 | tee /tmp/afl-build.log | tail -30
else
  info "执行 make distrib（完整构建）..."
  FRIDA_FLAG=""
  RUST_FLAG=""
  [ ! -d "$FRIDA_DIR" ] && FRIDA_FLAG="NO_FRIDA=1"
  [ ! -d "$RUST_DIR"  ] && RUST_FLAG="NO_UNICORN=1"
  make distrib -j"$(nproc)" ${FRIDA_FLAG} ${RUST_FLAG} 2>&1 | tee /tmp/afl-build.log | tail -30
fi

# --------------------------------------------------------------------------- #
# 安装 AFL++
# --------------------------------------------------------------------------- #
info "安装 AFL++ 到 /usr/local ..."
make install

# --------------------------------------------------------------------------- #
# 验证
# --------------------------------------------------------------------------- #
echo ""
echo "=========================================================="
echo " AFL++ 安装完成！"
echo "=========================================================="
echo ""
echo "  版本信息："
afl-fuzz --version 2>&1 | head -2 || echo "  (afl-fuzz 不在 PATH，请检查 /usr/local/bin)"
echo ""
echo "  可用编译器："
for cc in afl-clang-lto afl-clang-fast afl-gcc-fast afl-cc; do
  if command -v "$cc" &>/dev/null; then
    printf "    %-20s -> %s\n" "$cc" "$(which $cc)"
  fi
done
echo ""
echo "【下一步】请阅读 offline/README.md 了解如何插桩目标并开始 Fuzzing。"
echo ""
