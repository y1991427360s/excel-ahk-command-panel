#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, StdOut
; CAD 结果卡片冒烟测试：不连接 CAD。解析一份假结果，弹出卡片，把画布存成 PNG 供目视检查，
; 并核对解析排序、分页和关闭后的登记清理。用法：AutoHotkey64.exe tests\cad-report-card-smoke.ahk <输出目录>
#Include ..\src\modern-panel-ui.ahk
#Include ..\src\cad-report-card.ahk

SetTimer(CadReportPoll, 0)   ; 冒烟测试不读真实结果文件
outDir := A_Args.Length ? A_Args[1] : A_Temp
results := []
OnError(SmokeError)
SmokeError(err, *) {
    global outDir
    FileAppend("ERROR " . err.Message . " | " . err.What . " | line " . err.Line . " | " . err.Extra . "`r`n", outDir . "\cad-report-card-smoke.txt", "UTF-8")
    ExitApp(2)
}

sample := "AAREPORT`t1`nID`t2461000.5-BH2`nCMD`tBH2`nTIME`t2026-10-25 22:30:00`n"
    . "DWG`tE:\366256\2026年\09月\华润敦煌风电110kV变电站\62X-B26009S-D0206-35kV系统二次线.dwg`n"
    . "SHORT`t完成：填入 3，一致 12，疑似 1，冲突 1，相邻柜无法确定 2`n"
    . "SUM`t完成：已编号新记入 0 根；按记录填入 3 根；旧编号改为新编号 0 根；已编号且与记录一致 12 根；未编号且没有记录 1 根（未处理，需要编号请用 BH1；其中 1 根有疑似记录，已选中并写了原因）；编号冲突 1 根；无法识别 0 根（冲突和无法识别的已选中，并在电缆线右端写了原因）。`n"
    . "INFO`t相邻屏柜：按记录改为实际柜名 0 根；无法确定 2 根（已选中）。`n"
    . "INFO`t用时 0.4 秒。`n"
    . "ITEM`twarn`t疑似记录`t162D57`t疑似 YYH-136：原理号不一致，无法填入：图上 A610 B610 C610，记录 A610I B610I C610I（62X-B26009S-D0202-公用设备二次线.dwg）；统一两张图的原理号后再运行 BH2`n"
    . "ITEM`terr`t编号冲突`tA48C1`t2PMU-146：编号已被另一根电缆使用（宽频同步相量测量采集柜—35kV 2#站用变进线柜）`n"
    . "ITEM`twarn`t相邻屏柜`t9EE50`t未编号：无法确定实际柜，记录里没有本柜的相邻屏柜电缆`n"
    . "ITEM`twarn`t相邻屏柜`t9EE47`t未编号：无法确定实际柜，记录里没有本柜的相邻屏柜电缆`n"
    . "ITEM`tinfo`t跳过`t`t第 3 根：上方没有“至…”去向文字，不是电缆`n"

; 编码识别：同一份结果分别按 UTF-8（中望）和 GBK（AutoCAD 2018）写盘，读回内容必须一致
for enc in ["UTF-8-RAW", "CP936"] {
    path := outDir . "\cad-report-enc-" . enc . ".txt"
    try FileDelete(path)
    FileAppend(sample, path, enc)
    back := CadReportReadText(path)
    FileDelete(path)
    Check(back = sample && CadReportParse(back)["items"][1]["text"] = CadReportParse(sample)["items"][1]["text"], "按 " . enc . " 写入的结果文件读回一致")
}

data := CadReportParse(sample)
Check(data["cmd"] = "BH2" && data["items"].Length = 5 && data["info"].Length = 2, "解析条目与说明数量")
Check(data["items"][1]["level"] = "err" && data["items"][1]["handle"] = "A48C1", "问题条目排在最前")
Check(data["items"][5]["level"] = "info" && data["items"][5]["handle"] = "", "说明级条目排在最后、无句柄")

