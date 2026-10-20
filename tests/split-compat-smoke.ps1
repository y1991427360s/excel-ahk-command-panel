param([switch]$LegacyParser, [switch]$SelectionSnapshot)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $project 'src\excel-command-panel.ahk'))
$functions = $source.Substring($source.IndexOf('RoundSpreadsheetSelectionUpToTen() {'))
$functions = $functions.Replace('xmlStr := areaRange.Value(11)', 'xmlStr := CompatXml(areaRange.Value(11))')
if ($SelectionSnapshot) {
    $functions = $functions.Replace('MsgBox(', 'SnapshotTestMsgBox(')
    $functions = $functions.Replace('xmlStr := CompatXml(areaRange.Value(11))', 'xmlStr := areaRange.Value(11)')
    $functions = [regex]::Replace($functions, '(?ms)^TryGetActiveComObject\(progId\) \{\r?\n.*?^\}', "TryGetActiveComObject(progId) {`n    global SnapshotTestApplication`n    return SnapshotTestApplication`n}")
}
if ($LegacyParser) {
    $start = $functions.IndexOf('                    xmlPosition := 1')
    $end = $functions.IndexOf('                        if (!inTable)', $start)
    $legacyLoop = '                    Loop Parse, xmlStr, "`n", "`r" {' + "`n                        line := A_LoopField`n"
    $functions = $functions.Substring(0, $start) + $legacyLoop + $functions.Substring($end)
    $functions = $functions.Replace('hasParsedXml := (areaItems.Length > 0)', 'hasParsedXml := true')
}
$temp = Join-Path $env:TEMP ('split-compat-' + [guid]::NewGuid().ToString('N') + '.ahk')
$header = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off
global ExcelCommandUndoStack := []
global AutomationContextHwnd := 0
global AutomationPanelGui := ""
global AutomationSpreadsheetSelectionContext := ""
global AutomationSelectedFilePaths := []
global CopyQExe := ""
global SelectedDwgPath := ""
global AaLspPath := ""
global CompatMode := "pretty"
LogPanelDiagnostic(*) {
}
'@
try {
    $testName = if ($SelectionSnapshot) { 'selection-snapshot-smoke.ahk' } else { 'split-compat-smoke.ahk' }
    [IO.File]::WriteAllText($temp, $header + "`n" + [IO.File]::ReadAllText((Join-Path $PSScriptRoot $testName)) + "`n" + $functions, [Text.UTF8Encoding]::new($true))
    $process = Start-Process -FilePath 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' -ArgumentList @('/ErrorStdOut', ('"' + $temp + '"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput ($temp + '.log') -RedirectStandardError ($temp + '.error.log')
    $null = $process.Handle
    if (-not $process.WaitForExit(55000)) { Stop-Process -Id $process.Id; throw '兼容测试超时' }
    $process.Refresh()
    Get-Content -LiteralPath ($temp + '.log') -Encoding UTF8
    Get-Content -LiteralPath ($temp + '.error.log') -Encoding UTF8
    if ($process.ExitCode -ne 0) { throw ('兼容测试失败：' + $process.ExitCode) }
} finally {
    foreach ($path in @($temp, ($temp + '.log'), ($temp + '.error.log'))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
}
