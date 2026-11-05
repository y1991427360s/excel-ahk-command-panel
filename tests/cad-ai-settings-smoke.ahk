#Requires AutoHotkey v2.0
; AI 设置冒烟：临时配置文件上跑一遍保存，确认 Python 能解开 Key，并截图。不访问外网，不连接 CAD。
; 运行：AutoHotkey64.exe tests\cad-ai-settings-smoke.ahk <截图路径>
#SingleInstance Force
#Include ..\src\modern-panel-ui.ahk
#Include ..\src\cad-ai-text.ahk

RunPanelCommand(callback) => callback.Call()
RunZwcadCommand(cmd, label, *) => 0

Main()

Main() {
    global CadAiConfigPath
    folder := A_Temp . "\cad-ai-settings-smoke"
    DirCreate(folder)
    CadAiConfigPath := folder . "\config.ini"
    if FileExist(CadAiConfigPath)
        FileDelete(CadAiConfigPath)
    OpenCadAiTextWindow()
    OpenCadAiSettings()
    ui := CadAiSettingsUi
    ui["login"].Value := 0
    CadAiSettingsSyncEnabled(ui)

    ; Anthropic 填一套，切到 OpenAI 再填一套，切回来应当还在
    ui["key"].Value := "sk-ant-测试"
    ui["openai"].Value := 1
    CadAiSettingsLoad(ui, "openai")
    ui["url"].Value := "https://relay.example/v1"
    ui["model"].Value := "gpt-test"
    ui["key"].Value := "sk-openai-test"
    ui["anthropic"].Value := 1
    CadAiSettingsLoad(ui, "anthropic")
    if (ui["key"].Value != "sk-ant-测试")
        Fail("切换格式后 Anthropic 的 Key 丢失")
    ui["openai"].Value := 1
    CadAiSettingsLoad(ui, "openai")
    Sleep(600)
    if A_Args.Length
        Screenshot(ui["gui"].Hwnd, A_Args[1])
    CadAiSettingsSave(false)

    if InStr(FileRead(CadAiConfigPath, "UTF-16"), "sk-openai-test")
        Fail("配置文件里出现明文 Key")
    if (CadAiProviderText() != "当前 AI：OpenAI 兼容 · gpt-test")
        Fail("当前 AI 显示不对：" . CadAiProviderText())

    code := "import sys;sys.path.insert(0,r'" . A_ScriptDir . "\..\tools');import cad_ai_text as t;s=t.load_settings(sys.argv[1]);"
        . "assert s['provider']=='openai' and s['api_key']=='sk-openai-test' and s['base_url']=='https://relay.example/v1' and s['model']=='gpt-test'"
    if RunWait('python -c "' . code . '" "' . CadAiConfigPath . '"', , "Hide")
        Fail("Python 读取配置或解密失败")
    CadAiClose()
    FileDelete(CadAiConfigPath)
    FileAppend("OK`n", "*", "UTF-8")
    ExitApp(0)
}

Fail(message) {
    FileAppend("FAIL: " . message . "`n", "*", "UTF-8")
    ExitApp(1)
}

Screenshot(hwnd, path) {
    WinActivate("ahk_id " . hwnd)
    Sleep(200)
    WinGetPos(&x, &y, &w, &h, "ahk_id " . hwnd)
    ps := "Add-Type -AssemblyName System.Drawing;$b=New-Object Drawing.Bitmap " . w . "," . h
        . ";$g=[Drawing.Graphics]::FromImage($b);$g.CopyFromScreen(" . x . "," . y . ",0,0,$b.Size);$b.Save('" . path . "')"
    RunWait('powershell.exe -NoProfile -NonInteractive -Command "' . ps . '"', , "Hide")
}
