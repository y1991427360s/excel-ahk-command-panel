"""面板的 HTML 转 PDF：用本机 Edge（Chromium）打印网页，输出到源文件同目录同名 .pdf。

优先用 Playwright 驱动已安装的 Edge（channel="msedge"，不下载浏览器）：A4、打印背景色、页面自带
@page 尺寸时以页面为准，等网络空闲后再打印，让脚本画的图表也能出来。
没有 Playwright 时退回 msedge --headless --print-to-pdf（纸张为浏览器默认的 Letter）。

用法：
  html_to_pdf.py --report 结果.txt 页面1.html 页面2.htm ...
结果文件每行：OK<TAB>源文件<TAB>输出PDF  或  FAIL<TAB>源文件<TAB>原因。全部成功退出 0，否则 1。
每个 PDF 先写临时文件，成功后再替换目标；源文件不修改。
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

EDGE_CANDIDATES = [
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
]
SCRIPT_WAIT_MS = 1500   # 网络空闲后再等一会儿，给 setTimeout / 动画类图表留时间
PAGE_TIMEOUT_MS = 60000


def output_path(source):
    return os.path.splitext(source)[0] + ".pdf"


def temp_path(target):
    return f"{target}.tmp-{os.getpid()}.pdf"


def convert_with_playwright(sources, results):
    from playwright.sync_api import sync_playwright

    with sync_playwright() as pw:
        browser = pw.chromium.launch(channel="msedge", headless=True)
        try:
            page = browser.new_page()
            for source in sources:
                target = output_path(source)
                temp = temp_path(target)
                try:
                    page.goto(Path(source).resolve().as_uri(), wait_until="networkidle", timeout=PAGE_TIMEOUT_MS)
                    page.wait_for_timeout(SCRIPT_WAIT_MS)
                    page.emulate_media(media="print")
                    page.pdf(path=temp, format="A4", print_background=True, prefer_css_page_size=True,
                             margin={"top": "10mm", "bottom": "10mm", "left": "10mm", "right": "10mm"})
                    os.replace(temp, target)
                    results.append(("OK", source, target))
                except Exception as exc:
                    if os.path.exists(temp):
                        os.remove(temp)
                    results.append(("FAIL", source, str(exc).splitlines()[0]))
        finally:
            browser.close()


def find_edge():
    for path in EDGE_CANDIDATES:
        if os.path.isfile(path):
            return path
    return shutil.which("msedge")


def convert_with_edge_cli(sources, results):
    edge = find_edge()
    if not edge:
        raise RuntimeError("找不到 Microsoft Edge（msedge.exe）。")
    profile = tempfile.mkdtemp(prefix="html-to-pdf-edge-")  # 独立配置目录，不交给正在运行的 Edge
    try:
        for source in sources:
            target = output_path(source)
            temp = temp_path(target)
            cmd = [edge, "--headless", "--disable-gpu", "--no-pdf-header-footer",
                   "--run-all-compositor-stages-before-draw", "--virtual-time-budget=10000",
                   "--no-first-run", "--no-default-browser-check", "--disable-extensions",
                   f"--user-data-dir={profile}", f"--print-to-pdf={temp}", os.path.abspath(source)]
            subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            # 页面加载失败时 Edge 的退出码仍是 0，只能以是否生成 PDF 判断
            if os.path.isfile(temp) and os.path.getsize(temp) > 0:
                os.replace(temp, target)
                results.append(("OK", source, target))
            else:
                if os.path.exists(temp):
                    os.remove(temp)
                results.append(("FAIL", source, "Edge 未生成 PDF（页面无法打开或加载失败）"))
    finally:
        shutil.rmtree(profile, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True)
    parser.add_argument("sources", nargs="+")
    args = parser.parse_args()
    args.sources = [os.path.abspath(source) for source in args.sources]  # Edge 的工作目录不是这里

    results = []
    try:
        try:
            import playwright  # noqa: F401
            convert_with_playwright(args.sources, results)
        except ImportError:
            convert_with_edge_cli(args.sources, results)
    except Exception as exc:
        done = {item[1] for item in results}
        for source in args.sources:
            if source not in done:
                results.append(("FAIL", source, str(exc).splitlines()[0] if str(exc) else type(exc).__name__))

    with open(args.report, "w", encoding="utf-8") as handle:
        handle.write("\n".join("\t".join(item) for item in results))
    return 0 if results and all(item[0] == "OK" for item in results) else 1


if __name__ == "__main__":
    sys.exit(main())
