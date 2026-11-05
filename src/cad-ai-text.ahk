#Requires AutoHotkey v2.0
; AI 改 CAD 文字：从中望取模板和参照表（QW2），AI 出替换规则，tools\cad_ai_text.py 展开并校验，
; 结果预览可手改，确认后放进剪贴板并执行 QW2P 写回图纸。全程不修改模板原文字，一次 U 可撤销写回。

global CadAiUi := ""
global CadAiEdits := Map()
global CadAiCapture := ""
global CadAiJob := ""
global CadAiWorkDir := A_Temp . "\cad-ai-text"
global CadAiRequestPath := EnvGet("LOCALAPPDATA") . "\AutoHotkeyPanel\cad-ai-request.txt"
global CadAiConfigPath := EnvGet("LOCALAPPDATA") . "\AutoHotkeyPanel\cad-ai-config.ini"
global CadAiSettingsUi := ""

OpenCadAiTextWindow(*) {
    global CadAiUi, CadAiEdits
    if IsObject(CadAiUi) {
        try {
            CadAiUi["gui"].Show()
            return
        }
    }
    colors := ModernPanelColors()
    ; WS_CLIPCHILDREN：画布重绘时不盖掉输入框
    ui := ModernPanelCreate("AI 改 CAD 文字", "-MaximizeBox +0x2000000", true)
    panel := ui["gui"]
    panel.SetFont("s10", "Microsoft YaHei UI")
    CadAiUi := ui
    CadAiEdits := Map()

    leftX := 20, rightX := 460, columnW := 420
    ModernPanelLabelAt(ui, leftX, 14, 600, 26, "AI 改 CAD 文字", ModernPanelTextStyle(colors["text"], 13, true))
    ui["provider"] := ModernPanelLabelAt(ui, 460, 18, 310, 22, CadAiProviderText()
        , ModernPanelTextStyle(colors["secondary"], 9, false, "right"))
    ModernPanelTile(ui, 780, 14, 100, 30, "AI 设置", OpenCadAiSettings, true)
    ModernPanelLabelAt(ui, leftX, 40, 860, 18, "AI 只出替换规则，所有文字由程序展开并校验，不会漏行或抄错坐标。"
        , ModernPanelTextStyle(colors["secondary"], 9))

    CadAiField(ui, "template", leftX, 66, columnW, 150, "① 模板文字", true)
    CadAiField(ui, "table", leftX, 250, columnW, 130, "② 参照表（可空）", true)
    ModernPanelTile(ui, leftX + columnW - 228, 250, 96, 26, "图片识别", CadAiReadImage, true)
    CadAiField(ui, "request", leftX, 414, columnW, 120, "③ 修改要求（可空，默认按表头含义替换）", false, false, true)
    CadAiField(ui, "result", rightX, 66, columnW, 250, "结果（x,y 文字，可手改）", false)
    CadAiField(ui, "report", rightX, 350, columnW, 184, "校验与核对", false, true, true)

    if FileExist(CadAiRequestPath)
        try CadAiEdits["request"].Value := FileRead(CadAiRequestPath, "UTF-8")

    ui["status"] := ModernPanelLabelAt(ui, leftX, 570, 860, 18, "", ModernPanelTextStyle(colors["secondary"], 9))
    tileW := (860 - 20) // 3
    ModernPanelTile(ui, leftX, 594, tileW, 38, "让 AI 处理", CadAiRun, true, Chr(0xE945))
    ModernPanelTile(ui, leftX + tileW + 10, 594, tileW, 38, "复制结果", CadAiCopyResult, true, Chr(0xE8C8))
    ModernPanelTile(ui, leftX + (tileW + 10) * 2, 594, tileW, 38, "写入中望 CAD（QW2P）", CadAiWriteBack, true, Chr(0xE70F))

    panel.OnEvent("Close", (*) => CadAiClose())
    panel.Show("w900 h648 Center")
}

