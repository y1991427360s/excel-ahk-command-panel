#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

global AutomationPanelGui := ""
global AutomationContextHwnd := 0
global AutomationSpreadsheetSelectionContext := ""
global ExcelCommandUndoStack := []
global SelectedDwgPath := ""
global CopyQExe := "D:\CopyQ\copyq.exe"

^+e:: {
    KeyWait("e")
    KeyWait("Ctrl")
    KeyWait("Shift")
    ShowAutomationPanel()
}

#HotIf WinActive("ahk_exe EXCEL.EXE")
$^z::UndoExcelCommandPanelAction()
#HotIf

ShowAutomationPanel() {
    global AutomationPanelGui
    global AutomationContextHwnd
    global AutomationSpreadsheetSelectionContext
    global SelectedDwgPath

    AutomationContextHwnd := WinExist("A")
    AutomationSpreadsheetSelectionContext := CaptureSpreadsheetSelectionContext(AutomationContextHwnd)
    SelectedDwgPath := GetSelectedDwgPath()

    if IsObject(AutomationPanelGui)
        try AutomationPanelGui.Destroy()

    panel := Gui("+AlwaysOnTop", "自动化工具面板")
    panel.SetFont("s10", "Microsoft YaHei UI")
    panel.MarginX := 16
    panel.MarginY := 14

    tabs := panel.AddTab3("x16 y14 w430 h400", ["打开图纸", "表格工具", "批量修改文件", "说明"])

    tabs.UseTab(1)
    if (SelectedDwgPath != "") {
        SplitPath(SelectedDwgPath, &dwgName)
        panel.AddText("x34 y58 w390 c666666", "当前选中的 DWG：")
        panel.AddEdit("x34 y82 w390 h48 ReadOnly -Wrap", dwgName)
    } else {
        panel.AddText("x34 y58 w390 c666666", "请先在资源管理器或桌面选中一个 .dwg 文件，再按 Ctrl+Shift+E。")
    }

    autoCadButton := panel.AddButton("x34 y148 w390 h42", "使用 AutoCAD 2018 打开")
    autoCadButton.OnEvent("Click", (*) => RunPanelCommand(OpenSelectedDwg.Bind("autocad")))

    zwCadButton := panel.AddButton("x34 y202 w390 h42", "使用中望 CAD 2026 打开")
    zwCadButton.OnEvent("Click", (*) => RunPanelCommand(OpenSelectedDwg.Bind("zwcad")))

    quickViewButton := panel.AddButton("x34 y256 w390 h42", "使用 CAD快速看图 打开")
    quickViewButton.OnEvent("Click", (*) => RunPanelCommand(OpenSelectedDwg.Bind("quickview")))

    if (SelectedDwgPath = "") {
        autoCadButton.Enabled := false
        zwCadButton.Enabled := false
        quickViewButton.Enabled := false
    }

    panel.AddText("x34 y320 w390 c666666", "面板只把当前选中的图纸交给所选软件，不会修改图纸。")

    tabs.UseTab(2)
    panel.AddText("x34 y58 w390 c666666", "处理当前 Excel 或 WPS 表格选区。")

    prefixButton := panel.AddButton("x34 y90 w190 h38", "添加前缀")
    prefixButton.OnEvent("Click", (*) => RunPanelCommand(AddTextToExcelSelection.Bind("prefix")))

    suffixButton := panel.AddButton("x234 y90 w190 h38", "添加后缀")
    suffixButton.OnEvent("Click", (*) => RunPanelCommand(AddTextToExcelSelection.Bind("suffix")))

    trimStartButton := panel.AddButton("x34 y136 w190 h38", "删除前端字符")
    trimStartButton.OnEvent("Click", (*) => RunPanelCommand(RemoveTextFromExcelSelection.Bind("start")))

    trimEndButton := panel.AddButton("x234 y136 w190 h38", "删除末尾字符")
    trimEndButton.OnEvent("Click", (*) => RunPanelCommand(RemoveTextFromExcelSelection.Bind("end")))

    removeBracketButton := panel.AddButton("x34 y182 w390 h38", "删除括号内容并合并换行")
    removeBracketButton.OnEvent("Click", (*) => RunPanelCommand(RemoveBracketTextFromExcelSelection))

    dedupeButton := panel.AddButton("x34 y228 w190 h38", "去重整理")
    dedupeButton.OnEvent("Click", (*) => RunPanelCommand(DedupeAndGroupExcelSelectedColumn))

    cableSortButton := panel.AddButton("x234 y228 w190 h38", "按电缆截面排序")
    cableSortButton.OnEvent("Click", (*) => RunPanelCommand(SortCableRowsByCrossSection))

    mergeIdenticalButton := panel.AddButton("x34 y274 w390 h38", "合并相同内容并居中")
    mergeIdenticalButton.OnEvent("Click", (*) => RunPanelCommand(MergeIdenticalSpreadsheetCells))

    roundUpButton := panel.AddButton("x34 y320 w190 h34", "数字向上取十位")
    roundUpButton.OnEvent("Click", (*) => RunPanelCommand(RoundSpreadsheetSelectionUpToTen))

    undoButton := panel.AddButton("x234 y320 w190 h34", "撤销上次表格操作")
    undoButton.OnEvent("Click", (*) => RunPanelCommand(UndoExcelCommandPanelAction))

    panel.AddText("x34 y362 w390 c666666", "Excel 支持 Ctrl+Z；WPS 请使用上方撤销按钮。")

    tabs.UseTab(3)
    panel.AddText("x34 y58 w390 c666666", "先在资源管理器或桌面选中文件，再执行下面的批量改名。")

    filePrefixButton := panel.AddButton("x34 y90 w390 h38", "给选中文件名添加固定前缀")
    filePrefixButton.OnEvent("Click", (*) => RunPanelCommand(AddFixedTextToSelectedFileNames.Bind("prefix")))

    fileSuffixButton := panel.AddButton("x34 y136 w390 h38", "给选中文件名添加固定后缀")
    fileSuffixButton.OnEvent("Click", (*) => RunPanelCommand(AddFixedTextToSelectedFileNames.Bind("suffix")))

    numberPrefixButton := panel.AddButton("x34 y182 w390 h38", "按顺序添加数字前缀")
    numberPrefixButton.OnEvent("Click", (*) => RunPanelCommand(AddSequentialNumberPrefixToSelectedFileNames))

    trimFileEndButton := panel.AddButton("x34 y228 w390 h38", "删除文件名末尾文字")
    trimFileEndButton.OnEvent("Click", (*) => RunPanelCommand(RemoveTextFromSelectedFileNames.Bind("end")))

    trimFileStartButton := panel.AddButton("x34 y274 w390 h38", "删除文件名前端文字")
    trimFileStartButton.OnEvent("Click", (*) => RunPanelCommand(RemoveTextFromSelectedFileNames.Bind("start")))

    replaceFileTextButton := panel.AddButton("x34 y320 w390 h38", "将 ML 替换为目录")
    replaceFileTextButton.OnEvent("Click", (*) => RunPanelCommand(ReplaceTextInSelectedFileNames))

    panel.AddText("x34 y370 w390 c666666", "改名前会显示预览并要求确认；扩展名保持不变。")

    tabs.UseTab(4)
    panel.AddText("x34 y58 w390", "快捷键：Ctrl+Shift+E")
    panel.AddText("x34 y90 w390", "选中 DWG 后打开面板，可选择 AutoCAD、中望 CAD 或 CAD快速看图。")
    panel.AddText("x34 y132 w390", "图纸和文件工具均支持资源管理器与桌面选区。")
    panel.AddText("x34 y174 w390", "为便于迁移，安装脚本会直接启动本项目 src 里的主脚本，不再复制到用户文档目录。")

    tabs.UseTab()
    closeButton := panel.AddButton("x16 y426 w430 h34", "关闭")
    closeButton.OnEvent("Click", (*) => panel.Hide())
    panel.OnEvent("Close", (*) => panel.Hide())
    panel.OnEvent("Escape", (*) => panel.Hide())

    AutomationPanelGui := panel
    panel.Show("w462 h476 Center")
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
    callback.Call()
}

