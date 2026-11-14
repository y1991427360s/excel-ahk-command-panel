#Requires AutoHotkey v2.0
; 现代化面板组件，三套主题（ModernPanelTheme("名称") 切换）：
; - pet（默认）：与 Oracle-Sync 桌宠（D:\Syncthing\Oracle-Sync\tools\pets）一脉相承的浅色卡片风格：
;   白底、浅灰描边圆角按钮、左侧 Segoe MDL2 线性图标，悬停浅灰底 + 图标变蓝，信息行浅灰底。
; - light：浅灰底、白色圆角磁贴。
; - glass：仿 iOS 26 液态玻璃，Win11 系统毛玻璃做底，胶囊形半透明按钮 + 高光与边缘反光。
;
; 实现方式：界面不用系统子控件，所有元素（按钮、文字、分隔线）登记为“元素”，统一用 GDI+ 画进一张
; 预乘透明通道（PARGB）的画布，窗口 WM_PAINT 时经 BufferedPaint 原样交给 DWM 合成，半透明才能透出毛玻璃。
; 点击、悬停、手形光标由脚本按坐标自行判断。
; 布局采用“游标流式排版”：先 ModernPanelBeginPage 设定起点，之后的分组、按钮行、说明文字依次向下排。
; 坐标单位均为 96 DPI 下的逻辑像素，绘制时按系统缩放换算。不依赖第三方库，主面板与分享版共用。

ModernPanelTheme(newTheme := "") {
    static theme := "pet"
    if (newTheme != "")
        theme := newTheme
    return theme
}

; 颜色支持 6 位 RGB（不透明）或 8 位 ARGB。
ModernPanelColors() {
    static glass := Map(
        "window", "000000",
        "tile", "80FFFFFF",
        "tileHover", "C8FFFFFF",
        "tileDisabled", "2EFFFFFF",
        "text", "1D1D1F",
        "secondary", "3A3A3C",
        "disabled", "76767B",
        "accent", "E60A84FF",
        "accentText", "FFFFFF",
        "error", "C4001A",
        "separator", "73FFFFFF"
    )
    static light := Map(
        "window", "F2F2F7",
        "tile", "FFFFFF",
        "tileHover", "E5E5EA",
        "tileDisabled", "F7F7FA",
        "text", "1D1D1F",
        "secondary", "86868B",
        "disabled", "C7C7CC",
        "accent", "0A84FF",
        "accentText", "FFFFFF",
        "error", "D70015",
        "separator", "DCDCE1"
    )
    ; 取色与桌宠右键菜单一致
    static pet := Map(
        "window", "FFFFFF",
        "sidebar", "F7F8FA",
        "info", "F7F8FA",
        "tile", "FFFFFF",
        "tileBorder", "E4E6EB",
        "tileHover", "F1F3F6",
        "tileDisabled", "FFFFFF",
        "navSelected", "E8F0FE",
        "text", "1F2329",
        "secondary", "6B7280",
        "disabled", "B8BCC4",
        "icon", "6B7280",
        "iconHover", "3B82F6",
        "iconDisabled", "CBD0D8",
        "accent", "3B82F6",
        "accentText", "FFFFFF",
        "error", "D32F2F",
        "separator", "ECEEF1"
    )
    theme := ModernPanelTheme()
    colors := theme = "glass" ? glass : theme = "light" ? light : pet
    ; 旧主题没有的键补默认值，调用方可统一取色
    for key, value in Map("sidebar", "", "info", colors["tile"], "tileBorder", "", "navSelected", colors["accent"]
        , "icon", colors["secondary"], "iconHover", colors["accent"], "iconDisabled", colors["disabled"])
        if !colors.Has(key)
            colors[key] := value
    return colors
}

ModernPanelArgb(color) {
    value := Integer("0x" . color)
    return StrLen(color) <= 6 ? 0xFF000000 | value : value
}

ModernPanelColorRef(rgb) {
    value := Integer("0x" . rgb) & 0xFFFFFF
    return ((value & 0xFF) << 16) | (value & 0xFF00) | ((value >> 16) & 0xFF)
}

; 当前存活的面板：窗口句柄 → ui。
ModernPanelRegistry() {
    static panels := Map()
    return panels
}

; keep 为真表示常驻小窗（如 CAD 结果卡片）：不清掉别的面板，打开主面板时也不会被清掉，由创建方自己销毁。
ModernPanelCreate(title, options := "+AlwaysOnTop -MinimizeBox -MaximizeBox", keep := false) {
    static hooked := false
    colors := ModernPanelColors()

    ; 普通面板每次只保留一个，释放旧画布；常驻小窗不受影响
    registry := ModernPanelRegistry()
    if !keep {
        stale := []
        for hwnd, oldUi in registry
            if !(oldUi.Has("keep") && oldUi["keep"])
                stale.Push(hwnd)
        ; 旧面板窗口一并销毁：不同面板（如自动化面板与另一个面板）同一时间只显示一个
        for hwnd in stale {
            ModernPanelReleaseCanvas(registry[hwnd])
            try registry[hwnd]["gui"].Destroy()
            registry.Delete(hwnd)
        }
    }

    panel := Gui(options, title)
    panel.BackColor := colors["window"]
    panel.MarginX := 0
    panel.MarginY := 0
    ModernPanelStyleWindow(panel.Hwnd)

    if !hooked {
        OnMessage(0x000F, ModernPanelOnPaint)       ; WM_PAINT
        OnMessage(0x0014, ModernPanelOnEraseBkgnd)  ; WM_ERASEBKGND
        OnMessage(0x0200, ModernPanelOnMouseMove)   ; WM_MOUSEMOVE
        OnMessage(0x0201, ModernPanelOnMouseDown)   ; WM_LBUTTONDOWN
        OnMessage(0x0202, ModernPanelOnMouseUp)     ; WM_LBUTTONUP
        OnMessage(0x0203, ModernPanelOnMouseDown)   ; WM_LBUTTONDBLCLK（窗口类带 CS_DBLCLKS 时第二次按下是这个消息）
        OnMessage(0x0205, ModernPanelOnRightUp)     ; WM_RBUTTONUP
        OnMessage(0x020A, ModernPanelOnMouseWheel)  ; WM_MOUSEWHEEL
        OnMessage(0x0020, ModernPanelOnSetCursor)   ; WM_SETCURSOR
        hooked := true
    }

    ui := Map("gui", panel, "elements", [], "page", "", "x", 0, "y", 0, "w", 0, "current", ""
        , "hover", "", "pressed", "", "canvas", 0, "canvasW", 0, "canvasH", 0, "dirty", true, "keep", keep)
    registry[panel.Hwnd] := ui
    return ui
}

