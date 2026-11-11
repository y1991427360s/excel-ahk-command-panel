"""从生产源码提取通用功能，生成自带运行环境的朋友分享包（自动化工具面板）。

默认输出到桌面，并且桌面上只保留最新的一个分享包：新包构建成功后，
旧的“自动化工具面板-*.zip”（以及改名前的“表格工具面板-*.zip”）移到回收站。
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from datetime import datetime

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
PACKAGE_PREFIX = '自动化工具面板-'
OLD_PACKAGE_PREFIXES = (PACKAGE_PREFIX, '表格工具面板-')
FUNCTION_PATTERN = re.compile(r'^(\w+)\([^\n]*\) \{\n.*?^\}', re.M | re.S)


def default_output():
    try:
        import ctypes
        buffer = ctypes.create_unicode_buffer(260)
        if ctypes.windll.shell32.SHGetFolderPathW(None, 0x0010, None, 0, buffer) == 0:  # CSIDL_DESKTOPDIRECTORY
            return Path(buffer.value)
    except Exception:
        pass
    return Path.home() / 'Desktop'


def build_panel_script():
    functions = {}
    for source in (PROJECT / 'src').glob('*.ahk'):
        if source.name.endswith('-main.ahk'):  # 独立运行入口，与主面板有同名函数
            continue
        for match in FUNCTION_PATTERN.finditer(source.read_text(encoding='utf-8-sig')):
            if match[1] in functions:
                raise ValueError('Duplicate function: ' + match[1])
            functions[match[1]] = match[0]
    original = (PROJECT / 'src/excel-command-panel.ahk').read_text(encoding='utf-8-sig')
    body = (HERE / 'share-panel.ahk').read_text(encoding='utf-8-sig')
    # share-panel.ahk 里定义的同名函数（如 PdfToolCommand）覆盖生产源码里的版本
    for match in FUNCTION_PATTERN.finditer(body):
        functions.pop(match[1], None)
    buttons = original.split('    ; @@SPREADSHEET_BUTTONS_BEGIN\n', 1)[1].split('    ; @@SPREADSHEET_BUTTONS_END', 1)[0]
    body = body.replace('; @SPREADSHEET_BUTTONS@', buttons)
    used = set()
    pending = body
    while True:
        found = (set(re.findall(r'\b\w+\b', pending)) & functions.keys()) - used
        if not found:
            break
        used |= found
        pending = '\n'.join(functions[name] for name in sorted(found))
    script = body + '\n\n' + '\n\n'.join(code for name, code in functions.items() if name in used) + '\n'
    # 分享版不能带上本机路径、LISP 插件、系统 Python 或 AI 依赖；PDF 功能改用包内 pdf-tools.exe。
    # 电缆定义总览（cad-cable-panel.ahk）只读 DDFD 插件写的总览文件，朋友自己装有插件，所以随包带上；
    # 它顶部的全局变量不在函数里提取不到，share-panel.ahk 里抄了一份，这里核对没有走样。
    cable_source = (PROJECT / 'src/cad-cable-panel.ahk').read_text(encoding='utf-8-sig').replace('\r\n', '\n')
    cable_globals = cable_source[cable_source.index('global CablePanelPath'):]
    cable_globals = cable_globals[:cable_globals.index('\n\n')]
    if cable_globals not in body.replace('\r\n', '\n'):
        raise ValueError('share-panel.ahk 里的 CablePanel 全局变量与 src/cad-cable-panel.ahk 不一致')
    for forbidden in ('CopyQ', 'Syncthing', 'Oracle-Sync', 'ys199', 'AA整合版本', 'D:\\', 'python', 'pypdf',
                      'OpenSelectedDwg', 'RunZwcadCommand', 'ReloadCadAaLsp', 'CadAi', 'GetProjectAtlas',
                      'TrustedDwg'):
        if forbidden.lower() in script.lower():
            raise ValueError('Unexpected personal/file-tool dependency: ' + forbidden)
    return script, len(used)


def build_pdf_tools(payload, work):
    """把 tools/pdf_tools.py 打成单文件 pdf-tools.exe，朋友电脑不需要装 Python。"""
    # 合并和读页面尺寸用不到图片、加密和科学计算库，排除后 exe 从约 40MB 降到十几 MB
    excludes = ['PIL', 'numpy', 'cryptography', 'Crypto', 'tkinter', 'pandas', 'matplotlib', 'scipy', 'lxml', 'IPython']
    subprocess.run([sys.executable, '-m', 'PyInstaller', '--onefile', '--noconsole', '--clean', '--noconfirm',
                    *[arg for name in excludes for arg in ('--exclude-module', name)],
                    '--name', 'pdf-tools', '--distpath', str(work / 'dist'), '--workpath', str(work / 'build'),
                    '--specpath', str(work), str(PROJECT / 'tools/pdf_tools.py')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    shutil.copy2(work / 'dist/pdf-tools.exe', payload / 'pdf-tools.exe')


def recycle(path):
    """移到回收站（误删可以找回）；失败时抛出异常，不会直接永久删除。"""
    command = ("Add-Type -AssemblyName Microsoft.VisualBasic; "
               "[Microsoft.VisualBasic.FileIO.FileSystem]::{0}($env:RECYCLE_TARGET, 'OnlyErrorDialogs', 'SendToRecycleBin')")
    method = 'DeleteDirectory' if path.is_dir() else 'DeleteFile'
    subprocess.run(['powershell.exe', '-NoProfile', '-Command', command.format(method)],
                   check=True, env={**os.environ, 'RECYCLE_TARGET': str(path)})


def remove_old_packages(output, keep):
    removed = []
    for item in output.iterdir():
        if item == keep or not item.name.startswith(OLD_PACKAGE_PREFIXES):
            continue
        if not re.fullmatch(r'(自动化工具面板|表格工具面板)-\d{8}-\d{6}(\.zip)?', item.name):
            continue
        recycle(item)
        removed.append(item.name)
    return removed


def build(output, keep_old=False):
    started = datetime.now().astimezone()
    name = PACKAGE_PREFIX + started.strftime('%Y%m%d-%H%M%S')
    output.mkdir(parents=True, exist_ok=True)
    archive = output / (name + '.zip')
    if archive.exists():
        raise FileExistsError(archive)
    with tempfile.TemporaryDirectory(prefix='share-build-') as temp:
        temp = Path(temp)
        folder = temp / name
        payload = folder / 'app'
        payload.mkdir(parents=True)
        script, function_count = build_panel_script()
        (payload / 'spreadsheet-panel.ahk').write_text(script, encoding='utf-8-sig')
        build_pdf_tools(payload, temp / 'pyinstaller')
        runtime = Path(r'C:\Program Files\AutoHotkey')
        runtime_version = subprocess.check_output(['powershell.exe', '-NoProfile', '-Command',
            "(Get-Item 'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe').VersionInfo.ProductVersion"], text=True).strip()
        shutil.copy2(runtime / 'v2/AutoHotkey64.exe', payload / 'AutoHotkey64.exe')
        shutil.copy2(runtime / 'license.txt', payload / 'AutoHotkey-license.txt')
        (payload / 'AutoHotkey-source.txt').write_text(
            'AutoHotkey v2 runtime, unmodified. License: GNU GPL v2 or later.\n'
            f'Complete corresponding source: https://github.com/AutoHotkey/AutoHotkey/tree/v{runtime_version}\n'
            'A matching source archive is included alongside this notice.\n'
            'The runtime version is recorded in build-info.json.\n', encoding='utf-8-sig')
        urllib.request.urlretrieve(f'https://codeload.github.com/AutoHotkey/AutoHotkey/zip/refs/tags/v{runtime_version}', payload / 'AutoHotkey-source.zip')
        for file_name in ('install.ps1', 'uninstall.ps1', 'setup.ahk', '使用说明.txt'):
            (folder / file_name).write_text((HERE / file_name).read_text(encoding='utf-8-sig'), encoding='utf-8-sig')
        for file_name, mode in [('双击安装.cmd', 'install'), ('卸载.cmd', 'uninstall')]:
            (folder / file_name).write_bytes((
                '@echo off\r\nsetlocal\r\n'
                'echo Starting Automation Tools setup...\r\n'
                'if not exist "%~dp0app\\AutoHotkey64.exe" goto missing\r\n'
                'if not exist "%~dp0setup.ahk" goto missing\r\n'
                '"%~dp0app\\AutoHotkey64.exe" /ErrorStdOut "%~dp0setup.ahk" ' + mode + ' %* >>"%LOCALAPPDATA%\\SpreadsheetToolsShare-launch.log" 2>&1\r\n'
                'set "setupExit=%errorlevel%"\r\n'
                'if "%setupExit%"=="0" exit /b 0\r\n'
                'echo Setup failed. Error code: %setupExit%\r\n'
                'echo Log: %LOCALAPPDATA%\\SpreadsheetToolsShare-install.log\r\n'
                'echo Launcher log: %LOCALAPPDATA%\\SpreadsheetToolsShare-launch.log\r\n'
                'type "%LOCALAPPDATA%\\SpreadsheetToolsShare-launch.log"\r\n'
                'pause\r\nexit /b %setupExit%\r\n'
                ':missing\r\necho Missing setup files. Extract the ENTIRE ZIP first.\r\n'
                'pause\r\nexit /b 2\r\n').encode('ascii'))
        manifest = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in payload.iterdir() if p.is_file()}
        (folder / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8-sig')
        (folder / 'manifest.sha256').write_text(''.join(f'{digest}  {file}\n' for file, digest in manifest.items()), encoding='utf-8-sig')
        (folder / 'build-info.json').write_text(json.dumps({
            'build_started': started.isoformat(), 'functions': function_count, 'runtime_version': runtime_version,
            'source_hashes': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (PROJECT / 'src').glob('*.ahk')},
        }, indent=2), encoding='utf-8-sig')
        partial = archive.with_suffix('.zip.partial')
        with zipfile.ZipFile(partial, 'w', zipfile.ZIP_DEFLATED) as z:
            for p in folder.rglob('*'):
                if p.is_file():
                    z.write(p, Path(folder.name) / p.relative_to(folder))
        partial.replace(archive)
    removed = [] if keep_old else remove_old_packages(output, archive)
    print(json.dumps({'zip': str(archive), 'size': archive.stat().st_size, 'build_started': started.isoformat(),
                      'functions': function_count, 'recycled_old_packages': removed}, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=None, help='输出目录，默认桌面')
    parser.add_argument('--keep-old', action='store_true', help='不清理输出目录里的旧分享包')
    args = parser.parse_args()
    build(args.output or default_output(), args.keep_old)
