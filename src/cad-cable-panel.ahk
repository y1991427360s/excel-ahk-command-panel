#Requires AutoHotkey v2.0
; 电缆定义总览：把 cad_cable_wizard.lsp 写的 %TEMP%\DDFD-Cable\overview.txt 实时显示成悬浮面板（不抢焦点）。
; 每 0.2 秒比较文件的修改时间，向导每标一个对象就刷新一次，向导切楼层时面板跟着切。
; 面板只读文件，不连接 CAD；只有点条目或平面图上的对象时才在 CAD 空闲时发送 (ddfd:zoom "句柄") 定位。
; 窗口可拖边放大；平面图上滚轮缩放、中键拖动、双击中键或“全图”回到全貌。
; 文件格式见 LSP 的“定义总览”一节，中望写 UTF-8，AutoCAD 2018 写系统编码，读取时自动识别。
; 依赖 modern-panel-ui.ahk；主面板和独立版都 #Include 本文件，并各自调用 CablePanelInit()。

global CablePanelPath := EnvGet("TEMP") . "\DDFD-Cable\overview.txt"
global CablePanelState := Map("ui", "", "data", "", "floor", "", "curFloor", "", "scroll", 0, "hilite", ""
    , "stamp", 0, "closedDwg", "", "maxScroll", 0, "pos", "", "w", 440, "h", 760
    , "plan", "", "view", "", "drag", "", "pick", "", "down", "", "reveal", "")

; 启动时已有的旧文件不弹出，等向导写入新内容
CablePanelInit() {
    global CablePanelPath, CablePanelState
    CablePanelState["stamp"] := CablePanelFileStamp(CablePanelPath)
    OnMessage(0x020A, CablePanelOnWheel)        ; WM_MOUSEWHEEL
    OnMessage(0x0200, CablePanelOnMouseMove)    ; WM_MOUSEMOVE
    OnMessage(0x0201, CablePanelOnLeftDown)     ; WM_LBUTTONDOWN
    OnMessage(0x0202, CablePanelOnLeftUp)       ; WM_LBUTTONUP
    OnMessage(0x0207, CablePanelOnMiddleDown)   ; WM_MBUTTONDOWN
    OnMessage(0x0208, CablePanelOnMiddleUp)     ; WM_MBUTTONUP
    OnMessage(0x0209, CablePanelOnMiddleDouble) ; WM_MBUTTONDBLCLK
    OnMessage(0x0020, CablePanelOnSetCursor)    ; WM_SETCURSOR
    SetTimer(CablePanelPoll, 200)
}

; 文件修改时间（100 纳秒精度）。FileGetTime 只精确到秒，同一秒内的连续刷新会漏掉
CablePanelFileStamp(path) {
    info := Buffer(36, 0)
    if !DllCall("GetFileAttributesExW", "WStr", path, "Int", 0, "Ptr", info)
        return 0
    return NumGet(info, 20, "Int64")
}

CablePanelPoll() {
    global CablePanelPath, CablePanelState
    stamp := CablePanelFileStamp(CablePanelPath)
    if (!stamp || stamp = CablePanelState["stamp"])
        return
    try text := CablePanelDecode(FileRead(CablePanelPath, "RAW"))
    catch
        return          ; CAD 正在改名替换文件，下一轮再读
    CablePanelState["stamp"] := stamp
    data := CablePanelParse(text)
    if (data["id"] != "")
        CablePanelApply(data)
}

CablePanelDecode(buf) {
    if (buf.Size = 0)
        return ""
    ; MB_ERR_INVALID_CHARS：遇到非法 UTF-8 序列返回 0
    if DllCall("MultiByteToWideChar", "UInt", 65001, "UInt", 8, "Ptr", buf, "Int", buf.Size, "Ptr", 0, "Int", 0)
        return StrGet(buf, buf.Size, "UTF-8")
    return StrGet(buf, buf.Size, "CP936")
}

CablePanelParsePoints(text) {
    pts := []
    for pair in StrSplit(text, ";") {
        xy := StrSplit(pair, ",")
        if (xy.Length = 2 && IsNumber(xy[1]) && IsNumber(xy[2]))
            pts.Push([Number(xy[1]), Number(xy[2])])
    }
    return pts
}

CablePanelParse(text) {
    data := Map("id", "", "time", "", "dwg", "", "version", "", "cur", "", "export", "", "steps", [], "floors", []
        , "rooms", [], "cabs", [], "shafts", [], "routes", [], "issues", [])
    for line in StrSplit(text, "`n", "`r") {
        p := StrSplit(line, "`t")
        if (p.Length < 2)
            continue
        switch p[1] {
            case "ID": data["id"] := p[2]
            case "TIME": data["time"] := p[2]
            case "DWG": data["dwg"] := p[2]
            case "VERSION": data["version"] := p[2]
            case "CURFLOOR": data["cur"] := p[2]
            case "FLOOR": data["floors"].Push(p[2])
            case "STEP":
                if (p.Length >= 5)
                    data["steps"].Push(Map("no", p[2], "name", p[3], "state", p[4], "text", p[5]))
            case "ROOM":
                if (p.Length >= 6)
                    data["rooms"].Push(Map("floor", p[2], "name", p[3], "handle", p[4], "count", p[5], "pts", CablePanelParsePoints(p[6])))
            case "CAB":
                if (p.Length >= 8 && IsNumber(p[5]) && IsNumber(p[6]))
                    data["cabs"].Push(Map("floor", p[2], "name", p[3], "handle", p[4], "x", Number(p[5]), "y", Number(p[6]), "room", p[7], "roomName", p[8]))
            case "SHAFT":
                if (p.Length >= 7 && IsNumber(p[6]) && IsNumber(p[7]))
                    data["shafts"].Push(Map("floor", p[2], "base", p[3], "name", p[4], "handle", p[5], "x", Number(p[6]), "y", Number(p[7])))
            case "ROUTE":
                if (p.Length >= 5)
                    data["routes"].Push(Map("floor", p[2], "handle", p[3], "segs", p[4], "pts", CablePanelParsePoints(p[5])))
            case "ISSUE":
                if (p.Length >= 6)
                    data["issues"].Push(Map("level", p[2], "step", p[3], "kind", p[4], "handle", p[5], "text", p[6]))
            case "EXPORT": data["export"] := p[2]
        }
    }
    return data
}

