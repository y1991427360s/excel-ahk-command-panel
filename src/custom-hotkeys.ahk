; ===== 自定义快捷键 =====
; 给面板里的功能按钮绑定全局快捷键：按下时先像打开面板一样读取一次当前窗口选区快照，
; 再直接执行对应功能，不弹出面板。
;
; 按“作用域”分开管理：每个面板一个作用域，各有自己的功能清单、配置文件、入口快捷键和设置窗口，互不出现在对方的设置里。
; 本文件只定义自动化面板（"main"，配置 hotkeys.ini，入口 panel.open 默认 Ctrl+Shift+E）。
; 其他面板（如个人用的 2号自动化面板）在自己的文件里调用 CustomHotkeyAddScope 登记，本文件不引用它们。
; 所有作用域共用同一张绑定表：同一进程里一个组合键只能分给一个功能。
; 新增自动化面板按钮时，同时在 CustomHotkeyCommands() 里登记，才能被绑定快捷键。

global CustomHotkeyBindings := Map()   ; 命令 id → 快捷键（AHK 写法，如 ^!m）。id 在所有作用域中唯一
global CustomHotkeyScopes := Map()     ; 作用域名 → Map(name, configPath, commands, entryId, entryDefault)
global CustomHotkeyRunning := false
global CustomHotkeyWindow := ""
global CustomHotkeyWindowScope := ""   ; 当前设置窗口属于哪个作用域
global CustomHotkeyPanelId := "panel.open"
global CustomHotkeyPanelDefault := "^+e"

CustomHotkeyConfigPath() {
    return EnvGet("LOCALAPPDATA") . "\AutoHotkeyPanel\hotkeys.ini"
}

; 登记一个作用域。commands 为无参函数，返回 [Map(id, page, name, callback[, noContext])]，可每次动态生成。
CustomHotkeyAddScope(scopeKey, name, configPath, commands, entryId, entryDefault) {
    global CustomHotkeyScopes
    CustomHotkeyScopes[scopeKey] := Map("key", scopeKey, "name", name, "configPath", configPath
        , "commands", commands, "entryId", entryId, "entryDefault", entryDefault)
}

CustomHotkeyScope(scopeKey := "main") {
    global CustomHotkeyScopes
    if !CustomHotkeyScopes.Has("main")
        CustomHotkeyAddScope("main", "自动化面板", CustomHotkeyConfigPath(), CustomHotkeyCommands, CustomHotkeyPanelId, CustomHotkeyPanelDefault)
    return CustomHotkeyScopes[scopeKey]
}

