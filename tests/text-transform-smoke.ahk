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

    ; 文本前缀符 ' 只在需要时添加：普通文字不带 '，会被误解析的结果仍以文字保存。
    TextAssert(!NeedsSpreadsheetTextPrefix("ZAN-KVVP2-22-2×4") && NeedsSpreadsheetTextPrefix("001") && NeedsSpreadsheetTextPrefix("1-2"), "前缀符判断")
    prefixRange := sheet.Range("S1:S6")
    prefixRange.Value2 := ComObjArrayFromList(["KVVP2-22-2×4", "'01", "'-2", "Jan", "'１２", "月"])
    context["selection"] := prefixRange
    action := ApplySpreadsheetTextTransform(context, "prefix", "ZAN-")
    TextAssert(prefixRange.Cells(1, 1).Value2 == "ZAN-KVVP2-22-2×4" && prefixRange.Cells(1, 1).PrefixCharacter = "", "普通文字不加前缀符")
    RestoreUndoAction(app, action)
    TextAssert(prefixRange.Cells(1, 1).Value2 == "KVVP2-22-2×4" && prefixRange.Cells(1, 1).PrefixCharacter = "", "撤销普通文字不加前缀符")
    action := ApplySpreadsheetTextTransform(context, "prefix", "0")
    TextAssert(Type(prefixRange.Cells(2, 1).Value2) = "String" && prefixRange.Cells(2, 1).Value2 == "001", "数字样结果保持文字")
    RestoreUndoAction(app, action)
    action := ApplySpreadsheetTextTransform(context, "prefix", "1")
    TextAssert(prefixRange.Cells(3, 1).Value2 == "1-2" && prefixRange.Cells(4, 1).Value2 == "1Jan" && Type(prefixRange.Cells(5, 1).Value2) = "String", "日期样结果保持文字")
    RestoreUndoAction(app, action)
    action := ApplySpreadsheetTextTransform(context, "suffix", "-5")
    TextAssert(Type(prefixRange.Cells(4, 1).Value2) = "String" && prefixRange.Cells(4, 1).Value2 == "Jan-5", "英文月份日期保持文字")
    TextAssert(Type(prefixRange.Cells(5, 1).Value2) = "String" && prefixRange.Cells(5, 1).Value2 == "１２-5", "回读校验兜底")
    RestoreUndoAction(app, action)
    TextAssert(prefixRange.Cells(2, 1).Value2 == "01" && prefixRange.Cells(3, 1).Value2 == "-2", "撤销保留数字样文字")

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

    ; 标出重复项：忽略首尾空格，数字与数字文字视为相同，撤销还原原底色。
    dup := sheet.Range("L1:L6")
    dup.Cells(1, 1).Value2 := "甲"
    dup.Cells(2, 1).Value2 := "乙"
    dup.Cells(3, 1).Value2 := " 甲 "
    dup.Cells(4, 1).Value2 := 10
    dup.Cells(5, 1).Value2 := "10"
    dup.Cells(3, 1).Interior.Color := 0x0000FF
    context["selection"] := dup
    result := ApplySpreadsheetDuplicateHighlight(context)
    TextAssert(result["groups"] = 2 && result["cells"] = 4, "重复项分组与格数")
    TextAssert(dup.Cells(1, 1).Interior.Color = 0x00FFFF && dup.Cells(5, 1).Interior.Color = 0x00FFFF, "重复项标黄")
    TextAssert(dup.Cells(2, 1).Interior.ColorIndex = -4142 && dup.Cells(6, 1).Interior.ColorIndex = -4142, "唯一值和空白不标色")
    RestoreUndoAction(app, result["action"])
    TextAssert(dup.Cells(1, 1).Interior.ColorIndex = -4142 && dup.Cells(3, 1).Interior.Color = 0x0000FF, "撤销还原无填充和原底色")
    context["selection"] := sheet.Range("L2")
    result := ApplySpreadsheetDuplicateHighlight(context)
    TextAssert(result["groups"] = 2 && result["scope"] = "L 列", "单格时比较整列")
    RestoreUndoAction(app, result["action"])
    sheet.Range("N1:N2").Merge()
    sheet.Range("N1").Value2 := "合"
    sheet.Range("N3").Value2 := "合"
    sheet.Range("N4").Value2 := "独"
    context["selection"] := sheet.Range("N1:N4")
    result := ApplySpreadsheetDuplicateHighlight(context)
    TextAssert(sheet.Range("N2").Interior.Color = 0x00FFFF && sheet.Range("N3").Interior.Color = 0x00FFFF, "合并区域整体标黄")
    RestoreUndoAction(app, result["action"])
    TextAssert(sheet.Range("N2").Interior.ColorIndex = -4142, "合并区域撤销")
    context["selection"] := sheet.Range("N3:N4")
    TextAssert(ApplySpreadsheetDuplicateHighlight(context)["groups"] = 0, "无重复时不修改")

    ; 比较两列差异：按集合比较，忽略顺序与首尾空格，两侧各自标出对方没有的值。
    sheet.Range("P1:P3").Value2 := ComObjArrayFromList(["甲", "乙", 10])
    sheet.Range("Q1:Q4").Value2 := ComObjArrayFromList(["10", " 甲", "丙", "丁"])
    sheet.Range("Q3").Interior.Color := 0x0000FF
    context["selection"] := sheet.Range("P1")
    result := ApplySpreadsheetColumnCompare(context)
    TextAssert(result["names"][2] = "Q 列", "只选一列时配右侧相邻列")
    TextAssert(result["onlyLeft"].Length = 1 && result["onlyLeft"][1]["address"] = "P2", "左列独有项")
    TextAssert(result["onlyRight"].Length = 2 && result["onlyRight"][2]["key"] = "丁", "右列独有项")
    TextAssert(sheet.Range("P2").Interior.Color = 0xCEC7FF && sheet.Range("Q3").Interior.Color = 0xCEC7FF, "差异标浅红")
    TextAssert(sheet.Range("P1").Interior.ColorIndex = -4142 && sheet.Range("Q2").Interior.ColorIndex = -4142, "相同项不标色")
    RestoreUndoAction(app, result["action"])
    TextAssert(sheet.Range("P2").Interior.ColorIndex = -4142 && sheet.Range("Q3").Interior.Color = 0x0000FF, "差异撤销还原底色")
    context["selection"] := sheet.Range("Q1:Q4,P1:P3")
    result := ApplySpreadsheetColumnCompare(context)
    TextAssert(result["names"][1] = "P 列" && result["onlyLeft"].Length = 1, "Ctrl 选两列按左右顺序比较")
    RestoreUndoAction(app, result["action"])
    context["selection"] := sheet.Range("P1:Q2")
    result := ApplySpreadsheetColumnCompare(context)
    TextAssert(result["onlyLeft"].Length = 1 && result["onlyLeft"][1]["key"] = "乙" && result["onlyRight"][1]["key"] = "10", "多行选区只比较选中行")
    RestoreUndoAction(app, result["action"])
    context["selection"] := sheet.Range("P1:R1")
    rejected := false
    try ApplySpreadsheetColumnCompare(context)
    catch
        rejected := true
    TextAssert(rejected, "超过两列拒绝")
    FileAppend("PASS " . provider . ": batch text, formulas, blanks, selection bounds, literal text, merged cells, undo, dedupe, duplicate highlight, column compare and injected rollback failures`n", "*", "UTF-8")
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

ComObjArrayFromList(list) {
    values := ComObjArray(12, list.Length, 1)
    for index, value in list
        values[index - 1, 0] := value
    return values
}

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
