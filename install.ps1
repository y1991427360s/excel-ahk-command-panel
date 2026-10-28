$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceScript = [IO.Path]::GetFullPath((Join-Path $projectRoot 'src\excel-command-panel.ahk'))
$ahkExe = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$startupLink = Join-Path $startupDir 'excel-command-panel.lnk'
$documentsDir = [Environment]::GetFolderPath('MyDocuments')
$legacyScriptDir = Join-Path $documentsDir 'AutoHotkey'
$disabledBackupDir = Join-Path $legacyScriptDir 'disabled-startup-backup'
$oldStartupItems = @(
    (Join-Path $startupDir 'excel-prefix-selected-cells.lnk'),
    (Join-Path $startupDir 'excel-prefix-selected-cells.lnk.disabled'),
    (Join-Path $startupDir 'excel-dedupe-sort-b-column.lnk'),
    (Join-Path $startupDir 'excel-dedupe-sort-b-column.lnk.disabled')
)

if (-not (Test-Path -LiteralPath $ahkExe -PathType Leaf)) {
    throw "AutoHotkey v2 not found: $ahkExe"
}
if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) {
    throw "Main script not found: $sourceScript"
}

# 检查失败时保留正在运行的旧面板和原有启动项。
# GUI 程序必须显式等待，避免读取 PowerShell 继承的旧 LASTEXITCODE。
$validationStdout = [IO.Path]::GetTempFileName()
$validationStderr = [IO.Path]::GetTempFileName()
$validationProcess = $null
try {
    $validationProcess = Start-Process -FilePath $ahkExe -ArgumentList ('/iLib nul /ErrorStdOut=UTF-8 "' + $sourceScript + '"') -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $validationStdout -RedirectStandardError $validationStderr
    $null = $validationProcess.Handle
    if (-not $validationProcess.WaitForExit(15000)) {
        # 只结束本次静态检查进程，当前运行面板不受影响。
        $validationProcess.Kill()
        $null = $validationProcess.WaitForExit(5000)
        throw 'AutoHotkey static load check timed out after 15 seconds; the running panel was preserved.'
    }
    $validationProcess.WaitForExit()
    $validationExitCode = $validationProcess.ExitCode
    $validationOutput = [IO.File]::ReadAllText($validationStdout) + [IO.File]::ReadAllText($validationStderr)
    if ($validationExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($validationOutput)) {
        throw "AutoHotkey static load check failed (exit $validationExitCode):`n$validationOutput"
    }
} finally {
    if ($null -ne $validationProcess) { $validationProcess.Dispose() }
    Remove-Item -LiteralPath $validationStdout, $validationStderr -Force -ErrorAction SilentlyContinue
}

# 使用 Windows 原生命令行解析，避免文件名子串匹配误关其他目录的脚本。
if (-not ('PanelInstall.CommandLine' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace PanelInstall {
    public static class CommandLine {
        [DllImport("shell32.dll", SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW(
            [MarshalAs(UnmanagedType.LPWStr)] string commandLine, out int argc);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);
        public static string[] Split(string commandLine) {
            int count;
            IntPtr buffer = CommandLineToArgvW(commandLine, out count);
            if (buffer == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            try {
                string[] args = new string[count];
                for (int i = 0; i < count; i++)
                    args[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(buffer, i * IntPtr.Size));
                return args;
            } finally { LocalFree(buffer); }
        }
    }
}
"@
}

function Get-PanelScriptPath($process) {
    if (-not $process.CommandLine) { return }
    $arguments = [PanelInstall.CommandLine]::Split($process.CommandLine)
    # AHK 的首个非选项参数才是脚本，脚本后的参数不能用于进程匹配。
    foreach ($argument in ($arguments | Select-Object -Skip 1)) {
        if ($argument.StartsWith('/') -or $argument.StartsWith('-')) { continue }
        if ([IO.Path]::IsPathRooted($argument) -and [IO.Path]::GetExtension($argument) -ieq '.ahk') {
            return [IO.Path]::GetFullPath($argument)
        }
        return
    }
}

function Get-RunningPanel {
    Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
        Where-Object { (Get-PanelScriptPath $_) -ieq $sourceScript }
}

$managedPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$null = $managedPaths.Add($sourceScript)
foreach ($legacyName in @('excel-command-panel.ahk', 'excel-prefix-selected-cells.ahk', 'excel-dedupe-sort-b-column.ahk')) {
    $null = $managedPaths.Add([IO.Path]::GetFullPath((Join-Path $legacyScriptDir $legacyName)))
}

# 提前取得资源管理器桌面外壳；外壳不可用时不结束现有面板。
$desktopHwnd = 0
$desktop = (New-Object -ComObject Shell.Application).Windows().FindWindowSW([ref]0, [ref]0, 8, [ref]$desktopHwnd, 1)
$explorerShell = $desktop.Document.Application
if ($null -eq $explorerShell) {
    throw 'Explorer desktop shell is unavailable; the running panel was preserved.'
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

$previousIds = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
    Where-Object {
        $scriptPath = Get-PanelScriptPath $_
        $scriptPath -and $managedPaths.Contains($scriptPath)
    } |
    ForEach-Object { $_.ProcessId })
foreach ($id in $previousIds) {
    Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
}
# 强制结束后系统回收进程偶尔超过 15 秒（2026-10-28 两次实测，几秒后自行退出）。
# 统一等待最多 45 秒；仍未消失只警告并继续启动新面板，避免旧面板已失效而新面板没起来。
$stopWatch = [Diagnostics.Stopwatch]::StartNew()
$lingeringIds = @()
do {
    $lingeringIds = @($previousIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($lingeringIds.Count -eq 0) { break }
    Start-Sleep -Milliseconds 250
} while ($stopWatch.Elapsed.TotalSeconds -lt 45)
if ($previousIds.Count -gt 0) {
    Write-Host ("Previous panel stop took {0:N1}s" -f $stopWatch.Elapsed.TotalSeconds)
}
if ($lingeringIds.Count -gt 0) {
    Write-Warning "Previous panel process still exiting after 45s: $($lingeringIds -join ', '); starting the new panel anyway."
}

# 由开机时的 explorer 代为启动，避免随 AI 工具或终端清理而被连带结束。
$explorerShell.ShellExecute($ahkExe, ('"' + $sourceScript + '"'), $projectRoot, 'open', 0)
$deadline = [DateTime]::UtcNow.AddSeconds(10)
$runningPanel = @()
do {
    Start-Sleep -Milliseconds 250
    $runningPanel = @(Get-RunningPanel | Where-Object { $_.ProcessId -notin $previousIds })
} while ($runningPanel.Count -eq 0 -and [DateTime]::UtcNow -lt $deadline)
if ($runningPanel.Count -eq 0) {
    throw "Panel startup failed: no process was found for $sourceScript"
}
# 再检查一次同一 PID，排除启动后立即退出。
Start-Sleep -Seconds 1
$startedIds = @($runningPanel | ForEach-Object { $_.ProcessId })
$runningPanel = @(Get-RunningPanel | Where-Object { $_.ProcessId -in $startedIds })
if ($runningPanel.Count -eq 0) {
    throw "Panel exited immediately after startup: $sourceScript"
}

Write-Host "Installed automation panel:"
Write-Host "  Script: $sourceScript"
Write-Host "  Startup: $startupLink"
Write-Host "  PID: $(($runningPanel.ProcessId) -join ', ')"
Write-Host "  Hotkey: Ctrl+Shift+E"