; 收到新内容：向导换了楼层就跟过去；用户关掉过这张图的面板就不再弹，从托盘重新打开
CablePanelApply(data) {
    global CablePanelState
    st := CablePanelState
    oldFloor := st["floor"]
    if (!IsObject(st["data"]) || st["data"]["dwg"] != data["dwg"])
        st["view"] := ""
    st["data"] := data
    if (data["dwg"] != st["closedDwg"])
        st["closedDwg"] := ""
    if (data["cur"] != "" && data["cur"] != st["curFloor"]) {
        st["curFloor"] := data["cur"]
        st["floor"] := data["cur"]
        st["scroll"] := 0
    }
    if !CablePanelHasFloor(data, st["floor"])
        st["floor"] := data["floors"].Length ? data["floors"][1] : ""
    if (st["floor"] != oldFloor)
        st["view"] := ""
    if (st["closedDwg"] = "")
        CablePanelRender()
}

CablePanelHasFloor(data, floor) {
    for f in data["floors"]
        if (f = floor)
            return true
    return false
}

; 托盘或主面板调用：重新显示
CablePanelOpen(*) {
    global CablePanelPath, CablePanelState
    CablePanelState["closedDwg"] := ""
    if !IsObject(CablePanelState["data"]) && FileExist(CablePanelPath) {
        try CablePanelApply(CablePanelParse(CablePanelDecode(FileRead(CablePanelPath, "RAW"))))
        return
    }
    if IsObject(CablePanelState["data"])
        CablePanelRender()
    else
        TrayTip("还没有总览数据，在 CAD 里运行 DCW 或 DCV 后会自动显示。", "电缆定义总览", "Iconi Mute")
}

CablePanelClose(*) {
    global CablePanelState
    st := CablePanelState
    if IsObject(st["data"])
        st["closedDwg"] := st["data"]["dwg"]
    if !IsObject(st["ui"])
        return
    ui := st["ui"]
    st["ui"] := ""
    st["plan"] := "", st["drag"] := "", st["pick"] := "", st["down"] := ""
    try {
        ; 记住普通大小，下次不要以最大化后的尺寸打开
        if (WinGetMinMax("ahk_id " . ui["gui"].Hwnd) = 1)
            WinRestore("ahk_id " . ui["gui"].Hwnd)
        ui["gui"].GetPos(&x, &y)
        st["pos"] := "x" . x . " y" . y
        size := CablePanelClientSize(ui["gui"].Hwnd)
        st["w"] := size[1], st["h"] := size[2]
    }
    try {
        hwnd := ui["gui"].Hwnd
        ModernPanelReleaseCanvas(ui)
        registry := ModernPanelRegistry()
        if registry.Has(hwnd)
            registry.Delete(hwnd)
        ui["gui"].Destroy()
    }
}

CablePanelSize() {
    global CablePanelState
    return [CablePanelState["w"], CablePanelState["h"]]
}

; 客户区大小（逻辑像素）
CablePanelClientSize(hwnd) {
    rect := Buffer(16, 0)
    DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rect)
    scale := A_ScreenDPI / 96
    return [Round(NumGet(rect, 8, "Int") / scale), Round(NumGet(rect, 12, "Int") / scale)]
}

CablePanelOnSize(guiObj, minMax, *) {
    global CablePanelState
    st := CablePanelState
    if (minMax = -1 || !IsObject(st["ui"]))
        return
    ; 最大化时不置顶，否则点对象跳转后 CAD 会被面板盖住
    WinSetAlwaysOnTop(minMax = 1 ? 0 : 1, "ahk_id " . guiObj.Hwnd)
    size := CablePanelClientSize(guiObj.Hwnd)
    if (size[1] = st["w"] && size[2] = st["h"])
        return
    st["w"] := size[1], st["h"] := size[2]
    CablePanelRender()
}

; 同一个窗口原地重画，不销毁重建，实时刷新时不闪
CablePanelRender() {
    global CablePanelState
    st := CablePanelState
    size := CablePanelSize()
    first := !IsObject(st["ui"])
    if first {
        ui := ModernPanelCreate("电缆定义总览", "+AlwaysOnTop -MinimizeBox +MaximizeBox +Resize +MinSize420x520", true)
        ui["gui"].OnEvent("Close", CablePanelClose)
        ui["gui"].OnEvent("Size", CablePanelOnSize)
        st["ui"] := ui
    }
    ui := st["ui"]
    CablePanelBuild(ui, st["data"], size[1], size[2])
    if first {
        pos := st["pos"] != "" ? st["pos"] : CablePanelDefaultPos(size[1], size[2])
        ui["gui"].Show(pos . " w" . size[1] . " h" . size[2] . " NoActivate")
    }
    ModernPanelInvalidate(ui)
}

; 放在 CAD 主窗口右侧内缘；找不到 CAD 时放在屏幕右上角
CablePanelDefaultPos(width, height) {
    scale := A_ScreenDPI / 96
    w := width * scale, h := height * scale
    MonitorGetWorkArea(MonitorGetPrimary(), &left, &top, &right, &bottom)
    x := right - w - 24 * scale, y := top + 60 * scale
    best := 0
    for exe in ["ZWCAD.exe", "acad.exe"] {
        try list := WinGetList("ahk_exe " . exe)
        catch
            continue
        for hwnd in list {
            try {
                if !(WinGetStyle("ahk_id " . hwnd) & 0x10000000) || WinGetMinMax("ahk_id " . hwnd) = -1
                    continue
                WinGetPos(&cx, &cy, &cw, &ch, "ahk_id " . hwnd)
                if (cw * ch > best && cw > 600 && ch > 400) {
                    best := cw * ch
                    x := cx + cw - w - 40 * scale, y := cy + 110 * scale
                }
            }
        }
        if best
            break
    }
    vl := SysGet(76), vt := SysGet(77), vw := SysGet(78), vh := SysGet(79)
    x := Max(vl, Min(x, vl + vw - w))
    y := Max(vt, Min(y, vt + vh - h - 40 * scale))
    return "x" . Round(x) . " y" . Round(y)
}

