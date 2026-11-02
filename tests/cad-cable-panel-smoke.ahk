#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, StdOut
; 电缆定义总览冒烟测试：不连接 CAD，读假总览文件，窗口放在屏幕外。
; 核对解析、编码、实时跟随、滚动、不抢焦点，并把画布存成 PNG 供目视检查。
; 用法：AutoHotkey64.exe tests\cad-cable-panel-smoke.ahk <输出目录>
#Include ..\src\modern-panel-ui.ahk
#Include ..\src\cad-cable-panel.ahk

outDir := A_Args.Length ? A_Args[1] : A_Temp
results := []
OnError(SmokeError)
SmokeError(err, *) {
    global outDir
    FileAppend("ERROR " . err.Message . " | " . err.What . " | line " . err.Line . " | " . err.Extra . "`r`n", outDir . "\cad-cable-panel-smoke.txt", "UTF-8")
    ExitApp(2)
}

CablePanelPath := outDir . "\overview-test.txt"
try FileDelete(CablePanelPath)
try FileDelete(outDir . "\cad-cable-panel-smoke.txt")

base := "DDFDOVERVIEW`t1`nID`t2461347.1`nTIME`t2026-11-02 09:12:30`nDWG`tE:\366256\项目\110kV 配电装置平面图.dwg`nVERSION`t2026-11-02-live`nCURFLOOR`t1F`n"
    . "STEP`t1`t建楼层`tok`t3 层`nSTEP`t2`t定义房间`tok`t5 间`nSTEP`t3`t标柜子`terr`t8 台`nSTEP`t4`t画通道`twarn`t3 条 3 段`nSTEP`t5`t标竖井`twarn`t2 个`nSTEP`t6`t检查导出`ttodo`t1 个错误`n"
    . "FLOOR`tB1F`nFLOOR`t1F`nFLOOR`t2F`nFLOOR`t3F`n"
    . "ROOM`tB1F`t电缆夹层`t298`t0`t0,-20000;10000,-20000;10000,-12000;0,-12000;`n"
    . "ROOM`t2F`t配电室`t291`t2`t0,20000;10000,20000;10000,28000;0,28000;`n"
    . "ROOM`t1F`t主控室`t290`t1`t12000,0;20000,0;20000,8000;12000,8000;`n"
    . "ROOM`t1F`t配电室`t28E`t2`t0,0;10000,0;10000,8000;0,8000;`n"
    . "CAB`t2F`t5AH`t29D`t2000`t22000`t291`t配电室`nCAB`t2F`t7AH`t2AB`t5000`t23000`t291`t配电室`n"
    . "CAB`t1F`t4AH`t29C`t11000`t3000`t`t`nCAB`t1F`t3AH`t29B`t14000`t2000`t290`t主控室`n"
    . "CAB`t1F`t2AH`t29A`t3000`t4000`t28E`t配电室`nCAB`t1F`t10AH`t299`t2000`t2000`t28E`t配电室`n"
    . "SHAFT`t1F`t竖井甲`t竖井甲_1F`t2A4`t16000`t5000`nSHAFT`t2F`tZJ1`tZJ1_2F`t2A3`t15000`t24000`n"
    . "SHAFT`t1F`tZJ1`tZJ1_1F`t2A2`t15000`t4000`nSHAFT`tB1F`tZJ1`tZJ1_B1F`t2A1`t15000`t-15000`n"
    . "ROUTE`t2F`t2A0`t1`t1000,21000;9000,21000;`nROUTE`t1F`t29F`t1`t1000,1000;1000,5000;`nROUTE`t1F`t29E`t1`t1000,1000;19000,1000;`n"
    . "ISSUE`terr`t3`t柜名重复`t299`t柜名 1AH 重复 2 处，这是第 2 处；统计时只用第 1 处`n"
    . "ISSUE`twarn`t4`t缺通道`t`t3F 有柜子但没有通道`n"
    . "ISSUE`tinfo`t2`t空房间`t298`t房间 B1F 电缆夹层 里没有柜子`n"

; 编码：UTF-8（中望）和 GBK（AutoCAD 2018）读回一致
for enc in ["UTF-8-RAW", "CP936"] {
    path := outDir . "\overview-enc-" . enc . ".txt"
    try FileDelete(path)
    FileAppend(base, path, enc)
    back := CablePanelDecode(FileRead(path, "RAW"))
    FileDelete(path)
    Check(back = base, "按 " . enc . " 写入的总览读回一致")
}

