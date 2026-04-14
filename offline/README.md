# 无网环境下在 Ubuntu 20.04 上使用 AFL++ 进行 Fuzzing

本文档说明如何在**完全无网络**的 Ubuntu 20.04 环境中安装并使用 AFL++，
所有依赖均通过 U 盘从联网机器预先下载，无需目标机器访问互联网。

---

## 目录

1. [概述与准备](#1-概述与准备)
2. [步骤一：在联网机器上下载依赖](#2-步骤一在联网机器上下载依赖)
3. [步骤二：拷贝至 U 盘](#3-步骤二拷贝至-u-盘)
4. [步骤三：在离线机器上安装 AFL++](#4-步骤三在离线机器上安装-afl)
5. [步骤四：编译（插桩）目标程序](#5-步骤四编译插桩目标程序)
6. [步骤五：准备初始语料库（种子）](#6-步骤五准备初始语料库种子)
7. [步骤六：运行 AFL++ 进行 Fuzzing](#7-步骤六运行-afl-进行-fuzzing)
8. [步骤七：多核并行 Fuzzing](#8-步骤七多核并行-fuzzing)
9. [步骤八：查看结果与分析崩溃](#9-步骤八查看结果与分析崩溃)
10. [附录 A：构建模式说明](#附录-a构建模式说明)
11. [附录 B：常见问题](#附录-b常见问题)
12. [附录 C：目录结构说明](#附录-c目录结构说明)

---

## 1. 概述与准备

### 1.1 工作流程

```
联网机器 (Ubuntu 20.04)          U 盘              离线机器 (Ubuntu 20.04)
        |                           |                       |
        |  prepare_offline_env.sh   |                       |
        |  下载所有 .deb / Rust /   |                       |
        |  Frida / 初始化子模块     |                       |
        | ========================> |   拷贝仓库目录         |
        |                           | =====================> |
        |                           |                       |  install_offline.sh
        |                           |                       |  安装依赖 + 编译 AFL++
        |                           |                       |
        |                           |                       |  插桩目标 → Fuzzing
```

### 1.2 两种构建模式

| 模式 | make 目标 | 用途 | 额外依赖 |
|------|-----------|------|---------|
| **源码模式**（推荐）| `make source-only` | 对**有源码**的目标程序进行插桩 Fuzzing | 无额外大型依赖 |
| **完整模式** | `make distrib` | 另含 QEMU（二进制插桩）、Frida、Unicorn | Rust ≥ 1.87、Frida devkit |

> **推荐新手使用源码模式**，简单可靠，覆盖绝大多数 Fuzzing 场景。

### 1.3 要求

- **联网机器**：Ubuntu 20.04，有 sudo 权限，可访问互联网，磁盘空闲 ≥ 5 GB（完整模式 ≥ 10 GB）。
- **离线机器**：Ubuntu 20.04（x86_64 或 aarch64），sudo 权限，磁盘空闲 ≥ 5 GB。
- **U 盘**：容量 ≥ 4 GB（源码模式），完整模式建议 ≥ 10 GB。

---

## 2. 步骤一：在联网机器上下载依赖

### 方式 A：直接在联网 Ubuntu 20.04 上运行（需 sudo）

```bash
# 进入仓库目录
cd /path/to/AFLplusplus

# 初始化 git 子模块（若尚未执行）
git submodule update --init --recursive

# 下载源码模式所需依赖（推荐）
sudo bash offline/prepare_offline_env.sh

# 或者：下载完整模式依赖（含 QEMU/Frida/Rust/Unicorn）
sudo bash offline/prepare_offline_env.sh --full
```

### 方式 B：通过 Docker 运行（推荐，确保下载全量依赖）

```bash
cd /path/to/AFLplusplus

# 源码模式
docker run --rm -v "$(pwd)":/afl -w /afl ubuntu:20.04 \
  bash offline/prepare_offline_env.sh

# 完整模式
docker run --rm -v "$(pwd)":/afl -w /afl ubuntu:20.04 \
  bash offline/prepare_offline_env.sh --full
```

> **提示**：使用 Docker 方式可以保证在干净的 Ubuntu 20.04 环境下下载**所有**传递依赖（不会因本机已安装某些包而遗漏）。

### 下载完成后生成的目录结构

```
offline/
├── apt_packages/           # 所有 .deb 包 + Packages.gz 本地索引
│   ├── clang-14_*.deb
│   ├── llvm-14_*.deb
│   ├── build-essential_*.deb
│   ├── ...
│   ├── Packages             # apt 索引
│   ├── Packages.gz          # apt 索引（压缩）
│   └── llvm-snapshot.gpg    # LLVM GPG 密钥
├── frida/                  # [完整模式] Frida GumJS devkit
│   ├── frida-gumjs-devkit-*.tar.xz
│   ├── VERSION
│   ├── ARCH
│   └── OS_ARCH
├── rust/                   # [完整模式] Rust 独立安装包
│   ├── rust-*-x86_64-unknown-linux-gnu.tar.xz
│   ├── VERSION
│   └── TARGET
├── prepare_offline_env.sh  # 本脚本
├── install_offline.sh      # 离线安装脚本
└── README.md               # 本文档
```

另外，子模块目录（`qemu_mode/qemuafl/`、`unicorn_mode/unicornafl/` 等）已被 `git submodule update --init --recursive` 填充，无需单独处理。

---

## 3. 步骤二：拷贝至 U 盘

将**整个仓库目录**（含 `offline/` 子目录和已初始化的子模块）复制到 U 盘：

```bash
# 挂载 U 盘（以 /media/usb 为例）
sudo mount /dev/sdX1 /media/usb

# 复制整个仓库（rsync 可显示进度）
rsync -av --progress /path/to/AFLplusplus/ /media/usb/AFLplusplus/

# 或使用 cp
cp -r /path/to/AFLplusplus /media/usb/

# 完成后同步并卸载
sync
sudo umount /media/usb
```

> **注意**：请使用 `cp -r` 或 `rsync` 复制目录，**不要** `git clone`（clone 会丢失子模块内容）。

---

## 4. 步骤三：在离线机器上安装 AFL++

将 U 盘插入离线机器，挂载后执行：

```bash
# 挂载 U 盘
sudo mount /dev/sdX1 /media/usb

# 将仓库拷贝到本地（可选，避免从 U 盘直接操作）
cp -r /media/usb/AFLplusplus ~/AFLplusplus
cd ~/AFLplusplus

# 运行离线安装脚本（源码模式）
sudo bash offline/install_offline.sh

# 或完整模式（含 QEMU/Frida/Unicorn）
sudo bash offline/install_offline.sh --full
```

脚本将自动完成：
1. 在 `/opt/offline-afl-pkgs/` 建立本地 apt 仓库
2. 安装 build-essential、clang-14、llvm-14 等所有构建依赖
3. 配置 `clang`/`llvm-config` 等工具的系统链接
4. （完整模式）安装 Rust、放置 Frida devkit
5. 执行 `make source-only`（或 `make distrib`）编译 AFL++
6. 执行 `make install`，将 AFL++ 安装到 `/usr/local/bin/`

安装成功后可验证：

```bash
afl-fuzz --version
# AFL++ 4.x.x ...

which afl-clang-lto    # /usr/local/bin/afl-clang-lto
which afl-clang-fast   # /usr/local/bin/afl-clang-fast
```

---

## 5. 步骤四：编译（插桩）目标程序

### 5.1 选择编译器

按以下优先级选择 AFL++ 编译器：

```
afl-clang-lto   （首选，需 clang 11+，LTO 模式，覆盖率最优）
    ↓ 失败时
afl-clang-fast  （次选，需 clang/llvm，速度快）
    ↓ 失败时
afl-gcc-fast    （备选，需 gcc-plugin）
```

在 Ubuntu 20.04 + clang-14 环境下，**推荐使用 `afl-clang-lto`**。

### 5.2 有源码的目标程序

以常见的 `autoconf` 项目为例（假设目标为 `readpng`）：

```bash
# 设置编译器
export CC=afl-clang-lto
export CXX=afl-clang-lto++

# 进入目标源码目录
cd /path/to/target-source

# 按正常流程配置并编译
./configure
make -j$(nproc)

# 得到插桩后的二进制，例如 ./readpng
```

对于 `cmake` 项目：

```bash
export CC=afl-clang-lto
export CXX=afl-clang-lto++
cmake -B build -DCMAKE_BUILD_TYPE=Release .
cmake --build build -j$(nproc)
```

### 5.3 推荐：启用持久模式（大幅提升速度）

若有源码，在目标的主处理循环中加入持久模式标记，可将速度提升 **10x~20x**：

```c
#include "afl-fuzz.h"   // 或直接使用宏，无需头文件

int main(int argc, char **argv) {
    // 初始化代码...

    while (__AFL_LOOP(10000)) {    // 每次 fork 运行 10000 次迭代
        // 读取输入
        // 处理输入（被 fuzz 的逻辑）
        // 重置状态
    }
    return 0;
}
```

详见 [`instrumentation/README.persistent_mode.md`](../instrumentation/README.persistent_mode.md)。

---

## 6. 步骤五：准备初始语料库（种子）

初始种子文件质量对 Fuzzing 效率影响很大。

```bash
# 创建种子目录
mkdir -p /fuzz/input

# 放入有代表性的合法输入文件（越小越好，100B~10KB 最佳）
cp /path/to/sample.png  /fuzz/input/
cp /path/to/sample.xml  /fuzz/input/
# ... 可以有多个

# 使用 afl-cmin 精简语料库（去重，可选但推荐）
afl-cmin -i /fuzz/input -o /fuzz/input_min -- ./target_binary @@
```

> `@@` 是占位符，AFL++ 会将其替换为实际的输入文件路径。
> 若目标从 **stdin** 读取，则不需要 `@@`。

---

## 7. 步骤六：运行 AFL++ 进行 Fuzzing

### 7.1 系统配置（首次运行）

```bash
# 一键配置系统参数（core_pattern、CPU 亲和性等）
sudo afl-system-config

# 或手动设置关键参数
echo core | sudo tee /proc/sys/kernel/core_pattern
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

### 7.2 启动单实例 Fuzzing

```bash
# 输入从文件读取（@@ 模式）
afl-fuzz -i /fuzz/input -o /fuzz/output -- ./target_binary @@

# 输入从 stdin 读取
afl-fuzz -i /fuzz/input -o /fuzz/output -- ./target_binary

# 常用选项说明：
#   -i <dir>   种子输入目录
#   -o <dir>   输出目录（崩溃/队列等）
#   -m none    不限制内存（适合大内存程序）
#   -t 5000    超时时间（ms），默认自动检测
#   -x <dict>  字典文件，可提升特定格式的 Fuzzing 效率
#              AFL++ 自带字典在 dictionaries/ 目录
```

### 7.3 使用字典提升效率

```bash
# 查看可用字典
ls dictionaries/

# 使用 HTTP 字典 fuzzing 解析器
afl-fuzz -i /fuzz/input -o /fuzz/output \
         -x dictionaries/http.dict \
         -- ./target_binary @@
```

---

## 8. 步骤七：多核并行 Fuzzing

AFL++ 支持多进程并行 Fuzzing，充分利用多核 CPU。

```bash
# 主进程（-M，必须有且仅有一个）
afl-fuzz -M main-fuzzer \
         -i /fuzz/input -o /fuzz/output \
         -- ./target_binary @@

# 在其他终端启动从进程（-S，可以有多个）
afl-fuzz -S slave-01 \
         -i /fuzz/input -o /fuzz/output \
         -- ./target_binary @@

afl-fuzz -S slave-02 \
         -i /fuzz/input -o /fuzz/output \
         -- ./target_binary @@

# 查看所有实例状态
afl-whatsup /fuzz/output
```

> **建议**：CPU 有 N 个核时，启动 1 个 `-M` 主进程 + (N-1) 个 `-S` 从进程。

---

## 9. 步骤八：查看结果与分析崩溃

### 9.1 实时状态界面

`afl-fuzz` 运行时显示实时状态面板，主要关注指标：

| 字段 | 说明 |
|------|------|
| `exec speed` | 每秒执行次数，越高越好 |
| `stability` | 稳定性，低于 90% 说明目标有非确定性行为 |
| `total paths` | 已发现的路径数（覆盖率） |
| `crashes` | 发现的崩溃数 |
| `hangs` | 发现的超时数 |

### 9.2 输出目录结构

```
/fuzz/output/
└── main-fuzzer/
    ├── queue/          # 触发新路径的测试用例
    ├── crashes/        # 导致崩溃的测试用例 ← 重点关注
    ├── hangs/          # 导致超时的测试用例
    ├── fuzzer_stats    # 统计信息
    └── plot_data       # 绘图数据
```

### 9.3 分析崩溃

```bash
# 列出所有崩溃
ls /fuzz/output/main-fuzzer/crashes/

# 重现崩溃（用原始未插桩的二进制）
./target_binary_uninstrumented /fuzz/output/main-fuzzer/crashes/id:000000,*

# 使用 AddressSanitizer 重新编译以获取详细报告
AFL_USE_ASAN=1 afl-clang-lto -o target_asan ./target.c
./target_asan /fuzz/output/main-fuzzer/crashes/id:000000,*

# 使用 afl-tmin 最小化崩溃用例
afl-tmin -i /fuzz/output/main-fuzzer/crashes/id:000000,* \
         -o /tmp/minimized_crash \
         -- ./target_binary @@
```

### 9.4 绘制进度图

```bash
afl-plot /fuzz/output/main-fuzzer /tmp/afl-plot-output
# 在 /tmp/afl-plot-output/ 生成进度图（需要 gnuplot）
```

---

## 附录 A：构建模式说明

### 源码模式（`make source-only`）包含

- `afl-fuzz`、`afl-showmap`、`afl-tmin`、`afl-analyze` 等核心工具
- `afl-clang-lto` / `afl-clang-fast`（LLVM 插桩）
- `afl-gcc-fast`（GCC 插桩）
- `libdislocator.so`、`libtokencap.so` 工具库

### 完整模式（`make distrib`）额外包含

- **QEMU 模式**（`afl-qemu-trace`）：对**无源码**二进制进行黑盒 Fuzzing
  - 需要：`meson`、`ninja`、`libpixman-1-dev`
- **Frida 模式**（`afl-frida-trace`）：运行时插桩，支持闭源二进制
  - 需要：Frida GumJS devkit（已预下载到 `offline/frida/`）
- **Unicorn 模式**：基于 Unicorn 模拟器的 Fuzzing
  - 需要：Rust >= 1.87.0（已预下载到 `offline/rust/`）

---

## 附录 B：常见问题

### Q1：运行 afl-fuzz 时提示 "Hmm, your system is configured to send core dump notifications..."

```bash
echo core | sudo tee /proc/sys/kernel/core_pattern
# 或
sudo afl-system-config
```

### Q2：提示 "CPU scaling governor is set to 'ondemand'"

```bash
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
# 或
sudo afl-system-config
```

### Q3：afl-clang-lto 不可用，只有 afl-clang-fast

`afl-clang-lto` 需要 clang 11+（已安装 clang-14 应该可用）。检查：

```bash
which afl-clang-lto
afl-clang-lto --version
```

如仍不可用，改用 `afl-clang-fast`：

```bash
export CC=afl-clang-fast
export CXX=afl-clang-fast++
```

### Q4：prepare_offline_env.sh 下载了某些包，但离线机器安装时缺少依赖

原因：prepare 脚本在已安装了部分包的机器上运行，跳过了已满足的依赖。

**解决**：在 Docker 容器（干净 Ubuntu 20.04）中运行 prepare 脚本（见[方式 B](#方式-b通过-docker-运行推荐确保下载全量依赖)）。

### Q5：unicorn_mode 编译失败

确认 Rust 版本满足 >= 1.87.0：

```bash
rustc --version
```

如版本过低，重新运行 `install_offline.sh --full` 会自动从 `offline/rust/` 安装新版本。

### Q6：稳定性（stability）很低（< 85%）

- 目标程序中有非确定性行为（随机数、时间戳、哈希竞争等）。
- 解决方案：设置环境变量屏蔽不确定因素，或将相关函数从插桩列表中排除。
- 详见 [`docs/best_practices.md`](../docs/best_practices.md) 中的「Improving stability」部分。

### Q7：exec speed 很低（< 100 exec/s）

- 启用持久模式（见[步骤四 5.3](#53-推荐启用持久模式大幅提升速度)）
- 确认 CPU 调频策略为 `performance`
- 减少目标程序初始化开销（使用 `AFL_DEFER_FORKSRV=1`）

---

## 附录 C：目录结构说明

```
AFLplusplus/
├── offline/                    # 离线支持（本目录）
│   ├── README.md               # 本文档
│   ├── prepare_offline_env.sh  # 在联网机器上运行，下载依赖
│   ├── install_offline.sh      # 在离线机器上运行，安装+编译
│   ├── apt_packages/           # 下载的 .deb 包（运行 prepare 后生成）
│   ├── frida/                  # Frida devkit（--full 模式）
│   └── rust/                   # Rust 独立安装包（--full 模式）
├── docs/
│   ├── INSTALL.md              # 官方安装文档（联网）
│   ├── fuzzing_in_depth.md     # 深度 Fuzzing 指南
│   └── best_practices.md       # 最佳实践
├── instrumentation/            # LLVM/GCC 插桩插件源码
├── frida_mode/                 # Frida 模式
├── qemu_mode/                  # QEMU 模式
├── unicorn_mode/               # Unicorn 模式
├── dictionaries/               # 内置字典文件（xml、http、json 等）
├── testcases/                  # 示例测试用例
└── GNUmakefile                 # 主构建文件
```

---

*如有问题，请参阅 [`docs/FAQ.md`](../docs/FAQ.md) 或提交 Issue。*
