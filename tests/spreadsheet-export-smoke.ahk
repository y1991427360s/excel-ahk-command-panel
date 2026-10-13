#Requires AutoHotkey v2.0
#Include ../src/spreadsheet-export.ahk

GetSpreadsheetSelectionContext(title) {
    throw Error("独立测试不使用面板选区连接函数")
}

JoinLines(lines) {
    result := ""
    for line in lines
        result .= (A_Index > 1 ? "`r`n" : "") . line
    return result
}

AssertContains(text, expected) {
    if !InStr(text, expected)
        throw Error("报告缺少：" . expected)
}

app := ""
book := ""
try {
    kind := A_Args.Length ? A_Args[1] : "excel"
    app := ComObject(kind = "excel" ? "Excel.Application" : "Ket.Application")
    app.Visible := false
    app.DisplayAlerts := false
    book := app.Workbooks.Add()
    sheet := book.Worksheets(1)
    sheet.Range("A1:B1").Merge()
    sheet.Range("A1").Value := "合并标题"
    sheet.Range("A1").HorizontalAlignment := -4108
    sheet.Range("A1").Font.Name := "宋体"
    sheet.Range("A1").Font.Bold := true
    sheet.Range("A1").Interior.Color := 255
    sheet.Range("A2").Value := "项目"
    sheet.Range("B2").Value := "数量"
    sheet.Range("A3").Value := "电缆`n说明"
    sheet.Range("B3").Value := 12.5
    sheet.Range("B3").NumberFormat := "0.00"
    sheet.Range("A4").Value := "隐藏项目"
    sheet.Range("B4").Formula := "=1+2"
    sheet.Range("A5").Value := "可见项目"
    sheet.Range("B5").Value := 99
    sheet.Range("A2:B5").AutoFilter(1, "<>隐藏项目")
    context := Map("app", app, "selection", sheet.Range("A1:B5,D2"), "name", kind)
    report := BuildSpreadsheetSelectionReport(context)
    sample := FileOpen(A_Temp . "\spreadsheet-export-" . kind . "-sample.txt", "w", "UTF-8")
    sample.Write(report)
    sample.Close()
    for expected in ["合并=A1:B1", "居中", "宋体", "#FF0000", "电缆\n说明", "12.50", "公式=", "## 隐藏单元格", "隐藏项目", "第1列：条件1=", "D2 | 显示="]
        AssertContains(report, expected)
    if InStr(report, "C2 | 显示=")
        throw Error("读取了未选中的单元格")
    ; 条件格式颜色必须来自显示效果，不能仅读取基础颜色。
    try {
        rule := sheet.Range("B3").FormatConditions.Add(1, 5, "10")
        rule.Interior.Color := 65280
        app.Calculate()
        AssertContains(BuildSpreadsheetSelectionReport(context), "#00FF00")
    } catch as err {
        if (kind = "excel")
            throw err
        FileAppend("WPS 条件格式检查受限：" . err.Message . "`n", "*", "UTF-8")
    }
    wholeColumn := Map("app", app, "selection", sheet.Range("A:A"), "name", kind)
    AssertContains(BuildSpreadsheetSelectionReport(wholeColumn), "裁剪至 UsedRange")
    tooLarge := Map("app", app, "selection", sheet.Range("A1:Z1000"), "name", kind)
    rejected := false
    try BuildSpreadsheetSelectionReport(tooLarge)
    catch
        rejected := true
    if !rejected
        throw Error("大选区未被拒绝")
    tableSheet := book.Worksheets.Add()
    tableSheet.Range("A1").Value := "名称"
    tableSheet.Range("B1").Value := "数量"
    tableSheet.Range("A2").Value := "甲"
    tableSheet.Range("A3").Value := "乙"
    tableSheet.Range("A4").Value := "丙"
    tableSheet.Range("A5").Value := "丁"
    table := tableSheet.ListObjects.Add(1, tableSheet.Range("A1:B5"), , 1)
    criteria := ComObjArray(12, 3)
    criteria[0] := "甲"
    criteria[1] := "乙"
    criteria[2] := "丙"
    table.Range.AutoFilter(1, criteria, 7)
    tableReport := BuildSpreadsheetSelectionReport(Map("app", app, "selection", table.Range, "name", kind))
    AssertContains(tableReport, "结构化表数量=1")
    AssertContains(tableReport, '条件1=[')
    for expected in ["甲", "乙", "丙"]
        AssertContains(tableReport, expected)
    preview := ShowSpreadsheetReport(report)
    try {
        preview.Move(, , 720, 500)
        savedClipboard := ClipboardAll()
        try {
            CopySpreadsheetReport(report, preview["Button1"])
            if A_Clipboard != report
                throw Error("复制结果不一致")
        } finally A_Clipboard := savedClipboard
    } finally preview.Destroy()
    if sheet.Range("A1").Value != "合并标题" || !sheet.Range("A1").MergeCells
        throw Error("源单元格被修改")
    FileAppend(kind . "：导出验证通过`n", "*", "UTF-8")
} catch as err {
    FileAppend("失败：" . err.Message . "`n" . err.Stack . "`n", "**", "UTF-8")
    ExitApp(1)
} finally {
    if IsObject(book)
        try book.Close(false)
    if IsObject(app)
        try app.Quit()
}
ExitApp(0)