data := CablePanelParse(base)
Check(data["steps"].Length = 6 && data["floors"].Length = 4 && data["rooms"].Length = 4 && data["cabs"].Length = 6, "步骤、楼层、房间、柜子数量")
Check(data["shafts"].Length = 4 && data["routes"].Length = 3 && data["issues"].Length = 3 && data["cur"] = "1F", "竖井、通道、问题和当前楼层")
Check(data["cabs"][3]["room"] = "" && data["rooms"][4]["pts"].Length = 4 && data["rooms"][1]["pts"][1][2] = -20000, "空房间列和负坐标")
sorted := CablePanelSortByName(CablePanelFloorItems(data["cabs"], "1F"))
Check(sorted[1]["name"] = "2AH" && sorted[4]["name"] = "10AH", "柜名按数字顺序排序（2AH 在 10AH 前）")
Check(CablePanelShaftFloors(data, "ZJ1") = "B1F 1F 2F", "竖井配对楼层按楼层顺序")

; 启动基准：旧文件不弹出
FileAppend(base, CablePanelPath, "UTF-8-RAW")
CablePanelState["stamp"] := CablePanelFileStamp(CablePanelPath)
CablePanelPoll()
Check(!IsObject(CablePanelState["ui"]), "启动时已有的文件不弹出")

; 新内容自动显示在屏幕外，并跟到 CURFLOOR
marker := Gui("+AlwaysOnTop", "冒烟基准窗口")
CablePanelState["pos"] := "x-3000 y100"
active := WinExist("A")
Rewrite(base)
CablePanelPoll()
ui := CablePanelState["ui"]
Sleep(300)
Check(IsObject(ui) && CablePanelState["floor"] = "1F", "新内容弹出并切到 1F")
Check(WinExist("A") = active, "显示后焦点没有被抢走")
Check(ModernPanelRegistry().Has(ui["gui"].Hwnd) && ui["keep"], "登记为常驻小窗")
hwnd := ui["gui"].Hwnd
size := CablePanelSize()
SaveCanvas(ui, outDir . "\cable-panel-1f.png", size)

; 同一秒内连续写入也要刷新；窗口不重建
Rewrite(StrReplace(base, "STEP`t3`t标柜子`terr`t8 台", "STEP`t3`t标柜子`terr`t9 台")
    . "CAB`t1F`t新柜`t2B0`t5000`t6000`t28E`t配电室`n")
CablePanelPoll()
Check(CablePanelState["data"]["cabs"].Length = 7 && CablePanelState["ui"]["gui"].Hwnd = hwnd, "连续写入即时刷新且窗口没有重建")

; 向导切楼层，面板跟随；手动切页不被同一楼层的刷新打断
Rewrite(StrReplace(base, "CURFLOOR`t1F", "CURFLOOR`t2F"))
CablePanelPoll()
Check(CablePanelState["floor"] = "2F", "向导换到 2F 时面板跟随")
SaveCanvas(ui, outDir . "\cable-panel-2f.png", size)
CablePanelPickFloor("B1F")
Rewrite(StrReplace(base, "CURFLOOR`t1F", "CURFLOOR`t2F"))
CablePanelPoll()
Check(CablePanelState["floor"] = "B1F", "手动看别的楼层时，同层刷新不抢回去")

; 滚动：柜子多时只画可视区内的行，滚到底不越界
many := StrReplace(base, "CURFLOOR`t1F", "CURFLOOR`t3F")
loop 40
    many .= "CAB`t3F`tAH-" . A_Index . "`tF" . A_Index . "`t" . (A_Index * 500) . "`t" . Mod(A_Index, 7) * 900 . "`t`t`n"
Rewrite(many)
CablePanelPoll()
Check(CablePanelState["floor"] = "3F" && CablePanelState["maxScroll"] > 0, "内容超出时可滚动")
CablePanelOnWheel(-120 << 16, 0, 0x020A, ui["gui"].Hwnd)
Check(CablePanelState["scroll"] = 60, "向下滚一格")
loop 80
    CablePanelOnWheel(-120 << 16, 0, 0x020A, ui["gui"].Hwnd)
Check(CablePanelState["scroll"] = CablePanelState["maxScroll"], "滚到底不越界")
SaveCanvas(ui, outDir . "\cable-panel-scroll.png", size)
inside := true
for element in ui["elements"]
    if (element["y"] + element["h"] > size[2])
        inside := false
Check(inside, "所有元素都在窗口内")

