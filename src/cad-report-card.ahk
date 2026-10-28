#Requires AutoHotkey v2.0
; CAD 结果卡片：中望 CAD 的 BH1/BH2/BHG/BH3/JM 等命令把明细写进 %TEMP%\AA-CAD-Report\report.txt，
; 这里每 0.2 秒检查一次（只比较文件修改时间，开销很小），出现新结果且有明细时，在 CAD 窗口右上角弹出卡片（不抢焦点）。
; 点条目：确认 CAD 空闲后，切到结果所属图纸，发送 (aa:rep-zoom "句柄") 缩放并选中该对象。
; 文件格式（TAB 分隔；中望写 UTF-8，AutoCAD 2018 写系统 ANSI/GBK，读取时自动识别）：AAREPORT/ID/CMD/TIME/DWG/SHORT/SUM 各一行，INFO 说明若干行，
; ITEM 行为“级别 类别 句柄 文字”，级别 err/warn/ok/info。LISP 端见 AA整合版本.lsp 的“AA 结果卡片”。

global CadReportPath := EnvGet("TEMP") . "\AA-CAD-Report\report.txt"
global CadReportLastId := ""
global CadReportLastTime := ""
global CadReportUi := ""
global CadReportData := ""
global CadReportPage := 1

CadReportInit()

CadReportInit() {
    global CadReportPath, CadReportLastId, CadReportLastTime
    ; 启动时已有的旧结果不弹出
    if FileExist(CadReportPath) {
        try CadReportLastTime := FileGetTime(CadReportPath, "M")
        try CadReportLastId := CadReportParse(CadReportReadText(CadReportPath))["id"]
    }
    SetTimer(CadReportPoll, 200)
}

CadReportPoll() {
    global CadReportPath, CadReportLastId, CadReportLastTime
    if !FileExist(CadReportPath)
        return
    try modified := FileGetTime(CadReportPath, "M")
    catch
        return
    if (modified = CadReportLastTime)
        return
    try text := CadReportReadText(CadReportPath)
    catch
        return          ; CAD 正在改名替换文件，下一轮再读
    CadReportLastTime := modified
    data := CadReportParse(text)
    if (data["id"] = "" || data["id"] = CadReportLastId)
        return
    CadReportLastId := data["id"]
    if (data["items"].Length > 0)
        CadReportShow(data)
    else
        CadReportClose()  ; 这次没有问题：收起上一张卡片，免得误看旧结果
}

CadReportReadText(path) {
    ; 合法 UTF-8 按 UTF-8 解码（中望），否则按 CP936 解码（AutoCAD 2018 的 open 只能写系统 ANSI）
    return CadReportDecode(FileRead(path, "RAW"))
}

CadReportDecode(buf) {
    if (buf.Size = 0)
        return ""
    ; MB_ERR_INVALID_CHARS：遇到非法 UTF-8 序列返回 0
    if DllCall("MultiByteToWideChar", "UInt", 65001, "UInt", 8, "Ptr", buf, "Int", buf.Size, "Ptr", 0, "Int", 0)
        return StrGet(buf, buf.Size, "UTF-8")
    return StrGet(buf, buf.Size, "CP936")
}

CadReportParse(text) {
    data := Map("id", "", "cmd", "", "time", "", "dwg", "", "short", "", "sum", "", "info", [], "items", [])
    for line in StrSplit(text, "`n", "`r") {
        parts := StrSplit(line, "`t")
        if (parts.Length < 2)
            continue
        switch parts[1] {
            case "ID": data["id"] := parts[2]
            case "CMD": data["cmd"] := parts[2]
            case "TIME": data["time"] := parts[2]
            case "DWG": data["dwg"] := parts[2]
            case "SHORT": data["short"] := parts[2]
            case "SUM": data["sum"] := parts[2]
            case "INFO": data["info"].Push(parts[2])
            case "ITEM":
                if (parts.Length >= 5)
                    data["items"].Push(Map("level", parts[2], "kind", parts[3], "handle", parts[4], "text", parts[5]))
        }
    }
    ; 问题在前：err → warn → ok → info，同级保持原顺序
    order := Map("err", 1, "warn", 2, "ok", 3, "info", 4)
    sorted := []
    for level in ["err", "warn", "ok", "info"]
        for item in data["items"]
            if (item["level"] = level)
                sorted.Push(item)
    for item in data["items"]
        if !order.Has(item["level"])
            sorted.Push(item)
    data["items"] := sorted
    return data
}

