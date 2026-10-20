#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
global AutomationPanelGui := ""
global AutomationContextHwnd := 0
global AutomationSpreadsheetSelectionContext := ""
global ExcelCommandUndoStack := []
global ShareSelfTest := A_Args.Length && A_Args[1] = "--self-test"
A_IconTip := "表格工具面板：Ctrl+Shift+E"
A_TrayMenu.Add("退出表格工具面板", (*) => ExitApp())
if ShareSelfTest {
    Suspend(true)
    ShowSharePanel()
    FileAppend("SHARE_PANEL_START_OK`n", "*", "UTF-8")
    SetTimer(() => ExitApp(0), -2000)
}

^+e::ShowSharePanel()
#HotIf WinActive("ahk_exe EXCEL.EXE") && ExcelCommandUndoStack.Length > 0
$^z::UndoExcelCommandPanelAction()
#HotIf

ShowSharePanel() {
    global AutomationPanelGui, AutomationContextHwnd, AutomationSpreadsheetSelectionContext, ShareSelfTest
    static isOpening := false
    if isOpening
        return
    isOpening := true
    try {
        if !ShareSelfTest {
            AutomationContextHwnd := WinExist("A")
            AutomationSpreadsheetSelectionContext := CaptureSpreadsheetSelectionContext(AutomationContextHwnd)
        }
        if IsObject(AutomationPanelGui)
            try AutomationPanelGui.Destroy()
        colors := ModernPanelColors()
        ui := ModernPanelCreate("表格工具面板（Excel / WPS）")
        panel := ui["gui"]

        locked := IsObject(AutomationSpreadsheetSelectionContext) && AutomationSpreadsheetSelectionContext.Has("selectionAddress")
        isError := false
        if locked {
            title := AutomationSpreadsheetSelectionContext["workbookName"]
            detail := "工作表 " . AutomationSpreadsheetSelectionContext["worksheetName"] . " · 选区 " . StrReplace(AutomationSpreadsheetSelectionContext["selectionAddress"], "$")
        } else {
            title := "未锁定选区"
            detail := "请先在表格中选中单元格，再按 Ctrl+Shift+E。"
            if IsObject(AutomationSpreadsheetSelectionContext) && AutomationSpreadsheetSelectionContext.Has("error") {
                title := "表格选区读取失败"
                detail := AutomationSpreadsheetSelectionContext["error"]
                isError := true
            }
        }
        ModernPanelLabelAt(ui, 24, 20, 432, 28, title, ModernPanelTextStyle(colors["text"], 14, true))
        ModernPanelLabelAt(ui, 24, 52, 432, 36, detail
            , ModernPanelTextStyle(isError ? colors["error"] : colors["secondary"], 9, false, "left", true))

        ModernPanelBeginPage(ui, "table", 24, 96, 432)
        tableEnabled := locked
; @SPREADSHEET_BUTTONS@
        ModernPanelNote(ui, "切到面板后选区高亮可能隐藏，操作仍使用已锁定范围。Excel 可按 Ctrl+Z 撤销；WPS 请点撤销按钮。Esc 关闭面板。")
        ModernPanelShowPage(ui, "table")

        panel.OnEvent("Close", (*) => panel.Hide())
        created := A_TickCount
        panel.OnEvent("Escape", (*) => (A_TickCount - created > 400) ? panel.Hide() : 0)
        AutomationPanelGui := panel
        if !ShareSelfTest
            panel.Show("w480 h560 Center NA")
    } finally {
        SetTimer(() => isOpening := false, -300)
    }
}