CablePanelStateColor(state) {
    static colors := Map("ok", "16A34A", "warn", "D97706", "err", "D32F2F", "todo", "B8BCC4", "skip", "B8BCC4")
    return colors.Has(state) ? colors[state] : "B8BCC4"
}

CablePanelFloorItems(items, floor) {
    res := []
    for item in items
        if (item["floor"] = floor)
            res.Push(item)
    return res
}

; 按名称排序，返回新数组。名称里的换行已被 LSP 清掉，用 `n 作分隔，序号带在名称后面
CablePanelSortByName(items) {
    if (items.Length < 2)
        return items
    text := ""
    for item in items
        text .= item["name"] . "`t" . A_Index . "`n"
    res := []
    for line in StrSplit(Sort(RTrim(text, "`n"), "CLogical"), "`n")
        res.Push(items[Integer(StrSplit(line, "`t")[2])])
    return res
}

CablePanelBuild(ui, data, width, height) {
    global CablePanelState
    st := CablePanelState
    ui["elements"] := []
    ui["hover"] := ""
    ui["pressed"] := ""
    st["pick"] := ""
    ModernPanelBeginPage(ui, "", 16, 14, width - 32)
    ui["current"] := ""
    colors := ModernPanelColors()
    pad := 16, inner := width - pad * 2

    SplitPath(data["dwg"], &dwgName)
    ModernPanelLabelAt(ui, pad, 10, inner, 24, "电缆定义总览", ModernPanelTextStyle(colors["text"], 11, true))
    ModernPanelLabelAt(ui, pad, 34, inner, 18, dwgName . "　" . SubStr(data["time"], -8) . " 更新", ModernPanelTextStyle(colors["secondary"], 9))

    ; 六步状态条
    y := 58, gap := 6
    count := Max(1, data["steps"].Length)
    chipW := (inner - gap * (count - 1)) // count
    for step in data["steps"] {
        x := pad + (A_Index - 1) * (chipW + gap)
        ModernPanelLabelAt(ui, x, y, chipW, 46, "", ModernPanelStyle(colors["info"], colors["text"]))
        ModernPanelLabelAt(ui, x, y, chipW, 3, "", CablePanelBar(CablePanelStateColor(step["state"])))
        ModernPanelLabelAt(ui, x + 2, y + 5, chipW - 4, 18, step["name"], ModernPanelTextStyle(colors["text"], 8, true, "center"))
        ModernPanelLabelAt(ui, x + 2, y + 24, chipW - 4, 18, step["text"], ModernPanelTextStyle(colors["secondary"], 8, false, "center"))
    }

    ; 楼层页签
    y := 112
    x := pad
    for floor in data["floors"] {
        selected := floor = st["floor"]
        tabW := 54
        if (x + tabW > pad + inner - 60)
            break
        label := floor = "" ? "未知" : floor
        if selected {
            ModernPanelAddElement(ui, x, y, tabW, 28, label, CablePanelSized(ModernPanelStyle(colors["navSelected"], colors["accent"], true), colors["tileBorder"]))
        } else {
            ModernPanelAddElement(ui, x, y, tabW, 28, label
                , CablePanelSized(ModernPanelStyle(colors["tile"], colors["text"]), colors["tileBorder"])
                , CablePanelSized(ModernPanelStyle(colors["tileHover"], colors["text"]), colors["tileBorder"])
                , CablePanelPickFloor.Bind(floor))
        }
        x += tabW + 6
    }
    ModernPanelAddElement(ui, pad + inner - 54, y, 54, 28, "全图"
        , CablePanelSized(ModernPanelStyle(colors["tile"], colors["text"]), colors["tileBorder"])
        , CablePanelSized(ModernPanelStyle(colors["tileHover"], colors["text"]), colors["tileBorder"])
        , CablePanelFit)

    rooms := CablePanelFloorItems(data["rooms"], st["floor"])
    cabs := CablePanelFloorItems(data["cabs"], st["floor"])
    routes := CablePanelFloorItems(data["routes"], st["floor"])
    shafts := CablePanelFloorItems(data["shafts"], st["floor"])

    y := 146
    ModernPanelLabelAt(ui, pad + 2, y, inner, 20
        , "房间 " . rooms.Length . "　柜子 " . cabs.Length . "　通道 " . routes.Length . " 条　竖井 " . shafts.Length
        , ModernPanelTextStyle(colors["secondary"], 9))
    ; 图例
    legendX := pad + inner - 142
    for entry in [["FFD97706", "柜子", 8], ["FFD32F2F", "竖井", 8], ["FF60A5FA", "通道", 14]] {
        ModernPanelLabelAt(ui, legendX, y + (entry[3] = 8 ? 6 : 9), entry[3], entry[3] = 8 ? 8 : 2, "", CablePanelDot(SubStr(entry[1], 3)))
        ModernPanelLabelAt(ui, legendX + entry[3] + 3, y, 28, 20, entry[2], ModernPanelTextStyle(colors["secondary"], 8))
        legendX += entry[3] + 37
    }

    ; 平面图：窗口够宽时放左边、列表放右边；否则放上面，多出来的高度都给平面图
    y := 170, wide := width >= 720
    planW := wide ? inner - 312 : inner
    planH := wide ? height - y - 10 : Max(214, height - 546)
    plan := ModernPanelLabelAt(ui, pad, y, planW, planH, "", CablePanelSized(ModernPanelStyle(colors["info"], colors["text"]), colors["tileBorder"]))
    st["plan"] := CablePanelPlanLayout(pad, y, planW, planH, rooms, cabs, routes, shafts)
    plan["draw"] := CablePanelDrawPlan.Bind(st["plan"])
    if (st["plan"]["minX"] = "")
        ModernPanelLabelAt(ui, pad, y, planW, planH, "这一层还没有定义内容", ModernPanelTextStyle(colors["disabled"], 9, false, "center"))

    ; 明细列表：整行滚动，只画完全落在可视区里的行
    listX := wide ? pad + planW + 12 : pad
    listW := wide ? inner - planW - 12 : inner
    top := wide ? y : y + planH + 8
    bottom := height - 10
    rows := CablePanelRows(data, rooms, cabs, routes, shafts)
    total := 0
    for row in rows {
        ; 从平面图点过来的对象，把列表滚到它所在的行
        if (st["reveal"] != "" && row.Has("handle") && row["handle"] = st["reveal"]) {
            st["scroll"] := total - (bottom - top - row["h"]) // 2
            st["reveal"] := ""
        }
        total += row["h"]
    }
    st["reveal"] := ""
    st["maxScroll"] := Max(0, total - (bottom - top))
    st["scroll"] := Min(Max(0, st["scroll"]), st["maxScroll"])
    cursor := top - st["scroll"]
    for row in rows {
        if (cursor >= top && cursor + row["h"] <= bottom)
            CablePanelAddRow(ui, row, listX, cursor, listW - 8, colors)
        cursor += row["h"]
    }
    if st["maxScroll"] {
        viewH := bottom - top
        thumbH := Max(24, viewH * viewH // total)
        thumbY := top + (viewH - thumbH) * st["scroll"] // st["maxScroll"]
        ModernPanelLabelAt(ui, width - pad - 3, thumbY, 3, thumbH, "", CablePanelDot("CBD0D8"))
    }
}

CablePanelDot(color) {
    style := ModernPanelStyle(color, color)
    style["radius"] := 4
    return style
}

; 步骤卡顶部的状态色条
CablePanelBar(color) {
    style := ModernPanelStyle(color, color)
    style["radius"] := 1
    return style
}

CablePanelSized(style, border) {
    style["border"] := border
    style["size"] := 9
    style["padding"] := 2
    return style
}

; 列表内容：房间及其柜子、不在房间的柜子、通道、竖井配对，最后是全图问题
CablePanelRows(data, rooms, cabs, routes, shafts) {
    rows := []
    head(text) => rows.Push(Map("type", "head", "h", 26, "text", text))
    item(text, handle, icon, indent := 0) => rows.Push(Map("type", "item", "h", 25, "text", text, "handle", handle, "icon", icon, "indent", indent))

    if rooms.Length
        head("房间 " . rooms.Length)
    for room in CablePanelSortByName(rooms) {
        inside := []
        for cab in cabs
            if (cab["room"] = room["handle"])
                inside.Push(cab)
        item(room["name"] . "（" . inside.Length . " 台）", room["handle"], Chr(0xE80F))
        for cab in CablePanelSortByName(inside)
            item(cab["name"], cab["handle"], "", 18)
    }
    outside := []
    for cab in cabs
        if (cab["room"] = "")
            outside.Push(cab)
    if outside.Length {
        head((rooms.Length ? "不在任何房间 " : "柜子 ") . outside.Length)
        for cab in CablePanelSortByName(outside)
            item(cab["name"], cab["handle"], "", 18)
    }
    if routes.Length {
        head("通道 " . routes.Length . " 条")
        for route in routes
            item("通道 " . A_Index . "（" . route["segs"] . " 段）", route["handle"], Chr(0xE71B))
    }
    if shafts.Length {
        head("竖井 " . shafts.Length)
        for shaft in CablePanelSortByName(shafts)
            item(shaft["name"] . "　配对：" . CablePanelShaftFloors(data, shaft["base"]), shaft["handle"], Chr(0xE707))
    }
    issues := CablePanelSortIssues(data["issues"])
    if issues.Length {
        head("全图问题 " . issues.Length)
        for issue in issues
            rows.Push(Map("type", "issue", "h", 48, "text", "【" . issue["kind"] . "】" . issue["text"], "handle", issue["handle"], "level", issue["level"]))
    }
    return rows
}

CablePanelShaftFloors(data, base) {
    text := ""
    for floor in data["floors"]
        for shaft in data["shafts"]
            if (shaft["base"] = base && shaft["floor"] = floor) {
                text .= (text = "" ? "" : " ") . floor
                break
            }
    return text
}

CablePanelSortIssues(issues) {
    res := []
    for level in ["err", "warn", "info"]
        for issue in issues
            if (issue["level"] = level)
                res.Push(issue)
    return res
}

CablePanelAddRow(ui, row, x, y, w, colors) {
    static icons := Map("err", Chr(0xE783), "warn", Chr(0xE7BA), "info", Chr(0xE946))
    static iconColors := Map("err", "D32F2F", "warn", "D97706", "info", "6B7280")
    if (row["type"] = "head") {
        ModernPanelLabelAt(ui, x + 2, y + 4, w, 20, row["text"], ModernPanelTextStyle(colors["secondary"], 9, true))
        return
    }
    handle := row["handle"]
    if (row["type"] = "issue") {
        icon := icons.Has(row["level"]) ? icons[row["level"]] : icons["info"]
        iconColor := iconColors.Has(row["level"]) ? iconColors[row["level"]] : iconColors["info"]
        style := ModernPanelDecorate(ModernPanelStyle(colors["info"], colors["text"]), "", icon, iconColor)
        hover := ModernPanelDecorate(ModernPanelStyle(colors["tileHover"], colors["text"]), "", icon, colors["iconHover"])
        ModernPanelAddElement(ui, x, y, w, 44, "", style, handle != "" ? hover : "", handle != "" ? CablePanelClick.Bind(handle) : "")
        text := ModernPanelTextStyle(colors["text"], 9, false, "left", true)
        text["lineLimit"] := true
        ModernPanelLabelAt(ui, x + 42, y + 4, w - 50, 38, row["text"], text)
        return
    }
    selected := handle != "" && handle = CablePanelState["hilite"]
    indent := row["indent"]
    fill := selected ? colors["navSelected"] : "FFFFFF"
    style := ModernPanelStyle(fill, colors["text"], false, "left")
    hover := ModernPanelStyle(colors["tileHover"], colors["text"], false, "left")
    style["size"] := hover["size"] := 9.5
    style["padding"] := hover["padding"] := 8 + indent
    if (row["icon"] != "") {
        ModernPanelDecorate(style, "", row["icon"], colors["icon"])
        ModernPanelDecorate(hover, "", row["icon"], colors["iconHover"])
    }
    ModernPanelAddElement(ui, x, y, w, 24, row["text"], style, hover, CablePanelClick.Bind(handle))
}

CablePanelPickFloor(floor) {
    global CablePanelState
    CablePanelState["floor"] := floor
    CablePanelState["scroll"] := 0
    CablePanelState["view"] := ""
    CablePanelRender()
}

; 鼠标在平面图上滚轮缩放，其余位置滚动列表。滚轮消息的坐标是屏幕坐标
CablePanelOnWheel(wParam, lParam, msg, hwnd) {
    global CablePanelState
    st := CablePanelState
    if !CablePanelIsPanel(hwnd)
        return
    delta := (wParam >> 16) & 0xFFFF
    delta := delta >= 0x8000 ? delta - 0x10000 : delta
    pt := Buffer(8)
    NumPut("Int", (lParam & 0xFFFF) << 48 >> 48, "Int", (lParam >> 16 & 0xFFFF) << 48 >> 48, pt)
    DllCall("ScreenToClient", "Ptr", hwnd, "Ptr", pt)
    scale := A_ScreenDPI / 96
    lx := NumGet(pt, 0, "Int") / scale, ly := NumGet(pt, 4, "Int") / scale
    if (CablePanelInPlan(st["plan"], lx, ly) && st["plan"]["minX"] != "") {
        CablePanelZoomAt(st["plan"], lx, ly, delta > 0 ? 1.25 : 0.8)
        return 0
    }
    if !st["maxScroll"]
        return
    next := Min(Max(0, st["scroll"] + (delta > 0 ? -60 : 60)), st["maxScroll"])
    if (next != st["scroll"]) {
        st["scroll"] := next
        CablePanelRender()
    }
    return 0
}

CablePanelClick(handle) {
    global CablePanelState
    CablePanelState["hilite"] := handle
    CablePanelRender()
    CablePanelLocate(handle)
}

; ---------- 平面图交互 ----------

CablePanelIsPanel(hwnd) {
    global CablePanelState
    return IsObject(CablePanelState["ui"]) && hwnd = CablePanelState["ui"]["gui"].Hwnd
}

; 鼠标消息里的客户区坐标换成逻辑像素
CablePanelMouse(lParam) {
    scale := A_ScreenDPI / 96
    return [((lParam & 0xFFFF) << 48 >> 48) / scale, ((lParam >> 16 & 0xFFFF) << 48 >> 48) / scale]
}

CablePanelInPlan(plan, lx, ly) {
    return IsObject(plan) && lx >= plan["x"] && lx < plan["x"] + plan["w"] && ly >= plan["y"] && ly < plan["y"] + plan["h"]
}

; 平面图的位置、内容和图形范围。范围为空（minX 为空串）表示这一层没有内容
CablePanelPlanLayout(x, y, w, h, rooms, cabs, routes, shafts) {
    minX := "", minY := "", maxX := "", maxY := ""
    grow(px, py) {
        minX := minX = "" ? px : Min(minX, px)
        minY := minY = "" ? py : Min(minY, py)
        maxX := maxX = "" ? px : Max(maxX, px)
        maxY := maxY = "" ? py : Max(maxY, py)
    }
    for room in rooms
        for p in room["pts"]
            grow(p[1], p[2])
    for route in routes
        for p in route["pts"]
            grow(p[1], p[2])
    for cab in cabs
        grow(cab["x"], cab["y"])
    for shaft in shafts
        grow(shaft["x"], shaft["y"])
    return Map("x", x, "y", y, "w", w, "h", h, "rooms", rooms, "cabs", cabs, "routes", routes, "shafts", shafts
        , "minX", minX, "minY", minY, "maxX", maxX, "maxY", maxY)
}

; 当前视图：k 为每图纸单位对应的逻辑像素，(cx, cy) 是框中心对应的图纸坐标。
; 视图按图纸坐标保存，向导新增对象时用户缩放好的画面不跳；没缩放过就一直适应全图
CablePanelPlanXform(plan) {
    global CablePanelState
    fit := Min((plan["w"] - 32) / Max(plan["maxX"] - plan["minX"], 1), (plan["h"] - 32) / Max(plan["maxY"] - plan["minY"], 1))
    view := CablePanelState["view"]
    if IsObject(view)
        return Map("k", view["k"], "cx", view["cx"], "cy", view["cy"], "fit", fit)
    return Map("k", fit, "cx", (plan["minX"] + plan["maxX"]) / 2, "cy", (plan["minY"] + plan["maxY"]) / 2, "fit", fit)
}

CablePanelToWorld(plan, xf, lx, ly) {
    return [xf["cx"] + (lx - plan["x"] - plan["w"] / 2) / xf["k"], xf["cy"] - (ly - plan["y"] - plan["h"] / 2) / xf["k"]]
}

; 框中心不离开图形范围，拖不丢
CablePanelSetView(plan, k, cx, cy) {
    global CablePanelState
    CablePanelState["view"] := Map("k", k
        , "cx", Min(Max(cx, plan["minX"]), plan["maxX"])
        , "cy", Min(Max(cy, plan["minY"]), plan["maxY"]))
    ModernPanelInvalidate(CablePanelState["ui"])
}

; 以鼠标所指的点为中心缩放
CablePanelZoomAt(plan, lx, ly, factor) {
    xf := CablePanelPlanXform(plan)
    world := CablePanelToWorld(plan, xf, lx, ly)
    k := Min(Max(xf["k"] * factor, xf["fit"] / 2), xf["fit"] * 400)
    CablePanelSetView(plan, k
        , world[1] - (lx - plan["x"] - plan["w"] / 2) / k
        , world[2] + (ly - plan["y"] - plan["h"] / 2) / k)
}

CablePanelFit(*) {
    global CablePanelState
    CablePanelState["view"] := ""
    if IsObject(CablePanelState["ui"])
        ModernPanelInvalidate(CablePanelState["ui"])
}

CablePanelSegDist(px, py, a, b) {
    dx := b[1] - a[1], dy := b[2] - a[2]
    len := dx * dx + dy * dy
    t := len = 0 ? 0 : Min(Max(((px - a[1]) * dx + (py - a[2]) * dy) / len, 0), 1)
    return Sqrt((px - a[1] - t * dx) ** 2 + (py - a[2] - t * dy) ** 2)
}

; 射线法；顺便返回多边形面积，有嵌套房间时取小的
CablePanelInPolygon(px, py, pts, &area) {
    inside := false, sum := 0, prev := pts[pts.Length]
    for p in pts {
        sum += prev[1] * p[2] - p[1] * prev[2]
        if ((p[2] > py) != (prev[2] > py) && px < (prev[1] - p[1]) * (py - p[2]) / (prev[2] - p[2]) + p[1])
            inside := !inside
        prev := p
    }
    area := Abs(sum) / 2
    return inside
}

; 鼠标下的对象：先柜子和竖井（取最近的），再通道，最后房间。返回 Map("handle", 句柄, "text", 说明) 或空串
CablePanelPick(plan, lx, ly) {
    if (!CablePanelInPlan(plan, lx, ly) || plan["minX"] = "")
        return ""
    xf := CablePanelPlanXform(plan)
    world := CablePanelToWorld(plan, xf, lx, ly)
    wx := world[1], wy := world[2]
    best := "", bestDist := 8 / xf["k"]
    for cab in plan["cabs"] {
        dist := Sqrt((cab["x"] - wx) ** 2 + (cab["y"] - wy) ** 2)
        if (dist <= bestDist) {
            bestDist := dist
            best := Map("handle", cab["handle"], "text", "柜子　" . cab["name"] . (cab["roomName"] != "" ? "（" . cab["roomName"] . "）" : ""))
        }
    }
    for shaft in plan["shafts"] {
        dist := Sqrt((shaft["x"] - wx) ** 2 + (shaft["y"] - wy) ** 2)
        if (dist <= bestDist) {
            bestDist := dist
            best := Map("handle", shaft["handle"], "text", "竖井　" . shaft["name"])
        }
    }
    if IsObject(best)
        return best
    for index, route in plan["routes"] {
        pts := route["pts"]
        loop pts.Length - 1 {
            if (CablePanelSegDist(wx, wy, pts[A_Index], pts[A_Index + 1]) <= 5 / xf["k"])
                return Map("handle", route["handle"], "text", "通道 " . index . "（" . route["segs"] . " 段）")
        }
    }
    bestArea := ""
    for room in plan["rooms"] {
        if (room["pts"].Length >= 3 && CablePanelInPolygon(wx, wy, room["pts"], &area) && (bestArea = "" || area < bestArea)) {
            bestArea := area
            best := Map("handle", room["handle"], "text", "房间　" . room["name"] . "（" . room["count"] . " 台）")
        }
    }
    return best
}

CablePanelSetPick(pick) {
    global CablePanelState
    st := CablePanelState
    if (IsObject(pick) ? IsObject(st["pick"]) && st["pick"]["handle"] = pick["handle"] : !IsObject(st["pick"]))
        return
    st["pick"] := pick
    ModernPanelInvalidate(st["ui"])
    ; 鼠标直接移出窗口时收不到 WM_MOUSEMOVE，用定时器清掉悬停
    SetTimer(CablePanelCheckPick, IsObject(pick) ? 120 : 0)
}

CablePanelCheckPick() {
    global CablePanelState
    if !IsObject(CablePanelState["ui"]) {
        SetTimer(CablePanelCheckPick, 0)
        return
    }
    windowHwnd := 0
    try MouseGetPos(, , &windowHwnd)
    if (windowHwnd != CablePanelState["ui"]["gui"].Hwnd)
        CablePanelSetPick("")
}

CablePanelOnMouseMove(wParam, lParam, msg, hwnd) {
    global CablePanelState
    st := CablePanelState
    if !CablePanelIsPanel(hwnd)
        return
    mouse := CablePanelMouse(lParam)
    if IsObject(st["drag"]) {
        drag := st["drag"]
        CablePanelSetView(st["plan"], drag["k"]
            , drag["cx"] - (mouse[1] - drag["x"]) / drag["k"]
            , drag["cy"] + (mouse[2] - drag["y"]) / drag["k"])
        return 0
    }
    CablePanelSetPick(CablePanelPick(st["plan"], mouse[1], mouse[2]))
}

CablePanelOnLeftDown(wParam, lParam, msg, hwnd) {
    global CablePanelState
    st := CablePanelState
    if !CablePanelIsPanel(hwnd)
        return
    mouse := CablePanelMouse(lParam)
    pick := CablePanelPick(st["plan"], mouse[1], mouse[2])
    st["down"] := IsObject(pick) ? pick["handle"] : ""
}

; 按下和松开落在同一个对象上才算点击
CablePanelOnLeftUp(wParam, lParam, msg, hwnd) {
    global CablePanelState
    st := CablePanelState
    if !CablePanelIsPanel(hwnd)
        return
    down := st["down"]
    st["down"] := ""
    if (down = "")
        return
    mouse := CablePanelMouse(lParam)
    pick := CablePanelPick(st["plan"], mouse[1], mouse[2])
    if (IsObject(pick) && pick["handle"] = down)
        SetTimer(CablePanelPlanClick.Bind(down), -1)
}

CablePanelPlanClick(handle) {
    global CablePanelState
    CablePanelState["reveal"] := handle
    CablePanelClick(handle)
}

CablePanelOnMiddleDown(wParam, lParam, msg, hwnd) {
    global CablePanelState
    st := CablePanelState
    if !CablePanelIsPanel(hwnd)
        return
    mouse := CablePanelMouse(lParam)
    plan := st["plan"]
    if (!CablePanelInPlan(plan, mouse[1], mouse[2]) || plan["minX"] = "")
        return
    xf := CablePanelPlanXform(plan)
    st["drag"] := Map("x", mouse[1], "y", mouse[2], "k", xf["k"], "cx", xf["cx"], "cy", xf["cy"])
    DllCall("SetCapture", "Ptr", hwnd)
    DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32646, "Ptr")) ; IDC_SIZEALL
    return 0
}