; 一个带标题的输入框：浅灰描边卡片里嵌无边框 Edit
CadAiField(ui, key, x, y, w, h, title, canCapture, readOnly := false, wrap := false) {
    global CadAiEdits
    colors := ModernPanelColors()
    ModernPanelLabelAt(ui, x + 2, y + 4, w - 130, 20, title, ModernPanelTextStyle(colors["secondary"], 9, true))
    if canCapture
        ModernPanelTile(ui, x + w - 124, y, 124, 26, "从 CAD 取", CadAiStartCapture.Bind(key), true)
    ModernPanelLabelAt(ui, x, y + 30, w, h, "", ModernPanelDecorate(ModernPanelStyle(colors["tile"], colors["text"]), colors["tileBorder"]))
    options := "x" . (x + 8) . " y" . (y + 37) . " w" . (w - 16) . " h" . (h - 14) . " -E0x200 VScroll" . (wrap ? " +Wrap" : " -Wrap HScroll")
    if readOnly
        options .= " ReadOnly"
    CadAiEdits[key] := ui["gui"].AddEdit(options)
}

CadAiSetStatus(text) {
    global CadAiUi
    if !IsObject(CadAiUi)
        return
    CadAiUi["status"]["text"] := text
    ModernPanelInvalidate(CadAiUi)
}

CadAiDestroyWindow(ui) {
    try {
        ModernPanelReleaseCanvas(ui)
        ModernPanelRegistry().Delete(ui["gui"].Hwnd)
        ui["gui"].Destroy()
    }
}

CadAiClose() {
    global CadAiUi, CadAiEdits
    CadAiStopCapture()
    CadAiSaveRequest()
    CadAiSettingsClose()
    CadAiDestroyWindow(CadAiUi)
    CadAiUi := ""
    CadAiEdits := Map()
}

CadAiSaveRequest() {
    global CadAiEdits, CadAiRequestPath
    if !CadAiEdits.Has("request")
        return
    try {
        SplitPath(CadAiRequestPath, , &dir)
        DirCreate(dir)
        file := FileOpen(CadAiRequestPath, "w", "UTF-8-RAW")
        file.Write(CadAiEdits["request"].Value)
        file.Close()
    }
}

; ---------- 从 CAD 取文字：发 QW2，等它把结果写进剪贴板 ----------

CadAiStartCapture(key, *) {
    global CadAiCapture
    CadAiStopCapture()
    CadAiCapture := key
    OnClipboardChange(CadAiOnClipboard)
    SetTimer(CadAiStopCapture, -180000)
    CadAiSetStatus("请在 CAD 里框选文字并回车；取到后自动填入。")
    RunZwcadCommand("QW2", "取文字")
}

CadAiStopCapture() {
    global CadAiCapture
    if (CadAiCapture = "")
        return
    CadAiCapture := ""
    OnClipboardChange(CadAiOnClipboard, 0)
    SetTimer(CadAiStopCapture, 0)
}

CadAiOnClipboard(dataType) {
    global CadAiCapture, CadAiEdits, CadAiUi
    if (dataType != 1 || CadAiCapture = "")
        return
    text := A_Clipboard
    if !RegExMatch(text, "^-?[\d.]+,-?[\d.]+ ")
        return
    key := CadAiCapture
    CadAiStopCapture()
    CadAiEdits[key].Value := text
    count := StrSplit(Trim(text, "`r`n"), "`n").Length
    CadAiSetStatus("已取到 " . count . " 行文字。")
    try {
        CadAiUi["gui"].Show()
        WinActivate("ahk_id " . CadAiUi["gui"].Hwnd)
    }
}

; ---------- 调 AI：后台运行，窗口不卡 ----------

CadAiWriteFile(path, text) {
    file := FileOpen(path, "w", "UTF-8-RAW")
    file.Write(text)
    file.Close()
}

