"""面板的视频工具：视频转 GIF（gif）、压缩视频（compress）。

ffmpeg 优先用 imageio-ffmpeg 自带的那份，找不到再用 PATH 里的 ffmpeg。
都输出到源文件同目录；先写临时文件，成功后替换，源视频不改。

gif：一条滤镜链做两遍调色板（palettegen + paletteuse），比直接转 GIF 色彩好、体积小，输出同名 .gif。
compress：x264 按 CRF 画质压缩（与小丸工具箱同一思路），音频转 AAC，输出到源文件夹下“压缩视频\原名.mp4”；
          压缩后不比原文件小时不保留结果。

用法：
  video_tools.py gif --width 0 --fps 12 --log 结果.txt 视频1.mp4 [视频2.mov ...]
  video_tools.py compress --crf 24 --width 0 --log 结果.txt 视频1.mp4 [视频2.mov ...]
  width 为 0 表示保持原宽；比原视频宽时不放大。
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
import traceback


COMPRESS_FOLDER = "压缩视频"


class Skipped(Exception):
    """不算失败、但没有产出（压缩后不比原文件小）。"""


def find_ffmpeg():
    try:
        import imageio_ffmpeg
        path = imageio_ffmpeg.get_ffmpeg_exe()
        if path and os.path.exists(path):
            return path
    except Exception:
        pass
    return shutil.which("ffmpeg")


def gif_filter(width, fps):
    parts = []
    if fps > 0:
        parts.append(f"fps={fps}")
    if width > 0:
        parts.append(f"scale='min({width},iw)':-1:flags=lanczos")
    chain = ",".join(parts)
    prefix = chain + "," if chain else ""
    return (prefix + "split[a][b];[a]palettegen=stats_mode=diff[p];"
            "[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle")


def run_ffmpeg(ffmpeg, source, output, options, container):
    """ffmpeg 写到 output.tmp，成功后换成 output；失败时删掉临时文件并给出 ffmpeg 最后一行报错。"""
    temp = output + ".tmp"
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", source] + options + ["-f", container, temp]
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                            errors="replace", creationflags=flags)
    try:
        if result.returncode != 0 or not os.path.exists(temp) or os.path.getsize(temp) == 0:
            message = (result.stderr or "").strip().splitlines()
            raise RuntimeError(message[-1] if message else f"ffmpeg 退出代码 {result.returncode}")
        return temp
    except Exception:
        if os.path.exists(temp):
            os.remove(temp)
        raise


def replace_output(temp, output):
    """临时文件换成正式文件。目标正被看图软件/播放器/预览窗格打开时改名会被拒绝（WinError 5），
    先重试，再退回直接把内容写进原文件；仍失败就提示关闭占用的程序。临时文件总会被删掉。"""
    try:
        for _ in range(5):
            try:
                os.replace(temp, output)
                return
            except PermissionError:
                time.sleep(0.4)
        try:
            shutil.copyfile(temp, output)
        except PermissionError:
            raise RuntimeError(f"{os.path.basename(output)} 正被其他程序打开（播放器、看图软件或资源管理器预览），请关闭后重试")
    finally:
        if os.path.exists(temp):
            os.remove(temp)


def to_gif(ffmpeg, source, args):
    output = os.path.splitext(source)[0] + ".gif"
    temp = run_ffmpeg(ffmpeg, source, output,
                      ["-filter_complex", gif_filter(args.width, args.fps), "-loop", "0"], "gif")
    replace_output(temp, output)
    return f"{os.path.basename(output)}（{size_text(os.path.getsize(output))}）"


def compress(ffmpeg, source, args):
    # 放进源文件夹下的“压缩视频”子文件夹，文件名不变（扩展名统一为 .mp4）
    folder = os.path.join(os.path.dirname(source), COMPRESS_FOLDER)
    os.makedirs(folder, exist_ok=True)
    output = os.path.join(folder, os.path.splitext(os.path.basename(source))[0] + ".mp4")
    options = ["-map", "0:v:0", "-map", "0:a?", "-c:v", "libx264", "-preset", args.preset,
               "-crf", str(args.crf), "-pix_fmt", "yuv420p"]
    if args.width > 0:
        # 宽高都要是偶数，x264 才能编码；-2 让高度按比例取偶数
        options += ["-vf", f"scale='min({args.width},iw)':-2:flags=lanczos"]
    else:
        options += ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
    options += ["-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
    temp = run_ffmpeg(ffmpeg, source, output, options, "mp4")
    before, after = os.path.getsize(source), os.path.getsize(temp)
    if after >= before:
        os.remove(temp)
        raise Skipped(f"压缩后 {size_text(after)} 不比原文件 {size_text(before)} 小，未保留（原视频已足够小，可调大 CRF 或缩小宽度）")
    replace_output(temp, output)
    return (f"{COMPRESS_FOLDER}\\{os.path.basename(output)}（{size_text(before)} → {size_text(after)}，"
            f"减小 {100 - after * 100 // before}%）")


def size_text(size):
    return f"{size / 1024 / 1024:.1f} MB" if size >= 1024 * 1024 else f"{size / 1024:.0f} KB"


def run_batch(args, action):
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
                lines.append(f"成功  {name} → {action(ffmpeg, source, args)}")
            except Skipped as note:
                lines.append(f"跳过  {name}：{note}")
            except Exception as err:
                failed += 1
                lines.append(f"失败  {name}：{err}")
    with open(args.log, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return 1 if failed else 0


def main():
    try:
        return run()
    except SystemExit:
        raise
    except BaseException:
        # 出任何意外都把完整报错写进日志，面板能显示原因
        log = sys.argv[sys.argv.index("--log") + 1] if "--log" in sys.argv[:-1] else None
        if log:
            with open(log, "w", encoding="utf-8") as f:
                f.write("视频处理出错：\n" + traceback.format_exc())
        raise


def run():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    gif = commands.add_parser("gif")
    gif.add_argument("--width", type=int, default=0)
    gif.add_argument("--fps", type=int, default=12)
    gif.add_argument("--log", required=True)
    gif.add_argument("inputs", nargs="+")
    comp = commands.add_parser("compress")
    comp.add_argument("--crf", type=int, default=24)
    comp.add_argument("--width", type=int, default=0)
    comp.add_argument("--preset", default="medium")
    comp.add_argument("--log", required=True)
    comp.add_argument("inputs", nargs="+")
    args = parser.parse_args()
    return run_batch(args, to_gif if args.command == "gif" else compress)


if __name__ == "__main__":
    sys.exit(main())
