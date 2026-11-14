#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off

; 拆分合并单元格并填充 —— 公式保护、横向合并列号、手动计算模式与撤销回归。
; 用法：AutoHotkey64.exe /ErrorStdOut tests\split-formula-smoke.ahk
; 会新建一个隐藏的 Excel 实例和临时工作簿，结束时不保存关闭，不连接已打开的工作簿。

global ExcelCommandUndoStack := []
global SplitFormulaFailures := []

SplitFormulaAssert(condition, message) {
    global SplitFormulaFailures
    if !condition
        SplitFormulaFailures.Push(message)
}

RunSplitFormulaSmoke() {
    global SplitFormulaFailures
    app := ""
    book := ""
    exitCode := 1
    try {
        app := ComObject("Excel.Application")
        app.Visible := false
        app.DisplayAlerts := false
        book := app.Workbooks.Add()
        sheet := book.Worksheets(1)
        app.Calculation := -4135 ; 手动计算：操作后必须保持

        ; A1:A3 纵向合并“X”；B1 常量、B2 未合并的公式；C1:D1 横向合并“M”；
        ; E1:E2 纵向合并且左上角是公式；F1 普通值；G1:G2 纵向合并“G”（检验横向合并之后的列号）。
        sheet.Range("A1").Value := "X"
        sheet.Range("A1:A3").Merge()
        sheet.Range("B1").Value := 5
        sheet.Range("B2").Formula := "=B1*2"
        sheet.Range("C1").Value := "M"
        sheet.Range("C1:D1").Merge()
        sheet.Range("E1").Formula := "=B1+1"
        sheet.Range("E1:E2").Merge()
        sheet.Range("F1").Value := "after"
        sheet.Range("G1").Value := "G"
        sheet.Range("G1:G2").Merge()
        sheet.Range("C2").Value := "c2"
        sheet.Calculate()

        context := Map("app", app, "selection", sheet.Range("A1:G3"), "name", "excel", "silent", true)
        action := SplitMergedSpreadsheetCellsAndFill(context)
        SplitFormulaAssert(IsObject(action), "拆分没有返回撤销记录")

        SplitFormulaAssert(sheet.Range("A1:G3").MergeCells == false, "拆分后仍有合并单元格")
        SplitFormulaAssert(sheet.Range("A2").Value = "X" && sheet.Range("A3").Value = "X", "A 列纵向合并未填充")
        SplitFormulaAssert(sheet.Range("B2").HasFormula, "未合并的公式单元格 B2 被写成了数值")
        SplitFormulaAssert(sheet.Range("B2").Formula = "=B1*2", "B2 公式被改动：" . sheet.Range("B2").Formula)
        SplitFormulaAssert(sheet.Range("C1").Value = "M" && sheet.Range("D1").Value = "M", "横向合并 C1:D1 未填充")
        SplitFormulaAssert(sheet.Range("C2").Value = "c2", "C2 普通单元格被改动")
        SplitFormulaAssert(sheet.Range("E1").HasFormula && sheet.Range("E1").Formula = "=B1+1", "合并块左上角公式 E1 丢失")
        SplitFormulaAssert(sheet.Range("E2").Value = 6, "E2 未填入 E1 的计算结果：" . sheet.Range("E2").Value)
        SplitFormulaAssert(sheet.Range("F1").Value = "after" && sheet.Range("F2").Value = "", "F 列被误填（横向合并后列号错位）")
        SplitFormulaAssert(sheet.Range("G2").Value = "G", "G1:G2 未填充（横向合并后列号错位）")
        SplitFormulaAssert(app.Calculation = -4135, "手动计算模式被改成了 " . app.Calculation)

        RestoreUndoAction(app, action)
        SplitFormulaAssert(sheet.Range("A1:A3").MergeCells == true, "撤销后 A1:A3 未恢复合并")
        SplitFormulaAssert(sheet.Range("C1:D1").MergeCells == true, "撤销后 C1:D1 未恢复合并")
        SplitFormulaAssert(sheet.Range("E1:E2").MergeCells == true, "撤销后 E1:E2 未恢复合并")
        SplitFormulaAssert(sheet.Range("E1").Formula = "=B1+1", "撤销后 E1 公式未恢复：" . sheet.Range("E1").Formula)
        SplitFormulaAssert(sheet.Range("G1:G2").MergeCells == true, "撤销后 G1:G2 未恢复合并")
        SplitFormulaAssert(sheet.Range("B2").Formula = "=B1*2", "撤销后 B2 公式被改动")
        SplitFormulaAssert(app.Calculation = -4135, "撤销后手动计算模式被改成了 " . app.Calculation)

        if SplitFormulaFailures.Length {
            text := "失败 " . SplitFormulaFailures.Length . " 项：`n"
            for message in SplitFormulaFailures
                text .= "  - " . message . "`n"
            FileAppend(text, "**", "UTF-8")
        } else {
            FileAppend("split-formula-smoke：全部通过`n", "*", "UTF-8")
            exitCode := 0
        }
    } catch as err {
        FileAppend("测试异常：" . err.Message . "`n" . err.Stack . "`n", "**", "UTF-8")
    } finally {
        if IsObject(book)
            try book.Close(false)
        if IsObject(app)
            try app.Quit()
    }
    return exitCode
}

ExitApp(RunSplitFormulaSmoke())

#Include ..\src
#Include excel-command-panel.ahk
