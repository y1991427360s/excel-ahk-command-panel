"""统计 PDF 图纸图幅（面板“统计图幅”按钮调用）。

输入可以是 PDF、文件夹或压缩包（rar / zip / 7z），逐页读取页面尺寸：
短边决定基本图幅（A4/A3/A2/A1/A0），长边 ÷ 基本图幅长边 得到加长倍数，按 0.25 取整，
例如 297×841 → A3*2、594×1051 → A1*1.25。列顺序与《图纸打印明细》表头一致。

用法：python drawing_sheet_sizes.py --report 报告.txt --row 表格行.txt 路径1 [路径2 ...]
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

from pypdf import PdfReader

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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True)
    parser.add_argument("--row", required=True)
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()

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


if __name__ == "__main__":
    sys.exit(main())