CablePanelOnMiddleUp(wParam, lParam, msg, hwnd) {
    global CablePanelState
    if !IsObject(CablePanelState["drag"])
        return
    CablePanelState["drag"] := ""
    DllCall("ReleaseCapture")
    return 0
}

; 双击中键回到全图，和 CAD 的习惯一致
CablePanelOnMiddleDouble(wParam, lParam, msg, hwnd) {
    global CablePanelState
    if !CablePanelIsPanel(hwnd)
        return
    mouse := CablePanelMouse(lParam)
    if CablePanelInPlan(CablePanelState["plan"], mouse[1], mouse[2]) {
        CablePanelFit()
        return 0
    }
}

CablePanelOnSetCursor(wParam, lParam, msg, hwnd) {
    global CablePanelState
    if (CablePanelIsPanel(hwnd) && (lParam & 0xFFFF) = 1 && IsObject(CablePanelState["pick"])) { ; HTCLIENT
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr")) ; IDC_HAND
        return 1
    }
}

; ---------- 平面图绘制 ----------

; 估算文字宽度：中文占 1 个字宽，ASCII 约 0.6 个。GDI+ 排版时两端还有留白，不加余量就会变成省略号
CablePanelTextWidth(text, em) {
    width := 0
    loop parse text
        width += Ord(A_LoopField) > 127 ? 1 : 0.6
    return (width + 1.5) * em
}