; 自动换行、只画完整行的文字样式
CadReportWrapStyle(color, size := 9, bold := false) {
    style := ModernPanelTextStyle(color, size, bold, "left", true)
    style["lineLimit"] := true
    return style
}

CadReportClose(*) {
    global CadReportUi
    if !IsObject(CadReportUi)
        return
    ui := CadReportUi
    CadReportUi := ""
    try {
        hwnd := ui["gui"].Hwnd
        ModernPanelReleaseCanvas(ui)
        registry := ModernPanelRegistry()
        if registry.Has(hwnd)
            registry.Delete(hwnd)
        ui["gui"].Destroy()
    }
}

CadReportShow(data, page := 1) {
    global CadReportUi, CadReportData, CadReportPage
    static perPage := 8
    static width := 480
    CadReportData := data
    oldPos := ""
    if IsObject(CadReportUi) {
        try {
            CadReportUi["gui"].GetPos(&ox, &oy)
            oldPos := [ox, oy]
        }
        CadReportClose()
    }
    items := data["items"]
    pages := Max(1, Ceil(items.Length / perPage))
    page := Min(Max(page, 1), pages)
    CadReportPage := page

    colors := ModernPanelColors()
    ui := ModernPanelCreate("CAD 结果 · " . data["cmd"], "+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow", true)
    ui["gui"].OnEvent("Close", CadReportClose)
    ui["gui"].OnEvent("Escape", CadReportClose)
    ModernPanelBeginPage(ui, "", 16, 14, width - 32)
    ui["current"] := ""

    ; 标题：命令名；第二行图纸名和时间；再下面是一行汇总（完整统计只留在结果文件里，卡片保持简明）
    SplitPath(data["dwg"], &dwgName)
    ModernPanelLabelAt(ui, 16, 12, width - 32, 24, data["cmd"] . " 结果", ModernPanelTextStyle(colors["text"], 11, true))
    ModernPanelLabelAt(ui, 16, 38, width - 32, 18, dwgName . "　" . data["time"], ModernPanelTextStyle(colors["secondary"], 9))
    y := 62
    if (data["short"] != "") {
        ModernPanelLabelAt(ui, 16, y, width - 32, 38, data["short"], CadReportWrapStyle(colors["text"], 9.5))
        y += 42
    }

    ; 明细：问题在前，点条目定位到图上（没有句柄的不可点）
    counts := Map()
    for item in items
        counts[item["level"]] := (counts.Has(item["level"]) ? counts[item["level"]] : 0) + 1
    head := "明细 " . items.Length . " 条"
    if counts.Has("err")
        head .= "　问题 " . counts["err"]
    if counts.Has("warn")
        head .= "　提醒 " . counts["warn"]
    if (pages > 1)
        head .= "　（第 " . page . "/" . pages . " 页）"
    ModernPanelLabelAt(ui, 22, y, width - 38, 20, head, ModernPanelTextStyle(colors["secondary"], 9, true))
    y += 24
    first := (page - 1) * perPage + 1
    last := Min(items.Length, page * perPage)
    loop last - first + 1 {
        item := items[first + A_Index - 1]
        CadReportAddItem(ui, data, item, 16, y, width - 32, colors)
        y += 52
    }

    ; 说明（不对应图元）
    if (data["info"].Length > 0) {
        y += 4
        ModernPanelLabelAt(ui, 22, y, width - 38, 20, "说明", ModernPanelTextStyle(colors["secondary"], 9, true))
        y += 22
        for info in data["info"] {
            if (A_Index > 4)
                break
            ModernPanelLabelAt(ui, 22, y, width - 38, 36, info, CadReportWrapStyle(colors["secondary"]))
            y += 38
        }
    }

    ; 底部按钮
    y += 6
    ; 翻页只放箭头（窄按钮），把宽度留给“复制全部”和“关闭”
    gap := 10
    x := 16
    if (pages > 1) {
        CadReportButton(ui, x, y, 44, 34, "", () => CadReportShow(CadReportData, CadReportPage - 1), page > 1, Chr(0xE76B), colors)
        x += 44 + gap
        CadReportButton(ui, x, y, 44, 34, "", () => CadReportShow(CadReportData, CadReportPage + 1), page < pages, Chr(0xE76C), colors)
        x += 44 + gap
    }
    bw := (16 + width - 32 - x - gap) // 2
    CadReportButton(ui, x, y, bw, 34, "复制全部", () => CadReportCopy(CadReportAllText(CadReportData), "全部明细"), true, Chr(0xE8C8), colors)
    CadReportButton(ui, x + bw + gap, y, bw, 34, "关闭", CadReportClose, true, Chr(0xE711), colors)
    y += 34 + 14

    CadReportUi := ui
    pos := IsObject(oldPos) ? "x" . oldPos[1] . " y" . oldPos[2] : CadReportDefaultPos(width, y)
    ui["gui"].Show(pos . " w" . width . " h" . y . " NoActivate")
    ModernPanelInvalidate(ui)
}

