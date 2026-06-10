$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceScript = Join-Path $projectRoot 'src\excel-command-panel.ahk'
$targetDir = 'D:\Users\ys199\Documents\AutoHotkey'
$targetScript = Join-Path $targetDir 'excel-command-panel.ahk'
$ahkExe = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$startupLink = Join-Path $startupDir 'excel-command-panel.lnk'
$oldLinks = @(
    (Join-Path $startupDir 'excel-prefix-selected-cells.lnk'),
    (Join-Path $startupDir 'excel-dedupe-sort-b-column.lnk')
)

if (-not (Test-Path -LiteralPath $ahkExe)) {
    throw "AutoHotkey v2 not found: $ahkExe"
}

New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
Copy-Item -LiteralPath $sourceScript -Destination $targetScript -Force

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($startupLink)
$shortcut.TargetPath = $ahkExe
$shortcut.Arguments = '"' + $targetScript + '"'
$shortcut.WorkingDirectory = $targetDir
$shortcut.IconLocation = "$ahkExe,0"
$shortcut.Save()

foreach ($link in $oldLinks) {
    if (Test-Path -LiteralPath $link) {
        Rename-Item -LiteralPath $link -NewName ((Split-Path -Leaf $link) + '.disabled') -Force
    }
}

Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
    Where-Object {
        $_.CommandLine -like '*excel-command-panel.ahk*' -or
        $_.CommandLine -like '*excel-prefix-selected-cells.ahk*' -or
        $_.CommandLine -like '*excel-dedupe-sort-b-column.ahk*'
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force
    }

Start-Process -FilePath $ahkExe -ArgumentList ('"' + $targetScript + '"') -WindowStyle Hidden

Write-Host "Installed Excel command panel:"
Write-Host "  Script: $targetScript"
Write-Host "  Startup: $startupLink"
Write-Host "  Hotkey: Ctrl+Shift+E"
