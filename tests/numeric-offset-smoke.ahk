; 使用 numeric-offset-smoke.ps1 载入生产函数，在独立工作簿验证。
DetectHiddenWindows(true)
app := ""
book := ""
exitCode := 0
try {
    provider := A_Args.Length ? A_Args[1] : "excel"
    FileAppend("Starting COM: " . provider . "`n", "*", "UTF-8")
    app := ComObject(provider = "excel" ? "Excel.Application" : "Ket.Application")
    FileAppend("COM connected`n", "*", "UTF-8")
    FileAppend("TEST_APP_PID=" . WinGetPID("ahk_id " . app.Hwnd) . "`n", "*", "UTF-8")
    app.Visible := false
    app.DisplayAlerts := false
    book := app.Workbooks.Add()
    sheet := book.Worksheets(1)
    ranges := ["B328:B331", "B332:B335", "B336:B337", "B338:B342", "B343:B347", "B348:B349"]
    for index, address in ranges {
        region := sheet.Range(address)
        region.Merge()
        region.Cells(1, 1).Value2 := index + 7
        region.NumberFormat := "0.00"
        region.HorizontalAlignment := -4108
    }
    context := Map("app", app, "kind", provider, "selection", sheet.Range("B328:B349"))
    oldEvents := app.EnableEvents
    oldUpdating := app.ScreenUpdating
    oldCalc := app.Calculation
    action := ApplySpreadsheetNumericOffset(context, -2)
    OffsetAssert(action["items"].Length = 6, "merged regions must be changed once")
    for index, address in ranges {
        region := sheet.Range(address)
        OffsetAssert(region.MergeCells && region.Cells(1, 1).Value2 = index + 5, "merged subtract")
        OffsetAssert(region.NumberFormat = "0.00" && region.HorizontalAlignment = -4108, "format retained")
    }
    OffsetAssert(app.EnableEvents = oldEvents && app.ScreenUpdating = oldUpdating && app.Calculation = oldCalc, "app state restored")
    RestoreUndoAction(app, action)
    for index, address in ranges
        OffsetAssert(sheet.Range(address).MergeCells && sheet.Range(address).Cells(1, 1).Value2 = index + 7, "undo merged values")

    ; 相交选区与重叠合并区域去重，同时支持小数。
    context["selection"] := sheet.Range("B329,B331,B333")
    action := ApplySpreadsheetNumericOffset(context, 0.5)
    OffsetAssert(action["items"].Length = 2, "partial merged region deduplication")
    OffsetAssert(sheet.Range("B328").Value2 = 8.5 && sheet.Range("B332").Value2 = 9.5, "decimal add")
    RestoreUndoAction(app, action)

    sheet.Range("D1").Value2 := -3
    sheet.Range("D2").Value2 := "text"
    sheet.Range("D3").Formula := "=1+2"
    sheet.Range("D4").NumberFormat := "yyyy-mm-dd"
    sheet.Range("D4").Value2 := 45000
    sheet.Range("D5").NumberFormat := "@"
    sheet.Range("D5").Value2 := "12"
    sheet.Range("D7").Value2 := 1.25
    sheet.Rows(7).Hidden := true
    sheet.Range("E1").Value2 := 99
    context["selection"] := sheet.Range("D:D")
    action := ApplySpreadsheetNumericOffset(context, 2)
    OffsetAssert(action["items"].Length = 2, "skip blanks text formulas dates")
    OffsetAssert(sheet.Range("D1").Value2 = -1 && sheet.Range("D7").Value2 = 3.25, "numbers including hidden rows")
    OffsetAssert(sheet.Range("D2").Value2 = "text" && sheet.Range("D3").Formula = "=1+2" && sheet.Range("D4").Value2 = 45000, "skipped unchanged")
    OffsetAssert(Type(sheet.Range("D5").Value2) = "String" && sheet.Range("E1").Value2 = 99, "text numbers and outside selection unchanged")
    RestoreUndoAction(app, action)
    OffsetAssert(sheet.Range("D1").Value2 = -3 && sheet.Range("D7").Value2 = 1.25 && sheet.Rows(7).Hidden, "undo ordinary cells")
    OffsetAssert(!IsObject(ApplySpreadsheetNumericOffset(context, 0)), "zero no-op")
    context["selection"] := sheet.Range("D2:D6")
    OffsetAssert(!IsObject(ApplySpreadsheetNumericOffset(context, 2)), "no eligible numbers no-op")
    FileAppend("PASS " . provider . ": merged numbers, decimals, partial/multiple selections, whole column, skipped cells, undo and formatting`n", "*", "UTF-8")
} catch as err {
    FileAppend("FAIL: " . err.Message . " (line " . err.Line . ")`n", "*", "UTF-8")
    exitCode := 1
} finally {
    if IsObject(book)
        try book.Close(false)
    if IsObject(app)
        try app.Quit()
}
ExitApp(exitCode)

OffsetAssert(condition, message) {
    if !condition
        throw Error(message)
}