; 自动化面板可绑定快捷键的功能清单：[id, 所在页面, 名称, 回调]。id 写进配置文件，改名时不要改 id。
CustomHotkeyCommands() {
    static commands := ""
    if IsObject(commands)
        return commands
    R := RepeatableSpreadsheetCommand
    list := [
        ["panel.open", "面板入口", "打开自动化面板", OpenAutomationPanelFromHotkey],
        ["table.prefix", "表格工具", "添加前缀", R("添加前缀", AddTextToExcelSelection.Bind("prefix"))],
        ["table.suffix", "表格工具", "添加后缀", R("添加后缀", AddTextToExcelSelection.Bind("suffix"))],
        ["table.removeStart", "表格工具", "删除前端字符", R("删除前端字符", RemoveTextFromExcelSelection.Bind("start"))],
        ["table.removeEnd", "表格工具", "删除末尾字符", R("删除末尾字符", RemoveTextFromExcelSelection.Bind("end"))],
        ["table.removeBracket", "表格工具", "删除括号内容并合并换行", R("删除括号内容", RemoveBracketTextFromExcelSelection)],
        ["table.dedupe", "表格工具", "去重整理", R("去重整理", DedupeAndGroupExcelSelectedColumn)],
        ["table.cableSort", "表格工具", "按电缆截面排序", R("电缆截面排序", SortCableRowsByCrossSection)],
        ["table.duplicates", "表格工具", "标出重复项", R("标出重复项", HighlightSpreadsheetDuplicates)],
        ["table.compare", "表格工具", "比较两列差异", R("比较两列差异", CompareSpreadsheetColumns)],
        ["table.merge", "表格工具", "合并相同内容并居中", R("合并相同内容", MergeIdenticalSpreadsheetCells)],
        ["table.split", "表格工具", "拆分合并单元格并填充", R("拆分合并单元格", SplitMergedSpreadsheetCellsAndFill)],
        ["table.roundTen", "表格工具", "数字向上取十位", R("向上取十位", RoundSpreadsheetSelectionUpToTen)],
        ["table.offset", "表格工具", "数字批量加减", R("数字批量加减", OffsetSpreadsheetSelectionNumbers)],
        ["table.export", "表格工具", "导出选区信息（给 AI）", ExportSpreadsheetSelection],
        ["table.repeat", "表格工具", "重复上次操作", RepeatLastSpreadsheetCommand],
        ["table.undo", "表格工具", "撤销上次操作", UndoExcelCommandPanelAction],
        ["dwg.autocad", "打开图纸", "用 AutoCAD 打开", OpenSelectedDwg.Bind("autocad")],
        ["dwg.zwcad", "打开图纸", "用中望 CAD 打开", OpenSelectedDwg.Bind("zwcad")],
        ["dwg.quickview", "打开图纸", "用快速看图打开", OpenSelectedDwg.Bind("quickview")],
        ["dwg.trusted", "打开图纸", "批量转可信 DWG", ConvertSelectedToTrustedDwg],
        ["dwg.forceClose", "打开图纸", "强制关闭当前图纸", ForceCloseActiveCadDrawing],
        ["dwg.saveClose", "打开图纸", "保存并关闭当前图纸", SaveAndCloseActiveCadDrawing],
        ["dwg.saveReopen", "打开图纸", "保存并重开当前图纸", SaveAndReopenActiveCadDrawing],
        ["dwg.sxc", "打开图纸", "查看文字标记 SXC", RunZwcadCommand.Bind("SXC", "查看文字标记")],
        ["dwg.cablePanel", "打开图纸", "电缆定义总览", CablePanelOpen],
        ["dwg.reloadZw", "打开图纸", "重载中望 CAD 插件", ReloadZwcadAaLsp],
        ["dwg.reloadAcad", "打开图纸", "重载 AutoCAD 插件", ReloadAutocadAaLsp],
        ["cadai.window", "CAD 文字", "打开 AI 改文字窗口", OpenCadAiTextWindow],
        ["cadai.qw2", "CAD 文字", "提取文字及坐标 QW2", RunZwcadCommand.Bind("QW2", "提取文字")],
        ["cadai.qw2p", "CAD 文字", "写回文字 QW2P", RunZwcadCommand.Bind("QW2P", "写入文字")],
        ["cadai.cableSortCsv", "CAD 文字", "打开 CSV 重新整理", CableSortOpenCsv],
        ["rename.prefix", "批量改名", "添加固定前缀", AddFixedTextToSelectedFileNames.Bind("prefix")],
        ["rename.suffix", "批量改名", "添加固定后缀", AddFixedTextToSelectedFileNames.Bind("suffix")],
        ["rename.number", "批量改名", "按顺序添加数字前缀", AddSequentialNumberPrefixToSelectedFileNames],
        ["rename.removeStart", "批量改名", "删除前端文字", RemoveTextFromSelectedFileNames.Bind("start")],
        ["rename.removeEnd", "批量改名", "删除末尾文字", RemoveTextFromSelectedFileNames.Bind("end")],
        ["rename.replace", "批量改名", "替换文件名中的文字", ReplaceCustomTextInSelectedFileNames],
        ["rename.mlToDir", "批量改名", "将 ML 替换为目录", ReplaceTextInSelectedFileNames],
        ["files.mergePdf", "文件处理", "合并选中的 PDF", MergeSelectedPdfFiles],
        ["files.sheetSizes", "文件处理", "统计图幅", CountSelectedDrawingSheetSizes],
        ["files.wordPdf", "文件处理", "Word 转 PDF", ConvertSelectedWordFilesToPdf],
        ["files.excelPdf", "文件处理", "Excel 转 PDF", ConvertSelectedExcelFilesToPdf],
        ["files.pptPdf", "文件处理", "PPT 转 PDF", ConvertSelectedPowerPointFilesToPdf],
        ["files.imagesPdf", "文件处理", "图片合并为 PDF", MergeSelectedImagesToPdf],
        ["files.latest", "文件处理", "找出最新版本", FindLatestFileVersions]
    ]
    commands := []
    for item in list
        commands.Push(Map("id", item[1], "page", item[2], "name", item[3], "callback", item[4]))
    return commands
}