; 高亮：不连接 CAD，只验证选中状态重画
CablePanelState["floor"] := "1F", CablePanelState["scroll"] := 0, CablePanelState["hilite"] := "29A"
Rewrite(base)
CablePanelPoll()
SaveCanvas(ui, outDir . "\cable-panel-hilite.png", size)
hit := 0
for element in ui["elements"]
    if IsObject(element["onClick"])
        hit++
Check(hit >= 10, "列表和楼层页签可点击（实际 " . hit . "）")

; 平面图：对象拾取、缩放、拖动。ToScreen 把图纸坐标换成窗口逻辑像素，和绘制用同一个视图
ToScreen(wx, wy) {
    plan := CablePanelState["plan"]
    xf := CablePanelPlanXform(plan)
    return [plan["x"] + plan["w"] / 2 + (wx - xf["cx"]) * xf["k"], plan["y"] + plan["h"] / 2 - (wy - xf["cy"]) * xf["k"]]
}
PickAt(wx, wy) {
    pos := ToScreen(wx, wy)
    pick := CablePanelPick(CablePanelState["plan"], pos[1], pos[2])
    return IsObject(pick) ? pick["handle"] : ""
}
Lparam(pos) {
    scale := A_ScreenDPI / 96
    return ((Round(pos[2] * scale) & 0xFFFF) << 16) | (Round(pos[1] * scale) & 0xFFFF)
}
CablePanelState["hilite"] := ""
CablePanelPickFloor("1F")
Check(PickAt(14000, 2000) = "29B", "点到柜子")
Check(PickAt(16000, 5000) = "2A4", "点到竖井")
Check(PickAt(5000, 1000) = "29E", "点到通道")
Check(PickAt(5000, 6000) = "28E", "点到房间")
Check(PickAt(11000, 7000) = "", "空白处没有对象")

plan := CablePanelState["plan"]
fitK := CablePanelPlanXform(plan)["k"]
before := ToScreen(14000, 2000)
loop 6
    CablePanelZoomAt(plan, before[1], before[2], 1.25)
after := ToScreen(14000, 2000)
Check(CablePanelState["view"]["k"] > fitK * 3.7 && Abs(after[1] - before[1]) < 0.01 && Abs(after[2] - before[2]) < 0.01, "缩放时鼠标所指的点不动")
SaveCanvas(ui, outDir . "\cable-panel-zoom.png", size)
loop 60
    CablePanelZoomAt(plan, before[1], before[2], 1.25)
Check(CablePanelState["view"]["k"] <= fitK * 400.01, "放大有上限")
CablePanelFit()
Check(!IsObject(CablePanelState["view"]), "全图回到适应窗口")

; 平面图名称：互相冲突的不画，拉开后显示；靠右的放到点的左边；房间名挡住时让开
closeMarks := [[100, 100, "柜A"], [100, 110, "柜B"]]
Check(CablePanelClearLabels(closeMarks, [], 1000, 12).Length = 0, "挨得太近的名称都不画")
farMarks := [[100, 100, "柜A"], [100, 200, "柜B"]]
Check(CablePanelClearLabels(farMarks, [], 1000, 12).Length = 2, "拉开后名称都显示")
Check(CablePanelClearLabels([[995, 100, "柜A"]], [], 1000, 12)[1][1] < 995, "靠右的名称放到点的左边")
Check(CablePanelClearLabels(farMarks, [[90, 90, 400, 110]], 1000, 12).Length = 1, "和房间名冲突的名称不画")
columns := CablePanelClearLabels([[100, 100, "继电保护试验电源柜"], [200, 100, "公用测控柜"]], [], 1000, 12)
Check(columns.Length = 2 && columns[1][3] < 200, "长名称截短到下一列的点之前，两列都显示")
crossing := CablePanelClearLabels([[100, 100, "继电保护试验电源柜配电柜"], [500, 112, "新能源数据中心专网柜配电柜"]], [], 510, 20)
Check(crossing.Length = 1 && crossing[1][5] = "继电保护试验电源柜配电柜", "隔得远的长名称相撞时保留一个")