CadAiRun() {
    global CadAiEdits, CadAiJob, CadAiWorkDir
    title := "AI 改 CAD 文字"
    if IsObject(CadAiJob) {
        MsgBox("AI 还在处理上一次的请求，请稍等。", title, "Icon!")
        return
    }
    template := Trim(CadAiEdits["template"].Value, " `t`r`n")
    request := Trim(CadAiEdits["request"].Value, " `t`r`n")
    if (template = "") {
        MsgBox("请先填好模板文字。", title, "Icon!")
        return
    }
    CadAiSaveRequest()
    DirCreate(CadAiWorkDir)
    paths := Map()
    for name in ["template", "table", "request", "out", "report"]
        paths[name] := CadAiWorkDir . "\" . name . ".txt"
    for name in ["out", "report"]
        if FileExist(paths[name])
            FileDelete(paths[name])
    CadAiWriteFile(paths["template"], template)
    CadAiWriteFile(paths["table"], CadAiEdits["table"].Value)
    CadAiWriteFile(paths["request"], request)

    CadAiStartJob('--template "' . paths["template"] . '" --table "' . paths["table"] . '" --request "' . paths["request"]
        . '" --out "' . paths["out"] . '" --report "' . paths["report"] . '"', paths, "run")
}

; 参照表来自图片：剪贴板有图就用，否则选文件。识别结果填进参照表，核对后再让 AI 处理
CadAiReadImage() {
    global CadAiJob, CadAiWorkDir
    title := "图片识别"
    if IsObject(CadAiJob) {
        MsgBox("AI 还在处理上一次的请求，请稍等。", title, "Icon!")
        return
    }
    DirCreate(CadAiWorkDir)
    image := ""
    if (DllCall("IsClipboardFormatAvailable", "UInt", 2) || DllCall("IsClipboardFormatAvailable", "UInt", 8)) {
        image := CadAiWorkDir . "\table-image.png"
        if FileExist(image)
            FileDelete(image)
        command := "$i=Get-Clipboard -Format Image;if($i){$i.Save('" . image . "',[Drawing.Imaging.ImageFormat]::Png)}"
        RunWait('powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -Command "' . command . '"', , "Hide")
        if !FileExist(image) {
            MsgBox("读取剪贴板图片失败。", title, "Icon!")
            return
        }
    } else {
        image := FileSelect(1, , "选择表格图片", "图片 (*.png; *.jpg; *.jpeg; *.webp)")
        if (image = "")
            return
    }
    paths := Map("out", CadAiWorkDir . "\table-out.txt", "report", CadAiWorkDir . "\report.txt")
    for name in ["out", "report"]
        if FileExist(paths[name])
            FileDelete(paths[name])
    CadAiStartJob('--read-image "' . image . '" --out "' . paths["out"] . '" --report "' . paths["report"] . '"', paths, "image")
}

; 只发一句话测试接口，结果写进“校验与核对”
CadAiTest() {
    global CadAiJob, CadAiWorkDir
    if IsObject(CadAiJob) {
        MsgBox("AI 还在处理上一次的请求，请稍等。", "AI 设置", "Icon!")
        return
    }
    DirCreate(CadAiWorkDir)
    paths := Map("out", CadAiWorkDir . "\out.txt", "report", CadAiWorkDir . "\report.txt")
    for name in ["out", "report"]
        if FileExist(paths[name])
            FileDelete(paths[name])
    CadAiStartJob('--test --report "' . paths["report"] . '"', paths, "test")
}

CadAiStartJob(arguments, paths, kind) {
    global CadAiJob, CadAiEdits, CadAiWorkDir, CadAiConfigPath
    script := A_ScriptDir . "\..\tools\cad_ai_text.py"
    pid := 0
    try Run('python "' . script . '" ' . arguments . ' --config "' . CadAiConfigPath . '"', CadAiWorkDir, "Hide", &pid)
    catch as err {
        MsgBox("启动 Python 失败：" . err.Message, "AI 改 CAD 文字", "Icon!")
        return
    }
    CadAiJob := Map("pid", pid, "paths", paths, "started", A_TickCount, "kind", kind)
    if (kind = "run")
        CadAiEdits["result"].Value := ""
    CadAiEdits["report"].Value := ""
    SetTimer(CadAiPoll, 500)
}

