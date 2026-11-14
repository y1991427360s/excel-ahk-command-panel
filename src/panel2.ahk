; ===== 2号自动化面板（个人专用，不进分享包）=====
; 默认 Alt+Q 打开。外观与自动化面板一致，与它同进程但互不引用：自动化面板的代码和设置里都不出现 2号面板。
; 页面：常用软件、常用文件夹（双击打开，右键管理，可从资源管理器拖进来）、文件处理（视频、HTML）、默认输入法、快捷键。
; 快捷键自成一个作用域（见 custom-hotkeys.ahk 的 CustomHotkeyAddScope）：打开 2号面板的快捷键（id panel2.open）、
; 文件处理功能和每个常用软件 / 文件夹都可绑定，只在本面板“快捷键”页设置，配置在 %LOCALAPPDATA%\AutoHotkeyPanel\panel2-hotkeys.ini。
; 快捷方式清单保存在 %LOCALAPPDATA%\AutoHotkeyPanel\panel2-shortcuts.tsv（UTF-8 带 BOM，每行：类型<Tab>名称<Tab>路径）。

global AutomationPanel2Gui := ""
global AutomationPanel2Ui := ""
global AutomationPanel2LastPage := "apps"
global AutomationPanel2Query := ""   ; 常用软件 / 文件夹的搜索词，两个页面共用；重新打开面板时清空

; 自己的快捷键作用域：打开 2号面板（默认 Alt+Q）和它的功能、常用软件 / 文件夹，配置在 panel2-hotkeys.ini；
; 只在 2号面板“快捷键”页设置，不出现在自动化面板里。等自动化面板初始化完再注册。
SetTimer(Panel2HotkeysInit, -1)

#HotIf AutomationPanel2IsActive()
^Tab::CycleAutomationPanel2Page(1)
^+Tab::CycleAutomationPanel2Page(-1)
#HotIf Panel2SearchKeysActive()
Enter::Panel2SearchEnter()
NumpadEnter::Panel2SearchEnter()
Up::Panel2SearchMove(-1)
Down::Panel2SearchMove(1)
Escape::Panel2SearchEscape()
#HotIf

AutomationPanel2Pages() {
    static pages := [
        Map("key", "apps", "title", "常用软件", "icon", Chr(0xE71D)),
        Map("key", "folders", "title", "常用文件夹", "icon", Chr(0xE8B7)),
        Map("key", "files", "title", "文件处理", "icon", Chr(0xE8A5)),
        Map("key", "ime", "title", "默认输入法", "icon", Chr(0xE765)),
        Map("key", "hotkeys", "title", "快捷键", "icon", Chr(0xE713))
    ]
    return pages
}

AutomationPanel2IsActive() {
    global AutomationPanel2Gui
    try return IsObject(AutomationPanel2Gui) && WinActive("ahk_id " . AutomationPanel2Gui.Hwnd)
    return false
}

OpenAutomationPanel2FromHotkey(*) {
    static isOpening := false
    if isOpening
        return
    isOpening := true
    try {
        ShowAutomationPanel2()
    } finally {
        SetTimer(() => isOpening := false, -300)
    }
}

; 打开面板：读取一次选区快照（视频、HTML 功能要用），再按选区决定默认页面。
ShowAutomationPanel2() {
    global AutomationSelectedFilePaths, AutomationPanel2LastPage, AutomationPanel2Query
    CaptureAutomationContext()
    AutomationPanel2Query := ""
    page := AutomationPanel2LastPage
    for filePath in AutomationSelectedFilePaths {
        SplitPath(filePath, , , &extension)
        if RegExMatch(extension, "i)^(mp4|mov|mkv|avi|webm|m4v|wmv|flv|html?|mhtml?)$") {
            page := "files"
            break
        }
    }
    Panel2Build(page)
}

