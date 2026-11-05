#Requires AutoHotkey v2.0
; 图片识别冒烟：把图片放进剪贴板，走窗口的完整流程，真实调用 AI，结束后还原剪贴板。不连接 CAD。
; 运行：AutoHotkey64.exe tests\cad-ai-image-smoke.ahk <表格图片> [截图路径]
#SingleInstance Force
#Include ..\src\modern-panel-ui.ahk
#Include ..\src\cad-ai-text.ahk

RunPanelCommand(callback) => callback.Call()
RunZwcadCommand(cmd, label, *) => 0

Main()

Main() {
    global CadAiConfigPath
    CadAiConfigPath := A_Temp . "\cad-ai-image-smoke-none.ini"   ; 不存在，走 Claude Code 登录
    saved := ClipboardAll()
    image := A_Args[1]
    command := "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;"
        . "[Windows.Forms.Clipboard]::SetImage([Drawing.Image]::FromFile('" . image . "'))"
    RunWait('powershell.exe -NoProfile -NonInteractive -STA -Command "' . command . '"', , "Hide")
    OpenCadAiTextWindow()
    CadAiReadImage()
    A_Clipboard := saved
    deadline := A_TickCount + 150000
    while (IsObject(CadAiJob) && A_TickCount < deadline)
        Sleep(200)
    Sleep(800)
    table := CadAiEdits["table"].Value
    count := StrSplit(Trim(table, "`r`n"), "`n").Length
    if (A_Args.Length > 1)
        Screenshot(CadAiUi["gui"].Hwnd, A_Args[2])
    FileAppend("rows=" . count . "`n" . SubStr(CadAiEdits["report"].Value, 1, 120) . "`n", "*", "UTF-8")
    CadAiEdits["request"].Value := FileExist(CadAiRequestPath) ? FileRead(CadAiRequestPath, "UTF-8") : ""
    CadAiClose()
    ExitApp(count = 11 ? 0 : 1)
}

Screenshot(hwnd, path) {
    WinActivate("ahk_id " . hwnd)
    Sleep(200)
    WinGetPos(&x, &y, &w, &h, "ahk_id " . hwnd)
    ps := "Add-Type -AssemblyName System.Drawing;$b=New-Object Drawing.Bitmap " . w . "," . h
        . ";$g=[Drawing.Graphics]::FromImage($b);$g.CopyFromScreen(" . x . "," . y . ",0,0,$b.Size);$b.Save('" . path . "')"
    RunWait('powershell.exe -NoProfile -NonInteractive -Command "' . ps . '"', , "Hide")
}