; 隐藏全部非常驻面板（执行按钮功能前调用）。
ModernPanelHideAll() {
    for hwnd, ui in ModernPanelRegistry()
        if !(ui.Has("keep") && ui["keep"])
            try ui["gui"].Hide()
}

; Win11 圆角窗口。玻璃主题：浅色毛玻璃底，客户区整体并入玻璃；浅色主题：标题栏与窗口同色。
ModernPanelStyleWindow(hwnd) {
    colors := ModernPanelColors()
    corner := 2 ; DWMWCP_ROUND
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 33, "Int*", corner, "UInt", 4)
    if (ModernPanelTheme() = "glass") {
        darkMode := 0
        backdrop := 3 ; DWMSBT_TRANSIENTWINDOW（Acrylic）
        margins := Buffer(16, 0xFF)
        try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 20, "Int*", darkMode, "UInt", 4)
        try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 38, "Int*", backdrop, "UInt", 4)
        try DllCall("dwmapi\DwmExtendFrameIntoClientArea", "Ptr", hwnd, "Ptr", margins)
        return
    }
    caption := ModernPanelColorRef(colors["window"])
    captionText := ModernPanelColorRef(colors["text"])
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 34, "UInt*", caption, "UInt", 4)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 35, "UInt*", caption, "UInt", 4)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "UInt", 36, "UInt*", captionText, "UInt", 4)
}

ModernPanelBeginPage(ui, page, x, y, w) {
    ui["page"] := page
    ui["x"] := x
    ui["y"] := y
    ui["w"] := w
}

; 登记一个元素。style/hoverStyle 见 ModernPanelStyle；onClick 为无参可调用对象，为空表示不可点击。
ModernPanelAddElement(ui, x, y, w, h, text, style, hoverStyle := "", onClick := "") {
    element := Map("x", x, "y", y, "w", w, "h", h, "text", text, "style", style
        , "hover", hoverStyle, "onClick", onClick, "page", ui["page"])
    ui["elements"].Push(element)
    ui["dirty"] := true
    return element
}

; 带底色的磁贴样式。fill 为空表示只画文字。
ModernPanelStyle(fill, textColor, bold := false, align := "center") {
    return Map("fill", fill, "text", textColor, "bold", bold, "align", align, "size", 10, "wrap", false, "radius", ""
        , "border", "", "icon", "", "iconColor", "")
}

; 给样式加描边和左侧图标（Segoe MDL2 Assets 字形，如 Chr(0xE710)）。返回同一个样式便于链式书写。
ModernPanelDecorate(style, border := "", icon := "", iconColor := "") {
    style["border"] := border
    style["icon"] := icon
    style["iconColor"] := iconColor
    if (icon != "")
        style["align"] := "left"
    return style
}

; 纯文字样式（透明底），wrap 为真时自动换行并顶部对齐。
ModernPanelTextStyle(textColor, size := 10, bold := false, align := "left", wrap := false) {
    style := ModernPanelStyle("", textColor, bold, align)
    style["size"] := size
    style["wrap"] := wrap
    return style
}

; 在指定位置放一块文字或色块（不可点击）。
ModernPanelLabelAt(ui, x, y, w, h, text, style) {
    return ModernPanelAddElement(ui, x, y, w, h, text, style)
}

ModernPanelSection(ui, title) {
    colors := ModernPanelColors()
    ModernPanelLabelAt(ui, ui["x"] + 6, ui["y"], ui["w"] - 6, 20, title, ModernPanelTextStyle(colors["secondary"], 9, true))
    ui["y"] += 24
}

; 一行按钮，按数量平分宽度。每项为 [文字, 回调, 是否可用(可省略), 图标字形(可省略)]。
ModernPanelRow(ui, items*) {
    gap := 10
    tileWidth := (ui["w"] - gap * (items.Length - 1)) // items.Length
    x := ui["x"]
    for item in items {
        enabled := item.Length >= 3 ? item[3] : true
        icon := item.Length >= 4 ? item[4] : ""
        ModernPanelTile(ui, x, ui["y"], tileWidth, 38, item[1], item[2], enabled, icon)
        x += tileWidth + gap
    }
    ui["y"] += 46
}

ModernPanelSpace(ui, height := 10) {
    ui["y"] += height
}

ModernPanelTile(ui, x, y, w, h, text, callback, enabled := true, icon := "") {
    colors := ModernPanelColors()
    border := colors["tileBorder"]
    if !enabled
        return ModernPanelAddElement(ui, x, y, w, h, text
            , ModernPanelDecorate(ModernPanelStyle(colors["tileDisabled"], colors["disabled"]), border, icon, colors["iconDisabled"]))
    return ModernPanelAddElement(ui, x, y, w, h, text
        , ModernPanelDecorate(ModernPanelStyle(colors["tile"], colors["text"]), border, icon, colors["icon"])
        , ModernPanelDecorate(ModernPanelStyle(colors["tileHover"], colors["text"]), border, icon, colors["iconHover"])
        , () => RunPanelCommand(callback))
}

; 圆角信息卡（不可点击），左对齐，长文本以省略号结尾。
ModernPanelCard(ui, text, textColor := "", icon := "") {
    colors := ModernPanelColors()
    card := ModernPanelLabelAt(ui, ui["x"], ui["y"], ui["w"], 38, text
        , ModernPanelDecorate(ModernPanelStyle(colors["info"], textColor != "" ? textColor : colors["text"], false, "left")
            , "", icon, colors["icon"]))
    ui["y"] += 50
    return card
}

ModernPanelNote(ui, text, lines := 2) {
    colors := ModernPanelColors()
    height := lines * 20
    note := ModernPanelLabelAt(ui, ui["x"] + 6, ui["y"], ui["w"] - 6, height, text
        , ModernPanelTextStyle(colors["secondary"], 9, false, "left", true))
    ui["y"] += height + 8
    return note
}

