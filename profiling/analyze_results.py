#!/usr/bin/env python3
"""
profiling/analyze_results.py
=============================
读取各实验产生的 JSON 结果文件，汇总统计数据并使用 matplotlib 生成以下图表：

  1. fork_vs_persistent_bar.png   — fork mode vs. persistent mode 柱状图
  2. tmpfs_vs_disk_bar.png        — tmpfs vs. 磁盘存储对比柱状图
  3. bitmap_size_line.png         — bitmap 大小 vs. execs/sec 折线图
  4. multicore_scaling_line.png   — 多核扩展性（实际 vs. 理想线性）折线图
  5. io_syscall_pie.png           — I/O 系统调用时间占比饼图
  6. memory_timeline.png          — 堆内存随时间增长曲线（若 Massif 数据可用）
  7. summary_report.txt           — 所有实验的文字摘要报告

输出目录：/tmp/afl-profiling/report/

用法：
    python3 profiling/analyze_results.py [--results-dir /tmp/afl-profiling]
"""

import argparse
import json
import pathlib
import sys
import textwrap
from typing import Any, Dict, List, Optional

# ── 依赖检查 ──────────────────────────────────────────────────────────────────
try:
    import matplotlib
    matplotlib.use("Agg")  # 无显示器环境
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("[WARN] matplotlib 未安装，跳过图表生成。安装: pip3 install matplotlib", flush=True)

# ── 参数解析 ──────────────────────────────────────────────────────────────────
parser = argparse.ArgumentParser(description="AFLplusplus Profiling 结果分析与可视化")
parser.add_argument(
    "--results-dir", default="/tmp/afl-profiling",
    help="profiling 结果根目录（默认: /tmp/afl-profiling）"
)
args = parser.parse_args()

RESULTS_DIR = pathlib.Path(args.results_dir)
REPORT_DIR = RESULTS_DIR / "report"
REPORT_DIR.mkdir(parents=True, exist_ok=True)


# ── 工具函数 ──────────────────────────────────────────────────────────────────
def load_json(path: pathlib.Path) -> Optional[Dict[str, Any]]:
    if path.exists():
        try:
            return json.loads(path.read_text())
        except json.JSONDecodeError as e:
            print(f"[WARN] 无法解析 {path}: {e}")
    else:
        print(f"[INFO] 文件不存在，跳过: {path}")
    return None


def save_fig(fig: "plt.Figure", filename: str) -> pathlib.Path:
    out = REPORT_DIR / filename
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  [图表] 已保存: {out}")
    return out


STYLE = {
    "fork":       ("#e74c3c", "Fork Mode"),
    "persistent": ("#2ecc71", "Persistent Mode"),
    "disk":       ("#e67e22", "磁盘（Disk）"),
    "tmpfs":      ("#3498db", "tmpfs（内存）"),
}


# ── 图表 1：Fork vs. Persistent Mode ─────────────────────────────────────────
def plot_fork_vs_persistent(data: Dict) -> None:
    fork_avg    = data["fork"]["execs_per_sec_avg"]
    persist_avg = data["persistent"]["execs_per_sec_avg"]
    fork_std    = data["fork"].get("execs_per_sec_stdev", 0)
    persist_std = data["persistent"].get("execs_per_sec_stdev", 0)
    speedup     = data.get("speedup_ratio", 0)

    fig, ax = plt.subplots(figsize=(7, 5))
    bars = ax.bar(
        ["Fork Mode", "Persistent Mode"],
        [fork_avg, persist_avg],
        color=[STYLE["fork"][0], STYLE["persistent"][0]],
        yerr=[fork_std, persist_std],
        capsize=6,
        width=0.5,
        edgecolor="black", linewidth=0.8,
    )

    for bar, val in zip(bars, [fork_avg, persist_avg]):
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + max(fork_std, persist_std) * 1.1,
            f"{val:,.0f}",
            ha="center", va="bottom", fontsize=11, fontweight="bold"
        )

    ax.set_ylabel("execs / sec", fontsize=12)
    ax.set_title(
        f"Fork Mode vs. Persistent Mode\n（speedup = {speedup:.2f}×，运行 {data['duration_s']}s × {data['runs']} 次）",
        fontsize=13, pad=14
    )
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f}"))
    ax.grid(axis="y", linestyle="--", alpha=0.5)
    ax.set_axisbelow(True)

    if HAS_MATPLOTLIB:
        save_fig(fig, "fork_vs_persistent_bar.png")


