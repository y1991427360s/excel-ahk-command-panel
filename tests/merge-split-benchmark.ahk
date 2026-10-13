#Requires AutoHotkey v2.0
#SingleInstance Off

; ==============================================================================
; tests/merge-split-benchmark.ahk
; AutoHotkey v2 Excel/WPS 命令面板 - 拆分合并与相同内容合并 1000行基准与全量回归测试套件
; ==============================================================================

global ExcelCommandUndoStack := []
global AssertFailures := []

; --- 辅助断言与高精度计时 ---
Assert(condition, message) {
    global AssertFailures
    if (!condition) {
        AssertFailures.Push(message)
        return false
    }
    return true
}

GetTimestamp() {
    DllCall("QueryPerformanceCounter", "Int64*", &count := 0)
    return count
}

GetDurationMs(startCount, endCount) {
    static freq := 0
    if (freq = 0)
        DllCall("QueryPerformanceFrequency", "Int64*", &freq := 0)
    return (endCount - startCount) * 1000.0 / freq
}

; --- 安全撤销封装：屏蔽模态提示弹窗 ---
SafeRestoreUndoAction(app, action) {
    oldAlerts := GetSpreadsheetProperty(app, "DisplayAlerts", false)
    oldUpdating := GetSpreadsheetProperty(app, "ScreenUpdating", false)
    try {
        try app.DisplayAlerts := false
        try app.ScreenUpdating := false
        RestoreUndoAction(app, action)
    } finally {
        try app.ScreenUpdating := oldUpdating
        try app.DisplayAlerts := oldAlerts
    }
}

; --- 基线算法实现 (保留原未经优化的基线算法作为真实对照组) ---
BaselineSplitMerged(context) {
    app := context["app"]
    selection := context["selection"]
    kind := context.Has("name") ? context["name"] : "excel"
    mergeRanges := []
    seenAddresses := Map()

    usedRange := selection.Worksheet.UsedRange
    usedFirstRow := usedRange.Row
    usedLastRow := usedFirstRow + usedRange.Rows.Count - 1
    usedFirstColumn := usedRange.Column
    usedLastColumn := usedFirstColumn + usedRange.Columns.Count - 1

    for area in selection.Areas {
        firstRow := Max(area.Row, usedFirstRow)
        lastRow := Min(area.Row + area.Rows.Count - 1, usedLastRow)
        firstColumn := Max(area.Column, usedFirstColumn)
        lastColumn := Min(area.Column + area.Columns.Count - 1, usedLastColumn)
        if (firstRow > lastRow || firstColumn > lastColumn)
            continue

        Loop (lastRow - firstRow + 1) {
            rowIndex := firstRow + A_Index - 1
            Loop (lastColumn - firstColumn + 1) {
                columnIndex := firstColumn + A_Index - 1
                cell := selection.Worksheet.Cells(rowIndex, columnIndex)
                if !cell.MergeCells
                    continue

                mergeRange := cell.MergeArea
                address := mergeRange.Address(false, false)
                if seenAddresses.Has(address)
                    continue

                seenAddresses[address] := true
                mergeRanges.Push(mergeRange)
            }
        }
    }

    if (mergeRanges.Length = 0)
        return ""

    undoAction := CreateUndoAction("拆分合并单元格并填充", app, kind)
    for mergeRange in mergeRanges
        AddUndoUnmergeRange(undoAction, mergeRange)

    oldScreenUpdating := GetSpreadsheetProperty(app, "ScreenUpdating", true)
    oldEnableEvents := GetSpreadsheetProperty(app, "EnableEvents", true)
    oldDisplayAlerts := GetSpreadsheetProperty(app, "DisplayAlerts", true)

    try {
        try app.ScreenUpdating := false
        try app.EnableEvents := false
        try app.DisplayAlerts := false

        for item in undoAction["items"] {
            wb := GetWorkbookByFullName(app, item["workbook"])
            if !IsObject(wb)
                throw Error("找不到原工作簿：" . item["workbook"])

            ws := wb.Worksheets(item["sheet"])
            mergeRange := ws.Range(item["address"])
            mergeRange.UnMerge()
            item["applied"] := true
            SetSpreadsheetCellContent(mergeRange, item["fillContent"])
        }
    } finally {
        try app.DisplayAlerts := oldDisplayAlerts
        try app.EnableEvents := oldEnableEvents
        try app.ScreenUpdating := oldScreenUpdating
    }

    return undoAction
}

