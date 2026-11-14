#Requires AutoHotkey v2.0
#Warn All, StdOut  ; 警告写到标准输出，不弹窗
; 找出最新版本窗口冒烟测试：在临时目录造几份同名 DWG（不同文件夹、不同修改时间），扫描后打开结果窗口，
; 检查归组、默认选中、气泡点击区域、切换选中和滚动，并把窗口截图存成 PNG。不改动临时目录以外的任何文件。
; 用法：AutoHotkey64.exe /ErrorStdOut tests\latest-version-window-smoke.ahk <输出PNG>
#Include ..\src\modern-panel-ui.ahk
#Include ..\src\cable-sort.ahk  ; 气泡右键菜单复用 CableSortPopup
#Include ..\src\file-latest-version.ahk

; 主面板里才有的函数；测试里放空的
RunPanelCommand(callback) => callback()
GetSelectedFilePaths() => []

failures := 0
Check(cond, what) {
    global failures
    if !cond {
        failures++
        FileAppend("FAIL: " . what . "`n", "*", "UTF-8")
    }
}

Main()
FileAppend(failures ? "FAIL (" . failures . ")`n" : "PASS latest-version-window`n", "*", "UTF-8")
ExitApp(failures ? 1 : 0)

Main() {
    global failures
    tempRoot := A_Temp . "\latest-version-smoke-" . A_TickCount
    win := ""
    try {
        win := RunWindowSmoke(tempRoot, A_Args.Length ? A_Args[1] : "")
    } catch as smokeErr {
        failures++
        FileAppend("FAIL: 运行出错 " . smokeErr.Message . "（" . smokeErr.What . " 第 " . smokeErr.Line . " 行）`n", "*", "UTF-8")
    }
    if IsObject(win)
        LatestUiClose(win)
    try DirDelete(tempRoot, true)
}