ModernPanelShowPage(ui, page) {
    ui["current"] := page
    ui["hover"] := ""
    ModernPanelInvalidate(ui)
}

ModernPanelInvalidate(ui) {
    ui["dirty"] := true
    try DllCall("InvalidateRect", "Ptr", ui["gui"].Hwnd, "Ptr", 0, "Int", false)
}

ModernPanelSame(a, b) {
    if IsObject(a)
        return IsObject(b) && ObjPtr(a) = ObjPtr(b)
    return !IsObject(b) && a = b
}

; 元素设 hidden 为真时不画也不响应（如搜索时被筛掉的卡片）。
ModernPanelIsVisible(ui, element) {
    if (element.Has("hidden") && element["hidden"])
        return false
    return element["page"] = "" || element["page"] = ui["current"]
}

; ---------- 绘制 ----------

ModernPanelGdiplusStart() {
    static token := 0
    if token
        return
    DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
    input := Buffer(24, 0)
    NumPut("UInt", 1, input)
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", input, "Ptr", 0)
}

ModernPanelFont(size, bold, familyName := "Microsoft YaHei UI") {
    static fonts := Map()
    static families := Map()
    key := familyName . "|" . size . "|" . bold . "|" . A_ScreenDPI
    if fonts.Has(key)
        return fonts[key]
    if !families.Has(familyName) {
        created := 0
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", familyName, "Ptr", 0, "Ptr*", &created)
        families[familyName] := created
    }
    family := families[familyName]
    font := 0
    DllCall("gdiplus\GdipCreateFont", "Ptr", family, "Float", size * A_ScreenDPI / 72, "Int", bold ? 1 : 0, "Int", 2, "Ptr*", &font)
    fonts[key] := font
    return font
}

ModernPanelReleaseCanvas(ui) {
    if ui["canvas"]
        DllCall("DeleteObject", "Ptr", ui["canvas"])
    ui["canvas"] := 0
}

; 把当前页所有元素画进一张 PARGB 画布（DIB 段）。
ModernPanelRender(ui, width, height) {
    ModernPanelGdiplusStart()
    isGlass := ModernPanelTheme() = "glass"
    colors := ModernPanelColors()
    scale := A_ScreenDPI / 96

    info := Buffer(40, 0)
    NumPut("UInt", 40, info, 0)
    NumPut("Int", width, info, 4)
    NumPut("Int", -height, info, 8)   ; 自上而下
    NumPut("UShort", 1, info, 12)
    NumPut("UShort", 32, info, 14)
    bits := 0
    canvas := DllCall("CreateDIBSection", "Ptr", 0, "Ptr", info, "UInt", 0, "Ptr*", &bits, "Ptr", 0, "UInt", 0, "Ptr")
    if !canvas
        return

    bitmap := 0, graphics := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", width, "Int", height, "Int", width * 4, "Int", 0xE200B, "Ptr", bits, "Ptr*", &bitmap) ; PARGB
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bitmap, "Ptr*", &graphics)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", graphics, "Int", 4)                       ; AntiAlias
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", graphics, "Int", isGlass ? 4 : 5)    ; 透明底不能用 ClearType
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", graphics, "UInt", isGlass ? 0x00000000 : ModernPanelArgb(colors["window"]))

    dragged := ModernPanelDragged(ui)
    for element in ui["elements"] {
        if (!ModernPanelIsVisible(ui, element) || ModernPanelSame(element, dragged))
            continue
        ModernPanelRenderElement(ui, graphics, element, scale, isGlass)
    }
    ; 滚动区右侧的细滚动条
    if ui.Has("scrolls") {
        for name, region in ui["scrolls"] {
            if (region["page"] != ui["current"] || region["max"] <= 0)
                continue
            viewH := region["bottom"] - region["top"]
            barH := Max(28, viewH * viewH / (viewH + region["max"]))
            barY := region["top"] + (viewH - barH) * region["offset"] / region["max"]
            bar := ModernPanelRoundPath((region["right"] + 5) * scale, barY * scale, 4 * scale, barH * scale, 2 * scale)
            ModernPanelFillPath(graphics, bar, 0x40000000 | 0x6B7280)
            DllCall("gdiplus\GdipDeletePath", "Ptr", bar)
        }
    }
    ; 拖动中的元素最后画，浮在最上层且不受滚动区裁剪
    if IsObject(dragged)
        ModernPanelRenderElement(ui, graphics, dragged, scale, isGlass, true)

    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", graphics)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bitmap)
    ModernPanelReleaseCanvas(ui)
    ui["canvas"] := canvas
    ui["canvasW"] := width
    ui["canvasH"] := height
    ui["dirty"] := false
}

ModernPanelRenderElement(ui, graphics, element, scale, isGlass, isDragged := false) {
    region := ModernPanelScrollRegion(ui, element)
    offset := IsObject(region) ? region["offset"] : 0
    y := element["y"] - offset
    if (IsObject(region) && !isDragged) {
        if (y + element["h"] + 12 < region["top"] || y - 12 > region["bottom"])
            return
        ; 上下各留 8 像素给投影
        DllCall("gdiplus\GdipSetClipRectI", "Ptr", graphics, "Int", Round((region["left"] - 10) * scale), "Int", Round((region["top"] - 8) * scale)
            , "Int", Round((region["right"] - region["left"] + 20) * scale), "Int", Round((region["bottom"] - region["top"] + 16) * scale), "Int", 0)
    }
    if (isDragged && element.Has("dragStyle"))
        style := element["dragStyle"]
    else
        style := (ModernPanelSame(element, ui["hover"]) && IsObject(element["hover"])) ? element["hover"] : element["style"]
    ModernPanelDrawElement(graphics, element["x"] * scale, y * scale, element["w"] * scale, element["h"] * scale
        , element["text"], style, scale, isGlass)
    ; 自绘元素（如电缆总览的平面图）：回调收到 GDI+ 图形对象和缩放比例
    if element.Has("draw")
        element["draw"](graphics, scale)
    if (IsObject(region) && !isDragged)
        DllCall("gdiplus\GdipResetClip", "Ptr", graphics)
}