; 在所有作用域里查找命令；scopeKey 有值时只查该作用域。
CustomHotkeyFindCommand(id, scopeKey := "") {
    global CustomHotkeyScopes
    CustomHotkeyScope()
    for key, scope in CustomHotkeyScopes {
        if (scopeKey != "" && key != scopeKey)
            continue
        for command in scope["commands"].Call()
            if (command["id"] = id)
                return command
    }
    return ""
}

; id 所属作用域；找不到返回空。
CustomHotkeyScopeOf(id) {
    global CustomHotkeyScopes
    CustomHotkeyScope()
    for key, scope in CustomHotkeyScopes
        for command in scope["commands"].Call()
            if (command["id"] = id)
                return scope
    return ""
}

; 面板入口：每个作用域的 entryId。入口必须始终有快捷键，配置无效或被清除时回退默认值。
CustomHotkeyEntryScope(id) {
    global CustomHotkeyScopes
    CustomHotkeyScope()
    for key, scope in CustomHotkeyScopes
        if (scope["entryId"] = id)
            return scope
    return ""
}

CustomHotkeyIsEntry(id) {
    return IsObject(CustomHotkeyEntryScope(id))
}

; 读取一个作用域的配置并注册；无效或冲突的条目跳过并记日志，不弹窗打断开机。
; 入口先注册（配置里没有或无效时用默认值），保证面板始终能打开，其他功能不能抢走入口的组合键。
CustomHotkeysInit(scopeKey := "main") {
    global CustomHotkeyBindings
    scope := CustomHotkeyScope(scopeKey)
    entryId := scope["entryId"]
    configuredEntry := ""
    others := []
    path := scope["configPath"]
    section := ""
    if FileExist(path)
        try section := IniRead(path, "Hotkeys")
    for line in StrSplit(section, "`n", "`r") {
        separator := InStr(line, "=")
        if !separator
            continue
        id := Trim(SubStr(line, 1, separator - 1))
        key := Trim(SubStr(line, separator + 1))
        if (key = "" || !IsObject(CustomHotkeyFindCommand(id, scopeKey)))
            continue
        if (id = entryId)
            configuredEntry := key
        else
            others.Push([id, key])
    }
    if !CustomHotkeyBindings.Has(entryId) {
        if (configuredEntry != "") {
            problem := CustomHotkeyValidate(configuredEntry, entryId)
            if (problem = "")
                problem := CustomHotkeyRegister(entryId, configuredEntry)
            if (problem != "")
                LogPanelDiagnostic("自定义快捷键跳过", entryId . "=" . configuredEntry . "：" . problem)
        }
        if !CustomHotkeyBindings.Has(entryId) {
            problem := CustomHotkeyValidate(scope["entryDefault"], entryId)
            if (problem = "")
                problem := CustomHotkeyRegister(entryId, scope["entryDefault"])
            if (problem != "")
                LogPanelDiagnostic("面板入口快捷键注册失败", entryId . "=" . scope["entryDefault"] . "：" . problem)
        }
    }
    for entry in others {
        problem := CustomHotkeyValidate(entry[2], entry[1])
        if (problem = "")
            problem := CustomHotkeyRegister(entry[1], entry[2])
        if (problem != "")
            LogPanelDiagnostic("自定义快捷键跳过", entry[1] . "=" . entry[2] . "：" . problem)
    }
    if (scopeKey = "main")
        CustomHotkeyTrayInit()
    else
        CustomHotkeyRefreshTrayTip()
}