CadAiPoll() {
    global CadAiJob, CadAiEdits
    job := CadAiJob
    if !IsObject(job) {
        SetTimer(CadAiPoll, 0)
        return
    }
    if ProcessExist(job["pid"]) {
        CadAiSetStatus("AI 处理中，已用 " . (A_TickCount - job["started"]) // 1000 . " 秒……通常半分钟左右。")
        return
    }
    SetTimer(CadAiPoll, 0)
    CadAiJob := ""
    if !CadAiEdits.Has("report")
        return
    paths := job["paths"]
    report := FileExist(paths["report"]) ? FileRead(paths["report"], "UTF-8") : "处理程序没有输出结果，请确认本机 Python 可用。"
    CadAiEdits["report"].Value := report
    if (job["kind"] = "test") {
        CadAiSetStatus("测试结束，结果见右下角。")
    } else if !FileExist(paths["out"]) {
        CadAiSetStatus("没有生成结果，原因见右下角。")
    } else if (job["kind"] = "image") {
        CadAiEdits["table"].Value := FileRead(paths["out"], "UTF-8")
        CadAiSetStatus("图片已识别到参照表，请逐项核对后再让 AI 处理。")
    } else {
        CadAiEdits["result"].Value := FileRead(paths["out"], "UTF-8")
        CadAiSetStatus("处理完成，用时 " . (A_TickCount - job["started"]) // 1000 . " 秒。核对后点“写入中望 CAD”。")
    }
}

; ---------- 交付结果 ----------

CadAiCopyResult() {
    global CadAiEdits
    text := Trim(CadAiEdits["result"].Value, " `t`r`n")
    if (text = "") {
        MsgBox("还没有结果。", "AI 改 CAD 文字", "Icon!")
        return
    }
    A_Clipboard := text
    CadAiSetStatus("结果已复制到剪贴板，可在 CAD 里运行 QW2P 写入。")
}

CadAiWriteBack() {
    global CadAiEdits
    text := Trim(CadAiEdits["result"].Value, " `t`r`n")
    if (text = "") {
        MsgBox("还没有结果。", "AI 改 CAD 文字", "Icon!")
        return
    }
    A_Clipboard := text
    CadAiSetStatus("已发送 QW2P：在 CAD 里指定第一行的位置。")
    RunZwcadCommand("QW2P", "写入文字")
}

; ---------- AI 设置：接口格式二选一，或用本机 Claude Code 登录 ----------

CadAiFormatDefault(format, name) {
    static defaults := Map("anthropic", Map("base_url", "https://api.anthropic.com", "model", "claude-sonnet-5-5")
        , "openai", Map("base_url", "https://api.openai.com/v1", "model", ""))
    return defaults[format][name]
}

CadAiProviderText() {
    global CadAiConfigPath
    provider := IniRead(CadAiConfigPath, "general", "provider", "claude_code")
    if (provider = "claude_code")
        return "当前 AI：Claude Code 登录"
    model := IniRead(CadAiConfigPath, provider, "model", CadAiFormatDefault(provider, "model"))
    return "当前 AI：" . (provider = "anthropic" ? "Anthropic 兼容" : "OpenAI 兼容") . " · " . model
}

; 用当前 Windows 账户加密，返回 Base64；只有同一台电脑的同一账户能解开
CadAiProtect(text) {
    size := StrPut(text, "UTF-8") - 1
    data := Buffer(size)
    StrPut(text, data, size, "UTF-8")
    source := Buffer(16, 0)
    NumPut("UInt", size, source, 0)
    NumPut("Ptr", data.Ptr, source, 8)
    target := Buffer(16, 0)
    if !DllCall("crypt32\CryptProtectData", "Ptr", source, "Ptr", 0, "Ptr", 0, "Ptr", 0, "Ptr", 0, "UInt", 1, "Ptr", target)
        throw OSError(A_LastError, "加密 API Key 失败。")
    length := NumGet(target, 0, "UInt")
    pointer := NumGet(target, 8, "Ptr")
    flags := 0x40000001   ; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
    chars := 0
    DllCall("crypt32\CryptBinaryToStringW", "Ptr", pointer, "UInt", length, "UInt", flags, "Ptr", 0, "UInt*", &chars)
    encoded := Buffer(chars * 2)
    DllCall("crypt32\CryptBinaryToStringW", "Ptr", pointer, "UInt", length, "UInt", flags, "Ptr", encoded, "UInt*", &chars)
    DllCall("LocalFree", "Ptr", pointer, "Ptr")
    return StrGet(encoded)
}

OpenCadAiSettings(*) {
    global CadAiSettingsUi, CadAiConfigPath, CadAiUi
    CadAiSettingsClose()
    colors := ModernPanelColors()
    ui := ModernPanelCreate("AI 设置", "-MinimizeBox -MaximizeBox +0x2000000 +Owner" . CadAiUi["gui"].Hwnd, true)
    panel := ui["gui"]
    panel.SetFont("s10", "Microsoft YaHei UI")
    CadAiSettingsUi := ui

    ModernPanelLabelAt(ui, 20, 14, 440, 26, "AI 设置", ModernPanelTextStyle(colors["text"], 13, true))
    ui["login"] := panel.AddCheckbox("x20 y50 w440", "使用本机 Claude Code 登录（不用填写下面的内容）")
    ModernPanelLabelAt(ui, 22, 84, 440, 20, "接口格式", ModernPanelTextStyle(colors["secondary"], 9, true))
    ui["anthropic"] := panel.AddRadio("x20 y106 w200 Group", "Anthropic 兼容")
    ui["openai"] := panel.AddRadio("x230 y106 w200", "OpenAI 兼容")
    CadAiSettingsField(ui, "url", 138, "请求地址", "")
    CadAiSettingsField(ui, "key", 204, "API Key", "Password")
    CadAiSettingsField(ui, "model", 270, "模型名称", "")
    ModernPanelLabelAt(ui, 22, 334, 436, 38, "API Key 用当前 Windows 账户加密，保存在本机，不进同步目录，也不会显示出来。"
        , ModernPanelTextStyle(colors["secondary"], 9, false, "left", true))

    format := IniRead(CadAiConfigPath, "general", "format", "anthropic")
    drafts := Map()
    for name in ["anthropic", "openai"] {
        url := IniRead(CadAiConfigPath, name, "base_url", "")
        model := IniRead(CadAiConfigPath, name, "model", "")
        drafts[name] := Map("url", url != "" ? url : CadAiFormatDefault(name, "base_url")
            , "model", model != "" ? model : CadAiFormatDefault(name, "model")
            , "key", "", "saved", IniRead(CadAiConfigPath, name, "api_key_dpapi", "") != "")
    }
    ui["drafts"] := drafts
    ui["format"] := ""
    ui["login"].Value := IniRead(CadAiConfigPath, "general", "provider", "claude_code") = "claude_code"
    ui[format].Value := 1
    CadAiSettingsLoad(ui, format)
    CadAiSettingsSyncEnabled(ui)

    ui["login"].OnEvent("Click", (*) => CadAiSettingsSyncEnabled(ui))
    ui["anthropic"].OnEvent("Click", (*) => CadAiSettingsLoad(ui, "anthropic"))
    ui["openai"].OnEvent("Click", (*) => CadAiSettingsLoad(ui, "openai"))

    tileW := 140
    ModernPanelTile(ui, 20, 380, tileW, 38, "保存", CadAiSettingsSave.Bind(false), true)
    ModernPanelTile(ui, 170, 380, tileW, 38, "保存并测试", CadAiSettingsSave.Bind(true), true)
    ModernPanelTile(ui, 320, 380, tileW, 38, "取消", CadAiSettingsClose, true)
    panel.OnEvent("Close", (*) => CadAiSettingsClose())
    panel.OnEvent("Escape", (*) => CadAiSettingsClose())
    panel.Show("w480 h434 Center")
}

CadAiSettingsField(ui, key, y, title, options) {
    colors := ModernPanelColors()
    ModernPanelLabelAt(ui, 22, y, 436, 20, title, ModernPanelTextStyle(colors["secondary"], 9, true))
    ModernPanelLabelAt(ui, 20, y + 24, 440, 34, "", ModernPanelDecorate(ModernPanelStyle(colors["tile"], colors["text"]), colors["tileBorder"]))
    ui[key] := ui["gui"].AddEdit("x30 y" . (y + 31) . " w420 h22 -E0x200 " . options)
}

; 切换格式时先记下当前填写的内容，两种格式的地址、Key、模型互不影响
CadAiSettingsStash(ui) {
    if (ui["format"] = "")
        return
    draft := ui["drafts"][ui["format"]]
    draft["url"] := Trim(ui["url"].Value)
    draft["model"] := Trim(ui["model"].Value)
    draft["key"] := Trim(ui["key"].Value)
}

CadAiSettingsLoad(ui, format) {
    CadAiSettingsStash(ui)
    ui["format"] := format
    draft := ui["drafts"][format]
    ui["url"].Value := draft["url"]
    ui["model"].Value := draft["model"]
    ui["key"].Value := draft["key"]
    SendMessage(0x1501, 1, StrPtr(draft["saved"] ? "已保存，留空保持不变" : "请填写 API Key"), ui["key"])  ; EM_SETCUEBANNER
}

CadAiSettingsSyncEnabled(ui) {
    enabled := !ui["login"].Value
    for key in ["anthropic", "openai", "url", "key", "model"]
        ui[key].Enabled := enabled
}

CadAiSettingsSave(thenTest, *) {
    global CadAiSettingsUi, CadAiConfigPath, CadAiUi
    ui := CadAiSettingsUi
    CadAiSettingsStash(ui)
    format := ui["format"]
    useLogin := ui["login"].Value
    if !useLogin {
        draft := ui["drafts"][format]
        problem := draft["url"] = "" ? "请填写请求地址。" : draft["model"] = "" ? "请填写模型名称。"
            : (draft["key"] = "" && !draft["saved"]) ? "请填写 API Key。" : ""
        if (problem != "") {
            MsgBox(problem, "AI 设置", "Icon! Owner" . ui["gui"].Hwnd)
            return
        }
    }
    if !FileExist(CadAiConfigPath) {
        SplitPath(CadAiConfigPath, , &dir)
        DirCreate(dir)
        FileAppend("", CadAiConfigPath, "UTF-16")   ; 先建 UTF-16 文件，IniWrite 才能保存非 ASCII 字符
    }
    IniWrite(useLogin ? "claude_code" : format, CadAiConfigPath, "general", "provider")
    IniWrite(format, CadAiConfigPath, "general", "format")
    for name, draft in ui["drafts"] {
        IniWrite(draft["url"], CadAiConfigPath, name, "base_url")
        IniWrite(draft["model"], CadAiConfigPath, name, "model")
        if (draft["key"] != "")
            IniWrite(CadAiProtect(draft["key"]), CadAiConfigPath, name, "api_key_dpapi")
    }
    CadAiSettingsClose()
    if IsObject(CadAiUi) {
        CadAiUi["provider"]["text"] := CadAiProviderText()
        CadAiSetStatus("AI 设置已保存。")
    }
    if thenTest
        CadAiTest()
}

CadAiSettingsClose(*) {
    global CadAiSettingsUi
    if !IsObject(CadAiSettingsUi)
        return
    ui := CadAiSettingsUi
    CadAiSettingsUi := ""
    CadAiDestroyWindow(ui)
}