; ---------- 滚动区、拖动与动画 ----------

; 登记一个可滚动区域（逻辑像素）。元素设 element["scroll"] := name 即归入该区，y 为内容坐标。
ModernPanelAddScrollRegion(ui, name, page, left, top, right, bottom, contentBottom) {
    if !ui.Has("scrolls")
        ui["scrolls"] := Map()
    ui["scrolls"][name] := Map("page", page, "left", left, "top", top, "right", right, "bottom", bottom
        , "offset", 0, "max", Max(0, contentBottom - bottom))
}

ModernPanelScrollRegion(ui, element) {
    if (element.Has("scroll") && ui.Has("scrolls") && ui["scrolls"].Has(element["scroll"]))
        return ui["scrolls"][element["scroll"]]
    return ""
}

ModernPanelScrollBy(ui, region, delta) {
    newOffset := Min(region["max"], Max(0, region["offset"] + delta))
    if (newOffset = region["offset"])
        return false
    region["offset"] := newOffset
    ModernPanelInvalidate(ui)
    return true
}

ModernPanelDragged(ui) {
    return (ui.Has("drag") && IsObject(ui["drag"])) ? ui["drag"]["element"] : ""
}

; 鼠标位置（逻辑像素）。
ModernPanelMousePoint(lParam) {
    scale := A_ScreenDPI / 96
    return [((lParam & 0xFFFF) << 48 >> 48) / scale, ((lParam >> 16 & 0xFFFF) << 48 >> 48) / scale]
}

; 元素设 tx/ty 目标坐标后调用：定时器让它们缓动过去（拖动排序时其他卡片让位）。
ModernPanelAnimate(ui) {
    if (ui.Has("animTimer") && IsObject(ui["animTimer"]))
        return
    ui["animTimer"] := ModernPanelAnimateStep.Bind(ui)
    SetTimer(ui["animTimer"], 15)
}

ModernPanelAnimateStep(ui) {
    moving := false
    dragged := ModernPanelDragged(ui)
    for element in ui["elements"] {
        if (!element.Has("tx") || ModernPanelSame(element, dragged))
            continue
        dx := element["tx"] - element["x"], dy := element["ty"] - element["y"]
        if (Abs(dx) < 0.6 && Abs(dy) < 0.6) {
            element["x"] := element["tx"], element["y"] := element["ty"]
            continue
        }
        element["x"] += dx * 0.32, element["y"] += dy * 0.32
        moving := true
    }
    ModernPanelInvalidate(ui)
    if !moving {
        SetTimer(ui["animTimer"], 0)
        ui["animTimer"] := ""
    }
}

ModernPanelOnMouseWheel(wParam, lParam, msg, hwnd) {
    registry := ModernPanelRegistry()
    if !registry.Has(hwnd)
        return
    ui := registry[hwnd]
    if !ui.Has("scrolls")
        return
    delta := (wParam >> 16) << 48 >> 48
    for name, region in ui["scrolls"]
        if (region["page"] = ui["current"] && region["max"] > 0) {
            ModernPanelScrollBy(ui, region, -delta / 120 * 56)
            return 0
        }
}

ModernPanelRoundPath(x, y, w, h, radius) {
    path := 0
    diameter := Min(radius * 2, w, h)
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &path)
    if (diameter <= 0) {
        DllCall("gdiplus\GdipAddPathRectangle", "Ptr", path, "Float", x, "Float", y, "Float", w, "Float", h)
        return path
    }
    right := x + w - diameter
    bottom := y + h - diameter
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x, "Float", y, "Float", diameter, "Float", diameter, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", right, "Float", y, "Float", diameter, "Float", diameter, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", right, "Float", bottom, "Float", diameter, "Float", diameter, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x, "Float", bottom, "Float", diameter, "Float", diameter, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", path)
    return path
}

ModernPanelFillPath(graphics, path, argb) {
    brush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &brush)
    DllCall("gdiplus\GdipFillPath", "Ptr", graphics, "Ptr", brush, "Ptr", path)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
}

; 线性渐变画刷。mode：1 竖直，2 左上到右下。
ModernPanelGradientBrush(x, y, w, h, argbStart, argbEnd, mode) {
    brush := 0
    rect := Buffer(16)
    NumPut("Float", x, "Float", y, "Float", w, "Float", h, rect)
    DllCall("gdiplus\GdipCreateLineBrushFromRect", "Ptr", rect, "UInt", argbStart, "UInt", argbEnd, "Int", mode, "Int", 0, "Ptr*", &brush)
    return brush
}

; 液态玻璃质感：底部细阴影、半透明主体、顶部高光、渐变边缘反光。
ModernPanelDrawGlassShape(graphics, x, y, width, height, radius, fillArgb, scale) {
    inset := 0.5 * scale
    bodyX := x + inset
    bodyY := y + inset
    bodyW := width - inset * 2
    bodyH := height - inset * 2 - 1.5 * scale
    if (radius < 0)
        radius := bodyH / 2

    shadow := ModernPanelRoundPath(bodyX, bodyY + 1.5 * scale, bodyW, bodyH, radius)
    ModernPanelFillPath(graphics, shadow, 0x1F000000)
    DllCall("gdiplus\GdipDeletePath", "Ptr", shadow)

    body := ModernPanelRoundPath(bodyX, bodyY, bodyW, bodyH, radius)
    ModernPanelFillPath(graphics, body, fillArgb)

    ; 顶部高光：只在玻璃形状内部，自上而下淡出。
    DllCall("gdiplus\GdipSetClipPath", "Ptr", graphics, "Ptr", body, "Int", 0)
    gloss := ModernPanelGradientBrush(bodyX, bodyY - 1, bodyW, bodyH * 0.55 + 1, 0x80FFFFFF, 0x00FFFFFF, 1)
    DllCall("gdiplus\GdipFillRectangle", "Ptr", graphics, "Ptr", gloss, "Float", bodyX, "Float", bodyY, "Float", bodyW, "Float", bodyH * 0.55)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", gloss)
    DllCall("gdiplus\GdipResetClip", "Ptr", graphics)

    ; 边缘内发光：光从左上方（约 -120°）照来，亮边一侧有一圈柔和的光晕。
    DllCall("gdiplus\GdipSetClipPath", "Ptr", graphics, "Ptr", body, "Int", 0)
    glowBrush := ModernPanelGradientBrush(bodyX, bodyY, bodyW, bodyH, 0x59FFFFFF, 0x00FFFFFF, 2)
    glowPen := 0
    DllCall("gdiplus\GdipCreatePen2", "Ptr", glowBrush, "Float", 5 * scale, "Int", 2, "Ptr*", &glowPen)
    DllCall("gdiplus\GdipDrawPath", "Ptr", graphics, "Ptr", glowPen, "Ptr", body)
    DllCall("gdiplus\GdipDeletePen", "Ptr", glowPen)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", glowBrush)
    DllCall("gdiplus\GdipResetClip", "Ptr", graphics)

    ; 边缘反光：左上亮、右下暗，模拟光线在玻璃边缘折射。
    rimBrush := ModernPanelGradientBrush(bodyX, bodyY, bodyW, bodyH, 0xFFFFFFFF, 0x4DFFFFFF, 2)
    pen := 0
    DllCall("gdiplus\GdipCreatePen2", "Ptr", rimBrush, "Float", 1.2 * scale, "Int", 2, "Ptr*", &pen)
    DllCall("gdiplus\GdipDrawPath", "Ptr", graphics, "Ptr", pen, "Ptr", body)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", rimBrush)
    DllCall("gdiplus\GdipDeletePath", "Ptr", body)
}

