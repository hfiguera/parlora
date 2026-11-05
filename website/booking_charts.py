"""Plot the article's two traces from the same captured café call as its player.

Requires matplotlib, fonttools and brotli; these are publication tooling only.
"""
import argparse
import json
from pathlib import Path
import tempfile

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties
from matplotlib.ticker import FuncFormatter, MultipleLocator
from fontTools.ttLib import TTFont
import numpy as np

from booking_recordings import RATE, ROOT, Recording, sha

PAPER, INK, ACCENT, RULE, SOFT = "#f6f1e8", "#183e36", "#b84226", "#d8cbb7", "#526155"


def chart_fonts(directory):
    fonts = []
    for name in ["dmsans"]:
        font = TTFont(ROOT / f"website/assets/fonts/{name}-latin.woff2")
        font.flavor = None
        target = Path(directory) / (name + ".ttf")
        font.save(target)
        fonts.append(FontProperties(fname=target))
    return fonts


def draw_waveform(axis, raw, lane, start, end, color):
    samples_per_bin = RATE // 10
    samples = np.frombuffer(raw, dtype="<i2").astype(np.float64)
    samples = samples[:len(samples) // samples_per_bin * samples_per_bin].reshape(-1, samples_per_bin)
    rms = np.sqrt(np.mean(samples ** 2, axis=1))
    smoothed = np.convolve(rms, [0.25, 0.5, 0.25], mode="same")
    level = np.minimum(1, smoothed / 3000) * 0.23
    time = (np.arange(len(level)) + 0.5) * samples_per_bin / RATE
    visible = (time >= start - 0.1) & (time <= end + 0.1)
    axis.axhline(lane, color=RULE, linewidth=0.7)
    axis.fill_between(time[visible], lane - level[visible], lane + level[visible],
                      color=color, linewidth=0, zorder=3)


def caption_at(data, speaker, phrase, after=0):
    return next(caption["start"] / 1000 for caption in data["captions"]
                if caption["speaker"] == speaker and caption["start"] / 1000 >= after
                and phrase in caption["text"].lower())


def render(recording, data, output, fonts, mode, metadata_sha):
    body = fonts[0]
    jobs = data["backend_activity"]
    if mode == "lookup":
        old = next(job for job in jobs if job["input"].get("date") == "2026-11-04"
                   and job["operation"] == "availability")
        new = next(job for job in jobs if job["input"].get("date") == "2026-11-05"
                   and job["operation"] == "availability")
        start, end = old["start"] / 1000 - 2, old["filtered_at"] / 1000 + 3
        title = "A new date while the old lookup runs"
        lanes = {"Caller + café": 3.9, "Assistant": 3.1, "Wednesday lookup": 1.9, "Thursday lookup": 1.1}
        tick_seconds = 5
    else:
        job = next(job for job in jobs if job["operation"] == "confirm")
        result = job["result"]["at"] / 1000
        start, end = job["start"] / 1000 - 2.5, result + 6
        title = "A progress reply while booking finishes"
        lanes = {"Caller + café": 3.8, "Assistant": 2.8, "Booking backend": 1.3}
        tick_seconds = 2

    matplotlib.rcParams.update({"svg.fonttype": "path", "svg.hashsalt": "parlora-booking",
                               "figure.facecolor": PAPER, "axes.facecolor": PAPER})
    fig, axis = plt.subplots(figsize=(12.5, 6.944444))
    fig.subplots_adjust(left=0.205, right=0.965, top=0.91, bottom=0.14)
    axis.set(xlim=(start, end), ylim=(0, 5))
    axis.set_yticks(list(lanes.values()), labels=list(lanes))
    axis.xaxis.set_major_locator(MultipleLocator(tick_seconds))
    axis.xaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{int(value) // 60}:{int(value) % 60:02d}"))
    axis.tick_params(axis="both", length=0, pad=12, colors=SOFT)
    for label in axis.get_xticklabels() + axis.get_yticklabels():
        label.set_fontproperties(body)
        label.set_fontsize(15)
    for spine in axis.spines.values():
        spine.set_visible(False)
    axis.spines["bottom"].set_visible(True)
    axis.spines["bottom"].set_color(RULE)
    axis.grid(axis="x", color=RULE, linewidth=0.6)
    axis.set_axisbelow(True)
    axis.set_xlabel("Time into the café GPT Live-1 call", fontproperties=body, fontsize=15,
                    color=SOFT, labelpad=17)

    caller, assistant = lanes["Caller + café"], lanes["Assistant"]
    draw_waveform(axis, recording.caller, caller, start, end, INK)
    draw_waveform(axis, recording.assistant, assistant, start, end, ACCENT)

    def callout(text, at, lane, position, color=INK, align="left"):
        axis.annotate(text, (at, lane), xytext=position, ha=align, va="center", color=color,
                      fontproperties=body, fontsize=13.5, zorder=5,
                      bbox={"facecolor": PAPER, "edgecolor": "none", "pad": 2},
                      arrowprops={"arrowstyle": "-", "color": color, "linewidth": 0.8})

    if mode == "lookup":
        wednesday, thursday = lanes["Wednesday lookup"], lanes["Thursday lookup"]
        replaced = old["replaced_at"] / 1000
        old_end = old["end"] / 1000
        filtered = old["filtered_at"] / 1000
        new_start, new_end = new["start"] / 1000, new["end"] / 1000
        axis.barh(wednesday, replaced - old["start"] / 1000, left=old["start"] / 1000,
                  height=0.20, color=SOFT)
        axis.barh(wednesday, old_end - replaced, left=replaced, height=0.20,
                  color=PAPER, edgecolor=SOFT, linestyle=":", linewidth=1.5)
        axis.barh(thursday, new_end - new_start, left=new_start, height=0.20, color=INK)
        axis.plot(filtered, wednesday, marker="x", markersize=7, color=ACCENT, zorder=4)
        axis.text(old["start"] / 1000 + 0.3, wednesday - 0.29,
                  f'{old["execution_ms"] / 1000:.1f} s total',
                  color=SOFT, fontproperties=body, fontsize=12)
        axis.text((replaced + old_end) / 2, wednesday + 0.33, "Earlier work keeps running",
                  ha="center", color=SOFT, fontproperties=body, fontsize=12)
        callout("“What should I bring\nto the appointment?”",
                caption_at(data, "user", "what should i bring"), caller, (start + 1, 4.65))
        callout("“Thursday instead?”", caption_at(data, "user", "thursday instead"),
                caller, (start + 14, 4.65))
        callout("Assistant answers\nwhile lookup runs",
                caption_at(data, "assistant", "photo id"), assistant, (start + 1, 2.52), ACCENT)
        callout("Old result filtered", filtered, wednesday, (end - 0.15, 2.76), ACCENT, "right")
        callout(f'Thursday returns first · {new["execution_ms"] / 1000:.1f} s',
                new["result"]["at"] / 1000, thursday, (new_end + 0.6, 0.43))
    else:
        booking = lanes["Booking backend"]
        question = caption_at(data, "user", "is it booked yet?")
        progress = caption_at(data, "assistant", "still processing", after=question)
        spoken_confirmation = caption_at(data, "assistant", "you're booked", after=result)
        if not job["start"] / 1000 <= question < progress < result <= spoken_confirmation < end:
            raise ValueError("Booking callouts do not match the recorded booking sequence")
        booking_start, booking_end = job["start"] / 1000, job["end"] / 1000
        axis.barh(booking, booking_end - booking_start, left=booking_start, height=0.27, color=INK)
        axis.vlines(result, 0, caller, color=SOFT, linewidth=0.8, linestyle=":")
        axis.text(booking_start + 0.16, booking - 0.34,
                  f'{job["execution_ms"] / 1000:.1f} s',
                  color=SOFT, fontproperties=body, fontsize=12)
        callout("“Is it booked yet?”", question, caller, (start + 0.45, 4.62))
        callout("“It’s still processing.”", progress, assistant, (start + 0.45, 2.13), ACCENT)
        callout("Backend confirms", result, booking, (result + 0.45, 0.55))
        callout("“You’re booked…”", spoken_confirmation, assistant, (end - 0.2, 3.48),
                ACCENT, "right")

    source = json.dumps({"recording": "assets/booking/openai.json", "recording_sha256": metadata_sha,
                         "report_sha256": sha(recording.report_bytes), "input_pcm_sha256": sha(recording.caller),
                         "output_pcm_sha256": sha(recording.assistant), "window_seconds": [start, end]}, sort_keys=True)
    fig.savefig(output, format="svg", metadata={"Date": None, "Title": title, "Description": source})
    output = Path(output)
    output.write_text("\n".join(line.rstrip() for line in output.read_text().splitlines()) + "\n")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--metadata", type=Path, default=ROOT / "website/assets/booking/openai.json")
    parser.add_argument("--output", type=Path, default=ROOT / "website/assets/booking")
    args = parser.parse_args()
    recording = Recording(args.directory)
    data = json.loads(args.metadata.read_text())
    source = data["caption_source"]
    if (source["report_sha256"] != sha(recording.report_bytes)
            or source["pcm_sha256"] != {"input": sha(recording.caller), "output": sha(recording.assistant)}):
        raise ValueError("Graphs and player refer to different calls")
    with tempfile.TemporaryDirectory() as temporary:
        fonts = chart_fonts(temporary)
        metadata_sha = sha(args.metadata.read_bytes())
        render(recording, data, args.output / "lookup-correction.svg", fonts, "lookup", metadata_sha)
        render(recording, data, args.output / "booking-progress.svg", fonts, "booking", metadata_sha)
    print("Updated both graphs from", args.directory)


if __name__ == "__main__":
    main()