RunWindowSmoke(root, png) {
    project := root . "\D260012S 宜昌东至35kV变电站项目"
    name := "D260012S-D0204-主变压器保护二次线.dwg"
    copies := [[project . "\电气二次施工图 CAD", name, "20260904172300", 700]
        , [root . "\CAD - 无标注版", name, "20260827135436", 600]
        , [project . "\CAD", name, "20260827080258", 500]
        , [root . "\20260814-加厂家配线", "D260012S-D0204-主变压器保护二次线 - 副本.dwg", "20260813083651", 400]
        , [root . "\旧\CAD", name, "20260813083651", 400]
        , [root . "\20260810东至发", name, "20260811134249", 300]
        , [root . "\20260810东至发", "D260012S-D0208-火灾报警二次线.dwg", "20260811134249", 100]
        , [root . "\CAD - 无标注版", "D260012S-D0208-火灾报警二次线_v2.dwg", "20260820100000", 120]
        , [root, "说明.pdf", "20260801100000", 50]
        , [root, "说明.bak", "20260801100000", 50]]
    for _, c in copies {
        DirCreate(c[1])
        path := c[1] . "\" . c[2]
        f := FileOpen(path, "w")
        f.RawWrite(Buffer(c[4], 65))
        f.Close()
        FileSetTime(c[3], path, "M")
    }
    scan := LatestVersionScan([root])
    scan["selected"] := [root], scan["elapsed"] := 400
    Check(scan["files"] = 9, "应比较 9 个文件，实际 " . scan["files"])
    Check(scan["skipped"] = 1, "应忽略 1 个 .bak")
    Check(scan["groups"].Length = 3, "应归成 3 组，实际 " . scan["groups"].Length)

    st := ShowLatestVersionReport("找出最新版本", scan)
    hwnd := st["gui"].Hwnd
    ; 窗口放到屏幕外、搜索框只读：测试时用户正在打字的话，按键会进搜索框把列表过滤空（2026-11-11 实测）
    st["search"].Opt("+ReadOnly")
    WinMove(-4000, 20, 1280, 860, hwnd)
    Redraw(st)
    group := st["groups"][st["sel"]]
    Check(group["copies"].Length = 6, "默认应选中 6 份的主变压器那组")
    Check(group["newest"]["path"] = project . "\电气二次施工图 CAD\" . name, "最新那份路径不对")
    Check(st["rows"].Length = 2, "只看多份时列表应有 2 组，实际 " . st["rows"].Length)
    cards := LatestUiCards(st, st["sel"])
    Check(cards[1]["title"] = "电气二次施工图 CAD", "最新气泡标题应为所在文件夹")
    Check(InStr(cards[5]["title"], "另一处"), "同名文件夹的第二个气泡应标“另一处”")
    Check(cards[3]["ambiguous"] && cards[3]["parent"] = "D260012S 宜昌东至35kV变电站项目", "同名文件夹应显示上级")
    Check(LatestUiCurveLabel(group, 5)[1] = "与最新相同" || InStr(LatestUiCurveLabel(group, 5)[1], "早"), "连线标签")
    cardHits := 0
    for _, hit in st["hits"]
        if (SubStr(hit[1], 1, 5) = "card:")
            cardHits++
    Check(cardHits = 6, "应有 6 个气泡点击区域，实际 " . cardHits)
    ; 左键双击气泡不打开文件夹；右键气泡弹出“打开所在文件夹”菜单（菜单放屏幕外，不打扰用户）
    st["popupAt"] := [-4000, 300]
    for _, hit in st["hits"]
        if (hit[1] = "card:2") {
            scale := A_ScreenDPI / 96
            lp := (Round((hit[3] + hit[5] / 2) * scale) << 16) | Round((hit[2] + hit[4] / 2) * scale)
            loop 2 {
                SendMessage(0x201, 1, lp, , hwnd)
                SendMessage(0x202, 0, lp, , hwnd)
            }
            Sleep(100)
            Check(!(st.Has("popup") && IsObject(st["popup"])), "左键点气泡不应弹菜单")
            SendMessage(0x205, 0, lp, , hwnd)
            Sleep(300)
            Check(st.Has("popup") && IsObject(st["popup"]), "右键气泡应弹出菜单")
            CableSortPopupClose(st)
        }
    Check(!WinExist("ahk_class CabinetWClass ahk_exe explorer.exe", "电气二次施工图") , "左键双击气泡不应打开资源管理器")
    if (png != "")
        Check(SaveCanvasPng(st, png), "截图失败")

    ; 键盘切到下一组，气泡跟着换
    LatestUiMoveSel(st, 1)
    Redraw(st)
    Check(st["groups"][st["sel"]]["copies"].Length = 2, "切换后应是 2 份的那组")
    if (png != "")
        SaveCanvasPng(st, RegExReplace(png, "\.png$", "-2.png"))
    ; 关掉“只看有多份的”后列表含单份文件
    LatestUiClick(st, "toggle", "")
    Redraw(st)
    Check(st["rows"].Length = 3, "显示全部时应有 3 组")
    ; 列表按文件名排序（不按修改时间）：说明.pdf 最旧，但按名称排在 D260012S 后面；D0204 在 D0208 前
    order := ""
    for _, index in st["rows"]
        order .= st["groups"][index]["newest"]["name"] . "|"
    Check(order = name . "|D260012S-D0208-火灾报警二次线_v2.dwg|说明.pdf|", "列表应按文件名排序，实际 " . order)
    ; 文件类型按钮
    typeHits := 0
    for _, hit in st["hits"]
        if (SubStr(hit[1], 1, 5) = "type:")
            typeHits++
    Check(typeHits = 5, "应有 5 个文件类型按钮，实际 " . typeHits)
    LatestUiClick(st, "type:pdf", "")
    Redraw(st)
    Check(st["rows"].Length = 1, "只看 PDF 应剩 1 组，实际 " . st["rows"].Length)
    if (png != "")
        SaveCanvasPng(st, RegExReplace(png, "\.png$", "-pdf.png"))
    LatestUiClick(st, "type:dwg", "")
    Check(st["rows"].Length = 2, "只看 DWG 应剩 2 组")
    LatestUiClick(st, "type:excel", "")
    Check(st["rows"].Length = 0, "只看 Excel 应为空")
    LatestUiClick(st, "type:all", "")
    Check(st["rows"].Length = 3, "回到全部应有 3 组")
    ; 搜索
    st["search"].Value := "火灾"
    st["query"] := "火灾"
    LatestUiRefill(st)
    Redraw(st)
    Check(st["rows"].Length = 1, "搜索“火灾”应剩 1 组")
    ; 窄窗口不报错
    WinMove(-4000, 20, 980, 620, hwnd)
    st["search"].Value := "", st["query"] := ""
    LatestUiRefill(st)
    LatestUiSelect(st, st["latest"])
    Redraw(st)
    if (png != "")
        SaveCanvasPng(st, RegExReplace(png, "\.png$", "-small.png"))
    Check(st["graphMax"] >= 0, "窄窗口布局")
    return st
}

Redraw(st) {
    LatestUiInvalidate(st)
    DllCall("RedrawWindow", "Ptr", st["gui"].Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
    Sleep(150)
}

; 直接把界面画布存成 PNG（窗口在屏幕外时 PrintWindow 拿到的是 DWM 旧缓存，画面不更新）
SaveCanvasPng(st, path) {
    rc := Buffer(16, 0)
    DllCall("GetClientRect", "Ptr", st["gui"].Hwnd, "Ptr", rc)
    LatestUiRender(st, NumGet(rc, 8, "Int"), NumGet(rc, 12, "Int"))
    clsid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
    return DllCall("gdiplus\GdipSaveImageToFile", "Ptr", st["bmp"], "Str", path, "Ptr", clsid, "Ptr", 0) = 0
}
