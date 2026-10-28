param([string]$AutoHotkey = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe')
$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
$testRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testDir = Join-Path $testRoot ('copyq-guard-smoke-' + [guid]::NewGuid().ToString('N'))
$fakeExe = Join-Path $testDir 'fake-copyq.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'C# compiler not found.' }
if (-not (Test-Path -LiteralPath $AutoHotkey)) { throw 'AutoHotkey v2 not found.' }

# 所有状态和进程都由此测试临时创建；不会运行或连接真实 CopyQ。
$fakeSource = @'
using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
class FakeCopyQ {
    static int Main(string[] args) {
        string dir = Environment.GetEnvironmentVariable("COPYQ_GUARD_TEST_DIR");
        File.AppendAllText(Path.Combine(dir, "calls"), String.Join(" ", args) + "\n");
        string mode = args[0];
        if (mode == "sentinel") { Thread.Sleep(20000); return 0; }
        if (mode == "wait") {
            File.WriteAllText(Path.Combine(dir, "pid"), Process.GetCurrentProcess().Id.ToString());
            Thread.Sleep(20000);
            return 0;
        }
        if (mode == "error") { Console.Error.Write("expected failure"); return 7; }
        if (mode == "eval") { Console.Write(File.ReadAllText(Path.Combine(dir, "state"))); return 0; }
        if (mode == "disable") {
            File.WriteAllText(Path.Combine(dir, "state"), "false");
            if (File.Exists(Path.Combine(dir, "fail-disable"))) {
                Console.Error.Write("disable failed after state change");
                return 8;
            }
            return 0;
        }
        if (mode == "enable") { File.WriteAllText(Path.Combine(dir, "state"), "true"); return 0; }
        Console.Write("OK");
        return 0;
    }
}
'@
New-Item -ItemType Directory -Path $testDir | Out-Null
try {
    $fakePath = Join-Path $testDir 'fake-copyq.cs'
    [IO.File]::WriteAllText($fakePath, $fakeSource)
    & $compiler /nologo /target:winexe "/out:$fakeExe" $fakePath
    if ($LASTEXITCODE -ne 0) { throw 'Fake CLI compilation failed.' }

    $guardPath = Join-Path $projectDir 'src\copyq-guard.ahk'
    $header = "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#Warn All, StdOut`n#Warn LocalSameAsGlobal, Off`n#Include $guardPath`n"
    $testPath = Join-Path $testDir 'test.ahk'
    [IO.File]::WriteAllText($testPath, $header + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'copyq-guard-smoke.ahk')), [Text.UTF8Encoding]::new($true))
    $outputPath = Join-Path $testDir 'output.txt'
    $errorPath = Join-Path $testDir 'error.txt'
    $testProcess = Start-Process -FilePath $AutoHotkey -ArgumentList @('/ErrorStdOut', ('"' + $testPath + '"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath
    $null = $testProcess.Handle
    if (-not $testProcess.WaitForExit(30000)) {
        $testProcess.Kill()
        throw 'CopyQ guard test timed out.'
    }
    $testProcess.Refresh()
    Get-Content -LiteralPath $outputPath
    Get-Content -LiteralPath $errorPath
    if ($testProcess.ExitCode -ne 0) { throw ('CopyQ guard test failed: ' + $testProcess.ExitCode) }
    if ([IO.File]::ReadAllText($outputPath) -notmatch 'PASS CopyQ guard:') { throw 'Test exited without PASS.' }
} finally {
    # 仅清理此随机目录中的模拟客户端，绝不按 CopyQ 主程序名称结束进程。
    Get-Process -Name 'fake-copyq' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $fakeExe } | Stop-Process -Force
    $resolvedTestDir = [IO.Path]::GetFullPath($testDir)
    if (-not $resolvedTestDir.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedTestDir) -notlike 'copyq-guard-smoke-*') {
        throw 'Refusing cleanup outside the test temporary directory.'
    }
    if (Test-Path -LiteralPath $resolvedTestDir) { Remove-Item -LiteralPath $resolvedTestDir -Recurse -Force }
}
