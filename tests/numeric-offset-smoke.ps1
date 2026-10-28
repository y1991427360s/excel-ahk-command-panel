param([ValidateSet('excel', 'wps')][string]$Provider = 'excel')
$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $projectDir 'src\excel-command-panel.ahk'
$sourceText = [IO.File]::ReadAllText($sourcePath)
$functionStart = $sourceText.IndexOf('ShowAutomationPanel() {')
if ($functionStart -lt 0) { throw 'Cannot locate panel functions' }
$diagnosticStart = $sourceText.IndexOf('LogPanelDiagnostic(eventName, details := "") {')
$diagnosticEnd = $sourceText.IndexOf('^+e:: {')
if ($diagnosticStart -lt 0 -or $diagnosticEnd -lt 0) { throw 'Cannot locate diagnostic function' }
$testPath = Join-Path $PSScriptRoot 'numeric-offset-smoke.ahk'
$tempPath = Join-Path $PSScriptRoot ('numeric-offset-' + [guid]::NewGuid().ToString('N') + '.tmp.ahk')
$outputPath = $tempPath + '.log'
$errorPath = $tempPath + '.error.log'
$exportPath = Join-Path $projectDir 'src\spreadsheet-export.ahk'
$offsetPath = Join-Path $projectDir 'src\spreadsheet-numeric-offset.ahk'
$textPath = Join-Path $projectDir 'src\spreadsheet-text-transform.ahk'
$copyqPath = Join-Path $projectDir 'src\copyq-guard.ahk'
$uiPath = Join-Path $projectDir 'src\modern-panel-ui.ahk'
$globalsStart = $sourceText.IndexOf('global AutomationPanelGui :=')
$globalsEnd = $sourceText.IndexOf('LogPanelDiagnostic("')
$header = "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#Warn All, StdOut`n#Warn LocalSameAsGlobal, Off`n#Include $exportPath`n#Include $offsetPath`n#Include $textPath`n#Include $copyqPath`n#Include $uiPath`n" + $sourceText.Substring($globalsStart, $globalsEnd - $globalsStart)
$existingExcelIds = @(Get-Process EXCEL -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
try {
    [IO.File]::WriteAllText($tempPath, $header + [IO.File]::ReadAllText($testPath) + "`n" + $sourceText.Substring($diagnosticStart, $diagnosticEnd - $diagnosticStart) + $sourceText.Substring($functionStart), [Text.UTF8Encoding]::new($true))
    $testProcess = Start-Process -FilePath 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' -ArgumentList @('/ErrorStdOut', ('"' + $tempPath + '"'), $Provider) -WindowStyle Hidden -PassThru -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath
    $null = $testProcess.Handle
    if (-not $testProcess.WaitForExit(60000)) {
        Stop-Process -Id $testProcess.Id -Force
        throw ('Test timeout; process PID=' + $testProcess.Id)
    }
    $testProcess.Refresh()
    Get-Content -LiteralPath $outputPath
    Get-Content -LiteralPath $errorPath
    if ($testProcess.ExitCode -ne 0) { throw ('Test failed: ' + $testProcess.ExitCode) }
    # Only clean a newly created, hidden Excel automation process after PASS.
    $resultText = [IO.File]::ReadAllText($outputPath)
    if ($Provider -eq 'excel' -and $resultText -match 'TEST_APP_PID=(\d+)' -and $resultText -match 'PASS excel:') {
        $testExcelId = [int]([regex]::Match($resultText, 'TEST_APP_PID=(\d+)').Groups[1].Value)
        if ($testExcelId -notin $existingExcelIds) {
            $testExcelProcess = Get-Process -Id $testExcelId -ErrorAction SilentlyContinue
            $testExcelInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$testExcelId"
            if ($testExcelProcess -and $testExcelProcess.MainWindowHandle -eq 0 -and $testExcelInfo.Name -eq 'EXCEL.EXE' -and $testExcelInfo.CommandLine -like '*/automation*') {
                Stop-Process -Id $testExcelId -Force
            }
        }
    }
} finally {
    foreach ($testFile in @($tempPath, $outputPath, $errorPath)) {
        if (Test-Path -LiteralPath $testFile) { Remove-Item -LiteralPath $testFile }
    }
}