; 托盘兜底入口：快捷键设成按不出来的组合键时，双击托盘图标仍能打开自动化面板，右键可恢复默认快捷键。
CustomHotkeyTrayInit() {
    static done := false
    if !done {
        A_TrayMenu.Insert("1&", "打开自动化面板", (*) => OpenAutomationPanelFromHotkey())
        A_TrayMenu.Insert("2&", "恢复打开面板快捷键为 Ctrl+Shift+E", (*) => CustomHotkeyRestorePanelDefault())
        A_TrayMenu.Insert("3&")
        A_TrayMenu.Default := "打开自动化面板"
        done := true
    }
    CustomHotkeyRefreshTrayTip()
}

; 托盘提示列出每个面板当前的打开快捷键。
CustomHotkeyRefreshTrayTip() {
    global CustomHotkeyScopes, CustomHotkeyBindings
    CustomHotkeyScope()
    tip := ""
    for key, scope in CustomHotkeyScopes {
        entryKey := CustomHotkeyBindings.Has(scope["entryId"]) ? CustomHotkeyBindings[scope["entryId"]] : scope["entryDefault"]
        tip .= (tip = "" ? "" : "`n") . scope["name"] . "：" . CustomHotkeyDisplay(entryKey)
    }
    A_IconTip := tip
}

; 托盘“恢复默认”：Ctrl+Shift+E 若已分给其他功能，先把那个功能的快捷键清掉。
CustomHotkeyRestorePanelDefault() {
    global CustomHotkeyBindings
    for id, key in CustomHotkeyBindings.Clone() {
        if (id != CustomHotkeyPanelId && CustomHotkeyNormalize(key) = CustomHotkeyNormalize(CustomHotkeyPanelDefault)) {
            owner := CustomHotkeyScopeOf(id)
            CustomHotkeyUnregister(id)
            if IsObject(owner)
                CustomHotkeySave(owner["key"])
        }
    }
    problem := CustomHotkeyRebind(CustomHotkeyPanelId, CustomHotkeyPanelDefault)
    if (problem != "") {
        MsgBox("无法恢复 Ctrl+Shift+E：" . problem, "自动化工具面板", "Icon!")
        return
    }
    CustomHotkeySave("main")
    CustomHotkeyTrayInit()
    TrayTip("已恢复：按 Ctrl+Shift+E 打开面板", "自动化工具面板")
}

; 所有自定义快捷键共用这个条件：设置窗口在前台时全部暂停，好让输入框能录下已被占用的组合键。
CustomHotkeyCriterion(*) {
    global CustomHotkeyWindow
    try return !(IsObject(CustomHotkeyWindow) && WinActive("ahk_id " . CustomHotkeyWindow.Hwnd))
    return true
}

CustomHotkeyRegister(id, key) {
    global CustomHotkeyBindings
    ; 面板入口直接打开面板；其他功能经 CustomHotkeyRun 执行
    callback := CustomHotkeyIsEntry(id) ? CustomHotkeyFindCommand(id)["callback"] : CustomHotkeyRun.Bind(id)
    try {
        HotIf(CustomHotkeyCriterion)
        Hotkey(key, callback, "On")
    } catch as err {
        HotIf()
        return "无法注册：" . err.Message
    }
    HotIf()
    CustomHotkeyBindings[id] := key
    return ""
}

CustomHotkeyUnregister(id) {
    global CustomHotkeyBindings
    if !CustomHotkeyBindings.Has(id)
        return
    try {
        HotIf(CustomHotkeyCriterion)
        Hotkey(CustomHotkeyBindings[id], "Off")
    }
    HotIf()
    CustomHotkeyBindings.Delete(id)
}

; 改绑：先注销旧键再注册新键，新键注册失败时恢复旧键。返回空字符串表示成功。
CustomHotkeyRebind(id, key) {
    global CustomHotkeyBindings
    problem := CustomHotkeyValidate(key, id)
    if (problem != "")
        return problem
    oldKey := CustomHotkeyBindings.Has(id) ? CustomHotkeyBindings[id] : ""
    CustomHotkeyUnregister(id)
    problem := CustomHotkeyRegister(id, key)
    if (problem != "" && oldKey != "")
        CustomHotkeyRegister(id, oldKey)
    return problem
}