ModernPanelDrawElement(graphics, x, y, width, height, text, style, scale, isGlass) {
    ; 柔和投影：样式带 shadow（1 常态、2 悬停、3 拖动中），在底色之下画几层逐渐外扩的半透明圆角矩形
    if (style.Has("shadow") && style["shadow"] > 0 && style["fill"] != "") {
        level := style["shadow"]
        base := level = 1 ? 0x14 : level = 2 ? 0x22 : 0x34
        radius := (style["radius"] != "" ? style["radius"] : 8) * scale
        offsetY := (level + 0.5) * scale
        loop 4 {
            k := 5 - A_Index
            expand := k * 1.6 * scale
            alpha := Round(base * (5 - k) / 10)
            path := ModernPanelRoundPath(x - expand, y - expand + offsetY, width + expand * 2, height + expand * 2, radius + expand)
            ModernPanelFillPath(graphics, path, (alpha << 24) | 0x1F2937)
            DllCall("gdiplus\GdipDeletePath", "Ptr", path)
        }
    }
    if (style["fill"] != "") {
        fillArgb := ModernPanelArgb(style["fill"])
        if (style["radius"] != "")
            radius := style["radius"] * scale
        else
            radius := isGlass ? -1 : 8 * scale  ; 玻璃主题用胶囊形
        if (radius = 0) {
            path := ModernPanelRoundPath(x, y, width, height, 0)  ; 分隔线等直角色块
            ModernPanelFillPath(graphics, path, fillArgb)
            DllCall("gdiplus\GdipDeletePath", "Ptr", path)
        } else if isGlass {
            ModernPanelDrawGlassShape(graphics, x, y, width, height, radius, fillArgb, scale)
        } else {
            path := ModernPanelRoundPath(x + 0.5, y + 0.5, width - 1, height - 1, radius)
            ModernPanelFillPath(graphics, path, fillArgb)
            if (style["border"] != "") {
                pen := 0
                DllCall("gdiplus\GdipCreatePen1", "UInt", ModernPanelArgb(style["border"]), "Float", 1 * scale, "Int", 2, "Ptr*", &pen)
                DllCall("gdiplus\GdipDrawPath", "Ptr", graphics, "Ptr", pen, "Ptr", path)
                DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
            }
            DllCall("gdiplus\GdipDeletePath", "Ptr", path)
        }
    }

    hasImage := style.Has("image") && style["image"]
    hasFolder := style.Has("folder") && style["folder"] != ""
    if (text = "" && style["icon"] = "" && !hasImage && !hasFolder)
        return
    format := 0, textBrush := 0
    ; 0x1000 NoWrap；样式带 lineLimit 时换行文字只画完整的行（0x2000 LineLimit），放不下的以省略号结尾
    formatFlags := style["wrap"] ? ((style.Has("lineLimit") && style["lineLimit"]) ? 0x2000 : 0) : 0x1000
    DllCall("gdiplus\GdipCreateStringFormat", "Int", formatFlags, "Int", 0, "Ptr*", &format)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", format, "Int", style["align"] = "left" ? 0 : 1)
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", format, "Int", style["wrap"] ? 0 : 1)
    DllCall("gdiplus\GdipSetStringFormatTrimming", "Ptr", format, "Int", 3)   ; EllipsisCharacter
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", ModernPanelArgb(style["text"]), "Ptr*", &textBrush)
    if style.Has("padding")
        padding := style["padding"] * scale
    else if (style["fill"] = "")
        padding := 0
    else
        padding := style["align"] = "left" ? 14 * scale : 6 * scale
    textHeight := height - ((isGlass && style["fill"] != "") ? 1.5 * scale : 0)
    ; 左侧图标（Segoe MDL2 Assets），文字随之右移，与桌宠菜单的图标列一致
    iconOffset := 0
    ; 图片图标（GDI+ 位图，如软件自身的图标）或彩色文件夹图标，尺寸 imageSize（逻辑像素）
    if (hasImage || hasFolder) {
        imageSize := (style.Has("imageSize") ? style["imageSize"] : 24) * scale
        imageX := x + padding
        imageY := y + (height - imageSize) / 2
        if hasImage {
            DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", graphics, "Int", 7)   ; HighQualityBicubic
            DllCall("gdiplus\GdipDrawImageRect", "Ptr", graphics, "Ptr", style["image"]
                , "Float", imageX, "Float", imageY, "Float", imageSize, "Float", imageSize)
        } else {
            ModernPanelDrawFolderIcon(graphics, imageX, imageY, imageSize, ModernPanelArgb(style["folder"]))
        }
        iconOffset := imageSize + 10 * scale
    } else if (style["icon"] != "") {
        iconBrush := 0, iconFormat := 0
        DllCall("gdiplus\GdipCreateStringFormat", "Int", 0x1000, "Int", 0, "Ptr*", &iconFormat)
        DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", iconFormat, "Int", 1)
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", iconFormat, "Int", 1)
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", ModernPanelArgb(style["iconColor"] != "" ? style["iconColor"] : style["text"]), "Ptr*", &iconBrush)
        iconLayout := Buffer(16)
        NumPut("Float", x + padding, "Float", y, "Float", 18 * scale, "Float", textHeight, iconLayout)
        DllCall("gdiplus\GdipDrawString", "Ptr", graphics, "WStr", style["icon"], "Int", -1
            , "Ptr", ModernPanelFont(10.5, false, "Segoe MDL2 Assets"), "Ptr", iconLayout, "Ptr", iconFormat, "Ptr", iconBrush)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", iconBrush)
        DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", iconFormat)
        iconOffset := 28 * scale
    }
    layout := Buffer(16)
    textX := x + padding + iconOffset
    textW := width - padding * 2 - iconOffset
    subtext := style.Has("subtext") ? style["subtext"] : ""
    if (subtext != "") {
        ; 两行：主文字贴下半区上沿，副文字（如快捷键）在下
        middle := y + textHeight * 0.56
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", format, "Int", 2)
        NumPut("Float", textX, "Float", y, "Float", textW, "Float", middle - y, layout)
        DllCall("gdiplus\GdipDrawString", "Ptr", graphics, "WStr", text, "Int", -1, "Ptr", ModernPanelFont(style["size"], style["bold"])
            , "Ptr", layout, "Ptr", format, "Ptr", textBrush)
        subBrush := 0
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", ModernPanelArgb(style.Has("subColor") ? style["subColor"] : style["text"]), "Ptr*", &subBrush)
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", format, "Int", 0)
        NumPut("Float", textX, "Float", middle + 1 * scale, "Float", textW, "Float", y + textHeight - middle, layout)
        DllCall("gdiplus\GdipDrawString", "Ptr", graphics, "WStr", subtext, "Int", -1, "Ptr", ModernPanelFont(8.5, false)
            , "Ptr", layout, "Ptr", format, "Ptr", subBrush)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", subBrush)
    } else {
        NumPut("Float", textX, "Float", y, "Float", textW, "Float", textHeight, layout)
        DllCall("gdiplus\GdipDrawString", "Ptr", graphics, "WStr", text, "Int", -1, "Ptr", ModernPanelFont(style["size"], style["bold"])
            , "Ptr", layout, "Ptr", format, "Ptr", textBrush)
    }
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", textBrush)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", format)
}