# ── 图表 2：tmpfs vs. 磁盘 ───────────────────────────────────────────────────
def plot_tmpfs_vs_disk(data: Dict) -> None:
    disk_avg   = data["disk"]["execs_per_sec_avg"]
    tmpfs_avg  = data["tmpfs"]["execs_per_sec_avg"]
    disk_std   = data["disk"].get("execs_per_sec_stdev", 0)
    tmpfs_std  = data["tmpfs"].get("execs_per_sec_stdev", 0)
    speedup    = data.get("speedup_ratio", 0)
    real_mount = data.get("tmpfs_real_mount", False)
    note       = "（真实 tmpfs 挂载）" if real_mount else "（使用 /dev/shm）"

    fig, ax = plt.subplots(figsize=(7, 5))
    bars = ax.bar(
        ["磁盘（Disk）", f"tmpfs {note}"],
        [disk_avg, tmpfs_avg],
        color=[STYLE["disk"][0], STYLE["tmpfs"][0]],
        yerr=[disk_std, tmpfs_std],
        capsize=6,
        width=0.5,
        edgecolor="black", linewidth=0.8,
    )

    for bar, val in zip(bars, [disk_avg, tmpfs_avg]):
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + max(disk_std, tmpfs_std) * 1.1,
            f"{val:,.0f}",
            ha="center", va="bottom", fontsize=11, fontweight="bold"
        )

    ax.set_ylabel("execs / sec", fontsize=12)
    ax.set_title(
        f"tmpfs vs. 磁盘 I/O 性能对比\n（speedup = {speedup:.3f}×，运行 {data['duration_s']}s × {data['runs']} 次）",
        fontsize=13, pad=14
    )
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f}"))
    ax.grid(axis="y", linestyle="--", alpha=0.5)
    ax.set_axisbelow(True)

    if HAS_MATPLOTLIB:
        save_fig(fig, "tmpfs_vs_disk_bar.png")


# ── 图表 3：Bitmap 大小 vs. execs/sec ─────────────────────────────────────────
def plot_bitmap_size(data: Dict) -> None:
    entries = data["results"]
    labels  = [e["map_size_label"] for e in entries]
    eps     = [e["execs_per_sec_avg"] for e in entries]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(labels, eps, marker="o", linewidth=2, markersize=8, color="#8e44ad")

    for lbl, val in zip(labels, eps):
        ax.annotate(
            f"{val:,.0f}",
            xy=(lbl, val),
            xytext=(0, 10),
            textcoords="offset points",
            ha="center", fontsize=10
        )

    ax.set_xlabel("AFL_MAP_SIZE（位图大小）", fontsize=12)
    ax.set_ylabel("execs / sec", fontsize=12)
    ax.set_title(
        f"Bitmap 大小对 execs/sec 的影响\n（运行 {data['duration_s']}s × {data['runs']} 次）",
        fontsize=13, pad=14
    )
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f}"))
    ax.grid(linestyle="--", alpha=0.5)
    ax.set_axisbelow(True)

    if HAS_MATPLOTLIB:
        save_fig(fig, "bitmap_size_line.png")


