#Requires AutoHotkey v2.0
; 按内容比较单元格的标色工具：标出重复项、比较两列差异。只改底色，不改内容。

; 标出重复项：锁定选区内（单格时为所在整列）内容相同的单元格统一填黄色底。
HighlightSpreadsheetDuplicates() {
    title := "标出重复项"
    context := GetSpreadsheetSelectionContext(title)
    if !IsObject(context)
        return
    try {
        result := ApplySpreadsheetDuplicateHighlight(context)
        if (result["groups"] = 0)
            MsgBox(result["scope"] . " 中没有重复项。`n比较时忽略首尾空格，空白单元格不参与。", title)
        else
            PushUndoAction(result["action"])
    } catch as err {
        MsgBox("处理失败：" . err.Message, title, "Icon!")
    }
}

; 先批量读取值找出重复格并记录原底色，再分批填色；失败时回滚。
ApplySpreadsheetDuplicateHighlight(context, limit := 100000) {
    app := context["app"]
    selection := context["selection"]
    sheet := selection.Worksheet
    used := sheet.UsedRange
    target := selection.Cells.CountLarge = 1 ? selection.EntireColumn : selection
    scope := selection.Cells.CountLarge = 1
        ? GetExcelColumnName(selection.Column) . " 列"
        : "选区 " . selection.Address(false, false)

    areas := []
    total := 0
    for area in target.Areas {
        bounded := app.Intersect(area, used)
        if !IsObject(bounded)
            continue
        total += bounded.Cells.CountLarge
        if (total > limit)
            throw Error("选区使用区域超过 " . limit . " 格，请分批选择后处理。")
        areas.Push(bounded)
    }

    ; 键 → 单元格地址列表
    occurrences := Map()
    for entry in CollectSpreadsheetKeyedCells(areas) {
        if !occurrences.Has(entry["key"])
            occurrences[entry["key"]] := []
        occurrences[entry["key"]].Push(entry["address"])
    }

    addresses := []
    groups := 0
    for key, list in occurrences {
        if (list.Length < 2)
            continue
        groups += 1
        for address in list
            addresses.Push(address)
    }
    result := Map("groups", groups, "cells", addresses.Length, "scope", scope, "action", "")
    if (groups = 0)
        return result
    result["action"] := FillSpreadsheetCells(app, context["kind"], sheet, addresses, 0x00FFFF, "标出重复项")  ; BGR 黄色
    return result
}

; 批量读取各区域的值，返回 [{key, address}]，key 同时用作显示文字；合并区域只有左上角有值，
; 其余格读出为空自然跳过，地址换成整个合并区域。
CollectSpreadsheetKeyedCells(areas) {
    entries := []
    seen := Map()
    for area in areas {
        hasMerged := area.MergeCells != false
        rows := area.Rows.Count
        columns := area.Columns.Count
        top := area.Row
        left := area.Column
        values := area.Value2
        Loop rows {
            row := A_Index
            Loop columns {
                value := GetSpreadsheetMatrixValue(values, row, A_Index, rows, columns)
                key := SpreadsheetDuplicateKey(value)
                if (key = "")
                    continue
                address := GetExcelColumnName(left + A_Index - 1) . (top + row - 1)
                ; 不连续选区可能重叠，同一格只算一次。
                if seen.Has(address)
                    continue
                seen[address] := true
                if hasMerged {
                    cell := area.Worksheet.Range(address)
                    if cell.MergeCells
                        address := cell.MergeArea.Address(false, false)
                }
                entries.Push(Map("key", key, "address", address))
            }
        }
    }
    return entries
}

; 记录原底色后分批填色，返回撤销记录；失败时回滚。
FillSpreadsheetCells(app, provider, sheet, addresses, color, name) {
    batches := JoinSpreadsheetAddressBatches(addresses)
    action := CreateUndoAction(name, app, provider)
    action["items"].Push(CreateInteriorUndoItem(sheet, batches, addresses))
    oldUpdating := GetSpreadsheetProperty(app, "ScreenUpdating", true)
    try {
        try app.ScreenUpdating := false
        for batch in batches
            sheet.Range(batch).Interior.Color := color
    } catch as err {
        try RestoreUndoAction(app, action)
        catch as rollbackError {
            PushUndoAction(action)
            throw Error(err.Message . "`n回滚失败，请使用面板撤销：" . rollbackError.Message)
        }
        throw err
    } finally {
        try app.ScreenUpdating := oldUpdating
    }
    return action
}

; 比较两列差异：一列里有、另一列里找不到的单元格填浅红色底，并列出清单。
CompareSpreadsheetColumns() {
    title := "比较两列差异"
    context := GetSpreadsheetSelectionContext(title)
    if !IsObject(context)
        return
    try {
        result := ApplySpreadsheetColumnCompare(context)
    } catch as err {
        MsgBox("处理失败：" . err.Message, title, "Icon!")
        return
    }
    if IsObject(result["action"])
        PushUndoAction(result["action"])
    names := result["names"]
    text := FormatSpreadsheetCompareSide(names[1], names[2], result["onlyLeft"])
        . "`n`n" . FormatSpreadsheetCompareSide(names[2], names[1], result["onlyRight"])
    if IsObject(result["action"])
        text .= "`n`n以上单元格已填浅红色底，可撤销。"
    else
        text .= "`n`n两列内容一致（忽略顺序和首尾空格）。"
    MsgBox(text, title)
}

