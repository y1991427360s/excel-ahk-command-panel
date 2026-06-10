#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

global ExcelCommandPanelGui := ""
global ExcelCommandUndoStack := []

#HotIf WinActive("ahk_exe EXCEL.EXE")
^+e::ShowExcelCommandPanel()
$^z::UndoExcelCommandPanelAction()
#HotIf

ShowExcelCommandPanel() {
    global ExcelCommandPanelGui

    if IsObject(ExcelCommandPanelGui) {
        try {
            ExcelCommandPanelGui.Show()
            WinActivate("Excel 快捷功能面板")
            return
        }
    }

    panel := Gui("+AlwaysOnTop", "Excel 快捷功能面板")
    panel.SetFont("s10", "Microsoft YaHei UI")
    panel.MarginX := 16
    panel.MarginY := 14

    panel.AddText("w360", "选择要执行的 Excel 快捷功能：")

    prefixButton := panel.AddButton("xm y+12 w360 h42", "添加前缀")
    prefixButton.OnEvent("Click", (*) => RunPanelCommand(AddPrefixToExcelSelection))

    dedupeButton := panel.AddButton("xm y+10 w360 h42", "去重整理")
    dedupeButton.OnEvent("Click", (*) => RunPanelCommand(DedupeAndGroupExcelSelectedColumn))

    panel.AddText("xm y+12 w360 c666666", "面板快捷键：Ctrl+Shift+E。脚本操作后可按 Ctrl+Z 撤销。")

    closeButton := panel.AddButton("xm y+12 w360 h34", "关闭")
    closeButton.OnEvent("Click", (*) => panel.Hide())
    panel.OnEvent("Close", (*) => panel.Hide())
    panel.OnEvent("Escape", (*) => panel.Hide())

    ExcelCommandPanelGui := panel
    panel.Show("AutoSize Center")
}

RunPanelCommand(callback) {
    global ExcelCommandPanelGui
    try ExcelCommandPanelGui.Hide()
    callback.Call()
}

AddPrefixToExcelSelection() {
    try xl := ComObjActive("Excel.Application")
    catch {
        MsgBox("没有找到正在运行的 Excel。请先打开 Excel 并选中单元格。", "Excel 批量添加前缀", "Icon!")
        return
    }

    try selection := xl.Selection
    catch {
        MsgBox("无法读取当前 Excel 选区。请先选中一个或多个单元格。", "Excel 批量添加前缀", "Icon!")
        return
    }

    try cells := selection.Cells
    catch {
        MsgBox("当前选区不是单元格区域。请选中一个或多个单元格后再通过面板执行。", "Excel 批量添加前缀", "Icon!")
        return
    }

    input := InputBox("请输入要添加到每个选中单元格前面的文字：", "Excel 批量添加前缀", "w420 h135")
    if (input.Result != "OK")
        return

    prefix := input.Value
    if (prefix = "")
        return

    processed := 0
    skippedBlank := 0
    skippedFormula := 0
    failed := 0

    undoAction := CreateUndoAction("添加前缀", xl)
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
                    cell.Value := prefix . value
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

    message := "已添加前缀：" . processed . " 个单元格"
    if (skippedBlank > 0)
        message .= "`n跳过空白单元格：" . skippedBlank . " 个"
    if (skippedFormula > 0)
        message .= "`n跳过公式单元格：" . skippedFormula . " 个"
    if (failed > 0)
        message .= "`n处理失败：" . failed . " 个"

    MsgBox(message, "Excel 批量添加前缀")
}

DedupeAndGroupExcelSelectedColumn() {
    try xl := ComObjActive("Excel.Application")
    catch {
        MsgBox("没有找到正在运行的 Excel。请先打开 Excel 文件。", "Excel 列去重整理", "Icon!")
        return
    }

    try ws := xl.ActiveSheet
    catch {
        MsgBox("无法读取当前活动工作表。请先切换到要整理的工作表。", "Excel 列去重整理", "Icon!")
        return
    }

    try selection := xl.Selection
    catch {
        MsgBox("无法读取当前选区。请先点一下要整理列里的任意单元格。", "Excel 列去重整理", "Icon!")
        return
    }

    try columnNumber := selection.Column
    catch {
        MsgBox("当前选区不是单元格区域。请先点一下要整理列里的任意单元格。", "Excel 列去重整理", "Icon!")
        return
    }

    if HasMultipleSelectedColumns(selection, columnNumber) {
        MsgBox("当前选区跨了多列。请只选中要整理列里的一个单元格，或只选中单独一列。", "Excel 列去重整理", "Icon!")
        return
    }

    columnName := GetExcelColumnName(columnNumber)
    lastRow := GetLastRowInColumn(ws, columnNumber)
    if (lastRow < 2) {
        MsgBox(columnName . " 列从第 2 行开始没有可整理的数据。", "Excel 列去重整理")
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
        MsgBox(columnName . " 列没有可写回的数据。", "Excel 列去重整理")
        return
    }

    confirmText := "即将整理当前工作表：" . ws.Name
        . "`n范围：" . columnName . "2:" . columnName . lastRow
        . "`n保留唯一值：" . result.Length . " 个"
        . "`n删除重复值：" . duplicateCount . " 个"
        . "`n跳过空白单元格：" . blankCount . " 个"
        . "`n`n写回顺序：10kV -> 110kV -> 其他"
        . "`n注意：脚本会记录本次操作，可按 Ctrl+Z 撤销；脚本不会自动保存文件。"
    if (MsgBox(confirmText, "Excel 列去重整理", "OKCancel Icon?") != "OK")
        return

    undoAction := CreateUndoAction("去重整理", xl)
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
        MsgBox("整理失败：" . err.Message, "Excel 列去重整理", "Icon!")
        return
    } finally {
        xl.ScreenUpdating := oldScreenUpdating
        xl.EnableEvents := oldEnableEvents
    }

    PushUndoAction(undoAction)
    MsgBox("已完成 " . columnName . " 列整理。`n10kV：" . group10.Length . " 个`n110kV：" . group110.Length . " 个`n其他：" . groupOther.Length . " 个", "Excel 列去重整理")
}

UndoExcelCommandPanelAction() {
    global ExcelCommandUndoStack

    if (ExcelCommandUndoStack.Length = 0) {
        Send("^z")
        return
    }

    action := ExcelCommandUndoStack.Pop()
    try xl := ComObjActive("Excel.Application")
    catch {
        MsgBox("没有找到正在运行的 Excel，无法撤销上一次脚本操作。", "Excel 快捷功能撤销", "Icon!")
        return
    }

    oldScreenUpdating := xl.ScreenUpdating
    oldEnableEvents := xl.EnableEvents

    try {
        xl.ScreenUpdating := false
        xl.EnableEvents := false

        for index, item in action["items"] {
            wb := GetWorkbookByFullName(xl, item["workbook"])
            if (!IsObject(wb))
                throw Error("找不到原工作簿：" . item["workbook"])

            ws := wb.Worksheets(item["sheet"])
            range := ws.Range(item["address"])
            range.Formula := item["formula"]
        }
    } catch as err {
        MsgBox("撤销失败：" . err.Message, "Excel 快捷功能撤销", "Icon!")
        return
    } finally {
        xl.ScreenUpdating := oldScreenUpdating
        xl.EnableEvents := oldEnableEvents
    }

    MsgBox("已撤销：" . action["name"], "Excel 快捷功能撤销")
}

CreateUndoAction(name, xl) {
    return Map(
        "name", name,
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