; 重建面板。rebuild 为真时保持窗口位置（添加、删除、改名后刷新用），不重新读取选区。
Panel2Build(page, rebuild := false) {
    global AutomationPanelGui, AutomationPanel2Gui, AutomationPanel2Ui, AutomationSelectedFilePaths

    position := ""
    if (rebuild && IsObject(AutomationPanel2Gui)) {
        try {
            WinGetPos(&oldX, &oldY, , , "ahk_id " . AutomationPanel2Gui.Hwnd)
            position := "x" . oldX . " y" . oldY
        }
    }
    if IsObject(AutomationPanelGui)
        try AutomationPanelGui.Destroy()
    AutomationPanelGui := ""
    Panel2PopupClose()
    if IsObject(AutomationPanel2Gui)
        try AutomationPanel2Gui.Destroy()

    colors := ModernPanelColors()
    fileCount := AutomationSelectedFilePaths.Length
    hasFiles := fileCount > 0
    shortcuts := Panel2LoadShortcuts()

    ; +0x2000000（WS_CLIPCHILDREN）：自绘画布不盖住搜索框这个子控件
    ui := ModernPanelCreate("2号自动化面板", "+AlwaysOnTop -MinimizeBox -MaximizeBox +0x2000000")
    panel := ui["gui"]

    sidebarStyle := ModernPanelStyle(colors["sidebar"], colors["text"])
    sidebarStyle["radius"] := 0
    ModernPanelLabelAt(ui, 0, 0, 188, 586, "", sidebarStyle)
    ModernPanelLabelAt(ui, 26, 20, 146, 26, "2号自动化面板", ModernPanelTextStyle(colors["text"], 13, true))
    ModernPanelLabelAt(ui, 26, 46, 146, 18, Panel2HotkeyText(), ModernPanelTextStyle(colors["secondary"], 9))
    navItems := Map()
    navY := 84
    for item in AutomationPanel2Pages() {
        navItems[item["key"]] := ModernPanelAddElement(ui, 14, navY, 160, 34, item["title"]
            , AutomationPanelNavStyle("", colors["text"], false, item["icon"], colors["icon"]), ""
            , Panel2SelectPage.Bind(ui, item["key"]))
        navItems[item["key"]]["icon"] := item["icon"]
        navY += 38
    }
    ui["nav"] := navItems
    ModernPanelLabelAt(ui, 26, 546, 160, 20, "Esc 关闭 · Ctrl+Tab 切换", ModernPanelTextStyle(colors["secondary"], 9))
    separatorStyle := ModernPanelStyle(colors["separator"], colors["text"])
    separatorStyle["radius"] := 0
    ModernPanelLabelAt(ui, 188, 0, 1, 586, "", separatorStyle)

    ; 顶部信息行：默认显示选区；单击快捷方式时改为显示它的路径
    ModernPanelLabelAt(ui, 208, 16, 432, 62, "", ModernPanelStyle(colors["info"], colors["text"]))
    ModernPanelLabelAt(ui, 222, 16, 20, 62, "", ModernPanelDecorate(ModernPanelTextStyle(colors["icon"]), "", Chr(0xE946), colors["icon"]))
    if hasFiles {
        SplitPath(AutomationSelectedFilePaths[1], &firstName)
        infoTitle := "已选中 " . fileCount . " 个文件"
        infoDetail := fileCount = 1 ? firstName : firstName . " 等 " . fileCount . " 个"
    } else {
        infoTitle := "常用软件与文件夹"
        infoDetail := "直接打字搜索，回车打开；双击打开，按住拖动排序，右键管理。"
    }
    ui["infoDefault"] := [infoTitle, infoDetail]
    ui["infoTitle"] := ModernPanelLabelAt(ui, 250, 24, 380, 24, infoTitle, ModernPanelTextStyle(colors["text"], 11, true))
    ui["infoDetail"] := ModernPanelLabelAt(ui, 250, 48, 380, 24, infoDetail, ModernPanelTextStyle(colors["secondary"], 9))
    ui["shortcutTiles"] := []
    ui["grids"] := Map()
    ui["onDragMove"] := Panel2OnDragMove
    ui["onDragEnd"] := Panel2OnDragEnd
    ui["emptyHints"] := Map()
    ui["clearButtons"] := []

    contentX := 208, contentY := 92, contentW := 432

    for kind in ["app", "folder"] {
        isApp := kind = "app"
        ModernPanelBeginPage(ui, isApp ? "apps" : "folders", contentX, contentY, contentW)
        items := []
        for item in shortcuts
            if (item["type"] = kind)
                items.Push(item)
        ; 标题与搜索框同一行：左边标题，右边圆角搜索框（输入框是子控件，压在这块底色上）
        pageKey := isApp ? "apps" : "folders"
        ModernPanelLabelAt(ui, contentX + 6, contentY, 190, 34, (isApp ? "常用软件" : "常用文件夹") . "（" . items.Length . "）"
            , ModernPanelTextStyle(colors["secondary"], 9, true))
        searchStyle := ModernPanelDecorate(ModernPanelStyle(Panel2SearchFill(), colors["text"], false, "left"), "", Chr(0xE721), colors["icon"])
        searchStyle["radius"] := 17
        searchStyle["padding"] := 12
        ModernPanelLabelAt(ui, Panel2SearchBox()[1], Panel2SearchBox()[2], Panel2SearchBox()[3], Panel2SearchBox()[4], "", searchStyle)
        clearStyle := ModernPanelDecorate(ModernPanelStyle("", colors["secondary"]), "", Chr(0xE711), colors["secondary"])
        clearHover := ModernPanelDecorate(ModernPanelStyle("", colors["text"]), "", Chr(0xE711), colors["iconHover"])
        clearButton := ModernPanelAddElement(ui, Panel2SearchBox()[1] + Panel2SearchBox()[3] - 34, Panel2SearchBox()[2], 30, Panel2SearchBox()[4], ""
            , clearStyle, clearHover, Panel2ClearSearch)
        clearButton["hidden"] := true
        ui["clearButtons"].Push(clearButton)
        ui["y"] := contentY + 42
        selectedOfType := Panel2SelectedPaths(kind)
        Panel2Row(ui
            , [isApp ? "添加软件…" : "添加文件夹…", Panel2AddByDialog.Bind(kind), true, Chr(isApp ? 0xE710 : 0xE8F4)]
            , [(isApp ? "添加选中的文件" : "添加选中的文件夹") . (selectedOfType.Length ? "（" . selectedOfType.Length . "）" : "")
                , Panel2AddPaths.Bind(selectedOfType), selectedOfType.Length > 0, Chr(0xE8DA)])
        if !items.Length {
            ModernPanelCard(ui, isApp ? "还没有常用软件" : "还没有常用文件夹", colors["secondary"], Chr(isApp ? 0xE71D : 0xE8B7))
            ModernPanelNote(ui, isApp
                ? "点“添加软件…”选 exe 或快捷方式，或在资源管理器选中后按 " . Panel2HotkeyText() . " 点“添加选中的文件”，也可以直接拖进面板。"
                : "点“添加文件夹…”，或在资源管理器选中文件夹后按 " . Panel2HotkeyText() . " 点“添加选中的文件夹”，也可以直接拖进面板。", 3)
            continue
        }
        Panel2ShortcutGrid(ui, pageKey, items, colors)
        hint := ModernPanelLabelAt(ui, contentX + 6, ui["grids"][pageKey]["top"] + 4, contentW - 6, 40, ""
            , ModernPanelTextStyle(colors["secondary"], 10))
        hint["hidden"] := true
        ui["emptyHints"][pageKey] := hint
    }

    ModernPanelBeginPage(ui, "files", contentX, contentY, contentW)
    ModernPanelSection(ui, "视频")
    ModernPanelRow(ui, ["MP4 转 GIF", ConvertSelectedVideosToGif, hasFiles, Chr(0xE714)]
        , ["压缩视频", CompressSelectedVideos, hasFiles, Chr(0xE73F)])
    ModernPanelSpace(ui, 6)
    ModernPanelSection(ui, "网页")
    ModernPanelRow(ui, ["HTML 转 PDF", ConvertSelectedHtmlFilesToPdf, hasFiles, Chr(0xE774)])
    ModernPanelNote(ui, hasFiles
        ? "视频转为同目录同名 GIF；压缩视频放进同目录新建的“压缩视频”文件夹；HTML 转为同目录同名 PDF。覆盖前会确认。"
        : "请先在资源管理器或桌面选中视频或 HTML 文件，再按 " . Panel2HotkeyText() . "。", 3)

    ModernPanelBeginPage(ui, "ime", contentX, contentY, contentW)
    ModernPanelSection(ui, "替代默认输入法")
    currentTip := GetDefaultInputMethodOverride()
    ModernPanelRow(ui, ["使用语言列表(推荐)" . (currentTip = "" ? "（当前）" : "")
        , SetDefaultInputMethod.Bind("", "使用语言列表(推荐)"), currentTip != "", Chr(0xE8C4)])
    for method in GetInstalledInputMethods() {
        isCurrent := method["tip"] = currentTip
        ModernPanelRow(ui, [method["name"] . (isCurrent ? "（当前）" : method["added"] ? "" : "（未添加）")
            , SetDefaultInputMethod.Bind(method["tip"], method["name"], method["added"] ? "" : method["language"])
            , !isCurrent, Chr(0xE765)])
    }
    ModernPanelNote(ui, "列表随安装的输入法自动更新；“未添加”的会先加入输入法列表再设为默认。切换后对新打开的窗口生效。", 3)

    ModernPanelBeginPage(ui, "hotkeys", contentX, contentY, contentW)
    ModernPanelSection(ui, "2号面板的快捷键")
    ModernPanelRow(ui, ["设置快捷键…", OpenCustomHotkeyWindow.Bind("panel2"), true, Chr(0xE713)])
    ModernPanelNote(ui, "打开本面板的快捷键（默认 Alt+Q）在这里改；也可以给文件处理功能和每个常用软件、文件夹单独设快捷键，按下直接打开。与自动化面板的快捷键分开保存。", 3)
    assignedHotkeys := CustomHotkeyAssignedList("panel2")
    ModernPanelSection(ui, "已设置（" . assignedHotkeys.Length . " 个）")
    maxShown := 8
    for index, item in assignedHotkeys {
        if (index > maxShown) {
            ModernPanelLabelAt(ui, contentX + 6, ui["y"], contentW - 6, 24
                , "…另有 " . (assignedHotkeys.Length - maxShown) . " 个，完整列表见设置窗口", ModernPanelTextStyle(colors["secondary"], 9))
            break
        }
        ModernPanelLabelAt(ui, contentX, ui["y"], contentW, 30, "", ModernPanelStyle(colors["info"], colors["text"]))
        ModernPanelLabelAt(ui, contentX + 12, ui["y"], 250, 30, item["name"], ModernPanelTextStyle(colors["text"], 10, false, "left"))
        ModernPanelLabelAt(ui, contentX + 262, ui["y"], 158, 30, item["key"], ModernPanelTextStyle(colors["secondary"], 10, true, "right"))
        ui["y"] += 34
    }

    ; 搜索框：无边框输入框，底色与圆角框一致，带灰色占位提示
    box := Panel2SearchBox()
    panel.SetFont("s10 c1F2329", "Microsoft YaHei UI")
    search := panel.AddEdit("x" . (box[1] + 36) . " y" . (box[2] + 8) . " w" . (box[3] - 36 - 34) . " h20 -E0x200 -Wrap Background" . Panel2SearchFill(), AutomationPanel2Query)
    SendMessage(0x1501, 1, StrPtr("搜索名称或拼音首字母"), search)   ; EM_SETCUEBANNER
    search.OnEvent("Change", Panel2OnSearchChange)
    ui["search"] := search

    AutomationPanel2Gui := panel
    AutomationPanel2Ui := ui
    Panel2SelectPage(ui, page)
    createdTime := A_TickCount
    panel.OnEvent("Close", (*) => panel.Hide())
    panel.OnEvent("Escape", Panel2OnEscape.Bind(createdTime))
    panel.OnEvent("DropFiles", Panel2OnDropFiles)
    Panel2ApplySearch(ui, false)
    panel.Show("w656 h586 " . (position != "" ? position : "Center"))
    if (page = "apps" || page = "folders") {
        search.Focus()
        SendMessage(0xB1, -1, -1, search)   ; 光标放到末尾
    }
}