CadReportShow(data)
Sleep(600)
ui := CadReportUi
Check(IsObject(ui) && ModernPanelRegistry().Has(ui["gui"].Hwnd) && ui["keep"], "卡片已登记为常驻小窗")
clickable := 0
for element in ui["elements"]
    if IsObject(element["onClick"])
        clickable++
Check(clickable = 11, "可点击元素：4 个有句柄的条目 + 5 个单条复制 + 复制全部 + 关闭（实际 " . clickable . "）")
; 复制文字（只测拼出的文字，不动真实剪贴板）
one := CadReportItemText(data, data["items"][1])
Check(one = "[BH2] 编号冲突：2PMU-146：编号已被另一根电缆使用（宽频同步相量测量采集柜—35kV 2#站用变进线柜）（图纸 62X-B26009S-D0206-35kV系统二次线.dwg，句柄 A48C1）", "单条复制文字：" . one)
all := CadReportAllText(data)
Check(InStr(all, "汇总：完成：填入 3") && InStr(all, "明细（5 条）：") && InStr(all, "1. [问题] 编号冲突：2PMU-146")
    && InStr(all, "5. [说明] 跳过：第 3 根") && InStr(all, "- 用时 0.4 秒。") && InStr(all, "完整统计：完成：已编号新记入 0 根"), "复制全部包含汇总、完整统计、全部明细和说明")
; 单条复制按钮与条目底板不重叠：点条目右侧 30 像素处命中的是复制按钮
rowHit := ModernPanelHitTest(ui, ((128 + 23) << 16) | (16 + 448 - 46 + 6 + 20))
Check(IsObject(rowHit) && rowHit["w"] = 40, "条目右侧命中复制按钮")
WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " . ui["gui"].Hwnd)
results.Push("窗口位置 " . wx . "," . wy . " 尺寸 " . ww . "x" . wh)
Check(wx >= SysGet(76) && wy >= SysGet(77) && wx + ww <= SysGet(76) + SysGet(78) && wy + wh <= SysGet(77) + SysGet(79), "卡片在桌面范围内")
SaveCanvas(ui, outDir . "\cad-report-card.png")

; 普通面板创建时不应清掉常驻卡片
other := ModernPanelCreate("测试主面板")
Check(ModernPanelRegistry().Has(ui["gui"].Hwnd), "打开普通面板后卡片仍在登记表")
other["gui"].Destroy()

; 分页：20 条 → 3 页
many := CadReportParse(sample)
loop 15
    many["items"].Push(Map("level", "ok", "kind", "编号", "handle", "1" . A_Index, "text", "第 " . A_Index . " 根 至某柜：新编号 X-" . A_Index))
CadReportShow(many, 3)
Check(CadReportPage = 3, "翻到第 3 页")
SaveCanvas(CadReportUi, outDir . "\cad-report-card-page3.png")
CadReportClose()
Check(!IsObject(CadReportUi), "关闭后清空")

FileAppend(JoinLines(results), outDir . "\cad-report-card-smoke.txt", "UTF-8")
ExitApp(InStr(JoinLines(results), "FAIL") ? 1 : 0)

; 主脚本里的按钮包装函数，冒烟测试只需占位
RunPanelCommand(callback) {
    callback()
}

Check(ok, name) {
    global results
    results.Push((ok ? "PASS " : "FAIL ") . name)
}

JoinLines(lines) {
    out := ""
    for line in lines
        out .= line . "`r`n"
    return out
}

SaveCanvas(ui, path) {
    ModernPanelRender(ui, ui["canvasW"] ? ui["canvasW"] : 480, ui["canvasH"] ? ui["canvasH"] : 600)
    bitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", ui["canvas"], "Ptr", 0, "Ptr*", &bitmap)
    clsid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "WStr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
    DllCall("gdiplus\GdipSaveImageToFile", "Ptr", bitmap, "WStr", path, "Ptr", clsid, "Ptr", 0)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bitmap)
}