; 打开自动化面板的当前快捷键（显示用）。分享版在 share-panel.ahk 里覆盖为固定的 Ctrl+Shift+E。
AutomationPanelHotkeyText() {
    global CustomHotkeyBindings
    return CustomHotkeyBindings.Has(CustomHotkeyPanelId)
        ? CustomHotkeyDisplay(CustomHotkeyBindings[CustomHotkeyPanelId]) : "Ctrl+Shift+E"
}

OpenAutomationPanelFromHotkey(*) {
    static isOpening := false
    if isOpening
        return
    isOpening := true
    try {
        ShowAutomationPanel()
    } finally {
        SetTimer(() => isOpening := false, -300)
    }
}

; 检查快捷键是否可用，返回空字符串表示可用，否则返回原因。
CustomHotkeyValidate(key, id := "") {
    global CustomHotkeyBindings
    if !RegExMatch(key, "^([\^\+!#]*)(.+)$", &m)
        return "快捷键格式不正确"
    modifiers := m[1], baseKey := m[2]
    reserved := Map("^z", "Excel 撤销", "^tab", "面板切页", "^+tab", "面板切页")
    normalized := CustomHotkeyNormalize(key)
    if reserved.Has(normalized)
        return "已被面板占用（" . reserved[normalized] . "）"
    ; 不带 Ctrl / Alt / Win 的普通按键会影响日常打字，只允许 F1~F24 这类功能键单独使用
    if !RegExMatch(modifiers, "[\^!#]") && !RegExMatch(baseKey, "i)^F([1-9]|1\d|2[0-4])$")
        return "需要至少带 Ctrl、Alt 或 Win 之一（F1~F24 可单独使用）"
    myScope := CustomHotkeyScopeOf(id)
    for otherId, otherKey in CustomHotkeyBindings {
        if (otherId != id && CustomHotkeyNormalize(otherKey) = normalized) {
            other := CustomHotkeyFindCommand(otherId)
            otherScope := CustomHotkeyScopeOf(otherId)
            where := (IsObject(otherScope) && !(IsObject(myScope) && myScope["key"] = otherScope["key"]))
                ? otherScope["name"] . "的" : ""
            return "已分配给" . where . "“" . (IsObject(other) ? other["name"] : otherId) . "”"
        }
    }
    return ""
}

; 统一修饰键顺序和大小写，用于比较是否重复。
CustomHotkeyNormalize(key) {
    if !RegExMatch(key, "^([\^\+!#]*)(.+)$", &m)
        return StrLower(key)
    modifiers := ""
    for symbol in ["^", "+", "!", "#"]
        if InStr(m[1], symbol)
            modifiers .= symbol
    return modifiers . StrLower(m[2])
}

; ^!m → Ctrl+Alt+M
CustomHotkeyDisplay(key) {
    if (key = "")
        return ""
    if !RegExMatch(key, "^([\^\+!#]*)(.+)$", &m)
        return key
    parts := []
    for pair in [["^", "Ctrl"], ["+", "Shift"], ["!", "Alt"], ["#", "Win"]]
        if InStr(m[1], pair[1])
            parts.Push(pair[2])
    baseKey := m[2]
    parts.Push(StrLen(baseKey) = 1 ? StrUpper(baseKey) : StrUpper(SubStr(baseKey, 1, 1)) . SubStr(baseKey, 2))
    text := ""
    for index, part in parts
        text .= (index > 1 ? "+" : "") . part
    return text
}

