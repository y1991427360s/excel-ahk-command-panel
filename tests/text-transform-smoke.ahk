; 生产函数 + 独立未保存工作簿，验证真实 COM 批量读写及故障恢复。
DetectHiddenWindows(true)
app := ""
book := ""
exitCode := 0
try {
    provider := A_Args.Length ? A_Args[1] : "excel"
    app := ComObject(provider = "excel" ? "Excel.Application" : "Ket.Application")
    FileAppend("TEST_APP_PID=" . WinGetPID("ahk_id " . app.Hwnd) . "`n", "*", "UTF-8")
    app.Visible := false
    app.DisplayAlerts := false
    book := app.Workbooks.Add()
    sheet := book.Worksheets(1)
    sheet.Range("A1").Value2 := "甲（备注）"
    sheet.Range("A1").WrapText := true
    sheet.Range("A2").Formula := "=1+2"
    sheet.Range("A4").Value2 := "乙"
    sheet.Range("A4").WrapText := true
    sheet.Range("A5").Value2 := "丙"
    sheet.Range("B1").Value2 := "不可修改"
    context := Map("app", app, "kind", provider, "selection", sheet.Range("A:A"))
    beforeEvents := app.EnableEvents
    beforeCalc := app.Calculation
    beforeUpdating := app.ScreenUpdating
    action := ApplySpreadsheetTextTransform(context, "prefix", "前")
    TextAssert(sheet.Range("A1").Value2 = "前甲（备注）", "整列裁剪并添加前缀")
    TextAssert(sheet.Range("A2").Formula = "=1+2" && sheet.Range("A3").Value2 = "", "公式和空白跳过")
    TextAssert(sheet.Range("A5").Value2 = "前丙" && sheet.Range("B1").Value2 = "不可修改", "连续块批量写回且不越界")
    TextAssert(action["items"].Length < 4, "撤销按连续块记录")
    RestoreUndoAction(app, action)
    TextAssert(sheet.Range("A1").Value2 = "甲（备注）" && sheet.Range("A5").Value2 = "丙", "文字撤销")
    context["selection"] := sheet.Range("A4")
    action := ApplySpreadsheetTextTransform(context, "suffix", "后")
    TextAssert(sheet.Range("A4").Value2 = "乙后" && sheet.Range("A1").Value2 = "甲（备注）", "单格SpecialCells不扩展选区")
    RestoreUndoAction(app, action)
    context["selection"] := sheet.Range("A1,A4")
    action := ApplySpreadsheetTextTransform(context, "prefix", "=")
    TextAssert(!sheet.Range("A1").HasFormula && sheet.Range("A1").Value2 = "=甲（备注）", "等号前缀保持文字")
    RestoreUndoAction(app, action)
    sheet.Range("A5").Value2 := 123
    context["selection"] := sheet.Range("A1:A5")
    action := ApplySpreadsheetTextTransform(context, "brackets")
    TextAssert(sheet.Range("A1").Value2 = "甲" && !sheet.Range("A1").WrapText, "括号清理")
    TextAssert(Type(sheet.Range("A5").Value2) != "String", "未变化数字保持原类型")
    RestoreUndoAction(app, action)
    sheet.Range("A5").Value2 := "丙"
    TextAssert(sheet.Range("A1").Value2 = "甲（备注）" && sheet.Range("A1").WrapText && sheet.Range("A4").WrapText, "括号撤销恢复内容和换行格式")
    context["selection"] := sheet.Range("A4:A5")
    action := ApplySpreadsheetTextTransform(context, "end", 1)
    TextAssert(sheet.Range("A4").Value2 = "" && sheet.Range("A5").Value2 = "", "删除全部字符")
    TextAssert(!IsObject(ApplySpreadsheetTextTransform(context, "prefix", "不可误填")), "删空后仍跳过空白")
    RestoreUndoAction(app, action)
    sheet.Range("D2:D4").Merge()
    sheet.Range("D2").Value2 := "合并"
    context["selection"] := sheet.Range("D2:D4")
    action := ApplySpreadsheetTextTransform(context, "suffix", "后")
    TextAssert(sheet.Range("D2").Value2 = "合并后" && sheet.Range("D2:D4").MergeCells, "合并块只处理一次")
    RestoreUndoAction(app, action)
    TextAssert(sheet.Range("D2").Value2 = "合并", "合并块撤销")
    context["selection"] := sheet.Range("A1:B6000")
    sheet.Range("B6000").Value2 := "边界"
    rejected := false
    try ApplySpreadsheetTextTransform(context, "prefix", "拒绝")
    catch
        rejected := true
    TextAssert(rejected && sheet.Range("A1").Value2 = "甲（备注）", "超过10000格写前拒绝")

    literalRange := sheet.Range("H1:H3")
    literalRange.Cells(1, 1).Value2 := "'=1+1"
    literalRange.Cells(2, 1).Value2 := "'00123"
    literalRange.Cells(3, 1).Formula := "=3+4"
    context["selection"] := literalRange
    action := ApplySpreadsheetTextTransform(context, "prefix", "前")
    RestoreUndoAction(app, action)
    TextAssert(!literalRange.Cells(1, 1).HasFormula && literalRange.Cells(1, 1).Value2 = "=1+1", "文字撤销保留等号文字")
    TextAssert(Type(literalRange.Cells(2, 1).Value2) = "String" && literalRange.Cells(2, 1).Value2 == "00123", "文字撤销保留前导零")
    action := WriteSpreadsheetDedupeResult(context, literalRange, ["替换"])
    RestoreUndoAction(app, action)
    TextAssert(!literalRange.Cells(1, 1).HasFormula && literalRange.Cells(1, 1).Value2 = "=1+1", "混合区域撤销保留等号常量")
    TextAssert(literalRange.Cells(2, 1).Value2 == "00123" && literalRange.Cells(3, 1).Formula = "=3+4", "混合区域撤销区分数字文字和真实公式")
    blankRange := sheet.Range("J1:J3")
    blankRange.Cells(1, 1).Value2 := "内容"
    action := WriteSpreadsheetDedupeResult(context, blankRange, ["结果"])
    RestoreUndoAction(app, action)
    TextAssert(app.WorksheetFunction.CountA(blankRange) = 1, "撤销不把真正空白变为非空文字")

    target := sheet.Range("F2:F5")
    target.Cells(1, 1).Formula := "=1+2"
    target.Cells(2, 1).Value2 := "原文"
    target.Cells(3, 1).Value2 := 7
    target.Cells(4, 1).Value2 := "尾部"
    action := WriteSpreadsheetDedupeResult(context, target, ["10kV", "110kV"])
    TextAssert(target.Cells(1, 1).Value2 = "10kV" && target.Cells(3, 1).Value2 = "", "去重批量写入并清空尾部")
    RestoreUndoAction(app, action)
    TextAssert(target.Cells(1, 1).Formula = "=1+2" && target.Cells(4, 1).Value2 = "尾部", "去重撤销还原公式和原值")
    target.Cells(1, 1).Value2 := "原始常量"
    failed := false
    try WriteSpreadsheetDedupeResult(context, FaultingDedupeRange(target), ["失败写入"])
    catch as err
        failed := InStr(err.Message, "测试写回故障") > 0
    TextAssert(failed && target.Cells(1, 1).Value2 = "原始常量", "写回中途失败自动回滚")
    failed := false
    stackBefore := ExcelCommandUndoStack.Length
    try WriteSpreadsheetDedupeResult(context, FaultingDedupeRange(target, true), ["回滚受阻"])
    catch as err
        failed := InStr(err.Message, "测试写回故障") > 0
    finally sheet.Unprotect()
    TextAssert(failed && ExcelCommandUndoStack.Length = stackBefore + 1, "回滚失败保留撤销快照")
    RestoreUndoAction(app, ExcelCommandUndoStack.Pop())
    TextAssert(target.Cells(1, 1).Value2 = "原始常量", "解除保护后可恢复保留快照")
    TextAssert(app.EnableEvents = beforeEvents && app.Calculation = beforeCalc && app.ScreenUpdating = beforeUpdating, "成功失败均恢复应用状态")
    FileAppend("PASS " . provider . ": batch text, formulas, blanks, selection bounds, literal text, merged cells, undo, dedupe and injected rollback failures`n", "*", "UTF-8")
} catch as err {
    FileAppend("FAIL: " . err.Message . " (line " . err.Line . ")`n" . err.Stack . "`n", "*", "UTF-8")
    exitCode := 1
} finally {
    if IsObject(book) {
        try book.Worksheets(1).Unprotect()
        try book.Close(false)
    }
    if IsObject(app)
        try app.Quit()
}
ExitApp(exitCode)

TextAssert(condition, message) {
    if !condition
        throw Error(message)
}

class FaultingDedupeRange {
    __New(actual, blockRollback := false) {
        this.actual := actual
        this.blockRollback := blockRollback
    }
    Worksheet => this.actual.Worksheet
    Rows => this.actual.Rows
    Columns => this.actual.Columns
    HasFormula => this.actual.HasFormula
    Application => this.actual.Application
    Row => this.actual.Row
    Column => this.actual.Column
    Formula => this.actual.Formula
    Address(args*) => this.actual.Address(args*)
    SpecialCells(args*) => this.actual.SpecialCells(args*)
    Value2 {
        get => this.actual.Value2
        set {
            this.actual.Cells(1, 1).Value2 := "故障注入的部分写入"
            if this.blockRollback
                this.actual.Worksheet.Protect()
            throw Error("测试写回故障")
        }
    }
}