# ── 图表 4：多核扩展性 ────────────────────────────────────────────────────────
def plot_multicore_scaling(data: Dict) -> None:
    entries  = data["results"]
    fuzzers  = [e["fuzzers"] for e in entries]
    actual   = [e["execs_per_sec_total"] for e in entries]
    ideal    = [e["execs_per_sec_ideal"] for e in entries]
    eff      = [e["scaling_efficiency_pct"] for e in entries]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5))
    fig.suptitle(
        f"多核扩展性测试（运行 {data['duration_s']}s，最大 {data['max_cpus']} 核）",
        fontsize=14, y=1.02
    )

    # 左图：实际 vs. 理想 execs/sec
    ax1.plot(fuzzers, ideal, "--", color="gray", linewidth=1.5, label="理想线性增长")
    ax1.plot(fuzzers, actual, marker="o", linewidth=2, markersize=8,
             color="#1abc9c", label="实际 execs/sec")
    for n, val in zip(fuzzers, actual):
        ax1.annotate(f"{val:,.0f}", xy=(n, val), xytext=(0, 8),
                     textcoords="offset points", ha="center", fontsize=8)
    ax1.set_xlabel("Fuzzer 实例数", fontsize=11)
    ax1.set_ylabel("总 execs / sec", fontsize=11)
    ax1.set_title("实际 vs. 理想线性增长", fontsize=12)
    ax1.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f}"))
    ax1.legend(fontsize=10)
    ax1.grid(linestyle="--", alpha=0.5)
    ax1.set_axisbelow(True)

    # 右图：扩展效率（%）
    ax2.bar(fuzzers, eff, color="#f39c12", edgecolor="black", linewidth=0.8)
    ax2.axhline(100, color="red", linestyle="--", linewidth=1.2, label="100%（理想）")
    for n, val in zip(fuzzers, eff):
        ax2.text(n, val + 1, f"{val:.1f}%", ha="center", fontsize=9, fontweight="bold")
    ax2.set_xlabel("Fuzzer 实例数", fontsize=11)
    ax2.set_ylabel("扩展效率（%）", fontsize=11)
    ax2.set_title("并行扩展效率", fontsize=12)
    ax2.set_ylim(0, 120)
    ax2.legend(fontsize=10)
    ax2.grid(axis="y", linestyle="--", alpha=0.5)
    ax2.set_axisbelow(True)

    plt.tight_layout()
    if HAS_MATPLOTLIB:
        save_fig(fig, "multicore_scaling_line.png")


# ── 图表 5：I/O 系统调用时间占比饼图 ─────────────────────────────────────────
def plot_io_syscalls(data: Dict) -> None:
    syscalls = data.get("syscalls", {})
    if not syscalls:
        print("  [INFO] 无 I/O 系统调用数据，跳过饼图")
        return

    # 只展示 top-10 耗时项
    sorted_items = sorted(syscalls.items(), key=lambda x: x[1]["percent_time"], reverse=True)[:10]
    labels = [item[0] for item in sorted_items]
    sizes  = [item[1]["percent_time"] for item in sorted_items]
    other  = max(0, 100 - sum(sizes))
    if other > 0.1:
        labels.append("其他")
        sizes.append(other)

    fig, ax = plt.subplots(figsize=(9, 7))
    wedges, texts, autotexts = ax.pie(
        sizes,
        labels=labels,
        autopct="%1.1f%%",
        startangle=140,
        pctdistance=0.8,
    )
    for autotext in autotexts:
        autotext.set_fontsize(9)

    ax.set_title(
        f"afl-fuzz 系统调用时间占比（top-10）\n"
        f"I/O 类调用总占比: {data.get('io_syscall_percent_time', 0):.1f}%",
        fontsize=13, pad=14
    )

    if HAS_MATPLOTLIB:
        save_fig(fig, "io_syscall_pie.png")


# ── 图表 6：内存增长曲线 ──────────────────────────────────────────────────────
def plot_memory_timeline(data: Dict) -> None:
    snapshots = data.get("snapshots", [])
    if not snapshots:
        print("  [INFO] 无 Massif 快照数据，跳过内存曲线图")
        return

    times_ms = [s.get("time_ms", 0) for s in snapshots]
    heap_mb  = [(s.get("heap_bytes", 0) + s.get("heap_extra_bytes", 0)) / 1024 / 1024
                for s in snapshots]

    fig, ax = plt.subplots(figsize=(10, 5))
    ax.fill_between(times_ms, heap_mb, alpha=0.3, color="#3498db")
    ax.plot(times_ms, heap_mb, linewidth=1.5, color="#2980b9", label="堆内存（MB）")

    peak_mb = data.get("peak_heap_mb", max(heap_mb, default=0))
    ax.axhline(peak_mb, color="red", linestyle="--", linewidth=1,
               label=f"峰值: {peak_mb:.2f} MB")

    ax.set_xlabel("时间（ms）", fontsize=12)
    ax.set_ylabel("堆内存使用（MB）", fontsize=12)
    ax.set_title(
        f"afl-fuzz 堆内存随时间增长（Valgrind Massif）\n"
        f"峰值: {peak_mb:.2f} MB  |  快照数: {data.get('snapshot_count', 0)}",
        fontsize=13, pad=14
    )
    ax.legend(fontsize=10)
    ax.grid(linestyle="--", alpha=0.5)
    ax.set_axisbelow(True)

    if HAS_MATPLOTLIB:
        save_fig(fig, "memory_timeline.png")