; 快捷键触发：读取当前窗口选区快照后直接执行，不弹面板（命令带 noContext 时不读选区，如打开常用软件）。
; 执行期间再按其他快捷键会被忽略，避免快照被覆盖。
CustomHotkeyRun(id, *) {
    global CustomHotkeyRunning
    if CustomHotkeyRunning
        return
    command := CustomHotkeyFindCommand(id)
    if !IsObject(command)
        return
    CustomHotkeyRunning := true
    try {
        LogPanelDiagnostic("自定义快捷键", command["name"] . "（" . A_ThisHotkey . "）")
        if !(command.Has("noContext") && command["noContext"])
            CaptureAutomationContext()
        RunPanelCommand(command["callback"])
    } finally {
        CustomHotkeyRunning := false
    }
}

; 只把属于该作用域的绑定写进它自己的配置文件。
CustomHotkeySave(scopeKey := "main") {
    global CustomHotkeyBindings
    scope := CustomHotkeyScope(scopeKey)
    path := scope["configPath"]
    SplitPath(path, , &directory)
    DirCreate(directory)
    try IniDelete(path, "Hotkeys")
    ids := Map()
    for command in scope["commands"].Call()
        ids[command["id"]] := true
    for id, key in CustomHotkeyBindings
        if ids.Has(id)
            IniWrite(key, path, "Hotkeys", id)
}

