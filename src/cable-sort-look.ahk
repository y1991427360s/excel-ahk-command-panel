#Requires AutoHotkey v2.0
; 电缆排序窗口的外观（沉稳灰白风格，见 D:\Syncthing\Oracle-Sync\tools\前端风格\沉稳灰白风格）。
; 仍用原生控件，只换“皮”：
;  - 按钮：BS_OWNERDRAW 自绘圆角（主按钮深灰底白字，其余白底灰描边，悬停浅灰）
;  - 卡片、输入框描边、摘要行、详情胶囊：GDI+ 画成位图贴到 SS_BITMAP 静态控件上，压在 Z 序最下层
;  - 列表：自绘选中行（浅灰底 + 左侧深灰竖条，不用系统蓝）、编号列加粗、行间细线、行高加大
; 依赖 modern-panel-ui.ahk 的 GDI+ 启动、字体、圆角路径。

; 自绘按钮登记表：按钮 hwnd → Map(kind, bg)
CableSortButtonMap() {
    static m := Map()
    return m
}

; kind：primary 深灰主按钮 / normal 白底描边；bg 为按钮所在区域的底色（圆角外面填这个色）
CableSortButton(g, options, text, kind := "normal", bg := "FFFFFF") {
    static started := false
    if !started {
        started := true
        ModernPanelGdiplusStart()
        OnMessage(0x2B, CableSortOnDrawItem)        ; WM_DRAWITEM
        OnMessage(0x200, CableSortButtonMouseMove)   ; WM_MOUSEMOVE
        OnMessage(0x2A3, CableSortButtonMouseLeave)  ; WM_MOUSELEAVE
    }
    m := CableSortButtonMap()
    if (m.Count > 300)                              ; 关掉的窗口留下的旧句柄
        for h in [m*]
            if !DllCall("IsWindow", "Ptr", h)
                m.Delete(h)
    b := g.AddButton(options, text)
    m[b.Hwnd] := Map("kind", kind, "bg", bg)
    ; AHK 建按钮时会把类型位改回普通按钮，建好后再直接改成 BS_OWNERDRAW
    style := DllCall("GetWindowLongPtr", "Ptr", b.Hwnd, "Int", -16, "Ptr")
    DllCall("SetWindowLongPtr", "Ptr", b.Hwnd, "Int", -16, "Ptr", (style & ~0xF) | 0xB)
    DllCall("InvalidateRect", "Ptr", b.Hwnd, "Ptr", 0, "Int", 1)
    return b
}

; 悬停：按钮自己收到 WM_MOUSEMOVE 时点亮，并请求 WM_MOUSELEAVE 熄灭；只重画进出的那两个按钮。
; 不用定时器轮询 MouseGetPos：鼠标停在别的程序（如 D3D 窗口）上时它一次要等约 60 毫秒，
; 每 60 毫秒一次会把面板线程占满，重画消息排不上，列表滚动后不重画、看着卡死（2026-11-11 用户反馈，偶发）。
CableSortButtonMouseMove(wParam, lParam, msg, hwnd) {
    if (hwnd = CableSortHoverHwnd() || !CableSortButtonMap().Has(hwnd))
        return
    old := CableSortHoverHwnd()
    CableSortHoverHwnd(hwnd)
    tme := Buffer(24, 0)                              ; TRACKMOUSEEVENT
    NumPut("UInt", 24, tme, 0), NumPut("UInt", 2, tme, 4), NumPut("Ptr", hwnd, tme, 8)   ; TME_LEAVE
    DllCall("TrackMouseEvent", "Ptr", tme)
    for x in [old, hwnd]
        if (x && DllCall("IsWindow", "Ptr", x))
            DllCall("InvalidateRect", "Ptr", x, "Ptr", 0, "Int", 0)
}

CableSortButtonMouseLeave(wParam, lParam, msg, hwnd) {
    if (hwnd != CableSortHoverHwnd())
        return
    CableSortHoverHwnd(0)
    if DllCall("IsWindow", "Ptr", hwnd)
        DllCall("InvalidateRect", "Ptr", hwnd, "Ptr", 0, "Int", 0)
}

