#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
global AutomationPanelGui := ""
global AutomationPanelUi := ""
global AutomationContextHwnd := 0
global AutomationSelectedFilePaths := []
global AutomationSpreadsheetSelectionContext := ""
global AutomationPanelLastPage := "table"
global SelectedDwgPath := ""
global ExcelCommandUndoStack := []
global SpreadsheetRepeatAction := ""
global SpreadsheetRepeatPending := ""
global InputMethodProfileKey := "HKCU\Control Panel\International\User Profile"
global ShareSelfTest := A_Args.Length && A_Args[1] = "--self-test"
A_IconTip := "工具面板（分享版）：Ctrl+Shift+E"
A_TrayMenu.Add("退出表格工具面板", (*) => ExitApp())
if ShareSelfTest {
    Suspend(true)
    ShowSharePanel()
    for page in SharePanelPages()
        SelectAutomationPanelPage(AutomationPanelUi, page["key"], false)
    FileAppend("SHARE_PANEL_START_OK`n", "*", "UTF-8")
    SetTimer(() => ExitApp(0), -2000)
}

^+e::ShowSharePanel()
#HotIf WinActive("ahk_exe EXCEL.EXE") && ExcelCommandUndoStack.Length > 0
$^z::UndoExcelCommandPanelAction()
#HotIf SharePanelIsActive()
^Tab::CycleSharePanelPage(1)
^+Tab::CycleSharePanelPage(-1)
#HotIf

SharePanelIsActive() {
    global AutomationPanelGui
    try return IsObject(AutomationPanelGui) && WinActive("ahk_id " . AutomationPanelGui.Hwnd)
    return false
}

SharePanelPages() {
    static pages := [
        Map("key", "table", "title", "表格工具", "icon", Chr(0xE80A)),
        Map("key", "dwg", "title", "CAD 图纸", "icon", Chr(0xE8E5)),
        Map("key", "rename", "title", "批量改名", "icon", Chr(0xE8AC)),
        Map("key", "files", "title", "转成 PDF", "icon", Chr(0xE8A5)),
        Map("key", "ime", "title", "默认输入法", "icon", Chr(0xE765)),
        Map("key", "help", "title", "使用说明", "icon", Chr(0xE897))
    ]
    return pages
}

CycleSharePanelPage(step) {
    global AutomationPanelUi
    pages := SharePanelPages()
    index := 1
    for i, page in pages
        if (page["key"] = AutomationPanelUi["current"])
            index := i
    index := Mod(index - 1 + step + pages.Length, pages.Length) + 1
    SelectAutomationPanelPage(AutomationPanelUi, pages[index]["key"])
}

