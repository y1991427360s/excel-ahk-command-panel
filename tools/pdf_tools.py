"""面板的 PDF 工具：统计图幅（sizes）和合并 PDF（merge）。

主面板用系统 python 运行本脚本；分享版把它用 PyInstaller 打成 pdf-tools.exe，朋友电脑不需要装 Python。

统计图幅：输入可以是 PDF、文件夹或压缩包（rar / zip / 7z），逐页读取页面尺寸：
短边决定基本图幅（A4/A3/A2/A1/A0），长边 ÷ 基本图幅长边 得到加长倍数，按 0.25 取整，
例如 297×841 → A3*2、594×1051 → A1*1.25。列顺序与《图纸打印明细》表头一致。

用法：
  pdf_tools.py sizes --report 报告.txt --row 表格行.txt 路径1 [路径2 ...]
  pdf_tools.py merge 输出.pdf 输入1.pdf 输入2.pdf ...   （先写临时文件，成功后替换输出）
  pdf_tools.py images 输出.pdf 图1.png 图2.jpg ...      （每张图一页 A4，横图横版，无损嵌入）
"""
import argparse
import io
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from collections import Counter, OrderedDict

from pypdf import PdfReader, PdfWriter

MM_PER_PT = 25.4 / 72

# 基本图幅：名称 → (短边, 长边) mm
BASE_SIZES = OrderedDict([
    ("A0", (841, 1189)),
    ("A1", (594, 841)),
    ("A2", (420, 594)),
    ("A3", (297, 420)),
    ("A4", (210, 297)),
])

# 《图纸打印明细》表头里的图幅列（F~AB 共 23 列）
TABLE_COLUMNS = [
    "A0", "A0*1.25", "A0*1.5", "A0*1.75", "A0*2",
    "A1", "A1*1.25", "A1*1.5", "A1*1.75", "A1*2",
    "A2", "A2*1.25", "A2*1.5", "A2*1.75", "A2*2",
    "A3", "A3*1.25", "A3*1.5", "A3*1.75", "A3*2", "A3*2.5", "A3*2.75",
    "A4",
]

SHORT_TOLERANCE = 8   # 短边允许偏差 mm（打印 PDF 常见 299×422 之类）
LONG_TOLERANCE = 10   # 长边与倍数尺寸允许偏差 mm

ARCHIVE_EXTS = {".rar", ".zip", ".7z"}


def classify(width_mm, height_mm):
    short, long_ = sorted((width_mm, height_mm))
    for name, (base_short, base_long) in BASE_SIZES.items():
        if abs(short - base_short) > SHORT_TOLERANCE:
            continue
        factor = round(long_ / base_long * 4) / 4
        if factor >= 1 and abs(long_ - base_long * factor) <= LONG_TOLERANCE:
            return name if factor == 1 else f"{name}*{factor:g}"
    return f"非标 {round(short)}×{round(long_)}mm"


def page_size_mm(page):
    box = page.mediabox
    unit = float(page.get("/UserUnit", 1) or 1)
    return float(box.width) * unit * MM_PER_PT, float(box.height) * unit * MM_PER_PT


def count_pdf(source, label, results, errors):
    try:
        reader = PdfReader(source)
        counter = Counter()
        for page in reader.pages:
            counter[classify(*page_size_mm(page))] += 1
        results.append((label, counter))
    except Exception as exc:  # 损坏或加密的 PDF 记下来，不中断整体统计
        errors.append(f"{label}：{exc}")


def find_tool(names):
    candidates = []
    for name in names:
        found = shutil.which(name)
        if found:
            candidates.append(found)
    for base in (os.environ.get("ProgramFiles", r"C:\Program Files"),
                 os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
                 "D:\\", "D:\\Program Files"):
        candidates += [os.path.join(base, "WinRAR", "UnRAR.exe"),
                       os.path.join(base, "7-Zip", "7z.exe")]
    for path in candidates:
        if path and os.path.isfile(path) and os.path.basename(path).lower().split(".")[0] in [n.lower() for n in names]:
            return path
    return None


def extract_archive(archive, target_dir):
    ext = os.path.splitext(archive)[1].lower()
    if ext == ".rar":
        unrar = find_tool(["UnRAR"])
        if unrar:
            cmd = [unrar, "x", "-y", "-inul", archive, "*.pdf", target_dir + os.sep]
        else:
            cmd = None
    else:
        cmd = None
    if cmd is None:
        seven = find_tool(["7z"])
        if seven:
            cmd = [seven, "x", "-y", "-bso0", "-bsp0", f"-o{target_dir}", archive, "*.pdf", "-r"]
        else:
            tar = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "tar.exe")
            cmd = [tar, "-xf", archive, "-C", target_dir]
    completed = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    # UnRAR 在“没有匹配文件”时返回 10，不算失败
    if completed.returncode not in (0, 10):
        message = completed.stderr.decode("gbk", "replace").strip()
        raise RuntimeError(f"解压失败（{os.path.basename(cmd[0])} 退出代码 {completed.returncode}）{message}")


