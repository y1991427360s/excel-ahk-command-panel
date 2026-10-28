; 文本操作只处理已锁定选区中的常量，先完整规划及记录撤销再写入。
GetBoundedSpreadsheetAreas(context, limit := 10000) {
    selection := context["selection"]
    app := context["app"]
    used := selection.Worksheet.UsedRange
    areas := []
    total := 0
    for area in selection.Areas {
        bounded := app.Intersect(area, used)
        if !IsObject(bounded)
            continue
        total += bounded.Cells.CountLarge
        if (total > limit)
            throw Error("选区使用区域超过 " . limit . " 格，请分批选择后处理。")
        areas.Push(bounded)
    }
    return areas
}

TransformSpreadsheetText(value, mode, argument) {
    text := value . ""
    switch mode {
        case "prefix": return argument . text
        case "suffix": return text . argument
        case "start": return RemoveLeadingText(text, argument)
        case "end": return RemoveTrailingText(text, argument)
        case "brackets": return RemoveBracketTextAndLineBreaks(text)
        default: throw Error("未知文字处理方式：" . mode)
    }
}

; 以文本方式写入，避免处理结果以 = 开头时被 Excel 解释成公式。
SpreadsheetLiteralText(text) {
    return text = "" ? "" : "'" . text
}

AppendSpreadsheetTextRun(plans, column, startRow, texts) {
    if (texts.Length = 0)
        return
    values := ComObjArray(12, texts.Length, 1)
    for index, text in texts
        values[index - 1, 0] := SpreadsheetLiteralText(text)
    range := column.Cells(startRow, 1).Resize(texts.Length, 1)
    plans.Push(Map("range", range, "values", values))
}

ApplySpreadsheetTextTransform(context, mode, argument := "") {
    app := context["app"]
    plans := []
    seen := Map()
    for area in GetBoundedSpreadsheetAreas(context) {
        ; HasFormula 混合时为空；SpecialCells 只取常量，并再次相交，
        ; 避免单格 SpecialCells 扩展到整张工作表。
        constants := ""
        if (area.HasFormula = true)
            continue
        try constants := app.Intersect(area, area.SpecialCells(2))
        if !IsObject(constants)
            continue
        for block in constants.Areas {
            if (block.MergeCells != false) {
                for selectedCell in block.Cells {
                    cell := selectedCell.MergeCells ? selectedCell.MergeArea.Cells(1, 1) : selectedCell
                    address := cell.Address(false, false)
                    if seen.Has(address)
                        continue
                    seen[address] := true
                    if cell.HasFormula
                        continue
                    value := cell.Value
                    if (value = "")
                        continue
                    text := TransformSpreadsheetText(value, mode, argument)
                    if (text == value . "")
                        continue
                    plans.Push(Map("range", cell, "values", SpreadsheetLiteralText(text)))
                }
                continue
            }
            for column in block.Columns {
                count := column.Rows.Count
                original := column.Value
                texts := []
                startRow := 1
                Loop count {
                    value := GetSpreadsheetMatrixValue(original, A_Index, 1, count, 1)
                    text := value = "" ? "" : TransformSpreadsheetText(value, mode, argument)
                    if (value = "" || text == value . "") {
                        AppendSpreadsheetTextRun(plans, column, startRow, texts)
                        texts := []
                        continue
                    }
                    if (texts.Length = 0)
                        startRow := A_Index
                    texts.Push(text)
                }
                AppendSpreadsheetTextRun(plans, column, startRow, texts)
            }
        }
    }
    if (plans.Length = 0)
        return ""
    action := CreateUndoAction("批量文字处理", app, context["kind"])
    for plan in plans {
        range := plan["range"]
        AddUndoRange(action, range)
        if (mode = "brackets") {
            wraps := []
            for cell in range.Cells
                wraps.Push(Map("address", cell.Address(false, false), "value", cell.WrapText))
            action["items"][action["items"].Length]["wraps"] := wraps
        }
    }
    oldUpdating := GetSpreadsheetProperty(app, "ScreenUpdating", true)
    oldEvents := GetSpreadsheetProperty(app, "EnableEvents", true)
    oldCalculation := GetSpreadsheetProperty(app, "Calculation", -4105)
    try {
        app.ScreenUpdating := false
        app.EnableEvents := false
        app.Calculation := -4135
        for plan in plans {
            plan["range"].Value2 := plan["values"]
            if (mode = "brackets")
                plan["range"].WrapText := false
        }
    } catch as err {
        try RestoreUndoAction(app, action)
        catch as rollbackError {
            PushUndoAction(action)
            throw Error(err.Message . "`n回滚失败，请使用面板撤销：" . rollbackError.Message)
        }
        throw err
    } finally {
        try app.Calculation := oldCalculation
        try app.EnableEvents := oldEvents
        try app.ScreenUpdating := oldUpdating
    }
    return action
}

WriteSpreadsheetDedupeResult(context, range, result) {
    app := context["app"]
    action := CreateUndoAction("去重整理", app, context["kind"])
    AddUndoRange(action, range)
    values := ComObjArray(12, range.Rows.Count, 1)
    Loop range.Rows.Count
        values[A_Index - 1, 0] := A_Index <= result.Length ? SpreadsheetLiteralText(result[A_Index]) : ""
    oldUpdating := GetSpreadsheetProperty(app, "ScreenUpdating", true)
    oldEvents := GetSpreadsheetProperty(app, "EnableEvents", true)
    oldCalculation := GetSpreadsheetProperty(app, "Calculation", -4105)
    try {
        app.ScreenUpdating := false
        app.EnableEvents := false
        app.Calculation := -4135
        range.Value2 := values
    } catch as err {
        try RestoreUndoAction(app, action)
        catch as rollbackError {
            PushUndoAction(action)
            throw Error(err.Message . "`n回滚失败，请使用面板撤销：" . rollbackError.Message)
        }
        throw err
    } finally {
        try app.Calculation := oldCalculation
        try app.EnableEvents := oldEvents
        try app.ScreenUpdating := oldUpdating
    }
    return action
}