ShowSharePanel() {
    global AutomationPanelGui, AutomationPanelUi, AutomationContextHwnd, AutomationSelectedFilePaths
    global AutomationSpreadsheetSelectionContext, SelectedDwgPath, ShareSelfTest
    static isOpening := false
    if isOpening
        return
    isOpening := true
    try {
        AutomationSelectedFilePaths := []
        AutomationSpreadsheetSelectionContext := ""
        if !ShareSelfTest {
            AutomationContextHwnd := WinExist("A")
            contextClass := ""
            try contextClass := WinGetClass("ahk_id " . AutomationContextHwnd)
            if (contextClass = "CabinetWClass" || contextClass = "ExploreWClass"
                || contextClass = "Progman" || contextClass = "WorkerW")
                AutomationSelectedFilePaths := DeduplicateSelectedFilePaths(ShareReadSelectedFiles(AutomationContextHwnd))
            else
                AutomationSpreadsheetSelectionContext := CaptureSpreadsheetSelectionContext(AutomationContextHwnd)
        }
        SelectedDwgPath := GetSelectedDwgPath()
        if IsObject(AutomationPanelGui)
            try AutomationPanelGui.Destroy()

        panelContext := DescribeAutomationPanelContext()
        fileCount := AutomationSelectedFilePaths.Length
        hasFiles := fileCount > 0
        hasDwg := SelectedDwgPath != ""
        colors := ModernPanelColors()
        ui := ModernPanelCreate("工具面板（分享版）")
        panel := ui["gui"]

        if (colors["sidebar"] != "") {
            sidebarStyle := ModernPanelStyle(colors["sidebar"], colors["text"])
            sidebarStyle["radius"] := 0
            ModernPanelLabelAt(ui, 0, 0, 188, 586, "", sidebarStyle)
        }
        ModernPanelLabelAt(ui, 26, 20, 146, 26, "工具面板", ModernPanelTextStyle(colors["text"], 13, true))
        ModernPanelLabelAt(ui, 26, 46, 146, 18, "Ctrl+Shift+E", ModernPanelTextStyle(colors["secondary"], 9))
        navItems := Map()
        navY := 84
        for page in SharePanelPages() {
            navItems[page["key"]] := ModernPanelAddElement(ui, 14, navY, 160, 34, page["title"]
                , AutomationPanelNavStyle("", colors["text"], false, page["icon"], colors["icon"]), ""
                , SelectAutomationPanelPage.Bind(ui, page["key"], true))
            navItems[page["key"]]["icon"] := page["icon"]
            navY += 38
        }
        ui["nav"] := navItems
        ModernPanelLabelAt(ui, 26, 546, 160, 20, "Esc 关闭 · Ctrl+Tab 切换", ModernPanelTextStyle(colors["secondary"], 9))
        separatorStyle := ModernPanelStyle(colors["separator"], colors["text"])
        separatorStyle["radius"] := 0
        ModernPanelLabelAt(ui, 188, 0, 1, 586, "", separatorStyle)

        infoStyle := ModernPanelStyle(colors["info"], colors["text"])
        ModernPanelLabelAt(ui, 208, 16, 432, 62, "", infoStyle)
        ModernPanelLabelAt(ui, 222, 16, 20, 62, ""
            , ModernPanelDecorate(ModernPanelTextStyle(colors["icon"]), "", Chr(panelContext["isError"] ? 0xE7BA : 0xE946)
                , panelContext["isError"] ? colors["error"] : colors["icon"]))
        ModernPanelLabelAt(ui, 250, 24, 380, 24, panelContext["title"], ModernPanelTextStyle(colors["text"], 11, true))
        ModernPanelLabelAt(ui, 250, 48, 380, 24, panelContext["detail"]
            , ModernPanelTextStyle(panelContext["isError"] ? colors["error"] : colors["secondary"], 9))

        contentX := 208
        contentY := 92
        contentW := 432

        ModernPanelBeginPage(ui, "table", contentX, contentY, contentW)
        tableEnabled := IsObject(AutomationSpreadsheetSelectionContext) && AutomationSpreadsheetSelectionContext.Has("selectionAddress")
; @SPREADSHEET_BUTTONS@

        ModernPanelBeginPage(ui, "dwg", contentX, contentY, contentW)
        ModernPanelSection(ui, "选中的 DWG 文件")
        if hasDwg {
            SplitPath(SelectedDwgPath, &dwgName)
            ModernPanelCard(ui, dwgName, "", Chr(0xE8A5))
        } else {
            ModernPanelCard(ui, "未选中 DWG 文件", colors["secondary"], Chr(0xE8A5))
        }
        ModernPanelRow(ui, ["用默认程序打开", ShareOpenDwgFile.Bind(false), hasDwg, Chr(0xE8E5)]
            , ["选择打开方式", ShareOpenDwgFile.Bind(true), hasDwg, Chr(0xE7AC)])
        ModernPanelSpace(ui, 6)
        ModernPanelSection(ui, "CAD 里正在编辑的图纸")
        ModernPanelRow(ui, ["强制关闭", ForceCloseActiveCadDrawing, true, Chr(0xE711)]
            , ["保存并关闭", SaveAndCloseActiveCadDrawing, true, Chr(0xE74E)]
            , ["保存并重开", SaveAndReopenActiveCadDrawing, true, Chr(0xE777)])
        ModernPanelNote(ui, "支持中望 CAD 和 AutoCAD，作用于打开面板前所在 CAD 的当前图纸；强制关闭不保存、不确认。", 2)

        ModernPanelBeginPage(ui, "rename", contentX, contentY, contentW)
        ModernPanelSection(ui, "添加")
        ModernPanelRow(ui, ["添加固定前缀", AddFixedTextToSelectedFileNames.Bind("prefix"), hasFiles, Chr(0xE710)]
            , ["添加固定后缀", AddFixedTextToSelectedFileNames.Bind("suffix"), hasFiles, Chr(0xE710)])
        ModernPanelRow(ui, ["按顺序添加数字前缀", AddSequentialNumberPrefixToSelectedFileNames, hasFiles, Chr(0xE8FD)])
        ModernPanelSpace(ui, 6)
        ModernPanelSection(ui, "删除与替换")
        ModernPanelRow(ui, ["删除前端文字", RemoveTextFromSelectedFileNames.Bind("start"), hasFiles, Chr(0xE738)]
            , ["删除末尾文字", RemoveTextFromSelectedFileNames.Bind("end"), hasFiles, Chr(0xE738)])
        ModernPanelRow(ui, ["替换文件名中的文字", ReplaceCustomTextInSelectedFileNames, hasFiles, Chr(0xE8AC)]
            , ["将 ML 替换为目录", ReplaceTextInSelectedFileNames, hasFiles, Chr(0xE8B7)])
        ModernPanelNote(ui, hasFiles
            ? "将处理选中的 " . fileCount . " 个文件，文件夹会被跳过。改名前会显示预览并要求确认，扩展名保持不变。"
            : "请先在资源管理器或桌面选中文件，再按 Ctrl+Shift+E。改名前会显示预览并要求确认。")

        ModernPanelBeginPage(ui, "files", contentX, contentY, contentW)
        ModernPanelSection(ui, "转换")
        ModernPanelRow(ui, ["Word 转 PDF", ConvertSelectedWordFilesToPdf, hasFiles, Chr(0xE8A5)]
            , ["Excel 转 PDF", ConvertSelectedExcelFilesToPdf, hasFiles, Chr(0xE80A)])
        ModernPanelNote(ui, "需要已安装 Microsoft Word / Excel。转换后保存为同目录同名 PDF，Excel 会导出整个工作簿；源文件只读打开、不修改，覆盖已有 PDF 前会先确认。", 3)

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

        ModernPanelBeginPage(ui, "help", contentX, contentY, contentW)
        ModernPanelSection(ui, "使用方法")
        ModernPanelNote(ui
            , "1. 先在 Excel / WPS 里选中单元格，或在资源管理器、桌面里选中文件。`n"
            . "2. 按 Ctrl+Shift+E 打开面板，会自动切到对应页面。`n"
            . "3. 点击按钮执行；没有对应选区的按钮会变灰。", 4)
        ModernPanelSection(ui, "撤销与保存")
        ModernPanelNote(ui, "表格操作不会自动保存。Excel 中可直接 Ctrl+Z 撤销面板操作；WPS 请用“表格工具”里的撤销按钮。“重复上次操作”把上一次表格操作直接套用到新选区。切到面板后选区高亮可能隐藏，操作仍使用已锁定范围。", 5)

        SelectAutomationPanelPage(ui, panelContext["page"], false)
        panel.OnEvent("Close", (*) => panel.Hide())
        created := A_TickCount
        panel.OnEvent("Escape", (*) => (A_TickCount - created > 400) ? panel.Hide() : 0)
        AutomationPanelGui := panel
        AutomationPanelUi := ui
        if !ShareSelfTest
            panel.Show("w656 h586 Center")
    } finally {
        SetTimer(() => isOpening := false, -300)
    }
}