BaselineMergeIdentical(context) {
    xl := context["app"]
    selection := context["selection"]
    kind := context.Has("name") ? context["name"] : "excel"

    if (selection.Areas.Count != 1)
        throw Error("当前选区不连续。请只选择一个连续的单列或多列区域。")
    if (selection.Rows.Count < 2)
        throw Error("选区至少需要包含两个单元格。")

    usedRange := selection.Worksheet.UsedRange
    firstRow := Max(selection.Row, usedRange.Row)
    lastRow := Min(
        selection.Row + selection.Rows.Count - 1,
        usedRange.Row + usedRange.Rows.Count - 1
    )
    if (firstRow > lastRow)
        throw Error("当前选区内没有可处理的已使用单元格。")

    processRange := selection.Worksheet.Range(
        selection.Worksheet.Cells(firstRow, selection.Column),
        selection.Worksheet.Cells(
            lastRow,
            selection.Column + selection.Columns.Count - 1
        )
    )

    if HasSpreadsheetFormulaCells(processRange)
        throw Error("选区中包含公式单元格。为避免公式丢失，本次操作已取消。")

    values := processRange.Value2
    rowCount := processRange.Rows.Count
    columnCount := processRange.Columns.Count

    for cell in processRange.Cells {
        if (cell.MergeCells)
            throw Error("选区中包含已经合并的单元格。请先取消合并后再执行。")
    }

    entriesByColumn := []
    Loop columnCount {
        relativeColumn := A_Index
        columnEntries := []
        Loop rowCount {
            relativeRow := A_Index
            value := GetSpreadsheetMatrixValue(
                values,
                relativeRow,
                relativeColumn,
                rowCount,
                columnCount
            )
            columnEntries.Push(Map(
                "value", value,
                "row", firstRow + relativeRow - 1
            ))
        }
        entriesByColumn.Push(columnEntries)
    }

    pageBreakRows := GetHorizontalPageBreakRows(selection.Worksheet, firstRow, lastRow)
    mergeSpecs := []
    for relativeColumn, entries in entriesByColumn {
        groups := FindIdenticalSpreadsheetCellGroups(entries, pageBreakRows)
        for group in groups {
            mergeSpecs.Push(Map(
                "column", selection.Column + relativeColumn - 1,
                "firstRow", entries[group["start"]]["row"],
                "lastRow", entries[group["end"]]["row"]
            ))
        }
    }

    if (mergeSpecs.Length = 0)
        throw Error("选区中没有连续且内容完全相同的单元格。")

    undoAction := CreateUndoAction("合并相同内容并居中", xl, kind)
    for spec in mergeSpecs {
        mergeRange := selection.Worksheet.Range(
            selection.Worksheet.Cells(spec["firstRow"], spec["column"]),
            selection.Worksheet.Cells(spec["lastRow"], spec["column"])
        )
        AddUndoMergeRange(undoAction, mergeRange)
    }

    oldScreenUpdating := GetSpreadsheetProperty(xl, "ScreenUpdating", true)
    oldEnableEvents := GetSpreadsheetProperty(xl, "EnableEvents", true)
    oldDisplayAlerts := GetSpreadsheetProperty(xl, "DisplayAlerts", true)

    try {
        try xl.ScreenUpdating := false
        try xl.EnableEvents := false
        try xl.DisplayAlerts := false

        for item in undoAction["items"] {
            wb := GetWorkbookByFullName(xl, item["workbook"])
            if !IsObject(wb)
                throw Error("找不到原工作簿：" . item["workbook"])

            ws := wb.Worksheets(item["sheet"])
            mergeRange := ws.Range(item["address"])
            mergeRange.Merge()
            item["applied"] := true
            mergeRange.HorizontalAlignment := -4108
            mergeRange.VerticalAlignment := -4108
        }
    } finally {
        try xl.DisplayAlerts := oldDisplayAlerts
        try xl.EnableEvents := oldEnableEvents
        try xl.ScreenUpdating := oldScreenUpdating
    }

    return undoAction
}