CablePanelRectsHit(a, b) {
    return a[1] < b[3] && b[1] < a[3] && a[2] < b[4] && b[2] < a[4]
}

; 名称放在点的右边，超出框时放到左边；前方有别的点就截短到点之前（绘制时显示省略号），放不下 3 个字就不画。
; 同一列上下挤着的都不画，否则分不清是谁的，继续放大就会显示出来；隔得远的两个长名称相撞时留先排到的。
; 和房间名冲突的不画。返回 [左, 上, 右, 下, 名称] 的数组
CablePanelClearLabels(marks, taken, boxRight, em) {
    res := []
    if (marks.Length > 200)
        return res
    h := em * 1.5, gap := em * 0.7, dot := em * 0.4
    rects := []
    for mark in marks {
        w := CablePanelTextWidth(mark[3], em)
        toRight := mark[1] + gap + w <= boxRight
        for other in marks {
            ahead := (other[1] - mark[1]) * (toRight ? 1 : -1)
            if (ahead > 0 && Abs(other[2] - mark[2]) < h / 2 + dot)
                w := Min(w, ahead - gap - dot)
        }
        x := toRight ? mark[1] + gap : mark[1] - gap - w
        rects.Push(w >= em * 3 ? [x, mark[2] - h / 2, x + w, mark[2] + h / 2, mark[3]] : "")
    }
    for i, rect in rects {
        if !IsObject(rect)
            continue
        clear := true
        for j, other in rects {
            if (i != j && IsObject(other) && CablePanelRectsHit(rect, other)
                && (j < i || Abs(marks[i][1] - marks[j][1]) < em * 3)) {
                clear := false
                break
            }
        }
        if clear
            for block in taken
                if CablePanelRectsHit(rect, block)
                    clear := false
        if clear
            res.Push(rect)
    }
    return res
}

