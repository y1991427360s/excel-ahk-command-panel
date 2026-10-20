param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'SpreadsheetToolsShare'), [switch]$NoShortcuts, [switch]$NoLaunch)
$ErrorActionPreference = 'Stop'
try {
    if (-not [Environment]::Is64BitOperatingSystem) { throw '此安装包需要 64 位 Windows。' }
    $payload = Join-Path $PSScriptRoot 'app'
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($item in $manifest.PSObject.Properties) {
        if ($item.Name -ne [IO.Path]::GetFileName($item.Name)) { throw '安装包文件清单无效。' }
        $source = Join-Path $payload $item.Name
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $item.Value) { throw "安装包文件损坏，请重新解压：$($item.Name)" }
    }
    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
    $scriptPath = Join-Path $InstallRoot 'spreadsheet-panel.ahk'
    $exePath = Join-Path $InstallRoot 'AutoHotkey64.exe'
    Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe'" | Where-Object {
        $_.ExecutablePath -eq $exePath -and $_.CommandLine.Contains($scriptPath)
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    foreach ($item in $manifest.PSObject.Properties) {
        Copy-Item -LiteralPath (Join-Path $payload $item.Name) -Destination (Join-Path $InstallRoot $item.Name) -Force
        if ((Get-FileHash -LiteralPath (Join-Path $InstallRoot $item.Name) -Algorithm SHA256).Hash -ne $item.Value) { throw "安装后校验失败：$($item.Name)" }
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '使用说明.txt') -Destination $InstallRoot -Force
    if (-not $NoShortcuts) {
        $shell = New-Object -ComObject WScript.Shell
        $startupDir = [Environment]::GetFolderPath('Startup')
        $desktopDir = [Environment]::GetFolderPath('Desktop')
        foreach ($directory in @($startupDir, $desktopDir)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $link = $shell.CreateShortcut((Join-Path $directory '表格工具面板（分享版）.lnk'))
            $link.TargetPath = $exePath
            $link.Arguments = '"' + $scriptPath + '"'
            $link.WorkingDirectory = $InstallRoot
            $link.Description = 'Excel / WPS 表格工具，快捷键 Ctrl+Shift+E'
            $link.Save()
        }
    }
    if (-not $NoLaunch) {
        $process = Start-Process -FilePath $exePath -ArgumentList ('"' + $scriptPath + '"') -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 1000
        if ($process.HasExited) { throw '程序启动失败，请保留错误信息并联系发送者。' }
    }
    Write-Host '安装成功！先打开 Excel 或 WPS，选中单元格，再按 Ctrl+Shift+E。' -ForegroundColor Green
    Write-Host "安装目录：$InstallRoot"
    Write-Host '已安装的程序不依赖解压目录，安装后可删除压缩包和解压文件夹。'
    Write-Host '需要卸载时，重新解压本包并双击“卸载.cmd”。'
} catch {
    Write-Host ('安装失败：' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
