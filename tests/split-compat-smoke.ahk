app := ""
book := ""
exitCode := 0
try {
    app := ComObject("Excel.Application")
    app.Visible := false
    app.DisplayAlerts := false
    book := app.Workbooks.Add()
    sheet := book.Worksheets(1)
    for mode in ["pretty", "compact", "wrapped", "unavailable"] {
        CompatMode := mode
        sheet.Cells.Clear()
        sheet.Range("B328:B331").Merge()
        sheet.Range("B328").Value2 := "第一块"
        sheet.Range("B334:B337").Merge()
        sheet.Range("B334").Value2 := "第二块"
        sheet.Range("B332").Value2 := "普通行"
        sheet.Range("C328").Value2 := "邻列不变"
        context := Map("app", app, "selection", sheet.Range("B:B"), "kind", "excel", "silent", true)
        action := SplitMergedSpreadsheetCellsAndFill(context)
        if !IsObject(action) || action["items"].Length != 2
            throw Error(mode . ": 整列选区未识别出两个合并块")
        for address in ["B328", "B329", "B330", "B331"]
            if sheet.Range(address).Value2 != "第一块" || sheet.Range(address).MergeCells
                throw Error(mode . ": 第一块拆分或填充错误")
        for address in ["B334", "B335", "B336", "B337"]
            if sheet.Range(address).Value2 != "第二块" || sheet.Range(address).MergeCells
                throw Error(mode . ": 第二块拆分或填充错误")
        if sheet.Range("B332").Value2 != "普通行" || sheet.Range("C328").Value2 != "邻列不变"
            throw Error(mode . ": 普通行或邻列被改变")
        RestoreUndoAction(app, action)
        if !sheet.Range("B328:B331").MergeCells || !sheet.Range("B334:B337").MergeCells
            throw Error(mode . ": 撤销未恢复合并")
        if sheet.Range("B328").Value2 != "第一块" || sheet.Range("B334").Value2 != "第二块"
            throw Error(mode . ": 撤销未恢复原值")
        sheet.Cells.UnMerge()
        FileAppend("PASS " . mode . ": whole column, non-A1 origin, mixed rows, fill and undo`n", "*", "UTF-8")
    }
} catch as err {
    FileAppend("FAIL: " . err.Message . "`n" . err.Stack . "`n", "*", "UTF-8")
    exitCode := 1
} finally {
    if IsObject(book)
        try book.Close(false)
    if IsObject(app)
        try app.Quit()
}
ExitApp(exitCode)

CompatXml(xml) {
    global CompatMode
    if CompatMode = "compact"
        return RegExReplace(xml, ">\s*<", "><")
    if CompatMode = "wrapped"
        return StrReplace(RegExReplace(xml, ">\s*<", "><"), " ss:", "`n ss:")
    if CompatMode = "unavailable"
        return "<Workbook><Table><Row><Cell/></Row></Table></Workbook>"
    return xml
}