def walk_pdfs(folder):
    found = []
    for root, _dirs, files in os.walk(folder):
        for name in files:
            if name.lower().endswith(".pdf"):
                found.append(os.path.join(root, name))
    return sorted(found, key=lambda p: os.path.relpath(p, folder).lower())


def zip_member_name(info):
    if info.flag_bits & 0x800:
        return info.filename
    try:  # 无 UTF-8 标记的中文 zip 一般是 GBK
        return info.filename.encode("cp437").decode("gbk")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return info.filename


def process_source(path, results, errors, temp_dirs):
    base_name = os.path.basename(path.rstrip("\\/"))
    if os.path.isdir(path):
        for pdf in walk_pdfs(path):
            count_pdf(pdf, os.path.join(base_name, os.path.relpath(pdf, path)), results, errors)
        return
    ext = os.path.splitext(path)[1].lower()
    if ext == ".pdf":
        count_pdf(path, base_name, results, errors)
    elif ext == ".zip":
        with zipfile.ZipFile(path) as archive:
            infos = sorted((i for i in archive.infolist() if not i.is_dir()
                            and i.filename.lower().endswith(".pdf")), key=zip_member_name)
            for info in infos:
                count_pdf(io.BytesIO(archive.read(info)), f"{base_name} › {zip_member_name(info)}", results, errors)
    elif ext in ARCHIVE_EXTS:
        temp_dir = tempfile.mkdtemp(prefix="sheet-size-")
        temp_dirs.append(temp_dir)
        extract_archive(path, temp_dir)
        for pdf in walk_pdfs(temp_dir):
            count_pdf(pdf, f"{base_name} › {os.path.relpath(pdf, temp_dir)}", results, errors)


def sort_key(size_name):
    if size_name in TABLE_COLUMNS:
        return (0, TABLE_COLUMNS.index(size_name), "")
    if size_name.startswith("A"):
        base = size_name.split("*")[0]
        order = list(BASE_SIZES).index(base) if base in BASE_SIZES else 9
        return (1, order, size_name)
    return (2, 0, size_name)


def format_counter(counter):
    return "、".join(f"{name} ×{counter[name]}" for name in sorted(counter, key=sort_key))