CadReportAddItem(ui, data, item, x, y, w, colors) {
    static icons := Map("err", Chr(0xE783), "warn", Chr(0xE7BA), "ok", Chr(0xE73E), "info", Chr(0xE946))
    static iconColors := Map("err", "D32F2F", "warn", "D97706", "ok", "16A34A", "info", "6B7280")
    level := item["level"]
    icon := icons.Has(level) ? icons[level] : Chr(0xE946)
    iconColor := iconColors.Has(level) ? iconColors[level] : colors["icon"]
    clickable := item["handle"] != ""
    rowW := w - 46
    style := ModernPanelDecorate(ModernPanelStyle(clickable ? colors["tile"] : colors["info"], colors["text"]), colors["tileBorder"], icon, iconColor)
    if clickable {
        hover := ModernPanelDecorate(ModernPanelStyle(colors["tileHover"], colors["text"]), colors["tileBorder"], icon, colors["iconHover"])
        ModernPanelAddElement(ui, x, y, rowW, 46, "", style, hover, CadReportLocate.Bind(item["handle"]))
    } else {
        ModernPanelAddElement(ui, x, y, rowW, 46, "", style)
    }
    ModernPanelLabelAt(ui, x + 42, y + 5, rowW - 54, 38, "【" . item["kind"] . "】" . item["text"]
        , CadReportWrapStyle(colors["text"]))
    ; 复制这一条
    copyText := CadReportItemText(data, item)
    CadReportButton(ui, x + rowW + 6, y, 40, 46, "", () => CadReportCopy(copyText, "这一条"), true, Chr(0xE8C8), colors)
}

CadReportButton(ui, x, y, w, h, text, callback, enabled, icon, colors) {
    border := colors["tileBorder"]
    if !enabled
        return ModernPanelAddElement(ui, x, y, w, h, text
            , ModernPanelDecorate(ModernPanelStyle(colors["tileDisabled"], colors["disabled"]), border, icon, colors["iconDisabled"]))
    return ModernPanelAddElement(ui, x, y, w, h, text
        , ModernPanelDecorate(ModernPanelStyle(colors["tile"], colors["text"]), border, icon, colors["icon"])
        , ModernPanelDecorate(ModernPanelStyle(colors["tileHover"], colors["text"]), border, icon, colors["iconHover"])
        , callback)
}