CablePanelPointsBuffer(pts, toX, toY) {
    buf := Buffer(pts.Length * 8)
    for p in pts {
        NumPut("Float", toX(p[1]), buf, (A_Index - 1) * 8)
        NumPut("Float", toY(p[2]), buf, (A_Index - 1) * 8 + 4)
    }
    return buf
}

; 同一楼层按实际比例画进框内，Y 轴朝上。元素：房间灰框、通道蓝线、柜子橙点、竖井红块，选中和鼠标指着的对象加蓝色高亮。
; 每次重画都读当前视图，缩放和拖动只需要刷新窗口，不用重排
CablePanelDrawPlan(plan, graphics, scale) {
    global CablePanelState
    if (plan["minX"] = "")
        return
    rooms := plan["rooms"], cabs := plan["cabs"], routes := plan["routes"], shafts := plan["shafts"]
    hilite := CablePanelState["hilite"]
    hover := IsObject(CablePanelState["pick"]) ? CablePanelState["pick"]["handle"] : ""
    lit := (handle) => handle != "" && (handle = hilite || handle = hover)

    xf := CablePanelPlanXform(plan)
    k := xf["k"] * scale
    boxX := plan["x"] * scale, boxY := plan["y"] * scale, boxW := plan["w"] * scale, boxH := plan["h"] * scale
    toX := (v) => boxX + boxW / 2 + (v - xf["cx"]) * k
    toY := (v) => boxY + boxH / 2 - (v - xf["cy"]) * k

    DllCall("gdiplus\GdipSetClipRect", "Ptr", graphics, "Float", boxX, "Float", boxY, "Float", boxW, "Float", boxH, "Int", 0)

    ; 房间
    fill := 0, roomPen := 0, hiPen := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFFFFFFFF, "Ptr*", &fill)
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFF9CA3AF, "Float", 1 * scale, "Int", 2, "Ptr*", &roomPen)
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFF3B82F6, "Float", 2.5 * scale, "Int", 2, "Ptr*", &hiPen)
    for room in rooms {
        count := room["pts"].Length
        if (count < 3)
            continue
        buf := CablePanelPointsBuffer(room["pts"], toX, toY)
        DllCall("gdiplus\GdipFillPolygon2", "Ptr", graphics, "Ptr", fill, "Ptr", buf, "Int", count)
        DllCall("gdiplus\GdipDrawPolygon", "Ptr", graphics, "Ptr", lit(room["handle"]) ? hiPen : roomPen, "Ptr", buf, "Int", count)
    }
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", fill)

    ; 通道
    routePen := 0
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFF60A5FA, "Float", 1.5 * scale, "Int", 2, "Ptr*", &routePen)
    for route in routes {
        if (route["pts"].Length < 2)
            continue
        buf := CablePanelPointsBuffer(route["pts"], toX, toY)
        DllCall("gdiplus\GdipDrawLines", "Ptr", graphics, "Ptr", lit(route["handle"]) ? hiPen : routePen, "Ptr", buf, "Int", route["pts"].Length)
    }
    DllCall("gdiplus\GdipDeletePen", "Ptr", routePen)

    ; 文字随放大变大，范围 8 到 13 磅；按 0.5 磅取整，字体对象是按字号缓存的
    colors := ModernPanelColors()
    labelSize := Min(13, Round((8 + 1.6 * Ln(Max(1, xf["k"] / xf["fit"])) / Ln(2)) * 2) / 2)
    em := labelSize * scale * 4 / 3
    boxRight := boxX + boxW, boxBottom := boxY + boxH

    ; 房间名放在房间可见部分的顶部居中，放大后房间顶边移出画面时名称还在；放不下就不写
    nameStyle := ModernPanelTextStyle(colors["secondary"], labelSize, false, "center")
    nameH := em * 1.6
    taken := []
    for room in rooms {
        if (room["pts"].Length < 3)
            continue
        x0 := "", x1 := "", y0 := "", y1 := ""
        for p in room["pts"] {
            x0 := x0 = "" ? p[1] : Min(x0, p[1]), x1 := x1 = "" ? p[1] : Max(x1, p[1])
            y0 := y0 = "" ? p[2] : Min(y0, p[2]), y1 := y1 = "" ? p[2] : Max(y1, p[2])
        }
        left := Max(toX(x0), boxX), right := Min(toX(x1), boxRight)
        top := Max(toY(y1), boxY), bottom := Min(toY(y0), boxBottom)
        nameW := CablePanelTextWidth(room["name"], em)
        if (right - left >= nameW && bottom - top >= nameH) {
            ModernPanelDrawElement(graphics, left, top, right - left, nameH, room["name"], nameStyle, scale, false)
            taken.Push([(left + right - nameW) / 2, top, (left + right + nameW) / 2, top + nameH])
        }
    }

    ; 柜子
    dot := 0, r := 3 * scale
    marks := []
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFFD97706, "Ptr*", &dot)
    for cab in cabs {
        px := toX(cab["x"]), py := toY(cab["y"])
        if (px >= boxX && px < boxRight && py >= boxY && py < boxBottom)
            marks.Push([px, py, cab["name"]])
        DllCall("gdiplus\GdipFillEllipse", "Ptr", graphics, "Ptr", dot, "Float", px - r, "Float", py - r, "Float", r * 2, "Float", r * 2)
        if lit(cab["handle"])
            DllCall("gdiplus\GdipDrawEllipse", "Ptr", graphics, "Ptr", hiPen, "Float", px - r * 2, "Float", py - r * 2, "Float", r * 4, "Float", r * 4)
    }
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", dot)

    ; 竖井
    box := 0, s := 4 * scale
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFFD32F2F, "Ptr*", &box)
    for shaft in shafts {
        px := toX(shaft["x"]), py := toY(shaft["y"])
        if (px >= boxX && px < boxRight && py >= boxY && py < boxBottom)
            marks.Push([px, py, shaft["name"]])
        DllCall("gdiplus\GdipFillRectangle", "Ptr", graphics, "Ptr", box, "Float", px - s, "Float", py - s, "Float", s * 2, "Float", s * 2)
        if lit(shaft["handle"])
            DllCall("gdiplus\GdipDrawRectangle", "Ptr", graphics, "Ptr", hiPen, "Float", px - s * 1.8, "Float", py - s * 1.8, "Float", s * 3.6, "Float", s * 3.6)
    }
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", box)
    DllCall("gdiplus\GdipDeletePen", "Ptr", roomPen)
    DllCall("gdiplus\GdipDeletePen", "Ptr", hiPen)

    labelStyle := ModernPanelTextStyle(colors["text"], labelSize)
    for label in CablePanelClearLabels(marks, taken, boxRight, em)
        ModernPanelDrawElement(graphics, label[1], label[2], label[3] - label[1], label[4] - label[2], label[5], labelStyle, scale, false)

    ; 底部提示条：平时是操作说明，鼠标指着对象时显示它的名称
    tip := ModernPanelStyle("E6F7F8FA", colors["secondary"], false, "left")
    tip["size"] := 8.5, tip["padding"] := 8, tip["radius"] := 6
    text := IsObject(CablePanelState["pick"]) ? CablePanelState["pick"]["text"] : "滚轮缩放　中键拖动　点对象跳转到 CAD"
    ModernPanelDrawElement(graphics, boxX + 4 * scale, boxY + boxH - 26 * scale, boxW - 8 * scale, 22 * scale, text, tip, scale, false)
    DllCall("gdiplus\GdipResetClip", "Ptr", graphics)
}