def run_sizes(args):

    results, errors, temp_dirs = [], [], []
    try:
        for path in args.paths:
            try:
                process_source(path, results, errors, temp_dirs)
            except Exception as exc:
                errors.append(f"{os.path.basename(path)}：{exc}")
    finally:
        for folder in temp_dirs:
            shutil.rmtree(folder, ignore_errors=True)

    total = Counter()
    for _label, counter in results:
        total.update(counter)
    pages = sum(total.values())

    lines = []
    if not results:
        lines.append("没有找到可统计的 PDF。")
    else:
        lines.append(f"共 {len(results)} 个 PDF、{pages} 张图纸：")
        lines.append("")
        for name in sorted(total, key=sort_key):
            lines.append(f"  {name}：{total[name]} 张")
        extra = [name for name in total if name not in TABLE_COLUMNS]
        if extra:
            lines.append("")
            lines.append("以下图幅不在打印明细表的列中，需手工填写“补充尺寸”：" + "、".join(sorted(extra, key=sort_key)))
        lines.append("")
        lines.append("各文件明细：")
        for label, counter in results:
            lines.append(f"  {label}（{sum(counter.values())} 张）：{format_counter(counter)}")
    if errors:
        lines.append("")
        lines.append("无法读取：")
        lines.extend(f"  {message}" for message in errors)

    with open(args.report, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
    with open(args.row, "w", encoding="utf-8") as handle:
        handle.write("\t".join(str(total[name]) if total[name] else "" for name in TABLE_COLUMNS))
    return 0 if results else 2


def run_merge(args):
    output = os.path.abspath(args.output)
    temp_output = f"{output}.tmp-{os.getpid()}"
    writer = PdfWriter()
    try:
        for path in args.inputs:
            writer.append(path)
        with open(temp_output, "wb") as handle:
            writer.write(handle)
    except Exception:
        if os.path.exists(temp_output):
            os.remove(temp_output)
        raise
    finally:
        writer.close()
    os.replace(temp_output, output)
    return 0


A4_PT = (595.276, 841.89)
IMAGE_MARGIN_PT = 10 / MM_PER_PT   # 四周留白 10mm
MIN_IMAGE_DPI = 96                  # 小图最多放大到 96dpi，避免截图被拉糊


def png_idat_stream(image):
    """把图片存成 PNG，取出 IDAT 数据：本身就是带 PNG 预测器的 zlib 流，可原样放进 PDF（无损、不重新压缩）。"""
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", compress_level=6)
    data = buffer.getvalue()
    pos, idat = 8, []
    while pos < len(data):
        length = int.from_bytes(data[pos:pos + 4], "big")
        kind = data[pos + 4:pos + 8]
        if kind == b"IDAT":
            idat.append(data[pos + 8:pos + 8 + length])
        pos += 12 + length
    return b"".join(idat)


def load_image_object(path):
    """返回 (PDF 图像字典, 数据流, 宽像素, 高像素)。JPEG 原样嵌入，其余转 PNG 流无损嵌入；透明背景铺白。"""
    from PIL import Image, ImageOps

    with Image.open(path) as source:
        source.seek(0)  # 多帧 GIF/TIFF 只取第一帧
        image = ImageOps.exif_transpose(source)
        width, height = image.size
        upright = source.getexif().get(0x0112, 1) == 1  # 无 EXIF 旋转标记才能原样嵌入
        if source.format == "JPEG" and source.mode in ("RGB", "L") and upright:
            with open(path, "rb") as handle:
                stream = handle.read()
            colors = 3 if source.mode == "RGB" else 1
            space = "/DeviceRGB" if colors == 3 else "/DeviceGray"
            return f"/ColorSpace {space} /BitsPerComponent 8 /Filter /DCTDecode", stream, width, height
        if image.mode in ("RGBA", "LA", "PA") or (image.mode == "P" and "transparency" in image.info):
            rgba = image.convert("RGBA")
            image = Image.new("RGB", rgba.size, "white")
            image.paste(rgba, mask=rgba.getchannel("A"))
        elif image.mode not in ("RGB", "L"):
            image = image.convert("L" if image.mode in ("1", "I", "I;16", "F") else "RGB")
        colors = 3 if image.mode == "RGB" else 1
        space = "/DeviceRGB" if colors == 3 else "/DeviceGray"
        stream = png_idat_stream(image)
        info = (f"/ColorSpace {space} /BitsPerComponent 8 /Filter /FlateDecode "
                f"/DecodeParms << /Predictor 15 /Colors {colors} /BitsPerComponent 8 /Columns {width} >>")
        return info, stream, width, height


def image_page_layout(width_px, height_px):
    """A4 页面，横图用横版；图片等比缩放进 10mm 边距内并居中。返回 (页宽, 页高, x, y, 绘制宽, 绘制高) pt。"""
    page_w, page_h = A4_PT if height_px >= width_px else (A4_PT[1], A4_PT[0])
    box_w, box_h = page_w - 2 * IMAGE_MARGIN_PT, page_h - 2 * IMAGE_MARGIN_PT
    scale = min(box_w / width_px, box_h / height_px, 72 / MIN_IMAGE_DPI)
    draw_w, draw_h = width_px * scale, height_px * scale
    return page_w, page_h, (page_w - draw_w) / 2, (page_h - draw_h) / 2, draw_w, draw_h


def run_images(args):
    """每张图片一页拼成 PDF。先写临时文件，成功后替换输出。"""
    objects = []  # 下标 i 对应对象号 i+3（1 为 Catalog，2 为 Pages）
    page_ids = []
    for path in args.inputs:
        info, stream, width, height = load_image_object(path)
        page_w, page_h, x, y, draw_w, draw_h = image_page_layout(width, height)
        image_id = len(objects) + 3
        objects.append(f"<< /Type /XObject /Subtype /Image /Width {width} /Height {height} {info} "
                       f"/Length {len(stream)} >>".encode("ascii") + b"\nstream\n" + stream + b"\nendstream")
        content = f"q {draw_w:.3f} 0 0 {draw_h:.3f} {x:.3f} {y:.3f} cm /Im0 Do Q".encode("ascii")
        objects.append(f"<< /Length {len(content)} >>".encode("ascii") + b"\nstream\n" + content + b"\nendstream")
        page_ids.append(len(objects) + 3)
        objects.append((f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {page_w:.3f} {page_h:.3f}] "
                        f"/Resources << /XObject << /Im0 {image_id} 0 R >> >> /Contents {image_id + 1} 0 R >>").encode("ascii"))

    kids = " ".join(f"{pid} 0 R" for pid in page_ids)
    all_objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
                   f"<< /Type /Pages /Kids [{kids}] /Count {len(page_ids)} >>".encode("ascii")] + objects

    output = os.path.abspath(args.output)
    temp_output = f"{output}.tmp-{os.getpid()}"
    try:
        with open(temp_output, "wb") as handle:
            handle.write(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
            offsets = []
            for number, body in enumerate(all_objects, start=1):
                offsets.append(handle.tell())
                handle.write(f"{number} 0 obj\n".encode("ascii") + body + b"\nendobj\n")
            xref = handle.tell()
            handle.write(f"xref\n0 {len(all_objects) + 1}\n0000000000 65535 f \n".encode("ascii"))
            for offset in offsets:
                handle.write(f"{offset:010d} 00000 n \n".encode("ascii"))
            handle.write(f"trailer\n<< /Size {len(all_objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii"))
    except Exception:
        if os.path.exists(temp_output):
            os.remove(temp_output)
        raise
    os.replace(temp_output, output)
    return 0


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    sizes = commands.add_parser("sizes")
    sizes.add_argument("--report", required=True)
    sizes.add_argument("--row", required=True)
    sizes.add_argument("paths", nargs="+")
    merge = commands.add_parser("merge")
    merge.add_argument("output")
    merge.add_argument("inputs", nargs="+")
    images = commands.add_parser("images")
    images.add_argument("output")
    images.add_argument("inputs", nargs="+")
    args = parser.parse_args()
    handlers = {"sizes": run_sizes, "merge": run_merge, "images": run_images}
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
