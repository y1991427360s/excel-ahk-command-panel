#Requires AutoHotkey v2.0
; 找出最新版本：选中文件夹（连同子文件夹）或多个文件，把同一份文件散在各处的副本 / 版本归成一组，
; 按修改时间标出每组最新的那份。纯 AHK 实现，不依赖 Python，分享版也能用。
; 归组规则见 LatestVersionGroupKey：扩展名相同，文件名去掉“- 副本”“(1)”“v2”“20261104”“最终版”等版本后缀后相同，
; 就算同一份文件。CAD 备份 / 锁定文件（.bak .dwl .sv$ 等）、Office 临时文件 ~$ 和隐藏 / 系统文件不参与比较。
; 只读：不移动、不改名、不删除任何文件。

FindLatestFileVersions() {
    title := "找出最新版本"
    selected := GetSelectedFilePaths()
    if (selected.Length = 0) {
        MsgBox("请先在资源管理器或桌面选中文件夹（连同子文件夹一起查找），或选中同一文件的几个版本，再按 Ctrl+Shift+E。", title, "Icon!")
        return
    }
    ToolTip("正在查找最新版本，文件多时需要几秒…")
    try {
        start := A_TickCount
        scan := LatestVersionScan(selected)
        scan["selected"] := selected      ; 结果窗口“重新扫描”用
        scan["elapsed"] := A_TickCount - start
    } finally
        ToolTip()
    if (scan["files"] = 0) {
        MsgBox("选中的位置里没有可比较的文件"
            . (scan["skipped"] ? "（已忽略 " . scan["skipped"] . " 个备份 / 锁定 / 临时文件）" : "") . "。", title, "Icon!")
        return
    }
    ShowLatestVersionReport(title, scan)
}

