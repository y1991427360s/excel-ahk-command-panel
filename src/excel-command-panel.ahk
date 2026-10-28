#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
#Include spreadsheet-export.ahk
#Include spreadsheet-numeric-offset.ahk
#Include spreadsheet-text-transform.ahk
#Include copyq-guard.ahk
#Include input-method-switch.ahk
#Include modern-panel-ui.ahk
#Include cad-report-card.ahk

global AutomationPanelGui := ""
global AutomationContextHwnd := 0
global AutomationSelectedFilePaths := []
global AutomationSpreadsheetSelectionContext := ""
global ExcelCommandUndoStack := []
global AutomationPanelLastPage := "table"
global AutomationPanelUi := ""
global SelectedDwgPath := ""
global CopyQExe := "D:\CopyQ\copyq.exe"
global AaLspPath := "D:\Syncthing\Oracle-Sync\LISP\ZW-auto_lisp\AA整合版本.lsp"
global AcadAaLspPath := "D:\Syncthing\Oracle-Sync\LISP\AutoCAD2018_lisp\AA整合版本.lsp"
LogPanelDiagnostic("脚本初始化启动", "PID=" . ProcessExist() . "; ScriptHwnd=" . A_ScriptHwnd . "; Class=" . WinGetClass(A_ScriptHwnd))

LogPanelDiagnostic(eventName, details := "") {
    static logPath := ""
    try {
        if (logPath = "") {
            logDirectory := EnvGet("LOCALAPPDATA") . "\AutoHotkeyPanel"
            DirCreate(logDirectory)
            logPath := logDirectory . "\selection-debug.log"
        }
        logLine := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") . " [" . eventName . "]"
        if (details != "")
            logLine .= "`r`n" . details
        FileAppend(logLine . "`r`n", logPath, "UTF-8")
    }
}

