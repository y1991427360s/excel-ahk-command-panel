; 只读导出：不选择、不写回、不保存源工作簿。
ExportSpreadsheetSelection() {
    context := GetSpreadsheetSelectionContext("导出选区信息")
    if !IsObject(context)
        return
    progress := Gui("+AlwaysOnTop", "导出选区信息")
    progress.AddText("w360", "正在读取单元格内容与格式，请稍候……")
    progress.Show("NoActivate")
    try report := BuildSpreadsheetSelectionReport(context)
    finally progress.Destroy()
    ShowSpreadsheetReport(report)
}

ShowSpreadsheetReport(report) {
    preview := Gui("+Resize +MinSize640x420", "选区信息：复制给 AI 或另存为文本")
    preview.SetFont("s10", "Microsoft YaHei UI")
    preview.AddText("xm w850", "文本保留坐标、内容、格式和表格状态。隐藏单元格单独列出；源表格不会修改。")
    edit := preview.AddEdit("xm y45 w850 h500 ReadOnly -Wrap HScroll", report)
    copy := preview.AddButton("xm y555 w160 h32", "复制给 AI")
    copy.OnEvent("Click", (*) => CopySpreadsheetReport(report, copy))
    save := preview.AddButton("x+12 w160 h32", "另存为文本…")
    save.OnEvent("Click", (*) => SaveSpreadsheetReport(report))
    preview.OnEvent("Size", (gui, state, width, height) => ResizeSpreadsheetReport(edit, copy, save, state, width, height))
    preview.OnEvent("Close", (*) => preview.Destroy())
    preview.OnEvent("Escape", (*) => preview.Destroy())
    preview.Show("w880 h605")
    return preview
}

ResizeSpreadsheetReport(edit, copy, save, state, width, height) {
    if (state = -1)
        return
    edit.Move(, , width - 30, height - 105)
    copy.Move(, height - 50)
    save.Move(, height - 50)
}

CopySpreadsheetReport(report, button) {
    A_Clipboard := report
    button.Text := "已复制，可粘贴给 AI"
}

SaveSpreadsheetReport(report) {
    destination := FileSelect("S16", A_MyDocuments . "\表格选区信息-" . FormatTime(A_Now, "yyyyMMdd-HHmmss") . ".txt", "保存选区信息", "文本文件 (*.txt)")
    if (destination = "")
        return
    if !RegExMatch(destination, "i)\.txt$") {
        destination .= ".txt"
        if FileExist(destination) && MsgBox("目标文件已存在，是否覆盖？", "保存选区信息", "YesNo Icon?") != "Yes"
            return
    }
    file := FileOpen(destination, "w", "UTF-8")
    if !IsObject(file)
        throw Error("无法写入文件：" . destination)
    try file.Write(report)
    finally file.Close()
}