MergeIdenticalSpreadsheetCells() {
    title := "合并相同内容并居中"
    context := GetSpreadsheetSelectionContext(title)
    if !IsObject(context)
        return

    xl := context["app"]
    selection := context["selection"]

    try {
        if (selection.Areas.Count != 1) {
            MsgBox("当前选区不连续。请只选择一个连续的单列区域。", title, "Icon!")
            return
        }
        if (selection.Columns.Count != 1) {
            MsgBox("当前选区跨了多列。请只选择一个连续的单列区域。", title, "Icon!")
            return
        }
        if (selection.Rows.Count < 2) {
            MsgBox("选区至少需要包含两个单元格。", title)
            return
        }
    } catch {
        MsgBox("当前选区不是可处理的单元格区域。", title, "Icon!")
        return
    }

    entries := []
    try {
        for cell in selection.Cells {
            if (cell.MergeCells) {
                MsgBox("选区中包含已经合并的单元格。请先取消合并后再执行。", title, "Icon!")
                return
            }
            if (cell.HasFormula) {
                MsgBox("选区中包含公式单元格。为避免公式丢失，本次操作已取消。", title, "Icon!")
                return
            }
            entries.Push(Map("cell", cell, "value", cell.Value2))
        }
    } catch as err {
        MsgBox("无法读取选区：" . err.Message, title, "Icon!")
        return
    }

    groups := FindIdenticalSpreadsheetCellGroups(entries)
    if (groups.Length = 0) {
        MsgBox("选区中没有连续且内容完全相同的单元格。", title)
        return
    }

    undoAction := CreateUndoAction(title, xl, context["kind"])
    try {
        for group in groups {
            firstAddress := entries[group["start"]]["cell"].Address(false, false)
            lastAddress := entries[group["end"]]["cell"].Address(false, false)
            mergeRange := selection.Worksheet.Range(firstAddress . ":" . lastAddress)
            AddUndoMergeRange(undoAction, mergeRange)
        }
    } catch as err {
        MsgBox("无法记录撤销信息：" . err.Message, title, "Icon!")
        return
    }

    oldScreenUpdating := GetSpreadsheetProperty(xl, "ScreenUpdating", true)
    oldEnableEvents := GetSpreadsheetProperty(xl, "EnableEvents", true)
    oldDisplayAlerts := GetSpreadsheetProperty(xl, "DisplayAlerts", true)
    mergeError := ""

    try {
        try xl.ScreenUpdating := false
        try xl.EnableEvents := false
        try xl.DisplayAlerts := false

        for item in undoAction["items"] {
            wb := GetWorkbookByFullName(xl, item["workbook"])
            if !IsObject(wb)
                throw Error("找不到原工作簿：" . item["workbook"])

            ws := wb.Worksheets(item["sheet"])
            mergeRange := ws.Range(item["address"])
            mergeRange.Merge()
            item["applied"] := true
            mergeRange.HorizontalAlignment := -4108
            mergeRange.VerticalAlignment := -4108
        }
    } catch as err {
        mergeError := err.Message
        try RestoreUndoAction(xl, undoAction)
        catch as rollbackError
            mergeError .= Chr(10) . "回滚失败：" . rollbackError.Message
    } finally {
        try xl.DisplayAlerts := oldDisplayAlerts
        try xl.EnableEvents := oldEnableEvents
        try xl.ScreenUpdating := oldScreenUpdating
    }

    if (mergeError != "") {
        MsgBox("合并失败：" . mergeError, title, "Icon!")
        return
    }

    PushUndoAction(undoAction)
}

