"""面板的视频工具：视频转 GIF（gif）。

ffmpeg 优先用 imageio-ffmpeg 自带的那份，找不到再用 PATH 里的 ffmpeg。
转换用一条滤镜链做两遍调色板（palettegen + paletteuse），比直接转 GIF 色彩好、体积小。
输出到源文件同目录、同名 .gif；先写临时文件，成功后替换，源视频不改。

用法：
  video_tools.py gif --width 800 --fps 12 --log 结果.txt 视频1.mp4 [视频2.mov ...]
  width 为 0 表示保持原宽；比原视频宽时不放大。
"""
import argparse
import os
import shutil
import subprocess
import sys


def find_ffmpeg():
    try:
        import imageio_ffmpeg
        path = imageio_ffmpeg.get_ffmpeg_exe()
        if path and os.path.exists(path):
            return path
    except Exception:
        pass
    return shutil.which("ffmpeg")


def build_filter(width, fps):
    parts = []
    if fps > 0:
        parts.append(f"fps={fps}")
    if width > 0:
        parts.append(f"scale='min({width},iw)':-1:flags=lanczos")
    chain = ",".join(parts)
    prefix = chain + "," if chain else ""
    return (prefix + "split[a][b];[a]palettegen=stats_mode=diff[p];"
            "[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle")


def convert(ffmpeg, source, width, fps):
    base, _ = os.path.splitext(source)
    output = base + ".gif"
    temp = output + ".tmp"
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", source,
           "-filter_complex", build_filter(width, fps), "-loop", "0", "-f", "gif", temp]
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                            errors="replace", creationflags=flags)
    if result.returncode != 0 or not os.path.exists(temp) or os.path.getsize(temp) == 0:
        if os.path.exists(temp):
            os.remove(temp)
        message = (result.stderr or "").strip().splitlines()
        raise RuntimeError(message[-1] if message else f"ffmpeg 退出代码 {result.returncode}")
    os.replace(temp, output)
    return output


def size_text(path):
    size = os.path.getsize(path)
    return f"{size / 1024 / 1024:.1f} MB" if size >= 1024 * 1024 else f"{size / 1024:.0f} KB"


def run_gif(args):
    lines = []
    failed = 0
    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        lines.append("找不到 ffmpeg。请执行 pip install imageio-ffmpeg，或把 ffmpeg 加入 PATH。")
        failed = len(args.inputs)
    else:
        for source in args.inputs:
            name = os.path.basename(source)
            try:
                output = convert(ffmpeg, source, args.width, args.fps)
                lines.append(f"成功  {name} → {os.path.basename(output)}（{size_text(output)}）")
            except Exception as err:
                failed += 1
                lines.append(f"失败  {name}：{err}")
    with open(args.log, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    gif = commands.add_parser("gif")
    gif.add_argument("--width", type=int, default=800)
    gif.add_argument("--fps", type=int, default=12)
    gif.add_argument("--log", required=True)
    gif.add_argument("inputs", nargs="+")
    args = parser.parse_args()
    return run_gif(args)


if __name__ == "__main__":
    sys.exit(main())