; 默认放在 CAD 主窗口（该进程最大的可见窗口）右上角内侧；找不到时放在屏幕右上角。结果限制在屏幕工作区内。
CadReportDefaultPos(width, height) {
    scale := A_ScreenDPI / 96
    w := width * scale, h := height * scale
    MonitorGetWorkArea(MonitorGetPrimary(), &left, &top, &right, &bottom)
    x := right - w - 24 * scale, y := top + 80 * scale
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
    ; 多显示器时 CAD 可能不在主屏：只保证不超出整个虚拟桌面
    vl := SysGet(76), vt := SysGet(77), vw := SysGet(78), vh := SysGet(79)
    x := Max(vl, Min(x, vl + vw - w))
    y := Max(vt, Min(y, vt + vh - h - 40 * scale))
    return "x" . Round(x) . " y" . Round(y)
}

; 复制：单条为“命令｜类别｜文字（图纸、句柄）”；全部为标题、图纸、汇总、完整统计、全部明细（不分页）和说明，方便整段发给别人判断
CadReportItemText(data, item) {
    SplitPath(data["dwg"], &dwgName)
    text := "[" . data["cmd"] . "] " . item["kind"] . "：" . item["text"]
    text .= "（图纸 " . dwgName . (item["handle"] != "" ? "，句柄 " . item["handle"] : "") . "）"
    return text
}

CadReportAllText(data) {
    static levelNames := Map("err", "问题", "warn", "提醒", "ok", "正常", "info", "说明")
    text := "CAD 结果：" . data["cmd"] . "　" . data["time"] . "`r`n"
    text .= "图纸：" . data["dwg"] . "`r`n"
    if (data["short"] != "")
        text .= "汇总：" . data["short"] . "`r`n"
    if (data["sum"] != "")
        text .= "完整统计：" . data["sum"] . "`r`n"
    if (data["items"].Length > 0) {
        text .= "明细（" . data["items"].Length . " 条）：`r`n"
        for item in data["items"] {
            level := levelNames.Has(item["level"]) ? levelNames[item["level"]] : item["level"]
            text .= A_Index . ". [" . level . "] " . item["kind"] . "：" . item["text"]
                . (item["handle"] != "" ? "（句柄 " . item["handle"] . "）" : "") . "`r`n"
        }
    }
    if (data["info"].Length > 0) {
        text .= "说明：`r`n"
        for info in data["info"]
            text .= "- " . info . "`r`n"
    }
    return text
}

CadReportCopy(text, what) {
    A_Clipboard := text
    TrayTip("已复制" . what . "，可以直接粘贴。", "CAD 结果卡片", "Iconi Mute")
}

; 点条目：CAD 空闲时切到结果所属图纸并定位；CAD 正在执行命令时不发送，避免把文字打进命令提示
CadReportLocate(handle) {
    global CadReportData
    title := "CAD 结果卡片"
    cadApp := "", exe := ""
    for pair in [["ZWCAD.Application", "ZWCAD.exe"], ["AutoCAD.Application", "acad.exe"]] {
        try {
            cadApp := ComObjActive(pair[1])
            exe := pair[2]
            break
        }
    }
    if !IsObject(cadApp) {
        TrayTip("没有找到运行中的 CAD。", title, "Iconi Mute")
        return
    }
    try {
        doc := ""
        dwg := IsObject(CadReportData) ? CadReportData["dwg"] : ""
        for d in cadApp.Documents {
            if (dwg != "" && StrLower(d.FullName) = StrLower(dwg)) {
                doc := d
                break
            }
        }
        if !IsObject(doc) {
            TrayTip("结果所属的图纸没有打开：`n" . dwg, title, "Iconi Mute")
            return
        }
        if (doc.GetVariable("CMDACTIVE") != 0) {
            TrayTip("CAD 正在执行命令，请先结束命令（Esc）再点条目。", title, "Iconi Mute")
            return
        }
        if (cadApp.ActiveDocument.FullName != doc.FullName)
            doc.Activate()
        doc.SendCommand('(aa:rep-zoom "' . handle . '")`n')
        try WinActivate("ahk_exe " . exe)
    } catch as err {
        TrayTip("定位失败：" . err.Message, title, "Iconi Mute")
    }
}