FindIdenticalSpreadsheetCellGroups(entries) {
    groups := []
    groupStart := 0

    for index, entry in entries {
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

GetSelectedDwgPath() {
    global AutomationContextHwnd

    hwnd := AutomationContextHwnd
    if (!hwnd)
        return ""

    className := WinGetClass("ahk_id " . hwnd)
    if (className != "CabinetWClass" && className != "ExploreWClass"
        && className != "Progman" && className != "WorkerW")
        return ""

    files := GetSelectedFilePathsFromClipboard(hwnd)
    for _, filePath in files {
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

    try {
        if (WinExist("A") != hwnd)
            WinActivate("ahk_id " . hwnd)

        if hasCopyQ {
            RunWait('"' . CopyQExe . '" disable', , "Hide")
            copyQDisabled := true
        }

        A_Clipboard := ""
        Send("^c")
        if ClipWait(0.6, 1) {
            for line in StrSplit(A_Clipboard, Chr(10), Chr(13)) {
                filePath := Trim(line)
                if (filePath != "" && FileExist(filePath))
                    selected.Push(filePath)
            }
        }
    } finally {
        A_Clipboard := savedClipboard
        if copyQDisabled
            RunWait('"' . CopyQExe . '" enable', , "Hide")
    }

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

    processed := 0
    skippedBlank := 0
    skippedFormula := 0
    failed := 0

    undoAction := CreateUndoAction(isPrefix ? "添加前缀" : "添加后缀", xl, context["kind"])
    oldScreenUpdating := xl.ScreenUpdating
    oldEnableEvents := xl.EnableEvents

    try {
        xl.ScreenUpdating := false
        xl.EnableEvents := false

        for area in selection.Areas {
            for cell in area.Cells {
                try {
                    if (cell.HasFormula) {
                        skippedFormula += 1
                        continue
                    }

                    value := cell.Value
                    if (value = "") {
                        skippedBlank += 1
                        continue
                    }

                    AddUndoCell(undoAction, cell)
                    cell.Value := isPrefix ? addedText . value : value . addedText
                    processed += 1
                } catch {
                    failed += 1
                }
            }
        }
    } finally {
        xl.ScreenUpdating := oldScreenUpdating
        xl.EnableEvents := oldEnableEvents
    }

    if (processed > 0)
        PushUndoAction(undoAction)

    if (failed > 0)
        MsgBox("处理失败：" . failed . " 个单元格", title, "Icon!")
}

RemoveBracketTextFromExcelSelection() {
    context := GetSpreadsheetContext("表格删除括号内容")
    if !IsObject(context)
        return
    xl := context["app"]

    try selection := xl.Selection
    catch {
        MsgBox("无法读取当前表格选区。请先选中一个或多个单元格。", "表格删除括号内容", "Icon!")
        return
    }

    try cells := selection.Cells
    catch {
        MsgBox("当前选区不是单元格区域。请选中一个或多个单元格后再通过面板执行。", "表格删除括号内容", "Icon!")
        return
    }

    processed := 0
    unchanged := 0
    skippedBlank := 0
    skippedFormula := 0
    failed := 0

    undoAction := CreateUndoAction("删除括号内容并合并换行", xl, context["kind"])
    oldScreenUpdating := xl.ScreenUpdating
    oldEnableEvents := xl.EnableEvents

    try {
        xl.ScreenUpdating := false
        xl.EnableEvents := false

        for area in selection.Areas {
            for cell in area.Cells {
                try {
                    if (cell.HasFormula) {
                        skippedFormula += 1
                        continue
                    }

                    value := cell.Value
                    if (value = "") {
                        skippedBlank += 1
                        continue
                    }

                    oldText := value . ""
                    newText := RemoveBracketTextAndLineBreaks(oldText)
                    if (newText = oldText) {
                        unchanged += 1
                        continue
                    }

                    AddUndoCell(undoAction, cell)
                    cell.Value := newText
                    cell.WrapText := false
                    processed += 1
                } catch {
                    failed += 1
                }
            }
        }
    } finally {
        xl.ScreenUpdating := oldScreenUpdating
        xl.EnableEvents := oldEnableEvents
    }

    if (processed > 0)
        PushUndoAction(undoAction)

    if (failed > 0)
        MsgBox("处理失败：" . failed . " 个单元格", "表格删除括号内容", "Icon!")
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

    processed := 0
    unchanged := 0
    skippedBlank := 0
    skippedFormula := 0
    failed := 0

    actionName := isStart ? "删除前端 " : "删除末尾 "
    undoAction := CreateUndoAction(actionName . deleteCount . " 个字符", xl, context["kind"])
    oldScreenUpdating := xl.ScreenUpdating
    oldEnableEvents := xl.EnableEvents

    try {
        xl.ScreenUpdating := false
        xl.EnableEvents := false

        for area in selection.Areas {
            for cell in area.Cells {
                try {
                    if (cell.HasFormula) {
                        skippedFormula += 1
                        continue
                    }

                    value := cell.Value
                    if (value = "") {
                        skippedBlank += 1
                        continue
                    }

                    oldText := value . ""
                    newText := isStart
                        ? RemoveLeadingText(oldText, deleteCount)
                        : RemoveTrailingText(oldText, deleteCount)
                    if (newText = oldText) {
                        unchanged += 1
                        continue
                    }

                    AddUndoCell(undoAction, cell)
                    cell.Value := newText
                    processed += 1
                } catch {
                    failed += 1
                }
            }
        }
    } finally {
        xl.ScreenUpdating := oldScreenUpdating
        xl.EnableEvents := oldEnableEvents
    }

    if (processed > 0)
        PushUndoAction(undoAction)

    if (failed > 0)
        MsgBox("处理失败：" . failed . " 个单元格", title, "Icon!")
}

SortCableRowsByCrossSection() {
    title := "按电缆截面排序"
    context := GetSpreadsheetContext(title)
    if !IsObject(context)
        return
    app := context["app"]

    try selection := app.Selection
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
    context := GetSpreadsheetContext("表格列去重整理")
    if !IsObject(context)
        return
    xl := context["app"]

    try ws := xl.ActiveSheet
    catch {
        MsgBox("无法读取当前活动工作表。请先切换到要整理的工作表。", "表格列去重整理", "Icon!")
        return
    }

    try selection := xl.Selection
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

    Loop lastRow - 1 {
        row := A_Index + 1
        try rawValue := ws.Cells(row, columnNumber).Value
        catch
            continue

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

    undoAction := CreateUndoAction("去重整理", xl, context["kind"])
    oldScreenUpdating := xl.ScreenUpdating
    oldEnableEvents := xl.EnableEvents

    try {
        xl.ScreenUpdating := false
        xl.EnableEvents := false

        restoreRange := ws.Range(columnName . "2:" . columnName . lastRow)
        AddUndoRange(undoAction, restoreRange)
        restoreRange.ClearContents()
        for index, value in result {
            ws.Cells(index + 1, columnNumber).Value := value
        }
    } catch as err {
        MsgBox("整理失败：" . err.Message, "表格列去重整理", "Icon!")
        return
    } finally {
        xl.ScreenUpdating := oldScreenUpdating
        xl.EnableEvents := oldEnableEvents
    }

    PushUndoAction(undoAction)
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
        return ""

    try {
        selection := app.Selection
        cells := selection.Cells
        cellCount := cells.Count
        workbook := app.ActiveWorkbook
        worksheet := app.ActiveSheet
        workbookFullName := workbook.FullName
        workbookName := workbook.Name
        worksheetName := worksheet.Name
        selectionAddress := selection.Address
    } catch {
        return ""
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
    for _, item in action["items"] {
        wb := GetWorkbookByFullName(app, item["workbook"])
        if (!IsObject(wb))
            throw Error("找不到原工作簿：" . item["workbook"])

        ws := wb.Worksheets(item["sheet"])
        if (item.Has("kind") && item["kind"] = "merge") {
            RestoreMergedRangeUndoItem(ws, item)
            continue
        }

        range := ws.Range(item["address"])
        range.Formula := item["formula"]
    }
}

RestoreMergedRangeUndoItem(ws, item) {
    if (!item["applied"])
        return

    range := ws.Range(item["address"])
    range.UnMerge()

    for cellState in item["cells"] {
        cell := ws.Range(cellState["address"])
        SetSpreadsheetCellContent(cell, cellState["content"])
        cell.HorizontalAlignment := cellState["horizontalAlignment"]
        cell.VerticalAlignment := cellState["verticalAlignment"]
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

RemoveFileNameText(text, deleteCount, position) {
    if (deleteCount >= StrLen(text))
        return ""

    if (position = "start")
        return SubStr(text, deleteCount + 1)

    return SubStr(text, 1, StrLen(text) - deleteCount)
}

GetSelectedFilePaths() {
    global AutomationContextHwnd

    hwnd := AutomationContextHwnd
    if (!hwnd)
        hwnd := WinExist("A")
    className := WinGetClass("ahk_id " . hwnd)

    if (className = "CabinetWClass" || className = "ExploreWClass") {
        selected := GetSelectedFilePathsFromClipboard(hwnd)
        if (selected.Length > 0)
            return selected
        selected := GetExplorerSelectedFilePaths(hwnd)
        if (selected.Length > 0)
            return selected
    }

    if (className = "Progman" || className = "WorkerW")
        selected := GetDesktopSelectedFilePaths()
    else
        selected := []

    if (selected.Length > 0)
        return selected

    ; 面板打开后部分系统版本会改变原窗口句柄，扫描所有资源管理器窗口兜底。
    shellApp := ComObject("Shell.Application")
    try {
        for window in shellApp.Windows {
            try {
                selected := []
                for item in window.Document.SelectedItems
                    selected.Push(item.Path)
                if (selected.Length > 0)
                    return selected
            }
        }
    }
    try {
        selected := GetDesktopSelectedFilePaths()
        if (selected.Length > 0)
            return selected
    }

    return []
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
    formula := range.Formula

    action["items"].Push(Map(
        "workbook", workbook,
        "sheet", sheet,
        "address", address,
        "formula", formula
    ))
}

AddUndoMergeRange(action, range) {
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
        "workbook", range.Worksheet.Parent.FullName,
        "sheet", range.Worksheet.Name,
        "address", range.Address(false, false),
        "cells", cells,
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