CableSortHoverHwnd(set := "") {
    static h := 0
    if (set != "")
        h := set
    return h
}

CableSortOnDrawItem(wParam, lParam, msg, hwnd) {
    if (NumGet(lParam, 0, "UInt") != 4)             ; ODT_BUTTON
        return
    h := NumGet(lParam, 24, "Ptr")
    m := CableSortButtonMap()
    if !m.Has(h)
        return
    info := m[h]
    state := NumGet(lParam, 16, "UInt")
    hdc := NumGet(lParam, 32, "Ptr")
    l := NumGet(lParam, 40, "Int"), t := NumGet(lParam, 44, "Int")
    w := NumGet(lParam, 48, "Int") - l, ht := NumGet(lParam, 52, "Int") - t
    if (w <= 0 || ht <= 0)
        return true
    pressed := state & 1, disabled := state & 4
    hover := h = CableSortHoverHwnd()
    if (info["kind"] = "primary") {
        fill := disabled ? "9CA3AF" : pressed ? "111418" : hover ? "1F2329" : "2B3038"
        border := fill, color := "FFFFFF"
    } else {
        fill := disabled ? "FFFFFF" : pressed ? "E9EBEF" : hover ? "F3F4F6" : "FFFFFF"
        border := disabled ? "E9EBEF" : hover ? "C9CDD4" : "DCDFE4"
        color := disabled ? "B3B8C0" : "1F2329"
    }
    text := ControlGetText(h)
    scale := A_ScreenDPI / 96
    ; 先画到内存位图再一次贴上，避免闪烁
    mdc := DllCall("CreateCompatibleDC", "Ptr", hdc, "Ptr")
    hbm := DllCall("CreateCompatibleBitmap", "Ptr", hdc, "Int", w, "Int", ht, "Ptr")
    old := DllCall("SelectObject", "Ptr", mdc, "Ptr", hbm, "Ptr")
    g := 0
    DllCall("gdiplus\GdipCreateFromHDC", "Ptr", mdc, "Ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 5)
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", ModernPanelArgb(info["bg"]))
    CableSortRound(g, 0, 0, w, ht, 7 * scale, fill, border)
    CableSortDrawText(g, text, 4, 0, w - 8, ht, 10, false, color, 1)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("BitBlt", "Ptr", hdc, "Int", l, "Int", t, "Int", w, "Int", ht, "Ptr", mdc, "Int", 0, "Int", 0, "UInt", 0xCC0020)
    DllCall("SelectObject", "Ptr", mdc, "Ptr", old)
    DllCall("DeleteObject", "Ptr", hbm)
    DllCall("DeleteDC", "Ptr", mdc)
    return true
}

; ---------- 位图静态控件 ----------

; SS_BITMAP + SS_REALSIZECONTROL；notify 为真时接收点击（气泡卡片要当拖放、右键的目标）
CableSortAddPic(g, options, notify := false) {
    ModernPanelGdiplusStart()
    return g.AddText(options . " +0xE +0x40 +0x4000000 " . (notify ? "+0x100" : "-0x100"), "")
}

; 把控件压到 Z 序最下层（先建的在上层；底图要在所有控件下面）
CableSortToBottom(ctrl) {
    DllCall("SetWindowPos", "Ptr", ctrl.Hwnd, "Ptr", 1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x13)
}

; 用 GDI+ 按控件当前大小画一张位图贴上。drawFn(graphics, 宽, 高)，宽高为物理像素
CableSortPaint(ctrl, drawFn, bg := "FFFFFF") {
    rc := Buffer(16, 0)
    DllCall("GetClientRect", "Ptr", ctrl.Hwnd, "Ptr", rc)
    w := NumGet(rc, 8, "Int"), h := NumGet(rc, 12, "Int")
    if (w <= 0 || h <= 0)
        return
    bmp := 0, g := 0, hbm := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", w, "Int", h, "Int", 0, "Int", 0x22009, "Ptr", 0, "Ptr*", &bmp)  ; 32bppRGB
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bmp, "Ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 5)
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", ModernPanelArgb(bg))
    drawFn(g, w, h)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", bmp, "Ptr*", &hbm, "UInt", ModernPanelArgb(bg))
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bmp)
    old := SendMessage(0x172, 0, hbm, ctrl)          ; STM_SETIMAGE
    if old
        DllCall("DeleteObject", "Ptr", old)
    if (SendMessage(0x173, 0, 0, ctrl) != hbm)        ; 控件另存了一份（32 位位图会这样），自己的删掉
        DllCall("DeleteObject", "Ptr", hbm)
}

