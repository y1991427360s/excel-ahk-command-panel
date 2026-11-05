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

; 只有会被 Excel/WPS 解释成公式、数字、日期、逻辑值或错误值的文字才加文本前缀符 '，
; 普通文字直接写入，避免编辑栏出现多余的 '。判断不到的情况由写入后的回读校验兜底。
NeedsSpreadsheetTextPrefix(text) {
    text := text . ""
    if (text = "")
        return false
    if InStr("=+-@'", SubStr(text, 1, 1))
        return true
    ; 中文环境下全角数字、符号同样会被识别，先折算为半角再判断。
    normalized := ""
    Loop Parse, text {
        code := Ord(A_LoopField)
        normalized .= code = 0x3000 ? " " : (code >= 0xFF01 && code <= 0xFF5E) ? Chr(code - 0xFEE0) : A_LoopField
    }
    if InStr("=+-@'", SubStr(normalized, 1, 1))
        return true
    trimmed := Trim(normalized, " `t")
    if (trimmed = "")
        return false
    if RegExMatch(trimmed, "i)^[0-9.,:/\-%$¥￥()e+ ]*[0-9][0-9.,:/\-%$¥￥()e+ ]*( ?[ap]m?)?$")
        return true
    if RegExMatch(trimmed, "i)^(true|false)$")
        return true
    if RegExMatch(trimmed, "i)^#(N/A|NULL!|DIV/0!|VALUE!|REF!|NAME\?|NUM!|SPILL!|CALC!|GETTING_DATA)$")
        return true
    if RegExMatch(trimmed, "^(\d{1,4}年\d{1,2}月(\d{1,2}日)?|\d{1,2}月\d{1,2}日|\d{1,2}时(\d{1,2}分(\d{1,2}秒)?)?)$")
        return true
    months := "(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sep(t(ember)?)?|oct(ober)?|nov(ember)?|dec(ember)?)"
    if RegExMatch(trimmed, "i)^(\d{1,4}[-/ ]" . months . "([-/ ]\d{1,4})?|" . months . "[-/ ]\d{1,4}([-/ ,]+\d{1,4})?)$")
        return true
    return false
}

; 以文本方式写入，避免处理结果被 Excel 解释成公式或数值。
SpreadsheetLiteralText(text) {
    return NeedsSpreadsheetTextPrefix(text) ? "'" . text : text
}

AppendSpreadsheetTextRun(plans, column, startRow, texts) {
    if (texts.Length = 0)
        return
    range := column.Cells(startRow, 1).Resize(texts.Length, 1)
    plans.Push(Map("range", range, "texts", texts))
}

; 批量写入一列文字；回读未加 ' 的格子，若被转成数字、日期等则改用 ' 重写该格。
WriteSpreadsheetTextColumn(range, texts) {
    count := texts.Length
    if (count = 1) {
        range.Value2 := SpreadsheetLiteralText(texts[1])
    } else {
        values := ComObjArray(12, count, 1)
        for index, text in texts
            values[index - 1, 0] := SpreadsheetLiteralText(text)
        range.Value2 := values
    }
    written := range.Value2
    for index, text in texts {
        if (text = "" || NeedsSpreadsheetTextPrefix(text))
            continue
        actual := GetSpreadsheetMatrixValue(written, index, 1, count, 1)
        if !(Type(actual) = "String" && actual == text)
            range.Cells(index, 1).Value2 := "'" . text
    }
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
                    plans.Push(Map("range", cell, "texts", [text]))
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
            WriteSpreadsheetTextColumn(plan["range"], plan["texts"])
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
    texts := []
    Loop range.Rows.Count
        texts.Push(A_Index <= result.Length ? result[A_Index] : "")
    oldUpdating := GetSpreadsheetProperty(app, "ScreenUpdating", true)
    oldEvents := GetSpreadsheetProperty(app, "EnableEvents", true)
    oldCalculation := GetSpreadsheetProperty(app, "Calculation", -4105)
    try {
        app.ScreenUpdating := false
        app.EnableEvents := false
        app.Calculation := -4135
        WriteSpreadsheetTextColumn(range, texts)
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
