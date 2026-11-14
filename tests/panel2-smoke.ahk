; 2号自动化面板冒烟测试：快捷方式增删排序、双击打开、页面内容，以及自动化面板已移走的按钮。
; 运行前把 LOCALAPPDATA 指到临时目录，避免读写真实清单，例如（PowerShell）：
;   $env:LOCALAPPDATA = "$env:TEMP\panel2-smoke"; & "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut tests\panel2-smoke.ahk
; 会短暂弹出面板窗口；不连接 Excel / CAD。
#Warn All, StdOut
#Include ..\src\excel-command-panel.ahk

RunPanel2Smoke()

RunPanel2Smoke() {
    global AutomationPanel2Ui, AutomationPanel2Gui, AutomationPanelUi, AutomationPanelGui, AutomationSelectedFilePaths
    exitCode := 0
    work := A_Temp . "\panel2-smoke-work"
    try {
        P2Assert(InStr(Panel2ShortcutsPath(), "panel2-smoke"), "必须在临时 LOCALAPPDATA 下运行，当前清单路径：" . Panel2ShortcutsPath())
        try FileDelete(Panel2ShortcutsPath())
        try DirDelete(work, true)
        DirCreate(work . "\常用目录A")
        marker := work . "\opened.txt"
        FileAppend('FileAppend("ok", "' . marker . '")`n', work . "\打开测试.ahk", "UTF-8")
        FileAppend("", work . "\第二个软件.lnk")
        AutomationSelectedFilePaths := []

        Panel2AddPaths([work . "\常用目录A\", work . "\打开测试.ahk"])
        items := Panel2LoadShortcuts()
        P2Assert(items.Length = 2, "添加后 2 条，实际 " . items.Length)
        P2Assert(items[1]["type"] = "folder" && items[1]["name"] = "常用目录A" && items[1]["path"] = work . "\常用目录A", "文件夹条目：" . items[1]["path"])
        P2Assert(items[2]["type"] = "app" && items[2]["name"] = "打开测试", "软件条目去掉扩展名")
        Panel2AddPaths([work . "\常用目录A", work . "\第二个软件.lnk"])
        items := Panel2LoadShortcuts()
        P2Assert(items.Length = 3, "重复路径跳过，实际 " . items.Length)
        P2Assert(InStr(AutomationPanel2Ui["infoTitle"]["text"], "已添加 1 个，1 个已在列表里"), "添加结果提示：" . AutomationPanel2Ui["infoTitle"]["text"])
        raw := FileRead(Panel2ShortcutsPath(), "RAW")
        P2Assert(NumGet(raw, 0, "UChar") = 0xEF && NumGet(raw, 1, "UChar") = 0xBB && NumGet(raw, 2, "UChar") = 0xBF, "清单为带 BOM 的 UTF-8")

        Panel2MoveShortcut(items[3], -1)
        items := Panel2LoadShortcuts()
        P2Assert(items[2]["name"] = "第二个软件" && items[3]["name"] = "打开测试", "前移只在同类型之间调整顺序")
        Panel2MoveShortcut(items[2], 1)
        items := Panel2LoadShortcuts()
        P2Assert(items[2]["name"] = "打开测试", "后移恢复顺序")

        Panel2Build("apps")
        Sleep(300)
        appsText := P2PageText(AutomationPanel2Ui, "apps")
        P2Assert(InStr(appsText, "常用软件（2）") && InStr(appsText, "打开测试") && InStr(appsText, "第二个软件"), "软件页：" . appsText)
        P2Assert(InStr(P2PageText(AutomationPanel2Ui, "folders"), "常用目录A"), "文件夹页显示条目")
        filesText := P2PageText(AutomationPanel2Ui, "files")
        P2Assert(InStr(filesText, "MP4 转 GIF") && InStr(filesText, "压缩视频") && InStr(filesText, "HTML 转 PDF"), "2号面板文件处理页：" . filesText)
        P2Assert(InStr(P2PageText(AutomationPanel2Ui, "ime"), "使用语言列表"), "2号面板有默认输入法页")

        ; 按住拖动：第一张卡片拖到第二张的位置，松手后顺序保存
        grid := AutomationPanel2Ui["grids"]["apps"]
        firstName := grid["tiles"][1]["text"], secondName := grid["tiles"][2]["text"]
        scale := A_ScreenDPI / 96
        dragHwnd := AutomationPanel2Gui.Hwnd
        P(x, y) => (Round(y * scale) << 16) | (Round(x * scale) & 0xFFFF)
        from := grid["tiles"][1], to := grid["tiles"][2]
        sx := from["x"] + 30, sy := from["y"] + 20, ex := to["x"] + 40, ey := to["y"] + 20
        SendMessage(0x201, 1, P(sx, sy), , "ahk_id " . dragHwnd)
        loop 8
            SendMessage(0x200, 1, P(sx + (ex - sx) * A_Index / 8, sy + (ey - sy) * A_Index / 8), , "ahk_id " . dragHwnd)
        SendMessage(0x202, 0, P(ex, ey), , "ahk_id " . dragHwnd)
        Sleep(500)
        order := []
        for item in Panel2LoadShortcuts()
            if (item["type"] = "app")
                order.Push(item["name"])
        P2Assert(order[1] = secondName && order[2] = firstName, "拖动后顺序已保存：" . order[1] . "," . order[2])
        P2Assert(Panel2LoadShortcuts()[1]["type"] = "folder", "拖动只调整同类型条目的顺序")
        P2Assert(grid["tiles"][1]["x"] = Panel2SlotPosition(grid, 1)[1] && grid["tiles"][2]["y"] = Panel2SlotPosition(grid, 2)[2], "卡片落回格子")

        ; 搜索：名称、拼音首字母、路径；筛选后匹配卡片补到前面，其余隐藏，暂停拖动
        P2Assert(Panel2PinyinInitials("华润伊吾") = "hryw" && Panel2PinyinInitials("东圣Oracle") = "dsoracle", "拼音首字母：" . Panel2PinyinInitials("华润伊吾"))
        search := AutomationPanel2Ui["search"]
        P2Assert(search.Visible, "常用软件页显示搜索框")
        P2Search(text) {
            search.Value := text
            Panel2OnSearchChange(search)
            Sleep(300)
            names := ""
            for tile in AutomationPanel2Ui["grids"]["apps"]["tiles"]
                if !tile["hidden"]
                    names .= tile["text"] . "|"
            return names
        }
        P2Assert(P2Search("打开") = "打开测试|", "按名称搜索")
        P2Assert(P2Search("dkcs") = "打开测试|", "按拼音首字母搜索")
        P2Assert(P2Search("deg r") = "第二个软件|", "多个词都要命中（拼音 deg + r）")
        P2Assert(P2Search("panel2-smoke") = "第二个软件|打开测试|", "按路径搜索")
        P2Assert(P2Search("q") = "", "无匹配时全部隐藏")
        P2Assert(!AutomationPanel2Ui["emptyHints"]["apps"]["hidden"], "没有结果时显示提示")
        P2Search("第二")
        visibleTile := AutomationPanel2Ui["selectedTile"]
        P2Assert(visibleTile["text"] = "第二个软件" && visibleTile["x"] = Panel2SlotPosition(AutomationPanel2Ui["grids"]["apps"], 1)[1]
            && visibleTile["y"] = Panel2SlotPosition(AutomationPanel2Ui["grids"]["apps"], 1)[2], "唯一结果补到第一格并自动选中")
        P2Assert(!visibleTile.Has("dragGroup"), "搜索时暂停拖动排序")
        P2Assert(AutomationPanel2Ui["infoTitle"]["text"] = "第二个软件", "顶部显示选中结果")
        Panel2ClearSearch()
        Sleep(300)
        P2Assert(P2Search("") = "第二个软件|打开测试|" && AutomationPanel2Ui["grids"]["apps"]["tiles"][1].Has("dragGroup"), "清空后恢复全部并可拖动")
        Panel2SelectPage(AutomationPanel2Ui, "files")
        P2Assert(!search.Visible, "其他页面不显示搜索框")
        Panel2SelectPage(AutomationPanel2Ui, "apps")
        Sleep(300)

        ; 集合：存档往返、移入 / 移出、去重、搜索成员、展开列表、快捷键清单
        items := Panel2LoadShortcuts()
        items.Push(Map("type", "app", "name", "工作集合", "path", "group:smoke1", "members", []))
        Panel2SaveShortcuts(items)
        Panel2Build("apps", true)
        groupKey := Map("type", "app", "path", "group:smoke1")
        group := Panel2FindGroup(groupKey)
        P2Assert(IsObject(group) && group["name"] = "工作集合" && group["members"].Length = 0, "空集合存档往返")
        secondPath := work . "\第二个软件.lnk"
        Panel2MoveIntoGroup(Panel2MemberItem(secondPath), group)
        group := Panel2FindGroup(groupKey)
        P2Assert(group["members"].Length = 1 && group["members"][1] = secondPath, "移入集合")
        topNames := ""
        for item in Panel2LoadShortcuts()
            topNames .= item["name"] . "|"
        P2Assert(!InStr(topNames, "第二个软件"), "移入后不再单独显示：" . topNames)
        P2Assert(InStr(FileRead(Panel2ShortcutsPath(), "UTF-8"), "group:smoke1`t`t" . secondPath), "集合成员写在第 5 列")
        Panel2AddPaths([secondPath])
        P2Assert(Panel2LoadShortcuts().Length = 3, "集合里已有的路径不重复添加")
        P2Assert(InStr(P2PageText(AutomationPanel2Ui, "apps"), "工作集合"), "集合卡片显示")
        search := AutomationPanel2Ui["search"]   ; 重建后搜索框是新控件
        P2Assert(P2Search("deg") = "工作集合|", "搜索成员名命中集合")
        Panel2ClearSearch()
        Panel2GroupPopup(group)
        Sleep(100)
        P2Assert(Panel2PopupIsOpen(), "展开列表打开")
        popText := P2PageText(Panel2Popup, "")
        P2Assert(InStr(popText, "第二个软件") && !InStr(popText, "全部打开") && InStr(popText, "|添加|"), "集合方框内容：" . popText)
        Panel2PopupClose()
        memberId := Panel2ShortcutHotkeyId(Panel2MemberItem(secondPath))
        commandNames := ""
        for command in CustomHotkeyScope("panel2")["commands"].Call()
            if (command["id"] = memberId || command["id"] = Panel2ShortcutHotkeyId(group))
                commandNames .= command["name"] . "|"
        P2Assert(!InStr(commandNames, "打开集合") && InStr(commandNames, "打开 第二个软件（工作集合）"), "快捷键清单只含成员、不含集合本身：" . commandNames)
        Panel2RemoveFromGroup(group, secondPath)
        Sleep(100)
        Panel2PopupClose()
        group := Panel2FindGroup(groupKey)
        P2Assert(group["members"].Length = 0 && Panel2FindPath(Panel2LoadShortcuts(), secondPath), "移出后放回列表")
        items := Panel2LoadShortcuts()
        items.RemoveAt(Panel2IndexOf(items, groupKey))
        Panel2SaveShortcuts(items)
        Panel2Build("apps", true)
        Sleep(300)
        search := AutomationPanel2Ui["search"]
        P2Assert(P2Search("") = "打开测试|第二个软件|", "移出的成员排在集合后面：" . P2Search(""))

        ; 单击选中显示路径，双击打开（.ahk 由 AutoHotkey 运行，写出标记文件）
        tile := ""
        for element in AutomationPanel2Ui["shortcutTiles"]
            if (element["text"] = "打开测试")
                tile := element
        P2Assert(IsObject(tile), "找到“打开测试”磁贴")
        scale := A_ScreenDPI / 96
        lParam := (Round((tile["y"] + tile["h"] / 2) * scale) << 16) | Round((tile["x"] + tile["w"] / 2) * scale)
        hwnd := AutomationPanel2Gui.Hwnd
        PostMessage(0x201, 1, lParam, , "ahk_id " . hwnd)
        PostMessage(0x202, 0, lParam, , "ahk_id " . hwnd)
        Sleep(150)
        P2Assert(AutomationPanel2Ui["infoTitle"]["text"] = "打开测试" && InStr(AutomationPanel2Ui["infoDetail"]["text"], "打开测试.ahk"), "单击后顶部显示路径")
        P2Assert(!FileExist(marker), "单击不打开")
        PostMessage(0x201, 1, lParam, , "ahk_id " . hwnd)
        PostMessage(0x202, 0, lParam, , "ahk_id " . hwnd)
        deadline := A_TickCount + 6000
        while (!FileExist(marker) && A_TickCount < deadline)
            Sleep(100)
        P2Assert(FileExist(marker), "双击打开了快捷方式")
        P2Assert(!DllCall("IsWindowVisible", "Ptr", hwnd), "打开后面板隐藏")

        ; 自动化面板里已移走：默认输入法页、MP4 转 GIF、压缩视频、HTML 转 PDF
        ; 常用软件可在 2号面板的快捷键清单里单独绑定，id 只看类型和路径（改名不变）
        appItem := ""
        for item in Panel2LoadShortcuts()
            if (item["name"] = "打开测试")
                appItem := item
        hotkeyId := Panel2ShortcutHotkeyId(appItem)
        renamed := appItem.Clone(), renamed["name"] := "改过的名字"
        P2Assert(Panel2ShortcutHotkeyId(renamed) = hotkeyId, "改名后快捷键 id 不变")
        found := ""
        for command in CustomHotkeyScope("panel2")["commands"].Call()
            if (command["id"] = hotkeyId)
                found := command
        P2Assert(IsObject(found) && found["name"] = "打开 打开测试" && found["noContext"], "常用软件出现在 2号面板快捷键清单")
        P2Assert(!IsObject(CustomHotkeyFindCommand(hotkeyId, "main")), "自动化面板清单里没有常用软件")

        panel2Hwnd := AutomationPanel2Gui.Hwnd
        ShowAutomationPanel()
        Sleep(200)
        P2Assert(!WinExist("ahk_id " . panel2Hwnd), "打开自动化面板时 2号面板被关闭")
        panel1Text := P2PageText(AutomationPanelUi, "")
        for removed in ["MP4 转 GIF", "压缩视频|", "HTML 转 PDF", "使用语言列表"]
            P2Assert(!InStr(panel1Text, removed), "自动化面板不应再有：" . removed)
        for item in AutomationPanelPages()
            P2Assert(item["key"] != "ime", "自动化面板不应再有默认输入法页")
        P2Assert(InStr(panel1Text, "找出最新版本") && InStr(panel1Text, "PPT 转 PDF"), "自动化面板其余文件功能还在")
        AutomationPanelGui.Destroy()

        FileAppend("panel2-smoke 通过`n", "*", "UTF-8")
    } catch as err {
        FileAppend("panel2-smoke 失败：" . err.Message . "`n", "*", "UTF-8")
        exitCode := 1
    }
    try DirDelete(work, true)
    ExitApp(exitCode)
}

; 收集某页（page 为空则全部页）元素文字。
P2PageText(ui, page) {
    texts := ""
    for element in ui["elements"]
        if (page = "" || element["page"] = page)
            texts .= element["text"] . "|"
    return texts
}

P2Assert(condition, message) {
    if !condition
        throw Error(message)
}