; 圆角矩形：fill / border 为 RRGGBB，可空
CableSortRound(g, x, y, w, h, r, fill, border := "") {
    path := ModernPanelRoundPath(x + 0.5, y + 0.5, w - 1, h - 1, r)
    if (fill != "")
        ModernPanelFillPath(g, path, ModernPanelArgb(fill))
    if (border != "") {
        pen := 0
        DllCall("gdiplus\GdipCreatePen1", "UInt", ModernPanelArgb(border), "Float", 1, "Int", 2, "Ptr*", &pen)
        DllCall("gdiplus\GdipDrawPath", "Ptr", g, "Ptr", pen, "Ptr", path)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    }
    DllCall("gdiplus\GdipDeletePath", "Ptr", path)
}

CableSortRect(g, x, y, w, h, color) {
    brush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", ModernPanelArgb(color), "Ptr*", &brush)
    DllCall("gdiplus\GdipFillRectangle", "Ptr", g, "Ptr", brush, "Float", x, "Float", y, "Float", w, "Float", h)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
}

; 文字格式：不换行、放不下用省略号、竖直居中；align 0 左 1 中 2 右
CableSortFormat(align := 0) {
    static cache := Map()
    if cache.Has(align)
        return cache[align]
    base := 0, f := 0
    DllCall("gdiplus\GdipStringFormatGetGenericTypographic", "Ptr*", &base)
    DllCall("gdiplus\GdipCloneStringFormat", "Ptr", base, "Ptr*", &f)
    DllCall("gdiplus\GdipSetStringFormatFlags", "Ptr", f, "Int", 0x1000 | 0x800)   ; NoWrap | MeasureTrailingSpaces
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", f, "Int", align)
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", f, "Int", 1)
    DllCall("gdiplus\GdipSetStringFormatTrimming", "Ptr", f, "Int", 3)              ; EllipsisCharacter
    cache[align] := f
    return f
}

CableSortDrawText(g, text, x, y, w, h, size, bold, color, align := 0, family := "Microsoft YaHei UI") {
    if (text = "" || w <= 0)
        return
    scale := A_ScreenDPI / 96
    brush := 0, layout := Buffer(16)
    NumPut("Float", x, "Float", y, "Float", w, "Float", h, layout)
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", ModernPanelArgb(color), "Ptr*", &brush)
    DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", text, "Int", -1, "Ptr", ModernPanelFont(size, bold, family)
        , "Ptr", layout, "Ptr", CableSortFormat(align), "Ptr", brush)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
}

; 量文字宽度（物理像素）。g 为空时用一张 1×1 的位图量
CableSortTextWidth(text, size, bold, g := 0) {
    static mg := 0
    if !g {
        if !mg {
            ModernPanelGdiplusStart()
            bmp := 0
            DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", 1, "Int", 1, "Int", 0, "Int", 0x22009, "Ptr", 0, "Ptr*", &bmp)
            DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bmp, "Ptr*", &mg)
            DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", mg, "Int", 5)
        }
        g := mg
    }
    if (text = "")
        return 0
    layout := Buffer(16, 0), box := Buffer(16, 0)
    NumPut("Float", 0, "Float", 0, "Float", 20000, "Float", 200, layout)
    DllCall("gdiplus\GdipMeasureString", "Ptr", g, "WStr", text, "Int", -1, "Ptr", ModernPanelFont(size, bold)
        , "Ptr", layout, "Ptr", CableSortFormat(0), "Ptr", box, "Ptr", 0, "Ptr", 0)
    return NumGet(box, 8, "Float")
}

