# AFLplusplus 性能 Profiling 分析套件

本目录包含一套完整的性能分析脚本，用于对 AFLplusplus 进行 CPU、内存、I/O 及进程调度等多维度的量化分析。

## 目录结构

```
profiling/
├── README.md                    # 本文档
├── setup.sh                     # 环境准备：编译 AFL++ 及测试目标
├── 01_cpu_profiling.sh          # CPU 热点分析（perf record + 火焰图）
├── 02_memory_profiling.sh       # 内存分析（Valgrind Massif）
├── 03_io_profiling.sh           # I/O 开销分析（strace -c）
├── 04_fork_vs_persistent.sh     # fork mode vs. persistent mode 对比
├── 05_tmpfs_vs_disk.sh          # tmpfs vs. 磁盘存储性能对比
├── 06_bitmap_size_comparison.sh # AFL_MAP_SIZE 位图大小对比
├── 07_multicore_scaling.sh      # 多核扩展性测试
└── analyze_results.py           # 结果汇总与可视化（Python）
```

## 快速开始

```bash
cd /path/to/AFLplusplus
# 1. 环境准备（仅需运行一次）
bash profiling/setup.sh

# 2. 运行各项分析实验
bash profiling/01_cpu_profiling.sh
bash profiling/02_memory_profiling.sh
bash profiling/03_io_profiling.sh
bash profiling/04_fork_vs_persistent.sh
bash profiling/05_tmpfs_vs_disk.sh
bash profiling/06_bitmap_size_comparison.sh
bash profiling/07_multicore_scaling.sh

# 3. 汇总分析并生成图表
python3 profiling/analyze_results.py
```

所有实验结果保存于 `/tmp/afl-profiling/` 目录下。

## 依赖工具

| 工具 | 用途 | 安装 |
|------|------|------|
| `perf` | CPU 热点采样 | `apt install linux-perf` |
| `valgrind` | 内存使用分析 | `apt install valgrind` |
| `ms_print` | Massif 报告渲染 | 随 valgrind 附带 |
| `flamegraph` | 生成火焰图 SVG | `apt install flamegraph` 或从 GitHub 克隆 |
| `strace` | 系统调用追踪 | `apt install strace` |
| `python3` + `matplotlib` + `pandas` | 结果可视化 | `pip3 install matplotlib pandas` |

## 实验概览

### 实验 1 — CPU 热点（`01_cpu_profiling.sh`）

使用 `perf record -F 99 -g` 对 `afl-fuzz` 进行采样，生成火焰图 SVG，识别耗时最多的函数：
- `classify_counts` / `has_new_bits`（位图处理）
- fork server 相关函数
- 变异策略（havoc、splicing）

输出：`/tmp/afl-profiling/cpu/flamegraph.svg`

### 实验 2 — 内存分析（`02_memory_profiling.sh`）

使用 `valgrind --tool=massif` 测量 `afl-fuzz` 的堆内存随时间的增长趋势，识别主要内存消耗点（共享内存 bitmap、队列管理等）。

输出：`/tmp/afl-profiling/memory/massif.out.*`、`massif_report.txt`

### 实验 3 — I/O 开销（`03_io_profiling.sh`）

使用 `strace -c` 统计 `afl-fuzz` 的系统调用频率和耗时，量化文件 I/O（`write`、`read`、`openat`、`unlink`）占总运行时间的比例。

输出：`/tmp/afl-profiling/io/strace_summary.txt`

### 实验 4 — Fork vs. Persistent Mode（`04_fork_vs_persistent.sh`）

分别用普通 fork 模式和 persistent 模式对同一目标进行模糊测试，对比 `execs/sec` 差异，量化进程创建开销。

输出：`/tmp/afl-profiling/fork_vs_persistent/results.json`

### 实验 5 — tmpfs vs. 磁盘（`05_tmpfs_vs_disk.sh`）

将 AFL++ 输出目录分别挂载到 tmpfs 和普通磁盘，测量 `execs/sec` 和磁盘 I/O 延迟的差异。

输出：`/tmp/afl-profiling/tmpfs_vs_disk/results.json`

### 实验 6 — Bitmap 大小（`06_bitmap_size_comparison.sh`）

通过 `AFL_MAP_SIZE` 环境变量设置不同位图大小（64KB、1MB、8MB），对比 CPU cache miss 率和 `execs/sec`。

输出：`/tmp/afl-profiling/bitmap_size/results.json`

### 实验 7 — 多核扩展性（`07_multicore_scaling.sh`）

从 1 个 fuzzer 实例逐步增加到 `N`（可用 CPU 数），记录每级并行度下的总 `execs/sec` 及 CPU 利用率。

输出：`/tmp/afl-profiling/multicore/results.json`

### 结果分析（`analyze_results.py`）

读取各实验的 JSON 结果，使用 `matplotlib` 绘制：
- fork vs. persistent mode 柱状图
- 多核扩展性折线图（线性比率 vs. 实际 exec/sec）
- bitmap 大小 vs. exec/sec 折线图
- tmpfs vs. 磁盘对比柱状图

输出：`/tmp/afl-profiling/report/`（PNG 图表）