BuildSpreadsheetSelectionReport(context) {
    app := context["app"]
    selection := context["selection"]
    sheet := selection.Parent
    areas := []
    total := 0
    clipped := false
    for area in selection.Areas {
        ; 整行/整列只读取已用区域交集，普通选区保留空白格。
        if (area.Rows.Count = sheet.Rows.Count || area.Columns.Count = sheet.Columns.Count) {
            clipped := true
            area := app.Intersect(area, sheet.UsedRange)
            if !IsObject(area)
                continue
        }
        total += area.Cells.Count
        areas.Push(area)
    }
    if (total > 10000)
        throw Error("选区包含 " . total . " 个单元格。详细格式导出最多支持 10000 格，请缩小选区后重试。")
    report := "# 表格选区信息`r`n"
        . "程序：" . context["name"] . "`r`n"
        . "工作簿：" . ExportQuote(sheet.Parent.Name) . "；工作表：" . ExportQuote(sheet.Name) . "`r`n"
        . "原选区：" . selection.Address(false, false) . "；读取格数：" . total . "`r`n"
        . "导出时间：" . FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") . "`r`n"
        . "说明：坐标为原表坐标；空白格也保留；字符串中 \n 表示换行，\t 表示制表符。合并格文字来自合并区域左上角。`r`n"
        . "隐藏行/列（包括筛选隐藏）不属于可见内容，单独列在后面。未选中的普通单元格不读取。`r`n"
        . "格式优先读取 DisplayFormat（含条件格式的显示效果），不支持时回退基础格式；无法读取的属性标记为【不可读取】。`r`n"
        . "范围限制：不包含图片、浮动图形、图表和批注；混合字体的局部字符样式不逐字符展开；筛选操作符使用 Excel 数值编码。`r`n"
    if clipped
        report .= "整行/整列选区已裁剪至 UsedRange，未导出其余空白区域。`r`n"
    report .= "`r`n## 工作表状态`r`n"
    for prop in ["AutoFilterMode", "FilterMode", "ProtectContents", "DisplayRightToLeft"]
        report .= prop . "=" . ExportRead(sheet, prop) . "`r`n"
    try {
        window := sheet.Parent.Windows(1)
        report .= "窗口=" . ExportQuote(window.Caption) . "（该工作簿第一个窗口）`r`n"
        for prop in ["FreezePanes", "SplitRow", "SplitColumn", "DisplayGridlines", "Zoom"]
            report .= prop . "=" . ExportRead(window, prop) . "`r`n"
    } catch
        report .= "窗口状态：【不可读取】`r`n"
    try report .= ExportAutoFilter(sheet.AutoFilter, "工作表筛选")
    catch
        report .= "工作表筛选范围：无或不可读取（以上状态属性为准）`r`n"
    try {
        report .= "结构化表数量=" . sheet.ListObjects.Count . "`r`n"
        for table in sheet.ListObjects {
            report .= "结构化表 " . ExportQuote(table.Name) . "：范围=" . table.Range.Address(false, false)
                . "；样式=" . ExportRead(table, "TableStyle") . "；显示筛选=" . ExportRead(table, "ShowAutoFilter") . "`r`n"
            try report .= ExportAutoFilter(table.AutoFilter, "表 " . table.Name . " 筛选")
            catch
                report .= "该表筛选详情：【不可读取】`r`n"
        }
    } catch
        report .= "结构化表状态：【不可读取】`r`n"

    formats := Map()
    formatLines := []
    cells := Map()
    rows := Map()
    columns := Map()
    visibleLines := []
    hiddenLines := []
    for area in areas {
        report .= "`r`n读取区域：" . area.Address(false, false) . "（" . area.Rows.Count . " 行 × " . area.Columns.Count . " 列）`r`n"
        for cell in area.Cells {
            address := cell.Address(false, false)
            if cells.Has(address)
                continue
            cells[address] := true
            row := cell.Row
            col := cell.Column
            if !rows.Has(row)
                rows[row] := "行 " . row . "：高度=" . ExportRead(cell.EntireRow, "RowHeight") . " 磅；隐藏=" . ExportRead(cell.EntireRow, "Hidden")
            if !columns.Has(col)
                columns[col] := "列 " . col . "：宽度=" . ExportRead(cell.EntireColumn, "ColumnWidth") . "；隐藏=" . ExportRead(cell.EntireColumn, "Hidden")
            source := cell
            mergeInfo := "未合并"
            if cell.MergeCells {
                merged := cell.MergeArea
                source := merged.Cells(1, 1)
                mergeInfo := "合并=" . merged.Address(false, false) . "；内容来源=" . source.Address(false, false)
            }
            style := ExportCellFormat(source)
            if !formats.Has(style) {
                id := "F" . (formats.Count + 1)
                formats[style] := id
                formatLines.Push(id . "：" . style)
            }
            line := address . " | 显示=" . ExportRead(source, "Text") . " | " . formats[style] . " | " . mergeInfo
            if source.HasFormula
                line .= " | 公式=" . ExportRead(source, "Formula")
            value := ExportRead(source, "Value2")
            if (value != ExportRead(source, "Text"))
                line .= " | 原始值=" . value
            if (cell.EntireRow.Hidden || cell.EntireColumn.Hidden)
                hiddenLines.Push(line)
            else
                visibleLines.Push(line)
        }
    }
    report .= "`r`n## 可见单元格（按选区顺序）`r`n" . JoinLines(visibleLines)
        . "`r`n`r`n## 隐藏单元格（未显示）`r`n" . (hiddenLines.Length ? JoinLines(hiddenLines) : "无")
        . "`r`n`r`n## 格式字典`r`n" . JoinLines(formatLines)
        . "`r`n`r`n## 行列设置`r`n"
    for _, line in rows
        report .= line . "`r`n"
    for _, line in columns
        report .= line . "`r`n"
    return report
}