; ===== 设置窗口 =====
; scopeKey 决定列出哪个面板的功能；同一时间只开一个设置窗口。
OpenCustomHotkeyWindow(scopeKey := "main", *) {
    global CustomHotkeyWindow, CustomHotkeyWindowScope, CustomHotkeyBindings
    if !(Type(scopeKey) = "String")
        scopeKey := "main"
    if IsObject(CustomHotkeyWindow) {
        try {
            if (CustomHotkeyWindowScope = scopeKey) {
                CustomHotkeyWindow.Show()
                return
            }
            CustomHotkeyWindow.Destroy()
        }
        CustomHotkeyWindow := ""
    }
    scope := CustomHotkeyScope(scopeKey)
    entryDefault := CustomHotkeyDisplay(scope["entryDefault"])
    dlg := Gui("+AlwaysOnTop -MinimizeBox", scope["name"] . " · 快捷键")
    dlg.BackColor := "FFFFFF"
    dlg.MarginX := 16, dlg.MarginY := 14
    dlg.SetFont("s10 c1F2329", "Microsoft YaHei UI")
    dlg.AddText("w560", "选中一个功能，在下方输入框里按下想用的组合键，再点“设置”。第一行是打开" . scope["name"]
        . "的快捷键，清除即恢复默认 " . entryDefault . "。")
    lv := dlg.AddListView("w560 r16 -Multi NoSortHdr Grid", ["功能", "所在页面", "快捷键"])
    dlg.SetFont("s10 c6B7280")
    dlg.AddText("xm y+12 w52 h26 0x200", "快捷键")
    dlg.SetFont("s10 c1F2329")
    hotkeyInput := dlg.AddHotkey("x+6 yp w180 h26")
    winBox := dlg.AddCheckbox("x+10 yp h26", "加 Win 键")
    setBtn := dlg.AddButton("x+10 yp w80 h28 Default", "设置")
    clearBtn := dlg.AddButton("x+8 yp w80 h28", "清除")
    dlg.SetFont("s9 c6B7280")
    hint := dlg.AddText("xm y+10 w560 r2", "")
    dlg.SetFont("s10 c1F2329")
    closeBtn := dlg.AddButton("xm+480 y+6 w80 h28", "关闭")

    commands := scope["commands"].Call()
    refresh := CustomHotkeyRefreshList.Bind(lv, commands)
    refresh()
    lv.ModifyCol(1, 250)
    lv.ModifyCol(2, 110)
    lv.ModifyCol(3, 170)

    selected := () => (row := lv.GetNext(0), row ? commands[row] : "")
    showSelection(*) {
        command := selected()
        if !IsObject(command) {
            hint.Text := ""
            return
        }
        key := CustomHotkeyBindings.Has(command["id"]) ? CustomHotkeyBindings[command["id"]] : ""
        winBox.Value := InStr(key, "#") ? 1 : 0
        try hotkeyInput.Value := StrReplace(key, "#")
        catch
            hotkeyInput.Value := ""
        hint.Text := "“" . command["name"] . "”" . (key = "" ? "还没有快捷键。" : "当前快捷键：" . CustomHotkeyDisplay(key))
    }
    afterChange() {
        CustomHotkeySave(scopeKey)
        CustomHotkeyRefreshTrayTip()
        refresh()
        if scope.Has("onChange") && IsObject(scope["onChange"])
            scope["onChange"].Call()
    }
    applyKey(*) {
        command := selected()
        if !IsObject(command) {
            hint.Text := "请先在列表里选中一个功能。"
            return
        }
        key := hotkeyInput.Value
        if (key = "") {
            hint.Text := "请先在快捷键输入框里按下组合键。"
            return
        }
        if winBox.Value
            key := "#" . key
        problem := CustomHotkeyRebind(command["id"], key)
        if (problem != "") {
            hint.Text := CustomHotkeyDisplay(key) . " 不能用：" . problem
            return
        }
        afterChange()
        hint.Text := "已设置：" . command["name"] . " → " . CustomHotkeyDisplay(key)
        if (command["id"] = scope["entryId"]) {
            MsgBox("以后按 " . CustomHotkeyDisplay(key) . " 打开" . scope["name"] . "。`n`n"
                . "如果按了没反应（组合键被系统或其他程序占用），可以右键任务栏托盘里的面板图标，"
                . "从菜单打开" . scope["name"] . "，再回到这里选中第一行点“清除”，恢复默认 " . entryDefault . "。"
                , "打开" . scope["name"] . "的快捷键已修改", "Iconi Owner" . dlg.Hwnd)
        }
    }
    clearKey(*) {
        command := selected()
        if !IsObject(command)
            return
        ; 面板入口不能没有快捷键：清除即恢复默认
        if (command["id"] = scope["entryId"]) {
            problem := CustomHotkeyRebind(command["id"], scope["entryDefault"])
            if (problem != "") {
                hint.Text := "无法恢复默认的 " . entryDefault . "：" . problem
                return
            }
            afterChange()
            showSelection()
            hint.Text := "“" . command["name"] . "”已恢复默认：" . entryDefault . "。"
            return
        }
        CustomHotkeyUnregister(command["id"])
        afterChange()
        hotkeyInput.Value := ""
        winBox.Value := 0
        hint.Text := "已清除“" . command["name"] . "”的快捷键。"
    }
    closeWindow(*) {
        global CustomHotkeyWindow
        CustomHotkeyWindow := ""
        dlg.Destroy()
    }

    lv.OnEvent("ItemSelect", showSelection)
    setBtn.OnEvent("Click", applyKey)
    clearBtn.OnEvent("Click", clearKey)
    closeBtn.OnEvent("Click", closeWindow)
    dlg.OnEvent("Close", closeWindow)
    dlg.OnEvent("Escape", closeWindow)
    CustomHotkeyWindow := dlg
    CustomHotkeyWindowScope := scopeKey
    dlg.Show()
    lv.Focus()
}

CustomHotkeyRefreshList(lv, commands) {
    global CustomHotkeyBindings
    selectedRow := lv.GetNext(0)
    lv.Opt("-Redraw")
    lv.Delete()
    for command in commands {
        key := CustomHotkeyBindings.Has(command["id"]) ? CustomHotkeyBindings[command["id"]] : ""
        lv.Add(, command["name"], command["page"], CustomHotkeyDisplay(key))
    }
    if selectedRow
        lv.Modify(selectedRow, "Select Focus Vis")
    lv.Opt("+Redraw")
}

; 面板“快捷键”页里列出的已设置条目，按该面板功能清单顺序排列。
CustomHotkeyAssignedList(scopeKey := "main") {
    global CustomHotkeyBindings
    assigned := []
    for command in CustomHotkeyScope(scopeKey)["commands"].Call()
        if CustomHotkeyBindings.Has(command["id"])
            assigned.Push(Map("name", command["name"], "page", command["page"]
                , "key", CustomHotkeyDisplay(CustomHotkeyBindings[command["id"]])))
    return assigned
}