; 通过资源管理器原生 Ctrl+C 读取当前选中的文件（CF_HDROP），读取后恢复原剪贴板。
ShareReadSelectedFiles(hwnd) {
    selected := []
    savedClipboard := ClipboardAll()
    try {
        if (WinExist("A") != hwnd)
            WinActivate("ahk_id " . hwnd)
        if (WinExist("A") != hwnd && !WinWaitActive("ahk_id " . hwnd, , 2))
            return selected
        A_Clipboard := ""
        Send("^c")
        if ClipWait(1, 1)
            selected := GetClipboardFileDropPaths()
    } finally {
        A_Clipboard := savedClipboard
    }
    return selected
}

; 分享版不假设对方装了哪款 CAD：用系统默认关联程序打开，或弹出 Windows“打开方式”自己选。
ShareOpenDwgFile(chooseProgram, *) {
    global SelectedDwgPath
    title := "打开 DWG 图纸"
    if (SelectedDwgPath = "" || !FileExist(SelectedDwgPath)) {
        MsgBox("选中的 DWG 文件已不存在或无法访问。请重新选择图纸后再按 Ctrl+Shift+E。", title, "Icon!")
        return
    }
    try {
        if chooseProgram
            Run('rundll32.exe shell32.dll,OpenAs_RunDLL ' . SelectedDwgPath)
        else
            Run('"' . SelectedDwgPath . '"')
    } catch as err {
        MsgBox("无法打开图纸：`n`n" . SelectedDwgPath . "`n`n" . err.Message
            . (chooseProgram ? "" : "`n`n可能没有程序关联 .dwg，请改用“选择打开方式”。"), title, "Icon!")
    }
}