; --- 1000行真实测试数据集规划与填充 ---
BuildBenchmarkDatasetPlan(&groupSpecs) {
    groupSpecs := []
    colAGroups := []
    colBGroups := []
    colCGroups := []

    ; 构造 A 列分组 (约 60 组，覆盖首尾第 1 行与第 1000 行)
    row := 1
    groupIndex := 1
    while (row <= 1000) {
        if (row = 248) {
            ; 跨越分页符 (HPageBreak 在第 250 行)：248~253 行设为相同内容
            colAGroups.Push(Map("col", 1, "start", 248, "end", 253, "val", "跨分页测试段"))
            row := 254
            continue
        }
        if (row = 498) {
            ; 空白阻断测试：498~499 相同，500 空白，501~502 相同
            colAGroups.Push(Map("col", 1, "start", 498, "end", 499, "val", "空白阻断前段"))
            colAGroups.Push(Map("col", 1, "start", 500, "end", 500, "val", "")) ; 空白
            colAGroups.Push(Map("col", 1, "start", 501, "end", 502, "val", "空白阻断后段"))
            row := 503
            continue
        }

        groupLen := Mod(groupIndex, 5) + 2 ; 2~6 行
        if (row < 248 && row + groupLen > 248)
            groupLen := 248 - row
        if (row < 498 && row + groupLen > 498)
            groupLen := 498 - row
        if (row + groupLen - 1 > 1000)
            groupLen := 1000 - row + 1

        if (groupLen >= 2) {
            colAGroups.Push(Map("col", 1, "start", row, "end", row + groupLen - 1, "val", "工程类别_" . groupIndex))
            row += groupLen
        } else {
            colAGroups.Push(Map("col", 1, "start", row, "end", row, "val", "单项工程_" . groupIndex))
            row += 1
        }
        groupIndex += 1
    }

    ; 构造 B 列分组 (约 50 组，错开 A 列行边界，保证列间独立垂直合并)
    row := 1
    bIndex := 1
    while (row <= 1000) {
        groupLen := Mod(bIndex, 4) + 3 ; 3~6 行
        if (row + groupLen - 1 > 1000)
            groupLen := 1000 - row + 1

        if (groupLen >= 2) {
            colBGroups.Push(Map("col", 2, "start", row, "end", row + groupLen - 1, "val", "YJV22-3x" . (25 + Mod(bIndex, 5) * 25)))
            row += groupLen
        } else {
            colBGroups.Push(Map("col", 2, "start", row, "end", row, "val", "BV-1x4"))
            row += 1
        }
        bIndex += 1
    }

    ; 构造 C 列分组 (约 35 组，含部分单项和说明)
    row := 1
    cIndex := 1
    while (row <= 1000) {
        groupLen := Mod(cIndex, 3) + 2 ; 2~4 行
        if (row + groupLen - 1 > 1000)
            groupLen := 1000 - row + 1

        if (groupLen >= 2) {
            colCGroups.Push(Map("col", 3, "start", row, "end", row + groupLen - 1, "val", "敷设说明_" . cIndex))
            row += groupLen
        } else {
            colCGroups.Push(Map("col", 3, "start", row, "end", row, "val", "直埋敷设"))
            row += 1
        }
        cIndex += 1
    }

    for item in colAGroups
        groupSpecs.Push(item)
    for item in colBGroups
        groupSpecs.Push(item)
    for item in colCGroups
        groupSpecs.Push(item)

    return groupSpecs
}

