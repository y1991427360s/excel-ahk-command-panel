"""从生产源码提取表格功能，生成自带运行环境的朋友分享包。"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import urllib.request
import zipfile
from datetime import datetime

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent


def build(output):
    started = datetime.now().astimezone()
    folder = output / ('表格工具面板-' + started.strftime('%Y%m%d-%H%M%S'))
    folder.mkdir(parents=True, exist_ok=False)
    payload = folder / 'app'
    payload.mkdir()
    original = (PROJECT / 'src/excel-command-panel.ahk').read_text(encoding='utf-8-sig')
    functions = {}
    for source in (PROJECT / 'src').glob('*.ahk'):
        for match in re.finditer(r'^(\w+)\([^\n]*\) \{\n.*?^\}', source.read_text(encoding='utf-8-sig'), re.M | re.S):
            if match[1] in functions:
                raise ValueError('Duplicate function: ' + match[1])
            functions[match[1]] = match[0]
    body = (HERE / 'share-panel.ahk').read_text(encoding='utf-8-sig')
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
    for forbidden in ('ZWCAD', 'CopyQ', 'Syncthing', 'ys199', 'OpenSelectedDwg', 'GetSelectedFilePaths'):
        if forbidden in script:
            raise ValueError('Unexpected personal/file-tool dependency: ' + forbidden)
    (payload / 'spreadsheet-panel.ahk').write_text(script, encoding='utf-8-sig')
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
    for name in ('install.ps1', 'uninstall.ps1', 'setup.ahk', '使用说明.txt'):
        (folder / name).write_text((HERE / name).read_text(encoding='utf-8-sig'), encoding='utf-8-sig')
    for name, mode in [('双击安装.cmd', 'install'), ('卸载.cmd', 'uninstall')]:
        (folder / name).write_bytes((
            '@echo off\r\nsetlocal\r\n'
            'echo Starting Spreadsheet Tools setup...\r\n'
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
    (folder / 'manifest.sha256').write_text(''.join(f'{digest}  {name}\n' for name, digest in manifest.items()), encoding='utf-8-sig')
    (folder / 'build-info.json').write_text(json.dumps({
        'build_started': started.isoformat(), 'functions': len(used), 'runtime_version': runtime_version,
        'source_hashes': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (PROJECT / 'src').glob('*.ahk')},
    }, indent=2), encoding='utf-8-sig')
    archive = folder.with_suffix('.zip')
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
        for p in folder.rglob('*'):
            if p.is_file():
                z.write(p, Path(folder.name) / p.relative_to(folder))
    print(json.dumps({'folder': str(folder), 'zip': str(archive), 'build_started': started.isoformat(), 'functions': len(used)}, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    build(parser.parse_args().output)