; 搜索框位置（逻辑像素）：[x, y, 宽, 高]，在内容区右上角。
Panel2SearchBox() {
    return [420, 88, 220, 34]
}

Panel2SearchFill() {
    return "F3F5F8"
}

; Esc：搜索框里有字时先清空，再按一次才关闭面板。
Panel2OnEscape(createdTime, guiObj, *) {
    global AutomationPanel2Query, AutomationPanel2Ui
    if Panel2PopupIsOpen()
        return Panel2PopupClose()
    if (AutomationPanel2Query != "") {
        Panel2ClearSearch()
        return
    }
    if (A_TickCount - createdTime > 400)
        guiObj.Hide()
}

Panel2OnSearchChange(ctrl, *) {
    global AutomationPanel2Query, AutomationPanel2Ui
    AutomationPanel2Query := ctrl.Value
    Panel2ApplySearch(AutomationPanel2Ui)
}

Panel2ClearSearch(*) {
    global AutomationPanel2Query, AutomationPanel2Ui
    AutomationPanel2Query := ""
    ui := AutomationPanel2Ui
    if !IsObject(ui)
        return
    try {
        ui["search"].Value := ""
        ui["search"].Focus()
    }
    Panel2ApplySearch(ui)
}

; 按搜索词筛选两个页面的卡片：匹配的依次补到前面的格子（缓动过去），其余隐藏；
; 有搜索词时暂停拖动排序（筛选状态下排序没有意义），并自动选中当前页第一个结果。
Panel2ApplySearch(ui, animate := true) {
    global AutomationPanel2Query
    query := Trim(AutomationPanel2Query)
    terms := []
    for term in StrSplit(StrLower(query), [" ", "　"])
        if (term != "")
            terms.Push(term)
    for page, grid in ui["grids"] {
        visible := 0
        for tile in grid["tiles"] {
            match := !terms.Length || Panel2SearchMatch(tile["item"], terms)
            tile["hidden"] := !match
            if terms.Length {
                if tile.Has("dragGroup")
                    tile.Delete("dragGroup")
            } else {
                tile["dragGroup"] := page
            }
            if !match
                continue
            visible += 1
            slot := Panel2SlotPosition(grid, visible)
            tile["tx"] := slot[1], tile["ty"] := slot[2]
            if !animate
                tile["x"] := slot[1], tile["y"] := slot[2]
        }
        grid["visibleCount"] := visible
        rows := (visible + grid["columns"] - 1) // grid["columns"]
        if (ui.Has("scrolls") && ui["scrolls"].Has(page)) {
            region := ui["scrolls"][page]
            region["max"] := Max(0, grid["top"] + rows * grid["stepY"] - grid["gap"] + 6 - region["bottom"])
            region["offset"] := 0
        }
        if ui["emptyHints"].Has(page) {
            hint := ui["emptyHints"][page]
            hint["hidden"] := !(terms.Length && visible = 0)
            hint["text"] := "没有找到“" . query . "”。试试名称里的字、拼音首字母（如 hr）或路径里的词。"
        }
    }
    for button in ui["clearButtons"]
        button["hidden"] := query = ""
    if animate
        ModernPanelAnimate(ui)
    ; 当前页：有搜索词时选中第一个结果，清空时恢复默认提示
    page := ui["current"]
    first := ""
    if ui["grids"].Has(page)
        for tile in ui["grids"][page]["tiles"]
            if !tile["hidden"] {
                first := tile
                break
            }
    if (terms.Length && IsObject(first)) {
        Panel2SelectShortcut(ui, first, first["item"])
    } else {
        for tile in ui["shortcutTiles"]
            tile["style"] := tile["normalStyle"]
        ui["selectedTile"] := ""
        Panel2SetInfo(ui["infoDefault"][1], ui["infoDefault"][2])
    }
    ModernPanelInvalidate(ui)
}

; 每个词都要命中：名称、名称的拼音首字母，或路径（路径只认 2 个字以上的词，免得 “c” 命中所有 C 盘路径）。
Panel2SearchMatch(item, terms) {
    name := StrLower(item["name"])
    initials := Panel2PinyinInitials(item["name"])
    path := StrLower(item["path"])
    for term in terms {
        if InStr(name, term) || InStr(initials, term) || (StrLen(term) >= 2 && InStr(path, term))
            continue
        return false
    }
    return true
}

; 汉字转拼音首字母（GB2312 一级汉字按区位码分段，覆盖常用 3755 字；其余字符原样小写保留）。
Panel2PinyinInitials(text) {
    static cache := Map()
    static bounds := [[0xB0A1, "a"], [0xB0C5, "b"], [0xB2C1, "c"], [0xB4EE, "d"], [0xB6EA, "e"], [0xB7A2, "f"], [0xB8C1, "g"]
        , [0xB9FE, "h"], [0xBBF7, "j"], [0xBFA6, "k"], [0xC0AC, "l"], [0xC2E8, "m"], [0xC4C3, "n"], [0xC5B6, "o"], [0xC5BE, "p"]
        , [0xC6DA, "q"], [0xC8BB, "r"], [0xC8F6, "s"], [0xCBFA, "t"], [0xCDDA, "w"], [0xCEF4, "x"], [0xD1B9, "y"], [0xD4D1, "z"]]
    if cache.Has(text)
        return cache[text]
    result := ""
    buf := Buffer(8, 0)
    loop parse text {
        ch := A_LoopField
        if (Ord(ch) < 128) {
            result .= StrLower(ch)
            continue
        }
        letter := ""
        NumPut("UInt", 0, buf)
        StrPut(ch, buf, "CP936")
        code := (NumGet(buf, 0, "UChar") << 8) | NumGet(buf, 1, "UChar")
        if (code >= 0xB0A1 && code <= 0xD7F9) {
            for bound in bounds
                if (code >= bound[1])
                    letter := bound[2]
        }
        result .= letter != "" ? letter : ch
    }
    cache[text] := result
    return result
}