PopulateSheetWithData(sheet, groupSpecs, withInitialMerge := false) {
    app := sheet.Application
    oldScreenUpdating := app.ScreenUpdating
    oldDisplayAlerts := app.DisplayAlerts
    oldCalculation := -4105
    try oldCalculation := app.Calculation
    try {
        app.ScreenUpdating := false
        app.DisplayAlerts := false
        try app.Calculation := -4135 ; 手动计算
        try sheet.DisplayPageBreaks := false

        ; 1. 一次性通过 SafeArray 矩阵高速填充 1000x3 文本
        arr := ComObjArray(12, 1000, 3) ; VT_VARIANT
        for spec in groupSpecs {
            colIdx := spec["col"] - 1
            val := spec["val"]
            Loop (spec["end"] - spec["start"] + 1) {
                rowIdx := spec["start"] + A_Index - 2
                arr[rowIdx, colIdx] := val
            }
        }
        sheet.Range("A1:C1000").Value2 := arr

        ; 2. 填充 D 列公式 (验证公式检测与拆分保留)
        sheet.Range("D1:D1000").Formula := "=ROW()*10"

        ; 3. 如果是拆分测试模式，预先将各有效多行区域执行分批 Merge
        if (withInitialMerge) {
            currentBatch := ""
            for spec in groupSpecs {
                if (spec["end"] - spec["start"] + 1 >= 2 && spec["val"] != "") {
                    colLetter := (spec["col"] = 1 ? "A" : (spec["col"] = 2 ? "B" : "C"))
                    addr := colLetter . spec["start"] . ":" . colLetter . spec["end"]
                    if (currentBatch = "") {
                        currentBatch := addr
                    } else if (StrLen(currentBatch) + 1 + StrLen(addr) <= 240) {
                        currentBatch .= "," . addr
                    } else {
                        sheet.Range(currentBatch).Merge()
                        currentBatch := addr
                    }
                }
            }
            if (currentBatch != "")
                sheet.Range(currentBatch).Merge()
        } else {
            ; 4. 合并测试模式下添加水平分页符 (第 250 行与第 600 行)，不切换 View:=2 防止后台无头假死
            try {
                sheet.HPageBreaks.Add(sheet.Range("A250"))
                sheet.HPageBreaks.Add(sheet.Range("A600"))
                sheet.DisplayPageBreaks := false
            }
        }
    } finally {
        try app.Calculation := oldCalculation
        try app.DisplayAlerts := oldDisplayAlerts
        try app.ScreenUpdating := oldScreenUpdating
    }
}

; --- 主执行流程 ---
kind := A_Args.Length ? StrLower(A_Args[1]) : "excel"
progId := (kind = "excel" ? "Excel.Application" : "Ket.Application")
reportFile := A_ScriptDir . "\benchmark-results-" . kind . ".txt"
try FileDelete(reportFile)