; 一行多段文字。runs：[[文字, 颜色, 粗体, 胶囊底色(可省)], …]；返回画完后的 x
CableSortDrawRuns(g, runs, x, h, size, maxX := 0) {
    scale := A_ScreenDPI / 96
    pad := 8 * scale, ph := Round(22 * scale)
    for seg in runs {
        if (maxX && x >= maxX)
            break
        bold := seg.Length >= 3 && seg[3]
        tw := CableSortTextWidth(seg[1], size, bold, g)
        if (seg.Length >= 4 && seg[4] != "") {
            CableSortRound(g, x, (h - ph) / 2, tw + pad * 2, ph, ph / 2, seg[4])
            CableSortDrawText(g, seg[1], x + pad, 0, tw + 2, h, size, bold, seg[2])
            x += tw + pad * 2
        } else {
            CableSortDrawText(g, seg[1], x, 0, (maxX ? Min(tw + 2, maxX - x) : tw + 2), h, size, bold, seg[2])
            x += tw
        }
    }
    return x
}

CableSortRunsWidth(runs, size) {
    scale := A_ScreenDPI / 96, w := 0
    for seg in runs
        w += CableSortTextWidth(seg[1], size, seg.Length >= 3 && seg[3]) + ((seg.Length >= 4 && seg[4] != "") ? 16 * scale : 0)
    return w
}

; ---------- 输入框：去掉系统边框，外面套圆角描边（获得焦点时描边加深） ----------

CableSortFrameState() {
    static m := Map()
    return m
}

; 在 edit 之后建一个底框（压到最下层）；icon 为 Segoe MDL2 Assets 字符，如 Chr(0xE721) 放大镜
CableSortFrameEdit(g, edit, icon := "") {
    frame := CableSortAddPic(g, "x0 y0 w10 h10")
    CableSortToBottom(frame)
    CableSortFrameState()[frame.Hwnd] := Map("icon", icon, "focus", false)
    edit.OnEvent("Focus", (*) => CableSortFrameFocus(frame, true))
    edit.OnEvent("LoseFocus", (*) => CableSortFrameFocus(frame, false))
    return frame
}

CableSortFrameFocus(frame, on) {
    try {
        CableSortFrameState()[frame.Hwnd]["focus"] := on
        CableSortDrawFrame(frame)
    }
}

CableSortDrawFrame(frame) {
    st := CableSortFrameState()[frame.Hwnd]
    scale := A_ScreenDPI / 96
    CableSortPaint(frame, (g, w, h) => (
        CableSortRound(g, 0, 0, w, h, 7 * scale, "FFFFFF", st["focus"] ? "9CA3AF" : "DCDFE4"),
        st["icon"] != "" && CableSortDrawText(g, st["icon"], 10 * scale, 0, 20 * scale, h, 10, false, "9CA3AF", 0, "Segoe MDL2 Assets")))
}