ExportCellFormat(cell) {
    display := cell
    origin := "基础格式"
    try {
        display := cell.DisplayFormat
        displayFontName := display.Font.Name
        origin := "显示格式"
    }
    result := origin . "；"
    for prop in ["HorizontalAlignment", "VerticalAlignment", "WrapText", "ShrinkToFit", "Orientation", "IndentLevel", "NumberFormatLocal"]
        result .= prop . "=" . ExportRead(cell, prop) . "；"
    font := display.Font
    for prop in ["Name", "Size", "Bold", "Italic", "Underline", "Strikethrough"]
        result .= "字体." . prop . "=" . ExportRead(font, prop) . "；"
    result .= "字体颜色=" . ExportColor(font) . "；底色=" . ExportColor(display.Interior)
        . "；填充Pattern=" . ExportRead(display.Interior, "Pattern") . "；"
    for index, label in Map(7, "左", 8, "上", 9, "下", 10, "右", 5, "斜下", 6, "斜上") {
        try {
            border := display.Borders(index)
            lineStyle := border.LineStyle
            result .= label . "边框=" . lineStyle
            if (lineStyle != -4142)
                result .= "/粗细=" . ExportRead(border, "Weight") . "/颜色=" . ExportColor(border)
            result .= "；"
        } catch
            result .= label . "边框=【不可读取】；"
    }
    return result
}

ExportAutoFilter(filter, label) {
    text := label . "：范围=" . filter.Range.Address(false, false) . "`r`n"
    for item in filter.Filters {
        index := A_Index
        if item.On {
            text .= "  第" . index . "列：条件1=" . ExportRead(item, "Criteria1")
                . "；操作符=" . ExportRead(item, "Operator") . "；条件2=" . ExportRead(item, "Criteria2") . "`r`n"
        }
    }
    return text
}

ExportRead(object, property) {
    try {
        value := object.%property%
        if (property = "TableStyle" && IsObject(value))
            return ExportQuote(value.Name)
        if (property = "HorizontalAlignment")
            return ExportAlignment(value, false)
        if (property = "VerticalAlignment")
            return ExportAlignment(value, true)
        if InStr("|AutoFilterMode|FilterMode|ProtectContents|DisplayRightToLeft|FreezePanes|DisplayGridlines|ShowAutoFilter|Hidden|WrapText|ShrinkToFit|Bold|Italic|Strikethrough|", "|" . property . "|") && IsNumber(value)
            return value ? "是" : "否"
        return ExportQuote(value)
    } catch
        return "【不可读取】"
}

ExportAlignment(value, vertical) {
    names := Map(-4108, "居中", -4131, "左对齐", -4152, "右对齐", -4160, "顶端对齐", -4107, "底端对齐", 1, "常规", 5, "填充", 7, "跨列居中", -4130, "两端对齐", -4117, "分散对齐")
    return names.Has(value) ? names[value] : "编码 " . value
}

ExportColor(object) {
    try {
        color := object.Color
        if !IsNumber(color)
            return "【混合或空值】"
        color := Round(color)
        return Format("#{:02X}{:02X}{:02X}", color & 255, (color >> 8) & 255, (color >> 16) & 255)
    } catch
        return "【不可读取】"
}

ExportQuote(value) {
    if IsObject(value) {
        try {
            if (ComObjType(value) = 10)
                return "【错误值 " . ComObjValue(value) . "】"
            result := "["
            for entry in value
                result .= (A_Index > 1 ? ", " : "") . ExportQuote(entry)
            return result . "]"
        } catch
            return "【对象或混合值】"
    }
    value := StrReplace(value . "", "\", "\\")
    value := StrReplace(value, "`r`n", "\n")
    value := StrReplace(value, "`r", "\n")
    value := StrReplace(value, "`n", "\n")
    value := StrReplace(value, "`t", "\t")
    value := StrReplace(value, Chr(34), "\" . Chr(34))
    return Chr(34) . value . Chr(34)
}