^+e:: {
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

#HotIf WinActive("ahk_exe EXCEL.EXE") && ExcelCommandUndoStack.Length > 0
$^z::UndoExcelCommandPanelAction()
#HotIf AutomationPanelIsActive()
^Tab::CycleAutomationPanelPage(1)
^+Tab::CycleAutomationPanelPage(-1)
#HotIf

AutomationPanelIsActive() {
    global AutomationPanelGui
    try return IsObject(AutomationPanelGui) && WinActive("ahk_id " . AutomationPanelGui.Hwnd)
    return false
}

ShowAutomationPanel() {
    global AutomationPanelGui
    global AutomationPanelUi
    global AutomationContextHwnd
    global AutomationSelectedFilePaths
    global AutomationSpreadsheetSelectionContext
    global SelectedDwgPath

    AutomationContextHwnd := WinExist("A")
    try {
        contextClass := WinGetClass("ahk_id " . AutomationContextHwnd)
    } catch {
        contextClass := "无法读取窗口类名"
    }
    LogPanelDiagnostic("面板启动", "contextHwnd=" . AutomationContextHwnd . "; class=" . contextClass)
    AutomationSelectedFilePaths := []
    if (contextClass = "CabinetWClass" || contextClass = "ExploreWClass"
        || contextClass = "Progman" || contextClass = "WorkerW")
        AutomationSelectedFilePaths := DeduplicateSelectedFilePaths(
            GetSelectedFilePathsFromClipboard(AutomationContextHwnd)
        )
    else
        AutomationSelectedFilePaths := GetProjectAtlasSelectedFiles(AutomationContextHwnd)
    LogPanelDiagnostic("面板选区快照", "pathCount=" . AutomationSelectedFilePaths.Length
        . (AutomationSelectedFilePaths.Length ? "`r`n" . JoinLines(AutomationSelectedFilePaths) : "`r`n快照为空"))
    AutomationSpreadsheetSelectionContext := CaptureSpreadsheetSelectionContext(AutomationContextHwnd)
    SelectedDwgPath := GetSelectedDwgPath()

    if IsObject(AutomationPanelGui)
        try AutomationPanelGui.Destroy()

    panelContext := DescribeAutomationPanelContext()
    fileCount := AutomationSelectedFilePaths.Length
    hasFiles := fileCount > 0
    hasDwg := SelectedDwgPath != ""
    colors := ModernPanelColors()

    ui := ModernPanelCreate("自动化工具面板")
    panel := ui["gui"]

    ; 左侧边栏：浅灰底 + 应用名 + 带图标的页面导航（与桌宠右键菜单同一套配色和图标）
    if (colors["sidebar"] != "") {
        sidebarStyle := ModernPanelStyle(colors["sidebar"], colors["text"])
        sidebarStyle["radius"] := 0
        ModernPanelLabelAt(ui, 0, 0, 188, 540, "", sidebarStyle)
    }
    ModernPanelLabelAt(ui, 26, 20, 146, 26, "自动化工具", ModernPanelTextStyle(colors["text"], 13, true))
    ModernPanelLabelAt(ui, 26, 46, 146, 18, "Ctrl+Shift+E", ModernPanelTextStyle(colors["secondary"], 9))

    navItems := Map()
    navY := 84
    for page in AutomationPanelPages() {
        navItems[page["key"]] := ModernPanelAddElement(ui, 14, navY, 160, 34, page["title"]
            , AutomationPanelNavStyle("", colors["text"], false, page["icon"], colors["icon"]), ""
            , SelectAutomationPanelPage.Bind(ui, page["key"], true))
        navItems[page["key"]]["icon"] := page["icon"]
        navY += 38
    }
    ui["nav"] := navItems

    ModernPanelLabelAt(ui, 26, 500, 160, 20, "Esc 关闭 · Ctrl+Tab 切换", ModernPanelTextStyle(colors["secondary"], 9))
    separatorStyle := ModernPanelStyle(colors["separator"], colors["text"])
    separatorStyle["radius"] := 0
    ModernPanelLabelAt(ui, 188, 0, 1, 540, "", separatorStyle)

    ; 右侧顶部信息行：识别到的选区（同桌宠菜单顶部的状态信息行）
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
    tableEnabled := true
    ; @@SPREADSHEET_BUTTONS_BEGIN
    ModernPanelSection(ui, "文本")
    ModernPanelRow(ui
        , ["添加前缀", AddTextToExcelSelection.Bind("prefix"), tableEnabled, Chr(0xE710)]
        , ["添加后缀", AddTextToExcelSelection.Bind("suffix"), tableEnabled, Chr(0xE710)])
    ModernPanelRow(ui
        , ["删除前端字符", RemoveTextFromExcelSelection.Bind("start"), tableEnabled, Chr(0xE738)]
        , ["删除末尾字符", RemoveTextFromExcelSelection.Bind("end"), tableEnabled, Chr(0xE738)])
    ModernPanelRow(ui, ["删除括号内容并合并换行", RemoveBracketTextFromExcelSelection, tableEnabled, Chr(0xE74D)])
    ModernPanelSpace(ui, 6)
    ModernPanelSection(ui, "整理")
    ModernPanelRow(ui
        , ["去重整理", DedupeAndGroupExcelSelectedColumn, tableEnabled, Chr(0xE71C)]
        , ["按电缆截面排序", SortCableRowsByCrossSection, tableEnabled, Chr(0xE8CB)])
    ModernPanelRow(ui
        , ["合并相同内容并居中", MergeIdenticalSpreadsheetCells, tableEnabled, Chr(0xE8C8)]
        , ["拆分合并单元格并填充", SplitMergedSpreadsheetCellsAndFill, tableEnabled, Chr(0xE8C6)])
    ModernPanelSpace(ui, 6)
    ModernPanelSection(ui, "数字与其他")
    ModernPanelRow(ui
        , ["数字向上取十位", RoundSpreadsheetSelectionUpToTen, tableEnabled, Chr(0xE8EF)]
        , ["数字批量加减", OffsetSpreadsheetSelectionNumbers, tableEnabled, Chr(0xE70F)])
    ModernPanelRow(ui
        , ["导出选区信息（给 AI）", ExportSpreadsheetSelection, tableEnabled, Chr(0xE72D)]
        , ["撤销上次操作" . (ExcelCommandUndoStack.Length ? "（" . ExcelCommandUndoStack.Length . "）" : "")
            , UndoExcelCommandPanelAction, tableEnabled && ExcelCommandUndoStack.Length > 0, Chr(0xE7A7)])
    ; @@SPREADSHEET_BUTTONS_END

    ModernPanelBeginPage(ui, "dwg", contentX, contentY, contentW)
    ModernPanelSection(ui, "选中的 DWG 文件")
    if hasDwg {
        SplitPath(SelectedDwgPath, &dwgName)
        ModernPanelCard(ui, dwgName, "", Chr(0xE8A5))
    } else {
        ModernPanelCard(ui, "未选中 DWG 文件", colors["secondary"], Chr(0xE8A5))
    }
    ModernPanelSection(ui, "打开方式")
    ModernPanelRow(ui, ["AutoCAD", OpenSelectedDwg.Bind("autocad"), hasDwg, Chr(0xE8E5)]
        , ["中望 CAD", OpenSelectedDwg.Bind("zwcad"), hasDwg, Chr(0xE8E5)]
        , ["快速看图", OpenSelectedDwg.Bind("quickview"), hasDwg, Chr(0xE890)])
    ModernPanelSpace(ui, 6)
    ; 关闭/保存类按钮单独成组，并用“文字联动”一组隔开重载插件按钮，避免重载时误点关闭
    ModernPanelSection(ui, "CAD 里正在编辑的图纸")
    ModernPanelRow(ui, ["强制关闭", ForceCloseActiveCadDrawing, true, Chr(0xE711)]
        , ["保存并关闭", SaveAndCloseActiveCadDrawing, true, Chr(0xE74E)]
        , ["保存并重开", SaveAndReopenActiveCadDrawing, true, Chr(0xE777)])
    ModernPanelNote(ui, "作用于打开面板前所在 CAD 的当前图纸；强制关闭不保存、不确认。", 1)
    ModernPanelSpace(ui, 6)
    ModernPanelSection(ui, "文字联动标记（中望 CAD）")
    ModernPanelRow(ui, ["查看文字标记 SXC", RunZwcadCommand.Bind("SXC", "查看文字标记"), true, Chr(0xE721)])
    ModernPanelNote(ui, "执行 SXC：选文字或回车查全图，结果卡片里点条目定位。", 1)
    ModernPanelSpace(ui, 6)
    ModernPanelSection(ui, "重新加载 AA整合版本.lsp")
    ModernPanelRow(ui, ["重载中望 CAD 插件", ReloadZwcadAaLsp, true, Chr(0xE72C)], ["重载 AutoCAD 插件", ReloadAutocadAaLsp, true, Chr(0xE72C)])

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
    ModernPanelSection(ui, "转换与合并")
    ModernPanelRow(ui, ["合并选中的 PDF", MergeSelectedPdfFiles, hasFiles, Chr(0xE8F1)])
    ModernPanelRow(ui, ["Word 转 PDF", ConvertSelectedWordFilesToPdf, hasFiles, Chr(0xE8A5)]
        , ["Excel 转 PDF", ConvertSelectedExcelFilesToPdf, hasFiles, Chr(0xE80A)])
    ModernPanelNote(ui, "PDF 合并后保存到首个 PDF 所在文件夹；Word、Excel 转换后保存为同目录同名 PDF，Excel 会导出整个工作簿。覆盖已有 PDF 前会先确认。", 3)

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
    ModernPanelNote(ui, "表格操作不会自动保存。Excel 中可直接 Ctrl+Z 撤销面板操作；WPS 请用“表格工具”里的撤销按钮。", 3)

    SelectAutomationPanelPage(ui, panelContext["page"], false)

    panelCreatedTime := A_TickCount
    panel.OnEvent("Close", (*) => panel.Hide())
    panel.OnEvent("Escape", (*) => (A_TickCount - panelCreatedTime > 400) ? panel.Hide() : 0)

    AutomationPanelGui := panel
    AutomationPanelUi := ui
    panel.Show("w656 h540 Center")
}

AutomationPanelPages() {
    static pages := [
        Map("key", "table", "title", "表格工具", "icon", Chr(0xE80A)),
        Map("key", "dwg", "title", "打开图纸", "icon", Chr(0xE8E5)),
        Map("key", "rename", "title", "批量改名", "icon", Chr(0xE8AC)),
        Map("key", "files", "title", "文件处理", "icon", Chr(0xE8A5)),
        Map("key", "ime", "title", "默认输入法", "icon", Chr(0xE765)),
        Map("key", "help", "title", "使用说明", "icon", Chr(0xE897))
    ]
    return pages
}

SelectAutomationPanelPage(ui, page, remember := true, *) {
    global AutomationPanelLastPage
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
    ; “使用说明”不记忆，避免下次无选区时直接停在说明页。
    if (remember && page != "help")
        AutomationPanelLastPage := page
}

; 侧栏导航项：选中与否文字都保持同样的左内边距，避免切换时文字跳动。
AutomationPanelNavStyle(fill, textColor, bold := false, icon := "", iconColor := "") {
    style := ModernPanelDecorate(ModernPanelStyle(fill, textColor, bold, "left"), "", icon, iconColor)
    style["padding"] := 12
    return style
}

CycleAutomationPanelPage(step) {
    global AutomationPanelUi
    pages := AutomationPanelPages()
    index := 1
    for i, page in pages
        if (page["key"] = AutomationPanelUi["current"])
            index := i
    index := Mod(index - 1 + step + pages.Length, pages.Length) + 1
    SelectAutomationPanelPage(AutomationPanelUi, pages[index]["key"])
}

; 根据打开面板前的选区决定顶部状态文字和默认页面：表格优先，其次 DWG、文件，最后回到上次使用的页面。
DescribeAutomationPanelContext() {
    global AutomationContextHwnd
    global AutomationSelectedFilePaths
    global AutomationSpreadsheetSelectionContext
    global SelectedDwgPath
    global AutomationPanelLastPage

    snapshot := AutomationSpreadsheetSelectionContext
    if IsObject(snapshot) {
        if snapshot.Has("error")
            return Map("title", "表格选区读取失败", "detail", snapshot["error"], "isError", true, "page", "table")
        return Map(
            "title", snapshot["workbookName"],
            "detail", snapshot["name"] . " · 工作表 " . snapshot["worksheetName"] . " · 选区 " . StrReplace(snapshot["selectionAddress"], "$"),
            "isError", false,
            "page", "table"
        )
    }

    fileCount := AutomationSelectedFilePaths.Length
    if (fileCount > 0) {
        documentCount := 0
        for filePath in AutomationSelectedFilePaths {
            SplitPath(filePath, , , &extension)
            if RegExMatch(extension, "i)^(pdf|docx?|docm|xlsx?|xlsm|xlsb)$")
                documentCount += 1
        }
        SplitPath(AutomationSelectedFilePaths[1], &firstName)
        detail := fileCount = 1 ? firstName : firstName . " 等 " . fileCount . " 个文件"
        if (SelectedDwgPath != "")
            return Map("title", "已选中 DWG 图纸", "detail", detail, "isError", false, "page", "dwg")
        return Map(
            "title", "已选中 " . fileCount . " 个文件",
            "detail", detail,
            "isError", false,
            "page", documentCount = fileCount ? "files" : "rename"
        )
    }

    cadTarget := DetectAutomationContextCad()
    if IsObject(cadTarget) {
        windowTitle := ""
        try windowTitle := WinGetTitle("ahk_id " . AutomationContextHwnd)
        return Map("title", "当前窗口：" . cadTarget["name"], "detail", windowTitle, "isError", false, "page", "dwg")
    }

    return Map(
        "title", "未检测到选区",
        "detail", "先在 Excel / WPS 或资源管理器中选中内容，再按 Ctrl+Shift+E。",
        "isError", false,
        "page", AutomationPanelLastPage
    )
}

RoundSpreadsheetSelectionUpToTen() {
    title := "数字向上取十位"
    context := GetSpreadsheetSelectionContext(title)
    if !IsObject(context)
        return

    app := context["app"]
    selection := context["selection"]
    entries := []
    invalidAddress := ""
    invalidReason := ""

    try {
        for area in selection.Areas {
            for cell in area.Cells {
                address := cell.Address(false, false)
                if (cell.HasFormula) {
                    invalidAddress := address
                    invalidReason := "公式单元格"
                    break 2
                }

                value := cell.Value
                if (IsSpreadsheetDateFormattedCell(cell)) {
                    invalidAddress := address
                    invalidReason := "日期格式单元格"
                    break 2
                }
                if !IsSpreadsheetNativeNumber(value) {
                    invalidAddress := address
                    invalidReason := (value = "") ? "空白单元格" : "非数字单元格"
                    break 2
                }

                entries.Push(Map("cell", cell, "value", value))
            }
        }
    } catch as err {
        MsgBox("无法读取当前选区：" . err.Message, title, "Icon!")
        return
    }

    if (invalidReason != "") {
        MsgBox("选区中包含" . invalidReason . "（" . invalidAddress . "），本次未修改任何单元格。`n请只选择数字单元格。", title, "Icon!")
        return
    }
    if (entries.Length = 0) {
        MsgBox("当前选区没有可处理的数字单元格。", title, "Icon!")
        return
    }

    undoAction := CreateUndoAction(title, app, context["kind"])
    try {
        for _, entry in entries
            AddUndoCell(undoAction, entry["cell"])
    } catch as err {
        MsgBox("无法记录撤销信息：" . err.Message, title, "Icon!")
        return
    }

    oldScreenUpdating := GetSpreadsheetProperty(app, "ScreenUpdating", true)
    oldEnableEvents := GetSpreadsheetProperty(app, "EnableEvents", true)
    operationError := ""

    try {
        try app.ScreenUpdating := false
        try app.EnableEvents := false

        for _, entry in entries {
            entry["cell"].Value := Ceil(entry["value"] / 10) * 10
        }
    } catch as err {
        operationError := err.Message
        try RestoreUndoAction(app, undoAction)
        catch as rollbackError
            operationError .= Chr(10) . "回滚失败：" . rollbackError.Message
    } finally {
        try app.EnableEvents := oldEnableEvents
        try app.ScreenUpdating := oldScreenUpdating
    }

    if (operationError != "") {
        MsgBox("处理失败：" . operationError, title, "Icon!")
        return
    }

    PushUndoAction(undoAction)
}

IsSpreadsheetDateFormattedCell(cell) {
    format := ""
    try format := cell.NumberFormat
    catch
        return false

    if (format = "" || format = "General")
        return false

    ; Excel date formats contain date/time tokens outside quoted literals.
    normalized := RegExReplace(format, '"[^"]*"', "")
    return !!RegExMatch(normalized, "i)(^|[^a-z])(yyyy|yy|dd|d|hh|ss|m{1,4})([^a-z]|$)")
}

IsSpreadsheetNativeNumber(value) {
    valueType := Type(value)
    return valueType = "Integer" || valueType = "Float"
}

RunPanelCommand(callback) {
    global AutomationPanelGui
    try AutomationPanelGui.Hide()
    try callback.Call()
    catch as err
        MsgBox("操作失败：" . err.Message, "自动化工具面板", "Icon!")
}

SplitMergedSpreadsheetCellsAndFill(explicitContext := "") {
    title := "拆分合并单元格并填充"
    context := ""
    if IsObject(explicitContext) {
        context := explicitContext
    } else {
        ; 面板取得焦点后，Selection 可能发生变化；始终使用打开面板前的快照。
        context := GetSpreadsheetSelectionContext(title)
    }
    if !IsObject(context)
        return

    app := context["app"]
    selection := context["selection"]
    kind := context.Has("kind") ? context["kind"] : (context.Has("name") ? context["name"] : "excel")
    isSilent := (context.Has("silent") && context["silent"])
    undoAction := CreateUndoAction(title, app, kind)
    seenAddresses := Map()
    areaInfos := []

    ; 全局加速与环境保护：在扫描和操作前关闭屏幕刷新、事件与警告，切换为手动计算
    oldScreenUpdating := GetSpreadsheetProperty(app, "ScreenUpdating", true)
    oldEnableEvents := GetSpreadsheetProperty(app, "EnableEvents", true)
    oldDisplayAlerts := GetSpreadsheetProperty(app, "DisplayAlerts", true)
    oldCalculation := GetSpreadsheetProperty(app, "Calculation", -4105)
    oldDisplayPageBreaks := false
    oldView := 1

    try {
        try app.ScreenUpdating := false
        try app.EnableEvents := false
        try app.DisplayAlerts := false
        try app.Calculation := -4135 ; xlCalculationManual

        ; 整列选区包含超过一百万个单元格，不能直接遍历 area.Cells。
        ; 只扫描选区与 UsedRange 的交集，避免整列选择导致长时间卡顿。
        worksheet := selection.Worksheet
        try oldDisplayPageBreaks := worksheet.DisplayPageBreaks
        try worksheet.DisplayPageBreaks := false
        try oldView := app.ActiveWindow.View
        try app.ActiveWindow.View := 1 ; xlNormalView

        usedRange := worksheet.UsedRange
        usedFirstRow := usedRange.Row
        usedLastRow := usedFirstRow + usedRange.Rows.Count - 1
        usedFirstColumn := usedRange.Column
        usedLastColumn := usedFirstColumn + usedRange.Columns.Count - 1
        wbFullName := worksheet.Parent.FullName
        wsName := worksheet.Name

        for area in selection.Areas {
            firstRow := Max(area.Row, usedFirstRow)
            lastRow := Min(area.Row + area.Rows.Count - 1, usedLastRow)
            firstColumn := Max(area.Column, usedFirstColumn)
            lastColumn := Min(area.Column + area.Columns.Count - 1, usedLastColumn)
            if (firstRow > lastRow || firstColumn > lastColumn)
                continue

            areaRange := worksheet.Range(
                worksheet.Cells(firstRow, firstColumn),
                worksheet.Cells(lastRow, lastColumn)
            )
            if (areaRange.MergeCells == false)
                continue

            areaRowCount := lastRow - firstRow + 1
            areaColCount := lastColumn - firstColumn + 1
            areaValues := areaRange.Value2
            areaItems := []

            ; 优先尝试极速纯内存 XML 解析通道（将 2000+ 次 COM IPC 骤降至 1 次）
            hasParsedXml := false
            try {
                xmlStr := areaRange.Value(11) ; xlRangeValueXMLSpreadsheet
                if (Type(xmlStr) = "String" && InStr(xmlStr, "<Table")) {
                    curRelRow := 0
                    curRelCol := 0
                    inTable := false

                    ; 完整标签可能位于同一行，属性也可能跨行，不能按行解析。
                    xmlPosition := 1
                    while RegExMatch(xmlStr, "i)<(?:Table|Row|Cell)\b[^>]*>|</Table\s*>", &xmlTag, xmlPosition) {
                        line := xmlTag[0]
                        xmlPosition := xmlTag.Pos + xmlTag.Len
                        if (!inTable) {
                            if InStr(line, "<Table")
                                inTable := true
                            continue
                        }
                        if InStr(line, "</Table>")
                            break

                        ; 匹配行标签 <Row
                        if InStr(line, "<Row") {
                            if RegExMatch(line, 'i)ss:Index="(\d+)"', &mRow)
                                curRelRow := Integer(mRow[1])
                            else
                                curRelRow += 1
                            curRelCol := 0
                            continue
                        }

                        ; 匹配单元格标签 <Cell
                        if InStr(line, "<Cell") {
                            if RegExMatch(line, 'i)ss:Index="(\d+)"', &mCol)
                                curRelCol := Integer(mCol[1])
                            else
                                curRelCol += 1

                            hasMergeDown := RegExMatch(line, 'i)ss:MergeDown="(\d+)"', &downM)
                            hasMergeAcross := RegExMatch(line, 'i)ss:MergeAcross="(\d+)"', &acrossM)

                            if (hasMergeDown || hasMergeAcross) {
                                downCount := hasMergeDown ? Integer(downM[1]) : 0
                                acrossCount := hasMergeAcross ? Integer(acrossM[1]) : 0
                                mRowCount := downCount + 1
                                mColCount := acrossCount + 1

                                mStartRow := firstRow + curRelRow - 1
                                mEndRow := mStartRow + mRowCount - 1
                                mStartCol := firstColumn + curRelCol - 1
                                mEndCol := mStartCol + mColCount - 1

                                startColLetter := GetSpreadsheetColumnLetter(mStartCol)
                                endColLetter := (mColCount = 1) ? startColLetter : GetSpreadsheetColumnLetter(mEndCol)
                                rangeAddr := (mColCount = 1)
                                    ? startColLetter . mStartRow . ":" . startColLetter . mEndRow
                                    : startColLetter . mStartRow . ":" . endColLetter . mEndRow
                                firstAddr := startColLetter . mStartRow

                                if !seenAddresses.Has(rangeAddr) {
                                    seenAddresses[rangeAddr] := true
                                    firstVal := GetSpreadsheetMatrixValue(areaValues, curRelRow, curRelCol, areaRowCount, areaColCount)

                                    item := Map(
                                        "kind", "unmergeFill",
                                        "workbook", wbFullName,
                                        "sheet", wsName,
                                        "address", rangeAddr,
                                        "cells", [Map("address", firstAddr, "content", firstVal)],
                                        "fillContent", firstVal,
                                        "horizontalAlignment", "",
                                        "verticalAlignment", "",
                                        "applied", false
                                    )
                                    undoAction["items"].Push(item)
                                    areaItems.Push(item)

                                    fillRStart := curRelRow
                                    fillREnd := Min(curRelRow + mRowCount - 1, areaRowCount)
                                    fillCStart := curRelCol
                                    fillCEnd := Min(curRelCol + mColCount - 1, areaColCount)

                                    Loop (fillCEnd - fillCStart + 1) {
                                        fc := fillCStart + A_Index - 1
                                        Loop (fillREnd - fillRStart + 1) {
                                            fr := fillRStart + A_Index - 1
                                            if (areaRowCount = 1 && areaColCount = 1)
                                                areaValues := firstVal
                                            else
                                                areaValues[fr, fc] := firstVal
                                        }
                                    }
                                }
                            }
                        }
                    }
                    ; 找到 Table 却未识别到合并块时，必须进入兼容检测。
                    hasParsedXml := (areaItems.Length > 0)
                }
            }

            ; 兜底回退通道（例如 WPS 不支持 Value(11) 时）：高剪枝 COM 扫描通道
            if (!hasParsedXml) {
                Loop areaColCount {
                relCol := A_Index
                columnIndex := firstColumn + relCol - 1
                colRange := worksheet.Range(
                    worksheet.Cells(firstRow, columnIndex),
                    worksheet.Cells(lastRow, columnIndex)
                )
                if (colRange.MergeCells == false)
                    continue

                colLetter := GetSpreadsheetColumnLetter(columnIndex)

                ; 行指针跨步跳跃：结合内存 SafeArray 预筛与极简 COM 属性查询
                rowIndex := firstRow
                while (rowIndex <= lastRow) {
                    relR := rowIndex - firstRow + 1

                    ; 剪枝 1：利用内存 SafeArray，若当前单元格与下一单元格均非空，在 Excel 中绝对不可能跨行合并，直接跳过 COM 查询
                    if (relR < areaRowCount) {
                        curV := (areaRowCount = 1 && areaColCount = 1) ? areaValues : areaValues[relR, relCol]
                        nextV := (areaRowCount = 1 && areaColCount = 1) ? areaValues : areaValues[relR + 1, relCol]
                        if (curV != "" && nextV != "") {
                            ; 两个非空值绝不可能跨行合并。仅当多列选区且右侧为空时才可能跨列合并
                            if (areaColCount == 1 || (relCol < areaColCount && areaValues[relR, relCol + 1] != "")) {
                                rowIndex += 1
                                continue
                            }
                        }
                    }

                    cell := worksheet.Cells(rowIndex, columnIndex)
                    if (cell.MergeCells) {
                        ; 剪枝 2：一步链式读取 Rows.Count，杜绝多余 COM 对象赋值与 Columns.Count 查询
                        mRowCount := cell.MergeArea.Rows.Count
                        mColCount := 1
                        if (areaColCount > 1 && relCol < areaColCount && areaValues[relR, relCol + 1] == "") {
                            try mColCount := cell.MergeArea.Columns.Count
                        }
                        mStartRow := rowIndex
                        mEndRow := mStartRow + mRowCount - 1
                        mStartCol := columnIndex
                        mEndCol := mStartCol + mColCount - 1

                        ; 数学坐标生成地址，杜绝查询 mergeRange.Address 等属性
                        startColLetter := colLetter
                        endColLetter := (mColCount = 1) ? colLetter : GetSpreadsheetColumnLetter(mEndCol)
                        rangeAddr := (mColCount = 1)
                            ? colLetter . mStartRow . ":" . colLetter . mEndRow
                            : startColLetter . mStartRow . ":" . endColLetter . mEndRow
                        firstAddr := startColLetter . mStartRow

                        if !seenAddresses.Has(rangeAddr) {
                            seenAddresses[rangeAddr] := true

                            ; 从内存 SafeArray 中获取首单元格值
                            relC := relCol
                            firstVal := GetSpreadsheetMatrixValue(areaValues, relR, relC, areaRowCount, areaColCount)

                            ; 构造撤销项
                            item := Map(
                                "kind", "unmergeFill",
                                "workbook", wbFullName,
                                "sheet", wsName,
                                "address", rangeAddr,
                                "cells", [Map("address", firstAddr, "content", firstVal)],
                                "fillContent", firstVal,
                                "horizontalAlignment", "",
                                "verticalAlignment", "",
                                "applied", false
                            )
                            undoAction["items"].Push(item)
                            areaItems.Push(item)

                            ; 在内存 SafeArray 中向下填充合并块所覆盖的所有单元格
                            fillRStart := Max(relR, 1)
                            fillREnd := Min(relR + mRowCount - 1, areaRowCount)
                            fillCStart := Max(relC, 1)
                            fillCEnd := Min(relC + mColCount - 1, areaColCount)

                            Loop (fillCEnd - fillCStart + 1) {
                                fc := fillCStart + A_Index - 1
                                Loop (fillREnd - fillRStart + 1) {
                                    fr := fillRStart + A_Index - 1
                                    if (areaRowCount = 1 && areaColCount = 1)
                                        areaValues := firstVal
                                    else
                                        areaValues[fr, fc] := firstVal
                                }
                            }
                        }

                        rowIndex := mStartRow + mRowCount
                        continue
                    }
                    rowIndex += 1
                }
            }
        }

        if (areaItems.Length > 0) {
                areaInfos.Push(Map(
                    "range", areaRange,
                    "values", areaValues,
                    "items", areaItems
                ))
            }
        }
    } catch as err {
        try worksheet.DisplayPageBreaks := oldDisplayPageBreaks
        try app.ActiveWindow.View := oldView
        try app.Calculation := oldCalculation
        try app.DisplayAlerts := oldDisplayAlerts
        try app.EnableEvents := oldEnableEvents
        try app.ScreenUpdating := oldScreenUpdating
        if (isSilent)
            throw Error("无法读取当前选区中的合并单元格：" . err.Message)
        MsgBox("无法读取当前选区中的合并单元格：" . err.Message, title, "Icon!")
        return
    }

    if (undoAction["items"].Length = 0) {
        try worksheet.DisplayPageBreaks := oldDisplayPageBreaks
        try app.ActiveWindow.View := oldView
        try app.Calculation := oldCalculation
        try app.DisplayAlerts := oldDisplayAlerts
        try app.EnableEvents := oldEnableEvents
        try app.ScreenUpdating := oldScreenUpdating
        if (isSilent)
            return ""
        MsgBox("当前选区中没有合并单元格。", title)
        return
    }

    operationError := ""
    try {
        ; 拆分与填充：整块 UnMerge 与 SafeArray 批量写回，彻底消除逐个单元格 COM IPC
        for info in areaInfos {
            info["range"].UnMerge()
            info["range"].Value2 := info["values"]
            for item in info["items"]
                item["applied"] := true
        }
    } catch as err {
        operationError := err.Message
        try RestoreUndoAction(app, undoAction)
        catch as rollbackError
            operationError .= Chr(10) . "回滚失败：" . rollbackError.Message
    } finally {
        try worksheet.DisplayPageBreaks := oldDisplayPageBreaks
        try app.ActiveWindow.View := oldView
        try app.Calculation := oldCalculation
        try app.DisplayAlerts := oldDisplayAlerts
        try app.EnableEvents := oldEnableEvents
        try app.ScreenUpdating := oldScreenUpdating
    }

    if (operationError != "") {
        if (isSilent)
            throw Error("拆分失败：" . operationError)
        MsgBox("拆分失败：" . operationError, title, "Icon!")
        return
    }

    PushUndoAction(undoAction)
    return undoAction
}


MergeIdenticalSpreadsheetCells(explicitContext := "") {
    title := "合并相同内容并居中"
    context := ""
    if IsObject(explicitContext) {
        context := explicitContext
    } else {
        context := GetSpreadsheetSelectionContext(title)
    }
    if !IsObject(context)
        return

    xl := context["app"]
    selection := context["selection"]
    kind := context.Has("kind") ? context["kind"] : (context.Has("name") ? context["name"] : "excel")
    isSilent := (context.Has("silent") && context["silent"])
    processRange := ""

    try {
        if (selection.Areas.Count != 1) {
            if (isSilent)
                throw Error("当前选区不连续。请只选择一个连续的单列或多列区域。")
            MsgBox("当前选区不连续。请只选择一个连续的单列或多列区域。", title, "Icon!")
            return
        }
        if (selection.Rows.Count < 2) {
            if (isSilent)
                throw Error("选区至少需要包含两个单元格。")
            MsgBox("选区至少需要包含两个单元格。", title)
            return
        }

        worksheet := selection.Worksheet
        usedRange := worksheet.UsedRange
        firstRow := Max(selection.Row, usedRange.Row)
        lastRow := Min(
            selection.Row + selection.Rows.Count - 1,
            usedRange.Row + usedRange.Rows.Count - 1
        )
        if (firstRow > lastRow) {
            if (isSilent)
                throw Error("当前选区内没有可处理的已使用单元格。")
            MsgBox("当前选区内没有可处理的已使用单元格。", title)
            return
        }
        processRange := worksheet.Range(
            worksheet.Cells(firstRow, selection.Column),
            worksheet.Cells(
                lastRow,
                selection.Column + selection.Columns.Count - 1
            )
        )
    } catch as err {
        if (isSilent)
            throw Error("当前选区不是可处理的单元格区域：" . err.Message)
        MsgBox("当前选区不是可处理的单元格区域。", title, "Icon!")
        return
    }

    ; 全局加速与环境优化包裹
    oldScreenUpdating := GetSpreadsheetProperty(xl, "ScreenUpdating", true)
    oldEnableEvents := GetSpreadsheetProperty(xl, "EnableEvents", true)
    oldDisplayAlerts := GetSpreadsheetProperty(xl, "DisplayAlerts", true)
    oldCalculation := GetSpreadsheetProperty(xl, "Calculation", -4105)
    oldDisplayPageBreaks := false
    oldView := 1
    try oldDisplayPageBreaks := worksheet.DisplayPageBreaks
    try oldView := xl.ActiveWindow.View

    try {
        try xl.ScreenUpdating := false
        try xl.EnableEvents := false
        try xl.DisplayAlerts := false
        try xl.Calculation := -4135 ; xlCalculationManual

        ; 公式检测拦截
        if HasSpreadsheetFormulaCells(processRange) {
            if (isSilent)
                throw Error("选区中包含公式单元格。为避免公式丢失，本次操作已取消。")
            MsgBox("选区中包含公式单元格。为避免公式丢失，本次操作已取消。", title, "Icon!")
            return
        }

        ; 前置合并单元格 O(1) 预检：processRange.MergeCells != false 表示区域内存在合并单元格
        if (processRange.MergeCells != false) {
            if (isSilent)
                throw Error("选区中包含已经合并的单元格。请先取消合并后再执行。")
            MsgBox("选区中包含已经合并的单元格。请先取消合并后再执行。", title, "Icon!")
            return
        }

        values := processRange.Value2
        rowCount := processRange.Rows.Count
        columnCount := processRange.Columns.Count

        entriesByColumn := []
        Loop columnCount {
            relativeColumn := A_Index
            columnEntries := []
            Loop rowCount {
                relativeRow := A_Index
                value := GetSpreadsheetMatrixValue(
                    values,
                    relativeRow,
                    relativeColumn,
                    rowCount,
                    columnCount
                )
                columnEntries.Push(Map(
                    "value", value,
                    "row", firstRow + relativeRow - 1
                ))
            }
            entriesByColumn.Push(columnEntries)
        }

        pageBreakRows := GetHorizontalPageBreakRows(worksheet, firstRow, lastRow)

        ; 抑制分页符实时重算与视图模式损耗：临时关闭 DisplayPageBreaks 与切换普通视图
        try worksheet.DisplayPageBreaks := false
        try xl.ActiveWindow.View := 1 ; xlNormalView

        mergeSpecs := []
        for relativeColumn, entries in entriesByColumn {
            groups := FindIdenticalSpreadsheetCellGroups(entries, pageBreakRows)
            colNum := selection.Column + relativeColumn - 1
            colLetter := GetSpreadsheetColumnLetter(colNum)
            for group in groups {
                gStartRow := entries[group["start"]]["row"]
                gEndRow := entries[group["end"]]["row"]
                gVal := entries[group["start"]]["value"]
                mergeSpecs.Push(Map(
                    "column", colNum,
                    "colLetter", colLetter,
                    "firstRow", gStartRow,
                    "lastRow", gEndRow,
                    "value", gVal
                ))
            }
        }

        if (mergeSpecs.Length = 0) {
            if (isSilent)
                throw Error("选区中没有连续且内容完全相同的单元格。")
            MsgBox("选区中没有连续且内容完全相同的单元格。", title)
            return
        }

        undoAction := CreateUndoAction(title, xl, kind)
        wbFullName := worksheet.Parent.FullName
        wsName := worksheet.Name

        ; 纯内存构建撤销信息，0 次 COM 属性往返查询
        for spec in mergeSpecs {
            colLetter := spec["colLetter"]
            startR := spec["firstRow"]
            endR := spec["lastRow"]
            val := spec["value"]
            rangeAddr := colLetter . startR . ":" . colLetter . endR

            cells := []
            Loop (endR - startR + 1) {
                cellR := startR + A_Index - 1
                cells.Push(Map(
                    "address", colLetter . cellR,
                    "content", val,
                    "horizontalAlignment", "",
                    "verticalAlignment", ""
                ))
            }

            item := Map(
                "kind", "merge",
                "workbook", wbFullName,
                "sheet", wsName,
                "address", rangeAddr,
                "cells", cells,
                "applied", false
            )
            undoAction["items"].Push(item)
        }

        ; 执行合并前对整个选区一次性广播设置居中对齐，消除后续循环内对各合并块的重复对齐调用
        processRange.HorizontalAlignment := -4108
        processRange.VerticalAlignment := -4108

        ; 批量执行合并：分批使用逗号分隔 Range 字符串调用 Merge()，从 806 次 COM IPC 压缩至 ~35 次
        mergeError := ""
        try {
            currentBatch := ""
            for item in undoAction["items"] {
                item["applied"] := true
                addr := item["address"]
                if (currentBatch = "") {
                    currentBatch := addr
                } else if (StrLen(currentBatch) + 1 + StrLen(addr) <= 240) {
                    currentBatch .= "," . addr
                } else {
                    worksheet.Range(currentBatch).Merge()
                    currentBatch := addr
                }
            }
            if (currentBatch != "")
                worksheet.Range(currentBatch).Merge()
        } catch as err {
            mergeError := err.Message
            try RestoreUndoAction(xl, undoAction)
            catch as rollbackError
                mergeError .= Chr(10) . "回滚失败：" . rollbackError.Message
        }

        if (mergeError != "") {
            if (isSilent)
                throw Error("合并失败：" . mergeError)
            MsgBox("合并失败：" . mergeError, title, "Icon!")
            return
        }

        PushUndoAction(undoAction)
        return undoAction
    } finally {
        try worksheet.DisplayPageBreaks := oldDisplayPageBreaks
        try xl.ActiveWindow.View := oldView
        try xl.Calculation := oldCalculation
        try xl.DisplayAlerts := oldDisplayAlerts
        try xl.EnableEvents := oldEnableEvents
        try xl.ScreenUpdating := oldScreenUpdating
    }
}

GetSpreadsheetColumnLetter(columnNumber) {
    columnLetter := ""
    while (columnNumber > 0) {
        remainder := Mod(columnNumber - 1, 26)
        columnLetter := Chr(65 + remainder) . columnLetter
        columnNumber := (columnNumber - remainder - 1) // 26
    }
    return columnLetter
}


FindIdenticalSpreadsheetCellGroups(entries, pageBreakRows := "") {
    groups := []
    groupStart := 0

    for index, entry in entries {
        ; 分页符位于当前行之前时，强制结束上一段相同内容。
        if (index > 1 && IsObject(pageBreakRows) && pageBreakRows.Has(entry["row"])) {
            AddIdenticalSpreadsheetCellGroup(groups, groupStart, index - 1)
            groupStart := 0
        }

        if IsBlankSpreadsheetValue(entry["value"]) {
            AddIdenticalSpreadsheetCellGroup(groups, groupStart, index - 1)
            groupStart := 0
            continue
        }

        if (groupStart = 0) {
            groupStart := index
            continue
        }

        if !SpreadsheetValuesExactlyEqual(entries[groupStart]["value"], entry["value"]) {
            AddIdenticalSpreadsheetCellGroup(groups, groupStart, index - 1)
            groupStart := index
        }
    }

    AddIdenticalSpreadsheetCellGroup(groups, groupStart, entries.Length)
    return groups
}

HasSpreadsheetFormulaCells(range) {
    try {
        formulaCells := range.SpecialCells(-4123)
        return IsObject(formulaCells)
    } catch {
        return false
    }
}

GetSpreadsheetMatrixValue(values, row, column, rowCount, columnCount) {
    if (rowCount = 1 && columnCount = 1)
        return values
    return values[row, column]
}

GetHorizontalPageBreakRows(worksheet, firstRow := 1, lastRow := 1048576) {
    rows := Map()
    oldPageBreaks := false
    oldView := 1
    hasChangedView := false
    try {
        try oldPageBreaks := worksheet.DisplayPageBreaks
        try oldView := worksheet.Application.ActiveWindow.View
        try worksheet.DisplayPageBreaks := true
        hbreaks := worksheet.HPageBreaks
        breakCount := hbreaks.Count
        Loop breakCount {
            try {
                pb := hbreaks.Item(A_Index)
                locRow := pb.Location.Row
                if (locRow > lastRow)
                    break
                if (locRow >= firstRow && locRow <= lastRow)
                    rows[locRow] := true
            } catch {
                if (!hasChangedView) {
                    try {
                        worksheet.Application.ActiveWindow.View := 2
                        hasChangedView := true
                        pb := hbreaks.Item(A_Index)
                        locRow := pb.Location.Row
                        if (locRow >= firstRow && locRow <= lastRow)
                            rows[locRow] := true
                    } catch {
                        break
                    }
                } else {
                    break
                }
            }
        }
    } catch {
        ; 某些 WPS 版本可能不公开分页符集合，保持原有合并行为。
    } finally {
        if (hasChangedView)
            try worksheet.Application.ActiveWindow.View := oldView
        try worksheet.DisplayPageBreaks := oldPageBreaks
    }
    return rows
}

AddIdenticalSpreadsheetCellGroup(groups, startIndex, endIndex) {
    if (startIndex > 0 && endIndex - startIndex + 1 >= 2)
        groups.Push(Map("start", startIndex, "end", endIndex))
}

IsBlankSpreadsheetValue(value) {
    return Type(value) = "String" && value = ""
}

SpreadsheetValuesExactlyEqual(left, right) {
    leftType := Type(left)
    rightType := Type(right)

    if (leftType = "String" || rightType = "String")
        return leftType = "String" && rightType = "String" && StrCompare(left, right, true) = 0

    if (IsNumber(left) && IsNumber(right))
        return left = right

    if (leftType != rightType)
        return false

    try return left == right
    catch
        return false
}

; 「项目总览」把选中的图纸写入 %APPDATA%\项目总览\selected-cad.txt：第一行是写入者的进程 ID，其后每行一个路径。
; 只有前台窗口的进程 ID 与第一行一致时才采用，既不依赖 exe 名称（开发模式也可用），也能排除程序崩溃后的残留选区。
GetProjectAtlasSelectedFiles(hwnd) {
    selectionFile := EnvGet("APPDATA") . "\项目总览\selected-cad.txt"
    if !FileExist(selectionFile)
        return []
    try {
        windowPid := WinGetPID("ahk_id " . hwnd)
        lines := StrSplit(FileRead(selectionFile, "UTF-8"), "`n", "`r")
    } catch
        return []
    if (lines.Length < 2 || Trim(lines[1]) != String(windowPid))
        return []
    paths := []
    Loop lines.Length - 1 {
        filePath := Trim(lines[A_Index + 1])
        if (filePath != "" && FileExist(filePath))
            paths.Push(filePath)
    }
    if (paths.Length > 0)
        LogPanelDiagnostic("项目总览选区", JoinLines(paths))
    return paths
}

GetSelectedDwgPath() {
    global AutomationSelectedFilePaths

    for _, filePath in AutomationSelectedFilePaths {
        if DirExist(filePath)
            continue
        SplitPath(filePath, , , &extension)
        if (StrLower(extension) = "dwg")
            return filePath
    }
    return ""
}

GetSelectedFilePathsFromClipboard(hwnd) {
    global CopyQExe

    selected := []
    hasCopyQ := FileExist(CopyQExe) && ProcessExist("copyq.exe")
    copyQDisabled := false
    savedClipboard := ClipboardAll()
    contextClass := "unknown"
    try contextClass := WinGetClass("ahk_id " . hwnd)
    LogPanelDiagnostic("读取选区开始", "hwnd=" . hwnd . "; activeHwnd=" . WinExist("A") . "; class=" . contextClass)

    try {
        if (WinExist("A") != hwnd) {
            WinActivate("ahk_id " . hwnd)
            LogPanelDiagnostic("激活选区窗口", "afterActivateHwnd=" . WinExist("A"))
        }
        if (WinExist("A") != hwnd && !WinWaitActive("ahk_id " . hwnd, , 2)) {
            LogPanelDiagnostic("选区窗口激活失败", "targetHwnd=" . hwnd . "; activeHwnd=" . WinExist("A"))
            return selected
        }

        if hasCopyQ {
            copyQDisabled := PauseCopyQForSelection(CopyQExe)
        }

        A_Clipboard := ""
        Send("^c")
        clipReady := ClipWait(1, 1)
        if clipReady
            selected := GetClipboardFileDropPaths()
        LogPanelDiagnostic("读取剪贴板选区结束", "clipReady=" . clipReady . "; fileCount=" . selected.Length
            . (selected.Length ? "`r`n" . JoinLines(selected) : "`r`nCF_HDROP为空或剪贴板等待超时"))
    } finally {
        try {
            A_Clipboard := savedClipboard
        } finally {
            if copyQDisabled {
                try ResumeCopyQAfterSelection(CopyQExe, copyQDisabled)
                catch as err {
                    LogPanelDiagnostic("CopyQ恢复失败", err.Message)
                    TrayTip("CopyQ 监控恢复失败，请检查 CopyQ 状态。", "自动化面板")
                }
            }
        }
        LogPanelDiagnostic("选区读取清理", "clipboardRestored=1; copyQReenabled=" . copyQDisabled)
    }

    return selected
}

GetClipboardFileDropPaths() {
    selected := []
    if !DllCall("OpenClipboard", "Ptr", 0) {
        LogPanelDiagnostic("CF_HDROP读取失败", "OpenClipboard失败；lastError=" . A_LastError)
        return selected
    }

    try {
        ; CF_HDROP 是资源管理器复制文件时提供的原生路径列表，不解析剪贴板文本。
        hDrop := DllCall("GetClipboardData", "UInt", 15, "Ptr")
        if !hDrop {
            LogPanelDiagnostic("剪贴板没有CF_HDROP", "GetClipboardData(CF_HDROP)返回空；lastError=" . A_LastError)
            return selected
        }

        fileCount := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", 0xFFFFFFFF, "Ptr", 0, "UInt", 0, "UInt")
        Loop fileCount {
            index := A_Index - 1
            charCount := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", index, "Ptr", 0, "UInt", 0, "UInt")
            if (charCount = 0)
                continue

            pathBuffer := Buffer((charCount + 1) * 2, 0)
            DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", index, "Ptr", pathBuffer, "UInt", charCount + 1, "UInt")
            filePath := StrGet(pathBuffer, "UTF-16")
            if (filePath != "" && FileExist(filePath))
                selected.Push(filePath)
        }
    } finally {
        DllCall("CloseClipboard")
    }

    LogPanelDiagnostic("CF_HDROP读取成功", "fileCount=" . selected.Length
        . (selected.Length ? "`r`n" . JoinLines(selected) : "`r`nCF_HDROP中无可访问路径"))
    return selected
}

OpenSelectedDwg(viewer) {
    global SelectedDwgPath

    title := "打开 DWG 图纸"
    if (SelectedDwgPath = "" || !FileExist(SelectedDwgPath)) {
        MsgBox("选中的 DWG 文件已不存在或无法访问。请重新选择图纸后再按 Ctrl+Shift+E。", title, "Icon!")
        return
    }

    viewers := Map(
        "autocad", Map(
            "name", "AutoCAD 2018",
            "shortcut", "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\AutoCAD 2018 - 简体中文 (Simplified Chinese)\AutoCAD 2018 - 简体中文 (Simplified Chinese).lnk"
        ),
        "zwcad", Map(
            "name", "中望 CAD 2026",
            "shortcut", "C:\Users\Public\Desktop\中望CAD 2026.lnk"
        ),
        "quickview", Map(
            "name", "CAD快速看图",
            "shortcut", "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\CAD快速看图\CAD快速看图.lnk"
        )
    )

    if !viewers.Has(viewer) {
        MsgBox("未知的图纸打开方式。", title, "Icon!")
        return
    }

    selectedViewer := viewers[viewer]
    shortcut := selectedViewer["shortcut"]
    if !FileExist(shortcut) {
        MsgBox(selectedViewer["name"] . " 的快捷方式不存在：" . Chr(10) . Chr(10) . shortcut, title, "Icon!")
        return
    }

    try RunShortcutWithFile(shortcut, SelectedDwgPath)
    catch as err
        MsgBox("无法使用 " . selectedViewer["name"] . " 打开图纸：" . Chr(10) . Chr(10) . err.Message, title, "Icon!")
}

RunShortcutWithFile(shortcut, filePath) {
    FileGetShortcut(shortcut, &target, &workingDirectory, &arguments)
    if (target = "" || !FileExist(target))
        throw Error("快捷方式指向的程序不存在：" . target)

    commandLine := '"' . target . '"'
    if (Trim(arguments) != "")
        commandLine .= " " . arguments
    commandLine .= ' "' . filePath . '"'

    Run(commandLine, workingDirectory)
}

ReloadZwcadAaLsp() {
    global AaLspPath
    ReloadCadAaLsp("ZWCAD.Application", "中望 CAD", "中望 CAD 2026", AaLspPath)
}

ReloadAutocadAaLsp() {
    global AcadAaLspPath
    ReloadCadAaLsp("AutoCAD.Application", "AutoCAD", "AutoCAD 2018", AcadAaLspPath)
}

; 向中望 CAD 当前图纸发送一个插件命令并切到 CAD，命令中的选择交给用户在 CAD 里完成
RunZwcadCommand(cmd, label, *) {
    title := "中望 CAD · " . label
    try cadApp := ComObjActive("ZWCAD.Application")
    catch {
        MsgBox("未检测到运行中的中望 CAD，请先启动中望 CAD 2026 并打开图纸。", title, "Icon!")
        return
    }
    try {
        doc := cadApp.ActiveDocument
        if (doc.GetVariable("CMDACTIVE") != 0) {
            MsgBox("中望 CAD 正在执行命令，请先按 Esc 结束当前命令再试。", title, "Icon!")
            return
        }
        try WinActivate("ahk_exe ZWCAD.exe")
        doc.SendCommand(cmd . "`n")
    } catch as err {
        MsgBox("向中望 CAD 发送 " . cmd . " 失败：`n" . err.Message . "`n`n如果插件没加载，可先点“重新加载 AA整合版本.lsp”。", title, "Icon!")
    }
}

CadTargets() {
    return [
        Map("exe", "zwcad.exe", "progId", "ZWCAD.Application", "name", "中望 CAD"),
        Map("exe", "acad.exe", "progId", "AutoCAD.Application", "name", "AutoCAD")
    ]
}

; 打开面板前的前台窗口若属于中望 CAD 或 AutoCAD，返回对应目标，否则返回空
DetectAutomationContextCad() {
    global AutomationContextHwnd
    if !AutomationContextHwnd
        return ""
    processName := ""
    try processName := StrLower(WinGetProcessName("ahk_id " . AutomationContextHwnd))
    for target in CadTargets() {
        if (processName = target["exe"])
            return target
    }
    return ""
}

; 连接要操作的 CAD：优先打开面板前所在的 CAD 窗口；不在 CAD 时只有一个 CAD 在运行才自动选它，两个都在运行不猜测
GetActiveCadDocumentContext(title) {
    target := DetectAutomationContextCad()
    cadApp := ""
    if IsObject(target) {
        cadApp := TryGetActiveComObject(target["progId"])
        if !IsObject(cadApp) {
            MsgBox("无法连接到 " . target["name"] . "（" . target["progId"] . "）。", title, "Icon!")
            return ""
        }
    } else {
        found := []
        for candidate in CadTargets() {
            app := TryGetActiveComObject(candidate["progId"])
            if IsObject(app)
                found.Push(Map("target", candidate, "app", app))
        }
        if (found.Length = 0) {
            MsgBox("没有找到正在运行的中望 CAD 或 AutoCAD。", title, "Icon!")
            return ""
        }
        if (found.Length > 1) {
            MsgBox("中望 CAD 和 AutoCAD 都在运行。请先切换到要操作的 CAD 窗口，再按 Ctrl+Shift+E。", title, "Icon!")
            return ""
        }
        target := found[1]["target"]
        cadApp := found[1]["app"]
    }

    doc := ""
    try doc := cadApp.ActiveDocument
    if !IsObject(doc) {
        MsgBox(target["name"] . " 当前没有打开任何图纸。", title, "Icon!")
        return ""
    }
    cmdActive := 0
    try cmdActive := doc.GetVariable("CMDACTIVE")
    if (cmdActive != 0) {
        MsgBox(target["name"] . " 正在执行命令，请先按 Esc 结束当前命令再试。", title, "Icon!")
        return ""
    }
    return Map("app", cadApp, "doc", doc, "target", target)
}

; 不保存、不确认，直接关闭当前图纸
ForceCloseActiveCadDrawing(*) {
    title := "强制关闭当前图纸"
    context := GetActiveCadDocumentContext(title)
    if !IsObject(context)
        return
    doc := context["doc"]
    cadName := context["target"]["name"]

    docName := ""
    try docName := doc.Name

    try {
        doc.Close(false)
    } catch as err {
        MsgBox("关闭图纸“" . docName . "”失败：`n" . err.Message, title, "Icon!")
        return
    }
    TrayTip("已关闭（未保存）：" . docName, cadName . " · " . title, "Iconi Mute")
}

; 保存当前图纸后关闭
SaveAndCloseActiveCadDrawing(*) {
    title := "保存并关闭"
    context := SaveAndCloseCadDrawingNatively(title)
    if !IsObject(context)
        return
    SplitPath(context["fullName"], &docName)
    TrayTip("已保存并关闭：" . docName, context["target"]["name"] . " · " . title, "Iconi Mute")
}

; 保存当前图纸、关闭后按原路径重新打开
SaveAndReopenActiveCadDrawing(*) {
    title := "保存并重新打开"
    context := SaveAndCloseCadDrawingNatively(title)
    if !IsObject(context)
        return
    fullName := context["fullName"]
    try {
        context["app"].Documents.Open(fullName)
    } catch as err {
        MsgBox("图纸已保存并关闭，但重新打开失败，请手动打开：`n" . fullName . "`n`n" . err.Message, title, "Icon!")
        return
    }
    try WinActivate("ahk_exe " . context["target"]["exe"])
    SplitPath(fullName, &docName)
    TrayTip("已保存并重新打开：" . docName, context["target"]["name"] . " · " . title, "Iconi Mute")
}

; 让 CAD 在自己的命令行里执行 QSAVE + CLOSE，并等待图纸关闭。
; 不能从面板进程直接调用 COM 的 Document.Save()：2026-10-28 在中望 CAD 2026 上保存 26MB 图纸时直接崩溃，
; 原生 QSAVE 在同一张图上正常。QSAVE 没存成功时 CLOSE 会弹出 CAD 自己的“是否保存”，不会静默丢修改。
SaveAndCloseCadDrawingNatively(title) {
    context := GetActiveCadDocumentContext(title)
    if !IsObject(context)
        return ""
    doc := context["doc"]
    cadName := context["target"]["name"]

    fullName := ""
    try fullName := doc.FullName
    if (fullName = "" || !FileExist(fullName)) {
        MsgBox("当前图纸还没有保存过文件，请先在 " . cadName . " 里“另存为”指定路径。", title, "Icon!")
        return ""
    }
    readOnly := false
    try readOnly := doc.ReadOnly
    if readOnly {
        MsgBox("图纸以只读方式打开，无法保存：`n" . fullName, title, "Icon!")
        return ""
    }

    try {
        doc.SendCommand("_.QSAVE`n_.CLOSE`n")
    } catch as err {
        MsgBox("向 " . cadName . " 发送保存命令失败：`n" . fullName . "`n`n" . err.Message, title, "Icon!")
        return ""
    }
    if !WaitCadDocumentClosed(context["app"], fullName, 180000) {
        MsgBox(cadName . " 还没有关闭图纸（可能仍在保存，或弹出了提示）：`n" . fullName . "`n`n请到 " . cadName . " 里查看。", title, "Icon!")
        return ""
    }
    context["fullName"] := fullName
    return context
}

WaitCadDocumentClosed(cadApp, fullName, timeoutMs) {
    deadline := A_TickCount + timeoutMs
    loop {
        stillOpen := false
        try {
            for openDoc in cadApp.Documents {
                if (StrLower(openDoc.FullName) = StrLower(fullName)) {
                    stillOpen := true
                    break
                }
            }
        } catch {
            stillOpen := true
        }
        if !stillOpen
            return true
        if (A_TickCount >= deadline)
            return false
        Sleep(300)
    }
}

ReloadCadAaLsp(progId, cadName, cadFullName, lspPath) {
    title := cadName . " 插件重载"

    if (!FileExist(lspPath)) {
        MsgBox("未找到整合版本 LISP 脚本文件：`n" . lspPath, title, "Icon!")
        return
    }

    ; 转换为 AutoLISP 所需的正斜杠路径
    escapedPath := StrReplace(lspPath, "\", "/")

    try {
        cadApp := ComObjActive(progId)
    } catch as err {
        MsgBox("未检测到运行中的 " . cadName . "（" . progId . "）。`n请确认 " . cadFullName . " 已经启动。", title, "Icon!")
        return
    }

    try {
        doc := cadApp.ActiveDocument
        if (!doc) {
            MsgBox(cadName . " 当前没有打开任何图纸，请先打开或新建一张图纸。", title, "Icon!")
            return
        }

        ; 发送加载命令，以换行结尾触发执行
        doc.SendCommand('(load "' . escapedPath . '")`n')
        TrayTip("已向 " . cadName . " 发送重载指令：`n" . lspPath, title, "Iconi Mute")
    } catch as err {
        MsgBox("向 " . cadName . " 发送加载命令失败：`n" . err.Message, title, "Icon!")
    }
}

AddTextToExcelSelection(position) {
    isPrefix := position = "prefix"
    title := isPrefix ? "表格批量添加前缀" : "表格批量添加后缀"
    prompt := isPrefix
        ? "请输入要添加到每个选中单元格前面的文字："
        : "请输入要添加到每个选中单元格后面的文字："

    context := GetSpreadsheetSelectionContext(title)
    if !IsObject(context)
        return
    xl := context["app"]
    selection := context["selection"]

    try cells := selection.Cells
    catch {
        MsgBox("当前选区不是单元格区域。请选中一个或多个单元格后再通过面板执行。", title, "Icon!")
        return
    }

    input := InputBox(prompt, title, "w420 h135")
    if (input.Result != "OK")
        return

    addedText := input.Value
    if (addedText = "")
        return

    try {
        action := ApplySpreadsheetTextTransform(context, position, addedText)
        if IsObject(action)
            PushUndoAction(action)
    } catch as err {
        MsgBox("处理失败：" . err.Message, title, "Icon!")
    }
}

RemoveBracketTextFromExcelSelection() {
    context := GetSpreadsheetSelectionContext("表格删除括号内容")
    if !IsObject(context)
        return
    try {
        action := ApplySpreadsheetTextTransform(context, "brackets")
        if IsObject(action)
            PushUndoAction(action)
    } catch as err {
        MsgBox("处理失败：" . err.Message, "表格删除括号内容", "Icon!")
    }
}

RemoveTextFromExcelSelection(position) {
    isStart := position = "start"
    title := isStart ? "表格删除前端字符" : "表格删除末尾字符"
    prompt := isStart
        ? "请输入要删除的前端字符数，例如输入 2：`nAB时间同步柜 -> 时间同步柜"
        : "请输入要删除的末尾字符数，例如输入 5：`n时间同步柜2-36n -> 时间同步柜"

    context := GetSpreadsheetSelectionContext(title)
    if !IsObject(context)
        return
    xl := context["app"]
    selection := context["selection"]

    try cells := selection.Cells
    catch {
        MsgBox("当前选区不是单元格区域。请选中一个或多个单元格后再通过面板执行。", title, "Icon!")
        return
    }

    input := InputBox(prompt, title, "w460 h155")
    if (input.Result != "OK")
        return

    deleteCountText := Trim(input.Value)
    if !RegExMatch(deleteCountText, "^\d+$") {
        MsgBox("请输入正整数，例如 1、2、3、4 或 5。", title, "Icon!")
        return
    }

    deleteCount := Integer(deleteCountText)
    if (deleteCount < 1) {
        MsgBox("删除字符数必须大于 0。", title, "Icon!")
        return
    }

    try {
        action := ApplySpreadsheetTextTransform(context, position, deleteCount)
        if IsObject(action)
            PushUndoAction(action)
    } catch as err {
        MsgBox("处理失败：" . err.Message, title, "Icon!")
    }
}

SortCableRowsByCrossSection() {
    title := "按电缆截面排序"
    context := GetSpreadsheetSelectionContext(title)
    if !IsObject(context)
        return
    app := context["app"]

    try selection := context["selection"]
    catch {
        MsgBox("无法读取当前表格选区。请先选中需要整行一起排序的数据区域。", title, "Icon!")
        return
    }

    try {
        if (selection.Areas.Count != 1) {
            MsgBox("暂不支持多个不连续选区。请选中一个连续的数据区域。", title, "Icon!")
            return
        }

        if (selection.Rows.Count < 2) {
            MsgBox("请至少选择两行型号数据。可以只选型号列，脚本会自动带上右侧的电缆长度列。", title, "Icon!")
            return
        }

        if (selection.Rows.Count > 50000) {
            MsgBox("一次最多整理 50000 行，请缩小选区后重试。", title, "Icon!")
            return
        }

    } catch as err {
        MsgBox("无法检查当前选区：" . err.Message, title, "Icon!")
        return
    }

    sortRange := GetCableSortRange(selection, title)
    if !IsObject(sortRange)
        return

    try {
        if (sortRange.MergeCells) {
            MsgBox("型号列或长度列包含合并单元格，无法可靠地整行排序。请先取消合并或缩小选区。", title, "Icon!")
            return
        }
    } catch as err {
        MsgBox("无法检查型号和长度区域：" . err.Message, title, "Icon!")
        return
    }

    try firstKeyText := sortRange.Cells(1, 1).Value . ""
    catch {
        firstKeyText := ""
    }
    if LooksLikeCableHeader(firstKeyText) {
        if (sortRange.Rows.Count < 3) {
            MsgBox("除表头外至少需要两行数据。", title, "Icon!")
            return
        }
        sortRange := sortRange.Offset(1, 0).Resize(sortRange.Rows.Count - 1, sortRange.Columns.Count)
    }

    rows := []
    recognizedCount := 0
    unrecognizedCount := 0
    specialCount := 0
    columnCount := sortRange.Columns.Count

    Loop sortRange.Rows.Count {
        rowIndex := A_Index
        try keyText := sortRange.Cells(rowIndex, 1).Value . ""
        catch {
            keyText := ""
        }

        spec := ParseCableSpecification(keyText)
        contents := []
        Loop columnCount
            contents.Push(GetSpreadsheetCellContent(sortRange.Cells(rowIndex, A_Index)))

        rowData := Map(
            "originalIndex", rowIndex,
            "contents", contents,
            "recognized", IsObject(spec)
        )

        if IsObject(spec) {
            rowData["effectiveSection"] := spec["effectiveSection"]
            rowData["coreCount"] := spec["coreCount"]
            rowData["mainSection"] := spec["mainSection"]
            rowData["auxiliarySection"] := spec["auxiliarySection"]
            rowData["specialRule"] := spec["specialRule"]
            recognizedCount += 1
            if spec["specialRule"]
                specialCount += 1
        } else {
            unrecognizedCount += 1
        }

        rows.Push(rowData)
    }

    if (recognizedCount < 2) {
        MsgBox("选区第一列只识别到 " . recognizedCount . " 条电缆规格，无法排序。`n支持示例：10×1.5、3×25+1×16。", title, "Icon!")
        return
    }

    rangeAddress := sortRange.Address(false, false)
    modelColumnName := GetExcelColumnName(sortRange.Column)
    lengthColumnName := GetExcelColumnName(sortRange.Column + 1)
    confirmText := "应用：" . context["name"]
        . "`n排序范围：" . rangeAddress
        . "`n型号列：" . modelColumnName . "；长度列：" . lengthColumnName
        . "`n型号与长度同步移动，共 " . sortRange.Rows.Count . " 行"
        . "`n识别电缆规格：" . recognizedCount . " 行"
        . "`n无法识别并移到末尾：" . unrecognizedCount . " 行"
        . "`n3×50+1×25 特殊归入 25：" . specialCount . " 行"
        . "`n`n排序规则：有效截面升序 -> 总芯数升序。"
        . "`n每条电缆型号始终带着右侧长度一起移动。"
        . "`n脚本不会自动保存文件。"
    if (MsgBox(confirmText, title, "OKCancel Icon?") != "OK")
        return

    sortedRows := StableSortCableRows(rows)
    undoAction := CreateUndoAction(title, app, context["kind"])
    AddUndoRange(undoAction, sortRange)
    oldScreenUpdating := GetSpreadsheetProperty(app, "ScreenUpdating", true)
    oldEnableEvents := GetSpreadsheetProperty(app, "EnableEvents", true)

    try {
        try app.ScreenUpdating := false
        try app.EnableEvents := false

        for destinationRow, rowData in sortedRows {
            for columnIndex, content in rowData["contents"]
                SetSpreadsheetCellContent(sortRange.Cells(destinationRow, columnIndex), content)
        }
    } catch as err {
        try RestoreUndoAction(app, undoAction)
        MsgBox("排序失败，已尝试恢复原数据：" . err.Message, title, "Icon!")
        return
    } finally {
        try app.ScreenUpdating := oldScreenUpdating
        try app.EnableEvents := oldEnableEvents
    }

    PushUndoAction(undoAction)
}

GetCableSortRange(selection, title) {
    try selectedColumnCount := selection.Columns.Count
    catch {
        MsgBox("当前选区不是单元格区域。", title, "Icon!")
        return ""
    }

    if (selectedColumnCount > 2) {
        MsgBox("请只选择电缆型号列，或同时选择“电缆型号 + 右侧长度”两列。`n超过两列时无法判断哪一列属于同一条电缆记录。", title, "Icon!")
        return ""
    }

    if (selectedColumnCount = 2)
        return selection

    try return selection.Resize(selection.Rows.Count, 2)
    catch as err {
        MsgBox("无法自动带上右侧电缆长度列：" . err.Message, title, "Icon!")
        return ""
    }
}

ParseCableSpecification(text) {
    normalized := StrReplace(Trim(text), Chr(12288), " ")
    pattern := "i)(\d+)\s*[×xX*]\s*(\d+(?:[.,]\d+)?)\s*(?:\+\s*(\d+)\s*[×xX*]\s*(\d+(?:[.,]\d+)?))?\s*$"
    if !RegExMatch(normalized, pattern, &match)
        return ""

    mainCores := Integer(match[1])
    mainSection := StrReplace(match[2], ",", ".") + 0
    auxiliaryCores := match[3] = "" ? 0 : Integer(match[3])
    auxiliarySection := match[4] = "" ? 0 : StrReplace(match[4], ",", ".") + 0
    effectiveSection := mainSection
    specialRule := false

    if (auxiliaryCores > 0 && mainSection = 50 && auxiliarySection = 25) {
        effectiveSection := 25
        specialRule := true
    }

    return Map(
        "effectiveSection", effectiveSection,
        "coreCount", mainCores + auxiliaryCores,
        "mainSection", mainSection,
        "auxiliarySection", auxiliarySection,
        "specialRule", specialRule
    )
}

LooksLikeCableHeader(text) {
    return RegExMatch(Trim(text), "i)(电缆.*(型号|规格)|型号|规格)")
}

GetSpreadsheetCellContent(cell) {
    try return Map("type", "formulaR1C1", "value", cell.FormulaR1C1)
    catch
        return Map("type", "value", "value", cell.Value)
}

SetSpreadsheetCellContent(cell, content) {
    if !IsObject(content) {
        cell.Value := content
        return
    }
    if (content["type"] = "formulaR1C1")
        cell.FormulaR1C1 := content["value"]
    else
        cell.Value := content["value"]
}

StableSortCableRows(rows) {
    current := rows.Clone()
    rowCount := current.Length
    width := 1

    while (width < rowCount) {
        merged := []
        start := 1
        while (start <= rowCount) {
            left := start
            middle := Min(start + width, rowCount + 1)
            right := Min(start + width * 2, rowCount + 1)
            i := left
            j := middle

            while (i < middle && j < right) {
                if (CompareCableRows(current[i], current[j]) <= 0) {
                    merged.Push(current[i])
                    i += 1
                } else {
                    merged.Push(current[j])
                    j += 1
                }
            }
            while (i < middle) {
                merged.Push(current[i])
                i += 1
            }
            while (j < right) {
                merged.Push(current[j])
                j += 1
            }
            start += width * 2
        }
        current := merged
        width *= 2
    }

    return current
}

CompareCableRows(left, right) {
    if (left["recognized"] != right["recognized"])
        return left["recognized"] ? -1 : 1
    if !left["recognized"]
        return left["originalIndex"] - right["originalIndex"]

    keys := ["effectiveSection", "coreCount", "mainSection", "auxiliarySection", "originalIndex"]
    for _, key in keys {
        if (left[key] < right[key])
            return -1
        if (left[key] > right[key])
            return 1
    }
    return 0
}

DedupeAndGroupExcelSelectedColumn() {
    context := GetSpreadsheetSelectionContext("表格列去重整理")
    if !IsObject(context)
        return
    xl := context["app"]

    try ws := context["selection"].Worksheet
    catch {
        MsgBox("无法读取当前活动工作表。请先切换到要整理的工作表。", "表格列去重整理", "Icon!")
        return
    }

    try selection := context["selection"]
    catch {
        MsgBox("无法读取当前选区。请先点一下要整理列里的任意单元格。", "表格列去重整理", "Icon!")
        return
    }

    try columnNumber := selection.Column
    catch {
        MsgBox("当前选区不是单元格区域。请先点一下要整理列里的任意单元格。", "表格列去重整理", "Icon!")
        return
    }

    if HasMultipleSelectedColumns(selection, columnNumber) {
        MsgBox("当前选区跨了多列。请只选中要整理列里的一个单元格，或只选中单独一列。", "表格列去重整理", "Icon!")
        return
    }

    columnName := GetExcelColumnName(columnNumber)
    lastRow := GetLastRowInColumn(ws, columnNumber)
    if (lastRow < 2) {
        MsgBox(columnName . " 列从第 2 行开始没有可整理的数据。", "表格列去重整理")
        return
    }

    group10 := []
    group110 := []
    groupOther := []
    seen := Map()
    blankCount := 0
    duplicateCount := 0

    restoreRange := ws.Range(columnName . "2:" . columnName . lastRow)
    try {
        if (restoreRange.MergeCells != false)
            throw Error("待整理列包含合并单元格，请先拆分后处理。")
        rawValues := restoreRange.Value
    } catch as err {
        MsgBox("无法读取待整理数据，本次未修改：" . err.Message, "表格列去重整理", "Icon!")
        return
    }
    Loop lastRow - 1 {
        rawValue := GetSpreadsheetMatrixValue(rawValues, A_Index, 1, lastRow - 1, 1)

        text := CleanCellText(rawValue)
        if (text = "") {
            blankCount += 1
            continue
        }

        if seen.Has(text) {
            duplicateCount += 1
            continue
        }
        seen[text] := true

        category := VoltageCategory(text)
        if (category = "10")
            group10.Push(text)
        else if (category = "110")
            group110.Push(text)
        else
            groupOther.Push(text)
    }

    result := []
    AppendArray(result, group10)
    AppendArray(result, group110)
    AppendArray(result, groupOther)

    if (result.Length = 0) {
        MsgBox(columnName . " 列没有可写回的数据。", "表格列去重整理")
        return
    }

    confirmText := "即将整理当前工作表：" . ws.Name
        . "`n范围：" . columnName . "2:" . columnName . lastRow
        . "`n保留唯一值：" . result.Length . " 个"
        . "`n删除重复值：" . duplicateCount . " 个"
        . "`n跳过空白单元格：" . blankCount . " 个"
        . "`n`n写回顺序：10kV -> 110kV -> 其他"
        . "`n注意：脚本会记录本次操作，可按 Ctrl+Z 撤销；脚本不会自动保存文件。"
    if (MsgBox(confirmText, "表格列去重整理", "OKCancel Icon?") != "OK")
        return

    try {
        action := WriteSpreadsheetDedupeResult(context, restoreRange, result)
        PushUndoAction(action)
    } catch as err {
        MsgBox("整理失败：" . err.Message, "表格列去重整理", "Icon!")
    }
}

UndoExcelCommandPanelAction() {
    global ExcelCommandUndoStack

    context := GetSpreadsheetContext("表格快捷功能撤销", false)
    if !IsObject(context) {
        Send("^z")
        return
    }
    xl := context["app"]

    if SpreadsheetHasNativeUndo(xl) {
        Send("^z")
        return
    }

    actionIndex := FindLatestUndoActionIndex(context["kind"])
    if (actionIndex = 0) {
        Send("^z")
        return
    }

    action := ExcelCommandUndoStack[actionIndex]
    ExcelCommandUndoStack.RemoveAt(actionIndex)
    oldScreenUpdating := xl.ScreenUpdating
    oldEnableEvents := xl.EnableEvents

    try {
        xl.ScreenUpdating := false
        xl.EnableEvents := false
        RestoreUndoAction(xl, action)
    } catch as err {
        ExcelCommandUndoStack.InsertAt(actionIndex, action)
        MsgBox("撤销失败：" . err.Message, "表格快捷功能撤销", "Icon!")
        return
    } finally {
        xl.ScreenUpdating := oldScreenUpdating
        xl.EnableEvents := oldEnableEvents
    }
}

GetSpreadsheetContext(title := "表格工具", showError := true) {
    global AutomationContextHwnd

    processName := ""
    try processName := StrLower(WinGetProcessName("A"))
    if (processName != "excel.exe" && processName != "et.exe"
        && processName != "wps.exe" && AutomationContextHwnd) {
        try processName := StrLower(WinGetProcessName("ahk_id " . AutomationContextHwnd))
    }

    if (processName = "excel.exe")
        return ConnectSpreadsheetApplication("Excel.Application", "excel", "Microsoft Excel", title, showError)
    if (processName = "et.exe" || processName = "wps.exe")
        return ConnectSpreadsheetApplication("Ket.Application", "wps", "WPS 表格", title, showError)

    excelApp := TryGetActiveComObject("Excel.Application")
    wpsApp := TryGetActiveComObject("Ket.Application")

    if (IsObject(excelApp) && IsObject(wpsApp)) {
        if showError
            MsgBox("Excel 和 WPS 表格都在运行。请先切换到需要操作的表格窗口，再按 Ctrl+Shift+E。", title, "Icon!")
        return ""
    }
    if IsObject(excelApp)
        return Map("app", excelApp, "kind", "excel", "name", "Microsoft Excel")
    if IsObject(wpsApp)
        return Map("app", wpsApp, "kind", "wps", "name", "WPS 表格")

    if showError
        MsgBox("没有找到正在运行的 Excel 或 WPS 表格。请先打开表格并选中单元格。", title, "Icon!")
    return ""
}

CaptureSpreadsheetSelectionContext(hwnd) {
    if (!hwnd)
        return ""

    processName := ""
    try processName := StrLower(WinGetProcessName("ahk_id " . hwnd))

    if (processName = "excel.exe") {
        progId := "Excel.Application"
        kind := "excel"
        name := "Microsoft Excel"
    } else if (processName = "et.exe" || processName = "wps.exe") {
        progId := "Ket.Application"
        kind := "wps"
        name := "WPS 表格"
    } else {
        return ""
    }

    app := TryGetActiveComObject(progId)
    if !IsObject(app)
        return Map("error", "无法连接当前表格程序，请确认面板与表格都以普通权限运行。")

    try {
        selection := app.Selection
        cells := selection.Cells
        cellCount := cells.Count
        worksheet := selection.Worksheet
        workbook := worksheet.Parent
        workbookFullName := workbook.FullName
        workbookName := workbook.Name
        worksheetName := worksheet.Name
        selectionAddress := selection.Address
    } catch as err {
        return Map("error", "无法锁定打开面板前的单元格选区：" . err.Message)
    }

    return Map(
        "progId", progId,
        "kind", kind,
        "name", name,
        "workbookFullName", workbookFullName,
        "workbookName", workbookName,
        "worksheetName", worksheetName,
        "selectionAddress", selectionAddress
    )
}

GetSpreadsheetSelectionContext(title) {
    global AutomationSpreadsheetSelectionContext

    if IsObject(AutomationSpreadsheetSelectionContext) {
        snapshot := AutomationSpreadsheetSelectionContext
        if snapshot.Has("error") {
            MsgBox(snapshot["error"] . "`n请回到表格退出单元格编辑状态，重新选中后打开面板。", title, "Icon!")
            return ""
        }
        try {
            app := TryGetActiveComObject(snapshot["progId"])
            if !IsObject(app)
                throw Error("原表格程序已经关闭")

            workbook := GetWorkbookByIdentity(
                app,
                snapshot["workbookFullName"],
                snapshot["workbookName"]
            )
            if !IsObject(workbook)
                throw Error("原工作簿已经关闭")

            worksheet := workbook.Worksheets(snapshot["worksheetName"])
            selection := worksheet.Range(snapshot["selectionAddress"])
            cells := selection.Cells
            cellCount := cells.Count
            return Map(
                "app", app,
                "kind", snapshot["kind"],
                "name", snapshot["name"],
                "selection", selection
            )
        } catch {
            MsgBox("打开面板时的原选区已经失效。请回到表格重新选中单元格，再按 Ctrl+Shift+E。", title, "Icon!")
            return ""
        }
    }

    context := GetSpreadsheetContext(title)
    if !IsObject(context)
        return ""

    try {
        selection := context["app"].Selection
        cells := selection.Cells
        cellCount := cells.Count
    } catch {
        MsgBox("无法读取当前表格选区。请先选中一个或多个单元格。", title, "Icon!")
        return ""
    }

    context["selection"] := selection
    return context
}

GetWorkbookByIdentity(app, fullName, name) {
    try {
        for workbook in app.Workbooks {
            if (workbook.FullName = fullName || workbook.Name = name)
                return workbook
        }
    }
    return ""
}

ConnectSpreadsheetApplication(progId, kind, name, title, showError) {
    app := TryGetActiveComObject(progId)
    if IsObject(app)
        return Map("app", app, "kind", kind, "name", name)

    if showError
        MsgBox("无法连接当前 " . name . " 窗口。请确认文件已完全打开后重试。", title, "Icon!")
    return ""
}

TryGetActiveComObject(progId) {
    try return ComObjActive(progId)
    catch
        return ""
}

FindLatestUndoActionIndex(provider) {
    global ExcelCommandUndoStack

    Loop ExcelCommandUndoStack.Length {
        index := ExcelCommandUndoStack.Length - A_Index + 1
        if (ExcelCommandUndoStack[index]["provider"] = provider)
            return index
    }
    return 0
}

RestoreUndoAction(app, action) {
    oldAlerts := GetSpreadsheetProperty(app, "DisplayAlerts", true)
    oldUpdating := GetSpreadsheetProperty(app, "ScreenUpdating", true)
    oldCalc := GetSpreadsheetProperty(app, "Calculation", -4105)
    wsPageBreakStates := []
    try {
        try app.DisplayAlerts := false
        try app.ScreenUpdating := false
        try app.Calculation := -4135

        currentWbFullName := ""
        currentWb := ""
        currentWsName := ""
        currentWs := ""

        for _, item in action["items"] {
            itemWbName := item["workbook"]
            itemWsName := item["sheet"]

            if (itemWbName != currentWbFullName || !IsObject(currentWb)) {
                currentWbFullName := itemWbName
                currentWb := GetWorkbookByFullName(app, currentWbFullName)
                if (!IsObject(currentWb))
                    throw Error("找不到原工作簿：" . currentWbFullName)
                currentWsName := ""
                currentWs := ""
            }

            if (itemWsName != currentWsName || !IsObject(currentWs)) {
                currentWsName := itemWsName
                currentWs := currentWb.Worksheets(currentWsName)
                try {
                    oldPb := currentWs.DisplayPageBreaks
                    wsPageBreakStates.Push(Map("ws", currentWs, "state", oldPb))
                    currentWs.DisplayPageBreaks := false
                }
            }

            if (item.Has("kind") && item["kind"] = "merge") {
                RestoreMergedRangeUndoItem(currentWs, item)
                continue
            }
            if (item.Has("kind") && item["kind"] = "unmergeFill") {
                RestoreUnmergedRangeUndoItem(currentWs, item)
                continue
            }

            range := currentWs.Range(item["address"])
            range.Formula := item["formula"]
            if item.Has("wraps") {
                for wrap in item["wraps"]
                    currentWs.Range(wrap["address"]).WrapText := wrap["value"]
            }
        }
    } finally {
        for _, pbInfo in wsPageBreakStates {
            try pbInfo["ws"].DisplayPageBreaks := pbInfo["state"]
        }
        try app.Calculation := oldCalc
        try app.ScreenUpdating := oldUpdating
        try app.DisplayAlerts := oldAlerts
    }
}

RestoreUnmergedRangeUndoItem(ws, item) {
    if (!item["applied"])
        return

    range := ws.Range(item["address"])
    range.UnMerge()

    for cellState in item["cells"] {
        cell := ws.Range(cellState["address"])
        SetSpreadsheetCellContent(cell, cellState["content"])
    }

    range.Merge()
    if (item.Has("horizontalAlignment") && item["horizontalAlignment"] != "")
        try range.HorizontalAlignment := item["horizontalAlignment"]
    if (item.Has("verticalAlignment") && item["verticalAlignment"] != "")
        try range.VerticalAlignment := item["verticalAlignment"]
    item["applied"] := false
}

RestoreMergedRangeUndoItem(ws, item) {
    if (!item["applied"])
        return

    range := ws.Range(item["address"])
    range.UnMerge()

    cells := item["cells"]
    if (cells.Length > 0) {
        firstContent := cells[1]["content"]
        allSame := true
        for cellState in cells {
            if (cellState["content"] != firstContent) {
                allSame := false
                break
            }
        }
        if (allSame) {
            ; 纯同值区域利用 Range 广播一次性写回，极大压缩撤销还原耗时
            SetSpreadsheetCellContent(range, firstContent)
        } else {
            for cellState in cells {
                cell := ws.Range(cellState["address"])
                SetSpreadsheetCellContent(cell, cellState["content"])
                if (cellState.Has("horizontalAlignment") && cellState["horizontalAlignment"] != "")
                    try cell.HorizontalAlignment := cellState["horizontalAlignment"]
                if (cellState.Has("verticalAlignment") && cellState["verticalAlignment"] != "")
                    try cell.VerticalAlignment := cellState["verticalAlignment"]
            }
        }
    }

    item["applied"] := false
}

GetSpreadsheetProperty(app, propertyName, fallback) {
    try {
        if (propertyName = "ScreenUpdating")
            return app.ScreenUpdating
        if (propertyName = "EnableEvents")
            return app.EnableEvents
        if (propertyName = "DisplayAlerts")
            return app.DisplayAlerts
    }
    return fallback
}

AddFixedTextToSelectedFileNames(mode) {
    title := mode = "prefix" ? "批量添加文件名前缀" : "批量添加文件名后缀"
    prompt := mode = "prefix" ? "请输入要添加到文件名前面的文字：" : "请输入要添加到文件名后面的文字："
    input := InputBox(prompt, title, "w430 h135")
    if (input.Result != "OK")
        return

    text := input.Value
    if (text = "")
        return

    if !ValidateFileNamePart(text, title)
        return

    files := GetSelectedFilePaths()
    if (files.Length = 0) {
        MsgBox("没有读取到选中的文件。请先在资源管理器或桌面选中一个或多个文件。", title, "Icon!")
        return
    }

    operations := []
    for _, path in files {
        if DirExist(path)
            continue
        SplitPath(path, &name, &dir, &ext, &nameNoExt)
        newBase := mode = "prefix" ? text . nameNoExt : nameNoExt . text
        newPath := dir . "\" . newBase . (ext = "" ? "" : "." . ext)
        if (newPath != path)
            operations.Push(Map("from", path, "to", newPath))
    }

    ExecuteFileRenameOperations(operations, title)
}

AddSequentialNumberPrefixToSelectedFileNames() {
    title := "批量添加数字前缀"
    input := InputBox("请输入起始数字，例如 1：", title, "w430 h135")
    if (input.Result != "OK")
        return

    startText := Trim(input.Value)
    if !RegExMatch(startText, "^\d+$") {
        MsgBox("请输入 0 或正整数。", title, "Icon!")
        return
    }

    separatorInput := InputBox("请输入数字和原文件名之间的分隔符。可留空，例如输入 - 会得到 1-文件名。", title, "w500 h145")
    if (separatorInput.Result != "OK")
        return

    separator := separatorInput.Value
    if !ValidateFileNamePart(separator, title)
        return

    files := GetSelectedFilePaths()
    if (files.Length = 0) {
        MsgBox("没有读取到选中的文件。请先在资源管理器或桌面选中一个或多个文件。", title, "Icon!")
        return
    }

    files := SortPathsByFileName(files)
    number := Integer(startText)
    operations := []
    for _, path in files {
        if DirExist(path)
            continue
        SplitPath(path, &name, &dir, &ext, &nameNoExt)
        newPath := dir . "\" . number . separator . nameNoExt . (ext = "" ? "" : "." . ext)
        if (newPath != path)
            operations.Push(Map("from", path, "to", newPath))
        number += 1
    }

    ExecuteFileRenameOperations(operations, title)
}

RemoveTextFromSelectedFileNames(position) {
    title := position = "end" ? "删除文件名末尾文字" : "删除文件名前端文字"
    prompt := position = "end"
        ? "请输入要删除的末尾文字位数，例如 1、2、3、4："
        : "请输入要删除的开头文字位数，例如 1、2、3、4："
    input := InputBox(prompt, title, "w460 h135")
    if (input.Result != "OK")
        return

    countText := Trim(input.Value)
    if !RegExMatch(countText, "^\d+$") {
        MsgBox("请输入正整数，例如 1、2、3、4。", title, "Icon!")
        return
    }

    deleteCount := Integer(countText)
    if (deleteCount < 1) {
        MsgBox("删除位数必须大于 0。", title, "Icon!")
        return
    }

    files := GetSelectedFilePaths()
    if (files.Length = 0) {
        MsgBox("没有读取到选中的文件。请先在资源管理器或桌面选中一个或多个文件。", title, "Icon!")
        return
    }

    operations := []
    for _, path in files {
        if DirExist(path)
            continue
        SplitPath(path, &name, &dir, &ext, &nameNoExt)
        newBase := RemoveFileNameText(nameNoExt, deleteCount, position)
        if (newBase = "") {
            MsgBox("删除后文件名会变空，已取消。`n`n文件：" . name, title, "Icon!")
            return
        }
        newPath := dir . "\" . newBase . (ext = "" ? "" : "." . ext)
        if (newPath != path)
            operations.Push(Map("from", path, "to", newPath))
    }

    ExecuteFileRenameOperations(operations, title)
}

ReplaceTextInSelectedFileNames() {
    title := "批量替换文件名内容"
    findText := "ML"
    replaceText := "目录"

    files := GetSelectedFilePaths()
    if (files.Length = 0) {
        MsgBox("没有读取到选中的文件。请先在资源管理器或桌面选中一个或多个文件。", title, "Icon!")
        return
    }

    operations := []
    for _, path in files {
        path := Trim(path, '" `t')
        if DirExist(path)
            continue
        slashPos := InStr(path, "\",, -1)
        if (slashPos < 1)
            continue
        dir := SubStr(path, 1, slashPos - 1)
        name := SubStr(path, slashPos + 1)
        if !RegExMatch(name, "i)" . findText)
            continue
        newName := RegExReplace(name, "i)" . findText, replaceText)
        if (newName = "") {
            MsgBox("替换后文件名会变空，已取消。`n`n文件：" . name, title, "Icon!")
            return
        }
        newPath := dir . "\" . newName
        if (newPath != path)
            operations.Push(Map("from", path, "to", newPath))
    }

    ExecuteFileRenameOperations(operations, title)
}

ReplaceCustomTextInSelectedFileNames() {
    title := "替换文件名中的文字"
    findInput := InputBox("请输入要查找的文件名文字：", title, "w450 h140")
    if (findInput.Result != "OK")
        return

    findText := findInput.Value
    if (findText = "") {
        MsgBox("要查找的文字不能为空。", title, "Icon!")
        return
    }

    replaceInput := InputBox("请输入替换后的文字；留空表示删除查找内容：", title, "w470 h145")
    if (replaceInput.Result != "OK")
        return

    replaceText := replaceInput.Value
    if (replaceText != "" && !ValidateFileNamePart(replaceText, title))
        return

    files := GetSelectedFilePaths()
    if (files.Length = 0) {
        MsgBox("没有读取到选中的文件。请先在资源管理器或桌面选中一个或多个文件。", title, "Icon!")
        return
    }

    operations := []
    for _, path in files {
        if DirExist(path)
            continue
        SplitPath(path, , &dir, &ext, &nameNoExt)
        if !InStr(nameNoExt, findText, false)
            continue
        newBase := StrReplace(nameNoExt, findText, replaceText, false)
        if (newBase = "") {
            MsgBox("替换后文件名会变空，已取消。`n`n文件：" . path, title, "Icon!")
            return
        }
        newPath := dir . "\" . newBase . (ext = "" ? "" : "." . ext)
        if (newPath != path)
            operations.Push(Map("from", path, "to", newPath))
    }

    ExecuteFileRenameOperations(operations, title)
}

MergeSelectedPdfFiles() {
    title := "合并 PDF"
    selectedFiles := GetSelectedFilePaths()
    pdfFiles := []
    for _, path in selectedFiles {
        if DirExist(path)
            continue
        SplitPath(path, , , &extension)
        if (StrLower(extension) = "pdf")
            pdfFiles.Push(path)
    }

    if (pdfFiles.Length < 2) {
        MsgBox("请先在资源管理器或桌面中选中至少两个 PDF 文件，再打开面板执行合并。", title, "Icon!")
        return
    }

    input := InputBox("请输入合并后的文件名，例如：合并结果.pdf", title, "w460 h145", "合并结果.pdf")
    if (input.Result != "OK")
        return

    outputName := Trim(input.Value)
    if (outputName = "")
        outputName := "合并结果.pdf"
    if (StrLower(SubStr(outputName, -3)) = ".pdf")
        outputName := SubStr(outputName, 1, -4)
    if (outputName = "" || !ValidateFileNamePart(outputName, title))
        return

    firstPath := pdfFiles[1]
    SplitPath(firstPath, , &outputDir)
    outputPath := outputDir . "\" . outputName . ".pdf"
    if FileExist(outputPath) {
        if (MsgBox("目标文件已存在：`n`n" . outputPath . "`n`n是否覆盖？", title, "YesNo Icon? Default2") != "Yes")
            return
    }

    previewLines := []
    for _, path in pdfFiles {
        SplitPath(path, &fileName)
        previewLines.Push(fileName)
    }
    prompt := "将按当前选中顺序合并 " . pdfFiles.Length . " 个 PDF：`n`n"
        . JoinLines(previewLines, 10)
        . "`n`n输出位置：" . outputPath . "`n`n继续？"
    if (MsgBox(prompt, title, "OKCancel Icon? Default2") != "OK")
        return

    uniqueSuffix := A_NowUTC . "-" . Random(100000, 999999)
    scriptPath := A_Temp . "\merge-selected-pdfs-" . uniqueSuffix . ".py"
    tempOutputPath := outputPath . ".tmp-" . uniqueSuffix
    pythonScript := "import sys`n"
        . "from pypdf import PdfWriter`n"
        . "inputs = sys.argv[1:-2]`n"
        . "temp_output, final_output = sys.argv[-2:]`n"
        . "writer = PdfWriter()`n"
        . "try:`n"
        . "    for path in inputs:`n"
        . "        writer.append(path)`n"
        . "    with open(temp_output, 'wb') as output:`n"
        . "        writer.write(output)`n"
        . "finally:`n"
        . "    writer.close()`n"
        . "import os`n"
        . "if os.path.exists(final_output):`n"
        . "    os.remove(final_output)`n"
        . "os.rename(temp_output, final_output)`n"

    try {
        if FileExist(tempOutputPath)
            FileDelete(tempOutputPath)
        FileAppend(pythonScript, scriptPath, "UTF-8")
        commandLine := 'python "' . scriptPath . '"'
        for _, path in pdfFiles
            commandLine .= ' "' . StrReplace(path, '"', '\"') . '"'
        commandLine .= ' "' . tempOutputPath . '" "' . outputPath . '"'
        exitCode := RunWait(commandLine, outputDir, "Hide")
        if (exitCode != 0) {
            if FileExist(tempOutputPath)
                FileDelete(tempOutputPath)
            MsgBox("PDF 合并失败。请确认 PDF 未损坏且本机 Python 已安装 pypdf。`n`n退出代码：" . exitCode, title, "Icon!")
            return
        }
        TrayTip("已合并 " . pdfFiles.Length . " 个 PDF 文件。", title, 1)
    } catch as err {
        if FileExist(tempOutputPath)
            try FileDelete(tempOutputPath)
        MsgBox("PDF 合并失败：`n`n" . err.Message, title, "Icon!")
    } finally {
        if FileExist(scriptPath)
            try FileDelete(scriptPath)
    }
}

ConvertSelectedExcelFilesToPdf() {
    global AutomationContextHwnd
    title := "Excel 转 PDF"
    selectedFiles := GetSelectedFilePaths()
    LogPanelDiagnostic("Excel转换选区", "contextHwnd=" . AutomationContextHwnd . "; pathCount=" . selectedFiles.Length
        . (selectedFiles.Length ? "`r`n" . JoinLines(selectedFiles) : "`r`n未读取到路径"))
    excelFiles := []
    seenPaths := Map()
    supportedExtensions := Map("xls", true, "xlsx", true, "xlsm", true, "xlsb", true)
    for _, path in selectedFiles {
        if DirExist(path)
            continue
        SplitPath(path, , , &extension)
        pathKey := StrLower(path)
        if (supportedExtensions.Has(StrLower(extension)) && !seenPaths.Has(pathKey)) {
            seenPaths[pathKey] := true
            excelFiles.Push(path)
        }
    }

    if (excelFiles.Length = 0) {
        LogPanelDiagnostic("Excel转换未找到工作簿", "selectedPathCount=" . selectedFiles.Length)
        MsgBox("请先在资源管理器或桌面选中至少一个 Excel 工作簿（.xls、.xlsx、.xlsm 或 .xlsb）。", title, "Icon!")
        return
    }

    if (excelFiles.Length > 1) {
        prompt := "当前选区中检测到 " . excelFiles.Length . " 个不同的 Excel 工作簿：`n`n"
            . JoinLines(excelFiles, 8)
            . "`n`n将逐个把整个工作簿（含隐藏工作表）转换为同名 PDF，继续吗？"
        if (MsgBox(prompt, title, "YesNo Icon? Default2") != "Yes")
            return
    }

    outputFiles := []
    existingFiles := []
    outputPaths := Map()
    for _, path in excelFiles {
        SplitPath(path, , &dir, , &nameNoExt)
        outputPath := dir . "\" . nameNoExt . ".pdf"
        outputKey := StrLower(outputPath)
        if outputPaths.Has(outputKey) {
            MsgBox("多个工作簿会生成同一个 PDF 文件，无法安全批量转换：`n`n" . outputPath
                . "`n`n请将工作簿改成不同的文件名后再试。", title, "Icon!")
            return
        }
        outputPaths[outputKey] := path
        outputFiles.Push(Map("source", path, "output", outputPath))
        if FileExist(outputPath)
            existingFiles.Push(outputPath)
    }

    if (existingFiles.Length > 0) {
        prompt := "以下同名 PDF 已存在，转换后会覆盖：`n`n"
            . JoinLines(existingFiles, 8)
            . "`n`n共 " . existingFiles.Length . " 个。是否继续？"
        if (MsgBox(prompt, title, "YesNo Icon? Default2") != "Yes")
            return
    }

    excel := ""
    successList := []
    failedList := []
    try {
        excel := ComObject("Excel.Application")
        excel.Visible := false
        excel.DisplayAlerts := false
        excel.EnableEvents := false
        excel.AskToUpdateLinks := false
        excel.AutomationSecurity := 3

        for _, item in outputFiles {
            tempOutput := item["output"] . ".tmp-" . A_NowUTC . "-" . Random(100000, 999999) . ".pdf"
            workbook := ""
            sheetStates := []
            try {
                workbook := excel.Workbooks.Open(item["source"], 0, true)
                for sheet in workbook.Worksheets {
                    visibility := sheet.Visible
                    sheetStates.Push(Map("sheet", sheet, "visible", visibility))
                    if (visibility != -1)
                        sheet.Visible := -1
                }

                try {
                    workbook.ExportAsFixedFormat(0, tempOutput, 0, true, false)
                } finally {
                    Loop sheetStates.Length {
                        state := sheetStates[sheetStates.Length - A_Index + 1]
                        if (state["visible"] != -1)
                            state["sheet"].Visible := state["visible"]
                    }
                }

                workbook.Close(false)
                workbook := ""
                if !FileExist(tempOutput)
                    throw Error("Excel 未生成 PDF 文件。")
                FileMove(tempOutput, item["output"], 1)
                successList.Push(item["output"])
                LogPanelDiagnostic("Excel转换成功", item["source"] . "`r`n=> " . item["output"])
            } catch as err {
                if IsObject(workbook)
                    try workbook.Close(false)
                if FileExist(tempOutput)
                    try FileDelete(tempOutput)
                failedList.Push(item["source"] . "`n  " . err.Message)
                LogPanelDiagnostic("Excel转换单文件失败", item["source"] . "`r`n" . err.Message)
            }
        }
    } catch as err {
        failedList.Push("无法启动 Microsoft Excel。请确认已安装 Excel。`n  " . err.Message)
        LogPanelDiagnostic("Excel转换初始化失败", err.Message)
    } finally {
        if IsObject(excel)
            try excel.Quit()
    }

    if (failedList.Length > 0) {
        message := "转换完成：成功 " . successList.Length . " 个，失败 " . failedList.Length . " 个。`n`n"
            . JoinLines(failedList, 6)
        if (successList.Length > 0)
            message .= "`n`n成功生成：`n" . JoinLines(successList, 6)
        MsgBox(message, title, "Icon!")
    } else {
        LogPanelDiagnostic("Excel转换完成", "successCount=" . successList.Length . "; failedCount=0")
        TrayTip("已将 " . successList.Length . " 个 Excel 工作簿转换为 PDF。", title, 1)
    }
}

ConvertSelectedWordFilesToPdf() {
    global AutomationContextHwnd
    title := "Word 转 PDF"
    selectedFiles := GetSelectedFilePaths()
    LogPanelDiagnostic("Word转换选区", "contextHwnd=" . AutomationContextHwnd . "; pathCount=" . selectedFiles.Length
        . (selectedFiles.Length ? "`r`n" . JoinLines(selectedFiles) : "`r`n未读取到路径"))
    wordFiles := []
    seenPaths := Map()
    for _, path in selectedFiles {
        if DirExist(path)
            continue
        SplitPath(path, , , &extension)
        pathKey := StrLower(path)
        if ((StrLower(extension) = "doc" || StrLower(extension) = "docx" || StrLower(extension) = "docm")
            && !seenPaths.Has(pathKey)) {
            seenPaths[pathKey] := true
            wordFiles.Push(path)
        }
    }

    if (wordFiles.Length = 0) {
        LogPanelDiagnostic("Word转换未找到文档", "selectedPathCount=" . selectedFiles.Length)
        MsgBox("请先在资源管理器或桌面选中至少一个 Word 文档（.doc、.docx 或 .docm）。", title, "Icon!")
        return
    }

    if (wordFiles.Length > 1) {
        LogPanelDiagnostic("Word转换多文件确认", "documentCount=" . wordFiles.Length . "`r`n" . JoinLines(wordFiles))
        prompt := "当前选区中检测到 " . wordFiles.Length . " 个不同的 Word 文档：`n`n"
            . JoinLines(wordFiles, 8)
            . "`n`n将逐个转换为同名 PDF，继续吗？"
        if (MsgBox(prompt, title, "YesNo Icon? Default2") != "Yes")
            return
    }

    outputFiles := []
    existingFiles := []
    for _, path in wordFiles {
        SplitPath(path, , &dir, , &nameNoExt)
        outputPath := dir . "\" . nameNoExt . ".pdf"
        outputFiles.Push(Map("source", path, "output", outputPath))
        if FileExist(outputPath)
            existingFiles.Push(outputPath)
    }

    if (existingFiles.Length > 0) {
        prompt := "以下同名 PDF 已存在，转换后会覆盖：`n`n"
            . JoinLines(existingFiles, 8)
            . "`n`n共 " . existingFiles.Length . " 个。是否继续？"
        if (MsgBox(prompt, title, "YesNo Icon? Default2") != "Yes")
            return
    }

    word := ""
    successList := []
    failedList := []
    try {
        word := ComObject("Word.Application")
        word.Visible := false
        word.DisplayAlerts := 0
        word.AutomationSecurity := 3

        for _, item in outputFiles {
            tempOutput := item["output"] . ".tmp-" . A_NowUTC . "-" . Random(100000, 999999) . ".pdf"
            doc := ""
            try {
                doc := word.Documents.Open(item["source"], false, true, false)
                doc.ExportAsFixedFormat(tempOutput, 17)
                doc.Close(0)
                doc := ""
                FileMove(tempOutput, item["output"], 1)
                successList.Push(item["output"])
                LogPanelDiagnostic("Word转换成功", item["source"] . "`r`n=> " . item["output"])
            } catch as err {
                if IsObject(doc)
                    try doc.Close(0)
                if FileExist(tempOutput)
                    try FileDelete(tempOutput)
                failedList.Push(item["source"] . "`n  " . err.Message)
                LogPanelDiagnostic("Word转换单文件失败", item["source"] . "`r`n" . err.Message)
            }
        }
    } catch as err {
        failedList.Push("无法启动 Microsoft Word。请确认已安装 Word。`n  " . err.Message)
        LogPanelDiagnostic("Word转换初始化失败", err.Message)
    } finally {
        if IsObject(word)
            try word.Quit(0)
    }

    if (failedList.Length > 0) {
        message := "转换完成：成功 " . successList.Length . " 个，失败 " . failedList.Length . " 个。`n`n"
            . JoinLines(failedList, 6)
        if (successList.Length > 0)
            message .= "`n`n成功生成：`n" . JoinLines(successList, 6)
        MsgBox(message, title, "Icon!")
    } else {
        LogPanelDiagnostic("Word转换完成", "successCount=" . successList.Length . "; failedCount=0")
        TrayTip("已将 " . successList.Length . " 个 Word 文档转换为 PDF。", title, 1)
    }
}

RemoveFileNameText(text, deleteCount, position) {
    if (deleteCount >= StrLen(text))
        return ""

    if (position = "start")
        return SubStr(text, deleteCount + 1)

    return SubStr(text, 1, StrLen(text) - deleteCount)
}

GetSelectedFilePaths() {
    global AutomationSelectedFilePaths
    return AutomationSelectedFilePaths.Clone()
}

DeduplicateSelectedFilePaths(paths) {
    uniquePaths := []
    seenPaths := Map()
    for _, path in paths {
        key := StrLower(path)
        if seenPaths.Has(key)
            continue
        seenPaths[key] := true
        uniquePaths.Push(path)
    }
    return uniquePaths
}

GetExplorerSelectedFilePaths(hwnd) {
    selected := []
    shellApp := ComObject("Shell.Application")
    try {
        for window in shellApp.Windows {
            try {
                if (window.HWND != hwnd)
                    continue
                for item in window.Document.SelectedItems {
                    selected.Push(item.Path)
                }
                break
            }
        }
    }
    return selected
}

GetDesktopSelectedFilePaths() {
    selected := []
    shellApp := ComObject("Shell.Application")
    try {
        desktopView := shellApp.Windows.FindWindowSW(0, 0, 8, 0, 1).Document
        for item in desktopView.SelectedItems {
            selected.Push(item.Path)
        }
    }
    return selected
}

ExecuteFileRenameOperations(operations, title) {
    if (operations.Length = 0) {
        MsgBox("没有需要改名的文件。文件夹会被自动跳过。", title)
        return
    }

    conflictText := ValidateRenameOperations(operations)
    if (conflictText != "") {
        MsgBox(conflictText, title, "Icon!")
        return
    }

    preview := BuildRenamePreview(operations)
    if (MsgBox(preview, title, "OKCancel Icon?") != "OK")
        return

    failed := []
    for _, op in operations {
        try FileMove(op["from"], op["to"], false)
        catch as err
            failed.Push(op["from"] . "`n  " . err.Message)
    }

    if (failed.Length > 0)
        MsgBox("部分文件改名失败：`n`n" . JoinLines(failed, 8), title, "Icon!")
}

ValidateRenameOperations(operations) {
    targets := Map()
    for _, op in operations {
        from := op["from"]
        to := op["to"]
        key := StrLower(to)

        if targets.Has(key)
            return "目标文件名重复：`n" . to
        targets[key] := true

        if (FileExist(to) && StrLower(from) != key)
            return "目标文件已存在，已取消：`n" . to
    }
    return ""
}

BuildRenamePreview(operations) {
    lines := []
    maxPreview := Min(operations.Length, 12)
    Loop maxPreview {
        op := operations[A_Index]
        SplitPath(op["from"], &fromName)
        SplitPath(op["to"], &toName)
        lines.Push(fromName . "  ->  " . toName)
    }
    if (operations.Length > maxPreview)
        lines.Push("还有 " . (operations.Length - maxPreview) . " 个文件未显示")

    return "即将修改 " . operations.Length . " 个文件名：`n`n"
        . JoinLines(lines)
        . "`n`n确认执行？"
}

ValidateFileNamePart(text, title) {
    if RegExMatch(text, '[\\/:*?"<>|]') {
        MsgBox('文字里不能包含这些字符：\ / : * ? " < > |', title, "Icon!")
        return false
    }
    return true
}

SortPathsByFileName(paths) {
    sorted := paths.Clone()
    loop sorted.Length {
        i := A_Index
        j := i + 1
        while (j <= sorted.Length) {
            SplitPath(sorted[i], &nameA)
            SplitPath(sorted[j], &nameB)
            if (StrCompare(nameA, nameB, false) > 0) {
                temp := sorted[i]
                sorted[i] := sorted[j]
                sorted[j] := temp
            }
            j += 1
        }
    }
    return sorted
}

JoinLines(lines, limit := 0) {
    text := ""
    count := limit > 0 ? Min(lines.Length, limit) : lines.Length
    Loop count {
        if (A_Index > 1)
            text .= "`n"
        text .= lines[A_Index]
    }
    if (limit > 0 && lines.Length > limit)
        text .= "`n还有 " . (lines.Length - limit) . " 条未显示"
    return text
}

SpreadsheetHasNativeUndo(app) {
    try {
        undoControl := app.CommandBars.FindControl(1, 128)
        if IsObject(undoControl)
            return undoControl.Enabled
    }
    return false
}

CreateUndoAction(name, app, provider) {
    return Map(
        "name", name,
        "provider", provider,
        "createdAt", A_Now,
        "items", []
    )
}

AddUndoCell(action, cell) {
    AddUndoRange(action, cell)
}

AddUndoRange(action, range) {
    workbook := range.Worksheet.Parent.FullName
    sheet := range.Worksheet.Name
    address := range.Address(false, false)
    formula := GetSpreadsheetUndoFormula(range)

    action["items"].Push(Map(
        "workbook", workbook,
        "sheet", sheet,
        "address", address,
        "formula", formula
    ))
}

; Formula 写回会把 =开头的常量文字变成公式、数字文字变成数值。
; 对非公式的字符串明确添加文字前缀，恢复时保留原始类型。
GetSpreadsheetUndoFormula(range) {
    formula := range.Formula
    allFormulas := range.HasFormula
    if (allFormulas = true)
        return formula
    values := range.Value2
    rows := range.Rows.Count
    columns := range.Columns.Count
    if (rows = 1 && columns = 1)
        return Type(values) = "String" && values != "" ? "'" . values : formula
    formulaCells := Map()
    if (allFormulas != false) {
        app := range.Application
        actualFormulas := app.Intersect(range, range.SpecialCells(-4123))
        if IsObject(actualFormulas) {
            top := range.Row
            left := range.Column
            for area in actualFormulas.Areas {
                firstRow := area.Row - top + 1
                firstColumn := area.Column - left + 1
                Loop area.Rows.Count {
                    row := firstRow + A_Index - 1
                    Loop area.Columns.Count
                        formulaCells[row . ":" . (firstColumn + A_Index - 1)] := true
                }
            }
        }
    }
    Loop rows {
        row := A_Index
        Loop columns {
            column := A_Index
            value := values[row, column]
            if (Type(value) = "String" && value != "" && !formulaCells.Has(row . ":" . column))
                formula[row, column] := "'" . value
        }
    }
    return formula
}

AddUndoMergeRange(action, range) {
    wbFullName := range.Worksheet.Parent.FullName
    wsName := range.Worksheet.Name
    addr := range.Address(false, false)

    cells := []
    for cell in range.Cells {
        cells.Push(Map(
            "address", cell.Address(false, false),
            "content", GetSpreadsheetCellContent(cell),
            "horizontalAlignment", cell.HorizontalAlignment,
            "verticalAlignment", cell.VerticalAlignment
        ))
    }

    item := Map(
        "kind", "merge",
        "workbook", wbFullName,
        "sheet", wsName,
        "address", addr,
        "cells", cells,
        "applied", false
    )
    action["items"].Push(item)
    return item
}

AddUndoUnmergeRange(action, range) {
    ; 合并区域只有左上角保留有效内容，撤销时无需逐个保存空白单元格。
    firstCell := range.Cells(1, 1)
    fillContent := GetSpreadsheetCellContent(firstCell)
    wbFullName := range.Worksheet.Parent.FullName
    wsName := range.Worksheet.Name
    addr := range.Address(false, false)

    cells := [Map(
        "address", firstCell.Address(false, false),
        "content", fillContent
    )]

    item := Map(
        "kind", "unmergeFill",
        "workbook", wbFullName,
        "sheet", wsName,
        "address", addr,
        "cells", cells,
        "fillContent", fillContent,
        "horizontalAlignment", range.HorizontalAlignment,
        "verticalAlignment", range.VerticalAlignment,
        "applied", false
    )
    action["items"].Push(item)
    return item
}

PushUndoAction(action) {
    global ExcelCommandUndoStack

    if (action["items"].Length = 0)
        return

    ExcelCommandUndoStack.Push(action)
    while (ExcelCommandUndoStack.Length > 10) {
        ExcelCommandUndoStack.RemoveAt(1)
    }
}

GetWorkbookByFullName(xl, fullName) {
    try {
        for wb in xl.Workbooks {
            if (wb.FullName = fullName)
                return wb
        }
    }
    return ""
}

HasMultipleSelectedColumns(selection, expectedColumn) {
    try {
        for area in selection.Areas {
            if (area.Columns.Count > 1)
                return true
            if (area.Column != expectedColumn)
                return true
        }
    } catch {
        return false
    }
    return false
}

GetLastRowInColumn(ws, columnNumber) {
    xlUp := -4162
    return ws.Cells(ws.Rows.Count, columnNumber).End(xlUp).Row
}

GetExcelColumnName(columnNumber) {
    letter := ""
    while (columnNumber > 0) {
        index := Mod(columnNumber - 1, 26)
        letter := Chr(65 + index) . letter
        columnNumber := Floor((columnNumber - 1) / 26)
    }
    return letter
}

CleanCellText(value) {
    text := Trim(value . "")
    text := StrReplace(text, Chr(12288), " ")
    return Trim(text)
}

RemoveBracketTextAndLineBreaks(text) {
    previous := ""
    while (text != previous) {
        previous := text
        text := RegExReplace(text, "\s*[\(（][^()（）]*[\)）]\s*", "")
    }
    text := RegExReplace(text, "[`r`n]+", " ")
    text := StrReplace(text, Chr(12288), " ")
    text := RegExReplace(text, "[ \t]+", " ")
    return Trim(text)
}

RemoveTrailingText(text, deleteCount) {
    keepLength := StrLen(text) - deleteCount
    if (keepLength <= 0)
        return ""
    return SubStr(text, 1, keepLength)
}

RemoveLeadingText(text, deleteCount) {
    if (deleteCount >= StrLen(text))
        return ""
    return SubStr(text, deleteCount + 1)
}

VoltageCategory(text) {
    if RegExMatch(text, "i)(^|[^0-9])110\s*(kv|千伏)")
        return "110"
    if RegExMatch(text, "i)(^|[^0-9])10\s*(kv|千伏)")
        return "10"
    return "other"
}

AppendArray(target, source) {
    for _, value in source {
        target.Push(value)
    }
}