; 摆放带框输入框：框在 (x, y, w, h)，输入框在框内竖直居中；左边有图标时多让出位置，右边给清空叉号留 rightPad
CableSortPlaceFramed(frame, edit, x, y, w, h, rightPad := 8) {
    st := CableSortFrameState()[frame.Hwnd]
    frame.Move(x, y, w, h)
    CableSortDrawFrame(frame)
    edit.GetPos(, , , &eh)
    left := st["icon"] != "" ? 32 : 10
    edit.Move(x + left, y + (h - eh) // 2, w - left - rightPad)
}

; ---------- 列表 ----------

; 去掉边框和网格、双缓冲、行高 rowH（小图标列表撑高）
CableSortStyleLv(lv, rowH) {
    lv.Opt("-Grid +LV0x10000")                       ; LVS_EX_DOUBLEBUFFER
    il := DllCall("ImageList_Create", "Int", 1, "Int", Round(rowH * A_ScreenDPI / 96), "UInt", 0x21, "Int", 1, "Int", 0, "Ptr")
    SendMessage(0x1003, 1, il, lv)                   ; LVM_SETIMAGELIST LVSIL_SMALL
}

CableSortBoldFont(hwnd) {
    static cache := Map()
    normal := SendMessage(0x31, 0, 0, hwnd)          ; WM_GETFONT
    if cache.Has(normal)
        return cache[normal]
    lf := Buffer(92, 0)
    DllCall("GetObjectW", "Ptr", normal, "Int", 92, "Ptr", lf)
    NumPut("Int", 700, lf, 16)                        ; lfWeight
    cache[normal] := DllCall("CreateFontIndirectW", "Ptr", lf, "Ptr")
    return cache[normal]
}

CableSortBrush(rgb) {
    static cache := Map()
    if !cache.Has(rgb)
        cache[rgb] := DllCall("CreateSolidBrush", "UInt", ModernPanelColorRef(rgb), "Ptr")
    return cache[rgb]
}

; 列表自绘（NM_CUSTOMDRAW）。colors[i] 为第 i 行字色（RGB 或空）；col 为 -1 时整行用该色，否则只给第 col 列（0 起）上色。
; bold：加粗的列；dim：灰字的列（数组）；lines：画行间细线。
; 选中行：浅灰底 + 左侧 3px 深灰竖条（不用系统蓝，沉稳灰白风格）
CableSortCustomDraw(colors, lParam, col := -1, bold := -1, dim := "", lines := false) {
    static normal := "1F2329", selBg := "EDEFF2", bg := "FFFFFF"
    stage := NumGet(lParam, 24, "UInt")
    if (stage = 1)                                   ; CDDS_PREPAINT
        return 0x20                                  ; CDRF_NOTIFYITEMDRAW
    hwnd := NumGet(lParam, 0, "Ptr")
    item0 := NumGet(lParam, 56, "UPtr")
    color := (item0 + 1 <= colors.Length) ? colors[item0 + 1] : ""
    sel := SendMessage(0x102C, item0, 2, hwnd) & 2   ; LVM_GETITEMSTATE / LVIS_SELECTED
    if (stage = 0x10001 || stage = 0x30001) {
        if sel
            NumPut("UInt", NumGet(lParam, 64, "UInt") & ~0x11, lParam, 64)   ; 去掉 CDIS_SELECTED、CDIS_FOCUS，由这里自己上色
        if (stage = 0x10001)
            return 0x20 | 0x10                       ; CDRF_NOTIFYSUBITEMDRAW | CDRF_NOTIFYPOSTPAINT
        sub := NumGet(lParam, 88, "Int")
        c := normal
        if (color != "" && (col < 0 || sub = col))
            c := color
        else if IsObject(dim)
            for d in dim
                if (d = sub)
                    c := "9CA3AF"
        NumPut("UInt", ModernPanelColorRef(c), lParam, 80)                   ; clrText
        NumPut("UInt", ModernPanelColorRef(sel ? selBg : bg), lParam, 84)    ; clrTextBk
        hdc := NumGet(lParam, 32, "Ptr")
        DllCall("SelectObject", "Ptr", hdc, "Ptr", sub = bold ? CableSortBoldFont(hwnd) : SendMessage(0x31, 0, 0, hwnd))
        return 2                                     ; CDRF_NEWFONT
    }
    if (stage = 0x10002) {                           ; CDDS_ITEMPOSTPAINT：细线和选中竖条
        rc := Buffer(16, 0)                          ; LVIR_BOUNDS
        SendMessage(0x100E, item0, rc, hwnd)
        l := NumGet(rc, 0, "Int"), t := NumGet(rc, 4, "Int"), r := NumGet(rc, 8, "Int"), b := NumGet(rc, 12, "Int")
        hdc := NumGet(lParam, 32, "Ptr")
        if lines {
            lineRc := Buffer(16)
            NumPut("Int", l, "Int", b - 1, "Int", r, "Int", b, lineRc)
            DllCall("FillRect", "Ptr", hdc, "Ptr", lineRc, "Ptr", CableSortBrush("F0F1F4"))
        }
        if sel {
            bar := Buffer(16)
            NumPut("Int", l, "Int", t, "Int", l + 3, "Int", b, bar)
            DllCall("FillRect", "Ptr", hdc, "Ptr", bar, "Ptr", CableSortBrush("2B3038"))
        }
    }
    return 0
}
