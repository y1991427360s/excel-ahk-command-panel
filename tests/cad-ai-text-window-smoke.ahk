#Requires AutoHotkey v2.0
; AI 改 CAD 文字窗口冒烟：填入样例、真实调用 AI、核对结果并截图。不连接 CAD。
; 运行：AutoHotkey64.exe tests\cad-ai-text-window-smoke.ahk <截图路径>
#SingleInstance Force
#Include ..\src\modern-panel-ui.ahk
#Include ..\src\cad-ai-text.ahk

global SentCommands := []

; 替身：主面板里的函数，测试不碰 CAD
RunPanelCommand(callback) => callback.Call()
RunZwcadCommand(cmd, label, *) => SentCommands.Push(cmd)

Main()

Main() {
    fixtures := A_ScriptDir . "\cad-ai-text"
    OpenCadAiTextWindow()
    CadAiEdits["template"].Value := FileRead(fixtures . "\template.txt", "UTF-8")
    CadAiEdits["table"].Value := FileRead(fixtures . "\table.txt", "UTF-8")
    CadAiEdits["request"].Value := FileRead(fixtures . "\request.txt", "UTF-8")
    CadAiRun()
    deadline := A_TickCount + 240000
    while (IsObject(CadAiJob) && A_TickCount < deadline)
        Sleep(200)
    Sleep(800)
    result := CadAiEdits["result"].Value
    lineCount := StrSplit(Trim(result, "`r`n"), "`n").Length
    Screenshot(A_Args.Length ? A_Args[1] : A_Temp . "\cad-ai-text-window.png")

    CadAiWriteBack()
    summary := "lines=" . lineCount . " sent=" . (SentCommands.Length ? SentCommands[1] : "")
        . " clipSame=" . (Trim(A_Clipboard, "`r`n") = Trim(result, "`r`n")) . "`n" . SubStr(CadAiEdits["report"].Value, 1, 200)
    FileAppend(summary . "`n", "*", "UTF-8")
    CadAiClose()
    ExitApp(lineCount = 1350 ? 0 : 1)
}

Screenshot(path) {
    WinGetPos(&x, &y, &w, &h, "ahk_id " . CadAiUi["gui"].Hwnd)
    ps := "Add-Type -AssemblyName System.Drawing;$b=New-Object Drawing.Bitmap " . w . "," . h
        . ";$g=[Drawing.Graphics]::FromImage($b);$g.CopyFromScreen(" . x . "," . y . ",0,0,$b.Size);$b.Save('" . path . "')"
    RunWait('powershell.exe -NoProfile -NonInteractive -Command "' . ps . '"', , "Hide")
}