; 中键拖动：按下记录，移动平移，松开结束；拖到很远也不会把图拖丢
hwnd := ui["gui"].Hwnd
start := [plan["x"] + plan["w"] / 2, plan["y"] + plan["h"] / 2]
CablePanelOnMiddleDown(0, Lparam(start), 0x207, hwnd)
Check(IsObject(CablePanelState["drag"]), "中键按下进入拖动")
dragTo := [start[1] + 30, start[2] + 12]
CablePanelOnMouseMove(0, Lparam(dragTo), 0x200, hwnd)
Check(Abs(ToScreen(10000, 4000)[1] - dragTo[1]) < 40, "拖动后画面跟随鼠标")
CablePanelOnMouseMove(0, Lparam([start[1] + 5000, start[2]]), 0x200, hwnd)
view := CablePanelState["view"]
Check(view["cx"] >= plan["minX"] && view["cx"] <= plan["maxX"], "拖到很远时中心仍在图形范围内")
CablePanelOnMiddleUp(0, 0, 0x208, hwnd)
Check(!IsObject(CablePanelState["drag"]), "中键松开结束拖动")
CablePanelFit()

; 向导新增对象时，缩放好的画面不跳
pos := ToScreen(14000, 2000)
CablePanelZoomAt(plan, pos[1], pos[2], 2)
viewBefore := CablePanelState["view"]["cx"]
Rewrite(base . "CAB`t1F`t远处新柜`t2B1`t90000`t90000`t`t`n")
CablePanelPoll()
Check(CablePanelState["view"]["cx"] = viewBefore, "实时刷新不改变缩放后的画面")
CablePanelFit()
Rewrite(base)
CablePanelPoll()

; 平面图点中对象后列表滚到对应行（不走 CablePanelClick，避免连接 CAD）
Rewrite(many)
CablePanelPoll()
CablePanelState["floor"] := "3F", CablePanelState["scroll"] := 0, CablePanelState["reveal"] := "F35"
CablePanelRender()
Check(CablePanelState["scroll"] > 0 && CablePanelState["reveal"] = "", "列表滚到点中的柜子")

; 放大窗口：够宽时平面图在左、列表在右，所有元素仍在窗口内
ui["gui"].Show("w1100 h800 NoActivate")
Sleep(100)
wideSize := CablePanelSize()
Check(wideSize[1] = 1100 && wideSize[2] = 800, "窗口放大后尺寸同步（实际 " . wideSize[1] . "x" . wideSize[2] . "）")
Check(CablePanelState["plan"]["w"] > 700 && CablePanelState["plan"]["h"] > 600, "放大后平面图跟着变大")
inside := true
for element in ui["elements"]
    if (element["x"] + element["w"] > wideSize[1] || element["y"] + element["h"] > wideSize[2])
        inside := false
Check(inside, "放大后所有元素都在窗口内")
CablePanelPickFloor("1F")
SaveCanvas(ui, outDir . "\cable-panel-wide.png", wideSize)
ui["gui"].Show("w440 h760 NoActivate")
Sleep(100)
Check(CablePanelSize()[1] = 440 && CablePanelState["plan"]["h"] = 214, "缩回默认大小后恢复原布局")

; 关闭后这张图不再弹出；换一张图重新弹出
CablePanelClose()
Rewrite(base)
CablePanelPoll()
Check(!IsObject(CablePanelState["ui"]), "关掉后同一张图的刷新不再弹出")
Rewrite(StrReplace(base, "110kV 配电装置平面图.dwg", "另一张图.dwg"))
CablePanelPoll()
Check(IsObject(CablePanelState["ui"]), "换一张图重新弹出")
CablePanelClose()
FileDelete(CablePanelPath)

FileAppend(JoinLines(results), outDir . "\cad-cable-panel-smoke.txt", "UTF-8")
ExitApp(InStr(JoinLines(results), "FAIL") ? 1 : 0)

Rewrite(text) {
    global CablePanelPath
    static n := 1
    n++
    ; 和 LSP 一样先写临时文件再改名，ID 每次不同
    tmp := CablePanelPath . ".tmp"
    try FileDelete(tmp)
    FileAppend(StrReplace(text, "ID`t2461347.1", "ID`t2461347." . n), tmp, "UTF-8-RAW")
    FileMove(tmp, CablePanelPath, 1)
}

; ModernPanelTile 用到的主面板包装函数
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

SaveCanvas(ui, path, size) {
    scale := A_ScreenDPI / 96
    ModernPanelRender(ui, Round(size[1] * scale), Round(size[2] * scale))
    bitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", ui["canvas"], "Ptr", 0, "Ptr*", &bitmap)
    clsid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "WStr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
    DllCall("gdiplus\GdipSaveImageToFile", "Ptr", bitmap, "WStr", path, "Ptr", clsid, "Ptr", 0)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bitmap)
}