; 搜索框有焦点时的 Esc（输入框会吞掉 Esc，面板的 Escape 事件收不到）：有字先清空，没字关闭面板。
Panel2SearchEscape() {
    global AutomationPanel2Query, AutomationPanel2Gui
    if Panel2PopupIsOpen()
        return Panel2PopupClose()
    if (AutomationPanel2Query != "")
        Panel2ClearSearch()
    else
        try AutomationPanel2Gui.Hide()
}

; 搜索框有焦点、在常用软件 / 文件夹页时，回车打开选中的结果，上下键切换，Esc 先清空再关闭。
Panel2SearchKeysActive() {
    global AutomationPanel2Ui
    if !AutomationPanel2IsActive()
        return false
    ui := AutomationPanel2Ui
    if !(IsObject(ui) && (ui["current"] = "apps" || ui["current"] = "folders") && ui.Has("search"))
        return false
    try return ControlGetFocus("ahk_id " . ui["gui"].Hwnd) = ui["search"].Hwnd
    return false
}

Panel2VisibleTiles(ui) {
    tiles := []
    if ui["grids"].Has(ui["current"])
        for tile in ui["grids"][ui["current"]]["tiles"]
            if !tile["hidden"]
                tiles.Push(tile)
    return tiles
}

Panel2SearchEnter() {
    global AutomationPanel2Ui
    ui := AutomationPanel2Ui
    tiles := Panel2VisibleTiles(ui)
    if !tiles.Length
        return
    target := tiles[1]
    if (ui.Has("selectedTile") && IsObject(ui["selectedTile"]))
        for tile in tiles
            if ModernPanelSame(tile, ui["selectedTile"])
                target := tile
    Panel2OpenShortcut(target["item"])
}

; 上下键在当前可见卡片之间移动选中，并让选中卡片滚到可视区内。
Panel2SearchMove(step) {
    global AutomationPanel2Ui
    ui := AutomationPanel2Ui
    tiles := Panel2VisibleTiles(ui)
    if !tiles.Length
        return
    index := 0
    if (ui.Has("selectedTile") && IsObject(ui["selectedTile"]))
        for i, tile in tiles
            if ModernPanelSame(tile, ui["selectedTile"])
                index := i
    index := index = 0 ? 1 : Max(1, Min(tiles.Length, index + step))
    tile := tiles[index]
    Panel2SelectShortcut(ui, tile, tile["item"])
    if ui["scrolls"].Has(ui["current"]) {
        region := ui["scrolls"][ui["current"]]
        y := tile.Has("ty") ? tile["ty"] : tile["y"]
        if (y - region["offset"] < region["top"])
            ModernPanelScrollBy(ui, region, y - region["offset"] - region["top"] - 6)
        else if (y + tile["h"] - region["offset"] > region["bottom"])
            ModernPanelScrollBy(ui, region, y + tile["h"] - region["offset"] - region["bottom"] + 6)
    }
}

; 一行管理按钮：点击后不关闭面板。第一个是浅蓝主按钮，其余为白底描边，圆角比普通按钮更大一些。
Panel2Row(ui, items*) {
    colors := ModernPanelColors()
    gap := 12
    tileWidth := (ui["w"] - gap * (items.Length - 1)) // items.Length
    x := ui["x"]
    for index, item in items {
        primary := index = 1
        if !item[3] {
            style := ModernPanelDecorate(ModernPanelStyle("FAFBFC", colors["disabled"]), "EEF0F3", item[4], colors["iconDisabled"])
            style["radius"] := 12
            ModernPanelAddElement(ui, x, ui["y"], tileWidth, 40, item[1], style)
        } else {
            style := primary
                ? ModernPanelDecorate(ModernPanelStyle("EAF2FE", "1D4ED8", true), "", item[4], "3B82F6")
                : ModernPanelDecorate(ModernPanelStyle("FFFFFF", colors["text"]), colors["tileBorder"], item[4], colors["icon"])
            hover := primary
                ? ModernPanelDecorate(ModernPanelStyle("DCE9FD", "1D4ED8", true), "", item[4], "2563EB")
                : ModernPanelDecorate(ModernPanelStyle("F5F7FA", colors["text"]), colors["tileBorder"], item[4], colors["iconHover"])
            style["radius"] := hover["radius"] := 12
            ModernPanelAddElement(ui, x, ui["y"], tileWidth, 40, item[1], style, hover, item[2])
        }
        x += tileWidth + gap
    }
    ui["y"] += 52
}

; 快捷方式卡片网格：2 列柔和配色卡片（名字较长也能完整显示），带投影和真实图标；放不下时滚轮滚动。
; 单击选中并在顶部显示路径，双击打开，右键管理，按住拖动调整顺序（其他卡片实时让位）。
Panel2ShortcutGrid(ui, page, items, colors) {
    global CustomHotkeyBindings
    grid := Panel2GridLayout(ui["x"], ui["y"] + 4, ui["w"])
    grid["page"] := page
    grid["tiles"] := []
    ui["grids"][page] := grid
    for index, item in items {
        exists := Panel2ShortcutExists(item)
        hotkeyId := Panel2ShortcutHotkeyId(item)
        keyText := CustomHotkeyBindings.Has(hotkeyId) ? CustomHotkeyDisplay(CustomHotkeyBindings[hotkeyId]) : ""
        slot := Panel2SlotPosition(grid, index)
        element := ModernPanelAddElement(ui, slot[1], slot[2], grid["tileW"], grid["tileH"], item["name"]
            , Panel2CardStyle(item, exists, keyText, "normal"), Panel2CardStyle(item, exists, keyText, "hover"), "")
        element["scroll"] := page
        element["dragGroup"] := page
        element["dragStyle"] := Panel2CardStyle(item, exists, keyText, "drag")
        element["normalStyle"] := element["style"]
        element["selectedStyle"] := Panel2CardStyle(item, exists, keyText, "selected")
        element["exists"] := exists
        element["item"] := item
        element["onClick"] := Panel2SelectShortcut.Bind(ui, element, item)
        element["onDoubleClick"] := Panel2OpenShortcut.Bind(item)
        element["onRightClick"] := Panel2ShortcutMenu.Bind(item)
        grid["tiles"].Push(element)
        ui["shortcutTiles"].Push(element)
    }
    rows := (items.Length + grid["columns"] - 1) // grid["columns"]
    contentBottom := grid["top"] + rows * grid["stepY"] - grid["gap"] + 6
    ModernPanelAddScrollRegion(ui, page, page, grid["left"], grid["top"] - 4, grid["left"] + ui["w"], 574, contentBottom)
}

