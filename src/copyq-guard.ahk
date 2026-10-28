#Requires AutoHotkey v2.0

; 只持有本次 CLI 客户端的句柄；超时绝不按进程名结束 CopyQ 主程序。
RunCopyQCommand(exe, args, timeoutMs := 2000) {
    if (timeoutMs <= 0)
        throw ValueError("CopyQ 超时时间必须大于零。")
    if InStr(exe, '"')
        throw ValueError("CopyQ 程序路径包含无效引号。")

    client := ComObject("WScript.Shell").Exec('"' . exe . '" ' . args)
    ; 提前保存进程句柄，避免超时时按已被复用的 PID 误结束其他进程。
    processHandle := DllCall("OpenProcess", "UInt", 1, "Int", false, "UInt", client.ProcessID, "Ptr")
    started := DllCall("GetTickCount64", "UInt64")
    try {
        while (client.Status = 0) {
            if (DllCall("GetTickCount64", "UInt64") - started >= timeoutMs)
                throw Error("CopyQ 命令超时（" . timeoutMs . " 毫秒）：" . args)
            Sleep(20)
        }
        output := client.StdOut.ReadAll()
        errorText := client.StdErr.ReadAll()
        if (client.ExitCode != 0)
            throw Error("CopyQ 命令失败（退出码 " . client.ExitCode . "）：" . Trim(errorText . "`n" . output))
        return output
    } finally {
        try {
            if (client.Status = 0) {
                if processHandle {
                    if !DllCall("TerminateProcess", "Ptr", processHandle, "UInt", 1)
                        throw OSError(A_LastError, "结束超时的 CopyQ CLI 客户端失败。")
                } else {
                    ; 仅操作 Exec 创建的客户端；绝不按 copyq.exe 名称批量结束。
                    client.Terminate()
                }
            }
        } finally {
            if processHandle
                DllCall("CloseHandle", "Ptr", processHandle)
        }
    }
}

PauseCopyQForSelection(exe) {
    ; CopyQ 的官方状态查询是 monitoring()，不是不存在的 disabled()。
    state := StrLower(Trim(RunCopyQCommand(exe, 'eval "print(monitoring())"')))
    if (state = "false")
        return false
    if (state != "true")
        throw Error("无法确定 CopyQ 原有监控状态，已取消读取选区。")

    try RunCopyQCommand(exe, "disable")
    catch as err {
        ; 超时可能发生在主程序已经执行暂停之后，尽力恢复原先的开启状态。
        try RunCopyQCommand(exe, "enable")
        catch as restoreErr
            throw Error(err.Message . "`n恢复 CopyQ 监控也失败：" . restoreErr.Message)
        throw err
    }
    return true
}

ResumeCopyQAfterSelection(exe, pausedByUs) {
    if pausedByUs
        RunCopyQCommand(exe, "enable")
}
