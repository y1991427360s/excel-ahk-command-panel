#Requires AutoHotkey v2.0

OffsetSpreadsheetSelectionNumbers() {
    title := "数字批量加减"
    context := GetSpreadsheetSelectionContext(title)
    if !IsObject(context)
        return

    input := InputBox("输入要增加或减少的数：`n正数表示增加，负数表示减少。`n例如输入 2：8 → 10；输入 -2：8 → 6。`n合并区域只计算一次；空白、文字、公式和日期跳过。", title, "w430 h210", "1")
    if (input.Result != "OK")
        return
    text := Trim(input.Value)
    if !RegExMatch(text, "^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$") {
        MsgBox("请输入有效的正数或负数，例如 2、-2、0.5。", title, "Icon!")
        return
    }
    try {
        action := ApplySpreadsheetNumericOffset(context, text + 0)
        if IsObject(action)
            PushUndoAction(action)
        else if (text + 0 != 0)
            MsgBox("选区中没有可处理的数字。空白、文字、公式和日期不会修改。", title, "Icon!")
    } catch as err {
        MsgBox("处理失败：" . err.Message, title, "Icon!")
    }
}

; 先完整读取并记录撤销，再开始写入，合并区域只修改左上角数值。
ApplySpreadsheetNumericOffset(context, offset) {
    if !IsSpreadsheetNativeNumber(offset)
        throw Error("增减量必须是数字。")
    if (offset = 0)
        return ""
    app := context["app"]
    selection := context["selection"]
    sheet := selection.Worksheet
    entries := []
    seen := Map()
    boundedAreas := []
    scanCount := 0
    for area in selection.Areas {
        bounded := app.Intersect(area, sheet.UsedRange)
        if !IsObject(bounded)
            continue
        scanCount += bounded.Cells.Count
        if (scanCount > 10000)
            throw Error("选区使用区域超过 10000 格，请分批选择后处理。")
        boundedAreas.Push(bounded)
    }
    for area in boundedAreas {
        for selectedCell in area.Cells {
            cell := selectedCell.MergeCells ? selectedCell.MergeArea.Cells(1, 1) : selectedCell
            address := cell.Address(false, false)
            if seen.Has(address)
                continue
            seen[address] := true
            if cell.HasFormula
                continue
            value := cell.Value2
            if !IsSpreadsheetNativeNumber(value) || IsSpreadsheetDateFormattedCell(cell)
                continue
            entries.Push(Map("cell", cell, "value", value + offset))
        }
    }
    if (entries.Length = 0)
        return ""

    action := CreateUndoAction("数字批量加减", app, context["kind"])
    for entry in entries
        AddUndoCell(action, entry["cell"])
    oldUpdating := GetSpreadsheetProperty(app, "ScreenUpdating", true)
    oldEvents := GetSpreadsheetProperty(app, "EnableEvents", true)
    oldCalculation := GetSpreadsheetProperty(app, "Calculation", -4105)
    try {
        try app.ScreenUpdating := false
        try app.EnableEvents := false
        try app.Calculation := -4135
        for entry in entries
            entry["cell"].Value2 := entry["value"]
    } catch as err {
        try RestoreUndoAction(app, action)
        catch as rollbackError {
            PushUndoAction(action)
            throw Error(err.Message . "`n回滚失败，请尝试面板撤销：" . rollbackError.Message)
        }
        throw err
    } finally {
        try app.Calculation := oldCalculation
        try app.EnableEvents := oldEvents
        try app.ScreenUpdating := oldUpdating
    }
    return action
}
