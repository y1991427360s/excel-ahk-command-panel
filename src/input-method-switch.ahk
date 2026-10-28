#Requires AutoHotkey v2.0

; 默认输入法即“设置 → 时间和语言 → 输入 → 高级键盘设置 → 替代默认输入法”。
; 读取直接走注册表（打开面板时不启动 PowerShell），写入调用系统 Set-WinDefaultInputMethodOverride，
; 与设置页面的效果一致；只影响之后新打开的窗口，已打开窗口的当前输入法不变。
InputMethodProfileKey := "HKCU\Control Panel\International\User Profile"

GetDefaultInputMethodOverride() {
    global InputMethodProfileKey
    try return RegRead(InputMethodProfileKey, "InputMethodOverride")
    return ""
}

; 列出每种已安装语言的输入法：先按语言列表（Win+空格）顺序列出已添加的，
; 再补上系统里已注册、但还没加入语言列表的输入法（例如刚装好的豆包输入法），added 为 false。
; 每次打开面板都重新读取，装上或卸载输入法后列表自动跟着变化。
; 返回 [Map("tip", "0804:{...}{...}", "name", "简体中文(中国大陆) - 微信输入法", "language", "zh-Hans-CN", "added", true)]
GetInstalledInputMethods() {
    global InputMethodProfileKey
    methods := []
    try languages := RegRead(InputMethodProfileKey, "Languages")
    catch
        return methods

    for language in StrSplit(languages, "`n") {
        if (language = "")
            continue
        languageKey := InputMethodProfileKey . "\" . language
        languageName := language
        try languageName := LoadIndirectString(RegRead(languageKey, "CachedLanguageName"))

        entries := []
        listed := Map()
        listed.CaseSense := false
        loop reg, languageKey, "V" {
            if !RegExMatch(A_LoopRegName, "^[0-9A-Fa-f]{4}:")
                continue
            entries.Push(Map("tip", A_LoopRegName, "order", RegRead() + 0))
            listed[A_LoopRegName] := true
        }
        ; 语言内的输入法数量很少，用插入排序保持设置页里的顺序。
        loop entries.Length - 1 {
            i := A_Index + 1
            current := entries[i]
            while (i > 1 && entries[i - 1]["order"] > current["order"]) {
                entries[i] := entries[i - 1]
                i -= 1
            }
            entries[i] := current
        }
        for entry in entries
            methods.Push(Map("tip", entry["tip"], "name", languageName . " - " . GetInputMethodName(entry["tip"])
                , "language", language, "added", true))

        for tip in GetRegisteredInputMethodTips(language) {
            if !listed.Has(tip)
                methods.Push(Map("tip", tip, "name", languageName . " - " . GetInputMethodName(tip)
                    , "language", language, "added", false))
        }
    }
    return methods
}

; 系统中为该语言注册的全部文字服务输入法（HKLM\SOFTWARE\Microsoft\CTF\TIP），GUID 统一转大写以便和语言列表比较。
GetRegisteredInputMethodTips(language) {
    tips := []
    lcid := DllCall("LocaleNameToLCID", "WStr", language, "UInt", 0, "UInt")
    if !lcid
        return tips
    langId := Format("{:04X}", lcid & 0xFFFF)
    loop reg, "HKLM\SOFTWARE\Microsoft\CTF\TIP", "K" {
        clsid := A_LoopRegName
        loop reg, "HKLM\SOFTWARE\Microsoft\CTF\TIP\" . clsid . "\LanguageProfile\0x0000" . langId, "K"
            tips.Push(StrUpper(langId . ":" . clsid . A_LoopRegName))
    }
    return tips
}

GetInputMethodName(tip) {
    if !RegExMatch(tip, "^([0-9A-Fa-f]{4}):(\{[0-9A-Fa-f-]{36}\})(\{[0-9A-Fa-f-]{36}\})$", &match)
        return "键盘 " . SubStr(tip, 6)
    profileKey := "HKLM\SOFTWARE\Microsoft\CTF\TIP\" . match[2] . "\LanguageProfile\0x0000" . match[1] . "\" . match[3]
    try return LoadIndirectString(RegRead(profileKey, "Display Description"))
    try return RegRead(profileKey, "Description")
    return match[2]
}

; 把 “@C:\WINDOWS\system32\wetype_tip.dll,-102” 这类资源引用解析成本地化名称。
LoadIndirectString(source) {
    if (SubStr(source, 1, 1) != "@")
        return source
    output := Buffer(1024, 0)
    if DllCall("Shlwapi\SHLoadIndirectString", "WStr", source, "Ptr", output, "UInt", 512, "Ptr", 0) != 0
        throw Error("无法解析：" . source)
    return StrGet(output, "UTF-16")
}

; tip 为空表示“使用语言列表(推荐)”，即清除替代默认输入法。
; addToLanguage 非空时，先把该输入法加入这种语言的输入法列表（等同设置里“添加键盘”），再设为默认。
SetDefaultInputMethod(tip, name, addToLanguage := "") {
    global AutomationPanelGui
    title := "替代默认输入法"
    if (tip != "" && !RegExMatch(tip, "^[0-9A-Fa-f]{4}:[0-9A-Fa-f{}-]+$")
        || addToLanguage != "" && !RegExMatch(addToLanguage, "^[A-Za-z0-9-]+$")) {
        MsgBox("输入法标识无效：" . tip, title, "Icon!")
        return
    }

    command := "$ErrorActionPreference='Stop'; "
    if (addToLanguage != "")
        command .= "$list = Get-WinUserLanguageList; "
            . "($list | Where-Object LanguageTag -eq '" . addToLanguage . "').InputMethodTips.Add('" . tip . "'); "
            . "Set-WinUserLanguageList $list -Force; "
    command .= tip = "" ? "Set-WinDefaultInputMethodOverride" : "Set-WinDefaultInputMethodOverride -InputTip '" . tip . "'"
    try exitCode := RunWait('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' . command . '"', , "Hide")
    catch as err {
        MsgBox("无法启动 PowerShell：`n" . err.Message, title, "Icon!")
        return
    }

    if (exitCode != 0 || GetDefaultInputMethodOverride() != tip) {
        MsgBox("切换失败，当前设置未改变为“" . name . "”。`nPowerShell 退出码：" . exitCode, title, "Icon!")
        return
    }
    if IsObject(AutomationPanelGui)
        try AutomationPanelGui.Hide()
    TrayTip((addToLanguage != "" ? "已添加到输入法列表，并" : "") . "默认输入法已改为：" . name
        . "`n之后新打开的窗口生效。", title, "Iconi Mute")
}