; 彩色文件夹图标：后片（带标签页）用主色，前片用主色提亮，size 为外接正方形边长（设备像素）。
ModernPanelDrawFolderIcon(graphics, x, y, size, argb) {
    alpha := (argb >> 24) & 0xFF
    r := (argb >> 16) & 0xFF, g := (argb >> 8) & 0xFF, b := argb & 0xFF
    light :=(alpha << 24) | (Round(r + (255 - r) * 0.28) << 16) | (Round(g + (255 - g) * 0.28) << 8) | Round(b + (255 - b) * 0.28)
    top := y + size * 0.16
    height := size * 0.70
    ; 后片：左上角带一个小标签
    back := ModernPanelRoundPath(x, top, size, height, size * 0.12)
    ModernPanelFillPath(graphics, back, argb)
    DllCall("gdiplus\GdipDeletePath", "Ptr", back)
    tab := ModernPanelRoundPath(x, top - size * 0.10, size * 0.44, size * 0.22, size * 0.08)
    ModernPanelFillPath(graphics, tab, argb)
    DllCall("gdiplus\GdipDeletePath", "Ptr", tab)
    ; 前片
    front := ModernPanelRoundPath(x, top + size * 0.17, size, height - size * 0.17, size * 0.12)
    ModernPanelFillPath(graphics, front, light)
    DllCall("gdiplus\GdipDeletePath", "Ptr", front)
}

; 取文件或文件夹的系统图标（48px，带透明通道）转成 GDI+ 位图，按路径缓存；失败返回 0。
ModernPanelFileIcon(path) {
    static cache := Map()
    key := StrLower(path)
    if cache.Has(key)
        return cache[key]
    ModernPanelGdiplusStart()
    bitmap := 0
    try {
        info := Buffer(A_PtrSize + 8 + 520 + 160, 0)
        if DllCall("shell32\SHGetFileInfoW", "WStr", path, "UInt", 0, "Ptr", info, "UInt", info.Size, "UInt", 0x4000, "UPtr") { ; SHGFI_SYSICONINDEX
            index := NumGet(info, A_PtrSize, "Int")
            iid := Buffer(16)
            DllCall("ole32\CLSIDFromString", "WStr", "{46EB5926-582E-4017-9FDF-E8998DAA0950}", "Ptr", iid)
            imageList := 0
            if (DllCall("shell32\SHGetImageList", "Int", 2, "Ptr", iid, "Ptr*", &imageList) = 0 && imageList) { ; SHIL_EXTRALARGE
                hIcon := DllCall("comctl32\ImageList_GetIcon", "Ptr", imageList, "Int", index, "UInt", 1, "Ptr")
                ObjRelease(imageList)
                if hIcon {
                    bitmap := ModernPanelBitmapFromIcon(hIcon)
                    DllCall("DestroyIcon", "Ptr", hIcon)
                }
            }
        }
    }
    cache[key] := bitmap
    return bitmap
}