# ── 文字摘要报告 ──────────────────────────────────────────────────────────────
def write_summary_report(
    fvp_data:    Optional[Dict],
    tvd_data:    Optional[Dict],
    bmp_data:    Optional[Dict],
    mc_data:     Optional[Dict],
    io_data:     Optional[Dict],
    mem_data:    Optional[Dict],
) -> None:
    lines = [
        "=" * 70,
        "AFLplusplus 性能 Profiling 分析报告",
        "=" * 70,
        "",
    ]

    # 1. Fork vs. Persistent
    lines.append("─" * 40)
    lines.append("实验 4：Fork Mode vs. Persistent Mode")
    lines.append("─" * 40)
    if fvp_data:
        lines.append(f"  fork mode     均值 execs/sec : {fvp_data['fork']['execs_per_sec_avg']:>12,.1f}")
        lines.append(f"  persistent    均值 execs/sec : {fvp_data['persistent']['execs_per_sec_avg']:>12,.1f}")
        lines.append(f"  speedup 倍率  (persistent/fork) : {fvp_data['speedup_ratio']:.2f}×")
        lines.append(f"  fork 进程创建开销估算         : {fvp_data.get('fork_overhead_pct', 0):.1f}%")
    else:
        lines.append("  （数据未找到，请先运行 04_fork_vs_persistent.sh）")
    lines.append("")

    # 2. tmpfs vs. 磁盘
    lines.append("─" * 40)
    lines.append("实验 5：tmpfs vs. 磁盘存储性能")
    lines.append("─" * 40)
    if tvd_data:
        lines.append(f"  磁盘  均值 execs/sec : {tvd_data['disk']['execs_per_sec_avg']:>12,.1f}")
        lines.append(f"  tmpfs 均值 execs/sec : {tvd_data['tmpfs']['execs_per_sec_avg']:>12,.1f}")
        lines.append(f"  speedup (tmpfs/disk) : {tvd_data['speedup_ratio']:.3f}×")
        if not tvd_data.get("tmpfs_real_mount"):
            lines.append("  注：本次使用 /dev/shm 代替真实 tmpfs")
    else:
        lines.append("  （数据未找到，请先运行 05_tmpfs_vs_disk.sh）")
    lines.append("")

    # 3. Bitmap 大小
    lines.append("─" * 40)
    lines.append("实验 6：Bitmap 大小对 execs/sec 的影响")
    lines.append("─" * 40)
    if bmp_data:
        for entry in bmp_data["results"]:
            lines.append(
                f"  {entry['map_size_label']:<14} → {entry['execs_per_sec_avg']:>12,.1f} execs/sec"
                f"  | cache-miss: {str(entry.get('cache_miss_info', 'N/A'))[:40]}"
            )
    else:
        lines.append("  （数据未找到，请先运行 06_bitmap_size_comparison.sh）")
    lines.append("")

    # 4. 多核扩展性
    lines.append("─" * 40)
    lines.append("实验 7：多核扩展性")
    lines.append("─" * 40)
    if mc_data:
        lines.append(f"  基线（单核）execs/sec: {mc_data['baseline_eps_single']:>12,.1f}")
        for entry in mc_data["results"]:
            lines.append(
                f"  {entry['fuzzers']:>2} 核 → {entry['execs_per_sec_total']:>12,.1f} execs/sec"
                f"  （扩展效率 {entry['scaling_efficiency_pct']:.1f}%）"
            )
    else:
        lines.append("  （数据未找到，请先运行 07_multicore_scaling.sh）")
    lines.append("")

    # 5. I/O 分析
    lines.append("─" * 40)
    lines.append("实验 3：I/O 系统调用开销")
    lines.append("─" * 40)
    if io_data:
        lines.append(f"  总 I/O 类系统调用耗时占比: {io_data.get('io_syscall_percent_time', 0):.2f}%")
        top5 = sorted(
            io_data.get("syscalls", {}).items(),
            key=lambda x: x[1]["percent_time"], reverse=True
        )[:5]
        for name, info in top5:
            lines.append(
                f"    {name:<20} {info['percent_time']:>6.2f}%  "
                f"calls={info['calls']:>8,}"
            )
    else:
        lines.append("  （数据未找到，请先运行 03_io_profiling.sh）")
    lines.append("")

    # 6. 内存分析
    lines.append("─" * 40)
    lines.append("实验 2：内存分析（Valgrind Massif）")
    lines.append("─" * 40)
    if mem_data:
        lines.append(f"  峰值堆内存 : {mem_data.get('peak_heap_mb', 0):.2f} MB")
        lines.append(f"  快照数量   : {mem_data.get('snapshot_count', 0)}")
    else:
        lines.append("  （数据未找到，请先运行 02_memory_profiling.sh）")
    lines.append("")

    lines.append("=" * 70)
    lines.append("结论与优化建议")
    lines.append("=" * 70)
    lines.append(textwrap.dedent("""
  1. Persistent mode 相对 fork mode 通常有 5–20× 的性能提升，
     对于支持 persistent mode 的目标应优先采用。

  2. 将 AFL++ 输出目录放在 tmpfs（如 /dev/shm）可减少磁盘 I/O 开销，
     对 I/O 密集型目标尤为明显（提升通常在 5–30%）。

  3. Bitmap 大小（AFL_MAP_SIZE）影响 CPU 缓存效率：较小的 bitmap 能
     完全驻留在 L1/L2 缓存，classify_counts 等热点函数更快；
     大 bitmap 增加 cache miss，但覆盖率分辨率更高。

  4. 多核并行扩展效率随核数增加而下降（Amdahl 定律），通常在 4–8
     核时扩展效率仍较好，超过后边际收益递减。

  5. CPU 热点主要集中在 classify_counts、has_new_bits（位图处理）和
     fork server（进程创建），是优化优先级最高的区域。
  """))

    report_text = "\n".join(lines)
    out_path = REPORT_DIR / "summary_report.txt"
    out_path.write_text(report_text, encoding="utf-8")
    print(f"  [报告] 已保存: {out_path}")
    print()
    print(report_text)