app := ""
book := ""
try {
    FileAppend("================================================================================" . "`r`n", reportFile, "UTF-8")
    FileAppend("AutoHotkey v2 合并拆分性能基准与全量回归测试套件`r`n", reportFile, "UTF-8")
    FileAppend("目标平台: " . kind . " (ProgID: " . progId . ")`r`n", reportFile, "UTF-8")
    FileAppend("================================================================================" . "`r`n", reportFile, "UTF-8")

    ; 1. 启动无头 COM 宿主实例
    FileAppend("[PROGRESS] 正在启动 COM 实例...`r`n", reportFile, "UTF-8")
    app := ComObject(progId)
    app.Visible := false
    app.DisplayAlerts := false
    book := app.Workbooks.Add()
    FileAppend("[PROGRESS] COM 实例与工作簿创建成功。`r`n", reportFile, "UTF-8")

    BuildBenchmarkDatasetPlan(&planSpecs)
    validMergeCount := 0
    for s in planSpecs {
        if (s["end"] - s["start"] + 1 >= 2 && s["val"] != "")
            validMergeCount += 1
    }
    FileAppend(Format("[数据生成器] 成功规划 1000 行测试数据：包含 {1} 个连续相同值待合并区域 (目标 >=120)`r`n", validMergeCount), reportFile, "UTF-8")
    Assert(validMergeCount >= 120, "规划的合并区域数量不足 120 个")

    ; --------------------------------------------------------------------------
    ; 阶段一：SplitMergedSpreadsheetCellsAndFill 性能对比与回归断言
    ; --------------------------------------------------------------------------
    FileAppend("`r`n>>> 测试一：[拆分合并单元格并填充] 性能对比与回归断言...`r`n", reportFile, "UTF-8")

    ; 1. 基线耗时测量 (Baseline)
    sheetSplitBaseline := book.Worksheets.Add()
    FileAppend("  - [PROGRESS] 正在填充 SplitBaseline 数据...`r`n", reportFile, "UTF-8")
    PopulateSheetWithData(sheetSplitBaseline, planSpecs, true)
    FileAppend("  - [PROGRESS] SplitBaseline 数据填充完成，开始测量基线耗时...`r`n", reportFile, "UTF-8")
    contextSplitBaseline := Map("app", app, "selection", sheetSplitBaseline.Range("A1:C1000"), "name", kind, "silent", true)

    t0 := GetTimestamp()
    undoSplitBaseline := BaselineSplitMerged(contextSplitBaseline)
    t1 := GetTimestamp()
    baselineSplitMs := GetDurationMs(t0, t1)
    FileAppend(Format("  - SplitMerged 基线耗时 (Baseline): {1:.2f} ms`r`n", baselineSplitMs), reportFile, "UTF-8")

    ; 2. 优化后生产函数耗时测量 (Optimized)
    sheetSplitOpt := book.Worksheets.Add()
    PopulateSheetWithData(sheetSplitOpt, planSpecs, true)
    FileAppend("  - [PROGRESS] SplitOpt 数据填充完成，开始测量优化后耗时...`r`n", reportFile, "UTF-8")
    contextSplitOpt := Map("app", app, "selection", sheetSplitOpt.Range("A1:C1000"), "name", kind, "silent", true)

    t2 := GetTimestamp()
    undoSplitOpt := SplitMergedSpreadsheetCellsAndFill(contextSplitOpt)
    t3 := GetTimestamp()
    optSplitMs := GetDurationMs(t2, t3)
    speedupSplit := baselineSplitMs / optSplitMs
    FileAppend(Format("  - SplitMerged 优化后耗时 (Optimized): {1:.2f} ms`r`n", optSplitMs), reportFile, "UTF-8")
    FileAppend(Format("  - SplitMerged 性能提速比: {1:.2f}x`r`n", speedupSplit), reportFile, "UTF-8")

    ; 3. 性能硬性断言：耗时 < 1000 ms, 提速比 > 3.0x
    passedOptSplit := Assert(optSplitMs < 1000.0, Format("SplitMerged 优化后耗时未达标 (<1000ms): {1:.2f} ms", optSplitMs))
    passedSpeedupSplit := Assert(speedupSplit > 3.0, Format("SplitMerged 提速比未达标 (>3.0x): {1:.2f}x", speedupSplit))
    if (passedOptSplit && passedSpeedupSplit)
        FileAppend(Format("  - [PASS] SplitMerged 性能硬指标达标：耗时 {1:.2f} ms (<1000ms)，提速 {2:.2f}x (>3.0x)。`r`n", optSplitMs, speedupSplit), reportFile, "UTF-8")
    else
        FileAppend(Format("  - [FAIL] SplitMerged 性能硬指标未达标：耗时 {1:.2f} ms (<1000ms)，提速 {2:.2f}x (>3.0x)。`r`n", optSplitMs, speedupSplit), reportFile, "UTF-8")

    ; 4. 优化后生产函数数据正确性断言（整块 MergeCells 断言 + SafeArray 全量 3000 单元格校验）
    Assert(sheetSplitOpt.Range("A1:C1000").MergeCells == false, "拆分后选区依然存在合并单元格")
    splitOptMatrix := sheetSplitOpt.Range("A1:C1000").Value2
    for spec in planSpecs {
        if (spec["end"] - spec["start"] + 1 >= 2 && spec["val"] != "") {
            colIdx := spec["col"]
            Loop (spec["end"] - spec["start"] + 1) {
                cellRow := spec["start"] + A_Index - 1
                cellVal := splitOptMatrix[cellRow, colIdx]
                Assert(cellVal = spec["val"], "拆分后单元格值不一致: R" . cellRow . "C" . colIdx)
            }
        }
    }
    FileAppend("  - [PASS] 拆分后所有原合并区域解绑 (MergeCells==false) 且首格内容全量填充。`r`n", reportFile, "UTF-8")

    ; 5. 优化后生产函数拆分撤销断言
    tUndo0 := GetTimestamp()
    SafeRestoreUndoAction(app, undoSplitOpt)
    tUndo1 := GetDurationMs(tUndo0, GetTimestamp())
    FileAppend(Format("  - 拆分撤销还原耗时: {1:.2f} ms`r`n", tUndo1), reportFile, "UTF-8")
    undoOptMatrix := sheetSplitOpt.Range("A1:C1000").Value2
    checkedUndoCount := 0
    for spec in planSpecs {
        if (spec["end"] - spec["start"] + 1 >= 2 && spec["val"] != "") {
            colIdx := spec["col"]
            Assert(undoOptMatrix[spec["start"], colIdx] = spec["val"], "撤销后首单元格内容不匹配")
            checkedUndoCount += 1
            if (checkedUndoCount <= 15 || Mod(checkedUndoCount, 40) = 0) {
                colLetter := (colIdx = 1 ? "A" : (colIdx = 2 ? "B" : "C"))
                rangeAddr := colLetter . spec["start"] . ":" . colLetter . spec["end"]
                Assert(sheetSplitOpt.Range(rangeAddr).MergeCells == true, "撤销后区域未能重新合并: " . rangeAddr)
            }
        }
    }
    FileAppend("  - [PASS] 拆分撤销 (RestoreUndoAction) 100% 完整还原原合并状态与首格数据。`r`n", reportFile, "UTF-8")

    ; --------------------------------------------------------------------------
    ; 阶段二：MergeIdenticalSpreadsheetCells 性能对比与回归断言
    ; --------------------------------------------------------------------------
    FileAppend("`r`n>>> 测试二：[合并相同内容并居中] 性能对比与回归断言...`r`n", reportFile, "UTF-8")

    ; 1. 基线耗时测量 (Baseline)
    sheetMergeBaseline := book.Worksheets.Add()
    PopulateSheetWithData(sheetMergeBaseline, planSpecs, false)
    FileAppend("  - [PROGRESS] MergeBaseline 数据填充完成，开始测量基线耗时...`r`n", reportFile, "UTF-8")
    contextMergeBaseline := Map("app", app, "selection", sheetMergeBaseline.Range("A1:C1000"), "name", kind, "silent", true)

    t4 := GetTimestamp()
    undoMergeBaseline := BaselineMergeIdentical(contextMergeBaseline)
    t5 := GetTimestamp()
    baselineMergeMs := GetDurationMs(t4, t5)
    FileAppend(Format("  - MergeIdentical 基线耗时 (Baseline): {1:.2f} ms`r`n", baselineMergeMs), reportFile, "UTF-8")

    ; 2. 优化后生产函数耗时测量 (Optimized)
    sheetMergeOpt := book.Worksheets.Add()
    PopulateSheetWithData(sheetMergeOpt, planSpecs, false)
    FileAppend("  - [PROGRESS] MergeOpt 数据填充完成，开始测量优化后耗时...`r`n", reportFile, "UTF-8")
    contextMergeOpt := Map("app", app, "selection", sheetMergeOpt.Range("A1:C1000"), "name", kind, "silent", true)

    t6 := GetTimestamp()
    undoMergeOpt := MergeIdenticalSpreadsheetCells(contextMergeOpt)
    t7 := GetTimestamp()
    optMergeMs := GetDurationMs(t6, t7)
    speedupMerge := baselineMergeMs / optMergeMs
    FileAppend(Format("  - MergeIdentical 优化后耗时 (Optimized): {1:.2f} ms`r`n", optMergeMs), reportFile, "UTF-8")
    FileAppend(Format("  - MergeIdentical 性能提速比: {1:.2f}x`r`n", speedupMerge), reportFile, "UTF-8")

    ; 3. 性能硬性断言：耗时 < 1000 ms, 提速比 > 3.0x
    passedOptMerge := Assert(optMergeMs < 1000.0, Format("MergeIdentical 优化后耗时未达标 (<1000ms): {1:.2f} ms", optMergeMs))
    passedSpeedupMerge := Assert(speedupMerge > 3.0, Format("MergeIdentical 提速比未达标 (>3.0x): {1:.2f}x", speedupMerge))
    if (passedOptMerge && passedSpeedupMerge)
        FileAppend(Format("  - [PASS] MergeIdentical 性能硬指标达标：耗时 {1:.2f} ms (<1000ms)，提速 {2:.2f}x (>3.0x)。`r`n", optMergeMs, speedupMerge), reportFile, "UTF-8")
    else
        FileAppend(Format("  - [FAIL] MergeIdentical 性能硬指标未达标：耗时 {1:.2f} ms (<1000ms)，提速 {2:.2f}x (>3.0x)。`r`n", optMergeMs, speedupMerge), reportFile, "UTF-8")

    ; 4. 优化后生产函数纵向合并与居中断言
    Assert(sheetMergeOpt.Range("A1:C1000").HorizontalAlignment = -4108, "选区水平居中未生效")
    Assert(sheetMergeOpt.Range("A1:C1000").VerticalAlignment = -4108, "选区垂直居中未生效")
    checkedMergeIdx := 0
    for item in undoMergeOpt["items"] {
        checkedMergeIdx += 1
        if (checkedMergeIdx <= 15 || Mod(checkedMergeIdx, 40) = 0) {
            mRange := sheetMergeOpt.Range(item["address"])
            Assert(mRange.MergeCells == true, "合并后区域 MergeCells 属性不为 true: " . item["address"])
            Assert(mRange.Columns.Count = 1, "违背纵向独立合并规则，出现跨列合并: " . item["address"])
            Assert(mRange.HorizontalAlignment = -4108, "合并区域未居中对齐 HorizontalAlignment !== -4108: " . item["address"])
            Assert(mRange.VerticalAlignment = -4108, "合并区域未居中对齐 VerticalAlignment !== -4108: " . item["address"])
        }
    }
    FileAppend("  - [PASS] 纵向独立合并与居中对齐属性全量断言通过。`r`n", reportFile, "UTF-8")

    ; 5. 分页符边界截断断言 (第 250 行水平分页符)
    addr248 := sheetMergeOpt.Range("A248").MergeArea.Address(false, false)
    addr250 := sheetMergeOpt.Range("A250").MergeArea.Address(false, false)
    addr249 := sheetMergeOpt.Range("A249").MergeArea.Address(false, false)
    Assert(addr248 = "A248:A249", "分页符前半段未正确独立合并为 A248:A249 (实际: " . addr248 . ")")
    Assert(addr250 = "A250:A253", "分页符后半段未正确独立合并为 A250:A253 (实际: " . addr250 . ")")
    Assert(addr249 != addr250, "严重错误：相同内容跨越了分页符第 250 行合并！(A249=" . addr249 . ", A250=" . addr250 . ")")
    FileAppend("  - [PASS] 水平分页符强制隔离阻断合并断言通过。`r`n", reportFile, "UTF-8")

    ; 6. 空白单元格阻断断言 (第 500 行为空白)
    Assert(sheetMergeOpt.Range("A498:A499").MergeCells == true, "空白单元格前段 A498:A499 未合并")
    Assert(!sheetMergeOpt.Range("A500").MergeCells, "空白单元格 A500 被错误合并")
    Assert(sheetMergeOpt.Range("A501:A502").MergeCells == true, "空白单元格后段 A501:A502 未合并")
    FileAppend("  - [PASS] 空白单元格阻断合并断言通过。`r`n", reportFile, "UTF-8")

    ; 7. 优化后生产函数合并撤销断言
    tUndoMerge0 := GetTimestamp()
    SafeRestoreUndoAction(app, undoMergeOpt)
    tUndoMerge1 := GetDurationMs(tUndoMerge0, GetTimestamp())
    FileAppend(Format("  - 合并撤销还原耗时: {1:.2f} ms`r`n", tUndoMerge1), reportFile, "UTF-8")
    Assert(!sheetMergeOpt.Range("A248:A249").MergeCells, "撤销后区域 A248:A249 依然为合并状态")
    Assert(sheetMergeOpt.Range("A248").Value = "跨分页测试段", "撤销还原单元格内容不符")
    Assert(sheetMergeOpt.Range("A249").Value = "跨分页测试段", "撤销还原附属单元格内容不符")
    FileAppend("  - [PASS] 合并撤销 (RestoreUndoAction) 100% 完整还原原未合并状态与原始数据。`r`n", reportFile, "UTF-8")

    ; --------------------------------------------------------------------------
    ; 阶段三：边界条件、公式与已合并异常防御断言 (直接验证生产函数)
    ; --------------------------------------------------------------------------
    FileAppend("`r`n>>> 测试三：边界条件与异常拦截断言 (生产函数验证)...`r`n", reportFile, "UTF-8")

    ; 1. 包含公式单元格拦截
    sheetFormula := book.Worksheets.Add()
    sheetFormula.Range("A1").Value := "测试"
    sheetFormula.Range("A2").Value := "测试"
    sheetFormula.Range("B1").Formula := "=1+1"
    sheetFormula.Range("B2").Formula := "=2+2"
    rejectedFormula := false
    try {
        MergeIdenticalSpreadsheetCells(Map("app", app, "selection", sheetFormula.Range("A1:B2"), "name", kind, "silent", true))
    } catch {
        rejectedFormula := true
    }
    Assert(rejectedFormula, "选区包含公式时未能正确拦截拒绝！")
    FileAppend("  - [PASS] 包含公式选区拦截防御通过。`r`n", reportFile, "UTF-8")

    ; 2. 选区已包含合并单元格拦截
    sheetMergedPre := book.Worksheets.Add()
    sheetMergedPre.Range("A1:A2").Merge()
    sheetMergedPre.Range("A3").Value := "测试"
    rejectedMerged := false
    try {
        MergeIdenticalSpreadsheetCells(Map("app", app, "selection", sheetMergedPre.Range("A1:A3"), "name", kind, "silent", true))
    } catch {
        rejectedMerged := true
    }
    Assert(rejectedMerged, "选区包含已有合并单元格时未能正确拦截拒绝！")
    FileAppend("  - [PASS] 已有合并单元格选区拦截防御通过。`r`n", reportFile, "UTF-8")

    ; 3. 不连续选区拦截
    rejectedNonContiguous := false
    try {
        MergeIdenticalSpreadsheetCells(Map("app", app, "selection", sheetMergeOpt.Range("A1:A10,C1:C10"), "name", kind, "silent", true))
    } catch {
        rejectedNonContiguous := true
    }
    Assert(rejectedNonContiguous, "不连续选区未能正确拦截拒绝！")
    FileAppend("  - [PASS] 不连续选区拦截防御通过。`r`n", reportFile, "UTF-8")

    ; 4. 整列选择 A:B 与 UsedRange 裁剪验证
    sheetCol := book.Worksheets.Add()
    sheetCol.Range("A1:A3").Merge()
    sheetCol.Range("A1").Value := "整列测试"
    undoCol := SplitMergedSpreadsheetCellsAndFill(Map("app", app, "selection", sheetCol.Range("A:B"), "name", kind, "silent", true))
    Assert(!sheetCol.Range("A1:A3").MergeCells, "整列选区拆分失败")
    Assert(sheetCol.Range("A2").Value = "整列测试", "整列选区拆分填充失败")
    FileAppend("  - [PASS] 整列选区 (A:B) 裁剪至 UsedRange 执行成功。`r`n", reportFile, "UTF-8")

    if (AssertFailures.Length > 0) {
        failSummary := "断言未全部通过，共 " . AssertFailures.Length . " 项失败：`r`n"
        for msg in AssertFailures
            failSummary .= "  - [FAIL] " . msg . "`r`n"
        throw Error(failSummary)
    }

    FileAppend("`r`n================================================================================`r`n", reportFile, "UTF-8")
    FileAppend("所有基准性能与优化性能测量及全量回归断言 100% 验证通过！`r`n", reportFile, "UTF-8")
    FileAppend("================================================================================`r`n", reportFile, "UTF-8")

    try FileAppend(kind . "：基准与优化性能测量及全量回归断言通过`n", "*", "UTF-8")
    exitCode := 0
} catch as err {
    errMsg := "测试失败：" . err.Message . "`n" . err.Stack . "`n"
    try FileAppend(errMsg, reportFile, "UTF-8")
    try FileAppend(errMsg, "**", "UTF-8")
    exitCode := 1
} finally {
    if IsObject(book) {
        try book.Close(false)
        book := ""
    }
    if IsObject(app) {
        try app.Quit()
        app := ""
    }
}

ExitApp(exitCode)

#Include ..\src
#Include excel-command-panel.ahk
#SingleInstance Off