; HICON → 带透明通道的 GDI+ 位图：用 DrawIconEx 画到全透明的 32 位画布上取像素（直接读图标位图在部分图标上会出噪点）。
; 没有透明通道的老式图标再画一遍掩码补上不透明度。
ModernPanelBitmapFromIcon(hIcon, size := 48) {
    header := Buffer(40, 0)
    NumPut("UInt", 40, header, 0), NumPut("Int", size, header, 4), NumPut("Int", -size, header, 8)
    NumPut("UShort", 1, header, 12), NumPut("UShort", 32, header, 14)
    hdc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
    colorBits := 0, maskBits := 0
    colorDib := DllCall("CreateDIBSection", "Ptr", hdc, "Ptr", header, "UInt", 0, "Ptr*", &colorBits, "Ptr", 0, "UInt", 0, "Ptr")
    maskDib := DllCall("CreateDIBSection", "Ptr", hdc, "Ptr", header, "UInt", 0, "Ptr*", &maskBits, "Ptr", 0, "UInt", 0, "Ptr")
    result := 0
    if (colorDib && maskDib) {
        old := DllCall("SelectObject", "Ptr", hdc, "Ptr", colorDib, "Ptr")
        DllCall("DrawIconEx", "Ptr", hdc, "Int", 0, "Int", 0, "Ptr", hIcon, "Int", size, "Int", size, "UInt", 0, "Ptr", 0, "UInt", 3) ; DI_NORMAL
        count := size * size
        hasAlpha := false
        loop count
            if (NumGet(colorBits, (A_Index - 1) * 4 + 3, "UChar")) {
                hasAlpha := true
                break
            }
        if !hasAlpha {
            ; 掩码：先铺白，DI_MASK 后不透明处变黑
            DllCall("SelectObject", "Ptr", hdc, "Ptr", maskDib)
            DllCall("RtlFillMemory", "Ptr", maskBits, "UPtr", count * 4, "UChar", 0xFF)
            DllCall("DrawIconEx", "Ptr", hdc, "Int", 0, "Int", 0, "Ptr", hIcon, "Int", size, "Int", size, "UInt", 0, "Ptr", 0, "UInt", 1) ; DI_MASK
            loop count {
                offset := (A_Index - 1) * 4
                if (NumGet(maskBits, offset, "UInt") & 0xFFFFFF)
                    NumPut("UInt", 0, colorBits, offset)                    ; 透明处清零（预乘格式）
                else
                    NumPut("UChar", 0xFF, colorBits, offset + 3)
            }
        }
        DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
        ; 让 GDI+ 自己分配像素内存再拷进去：用外部内存创建或克隆的位图会一直引用那块内存，画布释放后就越界
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", size, "Int", size, "Int", 0, "Int", 0xE200B, "Ptr", 0, "Ptr*", &result) ; PARGB
        if result {
            rect := Buffer(16, 0)
            NumPut("Int", size, rect, 8), NumPut("Int", size, rect, 12)
            data := Buffer(16 + A_PtrSize * 2, 0)
            if (DllCall("gdiplus\GdipBitmapLockBits", "Ptr", result, "Ptr", rect, "UInt", 2, "Int", 0xE200B, "Ptr", data) = 0) { ; ImageLockModeWrite
                stride := NumGet(data, 8, "Int")
                scan0 := NumGet(data, 16, "Ptr")
                loop size
                    DllCall("RtlMoveMemory", "Ptr", scan0 + (A_Index - 1) * stride, "Ptr", colorBits + (A_Index - 1) * size * 4, "UPtr", size * 4)
                DllCall("gdiplus\GdipBitmapUnlockBits", "Ptr", result, "Ptr", data)
            }
        }
    }
    if colorDib
        DllCall("DeleteObject", "Ptr", colorDib)
    if maskDib
        DllCall("DeleteObject", "Ptr", maskDib)
    DllCall("DeleteDC", "Ptr", hdc)
    return result
}

; ---------- 窗口消息 ----------

ModernPanelOnEraseBkgnd(wParam, lParam, msg, hwnd) {
    if ModernPanelRegistry().Has(hwnd)
        return 1
}

; 经 BufferedPaint 把预乘透明通道的画布原样写入窗口，DWM 才能按透明度合成毛玻璃。
ModernPanelOnPaint(wParam, lParam, msg, hwnd) {
    static bufferedPaintReady := false
    registry := ModernPanelRegistry()
    if !registry.Has(hwnd)
        return
    ui := registry[hwnd]

    paintStruct := Buffer(A_PtrSize = 8 ? 72 : 64, 0)
    hdc := DllCall("BeginPaint", "Ptr", hwnd, "Ptr", paintStruct, "Ptr")
    client := Buffer(16, 0)
    DllCall("GetClientRect", "Ptr", hwnd, "Ptr", client)
    width := NumGet(client, 8, "Int")
    height := NumGet(client, 12, "Int")
    if (width > 0 && height > 0) {
        if (ui["dirty"] || !ui["canvas"] || ui["canvasW"] != width || ui["canvasH"] != height)
            ModernPanelRender(ui, width, height)
        if !bufferedPaintReady {
            DllCall("uxtheme\BufferedPaintInit")
            bufferedPaintReady := true
        }
        params := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
        NumPut("UInt", params.Size, params, 0)
        NumPut("UInt", 1, params, 4) ; BPPF_ERASE
        bufferDc := 0
        paintBuffer := DllCall("uxtheme\BeginBufferedPaint", "Ptr", hdc, "Ptr", client, "Int", 1, "Ptr", params, "Ptr*", &bufferDc, "Ptr")
        if (paintBuffer && ui["canvas"]) {
            memoryDc := DllCall("CreateCompatibleDC", "Ptr", bufferDc, "Ptr")
            oldBitmap := DllCall("SelectObject", "Ptr", memoryDc, "Ptr", ui["canvas"], "Ptr")
            DllCall("BitBlt", "Ptr", bufferDc, "Int", 0, "Int", 0, "Int", width, "Int", height
                , "Ptr", memoryDc, "Int", 0, "Int", 0, "UInt", 0x00CC0020) ; SRCCOPY，连同透明通道
            DllCall("SelectObject", "Ptr", memoryDc, "Ptr", oldBitmap)
            DllCall("DeleteDC", "Ptr", memoryDc)
        }
        if paintBuffer
            DllCall("uxtheme\EndBufferedPaint", "Ptr", paintBuffer, "Int", true)
    }
    DllCall("EndPaint", "Ptr", hwnd, "Ptr", paintStruct)
    return 0
}

ModernPanelHitTest(ui, lParam) {
    point := ModernPanelMousePoint(lParam)
    x := point[1], y := point[2]
    dragged := ModernPanelDragged(ui)
    for element in ui["elements"] {
        if (!ModernPanelIsInteractive(element) || !ModernPanelIsVisible(ui, element) || ModernPanelSame(element, dragged))
            continue
        top := element["y"]
        region := ModernPanelScrollRegion(ui, element)
        if IsObject(region) {
            if (y < region["top"] || y > region["bottom"])
                continue
            top -= region["offset"]
        }
        if (x >= element["x"] && x < element["x"] + element["w"] && y >= top && y < top + element["h"])
            return element
    }
    return ""
}

