; 由 copyq-guard-smoke.ps1 注入模块路径，在隔离临时目录运行。
testDir := A_ScriptDir
EnvSet("COPYQ_GUARD_TEST_DIR", testDir)
fakeExe := testDir . "\fake-copyq.exe"
sentinelPid := 0
try {
    AssertCopyQ(Trim(RunCopyQCommand(fakeExe, "ok")) = "OK", "stdout")
    caught := false
    try RunCopyQCommand(fakeExe, "error")
    catch as err
        caught := InStr(err.Message, "7") && InStr(err.Message, "expected failure")
    AssertCopyQ(caught, "exit status and stderr")

    SetCopyQTestState(testDir, "true")
    AssertCopyQ(PauseCopyQForSelection(fakeExe), "pause enabled monitoring")
    AssertCopyQ(FileRead(testDir . "\state") = "false", "disabled state")
    ResumeCopyQAfterSelection(fakeExe, true)
    AssertCopyQ(FileRead(testDir . "\state") = "true", "restore enabled monitoring")

    SetCopyQTestState(testDir, "false")
    FileDelete(testDir . "\calls")
    AssertCopyQ(!PauseCopyQForSelection(fakeExe), "already paused")
    ResumeCopyQAfterSelection(fakeExe, false)
    AssertCopyQ(FileRead(testDir . "\state") = "false", "retain paused state")
    calls := FileRead(testDir . "\calls")
    AssertCopyQ(!InStr(calls, "disable") && !InStr(calls, "enable"), "no unnecessary state changes")

    SetCopyQTestState(testDir, "unknown")
    FileDelete(testDir . "\calls")
    caught := false
    try PauseCopyQForSelection(fakeExe)
    catch
        caught := true
    AssertCopyQ(caught, "reject unknown state")
    calls := FileRead(testDir . "\calls")
    AssertCopyQ(!InStr(calls, "disable") && !InStr(calls, "enable"), "unknown state remains unchanged")

    SetCopyQTestState(testDir, "true")
    FileAppend("1", testDir . "\fail-disable")
    caught := false
    try PauseCopyQForSelection(fakeExe)
    catch
        caught := true
    AssertCopyQ(caught && FileRead(testDir . "\state") = "true", "restore after failed disable")
    FileDelete(testDir . "\fail-disable")

    Run('"' . fakeExe . '" sentinel', , "Hide", &sentinelPid)
    started := A_TickCount
    caught := false
    try RunCopyQCommand(fakeExe, "wait", 400)
    catch
        caught := true
    elapsed := A_TickCount - started
    AssertCopyQ(caught && elapsed < 1800, "bounded timeout")
    Sleep(100)
    AssertCopyQ(!ProcessExist(Integer(Trim(FileRead(testDir . "\pid")))), "timeout client terminated")
    AssertCopyQ(ProcessExist(sentinelPid), "other client survives timeout")
    FileAppend("PASS CopyQ guard: stdout, errors, enabled/paused/unknown states, failure recovery, isolated timeout (" . elapsed . " ms).`n", "*")
} catch as err {
    FileAppend("FAIL CopyQ guard: " . err.Message . " (line " . err.Line . ").`n", "*")
    ExitApp(1)
} finally {
    if (sentinelPid && ProcessExist(sentinelPid))
        ProcessClose(sentinelPid)
}
ExitApp()

AssertCopyQ(condition, message) {
    if !condition
        throw Error(message)
}

SetCopyQTestState(testDir, state) {
    path := testDir . "\state"
    if FileExist(path)
        FileDelete(path)
    FileAppend(state, path)
}