Panel2GridLayout(left, top, width) {
    columns := 2, gap := 12, tileH := 56
    tileW := (width - gap * (columns - 1)) // columns
    return Map("left", left, "top", top, "columns", columns, "gap", gap, "tileW", tileW, "tileH", tileH
        , "stepX", tileW + gap, "stepY", tileH + gap)
}

Panel2SlotPosition(grid, index) {
    column := Mod(index - 1, grid["columns"])
    row := (index - 1) // grid["columns"]
    return [grid["left"] + column * grid["stepX"], grid["top"] + row * grid["stepY"]]
}

; 柔和配色：[名称, 底色, 主色]。底色只带一点点色相，主色用于文件夹图标、选中描边。
Panel2Palette() {
    static palette := [
        ["蓝", "EEF4FE", "3B82F6"],
        ["绿", "ECF8F0", "22A55B"],
        ["紫", "F3EFFD", "8B5CF6"],
        ["橙", "FEF3EA", "EE8A2F"],
        ["粉", "FDEFF4", "E0558C"],
        ["青", "E9F7F6", "14A39A"],
        ["黄", "FEF8E6", "D9A40B"],
        ["靛", "EEF0FC", "5160D6"]
    ]
    return palette
}

; 条目颜色：右键菜单里选过的用选定色，否则按路径自动分配（同一路径颜色固定，调整顺序也不变）。
Panel2ItemColor(item) {
    palette := Panel2Palette()
    if (item.Has("color") && item["color"] >= 1 && item["color"] <= palette.Length)
        return palette[item["color"]]
    hash := 0
    loop parse StrLower(item["path"])
        hash := Mod(hash * 31 + Ord(A_LoopField), 1000003)
    return palette[Mod(hash, palette.Length) + 1]
}

; state：normal / hover / selected / drag。找不到路径的条目一律灰色。
Panel2CardStyle(item, exists, keyText, state) {
    colors := ModernPanelColors()
    color := Panel2ItemColor(item)
    fill := exists ? color[2] : "F4F5F7"
    strong := exists ? color[3] : "B8BCC4"
    if (state = "hover" || state = "drag")
        fill := Panel2Mix(fill, strong, 0.07)
    style := ModernPanelStyle(fill, exists ? colors["text"] : colors["disabled"], true, "left")
    style["radius"] := 14
    style["padding"] := 14
    style["size"] := 10
    style["shadow"] := state = "drag" ? 3 : state = "hover" ? 2 : 1
    style["border"] := state = "selected" ? strong : ""
    style["imageSize"] := 28
    if (item["type"] = "folder")
        style["folder"] := strong
    else {
        icon := exists ? ModernPanelFileIcon(item["path"]) : 0
        if icon
            style["image"] := icon
        else
            style["folder"] := "", style["icon"] := Chr(0xE71D), style["iconColor"] := strong
    }
    style["subtext"] := keyText != "" ? keyText : (exists ? "" : "找不到")
    style["subColor"] := colors["secondary"]
    return style
}

; 两个 6 位颜色按比例混合（ratio 为第二个颜色所占比例）。
Panel2Mix(colorA, colorB, ratio) {
    a := Integer("0x" . colorA), b := Integer("0x" . colorB)
    mixed := 0
    for shift in [16, 8, 0] {
        channel := Round(((a >> shift) & 0xFF) * (1 - ratio) + ((b >> shift) & 0xFF) * ratio)
        mixed |= channel << shift
    }
    return Format("{:06X}", mixed)
}

; 拖动中：按鼠标位置算出目标格子，把被拖卡片插到那里，其余卡片缓动让位。
Panel2OnDragMove(ui, element, x, y) {
    if !ui["grids"].Has(element["dragGroup"])
        return
    grid := ui["grids"][element["dragGroup"]]
    tiles := grid["tiles"]
    column := Max(0, Min(grid["columns"] - 1, Floor((x - grid["left"] + grid["gap"] / 2) / grid["stepX"])))
    row := Max(0, Floor((y - grid["top"] + grid["gap"] / 2) / grid["stepY"]))
    target := Min(tiles.Length, row * grid["columns"] + column + 1)
    current := 0
    for index, tile in tiles
        if ModernPanelSame(tile, element)
            current := index
    if (!current || target = current)
        return
    tiles.RemoveAt(current)
    tiles.InsertAt(target, element)
    for index, tile in tiles {
        slot := Panel2SlotPosition(grid, index)
        tile["tx"] := slot[1], tile["ty"] := slot[2]
    }
    ModernPanelAnimate(ui)
}

; 松手：被拖卡片落回自己的格子，按新顺序保存（只改同类型条目之间的顺序）。
Panel2OnDragEnd(ui, element) {
    if !ui["grids"].Has(element["dragGroup"])
        return
    grid := ui["grids"][element["dragGroup"]]
    for index, tile in grid["tiles"] {
        slot := Panel2SlotPosition(grid, index)
        tile["tx"] := slot[1], tile["ty"] := slot[2]
    }
    ModernPanelAnimate(ui)
    Panel2SaveOrder(element["item"]["type"], grid["tiles"])
}

Panel2SaveOrder(kind, tiles) {
    items := Panel2LoadShortcuts()
    ordered := []
    for tile in tiles {
        index := Panel2IndexOf(items, tile["item"])
        if index
            ordered.Push(items[index])
    }
    ; 文件里该类型条目原来的位置依次换成新顺序，另一类型的条目不动
    position := 0
    for index, item in items {
        if (item["type"] = kind && position < ordered.Length) {
            position += 1
            items[index] := ordered[position]
        }
    }
    Panel2SaveShortcuts(items)
}

Panel2SelectPage(ui, page, *) {
    global AutomationPanel2LastPage
    colors := ModernPanelColors()
    for key, item in ui["nav"] {
        if (key = page) {
            item["style"] := AutomationPanelNavStyle(colors["navSelected"], colors["text"], true, item["icon"], colors["accent"])
            item["hover"] := ""
        } else {
            item["style"] := AutomationPanelNavStyle("", colors["text"], false, item["icon"], colors["icon"])
            item["hover"] := AutomationPanelNavStyle(colors["tileHover"], colors["text"], false, item["icon"], colors["iconHover"])
        }
    }
    ModernPanelShowPage(ui, page)
    AutomationPanel2LastPage := page
    if ui.Has("search") {
        isShortcutPage := page = "apps" || page = "folders"
        ui["search"].Visible := isShortcutPage
        if isShortcutPage {
            try ui["search"].Focus()
            Panel2ApplySearch(ui, false)
        }
    }
}

CycleAutomationPanel2Page(step) {
    global AutomationPanel2Ui
    pages := AutomationPanel2Pages()
    index := 1
    for i, item in pages
        if (item["key"] = AutomationPanel2Ui["current"])
            index := i
    index := Mod(index - 1 + step + pages.Length, pages.Length) + 1
    Panel2SelectPage(AutomationPanel2Ui, pages[index]["key"])
}

; ---------- 快捷键作用域 ----------

