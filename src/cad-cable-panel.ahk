#Requires AutoHotkey v2.0
; 电缆定义总览：把 cad_cable_wizard.lsp 写的 %TEMP%\DDFD-Cable\overview.txt 实时显示成悬浮面板（不抢焦点）。
; 每 0.2 秒比较文件的修改时间，向导每标一个对象就刷新一次，向导切楼层时面板跟着切。
; 面板只读文件，不连接 CAD；只有点条目时才在 CAD 空闲时发送 (ddfd:zoom "句柄") 定位。
; 文件格式见 LSP 的“定义总览”一节，中望写 UTF-8，AutoCAD 2018 写系统编码，读取时自动识别。
; 依赖 modern-panel-ui.ahk；主面板和独立版都 #Include 本文件，并各自调用 CablePanelInit()。

global CablePanelPath := EnvGet("TEMP") . "\DDFD-Cable\overview.txt"
global CablePanelState := Map("ui", "", "data", "", "floor", "", "curFloor", "", "scroll", 0, "hilite", ""
    , "stamp", 0, "closedDwg", "", "maxScroll", 0, "pos", "")

; 启动时已有的旧文件不弹出，等向导写入新内容
CablePanelInit() {
    global CablePanelPath, CablePanelState
    CablePanelState["stamp"] := CablePanelFileStamp(CablePanelPath)
    OnMessage(0x020A, CablePanelOnWheel)  ; WM_MOUSEWHEEL
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
    try {
        ui["gui"].GetPos(&x, &y)
        st["pos"] := "x" . x . " y" . y
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
    return [440, 760]
}

; 同一个窗口原地重画，不销毁重建，实时刷新时不闪
CablePanelRender() {
    global CablePanelState
    st := CablePanelState
    size := CablePanelSize()
    first := !IsObject(st["ui"])
    if first {
        ui := ModernPanelCreate("电缆定义总览", "+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow", true)
        ui["gui"].OnEvent("Close", CablePanelClose)
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
        if (x + tabW > pad + inner)
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

    ; 平面图
    y := 170, planH := 214
    plan := ModernPanelLabelAt(ui, pad, y, inner, planH, "", CablePanelSized(ModernPanelStyle(colors["info"], colors["text"]), colors["tileBorder"]))
    plan["draw"] := CablePanelDrawPlan.Bind(pad, y, inner, planH, rooms, cabs, routes, shafts, st["hilite"])
    if !(rooms.Length || cabs.Length || routes.Length || shafts.Length)
        ModernPanelLabelAt(ui, pad, y, inner, planH, "这一层还没有定义内容", ModernPanelTextStyle(colors["disabled"], 9, false, "center"))

    ; 明细列表：整行滚动，只画完全落在可视区里的行
    top := y + planH + 8, bottom := height - 10
    rows := CablePanelRows(data, rooms, cabs, routes, shafts)
    total := 0
    for row in rows
        total += row["h"]
    st["maxScroll"] := Max(0, total - (bottom - top))
    st["scroll"] := Min(Max(0, st["scroll"]), st["maxScroll"])
    cursor := top - st["scroll"]
    for row in rows {
        if (cursor >= top && cursor + row["h"] <= bottom)
            CablePanelAddRow(ui, row, pad, cursor, inner - 8, colors)
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
    CablePanelRender()
}

CablePanelOnWheel(wParam, lParam, msg, hwnd) {
    global CablePanelState
    st := CablePanelState
    if (!IsObject(st["ui"]) || hwnd != st["ui"]["gui"].Hwnd || !st["maxScroll"])
        return
    delta := (wParam >> 16) & 0xFFFF
    delta := delta >= 0x8000 ? delta - 0x10000 : delta
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

; ---------- 平面图 ----------

CablePanelPointsBuffer(pts, toX, toY) {
    buf := Buffer(pts.Length * 8)
    for p in pts {
        NumPut("Float", toX(p[1]), buf, (A_Index - 1) * 8)
        NumPut("Float", toY(p[2]), buf, (A_Index - 1) * 8 + 4)
    }
    return buf
}

; 同一楼层按实际比例缩放到框内，Y 轴朝上。元素：房间灰框、通道蓝线、柜子橙点、竖井红块，选中的对象加蓝色高亮
CablePanelDrawPlan(x, y, w, h, rooms, cabs, routes, shafts, hilite, graphics, scale) {
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
    if (minX = "")
        return

    margin := 16 * scale
    boxX := x * scale, boxY := y * scale, boxW := w * scale, boxH := h * scale
    k := Min((boxW - margin * 2) / Max(maxX - minX, 1), (boxH - margin * 2) / Max(maxY - minY, 1))
    offX := boxX + (boxW - (maxX - minX) * k) / 2
    offY := boxY + (boxH + (maxY - minY) * k) / 2
    toX := (v) => offX + (v - minX) * k
    toY := (v) => offY - (v - minY) * k

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
        DllCall("gdiplus\GdipDrawPolygon", "Ptr", graphics, "Ptr", room["handle"] = hilite ? hiPen : roomPen, "Ptr", buf, "Int", count)
    }
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", fill)

    ; 通道
    routePen := 0
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFF60A5FA, "Float", 1.5 * scale, "Int", 2, "Ptr*", &routePen)
    for route in routes {
        if (route["pts"].Length < 2)
            continue
        buf := CablePanelPointsBuffer(route["pts"], toX, toY)
        DllCall("gdiplus\GdipDrawLines", "Ptr", graphics, "Ptr", route["handle"] = hilite ? hiPen : routePen, "Ptr", buf, "Int", route["pts"].Length)
    }
    DllCall("gdiplus\GdipDeletePen", "Ptr", routePen)

    ; 房间名放在外接框中心，框太小就不写
    colors := ModernPanelColors()
    nameStyle := ModernPanelTextStyle(colors["secondary"], 8, false, "center")
    for room in rooms {
        if (room["pts"].Length < 3)
            continue
        x0 := "", x1 := "", y0 := "", y1 := ""
        for p in room["pts"] {
            x0 := x0 = "" ? p[1] : Min(x0, p[1]), x1 := x1 = "" ? p[1] : Max(x1, p[1])
            y0 := y0 = "" ? p[2] : Min(y0, p[2]), y1 := y1 = "" ? p[2] : Max(y1, p[2])
        }
        pw := (x1 - x0) * k, ph := (y1 - y0) * k
        if (pw >= 44 * scale && ph >= 18 * scale)
            ModernPanelDrawElement(graphics, toX(x0), toY(y1), pw, Min(ph, 18 * scale), room["name"], nameStyle, scale, false)
    }

    ; 柜子
    dot := 0, r := 3 * scale
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFFD97706, "Ptr*", &dot)
    for cab in cabs {
        px := toX(cab["x"]), py := toY(cab["y"])
        DllCall("gdiplus\GdipFillEllipse", "Ptr", graphics, "Ptr", dot, "Float", px - r, "Float", py - r, "Float", r * 2, "Float", r * 2)
        if (cab["handle"] = hilite)
            DllCall("gdiplus\GdipDrawEllipse", "Ptr", graphics, "Ptr", hiPen, "Float", px - r * 2, "Float", py - r * 2, "Float", r * 4, "Float", r * 4)
    }
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", dot)

    ; 竖井
    box := 0, s := 4 * scale
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFFD32F2F, "Ptr*", &box)
    for shaft in shafts {
        px := toX(shaft["x"]), py := toY(shaft["y"])
        DllCall("gdiplus\GdipFillRectangle", "Ptr", graphics, "Ptr", box, "Float", px - s, "Float", py - s, "Float", s * 2, "Float", s * 2)
        if (shaft["handle"] = hilite)
            DllCall("gdiplus\GdipDrawRectangle", "Ptr", graphics, "Ptr", hiPen, "Float", px - s * 1.8, "Float", py - s * 1.8, "Float", s * 3.6, "Float", s * 3.6)
    }
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", box)
    DllCall("gdiplus\GdipDeletePen", "Ptr", roomPen)
    DllCall("gdiplus\GdipDeletePen", "Ptr", hiPen)
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
