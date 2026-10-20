global SnapshotTestApplication := ""
app := ""
book := ""
otherBook := ""
exitCode := 0
try {
    app := ComObject("Excel.Application")
    SnapshotTestApplication := app
    app.Visible := false
    app.DisplayAlerts := false
    book := app.Workbooks.Add()
    sheet := book.Worksheets(1)
    sheet.Range("B2:B4").Merge()
    sheet.Range("B2").Value2 := "原选区"
    otherBook := app.Workbooks.Add()
    otherSheet := otherBook.Worksheets(1)
    otherSheet.Range("D10").Value2 := "新选区不可修改"
    SetSnapshot(sheet, "B:B")
    otherSheet.Range("D10").Select()
    action := SplitMergedSpreadsheetCellsAndFill()
    SnapshotAssert(IsObject(action), "拆分必须使用原选区")
    SnapshotAssert(sheet.Range("B3").Value2 = "原选区", "原工作簿合并块填充")
    SnapshotAssert(!sheet.Range("B2:B4").MergeCells, "原工作簿合并块拆分")
    SnapshotAssert(otherSheet.Range("D10").Value2 = "新选区不可修改", "当前新选区不变")
    RestoreUndoAction(app, action)
    SnapshotAssert(sheet.Range("B2:B4").MergeCells, "原工作簿拆分撤销")
    sheet.Range("F2").Value2 := "名称（备注）"
    SetSnapshot(sheet, "F2")
    RemoveBracketTextFromExcelSelection()
    SnapshotAssert(sheet.Range("F2").Value2 = "名称", "删除括号使用原选区")
    sheet.Range("H2").Value2 := "4x4"
    sheet.Range("I2").Value2 := 40
    sheet.Range("H3").Value2 := "4x2.5"
    sheet.Range("I3").Value2 := 25
    SetSnapshot(sheet, "H2:I3")
    SortCableRowsByCrossSection()
    SnapshotAssert(sheet.Range("H2").Value2 = "4x2.5" && sheet.Range("I2").Value2 = 25, "电缆排序使用原选区并成对移动")
    SnapshotAssert(otherSheet.Range("D10").Value2 = "新选区不可修改", "所有操作均不改当前工作簿")
    FileAppend("PASS original workbook/column despite active selection changing; split, fill, undo, text cleanup and cable sorting`n", "*", "UTF-8")
} catch as err {
    FileAppend("FAIL: " . err.Message . "`n" . err.Stack . "`n", "*", "UTF-8")
    exitCode := 1
} finally {
    if IsObject(otherBook)
        try otherBook.Close(false)
    if IsObject(book)
        try book.Close(false)
    if IsObject(app)
        try app.Quit()
    SnapshotTestApplication := ""
}
ExitApp(exitCode)

SetSnapshot(sheet, address) {
    global AutomationSpreadsheetSelectionContext
    book := sheet.Parent
    AutomationSpreadsheetSelectionContext := Map("progId", "Excel.Application", "kind", "excel", "name", "Excel",
        "workbookFullName", book.FullName, "workbookName", book.Name,
        "worksheetName", sheet.Name, "selectionAddress", sheet.Range(address).Address)
}

SnapshotAssert(condition, message) {
    if !condition
        throw Error(message)
}

SnapshotTestMsgBox(text, title := "", options := "") {
    if InStr(options, "OKCancel")
        return "OK"
    throw Error("意外提示：" . text)
}