Panel2HotkeysInit() {
    CustomHotkeyAddScope("panel2", "2号自动化面板", EnvGet("LOCALAPPDATA") . "\AutoHotkeyPanel\panel2-hotkeys.ini"
        , Panel2HotkeyCommands, "panel2.open", "!q")
    CustomHotkeysInit("panel2")
    static trayDone := false
    if !trayDone {
        ; 放在自动化面板的托盘项（打开、恢复快捷键、分隔线）之后
        A_TrayMenu.Insert("4&", "打开 2号自动化面板", (*) => OpenAutomationPanel2FromHotkey())
        A_TrayMenu.Insert("5&")
        trayDone := true
    }
}

; 2号面板可绑定快捷键的功能：入口、文件处理，以及每个常用软件 / 文件夹（id 由类型和路径算出，改名不变）。
Panel2HotkeyCommands() {
    commands := [
        Map("id", "panel2.open", "page", "面板入口", "name", "打开 2号自动化面板", "callback", OpenAutomationPanel2FromHotkey),
        Map("id", "panel2.gif", "page", "文件处理", "name", "MP4 转 GIF", "callback", ConvertSelectedVideosToGif),
        Map("id", "panel2.compressVideo", "page", "文件处理", "name", "压缩视频", "callback", CompressSelectedVideos),
        Map("id", "panel2.htmlPdf", "page", "文件处理", "name", "HTML 转 PDF", "callback", ConvertSelectedHtmlFilesToPdf)
    ]
    for item in Panel2LoadShortcuts()
        commands.Push(Map("id", Panel2ShortcutHotkeyId(item), "page", item["type"] = "folder" ? "常用文件夹" : "常用软件"
            , "name", "打开 " . item["name"], "callback", Panel2OpenShortcut.Bind(item), "noContext", true))
    return commands
}

; 常用软件 / 文件夹的快捷键 id：类型 + 路径（忽略大小写）的 FNV-1a 32 位哈希。
Panel2ShortcutHotkeyId(item) {
    text := StrLower(item["type"] . "|" . item["path"])
    hash := 0x811C9DC5
    loop parse text
        hash := ((hash ^ Ord(A_LoopField)) * 0x01000193) & 0xFFFFFFFF
    return "panel2.shortcut." . Format("{:08x}", hash)
}

Panel2HotkeyText() {
    global CustomHotkeyBindings
    return CustomHotkeyBindings.Has("panel2.open") ? CustomHotkeyDisplay(CustomHotkeyBindings["panel2.open"]) : "Alt+Q"
}

; ---------- 快捷方式数据 ----------

Panel2ShortcutsPath() {
    return EnvGet("LOCALAPPDATA") . "\AutoHotkeyPanel\panel2-shortcuts.tsv"
}

Panel2LoadShortcuts() {
    items := []
    path := Panel2ShortcutsPath()
    if !FileExist(path)
        return items
    try text := FileRead(path, "UTF-8")
    catch
        return items
    for line in StrSplit(text, "`n", "`r") {
        fields := StrSplit(line, "`t")
        if (fields.Length < 3 || !(fields[1] = "app" || fields[1] = "folder") || Trim(fields[3]) = "")
            continue
        item := Map("type", fields[1], "name", fields[2], "path", fields[3])
        if (fields.Length >= 4 && IsInteger(fields[4]))
            item["color"] := Integer(fields[4])
        items.Push(item)
    }
    return items
}

Panel2SaveShortcuts(items) {
    path := Panel2ShortcutsPath()
    SplitPath(path, , &directory)
    DirCreate(directory)
    text := ""
    for item in items
        text .= item["type"] . "`t" . StrReplace(item["name"], "`t", " ") . "`t" . item["path"]
            . (item.Has("color") && item["color"] ? "`t" . item["color"] : "") . "`r`n"
    tempPath := path . ".tmp"
    file := FileOpen(tempPath, "w", "UTF-8")   ; 新建文件时写入 BOM
    file.Write(text)
    file.Close()
    FileMove(tempPath, path, 1)
}

Panel2IndexOf(items, item) {
    for index, current in items
        if (current["type"] = item["type"] && current["path"] = item["path"])
            return index
    return 0
}

Panel2ShortcutExists(item) {
    return item["type"] = "folder" ? DirExist(item["path"]) != "" : FileExist(item["path"]) != ""
}

