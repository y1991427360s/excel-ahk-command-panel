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

ModernPanelCreate(title, options := "+AlwaysOnTop -MinimizeBox -MaximizeBox") {
    static hooked := false
    colors := ModernPanelColors()

    ; 每次只保留一个面板，释放旧画布
    registry := ModernPanelRegistry()
    for hwnd, oldUi in registry
        ModernPanelReleaseCanvas(oldUi)
    registry.Clear()

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
        OnMessage(0x0020, ModernPanelOnSetCursor)   ; WM_SETCURSOR
        hooked := true
    }

    ui := Map("gui", panel, "elements", [], "page", "", "x", 0, "y", 0, "w", 0, "current", ""
        , "hover", "", "pressed", "", "canvas", 0, "canvasW", 0, "canvasH", 0, "dirty", true)
    registry[panel.Hwnd] := ui
    return ui
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

ModernPanelIsVisible(ui, element) {
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

    for element in ui["elements"] {
        if !ModernPanelIsVisible(ui, element)
            continue
        style := (ModernPanelSame(element, ui["hover"]) && IsObject(element["hover"])) ? element["hover"] : element["style"]
        ModernPanelDrawElement(graphics, element["x"] * scale, element["y"] * scale, element["w"] * scale, element["h"] * scale
            , element["text"], style, scale, isGlass)
    }

    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", graphics)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bitmap)
    ModernPanelReleaseCanvas(ui)
    ui["canvas"] := canvas
    ui["canvasW"] := width
    ui["canvasH"] := height
    ui["dirty"] := false
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

    if (text = "" && style["icon"] = "")
        return
    format := 0, textBrush := 0
    DllCall("gdiplus\GdipCreateStringFormat", "Int", style["wrap"] ? 0 : 0x1000, "Int", 0, "Ptr*", &format) ; 0x1000 NoWrap
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
    if (style["icon"] != "") {
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
    NumPut("Float", x + padding + iconOffset, "Float", y, "Float", width - padding * 2 - iconOffset, "Float", textHeight, layout)
    DllCall("gdiplus\GdipDrawString", "Ptr", graphics, "WStr", text, "Int", -1, "Ptr", ModernPanelFont(style["size"], style["bold"])
        , "Ptr", layout, "Ptr", format, "Ptr", textBrush)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", textBrush)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", format)
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
    scale := A_ScreenDPI / 96
    x := ((lParam & 0xFFFF) << 48 >> 48) / scale
    y := ((lParam >> 16 & 0xFFFF) << 48 >> 48) / scale
    for element in ui["elements"] {
        if (!IsObject(element["onClick"]) || !ModernPanelIsVisible(ui, element))
            continue
        if (x >= element["x"] && x < element["x"] + element["w"] && y >= element["y"] && y < element["y"] + element["h"])
            return element
    }
    return ""
}

ModernPanelOnMouseMove(wParam, lParam, msg, hwnd) {
    registry := ModernPanelRegistry()
    if registry.Has(hwnd)
        ModernPanelSetHover(registry[hwnd], ModernPanelHitTest(registry[hwnd], lParam))
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
    if registry.Has(hwnd)
        registry[hwnd]["pressed"] := ModernPanelHitTest(registry[hwnd], lParam)
}

ModernPanelOnMouseUp(wParam, lParam, msg, hwnd) {
    registry := ModernPanelRegistry()
    if !registry.Has(hwnd)
        return
    ui := registry[hwnd]
    element := ModernPanelHitTest(ui, lParam)
    pressed := ui["pressed"]
    ui["pressed"] := ""
    ; 延后执行，避免在消息处理中弹出输入框等阻塞窗口消息。
    if (IsObject(element) && ModernPanelSame(element, pressed))
        SetTimer(element["onClick"], -1)
}

ModernPanelOnSetCursor(wParam, lParam, msg, hwnd) {
    registry := ModernPanelRegistry()
    if (registry.Has(hwnd) && (lParam & 0xFFFF) = 1 && IsObject(registry[hwnd]["hover"])) { ; HTCLIENT
        DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr")) ; IDC_HAND
        return 1
    }
}