FormatSpreadsheetCompareSide(name, other, entries, limit := 30) {
    text := name . " 有、" . other . " 没有：" . entries.Length . " 个"
    for entry in entries {
        if (A_Index > limit) {
            text .= "`n  …… 其余 " . (entries.Length - limit) . " 个见表格标色"
            break
        }
        text .= "`n  " . entry["address"] . "  " . entry["key"]
    }
    return text
}

; 按集合比较：同一值在另一列出现过就算有，不管顺序和出现次数。
ApplySpreadsheetColumnCompare(context, limit := 200000) {
    app := context["app"]
    selection := context["selection"]
    sheet := selection.Worksheet
    pair := GetSpreadsheetComparePair(selection)
    used := sheet.UsedRange
    sides := []
    total := 0
    for column in pair {
        ; 只点了单元格或只选了一行时比较整列，否则只比较选中的行。
        if (column.Rows.Count = 1)
            column := column.EntireColumn
        bounded := app.Intersect(column, used)
        if IsObject(bounded) {
            total += bounded.Cells.CountLarge
            if (total > limit)
                throw Error("两列使用区域超过 " . limit . " 格，请分批选择后处理。")
        }
        sides.Push(IsObject(bounded) ? CollectSpreadsheetKeyedCells([bounded]) : [])
    }
    keys := [Map(), Map()]
    for index, entries in sides
        for entry in entries
            keys[index][entry["key"]] := true
    onlyLeft := []
    onlyRight := []
    for entry in sides[1]
        if !keys[2].Has(entry["key"])
            onlyLeft.Push(entry)
    for entry in sides[2]
        if !keys[1].Has(entry["key"])
            onlyRight.Push(entry)

    result := Map(
        "names", [GetExcelColumnName(pair[1].Column) . " 列", GetExcelColumnName(pair[2].Column) . " 列"],
        "onlyLeft", onlyLeft, "onlyRight", onlyRight, "action", "")
    addresses := []
    for entry in onlyLeft
        addresses.Push(entry["address"])
    for entry in onlyRight
        addresses.Push(entry["address"])
    if (addresses.Length)
        result["action"] := FillSpreadsheetCells(app, context["kind"], sheet, addresses, 0xCEC7FF, "比较两列差异")  ; BGR 浅红
    return result
}

; 支持：相邻两列一块选区、Ctrl 分别选两列、只选一列时自动配右侧相邻列。
GetSpreadsheetComparePair(selection) {
    areas := []
    for area in selection.Areas
        areas.Push(area)
    if (areas.Length = 1) {
        area := areas[1]
        if (area.Columns.Count = 1)
            return [area, area.Offset(0, 1)]
        if (area.Columns.Count = 2)
            return [area.Columns(1), area.Columns(2)]
    } else if (areas.Length = 2 && areas[1].Columns.Count = 1 && areas[2].Columns.Count = 1
        && areas[1].Column != areas[2].Column) {
        return areas[1].Column < areas[2].Column ? [areas[1], areas[2]] : [areas[2], areas[1]]
    }
    throw Error("请选中要比较的两列：选相邻两列，或按住 Ctrl 分别选两列；只选一列时与右侧相邻列比较。")
}

; 比较前去掉首尾空格；数字统一格式，避免 10 与 10.0 被当成不同内容。
SpreadsheetDuplicateKey(value) {
    if (Type(value) = "Float")
        return Format("{:.15g}", value)
    if (Type(value) != "String" && Type(value) != "Integer")
        return ""  ; 错误值等 COM 特殊值不参与比较
    return CleanCellText(value)
}

; Range() 的地址参数不能超过约 255 字符，逗号拼接后分批。
JoinSpreadsheetAddressBatches(addresses, maxLength := 240) {
    batches := []
    batch := ""
    for address in addresses {
        if (batch != "" && StrLen(batch) + 1 + StrLen(address) > maxLength) {
            batches.Push(batch)
            batch := ""
        }
        batch .= (batch = "" ? "" : ",") . address
    }
    if (batch != "")
        batches.Push(batch)
    return batches
}

; 整批无填充时只记一条，否则逐格记录原颜色与图案。
CreateInteriorUndoItem(sheet, batches, addresses) {
    states := []
    for batch in batches {
        colorIndex := ""
        try colorIndex := sheet.Range(batch).Interior.ColorIndex
        if (colorIndex = -4142) {
            states.Push(Map("address", batch, "none", true))
            continue
        }
        Loop Parse batch, "," {
            interior := sheet.Range(A_LoopField).Interior
            states.Push(Map(
                "address", A_LoopField,
                "none", interior.ColorIndex = -4142,
                "color", interior.Color,
                "pattern", interior.Pattern
            ))
        }
    }
    return Map(
        "kind", "interior",
        "workbook", sheet.Parent.FullName,
        "sheet", sheet.Name,
        "states", states
    )
}

RestoreInteriorUndoItem(ws, item) {
    for state in item["states"] {
        interior := ws.Range(state["address"]).Interior
        if state["none"] {
            interior.ColorIndex := -4142
            continue
        }
        try interior.Pattern := state["pattern"]
        interior.Color := state["color"]
    }
}
