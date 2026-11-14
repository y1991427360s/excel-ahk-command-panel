; 自定义快捷键冒烟测试：校验规则、注册/注销、两个面板各自的配置与设置窗口、托盘兜底、面板“快捷键”页。
; 运行前把 LOCALAPPDATA 指到临时目录并删掉旧配置，避免读写真实配置，例如（PowerShell）：
;   $env:LOCALAPPDATA = "$env:TEMP\hotkey-smoke"; & "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut tests\custom-hotkeys-smoke.ahk
; 会短暂弹出面板窗口；不连接 Excel / CAD。
#Warn All, StdOut
#Include ..\src\excel-command-panel.ahk

RunCustomHotkeySmoke()

RunCustomHotkeySmoke() {
    global CustomHotkeyBindings, AutomationPanelGui, AutomationPanelUi, AutomationPanel2Ui, CustomHotkeyWindow
    exitCode := 0
    try {
        Sleep(200)   ; 让 2号面板的延后初始化先跑完
        mainPath := CustomHotkeyConfigPath()
        panel2Path := CustomHotkeyScope("panel2")["configPath"]
        HotkeyAssert(InStr(mainPath, "hotkey-smoke") && InStr(panel2Path, "hotkey-smoke"), "必须在临时 LOCALAPPDATA 下运行：" . mainPath)
        HotkeyAssert(!FileExist(mainPath) && !FileExist(panel2Path), "运行前请删除临时目录里的旧配置")

        ; 默认入口
        HotkeyAssert(CustomHotkeyBindings.Count = 2, "没有配置时只有两个面板入口，实际 " . CustomHotkeyBindings.Count)
        HotkeyAssert(CustomHotkeyBindings["panel.open"] = "^+e" && AutomationPanelHotkeyText() = "Ctrl+Shift+E", "自动化面板默认 Ctrl+Shift+E")
        HotkeyAssert(CustomHotkeyBindings["panel2.open"] = "!q" && Panel2HotkeyText() = "Alt+Q", "2号面板默认 Alt+Q")

        ; 两个面板的功能清单互不包含
        mainIds := Map()
        for command in CustomHotkeyScope("main")["commands"].Call() {
            HotkeyAssert(!mainIds.Has(command["id"]), "功能 id 重复：" . command["id"])
            HotkeyAssert(HasMethod(command["callback"]), "回调不可调用：" . command["id"])
            HotkeyAssert(!InStr(command["id"], "panel2") && !InStr(command["name"], "2号"), "自动化面板清单不应含 2号面板的项：" . command["id"])
            HotkeyAssert(!(command["name"] ~= "MP4 转 GIF|压缩视频|HTML 转 PDF"), "自动化面板清单不应含已移走的功能：" . command["name"])
            mainIds[command["id"]] := true
        }
        panel2Commands := CustomHotkeyScope("panel2")["commands"].Call()
        HotkeyAssert(panel2Commands[1]["id"] = "panel2.open", "2号面板清单第一项是入口")
        for command in panel2Commands
            HotkeyAssert(!mainIds.Has(command["id"]), "2号面板与自动化面板 id 重复：" . command["id"])

        ; 校验规则
        HotkeyAssert(InStr(CustomHotkeyValidate("^+e", "table.merge"), "打开自动化面板"), "Ctrl+Shift+E 已被自动化面板入口占用")
        HotkeyAssert(InStr(CustomHotkeyValidate("!q", "table.merge"), "2号自动化面板的"), "跨面板冲突要说明是哪个面板")
        HotkeyAssert(CustomHotkeyValidate("^z") != "", "Ctrl+Z 保留给 Excel 撤销")
        HotkeyAssert(CustomHotkeyValidate("m") != "", "单个字母不能作快捷键")
        HotkeyAssert(CustomHotkeyValidate("+m") != "", "只带 Shift 不能作快捷键")
        HotkeyAssert(CustomHotkeyValidate("F9") = "", "F9 可单独使用")
        HotkeyAssert(CustomHotkeyDisplay("^!m") = "Ctrl+Alt+M", "显示格式 Ctrl+Alt+M")
        HotkeyAssert(CustomHotkeyDisplay("#+F11") = "Shift+Win+F11", "显示格式 Shift+Win+F11")

        ; 各自保存到各自的配置文件
        HotkeyAssert(CustomHotkeyRebind("table.merge", "^!F11") = "", "注册 Ctrl+Alt+F11")
        HotkeyAssert(CustomHotkeyRebind("panel2.gif", "^!F10") = "", "2号面板 MP4 转 GIF 注册 Ctrl+Alt+F10")
        HotkeyAssert(CustomHotkeyRebind("panel2.open", "^!F8") = "", "2号面板入口改为 Ctrl+Alt+F8")
        CustomHotkeySave("main")
        CustomHotkeySave("panel2")
        mainText := FileRead(mainPath)
        panel2Text := FileRead(panel2Path)
        HotkeyAssert(InStr(mainText, "table.merge=^!F11") && InStr(mainText, "panel.open=^+e"), "自动化面板配置：" . mainText)
        HotkeyAssert(!InStr(mainText, "panel2"), "自动化面板配置不含 2号面板：" . mainText)
        HotkeyAssert(InStr(panel2Text, "panel2.open=^!F8") && InStr(panel2Text, "panel2.gif=^!F10") && !InStr(panel2Text, "table."), "2号面板配置：" . panel2Text)
        HotkeyAssert(Panel2HotkeyText() = "Ctrl+Alt+F8", "2号面板入口显示随之改变")
        HotkeyAssert(CustomHotkeyValidate("!q", "table.split") = "", "Alt+Q 释放后可分配")
        HotkeyAssert(InStr(CustomHotkeyRebind("table.split", "^!F11"), "合并相同内容并居中"), "冲突时改绑失败")
        HotkeyAssert(!CustomHotkeyBindings.Has("table.split"), "改绑失败不留下半截绑定")
        HotkeyAssert(CustomHotkeyAssignedList("main").Length = 2 && CustomHotkeyAssignedList("panel2").Length = 2, "已设置列表按面板分开")

        ; 重新读取：配置无效时入口回退默认，其他面板的 id 写进来也会被忽略
        for id in ["table.merge", "panel.open", "panel2.open", "panel2.gif"]
            CustomHotkeyUnregister(id)
        HotkeyAssert(CustomHotkeyBindings.Count = 0, "注销后清空")
        IniWrite("^!F7", mainPath, "Hotkeys", "panel2.gif")      ; 2号面板的 id 写进自动化面板配置：忽略
        IniWrite("m", panel2Path, "Hotkeys", "panel2.open")       ; 无效：回退 Alt+Q
        CustomHotkeysInit("main")
        CustomHotkeysInit("panel2")
        HotkeyAssert(CustomHotkeyBindings["panel.open"] = "^+e" && CustomHotkeyBindings["table.merge"] = "^!F11", "自动化面板重新读取")
        HotkeyAssert(CustomHotkeyBindings["panel2.open"] = "!q", "2号面板无效配置回退 Alt+Q")
        HotkeyAssert(CustomHotkeyBindings["panel2.gif"] = "^!F10", "2号面板从自己的配置读取，不受自动化面板配置影响")
        CustomHotkeySave("main")
        CustomHotkeySave("panel2")

        ; 托盘兜底
        HotkeyAssert(A_TrayMenu.Default = "打开自动化面板", "托盘默认项是打开自动化面板")
        HotkeyAssert(InStr(A_IconTip, "自动化面板：Ctrl+Shift+E") && InStr(A_IconTip, "2号自动化面板：Alt+Q"), "托盘提示：" . A_IconTip)
        HotkeyAssert(CustomHotkeyRebind("panel.open", "#!q") = "", "自动化面板入口改为 Win+Alt+Q")
        HotkeyAssert(CustomHotkeyRebind("table.split", "^+e") = "", "Ctrl+Shift+E 分给拆分")
        CustomHotkeyRestorePanelDefault()
        HotkeyAssert(CustomHotkeyBindings["panel.open"] = "^+e" && !CustomHotkeyBindings.Has("table.split"), "托盘恢复默认并清掉占用者")
        HotkeyAssert(IniRead(mainPath, "Hotkeys", "panel.open") = "^+e", "恢复默认已保存")

        ; 两个设置窗口各列各的
        OpenCustomHotkeyWindow()
        mainList := ListViewGetContent("", "SysListView321", "ahk_id " . CustomHotkeyWindow.Hwnd)
        HotkeyAssert(InStr(mainList, "打开自动化面板") && InStr(mainList, "Ctrl+Alt+F11") && !InStr(mainList, "2号"), "自动化面板设置窗口只列自己的功能")
        OpenCustomHotkeyWindow("panel2")
        HotkeyAssert(InStr(WinGetTitle("ahk_id " . CustomHotkeyWindow.Hwnd), "2号自动化面板"), "切换为 2号面板设置窗口")
        panel2List := ListViewGetContent("", "SysListView321", "ahk_id " . CustomHotkeyWindow.Hwnd)
        HotkeyAssert(InStr(panel2List, "打开 2号自动化面板") && InStr(panel2List, "Ctrl+Alt+F10") && !InStr(panel2List, "合并相同内容"), "2号面板设置窗口只列自己的功能")
        WinClose("ahk_id " . CustomHotkeyWindow.Hwnd)
        Sleep(200)
        HotkeyAssert(!IsObject(CustomHotkeyWindow), "关闭后窗口变量清空")

        ; 两个面板的“快捷键”页
        ShowAutomationPanel()
        Sleep(200)
        texts := HotkeyPageText(AutomationPanelUi, "hotkeys")
        HotkeyAssert(InStr(texts, "已设置（2 个）") && InStr(texts, "打开自动化面板") && !InStr(texts, "2号"), "自动化面板快捷键页：" . texts)
        panel1Hwnd := AutomationPanelGui.Hwnd
        Panel2Build("hotkeys")
        Sleep(200)
        texts := HotkeyPageText(AutomationPanel2Ui, "hotkeys")
        HotkeyAssert(InStr(texts, "已设置（2 个）") && InStr(texts, "打开 2号自动化面板") && InStr(texts, "Alt+Q") && InStr(texts, "MP4 转 GIF"), "2号面板快捷键页：" . texts)
        HotkeyAssert(!WinExist("ahk_id " . panel1Hwnd), "打开 2号面板时自动化面板被关闭")

        for id in ["table.merge", "panel2.gif"]
            CustomHotkeyUnregister(id)
        FileAppend("custom-hotkeys-smoke 通过`n", "*", "UTF-8")
    } catch as err {
        FileAppend("custom-hotkeys-smoke 失败：" . err.Message . "`n", "*", "UTF-8")
        exitCode := 1
    }
    ExitApp(exitCode)
}

HotkeyPageText(ui, page) {
    texts := ""
    for element in ui["elements"]
        if (element["page"] = page)
            texts .= element["text"] . "|"
    return texts
}

HotkeyAssert(condition, message) {
    if !condition
        throw Error(message)
}