# ── 主入口 ────────────────────────────────────────────────────────────────────
def main() -> None:
    print(f"\n[分析] 读取实验结果目录: {RESULTS_DIR}")
    print(f"[分析] 图表输出目录: {REPORT_DIR}\n")

    # 加载各实验 JSON
    fvp_data = load_json(RESULTS_DIR / "fork_vs_persistent" / "results.json")
    tvd_data = load_json(RESULTS_DIR / "tmpfs_vs_disk"       / "results.json")
    bmp_data = load_json(RESULTS_DIR / "bitmap_size"         / "results.json")
    mc_data  = load_json(RESULTS_DIR / "multicore"           / "results.json")
    io_data  = load_json(RESULTS_DIR / "io"                  / "results.json")
    mem_data = load_json(RESULTS_DIR / "memory"              / "results.json")

    if not HAS_MATPLOTLIB:
        print("[WARN] matplotlib 不可用，仅生成文字摘要报告\n")
    else:
        if fvp_data:
            print("[图表 1/6] fork vs. persistent mode 柱状图...")
            plot_fork_vs_persistent(fvp_data)

        if tvd_data:
            print("[图表 2/6] tmpfs vs. 磁盘对比柱状图...")
            plot_tmpfs_vs_disk(tvd_data)

        if bmp_data:
            print("[图表 3/6] bitmap 大小折线图...")
            plot_bitmap_size(bmp_data)

        if mc_data:
            print("[图表 4/6] 多核扩展性折线图...")
            plot_multicore_scaling(mc_data)

        if io_data:
            print("[图表 5/6] I/O 系统调用饼图...")
            plot_io_syscalls(io_data)

        if mem_data:
            print("[图表 6/6] 堆内存增长曲线...")
            plot_memory_timeline(mem_data)

    print("\n[报告] 生成文字摘要报告...")
    write_summary_report(fvp_data, tvd_data, bmp_data, mc_data, io_data, mem_data)

    print(f"\n✓ 分析完成，所有输出已保存至: {REPORT_DIR}")


if __name__ == "__main__":
    main()