; ---------- 定位 ----------

; 找打开这张图的 CAD 文档。未保存的图 FullName 为空，按文件名比较
CablePanelFindDoc(cadApp, dwg) {
    SplitPath(dwg, &wantName)
    for d in cadApp.Documents {
        full := d.FullName
        if (full != "" ? StrLower(full) = StrLower(dwg) : StrLower(d.Name) = StrLower(wantName))
            return d
    }
    return ""
}

; 只在用户点条目时连接 CAD。CAD 正在执行命令时不发送，避免把文字打进命令提示；AutoCAD 取点时会直接拒绝 COM 调用
CablePanelLocate(handle) {
    global CablePanelState
    title := "电缆定义总览"
    dwg := IsObject(CablePanelState["data"]) ? CablePanelState["data"]["dwg"] : ""
    found := false
    for pair in [["ZWCAD.Application", "ZWCAD.exe"], ["AutoCAD.Application", "acad.exe"]] {
        try cadApp := ComObjActive(pair[1])
        catch
            continue
        found := true
        try {
            doc := CablePanelFindDoc(cadApp, dwg)
            if !IsObject(doc)
                continue
            if (doc.GetVariable("CMDACTIVE") != 0) {
                TrayTip("CAD 正在执行命令，结束当前步骤后再点条目定位。", title, "Iconi Mute")
                return
            }
            if (cadApp.ActiveDocument.Name != doc.Name)
                doc.Activate()
            doc.SendCommand('(ddfd:zoom "' . handle . '")`n')
            try WinActivate("ahk_exe " . pair[2])
            return
        } catch {
            TrayTip("CAD 正忙，结束当前步骤后再点条目定位。", title, "Iconi Mute")
            return
        }
    }
    TrayTip(found ? "这张图没有在 CAD 里打开：`n" . dwg : "没有找到运行中的 CAD。", title, "Iconi Mute")
}