; 扫描选中的文件和文件夹，返回按文件名排序的分组；每组 copies 按修改时间从新到旧排好。
LatestVersionScan(selected, limit := 50000) {
    root := LatestVersionCommonRoot(selected)
    candidates := [], seen := Map(), folders := 0, skipped := 0, truncated := false
    for _, path in selected {
        path := RTrim(path, "\")
        if DirExist(path) {
            folders++
            loop files path . "\*", "FR" {
                if seen.Has(A_LoopFileFullPath)
                    continue
                seen[A_LoopFileFullPath] := true
                if LatestVersionIgnored(A_LoopFileName, A_LoopFileAttrib) {
                    skipped++
                    continue
                }
                if (candidates.Length >= limit) {
                    truncated := true
                    break
                }
                candidates.Push([A_LoopFileFullPath, A_LoopFileName, A_LoopFileSize, A_LoopFileTimeModified])
            }
        } else if FileExist(path) && !seen.Has(path) {
            seen[path] := true
            SplitPath(path, &name)
            if LatestVersionIgnored(name, FileExist(path)) {
                skipped++
                continue
            }
            candidates.Push([path, name, FileGetSize(path), FileGetTime(path, "M")])
        }
        if truncated
            break
    }

    groups := Map(), order := []
    for _, item in candidates {
        key := LatestVersionGroupKey(item[2])
        if !groups.Has(key) {
            groups[key] := []
            order.Push(key)
        }
        groups[key].Push(Map("path", item[1], "name", item[2], "rel", LatestVersionRelative(item[1], root)
            , "size", item[3], "time", item[4]))
    }

    result := []
    for _, key in order {
        copies := LatestVersionSortCopies(groups[key])
        newest := copies[1]
        same := 0, older := 0, clash := false, names := Map()
        for index, copy in copies {
            names[StrLower(copy["name"])] := true
            if (index = 1)
                continue
            if (copy["time"] != newest["time"])
                older++
            else if (copy["size"] = newest["size"])
                same++
            else
                clash := true
        }
        result.Push(Map("copies", copies, "newest", newest, "same", same, "older", older
            , "clash", clash, "nameCount", names.Count))
    }
    ; 按最新那份的文件名排序（资源管理器同款逻辑）
    loop result.Length - 1 {
        i := A_Index + 1, current := result[i], j := i - 1
        while (j >= 1 && DllCall("shlwapi\StrCmpLogicalW", "WStr", result[j]["newest"]["name"]
                , "WStr", current["newest"]["name"], "Int") > 0) {
            result[j + 1] := result[j]
            j--
        }
        result[j + 1] := current
    }
    return Map("groups", result, "files", candidates.Length, "skipped", skipped, "folders", folders
        , "root", root, "truncated", truncated, "limit", limit)
}

; 同一份文件的归组键：扩展名 + 去掉版本后缀的文件名（不分大小写）。反复剥离，处理“xx_v2 - 副本 (1)”这类叠加后缀。
LatestVersionGroupKey(name) {
    static patterns := [
        "i)\s*[-－—_]?\s*(副本|copy)(\s*[\(（]\d+[\)）])?$",
        "\s*[\(（]\d{1,3}[\)）]$",
        "i)(?:[-_.\s]+|(?<![A-Za-z]))v(?:er)?\.?\d+(?:\.\d+)*$",
        "[-_.\s]*(?:19|20)\d\d[-_.]?[01]\d[-_.]?[0-3]\d(?:[-_\s]?\d{4,6})?$",
        "i)[-_.\s]*(?:最终版?|终版|定稿|最新版?|新版|旧版|修改版|修订版|final|new|old)$",
        "[-_.\s]*(?:第?\d+次)?(?:修改|修订)\d*$"
    ]
    SplitPath(name, , , &ext, &stem)
    stem := Trim(stem)
    loop 10 {
        before := stem
        for _, pattern in patterns {
            stripped := Trim(RegExReplace(stem, pattern))
            if (stripped != "")
                stem := stripped
        }
        if (stem = before)
            break
    }
    return StrLower(stem) . "|" . StrLower(ext)
}

; CAD 备份 / 锁定 / 自动保存文件、Office 临时文件、隐藏和系统文件不算“版本”。
LatestVersionIgnored(name, attrib := "") {
    if (InStr(attrib, "H") || InStr(attrib, "S") || SubStr(name, 1, 2) = "~$")
        return true
    SplitPath(name, , , &ext)
    return RegExMatch(ext, "i)^(bak|dwl2?|sv\$|ac\$|tmp|lck)$") || name = "Thumbs.db" || name = "desktop.ini"
}

; 选中一个文件夹时以它为根；选中多项时取它们所在位置的公共上级，结果里显示相对路径。
LatestVersionCommonRoot(paths) {
    if (paths.Length = 1 && DirExist(paths[1]))
        return RTrim(paths[1], "\")
    root := ""
    for _, path in paths {
        SplitPath(RTrim(path, "\"), , &dir)
        if (root = "") {
            root := dir
            continue
        }
        while (root != "" && !(StrLower(dir) = StrLower(root) || InStr(StrLower(dir) . "\", StrLower(root) . "\") = 1)) {
            SplitPath(root, , &parent)
            root := (parent = root) ? "" : parent
        }
    }
    return root
}

LatestVersionRelative(path, root) {
    if (root != "" && InStr(StrLower(path), StrLower(root) . "\") = 1)
        return SubStr(path, StrLen(root) + 2)
    return path
}

; 修改时间从新到旧；同一时间再按路径排，结果稳定。
LatestVersionSortCopies(copies) {
    loop copies.Length - 1 {
        i := A_Index + 1, current := copies[i], j := i - 1
        while (j >= 1 && (copies[j]["time"] < current["time"]
                || (copies[j]["time"] = current["time"] && StrCompare(copies[j]["rel"], current["rel"]) > 0))) {
            copies[j + 1] := copies[j]
            j--
        }
        copies[j + 1] := current
    }
    return copies
}

LatestVersionStatus(group) {
    if (group["copies"].Length = 1)
        return "只有 1 份"
    parts := []
    if group["clash"]
        parts.Push("注意：有修改时间相同但大小不同的副本")
    if group["older"]
        parts.Push(group["older"] . " 份是旧版本")
    if group["same"]
        parts.Push(group["same"] . " 份与最新相同")
    if (group["nameCount"] > 1)
        parts.Push("文件名不完全相同")
    text := ""
    for index, part in parts
        text .= (index > 1 ? "，" : "") . part
    return text
}

LatestVersionFolderLabel(rel) {
    SplitPath(rel, , &dir)
    return dir = "" ? "（顶层）" : dir
}

; 最新那份所在的全部文件夹：时间、大小都与最新相同的副本也算，用“、”连接。
LatestVersionNewestFolders(group) {
    newest := group["newest"], seen := Map(), text := ""
    for _, copy in group["copies"] {
        if (copy["time"] != newest["time"] || copy["size"] != newest["size"])
            continue
        label := LatestVersionFolderLabel(copy["rel"])
        if seen.Has(label)
            continue
        seen[label] := true
        text .= (text = "" ? "" : "、") . label
    }
    return text
}

LatestVersionSize(bytes) {
    if (bytes >= 1048576)
        return Format("{:.2f} MB", bytes / 1048576)
    if (bytes >= 1024)
        return Format("{:.1f} KB", bytes / 1024)
    return bytes . " B"
}

LatestVersionAge(newer, older) {
    minutes := DateDiff(newer, older, "Minutes")
    if (minutes < 1)
        return DateDiff(newer, older, "Seconds") . " 秒"
    days := minutes // 1440, hours := Mod(minutes, 1440) // 60, mins := Mod(minutes, 60)
    if days
        return days . " 天" . (hours ? " " . hours . " 小时" : "")
    if hours
        return hours . " 小时" . (mins ? " " . mins . " 分钟" : "")
    return mins . " 分钟"
}

; 文件类型分类：[排序序号, 显示名]。DWG、PDF 等常用类型各成一类，其余按扩展名大写归入“其他”之后。
LatestVersionCategory(name) {
    SplitPath(name, , , &ext)
    ext := StrLower(ext)
    static kinds := [
        [1, "DWG", "dwg|dxf|dwf"],
        [2, "PDF", "pdf"],
        [3, "Word", "doc|docx|docm|wps|rtf"],
        [4, "Excel", "xls|xlsx|xlsm|xlsb|et|csv"],
        [5, "图片", "jpg|jpeg|png|bmp|gif|tif|tiff|webp"],
        [6, "压缩包", "rar|zip|7z"]
    ]
    for _, kind in kinds
        if RegExMatch(ext, "^(" . kind[3] . ")$")
            return [kind[1], kind[2]]
    return [9, "其他"]
}

; 按排列方式返回 groups 的下标顺序；各方式相同时都再按文件名排，结果稳定。
LatestVersionSortedIndexes(groups, mode) {
    indexes := []
    loop groups.Length
        indexes.Push(A_Index)
    Compare(a, b) {
        ga := groups[a], gb := groups[b], na := ga["newest"], nb := gb["newest"]
        switch mode {
            case 2:
                diff := LatestVersionCategory(na["name"])[1] - LatestVersionCategory(nb["name"])[1]
                if (diff = 0) {  ; “其他”里再按扩展名聚在一起
                    SplitPath(na["name"], , , &ea), SplitPath(nb["name"], , , &eb)
                    diff := StrCompare(ea, eb)
                }
            case 3:
                diff := na["time"] > nb["time"] ? -1 : na["time"] < nb["time"] ? 1 : 0
            case 4:
                diff := na["time"] < nb["time"] ? -1 : na["time"] > nb["time"] ? 1 : 0
            case 5:
                diff := gb["copies"].Length - ga["copies"].Length
            case 6:
                diff := DllCall("shlwapi\StrCmpLogicalW", "WStr", LatestVersionNewestFolders(ga)
                    , "WStr", LatestVersionNewestFolders(gb), "Int")
            default:
                diff := 0
        }
        return diff != 0 ? diff : DllCall("shlwapi\StrCmpLogicalW", "WStr", na["name"], "WStr", nb["name"], "Int")
    }
    loop indexes.Length - 1 {
        i := A_Index + 1, current := indexes[i], j := i - 1
        while (j >= 1 && Compare(indexes[j], current) > 0) {
            indexes[j + 1] := indexes[j]
            j--
        }
        indexes[j + 1] := current
    }
    return indexes
}

; ---------- 结果窗口 ----------
; 界面按 2026-11-10 用户设计稿：蓝色渐变标题栏（自带最小化 / 最大化 / 关闭）、查找范围条、四张统计卡、
; “全局最新”提示条、搜索 + 类型筛选 + 排序 + 只看多份、文件列表、选中文件的副本卡片、底部按钮。
; 除搜索框（系统 Edit，方便输入中文）外全部用 GDI+ 画进一张位图，点击 / 悬停 / 滚动按坐标自行判断。
; 窗口去掉系统标题栏但保留 WS_CAPTION / WS_THICKFRAME：仍可拖动、贴边、缩放、最小化，任务栏有按钮。
; 坐标都是 96 DPI 下的逻辑像素，绘制时整体按系统缩放放大。

LatestUiSortLabels() {
    return ["按文件名", "按文件类型", "按修改时间（新 → 旧）", "按修改时间（旧 → 新）", "按份数（多 → 少）", "按所在文件夹"]
}

LatestUiStates() {
    static states := Map()
    return states
}

; 窗口或其子控件（搜索框）的句柄 → 窗口状态
LatestUiFind(hwnd) {
    states := LatestUiStates()
    if states.Has(hwnd)
        return states[hwnd]
    parent := DllCall("GetParent", "Ptr", hwnd, "Ptr")
    return (parent && states.Has(parent)) ? states[parent] : ""
}

ShowLatestVersionReport(title, scan) {
    static prefs := Map("sort", 3, "onlyMulti", true)  ; 排列方式、只看多份在本次运行期间记住
    static hooked := false
    ModernPanelGdiplusStart()
    if !hooked {
        for msg, fn in Map(0x0F, LatestUiOnPaint, 0x14, LatestUiOnErase, 0x83, LatestUiOnNcCalcSize
                , 0x84, LatestUiOnNcHitTest, 0x200, LatestUiOnMouseMove, 0x201, LatestUiOnMouseDown
                , 0x202, LatestUiOnMouseUp, 0x2A3, LatestUiOnMouseLeave, 0x20A, LatestUiOnWheel
                , 0x20, LatestUiOnSetCursor, 0x100, LatestUiOnKeyDown)
            OnMessage(msg, fn)
        hooked := true
    }

    dlg := Gui("+Resize +MinSize900x600 +0x02000000", title)  ; WS_CLIPCHILDREN：画背景时不盖住搜索框
    dlg.BackColor := "FFFFFF"
    dlg.MarginX := 0, dlg.MarginY := 0
    dlg.SetFont("s10 c1F2329", "Microsoft YaHei UI")
    search := dlg.AddEdit("x0 y0 w200 h22 -E0x200 -Border")
    DllCall("SendMessage", "Ptr", search.Hwnd, "UInt", 0x1501, "Ptr", 1, "WStr", "搜索文件名或文件夹…")  ; EM_SETCUEBANNER

    st := Map("gui", dlg, "title", title, "prefs", prefs, "search", search, "query", "", "filter", "全部"
        , "rows", [], "sel", 0, "scroll", 0, "copyScroll", 0, "hover", "", "pressed", "", "hits", []
        , "dirty", true, "dib", 0, "bmp", 0, "dibW", 0, "dibH", 0, "measure", Map(), "drag", ""
        , "lastClick", [0, ""], "tracking", false, "searchRect", "")
    LatestUiStates()[dlg.Hwnd] := st
    LatestUiSetScan(st, scan)
    LatestUiRefill(st, true)

    search.OnEvent("Change", (ctrl, *) => (st["query"] := ctrl.Text, LatestUiRefill(st)))
    search.OnEvent("Focus", (*) => LatestUiInvalidate(st))
    search.OnEvent("LoseFocus", (*) => LatestUiInvalidate(st))
    dlg.OnEvent("Close", (*) => LatestUiClose(st))
    dlg.OnEvent("Size", (guiObj, minMax, *) => (minMax != -1 ? LatestUiInvalidate(st) : 0))

    ; 圆角窗口；去掉系统标题栏后重新计算框架
    corner := 2
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", dlg.Hwnd, "UInt", 33, "Int*", corner, "UInt", 4)
    DllCall("SetWindowPos", "Ptr", dlg.Hwnd, "Ptr", 0, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x37)  ; FRAMECHANGED|NOMOVE|NOSIZE|NOZORDER|NOACTIVATE
    ; 初始大小：适中即可，能最大化 / 拖大；不再默认铺满屏幕
    scale := A_ScreenDPI / 96
    MonitorGetWorkArea(MonitorGetPrimary(), &waL, &waT, &waR, &waB)
    w := Round(Min(1180 * scale, (waR - waL) * 0.92)), h := Round(Min(820 * scale, (waB - waT) * 0.92))
    dlg.Show("Hide")
    WinMove(waL + ((waR - waL) - w) // 2, waT + ((waB - waT) - h) // 2, w, h, dlg.Hwnd)
    dlg.Show()
    DllCall("SetFocus", "Ptr", dlg.Hwnd)
}

LatestUiSetScan(st, scan) {
    groups := scan["groups"]
    st["scan"] := scan
    st["groups"] := groups
    st["sorted"] := Map()
    multi := 0, latest := 0, cats := Map()
    for index, group in groups {
        if (group["copies"].Length > 1)
            multi++
        if (!latest || group["newest"]["time"] > groups[latest]["newest"]["time"])
            latest := index
        cat := LatestVersionCategory(group["newest"]["name"])
        cats[cat[1]] := cat[2]
    }
    st["multi"] := multi
    st["latest"] := latest
    st["cats"] := ["全部"]
    for _, name in cats  ; Map 按键（排序序号）升序枚举
        st["cats"].Push(name)
    if !LatestUiHas(st["cats"], st["filter"])
        st["filter"] := "全部"
}

LatestUiHas(list, value) {
    for _, item in list
        if (item = value)
            return true
    return false
}

; 按当前排序、筛选、搜索重排列表。first 为真时默认选中全局最新那份。
LatestUiRefill(st, first := false) {
    mode := st["prefs"]["sort"]
    if !st["sorted"].Has(mode)
        st["sorted"][mode] := LatestVersionSortedIndexes(st["groups"], mode)
    query := StrLower(Trim(st["query"]))
    rows := []
    for _, index in st["sorted"][mode] {
        group := st["groups"][index]
        if (st["prefs"]["onlyMulti"] && group["copies"].Length < 2)
            continue
        if (st["filter"] != "全部" && LatestVersionCategory(group["newest"]["name"])[2] != st["filter"])
            continue
        if (query != "" && !InStr(StrLower(group["newest"]["name"]), query)
                && !InStr(StrLower(LatestVersionNewestFolders(group)), query))
            continue
        rows.Push(index)
    }
    st["rows"] := rows
    want := first ? st["latest"] : st["sel"]
    st["sel"] := 0
    for _, index in rows
        if (index = want)
            st["sel"] := want
    if (!st["sel"] && rows.Length)
        st["sel"] := rows[1]
    st["copyScroll"] := 0
    st["scroll"] := first ? st["scroll"] : 0
    LatestUiInvalidate(st)
    if first
        st["ensureSel"] := true
}

LatestUiInvalidate(st) {
    st["dirty"] := true
    try DllCall("InvalidateRect", "Ptr", st["gui"].Hwnd, "Ptr", 0, "Int", false)
}

LatestUiClose(st) {
    hwnd := st["gui"].Hwnd
    LatestUiStates().Delete(hwnd)
    if st["bmp"]
        DllCall("gdiplus\GdipDisposeImage", "Ptr", st["bmp"])
    if st["dib"]
        DllCall("DeleteObject", "Ptr", st["dib"])
    st["bmp"] := 0, st["dib"] := 0
    if st.Has("mg") {
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", st["mg"])
        DllCall("gdiplus\GdipDisposeImage", "Ptr", st["mgBmp"])
    }
    try st["gui"].Destroy()
}

LatestUiRescan(st) {
    ToolTip("正在重新扫描…")
    try {
        start := A_TickCount
        scan := LatestVersionScan(st["scan"]["selected"])
        scan["selected"] := st["scan"]["selected"]
        scan["elapsed"] := A_TickCount - start
    } finally
        ToolTip()
    if (scan["files"] = 0) {
        MsgBox("选中的位置里已经没有可比较的文件。", st["title"], "Icon! Owner" . st["gui"].Hwnd)
        return
    }
    keep := st["sel"] ? st["groups"][st["sel"]]["newest"]["path"] : ""
    LatestUiSetScan(st, scan)
    st["sel"] := 0
    for index, group in st["groups"]
        if (group["newest"]["path"] = keep)
            st["sel"] := index
    LatestUiRefill(st, !st["sel"])
}

; ---------- 文件操作 ----------

LatestUiReveal(st, path) {
    if !FileExist(path) {
        MsgBox("文件已不存在：`n" . path . "`n`n可以点“重新扫描”刷新结果。", st["title"], "Icon! Owner" . st["gui"].Hwnd)
        return
    }
    Run('explorer.exe /select,"' . path . '"')
}

LatestUiLocateSelected(st) {
    if !st["sel"] {
        ToolTip("请先在列表里选中一行")
        SetTimer(() => ToolTip(), -1500)
        return
    }
    LatestUiReveal(st, st["groups"][st["sel"]]["newest"]["path"])
}

LatestUiCopyResult(st) {
    text := "类型`t文件名`t最新的在`t完整路径`t修改时间`t份数`t说明"
    for _, index in st["rows"] {
        group := st["groups"][index], newest := group["newest"]
        text .= "`r`n" . LatestVersionCategory(newest["name"])[2] . "`t" . newest["name"] . "`t" . LatestVersionNewestFolders(group)
            . "`t" . newest["path"] . "`t" . FormatTime(newest["time"], "yyyy-MM-dd HH:mm:ss") . "`t" . group["copies"].Length
            . "`t" . LatestVersionStatus(group)
    }
    A_Clipboard := text
    ToolTip("已复制 " . st["rows"].Length . " 行结果，可直接粘贴到 Excel")
    SetTimer(() => ToolTip(), -1800)
}

LatestUiSortMenu(st, x, y) {
    sortMenu := Menu()
    for index, label in LatestUiSortLabels() {
        sortMenu.Add(label, LatestUiSortPick.Bind(st, index))
        if (index = st["prefs"]["sort"])
            sortMenu.Check(label)
    }
    scale := A_ScreenDPI / 96
    sortMenu.Show(Round(x * scale), Round(y * scale))
}

LatestUiSortPick(st, index, *) {
    st["prefs"]["sort"] := index
    LatestUiRefill(st)
    LatestUiEnsureVisible(st)
}

LatestUiSelect(st, index) {
    if (index = st["sel"])
        return
    st["sel"] := index
    st["copyScroll"] := 0
    LatestUiEnsureVisible(st)
    LatestUiInvalidate(st)
}

; 按行移动选中项（Up/Down/PgUp/PgDn/Home/End）
LatestUiMoveSel(st, delta) {
    rows := st["rows"]
    if !rows.Length
        return
    pos := 0
    for i, index in rows
        if (index = st["sel"])
            pos := i
    pos := pos ? Max(1, Min(rows.Length, pos + delta)) : (delta > 0 ? 1 : rows.Length)
    LatestUiSelect(st, rows[pos])
}

LatestUiEnsureVisible(st) {
    if !st.Has("listArea") || !st["sel"]
        return
    area := st["listArea"], rowH := 36
    for i, index in st["rows"] {
        if (index != st["sel"])
            continue
        top := (i - 1) * rowH
        if (top < st["scroll"])
            st["scroll"] := top
        else if (top + rowH > st["scroll"] + area[4])
            st["scroll"] := top + rowH - area[4]
    }
    LatestUiClampScroll(st)
}

LatestUiClampScroll(st) {
    if !st.Has("listArea")
        return
    maxScroll := Max(0, st["rows"].Length * 36 - st["listArea"][4])
    st["scroll"] := Round(Max(0, Min(maxScroll, st["scroll"])))
}

; ---------- 绘制工具 ----------

LatestUiFont(size, bold := false, family := "Microsoft YaHei UI") {
    static fonts := Map(), families := Map()
    key := family . "|" . size . "|" . bold
    if fonts.Has(key)
        return fonts[key]
    if !families.Has(family) {
        created := 0
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", family, "Ptr", 0, "Ptr*", &created)
        families[family] := created
    }
    font := 0
    DllCall("gdiplus\GdipCreateFont", "Ptr", families[family], "Float", size * 4 / 3, "Int", bold ? 1 : 0, "Int", 2, "Ptr*", &font)
    fonts[key] := font
    return font
}

; align：0 左 1 中 2 右；trim：3 末尾省略号，5 路径中间省略（保留开头和文件夹名末尾）
LatestUiFormat(align, trim) {
    static formats := Map()
    key := align . "|" . trim
    if formats.Has(key)
        return formats[key]
    fmt := 0
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0x1000, "Int", 0, "Ptr*", &fmt)  ; NoWrap
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmt, "Int", align)
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", 1)
    DllCall("gdiplus\GdipSetStringFormatTrimming", "Ptr", fmt, "Int", trim)
    formats[key] := fmt
    return fmt
}

LatestUiText(g, text, x, y, w, h, size, color, bold := false, align := 0, trim := 3, family := "Microsoft YaHei UI") {
    text := String(text)
    if (text = "" || w <= 2)
        return
    brush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", ModernPanelArgb(color), "Ptr*", &brush)
    rect := Buffer(16)
    NumPut("Float", x, "Float", y, "Float", w, "Float", h, rect)
    DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", text, "Int", -1, "Ptr", LatestUiFont(size, bold, family)
        , "Ptr", rect, "Ptr", LatestUiFormat(align, trim), "Ptr", brush)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
}

LatestUiGlyph(g, glyph, x, y, w, h, size, color) {
    LatestUiText(g, glyph, x, y, w, h, size, color, false, 1, 0, "Segoe MDL2 Assets")
}

LatestUiRect(g, x, y, w, h, fill, radius := 0, border := "") {
    if (w <= 0 || h <= 0)
        return
    if (radius = 0 && border = "") {
        brush := 0
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", ModernPanelArgb(fill), "Ptr*", &brush)
        DllCall("gdiplus\GdipFillRectangle", "Ptr", g, "Ptr", brush, "Float", x, "Float", y, "Float", w, "Float", h)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
        return
    }
    path := ModernPanelRoundPath(x + 0.5, y + 0.5, w - 1, h - 1, radius)
    if (fill != "")
        ModernPanelFillPath(g, path, ModernPanelArgb(fill))
    if (border != "") {
        pen := 0
        DllCall("gdiplus\GdipCreatePen1", "UInt", ModernPanelArgb(border), "Float", 1, "Int", 0, "Ptr*", &pen)
        DllCall("gdiplus\GdipDrawPath", "Ptr", g, "Ptr", pen, "Ptr", path)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    }
    DllCall("gdiplus\GdipDeletePath", "Ptr", path)
}

; 文字宽度（逻辑像素），结果缓存
LatestUiMeasure(st, text, size, bold := false, family := "Microsoft YaHei UI") {
    key := family . "|" . size . "|" . bold . "|" . text
    if st["measure"].Has(key)
        return st["measure"][key]
    if !st.Has("mg") {
        bmp := 0, mg := 0
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", 1, "Int", 1, "Int", 0, "Int", 0xE200B, "Ptr", 0, "Ptr*", &bmp)
        DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bmp, "Ptr*", &mg)
        DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", mg, "Int", 5)
        st["mgBmp"] := bmp, st["mg"] := mg
    }
    layout := Buffer(16, 0), box := Buffer(16, 0)
    NumPut("Float", 0, "Float", 0, "Float", 10000, "Float", 200, layout)
    DllCall("gdiplus\GdipMeasureString", "Ptr", st["mg"], "WStr", text, "Int", -1, "Ptr", LatestUiFont(size, bold, family)
        , "Ptr", layout, "Ptr", LatestUiFormat(0, 0), "Ptr", box, "Int*", 0, "Int*", 0)
    width := Ceil(NumGet(box, 8, "Float"))
    st["measure"][key] := width
    return width
}

; 登记可点击区域；后登记的在上层。hand 为真时显示手形光标。
LatestUiHit(st, id, x, y, w, h, hand := true) {
    st["hits"].Push([id, x, y, w, h, hand])
}

LatestUiHitAt(st, x, y) {
    hits := st["hits"]
    loop hits.Length {
        hit := hits[hits.Length - A_Index + 1]
        if (x >= hit[2] && x < hit[2] + hit[4] && y >= hit[3] && y < hit[3] + hit[5])
            return hit
    }
    return ""
}

; 列表“状态”列：[文字, 底色（空为不画底）, 字色]。只有“全局最新”用绿色徽标，其余用灰字，避免满屏彩色。
LatestUiStatusBadge(st, index) {
    group := st["groups"][index]
    if (index = st["latest"])
        return ["★ 全局最新", "D3EFDC", "166534"]
    if (group["copies"].Length = 1)
        return ["只有 1 份", "", "9CA3AF"]
    if group["clash"]
        return ["需核对", "", "B42318"]
    if group["older"]
        return ["含旧版", "", "6B7280"]
    return ["副本相同", "", "6B7280"]
}

LatestUiShortTime(time) {
    return SubStr(time, 1, 4) = A_YYYY ? FormatTime(time, "MM-dd HH:mm") : FormatTime(time, "yyyy-MM-dd")
}

; ---------- 绘制 ----------

LatestUiRender(st, pw, ph) {
    scale := A_ScreenDPI / 96
    if (!st["dib"] || st["dibW"] != pw || st["dibH"] != ph) {
        if st["bmp"]
            DllCall("gdiplus\GdipDisposeImage", "Ptr", st["bmp"])
        if st["dib"]
            DllCall("DeleteObject", "Ptr", st["dib"])
        info := Buffer(40, 0)
        NumPut("UInt", 40, info, 0), NumPut("Int", pw, info, 4), NumPut("Int", -ph, info, 8)
        NumPut("UShort", 1, info, 12), NumPut("UShort", 32, info, 14)
        bits := 0, bmp := 0
        st["dib"] := DllCall("CreateDIBSection", "Ptr", 0, "Ptr", info, "UInt", 0, "Ptr*", &bits, "Ptr", 0, "UInt", 0, "Ptr")
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", pw, "Int", ph, "Int", pw * 4, "Int", 0xE200B, "Ptr", bits, "Ptr*", &bmp)
        st["bmp"] := bmp, st["dibW"] := pw, st["dibH"] := ph
    }
    g := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", st["bmp"], "Ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 5)
    DllCall("gdiplus\GdipScaleWorldTransform", "Ptr", g, "Float", scale, "Float", scale, "Int", 0)
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", ModernPanelArgb("FFFFFF"))
    st["hits"] := []
    W := pw / scale, H := ph / scale
    pad := 18, cw := W - pad * 2
    LatestUiDrawHeader(st, g, W)
    y := 48 + 14
    LatestUiDrawScope(st, g, pad, y, cw, 40)
    y += 40 + 6
    LatestUiDrawSummary(st, g, pad, y, cw, 26)
    y += 26 + 8
    y += LatestUiDrawToolbar(st, g, pad, y, cw, 34) + 12
    footerY := H - 14 - 34
    ; 副本区高度只随窗口变化，不随选中行变化，切换时列表不跳动
    avail := footerY - 12 - y
    copyRows := Max(2, Min(6, Floor((avail * 0.42 - 40) / 34)))
    detailH := 40 + copyRows * 34 + 6
    detailY := footerY - 12 - detailH
    LatestUiDrawList(st, g, pad, y, cw, Max(110, detailY - 12 - y))
    LatestUiDrawDetail(st, g, pad, detailY, cw, detailH)
    LatestUiDrawFooter(st, g, pad, footerY, cw, 34)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    st["dirty"] := false
}

LatestUiDrawHeader(st, g, W) {
    LatestUiRect(g, 0, 0, W, 48, "F7F8FA")
    LatestUiRect(g, 0, 47, W, 1, "E4E6EB")
    LatestUiRect(g, 16, 9, 30, 30, "ECEEF1", 8, "E1E4EA")
    LatestUiGlyph(g, Chr(0xE721), 16, 9, 30, 30, 11, "374151")
    tw := LatestUiMeasure(st, st["title"], 12.5, true)
    LatestUiText(g, st["title"], 56, 0, tw + 4, 48, 12.5, "1F2329", true)
    LatestUiText(g, "同名文件自动归组 · 按修改时间判定最新", 56 + tw + 12, 1, W - 56 - tw - 12 - 160, 48, 9.5, "6B7280")
    maxed := DllCall("IsZoomed", "Ptr", st["gui"].Hwnd)
    for i, item in [["min", Chr(0xE921)], ["max", Chr(maxed ? 0xE923 : 0xE922)], ["close", Chr(0xE8BB)]] {
        bx := W - (4 - i) * 46
        hot := st["hover"] = item[1]
        if hot
            LatestUiRect(g, bx, 0, 46, 47, item[1] = "close" ? "E81123" : "E9EBEF")
        LatestUiGlyph(g, item[2], bx, 0, 46, 47, 7.5, hot && item[1] = "close" ? "FFFFFF" : "4B5563")
        LatestUiHit(st, item[1], bx, 0, 46, 47, false)
    }
}

LatestUiDrawScope(st, g, x, y, w, h) {
    scan := st["scan"]
    LatestUiRect(g, x, y, w, h, "FFFFFF", 8, "E4E6EB")
    LatestUiGlyph(g, Chr(0xE8B7), x + 12, y, 22, h, 11, "9CA3AF")
    labelW := LatestUiMeasure(st, "查找范围", 9.5)
    LatestUiText(g, "查找范围", x + 40, y, labelW + 2, h, 9.5, "6B7280")
    ; 右侧：重新扫描按钮、扫描信息
    bw := 96, bx := x + w - 6 - bw
    LatestUiRect(g, bx, y + 5, bw, h - 10, st["hover"] = "rescan" ? "E9EBEF" : "F3F4F6", 7, "E1E4EA")
    LatestUiGlyph(g, Chr(0xE72C), bx + 10, y + 5, 18, h - 10, 9, "374151")
    LatestUiText(g, "重新扫描", bx + 30, y + 5, bw - 34, h - 10, 9.5, "1F2329", true)
    LatestUiHit(st, "rescan", bx, y + 5, bw, h - 10)
    info := "扫描完成"
    if scan.Has("elapsed")
        info .= " · 用时 " . Format("{:.1f}", scan["elapsed"] / 1000) . " 秒"
    infoColor := "3F7D58", dotColor := "4CAF73"
    if scan["truncated"]
        info := "文件太多，只比较了前 " . scan["limit"] . " 个", infoColor := "B45309", dotColor := "D97706"
    iw := LatestUiMeasure(st, info, 9)
    ix := bx - 14 - iw
    LatestUiRect(g, ix - 10, y + h / 2 - 3, 6, 6, dotColor, 3)
    LatestUiText(g, info, ix, y, iw + 2, h, 9, infoColor)
    ; 中间：路径 + “含子文件夹”
    root := scan["root"] != "" ? scan["root"] : "选中的文件"
    chip := scan["folders"] ? "含子文件夹" : ""
    chipW := chip != "" ? LatestUiMeasure(st, chip, 8.5) + 18 : 0
    px := x + 40 + labelW + 10
    pathW := Min(LatestUiMeasure(st, root, 10, true) + 2, ix - 24 - px - chipW - 8)
    LatestUiText(g, root, px, y, pathW, h, 10, "1F2329", true, 0, 5)
    if (chip != "") {
        LatestUiRect(g, px + pathW + 8, y + 9, chipW, h - 18, "F3F4F6", 11, "E1E4EA")
        LatestUiText(g, chip, px + pathW + 8, y + 9, chipW, h - 18, 8.5, "4B5563", false, 1)
    }
}

; 统计一行字：数字加粗，其余灰色；右侧是同名判定规则
LatestUiDrawSummary(st, g, x, y, w, h) {
    scan := st["scan"]
    items := [["共", scan["files"], "个文件"], ["", st["groups"].Length, "组"], ["", st["multi"], "组有多份副本"]
        , ["已忽略", scan["skipped"], "个备份 / 临时文件"]]
    cx := x + 4
    for i, item in items {
        if (i > 1) {
            LatestUiText(g, "·", cx + 6, y, 10, h, 9.5, "C4C8CF", false, 1)
            cx += 22
        }
        for j, part in item {
            if (part = "")
                continue
            bold := j = 2
            pw := LatestUiMeasure(st, part, 9.5, bold)
            LatestUiText(g, part, cx, y, pw + 2, h, 9.5, bold ? "1F2329" : "6B7280", bold)
            cx += pw + 3
        }
    }
    rule := "同名判定已忽略「- 副本」「(1)」「v2」、日期、「最终版」等后缀"
    rw := Min(LatestUiMeasure(st, rule, 9) + 2, x + w - cx - 24)
    LatestUiText(g, rule, x + w - rw, y, rw, h, 9, "9CA3AF")
}

LatestUiDrawToolbar(st, g, x, y, w, h) {
    ; 右侧：只看有多份的
    label := "只看有多份的"
    lw := LatestUiMeasure(st, label, 9.5)
    on := st["prefs"]["onlyMulti"]
    lx := x + w - lw, sx := lx - 8 - 36
    LatestUiRect(g, sx, y + (h - 20) / 2, 36, 20, on ? "2B3038" : "D1D5DB", 10)
    LatestUiRect(g, on ? sx + 18 : sx + 2, y + (h - 20) / 2 + 2, 16, 16, "FFFFFF", 8)
    LatestUiText(g, label, lx, y, lw + 2, h, 9.5, "1F2329")
    LatestUiHit(st, "toggle", sx, y, x + w - sx, h)
    ; 排序框、类型分段宽度
    sortLabel := LatestUiSortLabels()[st["prefs"]["sort"]]
    sw1 := LatestUiMeasure(st, "排序", 9.5), sw2 := LatestUiMeasure(st, sortLabel, 9.5)
    sortW := 12 + sw1 + 8 + sw2 + 30
    segWs := [], segTotal := 6
    for _, cat in st["cats"] {
        segWs.Push(LatestUiMeasure(st, cat, 9.5, true) + 26)
        segTotal += segWs[segWs.Length]
    }
    ; 宽度不够时折成两行：第一行搜索 + 只看多份，第二行类型筛选 + 排序
    twoRows := sx - 20 - x - 12 - segTotal - 12 - sortW < 200
    searchW := twoRows ? Min(420, sx - 20 - x) : Min(320, sx - 20 - x - 12 - segTotal - 12 - sortW)
    ; 搜索框（系统 Edit 叠在画好的框上）
    focused := DllCall("GetFocus", "Ptr") = st["search"].Hwnd
    LatestUiRect(g, x, y, searchW, h, "FFFFFF", 8, focused ? "9CA3AF" : "DCDFE4")
    LatestUiGlyph(g, Chr(0xE721), x + 6, y, 24, h, 9.5, "6B7280")
    LatestUiHit(st, "search", x, y, searchW, h, false)
    rect := [x + 32, y + (h - 22) / 2, searchW - 40, 22]
    if (st["searchRect"] = "" || st["searchRect"][1] != rect[1] || st["searchRect"][2] != rect[2] || st["searchRect"][3] != rect[3]) {
        st["searchRect"] := rect
        st["search"].Move(Round(rect[1]), Round(rect[2]), Round(rect[3]), rect[4])
    }
    ; 类型分段
    segX := x + searchW + 12
    if twoRows
        segX := x, y += h + 8
    LatestUiRect(g, segX, y, segTotal, h, "F1F3F6", 8)
    cx := segX + 3
    for i, cat in st["cats"] {
        selected := cat = st["filter"]
        if selected
            LatestUiRect(g, cx, y + 3, segWs[i], h - 6, "FFFFFF", 6, "E1E4EA")
        else if (st["hover"] = "seg:" . i)
            LatestUiRect(g, cx, y + 3, segWs[i], h - 6, "E9EBEF", 6)
        LatestUiText(g, cat, cx, y + 3, segWs[i], h - 6, 9.5, selected ? "1F2329" : "6B7280", selected, 1)
        LatestUiHit(st, "seg:" . i, cx, y + 3, segWs[i], h - 6)
        cx += segWs[i]
    }
    ; 排序
    sortX := segX + segTotal + 12
    LatestUiRect(g, sortX, y, sortW, h, st["hover"] = "sort" ? "F7F8FA" : "FFFFFF", 8, "DCDFE4")
    LatestUiText(g, "排序", sortX + 12, y, sw1 + 2, h, 9.5, "9CA3AF")
    LatestUiText(g, sortLabel, sortX + 12 + sw1 + 8, y, sw2 + 2, h, 9.5, "1F2329")
    LatestUiGlyph(g, Chr(0xE70D), sortX + sortW - 26, y, 18, h, 7.5, "6B7280")
    LatestUiHit(st, "sort", sortX, y, sortW, h)
    st["sortAnchor"] := [sortX, y + h + 4]
    return twoRows ? h * 2 + 8 : h
}

LatestUiDrawList(st, g, x, y, w, h) {
    rowH := 36, headH := 36
    LatestUiRect(g, x, y, w, h, "FFFFFF", 8, "E4E6EB")
    LatestUiRect(g, x + 1, y + 1, w - 2, headH - 1, "F7F8FA", 7)
    LatestUiRect(g, x + 1, y + 10, w - 2, headH - 10, "F7F8FA")
    LatestUiRect(g, x + 1, y + headH, w - 2, 1, "ECEEF1")
    area := [x + 1, y + headH + 1, w - 2, h - headH - 2]
    st["listArea"] := area
    rows := st["rows"]
    if st.Has("ensureSel") {
        st.Delete("ensureSel")
        LatestUiEnsureVisible(st)
    }
    LatestUiClampScroll(st)
    contentH := rows.Length * rowH
    showBar := contentH > area[4]
    ; 列：类型+文件名 | 所在文件夹 | 修改时间 | 份数 | 状态 | 箭头
    x0 := x + 16, right := x + w - 14 - (showBar ? 8 : 0)
    chevW := 16, statusW := 112, countW := 56, timeW := 110
    flex := right - chevW - statusW - countW - timeW - x0
    nameW := Round(flex * 0.56), folderW := flex - nameW
    folderX := x0 + nameW, timeX := folderX + folderW, countX := timeX + timeW, statusX := countX + countW, chevX := statusX + statusW
    for _, col in [["文件名（最新那份）", x0, nameW, 0], ["最新副本所在文件夹", folderX + 12, folderW - 12, 0]
            , ["修改时间", timeX, timeW, 0], ["份数", countX, countW, 1], ["状态", statusX + 4, statusW, 0]]
        LatestUiText(g, col[1], col[2], y, col[3], headH, 9, "6B7280", false, col[4])
    if !rows.Length {
        LatestUiText(g, "没有符合条件的文件" . (st["prefs"]["onlyMulti"] ? "（可以关掉右上角“只看有多份的”）" : "")
            , area[1], area[2], area[3], Min(area[4], 120), 10, "9CA3AF", false, 1)
        return
    }
    DllCall("gdiplus\GdipSetClipRect", "Ptr", g, "Float", area[1], "Float", area[2], "Float", area[3], "Float", area[4], "Int", 0)
    first := Floor(st["scroll"] / rowH) + 1
    last := Min(rows.Length, first + Ceil(area[4] / rowH) + 1)
    i := first
    while (i <= last) {
        index := rows[i], group := st["groups"][index], newest := group["newest"]
        ry := area[2] + (i - 1) * rowH - st["scroll"]
        id := "row:" . i
        if (index = st["sel"]) {
            LatestUiRect(g, area[1], ry, area[3], rowH, "F1F3F6")
            LatestUiRect(g, area[1], ry, 3, rowH, "2B3038")
        } else if (st["hover"] = id) {
            LatestUiRect(g, area[1], ry, area[3], rowH, "F9FAFB")
        }
        if (i < rows.Length)
            LatestUiRect(g, x0, ry + rowH - 1, right - x0, 1, "F0F1F4")
        cat := LatestVersionCategory(newest["name"])[2]
        LatestUiRect(g, x0, ry + (rowH - 20) / 2, 42, 20, "F1F3F6", 5)
        LatestUiText(g, cat = "压缩包" ? "ZIP" : cat = "图片" ? "IMG" : cat = "其他" ? "FILE" : cat = "Excel" ? "XLS" : cat = "Word" ? "DOC" : cat
            , x0, ry + (rowH - 20) / 2, 42, 20, 7.5, "6B7280", true, 1)
        LatestUiText(g, newest["name"], x0 + 52, ry, nameW - 60, rowH, 10, "1F2329", true)
        LatestUiText(g, LatestVersionNewestFolders(group), folderX + 12, ry, folderW - 20, rowH, 9.5, "6B7280", false, 0, 5)
        LatestUiText(g, LatestUiShortTime(newest["time"]), timeX, ry, timeW, rowH, 9.5, "374151")
        n := group["copies"].Length
        LatestUiRect(g, countX + countW / 2 - 15, ry + (rowH - 22) / 2, 30, 22, "F1F3F6", 11)
        LatestUiText(g, n, countX + countW / 2 - 15, ry + (rowH - 22) / 2, 30, 22, 9, n > 1 ? "1F2329" : "9CA3AF", true, 1)
        badge := LatestUiStatusBadge(st, index)
        if (badge[2] != "") {
            bw := LatestUiMeasure(st, badge[1], 8.5, true) + 18
            LatestUiRect(g, statusX + 4, ry + (rowH - 22) / 2, bw, 22, badge[2], 11)
            LatestUiText(g, badge[1], statusX + 4, ry + (rowH - 22) / 2, bw, 22, 8.5, badge[3], true, 1)
        } else {
            LatestUiText(g, badge[1], statusX + 4, ry, statusW - 8, rowH, 9, badge[3])
        }
        LatestUiGlyph(g, Chr(0xE76C), chevX, ry, chevW, rowH, 7, "C4C8CF")
        top := Max(ry, area[2]), bottom := Min(ry + rowH, area[2] + area[4])
        if (bottom > top)
            LatestUiHit(st, id, area[1], top, area[3] - (showBar ? 14 : 0), bottom - top, false)
        i++
    }
    DllCall("gdiplus\GdipResetClip", "Ptr", g)
    if showBar {
        trackX := x + w - 12, trackY := area[2] + 4, trackH := area[4] - 8
        thumbH := Max(28, trackH * area[4] / contentH)
        thumbY := trackY + (trackH - thumbH) * st["scroll"] / (contentH - area[4])
        hot := st["hover"] = "thumb" || IsObject(st["drag"])
        LatestUiRect(g, trackX + (hot ? 0 : 1), thumbY, hot ? 8 : 6, thumbH, hot ? "9CA3AF" : "D1D5DB", hot ? 4 : 3)
        LatestUiHit(st, "track", trackX - 4, trackY, 16, trackH, false)
        LatestUiHit(st, "thumb", trackX - 4, thumbY, 16, thumbH, false)
        st["bar"] := [trackY, trackH, thumbH, contentH - area[4]]
    }
}

; 副本行的小标记：[文字, 底色, 字色]；旧版本不加标记，只在时间后写“早多久”
LatestUiCopyBadge(group, index) {
    copy := group["copies"][index], newest := group["newest"]
    if (index = 1)
        return ["最新", "D3EFDC", "166534"]
    if (copy["time"] = newest["time"])
        return copy["size"] = newest["size"] ? ["与最新相同", "F1F3F6", "4B5563"] : ["需核对", "FDECEC", "B42318"]
    return ""
}

LatestUiDrawDetail(st, g, x, y, w, h) {
    LatestUiRect(g, x, y, w, h, "FFFFFF", 8, "E4E6EB")
    st["detailRect"] := [x, y, w, h]
    if !st["sel"] {
        LatestUiText(g, "单击上方列表中的一行，查看这份文件的全部副本", x, y, w, h, 10, "9CA3AF", false, 1)
        return
    }
    group := st["groups"][st["sel"]], newest := group["newest"], copies := group["copies"]
    ; 标题行
    hint := "双击任一行打开所在文件夹"
    hintW := LatestUiMeasure(st, hint, 9) + 2
    head := "「" . newest["name"] . "」的全部副本"
    count := "共 " . copies.Length . " 份"
    cw := LatestUiMeasure(st, count, 10, true)
    status := copies.Length > 1 ? LatestVersionStatus(group) : ""
    if (status != "")
        status := "其中 " . status
    hw := Min(LatestUiMeasure(st, head, 10, true) + 2, w * 0.5)
    LatestUiText(g, head, x + 16, y, hw, 40, 10, "1F2329", true)
    LatestUiText(g, count, x + 16 + hw + 6, y, cw + 2, 40, 10, "1F2329", true)
    sx := x + 16 + hw + 6 + cw + 10
    LatestUiText(g, status, sx, y, x + w - 16 - hintW - 16 - sx, 40, 9, "6B7280")
    LatestUiText(g, hint, x + w - 16 - hintW, y, hintW, 40, 9, "9CA3AF")
    LatestUiRect(g, x + 14, y + 40, w - 28, 1, "ECEEF1")
    ; 副本行（纵向，可滚动）
    rowH := 34, ay := y + 41, ah := h - 41 - 5
    maxScroll := Max(0, copies.Length * rowH - ah)
    st["copyMax"] := maxScroll
    st["copyScroll"] := Round(Max(0, Min(maxScroll, st["copyScroll"])))
    folderW := Min(300, Max(160, w * 0.26))
    btnW := 84, btnX := x + w - 16 - (maxScroll ? 10 : 0) - btnW
    DllCall("gdiplus\GdipSetClipRect", "Ptr", g, "Float", x + 1, "Float", ay, "Float", w - 2, "Float", ah, "Int", 0)
    for i, copy in copies {
        ry := ay + (i - 1) * rowH - st["copyScroll"]
        if (ry + rowH < ay || ry > ay + ah)
            continue
        rowId := "copyRow:" . i
        if (st["hover"] = rowId || st["hover"] = "copy:" . i)
            LatestUiRect(g, x + 1, ry, w - 2, rowH, "F9FAFB")
        if (i < copies.Length)
            LatestUiRect(g, x + 14, ry + rowH - 1, w - 28, 1, "F0F1F4")
        isNew := i = 1
        LatestUiText(g, LatestVersionFolderLabel(copy["rel"]), x + 24, ry, folderW - 16, rowH, 9.5, isNew ? "166534" : "1F2329", true, 0, 5)
        cx := x + 24 + folderW
        badge := LatestUiCopyBadge(group, i)
        if IsObject(badge) {
            bw := LatestUiMeasure(st, badge[1], 8.5, true) + 16
            LatestUiRect(g, cx, ry + (rowH - 20) / 2, bw, 20, badge[2], 10)
            LatestUiText(g, badge[1], cx, ry + (rowH - 20) / 2, bw, 20, 8.5, badge[3], true, 1)
            cx += bw + 12
        }
        timeText := FormatTime(copy["time"], "yyyy-MM-dd HH:mm:ss")
        tw := LatestUiMeasure(st, timeText, 9.5)
        LatestUiText(g, timeText, cx, ry, tw + 2, rowH, 9.5, "374151")
        cx += tw + 14
        sizeText := LatestVersionSize(copy["size"])
        zw := LatestUiMeasure(st, sizeText, 9.5)
        LatestUiText(g, sizeText, cx, ry, zw + 2, rowH, 9.5, "6B7280")
        cx += zw + 14
        if (!isNew && copy["time"] != newest["time"])
            LatestUiText(g, "早 " . LatestVersionAge(newest["time"], copy["time"]), cx, ry, btnX - 12 - cx, rowH, 9.5, "9CA3AF")
        id := "copy:" . i
        LatestUiRect(g, btnX, ry + (rowH - 26) / 2, btnW, 26, st["hover"] = id ? "ECEEF1" : "F7F8FA", 6, "DCDFE4")
        LatestUiText(g, "打开文件夹", btnX, ry + (rowH - 26) / 2, btnW, 26, 8.5, "1F2329", false, 1)
        top := Max(ry, ay), bottom := Min(ry + rowH, ay + ah)
        if (bottom > top) {
            LatestUiHit(st, rowId, x + 1, top, w - 2, bottom - top, false)
            bt := Max(ry + (rowH - 26) / 2, ay), bb := Min(ry + (rowH + 26) / 2, ay + ah)
            if (bb > bt)
                LatestUiHit(st, id, btnX, bt, btnW, bb - bt)
        }
    }
    DllCall("gdiplus\GdipResetClip", "Ptr", g)
    if maxScroll {
        trackY := ay + 4, trackH := ah - 8, contentH := copies.Length * rowH
        thumbH := Max(24, trackH * ah / contentH)
        LatestUiRect(g, x + w - 11, trackY + (trackH - thumbH) * st["copyScroll"] / maxScroll, 5, thumbH, "D1D5DB", 2.5)
    }
}

LatestUiDrawFooter(st, g, x, y, w, h) {
    ; [id, 文字, 宽, 底色, 悬停底色, 字色, 描边, 图标]
    buttons := [["btnLocate", "定位最新文件", 136, "2B3038", "1F2329", "FFFFFF", "", Chr(0xE707)]
        , ["btnCopy", "复制结果", 96, "F3F4F6", "E9EBEF", "1F2329", "E1E4EA", ""]
        , ["btnClose", "关闭", 76, "FFFFFF", "F7F8FA", "1F2329", "DCDFE4", ""]]
    bx := x + w
    for _, b in buttons {
        bx -= b[3]
        LatestUiRect(g, bx, y, b[3], h, st["hover"] = b[1] ? b[5] : b[4], 8, b[7])
        if (b[8] != "") {
            tw := LatestUiMeasure(st, b[2], 9.5, true)
            sx := bx + (b[3] - tw - 22) / 2
            LatestUiGlyph(g, b[8], sx, y, 16, h, 9.5, b[6])
            LatestUiText(g, b[2], sx + 22, y, tw + 2, h, 9.5, b[6], true)
        } else {
            LatestUiText(g, b[2], bx, y, b[3], h, 9.5, b[6], b[1] = "btnCopy", 1)
        }
        LatestUiHit(st, b[1], bx, y, b[3], h)
        bx -= 10
    }
    LatestUiText(g, "↑↓ 切换 · Enter 定位最新那份 · Ctrl+F 搜索 · Esc 关闭"
        , x + 2, y, bx - x - 10, h, 9, "9CA3AF")
}

; ---------- 窗口消息 ----------

LatestUiPoint(lParam) {
    x := lParam & 0xFFFF, y := (lParam >> 16) & 0xFFFF
    return [(x > 0x7FFF ? x - 0x10000 : x), (y > 0x7FFF ? y - 0x10000 : y)]
}

LatestUiOnErase(wParam, lParam, msg, hwnd) {
    if LatestUiStates().Has(hwnd)
        return 1
}

LatestUiOnPaint(wParam, lParam, msg, hwnd) {
    states := LatestUiStates()
    if !states.Has(hwnd)
        return
    st := states[hwnd]
    ps := Buffer(A_PtrSize = 8 ? 72 : 64, 0)
    hdc := DllCall("BeginPaint", "Ptr", hwnd, "Ptr", ps, "Ptr")
    rc := Buffer(16, 0)
    DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rc)
    pw := NumGet(rc, 8, "Int"), ph := NumGet(rc, 12, "Int")
    if (pw > 0 && ph > 0) {
        if (st["dirty"] || st["dibW"] != pw || st["dibH"] != ph)
            LatestUiRender(st, pw, ph)
        mdc := DllCall("CreateCompatibleDC", "Ptr", hdc, "Ptr")
        old := DllCall("SelectObject", "Ptr", mdc, "Ptr", st["dib"], "Ptr")
        DllCall("BitBlt", "Ptr", hdc, "Int", 0, "Int", 0, "Int", pw, "Int", ph, "Ptr", mdc, "Int", 0, "Int", 0, "UInt", 0x00CC0020)
        DllCall("SelectObject", "Ptr", mdc, "Ptr", old)
        DllCall("DeleteDC", "Ptr", mdc)
    }
    DllCall("EndPaint", "Ptr", hwnd, "Ptr", ps)
    return 0
}

; 客户区占满整个窗口（去掉系统标题栏）；最大化时向内收一圈边框，避免内容伸出屏幕。
LatestUiOnNcCalcSize(wParam, lParam, msg, hwnd) {
    if !LatestUiStates().Has(hwnd)
        return
    if (wParam && DllCall("IsZoomed", "Ptr", hwnd)) {
        frame := DllCall("GetSystemMetrics", "Int", 32) + DllCall("GetSystemMetrics", "Int", 92)
        edge := DllCall("GetSystemMetrics", "Int", 33) + DllCall("GetSystemMetrics", "Int", 92)
        NumPut("Int", NumGet(lParam, 0, "Int") + frame, lParam, 0)
        NumPut("Int", NumGet(lParam, 4, "Int") + edge, lParam, 4)
        NumPut("Int", NumGet(lParam, 8, "Int") - frame, lParam, 8)
        NumPut("Int", NumGet(lParam, 12, "Int") - edge, lParam, 12)
    }
    return 0
}

; 标题栏可拖动（双击最大化、拖到屏幕边缘贴靠），四边可拉伸。
LatestUiOnNcHitTest(wParam, lParam, msg, hwnd) {
    states := LatestUiStates()
    if !states.Has(hwnd)
        return
    st := states[hwnd]
    point := LatestUiPoint(lParam)
    pt := Buffer(8)
    NumPut("Int", point[1], "Int", point[2], pt)
    DllCall("ScreenToClient", "Ptr", hwnd, "Ptr", pt)
    rc := Buffer(16, 0)
    DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rc)
    scale := A_ScreenDPI / 96
    cx := NumGet(pt, 0, "Int"), cy := NumGet(pt, 4, "Int"), pw := NumGet(rc, 8, "Int"), ph := NumGet(rc, 12, "Int")
    if !DllCall("IsZoomed", "Ptr", hwnd) {
        edge := Round(6 * scale)
        left := cx < edge, right := cx >= pw - edge, top := cy < edge, bottom := cy >= ph - edge
        if (top && left)
            return 13
        if (top && right)
            return 14
        if (bottom && left)
            return 16
        if (bottom && right)
            return 17
        if left
            return 10
        if right
            return 11
        if top
            return 12
        if bottom
            return 15
    }
    if (cy < 48 * scale && cx < pw - 138 * scale)
        return 2  ; HTCAPTION
    return 1
}

LatestUiOnMouseMove(wParam, lParam, msg, hwnd) {
    states := LatestUiStates()
    if !states.Has(hwnd)
        return
    st := states[hwnd]
    scale := A_ScreenDPI / 96
    point := LatestUiPoint(lParam)
    x := point[1] / scale, y := point[2] / scale
    if !st["tracking"] {
        tme := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
        NumPut("UInt", tme.Size, tme, 0), NumPut("UInt", 2, tme, 4), NumPut("Ptr", hwnd, tme, 8)  ; TME_LEAVE
        DllCall("TrackMouseEvent", "Ptr", tme)
        st["tracking"] := true
    }
    if IsObject(st["drag"]) {
        drag := st["drag"], bar := st["bar"]
        if (bar[2] > bar[3])
            st["scroll"] := drag[2] + (y - drag[1]) * bar[4] / (bar[2] - bar[3])
        LatestUiClampScroll(st)
        LatestUiInvalidate(st)
        return
    }
    hit := LatestUiHitAt(st, x, y)
    id := IsObject(hit) ? hit[1] : ""
    if (id != st["hover"]) {
        st["hover"] := id
        LatestUiInvalidate(st)
    }
}

LatestUiOnMouseLeave(wParam, lParam, msg, hwnd) {
    states := LatestUiStates()
    if !states.Has(hwnd)
        return
    st := states[hwnd]
    st["tracking"] := false
    if (st["hover"] != "" && !IsObject(st["drag"])) {
        st["hover"] := ""
        LatestUiInvalidate(st)
    }
}

LatestUiOnMouseDown(wParam, lParam, msg, hwnd) {
    states := LatestUiStates()
    if !states.Has(hwnd)
        return
    st := states[hwnd]
    scale := A_ScreenDPI / 96
    point := LatestUiPoint(lParam)
    x := point[1] / scale, y := point[2] / scale
    hit := LatestUiHitAt(st, x, y)
    id := IsObject(hit) ? hit[1] : ""
    st["pressed"] := id
    if (id = "search") {
        st["search"].Focus()
        return 0
    }
    DllCall("SetFocus", "Ptr", hwnd)  ; 让方向键、Enter 交给列表
    if (id = "thumb") {
        st["drag"] := [y, st["scroll"]]
        DllCall("SetCapture", "Ptr", hwnd)
    } else if (id = "track") {
        page := st["listArea"][4] - 36
        st["scroll"] += (y < st["bar"][1] + (st["bar"][2] - st["bar"][3]) * st["scroll"] / Max(1, st["bar"][4])) ? -page : page
        LatestUiClampScroll(st)
        LatestUiInvalidate(st)
    } else if (SubStr(id, 1, 4) = "row:" || SubStr(id, 1, 8) = "copyRow:") {
        isCopy := SubStr(id, 1, 8) = "copyRow:"
        last := st["lastClick"]
        if !isCopy
            LatestUiSelect(st, st["rows"][Integer(SubStr(id, 5))])
        if (last[2] = id && A_TickCount - last[1] <= DllCall("GetDoubleClickTime")) {
            st["lastClick"] := [0, ""]
            if isCopy
                SetTimer(LatestUiReveal.Bind(st, st["groups"][st["sel"]]["copies"][Integer(SubStr(id, 9))]["path"]), -1)
            else
                SetTimer(LatestUiLocateSelected.Bind(st), -1)
        } else {
            st["lastClick"] := [A_TickCount, id]
        }
    }
    return 0
}

LatestUiOnMouseUp(wParam, lParam, msg, hwnd) {
    states := LatestUiStates()
    if !states.Has(hwnd)
        return
    st := states[hwnd]
    if IsObject(st["drag"]) {
        st["drag"] := ""
        DllCall("ReleaseCapture")
        LatestUiInvalidate(st)
        return 0
    }
    scale := A_ScreenDPI / 96
    point := LatestUiPoint(lParam)
    hit := LatestUiHitAt(st, point[1] / scale, point[2] / scale)
    id := IsObject(hit) ? hit[1] : ""
    pressed := st["pressed"]
    st["pressed"] := ""
    if (id = "" || id != pressed)
        return 0
    ; 延后执行，避免在消息处理中弹出菜单 / 对话框
    SetTimer(LatestUiClick.Bind(st, id, hit), -1)
    return 0
}

LatestUiClick(st, id, hit) {
    if !LatestUiStates().Has(st["gui"].Hwnd)
        return
    hwnd := st["gui"].Hwnd
    switch id {
        case "min":
            st["hover"] := ""
            PostMessage(0x112, 0xF020, 0, , hwnd)  ; SC_MINIMIZE
        case "max":
            PostMessage(0x112, DllCall("IsZoomed", "Ptr", hwnd) ? 0xF120 : 0xF030, 0, , hwnd)  ; SC_RESTORE / SC_MAXIMIZE
        case "close", "btnClose":
            LatestUiClose(st)
        case "rescan":
            LatestUiRescan(st)
        case "toggle":
            st["prefs"]["onlyMulti"] := !st["prefs"]["onlyMulti"]
            LatestUiRefill(st)
            LatestUiEnsureVisible(st)
        case "sort":
            LatestUiSortMenu(st, st["sortAnchor"][1], st["sortAnchor"][2])
        case "btnCopy":
            LatestUiCopyResult(st)
        case "btnLocate":
            LatestUiLocateSelected(st)
        default:
            if (SubStr(id, 1, 4) = "seg:") {
                st["filter"] := st["cats"][Integer(SubStr(id, 5))]
                LatestUiRefill(st)
                LatestUiEnsureVisible(st)
            } else if (SubStr(id, 1, 5) = "copy:" && st["sel"]) {
                LatestUiReveal(st, st["groups"][st["sel"]]["copies"][Integer(SubStr(id, 6))]["path"])
            }
    }
}

LatestUiOnWheel(wParam, lParam, msg, hwnd) {
    st := LatestUiFind(hwnd)
    if !IsObject(st)
        return
    delta := (wParam >> 16) & 0xFFFF
    delta := delta > 0x7FFF ? delta - 0x10000 : delta
    point := LatestUiPoint(lParam)
    pt := Buffer(8)
    NumPut("Int", point[1], "Int", point[2], pt)
    DllCall("ScreenToClient", "Ptr", st["gui"].Hwnd, "Ptr", pt)
    scale := A_ScreenDPI / 96
    y := NumGet(pt, 4, "Int") / scale
    if (st.Has("detailRect") && y >= st["detailRect"][2] && st.Has("copyMax") && st["copyMax"] > 0) {
        st["copyScroll"] -= delta / 120 * 34 * 2
    } else {
        st["scroll"] -= delta / 120 * 36 * 3
        LatestUiClampScroll(st)
    }
    LatestUiInvalidate(st)
    return 0
}

LatestUiOnSetCursor(wParam, lParam, msg, hwnd) {
    states := LatestUiStates()
    if (!states.Has(hwnd) || (lParam & 0xFFFF) != 1)
        return
    st := states[hwnd]
    for _, hit in st["hits"]
        if (hit[1] = st["hover"] && hit[6]) {
            DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", 32649, "Ptr"))  ; IDC_HAND
            return 1
        }
}

LatestUiOnKeyDown(wParam, lParam, msg, hwnd) {
    st := LatestUiFind(hwnd)
    if !IsObject(st)
        return
    inSearch := hwnd = st["search"].Hwnd
    ctrl := GetKeyState("Ctrl")
    switch wParam {
        case 0x26:
            LatestUiMoveSel(st, -1)
        case 0x28:
            LatestUiMoveSel(st, 1)
        case 0x21:
            LatestUiMoveSel(st, -Max(1, Floor(st["listArea"][4] / 36) - 1))
        case 0x22:
            LatestUiMoveSel(st, Max(1, Floor(st["listArea"][4] / 36) - 1))
        case 0x0D:
            SetTimer(LatestUiLocateSelected.Bind(st), -1)
        case 0x1B:
            if (inSearch && st["search"].Value != "") {
                st["search"].Value := ""
                st["query"] := ""
                LatestUiRefill(st)
            } else {
                SetTimer(LatestUiClose.Bind(st), -1)
            }
        case 0x46:
            if !ctrl
                return
            st["search"].Focus()
            SendMessage(0xB1, 0, -1, st["search"])  ; EM_SETSEL 全选
        case 0x24, 0x23:
            if inSearch
                return
            LatestUiMoveSel(st, wParam = 0x24 ? -st["rows"].Length : st["rows"].Length)
        case 0x43:
            if (!ctrl || inSearch)
                return
            LatestUiCopyResult(st)
        default:
            return
    }
    return 0
}
