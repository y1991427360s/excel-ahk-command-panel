param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'SpreadsheetToolsShare'))
$ErrorActionPreference = 'Stop'
try {
    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
    if ([IO.Path]::GetFileName($InstallRoot) -ne 'SpreadsheetToolsShare') { throw '卸载目录不符合预期，已停止。' }
    $exePath = Join-Path $InstallRoot 'AutoHotkey64.exe'
    $scriptPath = Join-Path $InstallRoot 'spreadsheet-panel.ahk'
    Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe'" | Where-Object {
        $_.ExecutablePath -eq $exePath -and $_.CommandLine.Contains($scriptPath)
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($directory in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('Desktop'))) {
        $linkPath = Join-Path $directory '表格工具面板（分享版）.lnk'
        if (Test-Path -LiteralPath $linkPath) {
            if ($shell.CreateShortcut($linkPath).TargetPath -eq $exePath) { Remove-Item -LiteralPath $linkPath }
        }
    }
    foreach ($name in @('AutoHotkey64.exe', 'spreadsheet-panel.ahk', 'AutoHotkey-license.txt', 'AutoHotkey-source.txt', 'AutoHotkey-source.zip', '使用说明.txt')) {
        $path = Join-Path $InstallRoot $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    if ((Test-Path -LiteralPath $InstallRoot) -and @(Get-ChildItem -LiteralPath $InstallRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $InstallRoot }
    Write-Host '卸载完成。Excel / WPS 和你的表格文件不会被删除。' -ForegroundColor Green
} catch {
    Write-Host ('卸载失败：' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
