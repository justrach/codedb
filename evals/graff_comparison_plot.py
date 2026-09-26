#!/usr/bin/env python3
"""Render the portable study receipt (requires matplotlib)."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager


def plot(receipt_path, output, font_directory):
    font_cache = tempfile.TemporaryDirectory(prefix="graff-chart-fonts-")
    source_fonts, font_files = [], []
    for weight in ("Regular", "Bold"):
        source = next((font_directory / f"Gramatika-{weight}.{ext}" for ext in ("ttf", "woff2")
                       if (font_directory / f"Gramatika-{weight}.{ext}").is_file()), None)
        if source is None:
            raise FileNotFoundError("Provide --font-dir containing Gramatika Regular and Bold in TTF or WOFF2 format")
        source_fonts.append(source)
        path = source
        # Some installed .ttf files actually contain WOFF2 bytes. Decompress
        # into a temporary rendering file without redistributing font files.
        if source.read_bytes()[:4] in (b"wOF2", b"wOFF"):
            from fontTools.ttLib import TTFont
            path = Path(font_cache.name) / f"Gramatika-{weight}.ttf"
            font = TTFont(source, recalcTimestamp=False)
            font.flavor = None
            font.save(path)
        font_files.append(path)
        font_manager.fontManager.addfont(str(path))
    font_family = font_manager.FontProperties(fname=str(font_files[0])).get_name()
    receipt = json.loads(receipt_path.read_text())
    rows = receipt["records"]
    arms = ("baseline", "codedb", "graphify")
    families = list(dict.fromkeys(r["family"] for r in rows))
    colors = {"baseline": "#827B72", "codedb": "#2851E4", "graphify": "#C4432A"}
    names = {"baseline": "Workspace-only", "codedb": "CodeDB", "graphify": "Graphify"}
    plt.rcParams.update({"font.family": font_family, "font.size": 11, "svg.fonttype": "path", "svg.hashsalt": "graff-study-v3"})
    for weight, path in zip(("normal", "bold"), font_files):
        selected = font_manager.findfont(font_manager.FontProperties(family=font_family, weight=weight), fallback_to_default=False)
        if Path(selected).resolve() != path.resolve():
            raise ValueError(f"Unexpected font selected for {weight}: {selected}")
    fig, axes = plt.subplots(1, 2, figsize=(13, 8.8), sharey=True)
    fig.patch.set_facecolor("#FAF4E9")
    for ax, metric, divisor, title in zip(
        axes, ("total_tokens", "api_equivalent_usd"), (1000, 1),
        ("Model tokens · thousands", "Model API equivalent · USD"),
    ):
        ax.set_facecolor("#FAF4E9")
        for offset, arm in enumerate(arms):
            values = []
            for family in families:
                values.append(sum(r["usage"][metric] for r in rows if r["family"] == family and r["arm"] == arm) / divisor)
            ax.barh([i + (offset - 1) * 0.23 for i in range(len(families))], values,
                    height=0.20, color=colors[arm], label=names[arm], zorder=3)
        ax.set_title(title, loc="left", pad=18, weight="bold")
        ax.grid(axis="x", color="#DED5C5", zorder=0)
        ax.spines[["top", "right", "left", "bottom"]].set_visible(False)
        ax.tick_params(axis="both", length=0, pad=8)
        ax.set_yticks(range(len(families)), families)
        ax.set_xlim(left=0)
    axes[0].invert_yaxis()
    fig.suptitle("CodeDB, Graphify and workspace-only Graff", x=0.06, y=0.975,
                 ha="left", fontsize=22, weight="bold", color="#201B16")
    fig.text(0.06, 0.912, "48 attempts · 8 small Python task families · Grok 4.6 · two repeats per arm", fontsize=12)
    handles, labels = axes[0].get_legend_handles_labels()
    labels = [f"{label} ({receipt['totals'][arm]['passed']}/16 strict passes)" for label, arm in zip(labels, arms)]
    fig.legend(handles, labels, loc="upper left", bbox_to_anchor=(0.052, 0.876), ncol=3, frameon=False)
    fig.text(0.06, 0.07, "Each bar sums both attempts, including failures. API equivalents are estimates; subscription model charges were $0.", fontsize=10)
    fig.text(0.06, 0.042, "Graphify's JSON-stream failures depend on an underspecified whitespace-only check. This is a diagnostic study, not a ranking.", fontsize=10)
    fig.text(0.06, 0.017, "Retrieval was available in both retrieval arms; Graphify was used in 14/16 attempts and CodeDB in 16/16.", fontsize=10)
    fig.subplots_adjust(left=0.20, right=0.97, top=0.78, bottom=0.13, wspace=0.17)
    output.mkdir(parents=True, exist_ok=True)
    for extension in ("svg", "png"):
        fig.savefig(output / ("graff-retrieval-study." + extension), dpi=180, facecolor=fig.get_facecolor(),
                    metadata={"Date": None} if extension == "svg" else None)
    svg = output / "graff-retrieval-study.svg"
    svg.write_text("\n".join(line.rstrip() for line in svg.read_text().splitlines()) + "\n")
    plt.close(fig)
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()
    (output / "render.json").write_text(json.dumps({
        "font_family": font_family, "font_hashes": {p.name: sha(p) for p in source_fonts},
        "matplotlib": matplotlib.__version__, "receipt_sha256": sha(receipt_path),
        "plot_script_sha256": sha(Path(__file__)),
        "svg_text": "glyph outlines; viewing does not require installing the font",
        "artifacts": {"graff-retrieval-study." + ext: sha(output / ("graff-retrieval-study." + ext)) for ext in ("svg", "png")},
    }, indent=2) + "\n")
    font_cache.cleanup()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("--font-dir", type=Path, default=Path.home() / "Library/Fonts")
    args = parser.parse_args()
    plot(args.receipt, args.output_directory, args.font_dir)