Panel2DefaultName(path) {
    path := RTrim(path, "\")
    if RegExMatch(path, "^[A-Za-z]:$")
        return path . "\"
    SplitPath(path, &fileName, , , &nameNoExt)
    return DirExist(path) ? fileName : nameNoExt
}

; 选区快照里属于该类型的路径（软件页只取文件，文件夹页只取文件夹）。
Panel2SelectedPaths(type) {
    global AutomationSelectedFilePaths
    paths := []
    for filePath in AutomationSelectedFilePaths
        if ((DirExist(filePath) != "") = (type = "folder"))
            paths.Push(filePath)
    return paths
}

; 加入一批路径：文件夹进“常用文件夹”，其余进“常用软件”；已存在的跳过。完成后刷新面板并停在对应页面。
Panel2AddPaths(paths, *) {
    items := Panel2LoadShortcuts()
    added := 0, skipped := 0, lastType := ""
    for filePath in paths {
        filePath := RTrim(filePath, "\")
        if RegExMatch(filePath, "^[A-Za-z]:$")
            filePath .= "\"
        kind := DirExist(filePath) ? "folder" : "app"
        item := Map("type", kind, "name", Panel2DefaultName(filePath), "path", filePath)
        lastType := kind
        if Panel2IndexOf(items, item) {
            skipped += 1
            continue
        }
        items.Push(item)
        added += 1
    }
    if added
        Panel2SaveShortcuts(items)
    if (lastType = "")
        return
    Panel2Build(lastType = "folder" ? "folders" : "apps", true)
    Panel2SetInfo("已添加 " . added . " 个" . (skipped ? "，" . skipped . " 个已在列表里" : ""), "双击打开，右键可改名、调整顺序或删除。")
}

Panel2AddByDialog(type, *) {
    global AutomationPanel2Gui
    try AutomationPanel2Gui.Opt("+OwnDialogs")
    if (type = "folder") {
        folder := DirSelect("", 0, "选择要加入“常用文件夹”的文件夹")
        if (folder != "")
            Panel2AddPaths([folder])
        return
    }
    selected := FileSelect("M3", "", "选择要加入“常用软件”的程序或快捷方式"
        , "程序与快捷方式 (*.exe; *.lnk; *.url; *.bat; *.cmd; *.ps1; *.ahk; *.msc)")
    if !IsObject(selected) || !selected.Length
        return
    Panel2AddPaths(selected)
}

Panel2OnDropFiles(guiObj, guiCtrlObj, fileArray, x, y) {
    Panel2AddPaths(fileArray)
}

Panel2SetInfo(title, detail) {
    global AutomationPanel2Ui
    ui := AutomationPanel2Ui
    if !IsObject(ui)
        return
    ui["infoTitle"]["text"] := title
    ui["infoDetail"]["text"] := detail
    ModernPanelInvalidate(ui)
}

; 单击：高亮该项并在顶部信息行显示完整路径。
Panel2SelectShortcut(ui, element, item, *) {
    global CustomHotkeyBindings
    for tile in ui["shortcutTiles"]
        tile["style"] := tile["normalStyle"]
    element["style"] := element["selectedStyle"]
    ui["selectedTile"] := element
    hotkeyId := Panel2ShortcutHotkeyId(item)
    keyText := CustomHotkeyBindings.Has(hotkeyId) ? CustomHotkeyDisplay(CustomHotkeyBindings[hotkeyId]) . " · " : ""
    Panel2SetInfo(item["name"], keyText . (element["exists"] ? "" : "找不到：") . item["path"])
}

Panel2OpenShortcut(item, *) {
    global AutomationPanel2Gui
    if !Panel2ShortcutExists(item) {
        try AutomationPanel2Gui.Opt("+OwnDialogs")
        MsgBox("找不到“" . item["name"] . "”：`n" . item["path"] . "`n`n可右键选择“删除”，或重新添加。", "2号自动化面板", "Icon!")
        return
    }
    try AutomationPanel2Gui.Hide()
    try {
        if (item["type"] = "folder") {
            Run('explorer.exe "' . item["path"] . '"')
        } else {
            SplitPath(item["path"], , &directory, &extension)
            if (extension = "exe")
                Run('"' . item["path"] . '"', directory)
            else
                Run('"' . item["path"] . '"')
        }
    } catch as err {
        MsgBox("打开失败：" . err.Message, "2号自动化面板", "Icon!")
    }
}

; ---------- 右键菜单（柔彩卡片风格，自绘） ----------
; 顶部是条目信息块（该条目自己的淡彩底 + 图标 + 名称 + 路径），下面是带线性图标的菜单项、一排颜色圆点、
; 前移 / 后移两个小按钮和红色的删除。不抢焦点（WS_EX_NOACTIVATE），菜单外按下鼠标、按 Esc、面板失去前台时关闭。
global Panel2Popup := ""
global Panel2PopupTimer := ""
global Panel2PopupMouseDown := false

Panel2ShortcutMenu(item, *) {
    global AutomationPanel2Ui, AutomationPanel2Gui, Panel2Popup, Panel2PopupTimer, Panel2PopupMouseDown
    Panel2PopupClose()
    ui := AutomationPanel2Ui
    ; 右键的条目同时选中，让人看清操作的是哪一张卡片
    for tile in ui["shortcutTiles"]
        if (tile["item"]["type"] = item["type"] && tile["item"]["path"] = item["path"]) {
            Panel2SelectShortcut(ui, tile, tile["item"])
            break
        }

    colors := ModernPanelColors()
    exists := Panel2ShortcutExists(item)
    color := Panel2ItemColor(item)
    pop := ModernPanelCreate("2号面板菜单", "-Caption +ToolWindow +AlwaysOnTop +E0x08000000 +Owner" . AutomationPanel2Gui.Hwnd, true)
    g := pop["gui"]
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 34, "UInt*", ModernPanelColorRef(colors["tileBorder"]), "UInt", 4)
    w := 262, pad := 8, y := pad

    ; 信息块
    info := Panel2CardStyle(item, exists, "", "normal")
    info["shadow"] := 0
    info["radius"] := 10
    info["padding"] := 12
    info["imageSize"] := 26
    info["subtext"] := item["path"]
    ModernPanelAddElement(pop, pad, y, w - pad * 2, 52, item["name"], info)
    y += 52 + 6

    entries := [
        Map("text", "打开", "icon", Chr(0xE8A7), "action", () => Panel2OpenShortcut(item), "enabled", exists, "bold", true),
        Map("text", "打开所在位置", "icon", Chr(0xE838), "action", () => Panel2RevealShortcut(item), "enabled", exists),
        Map("sep", true),
        Map("text", "重命名…", "icon", Chr(0xE8AC), "action", () => Panel2RenameShortcut(item))
    ]
    for en in entries {
        if en.Has("sep") {
            Panel2PopupSeparator(pop, w, &y)
            continue
        }
        Panel2PopupItem(pop, pad, y, w - pad * 2, en)
        y += 34
    }

    ; 颜色：一排圆点，当前颜色外圈描边；“自动”按路径配色
    ModernPanelLabelAt(pop, pad + 12, y, 60, 30, "颜色", ModernPanelTextStyle(colors["secondary"], 9))
    current := (item.Has("color") && item["color"] >= 1 && item["color"] <= Panel2Palette().Length) ? item["color"] : 0
    dotX := pad + 48
    autoStyle := ModernPanelStyle(current = 0 ? "EEF4FE" : "F3F5F8", current = 0 ? "1D4ED8" : colors["secondary"], current = 0)
    autoStyle["radius"] := 10, autoStyle["size"] := 8.5
    autoHover := ModernPanelStyle("E6EFFE", "1D4ED8", current = 0)
    autoHover["radius"] := 10, autoHover["size"] := 8.5
    ModernPanelAddElement(pop, dotX, y + 5, 42, 20, "自动", autoStyle, autoHover, Panel2PopupAction(() => Panel2SetShortcutColor(item, 0)))
    dotX += 50
    for index, entry in Panel2Palette() {
        if (index = current) {
            ring := ModernPanelStyle("FFFFFF", colors["text"])
            ring["radius"] := 11, ring["border"] := entry[3]
            ModernPanelLabelAt(pop, dotX - 3, y + 4, 22, 22, "", ring)
        }
        dot := ModernPanelStyle(entry[3], colors["text"])
        dot["radius"] := 8
        dotHover := ModernPanelStyle(Panel2Mix(entry[3], "000000", 0.12), colors["text"])
        dotHover["radius"] := 8
        ModernPanelAddElement(pop, dotX, y + 7, 16, 16, "", dot, dotHover, Panel2PopupAction(Panel2SetShortcutColor.Bind(item, index)))
        dotX += 18
    }
    y += 32

    ; 前移 / 后移：一行两个小按钮
    half := (w - pad * 2 - 6) // 2
    for index, move in [["前移", Chr(0xE76B), -1], ["后移", Chr(0xE76C), 1]] {
        style := Panel2PopupStyle("F7F8FA", colors["text"], move[2], colors["icon"])
        style["align"] := "center"
        hover := Panel2PopupStyle(colors["tileHover"], colors["text"], move[2], colors["iconHover"])
        hover["align"] := "center"
        ModernPanelAddElement(pop, pad + (index - 1) * (half + 6), y + 2, half, 30, move[1], style, hover
            , Panel2PopupAction(Panel2MoveShortcut.Bind(item, move[3])))
    }
    y += 36
    Panel2PopupSeparator(pop, w, &y)
    Panel2PopupItem(pop, pad, y, w - pad * 2, Map("text", "从列表删除", "icon", Chr(0xE74D), "action", () => Panel2DeleteShortcut(item), "danger", true))
    y += 34
    height := y + pad

    ; 位置：鼠标右下方，放不下就往上 / 往左挪
    scale := A_ScreenDPI / 96
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    area := Panel2WorkArea(AutomationPanel2Gui.Hwnd)
    x := Min(mx + 2, area[3] - Round(w * scale) - 4)
    yy := my + 2
    if (yy + height * scale > area[4])
        yy := Max(area[2], my - Round(height * scale) - 2)
    Panel2Popup := pop
    g.Show("NA x" . x . " y" . yy . " w" . w . " h" . height)
    Panel2PopupMouseDown := Panel2AnyMouseDown()
    Panel2PopupTimer := Panel2PopupWatch
    SetTimer(Panel2PopupTimer, 60)
}

Panel2PopupStyle(fill, textColor, icon, iconColor, bold := false) {
    style := ModernPanelDecorate(ModernPanelStyle(fill, textColor, bold, "left"), "", icon, iconColor)
    style["radius"] := 8
    style["padding"] := 12
    return style
}

; 菜单项：enabled 为假变淡不可点；danger 为红色；bold 为默认项（加粗）。
Panel2PopupItem(pop, x, y, w, en) {
    colors := ModernPanelColors()
    enabled := !en.Has("enabled") || en["enabled"]
    danger := en.Has("danger") && en["danger"]
    bold := en.Has("bold") && en["bold"]
    textColor := !enabled ? colors["disabled"] : danger ? colors["error"] : colors["text"]
    iconColor := !enabled ? colors["iconDisabled"] : danger ? colors["error"] : colors["icon"]
    style := Panel2PopupStyle("", textColor, en["icon"], iconColor, bold)
    hover := enabled ? Panel2PopupStyle(danger ? "FDECEC" : colors["tileHover"], textColor, en["icon"]
        , danger ? colors["error"] : colors["iconHover"], bold) : ""
    ModernPanelAddElement(pop, x, y, w, 32, en["text"], style, hover, enabled ? Panel2PopupAction(en["action"]) : "")
}

Panel2PopupSeparator(pop, w, &y) {
    colors := ModernPanelColors()
    line := ModernPanelStyle(colors["separator"], colors["text"])
    line["radius"] := 0
    ModernPanelLabelAt(pop, 16, y + 4, w - 32, 1, "", line)
    y += 9
}

; 点菜单项：先关菜单再执行
Panel2PopupAction(action) {
    return () => (Panel2PopupClose(), action())
}

Panel2PopupIsOpen() {
    global Panel2Popup
    return IsObject(Panel2Popup)
}

Panel2AnyMouseDown() {
    return GetKeyState("LButton", "P") || GetKeyState("RButton", "P") || GetKeyState("MButton", "P")
}

; 菜单外新按下鼠标、按 Esc、面板不在前台或已隐藏时关闭菜单。
Panel2PopupWatch() {
    global Panel2Popup, Panel2PopupMouseDown, AutomationPanel2Gui
    if !IsObject(Panel2Popup)
        return Panel2PopupClose()
    down := Panel2AnyMouseDown()
    pressed := down && !Panel2PopupMouseDown
    Panel2PopupMouseDown := down
    if GetKeyState("Escape", "P")
        return Panel2PopupClose()
    if pressed {
        CoordMode("Mouse", "Screen")
        MouseGetPos(, , &win)
        if (win != Panel2Popup["gui"].Hwnd)
            return Panel2PopupClose()
    }
    panelHwnd := 0
    try panelHwnd := AutomationPanel2Gui.Hwnd
    active := WinExist("A")
    if (!panelHwnd || !DllCall("IsWindowVisible", "Ptr", panelHwnd) || (active && active != panelHwnd && active != Panel2Popup["gui"].Hwnd))
        Panel2PopupClose()
}

Panel2PopupClose() {
    global Panel2Popup, Panel2PopupTimer
    if IsObject(Panel2PopupTimer) {
        SetTimer(Panel2PopupTimer, 0)
        Panel2PopupTimer := ""
    }
    pop := Panel2Popup
    Panel2Popup := ""
    if !IsObject(pop)
        return
    hwnd := pop["gui"].Hwnd
    ModernPanelReleaseCanvas(pop)
    ModernPanelRegistry().Delete(hwnd)
    try pop["gui"].Destroy()
}

Panel2WorkArea(hwnd) {
    monitor := DllCall("MonitorFromWindow", "Ptr", hwnd, "UInt", 2, "Ptr")
    info := Buffer(40, 0)
    NumPut("UInt", 40, info, 0)
    DllCall("GetMonitorInfoW", "Ptr", monitor, "Ptr", info)
    return [NumGet(info, 20, "Int"), NumGet(info, 24, "Int"), NumGet(info, 28, "Int"), NumGet(info, 32, "Int")]
}

Panel2RevealShortcut(item) {
    global AutomationPanel2Gui
    try AutomationPanel2Gui.Hide()
    path := RTrim(item["path"], "\")
    if RegExMatch(path, "^[A-Za-z]:$")
        Run('explorer.exe "' . path . '\"')
    else
        Run('explorer.exe /select,"' . path . '"')
}

Panel2SetShortcutColor(item, colorIndex, *) {
    items := Panel2LoadShortcuts()
    index := Panel2IndexOf(items, item)
    if !index
        return
    if colorIndex
        items[index]["color"] := colorIndex
    else if items[index].Has("color")
        items[index].Delete("color")
    Panel2SaveShortcuts(items)
    Panel2Build(item["type"] = "folder" ? "folders" : "apps", true)
}

Panel2RenameShortcut(item) {
    global AutomationPanel2Gui
    try AutomationPanel2Gui.Opt("+OwnDialogs")
    input := InputBox("新的显示名称（只改面板里的名字，不改文件）：", "重命名", "w360 h130", item["name"])
    name := Trim(input.Value)
    if (input.Result != "OK" || name = "" || name = item["name"])
        return
    items := Panel2LoadShortcuts()
    index := Panel2IndexOf(items, item)
    if !index
        return
    items[index]["name"] := name
    Panel2SaveShortcuts(items)
    Panel2Build(item["type"] = "folder" ? "folders" : "apps", true)
}

; 在同类型条目之间前后移动一位。
Panel2MoveShortcut(item, step) {
    items := Panel2LoadShortcuts()
    index := Panel2IndexOf(items, item)
    if !index
        return
    target := index + step
    while (target >= 1 && target <= items.Length && items[target]["type"] != item["type"])
        target += step
    if (target < 1 || target > items.Length)
        return
    swap := items[target]
    items[target] := items[index]
    items[index] := swap
    Panel2SaveShortcuts(items)
    Panel2Build(item["type"] = "folder" ? "folders" : "apps", true)
}

Panel2DeleteShortcut(item) {
    global AutomationPanel2Gui, CustomHotkeyBindings
    try AutomationPanel2Gui.Opt("+OwnDialogs")
    if (MsgBox("从列表删除“" . item["name"] . "”？`n（只删面板里的条目，不删除文件）", "2号自动化面板", "OKCancel Icon? Default2") != "OK")
        return
    items := Panel2LoadShortcuts()
    index := Panel2IndexOf(items, item)
    if !index
        return
    items.RemoveAt(index)
    Panel2SaveShortcuts(items)
    ; 条目删掉后它的快捷键也一并取消
    hotkeyId := Panel2ShortcutHotkeyId(item)
    if CustomHotkeyBindings.Has(hotkeyId) {
        CustomHotkeyUnregister(hotkeyId)
        CustomHotkeySave("panel2")
    }
    Panel2Build(item["type"] = "folder" ? "folders" : "apps", true)
}