; 按住左键移动：元素带 dragGroup 时超过 5 像素即开始拖动，元素跟随鼠标；ui["onDragMove"] / ui["onDragEnd"]
; 回调收到 (ui, 元素, 内容坐标 x, y)，由面板决定其他元素如何让位、松手后如何保存。
ModernPanelOnMouseMove(wParam, lParam, msg, hwnd) {
    registry := ModernPanelRegistry()
    if !registry.Has(hwnd)
        return
    ui := registry[hwnd]
    point := ModernPanelMousePoint(lParam)
    drag := ui.Has("drag") ? ui["drag"] : ""
    pressed := ui["pressed"]
    if (!IsObject(drag) && (wParam & 1) && IsObject(pressed) && pressed.Has("dragGroup") && ui.Has("downPoint")) {
        if (Abs(point[1] - ui["downPoint"][1]) > 5 || Abs(point[2] - ui["downPoint"][2]) > 5) {
            region := ModernPanelScrollRegion(ui, pressed)
            offset := IsObject(region) ? region["offset"] : 0
            drag := Map("element", pressed, "dx", ui["downPoint"][1] - pressed["x"], "dy", ui["downPoint"][2] + offset - pressed["y"])
            ui["drag"] := drag
            ui["hover"] := ""
            DllCall("SetCapture", "Ptr", hwnd)
        }
    }
    if IsObject(drag) {
        element := drag["element"]
        region := ModernPanelScrollRegion(ui, element)
        ; 拖到滚动区上下边缘时自动滚动
        if IsObject(region) {
            if (point[2] < region["top"] + 18)
                ModernPanelScrollBy(ui, region, -10)
            else if (point[2] > region["bottom"] - 18)
                ModernPanelScrollBy(ui, region, 10)
        }
        offset := IsObject(region) ? region["offset"] : 0
        element["x"] := point[1] - drag["dx"]
        element["y"] := point[2] + offset - drag["dy"]
        if (ui.Has("onDragMove") && IsObject(ui["onDragMove"]))
            ui["onDragMove"].Call(ui, element, point[1], point[2] + offset)
        ModernPanelInvalidate(ui)
        return
    }
    ModernPanelSetHover(ui, ModernPanelHitTest(ui, lParam))
}

ModernPanelSetHover(ui, element) {
    if ModernPanelSame(element, ui["hover"])
        return
    ui["hover"] := element
    ModernPanelInvalidate(ui)
    ; 鼠标直接移出窗口时收不到 WM_MOUSEMOVE，用短定时器兜底清除悬停。
    SetTimer(ModernPanelCheckHover, IsObject(element) ? 80 : 0)
}

ModernPanelCheckHover() {
    windowHwnd := 0
    try MouseGetPos(, , &windowHwnd)
    for hwnd, ui in ModernPanelRegistry()
        if (IsObject(ui["hover"]) && windowHwnd != hwnd)
            ModernPanelSetHover(ui, "")
}

ModernPanelOnMouseDown(wParam, lParam, msg, hwnd) {
    registry := ModernPanelRegistry()
    if !registry.Has(hwnd)
        return
    registry[hwnd]["pressed"] := ModernPanelHitTest(registry[hwnd], lParam)
    registry[hwnd]["downPoint"] := ModernPanelMousePoint(lParam)
}

ModernPanelOnMouseUp(wParam, lParam, msg, hwnd) {
    static lastElement := "", lastTick := 0
    registry := ModernPanelRegistry()
    if !registry.Has(hwnd)
        return
    ui := registry[hwnd]
    ; 拖动结束：不算单击
    if (ui.Has("drag") && IsObject(ui["drag"])) {
        element := ui["drag"]["element"]
        ui["drag"] := ""
        ui["pressed"] := ""
        DllCall("ReleaseCapture")
        lastElement := "", lastTick := 0
        if (ui.Has("onDragEnd") && IsObject(ui["onDragEnd"]))
            ui["onDragEnd"].Call(ui, element)
        ModernPanelInvalidate(ui)
        return
    }
    element := ModernPanelHitTest(ui, lParam)
    pressed := ui["pressed"]
    ui["pressed"] := ""
    if !(IsObject(element) && ModernPanelSame(element, pressed))
        return
    ; 带双击回调的元素：间隔不超过系统双击时间的第二次单击算双击，第一次单击照常执行 onClick（如选中）。
    if (element.Has("onDoubleClick") && IsObject(element["onDoubleClick"])) {
        if (ModernPanelSame(element, lastElement) && A_TickCount - lastTick <= DllCall("GetDoubleClickTime", "UInt")) {
            lastElement := "", lastTick := 0
            SetTimer(element["onDoubleClick"], -1)
            return
        }
        lastElement := element, lastTick := A_TickCount
    }
    ; 延后执行，避免在消息处理中弹出输入框等阻塞窗口消息。
    if IsObject(element["onClick"])
        SetTimer(element["onClick"], -1)
}

ModernPanelOnRightUp(wParam, lParam, msg, hwnd) {
    registry := ModernPanelRegistry()
    if !registry.Has(hwnd)
        return
    element := ModernPanelHitTest(registry[hwnd], lParam)
    if (IsObject(element) && element.Has("onRightClick") && IsObject(element["onRightClick"]))
        SetTimer(element["onRightClick"], -1)
}

; 可交互元素：有单击、双击或右键回调之一。
ModernPanelIsInteractive(element) {
    if IsObject(element["onClick"])
        return true
    for key in ["onDoubleClick", "onRightClick"]
        if (element.Has(key) && IsObject(element[key]))
            return true
    return false
}

ModernPanelOnSetCursor(wParam, lParam, msg, hwnd) {
    registry := ModernPanelRegistry()
    if (registry.Has(hwnd) && (lParam & 0xFFFF) = 1 && IsObject(registry[hwnd]["hover"])) { ; HTCLIENT
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr")) ; IDC_HAND
        return 1
    }
}
