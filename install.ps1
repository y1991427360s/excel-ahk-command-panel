$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceScript = Join-Path $projectRoot 'src\excel-command-panel.ahk'
$ahkExe = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$startupLink = Join-Path $startupDir 'excel-command-panel.lnk'
$documentsDir = [Environment]::GetFolderPath('MyDocuments')
$disabledBackupDir = Join-Path $documentsDir 'AutoHotkey\disabled-startup-backup'
$oldStartupItems = @(
    (Join-Path $startupDir 'excel-prefix-selected-cells.lnk'),
    (Join-Path $startupDir 'excel-prefix-selected-cells.lnk.disabled'),
    (Join-Path $startupDir 'excel-dedupe-sort-b-column.lnk'),
    (Join-Path $startupDir 'excel-dedupe-sort-b-column.lnk.disabled')
)

if (-not (Test-Path -LiteralPath $ahkExe)) {
    throw "AutoHotkey v2 not found: $ahkExe"
}

if (-not (Test-Path -LiteralPath $sourceScript)) {
    throw "Main script not found: $sourceScript"
}

New-Item -ItemType Directory -Path $startupDir -Force | Out-Null
New-Item -ItemType Directory -Path $disabledBackupDir -Force | Out-Null

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($startupLink)
$shortcut.TargetPath = $ahkExe
$shortcut.Arguments = '"' + $sourceScript + '"'
$shortcut.WorkingDirectory = $projectRoot
$shortcut.IconLocation = "$ahkExe,0"
$shortcut.Save()

foreach ($item in $oldStartupItems) {
    if (Test-Path -LiteralPath $item) {
        Move-Item -LiteralPath $item -Destination (Join-Path $disabledBackupDir (Split-Path -Leaf $item)) -Force
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

$taskName = "StartAutoHotkeyPanel"
$taskAction = New-ScheduledTaskAction -Execute $ahkExe -Argument ('"' + $sourceScript + '"') -WorkingDirectory $projectRoot
Register-ScheduledTask -TaskName $taskName -Action $taskAction -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Milliseconds 600
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

Write-Host "Installed automation panel:"
Write-Host "  Script: $sourceScript"
Write-Host "  Startup: $startupLink"
Write-Host "  Hotkey: Ctrl+Shift+E"
