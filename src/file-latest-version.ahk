#Requires AutoHotkey v2.0
; 找出最新版本：选中文件夹（连同子文件夹）或多个文件，把同一份文件散在各处的副本 / 版本归成一组，
; 按修改时间标出每组最新的那份。纯 AHK 实现，不依赖 Python，分享版也能用。
; 归组规则见 LatestVersionGroupKey：扩展名相同，文件名去掉“- 副本”“(1)”“v2”“20261104”“最终版”等版本后缀后相同，
; 就算同一份文件。CAD 备份 / 锁定文件（.bak .dwl .sv$ 等）、Office 临时文件 ~$ 和隐藏 / 系统文件不参与比较。
; 只读：不移动、不改名、不删除任何文件。
; 依赖 modern-panel-ui.ahk 和 cable-sort.ahk（气泡右键菜单复用 CableSortPopup），使用方须先 #Include 二者。

FindLatestFileVersions() {
    title := "找出最新版本"
    selected := GetSelectedFilePaths()
    if (selected.Length = 0) {
        MsgBox("请先在资源管理器或桌面选中文件夹（连同子文件夹一起查找），或选中同一文件的几个版本，再按 " . AutomationPanelHotkeyText() . "。", title, "Icon!")
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
; 界面按 2026-11-11 用户设计稿：左侧“第一步 · 先选一个文件”列表，右侧“第二步 · 看图”气泡连线图——
; 深色中心节点就是这份文件，连线连到每份副本的气泡卡片（卡片标题是所在文件夹），绿色气泡是最新那份，
; 连线末端写“比最新早多久”，中间一列圆点是从新到旧的时间轴。
; 除搜索框（系统 Edit，方便输入中文）外全部用 GDI+ 画进一张位图，点击 / 悬停 / 滚动按坐标自行判断。
; 窗口去掉系统标题栏但保留 WS_CAPTION / WS_THICKFRAME：仍可拖动、贴边、缩放、最小化，任务栏有按钮。
; 坐标都是 96 DPI 下的逻辑像素，绘制时整体按系统缩放放大。

LatestUiRowH() {
    return 62
}

LatestUiHeaderH() {
    return 52
}

LatestUiBodyY() {
    return 152
}

LatestUiLeftW(W) {
    return Round(Min(380, Max(300, W * 0.27)))
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
    static prefs := Map("onlyMulti", true)  ; 只看有多份的：本次运行期间记住
    static hooked := false
    ModernPanelGdiplusStart()
    if !hooked {
        for msg, fn in Map(0x0F, LatestUiOnPaint, 0x14, LatestUiOnErase, 0x83, LatestUiOnNcCalcSize
                , 0x84, LatestUiOnNcHitTest, 0x200, LatestUiOnMouseMove, 0x201, LatestUiOnMouseDown
                , 0x202, LatestUiOnMouseUp, 0x205, LatestUiOnRButtonUp, 0x2A3, LatestUiOnMouseLeave, 0x20A, LatestUiOnWheel
                , 0x20, LatestUiOnSetCursor, 0x100, LatestUiOnKeyDown)
            OnMessage(msg, fn)
        hooked := true
    }

    dlg := Gui("+Resize +MinSize980x620 +0x02000000", title)  ; WS_CLIPCHILDREN：画背景时不盖住搜索框
    dlg.BackColor := "FFFFFF"
    dlg.MarginX := 0, dlg.MarginY := 0
    dlg.SetFont("s10 c1F2329", "Microsoft YaHei UI")
    search := dlg.AddEdit("x0 y0 w200 h22 -E0x200 -Border")
    DllCall("SendMessage", "Ptr", search.Hwnd, "UInt", 0x1501, "Ptr", 1, "WStr", "搜索文件名或文件夹…")  ; EM_SETCUEBANNER

    st := Map("gui", dlg, "title", title, "prefs", prefs, "search", search, "query", "", "type", "all"
        , "rows", [], "sel", 0, "scroll", 0, "graphScroll", 0, "graphMax", 0, "graphStep", 100
        , "hover", "", "pressed", "", "hits", [], "dirty", true, "dib", 0, "bmp", 0, "dibW", 0, "dibH", 0
        , "measure", Map(), "drag", "", "lastClick", [0, ""], "tracking", false, "searchRect", ""
        , "leftW", 340, "cards", Map())
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
    ; 初始大小：适中即可，能最大化 / 拖大
    scale := A_ScreenDPI / 96
    MonitorGetWorkArea(MonitorGetPrimary(), &waL, &waT, &waR, &waB)
    w := Round(Min(1280 * scale, (waR - waL) * 0.94)), h := Round(Min(860 * scale, (waB - waT) * 0.94))
    dlg.Show("Hide")
    WinMove(waL + ((waR - waL) - w) // 2, waT + ((waB - waT) - h) // 2, w, h, dlg.Hwnd)
    dlg.Show()
    DllCall("SetFocus", "Ptr", dlg.Hwnd)
    return st
}

LatestUiSetScan(st, scan) {
    groups := scan["groups"]
    st["scan"] := scan
    st["groups"] := groups
    st["sorted"] := ""
    st["cards"] := Map()
    multi := 0, latest := 0
    for index, group in groups {
        if (group["copies"].Length > 1)
            multi++
        if (!latest || group["newest"]["time"] > groups[latest]["newest"]["time"])
            latest := index
    }
    st["multi"] := multi
    st["latest"] := latest
}

; 按文件名排序，再按文件类型、只看多份、搜索过滤列表。first 为真时默认选中全局最新那份（并滚动到可见）。
LatestUiRefill(st, first := false) {
    if !IsObject(st["sorted"])
        st["sorted"] := LatestVersionSortedIndexes(st["groups"], 1)  ; 按文件名（数字按大小，D0202 在 D0210 前）；2026-11-11 用户要求
    query := StrLower(Trim(st["query"]))
    rows := []
    for _, index in st["sorted"] {
        group := st["groups"][index]
        if (st["prefs"]["onlyMulti"] && group["copies"].Length < 2)
            continue
        if (st["type"] != "all" && LatestUiTypeOf(group["newest"]["name"]) != st["type"])
            continue
        if (query != "" && !InStr(StrLower(group["newest"]["name"]), query)
                && !InStr(StrLower(LatestVersionNewestFolders(group)), query))
            continue
        rows.Push(index)
    }
    st["rows"] := rows
    want := first ? st["latest"] : st["sel"]
    old := st["sel"]
    st["sel"] := 0
    for _, index in rows
        if (index = want)
            st["sel"] := want
    if (!st["sel"] && rows.Length)
        st["sel"] := rows[1]
    if (st["sel"] != old)
        st["graphScroll"] := 0
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
    CableSortPopupClose(st)
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
        st.Delete("mg")
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
        ToolTip("请先在左侧列表里选一个文件")
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

LatestUiSelect(st, index) {
    if (index = st["sel"])
        return
    st["sel"] := index
    st["graphScroll"] := 0
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
    area := st["listArea"], rowH := LatestUiRowH()
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
    maxScroll := Max(0, st["rows"].Length * LatestUiRowH() - st["listArea"][4])
    st["scroll"] := Round(Max(0, Min(maxScroll, st["scroll"])))
}

; 选中组每份副本的气泡文字：标题（所在文件夹名）、上级文件夹、完整相对路径。按组缓存。
LatestUiCards(st, index) {
    if st["cards"].Has(index)
        return st["cards"][index]
    group := st["groups"][index], root := st["scan"]["root"]
    SplitPath(root, &rootName)
    infos := [], counts := Map()
    for _, copy in group["copies"] {
        SplitPath(copy["rel"], , &dir)
        parts := dir = "" ? [] : StrSplit(dir, "\")
        name := parts.Length ? parts[parts.Length] : (rootName != "" ? rootName : "查找范围") . "（顶层）"
        parent := parts.Length >= 2 ? parts[parts.Length - 1] : (parts.Length = 1 && rootName != "" ? rootName : "")
        key := StrLower(name)
        counts[key] := (counts.Has(key) ? counts[key] : 0) + 1
        infos.Push(Map("title", name, "key", key, "parent", parent
            , "dir", dir = "" ? "查找范围顶层" : StrReplace(dir, "\", " \ ")))
    }
    seen := Map()
    for _, info in infos {
        info["ambiguous"] := counts[info["key"]] > 1
        if seen.Has(info["key"])
            info["title"] .= "（另一处）"
        seen[info["key"]] := true
    }
    st["cards"][index] := infos
    return infos
}

; 连线末端的标签：[文字, 字色, 加粗]
LatestUiCurveLabel(group, i) {
    copy := group["copies"][i], newest := group["newest"]
    if (i = 1)
        return ["★ 最新那份", "166534", true]
    if (copy["time"] = newest["time"])
        return copy["size"] = newest["size"] ? ["与最新相同", "3F7D58", false] : ["时间相同、大小不同，需核对", "B42318", true]
    return ["早 " . LatestVersionAge(newest["time"], copy["time"]), "6B7280", false]
}

; 搜索框下方的文件类型按钮（2026-11-11 设计稿）：按最新那份的扩展名归类
LatestUiTypes() {
    return [["all", "全部"], ["dwg", "DWG"], ["pdf", "PDF"], ["excel", "Excel"], ["other", "其他"]]
}

LatestUiTypeOf(name) {
    SplitPath(name, , , &ext)
    ext := StrLower(ext)
    if (ext = "dwg" || ext = "dxf")
        return "dwg"
    if (ext = "pdf")
        return "pdf"
    if (ext = "xls" || ext = "xlsx" || ext = "xlsm" || ext = "xlsb" || ext = "et" || ext = "csv")
        return "excel"
    return "other"
}

LatestUiExtLabel(name) {
    SplitPath(name, , , &ext)
    ext := StrUpper(ext)
    return ext = "" ? "FILE" : StrLen(ext) > 4 ? SubStr(ext, 1, 4) : ext
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

; align：0 左 1 中 2 右；trim：3 末尾省略号，5 路径中间省略（保留开头和文件夹名末尾）；wrap：自动换行、顶端对齐
LatestUiFormat(align, trim, wrap := false) {
    static formats := Map()
    key := align . "|" . trim . "|" . wrap
    if formats.Has(key)
        return formats[key]
    fmt := 0
    DllCall("gdiplus\GdipCreateStringFormat", "Int", wrap ? 0 : 0x1000, "Int", 0, "Ptr*", &fmt)  ; NoWrap
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmt, "Int", align)
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", wrap ? 0 : 1)
    DllCall("gdiplus\GdipSetStringFormatTrimming", "Ptr", fmt, "Int", trim)
    formats[key] := fmt
    return formats[key]
}

LatestUiText(g, text, x, y, w, h, size, color, bold := false, align := 0, trim := 3, family := "Microsoft YaHei UI", wrap := false) {
    text := String(text)
    if (text = "" || w <= 2)
        return
    brush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", ModernPanelArgb(color), "Ptr*", &brush)
    rect := Buffer(16)
    NumPut("Float", x, "Float", y, "Float", w, "Float", h, rect)
    DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", text, "Int", -1, "Ptr", LatestUiFont(size, bold, family)
        , "Ptr", rect, "Ptr", LatestUiFormat(align, trim, wrap), "Ptr", brush)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
}

LatestUiGlyph(g, glyph, x, y, w, h, size, color) {
    LatestUiText(g, glyph, x, y, w, h, size, color, false, 1, 0, "Segoe MDL2 Assets")
}

LatestUiRect(g, x, y, w, h, fill, radius := 0, border := "", penW := 1) {
    if (w <= 0 || h <= 0)
        return
    if (radius = 0 && border = "") {
        brush := 0
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", ModernPanelArgb(fill), "Ptr*", &brush)
        DllCall("gdiplus\GdipFillRectangle", "Ptr", g, "Ptr", brush, "Float", x, "Float", y, "Float", w, "Float", h)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
        return
    }
    inset := penW / 2
    path := ModernPanelRoundPath(x + inset, y + inset, w - penW, h - penW, radius)
    if (fill != "")
        ModernPanelFillPath(g, path, ModernPanelArgb(fill))
    if (border != "") {
        pen := 0
        DllCall("gdiplus\GdipCreatePen1", "UInt", ModernPanelArgb(border), "Float", penW, "Int", 0, "Ptr*", &pen)
        DllCall("gdiplus\GdipDrawPath", "Ptr", g, "Ptr", pen, "Ptr", path)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    }
    DllCall("gdiplus\GdipDeletePath", "Ptr", path)
}

LatestUiDot(g, cx, cy, r, color) {
    brush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", ModernPanelArgb(color), "Ptr*", &brush)
    DllCall("gdiplus\GdipFillEllipse", "Ptr", g, "Ptr", brush, "Float", cx - r, "Float", cy - r, "Float", r * 2, "Float", r * 2)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
}

; 中心节点到气泡的连线：水平出、水平进的三次贝塞尔曲线
LatestUiCurve(g, x1, y1, x2, y2, color, width) {
    pen := 0
    DllCall("gdiplus\GdipCreatePen1", "UInt", ModernPanelArgb(color), "Float", width, "Int", 0, "Ptr*", &pen)
    dx := (x2 - x1) * 0.5
    DllCall("gdiplus\GdipDrawBezier", "Ptr", g, "Ptr", pen, "Float", x1, "Float", y1, "Float", x1 + dx, "Float", y1
        , "Float", x2 - dx, "Float", y2, "Float", x2, "Float", y2)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
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

; 列表第二行只写份数；“全局最新”“含旧版”等标签 2026-11-11 用户要求去掉（两者含义不同却挤在同一位置，容易看糊涂）。
; 只保留红字“需核对”：修改时间相同、大小却不同，光看时间判断不了哪份是最新。
LatestUiStatusBadge(st, index) {
    return st["groups"][index]["clash"] ? ["需核对", "B42318", true] : ""
}

LatestUiShortDate(time) {
    return SubStr(time, 1, 4) = A_YYYY ? FormatTime(time, "MM-dd") : FormatTime(time, "yyyy-MM-dd")
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
    headH := LatestUiHeaderH(), bodyY := LatestUiBodyY()
    LatestUiDrawHeader(st, g, W)
    LatestUiDrawScope(st, g, 0, headH, W, 56)
    LatestUiDrawSummary(st, g, 0, headH + 56, W, bodyY - headH - 56)
    leftW := LatestUiLeftW(W)
    st["leftW"] := leftW
    LatestUiRect(g, leftW, bodyY, 1, H - bodyY, "E4E6EB")
    LatestUiDrawList(st, g, 0, bodyY, leftW, H - bodyY)
    LatestUiDrawGraphPane(st, g, leftW + 1, bodyY, W - leftW - 1, H - bodyY)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    st["dirty"] := false
}

LatestUiDrawHeader(st, g, W) {
    headH := LatestUiHeaderH()
    LatestUiRect(g, 0, 0, W, headH, "F7F8FA")
    LatestUiRect(g, 0, headH - 1, W, 1, "E4E6EB")
    LatestUiGlyph(g, Chr(0xE721), 14, 0, 30, headH, 13, "374151")
    tw := LatestUiMeasure(st, st["title"], 13, true)
    LatestUiText(g, st["title"], 46, 0, tw + 4, headH, 13, "1F2329", true)
    LatestUiText(g, "同名文件自动归组 · 按修改时间判定最新", 46 + tw + 14, 1, W - 46 - tw - 14 - 160, headH, 9.5, "6B7280")
    maxed := DllCall("IsZoomed", "Ptr", st["gui"].Hwnd)
    for i, item in [["min", Chr(0xE921)], ["max", Chr(maxed ? 0xE923 : 0xE922)], ["close", Chr(0xE8BB)]] {
        bx := W - (4 - i) * 46
        hot := st["hover"] = item[1]
        if hot
            LatestUiRect(g, bx, 0, 46, headH - 1, item[1] = "close" ? "E81123" : "E9EBEF")
        LatestUiGlyph(g, item[2], bx, 0, 46, headH - 1, 7.5, hot && item[1] = "close" ? "FFFFFF" : "6B7280")
        LatestUiHit(st, item[1], bx, 0, 46, headH - 1, false)
    }
}

LatestUiDrawScope(st, g, x, y, w, h) {
    scan := st["scan"]
    LatestUiRect(g, x, y + h - 1, w, 1, "ECEEF1")
    labelW := LatestUiMeasure(st, "查找范围", 10)
    LatestUiText(g, "查找范围", x + 20, y, labelW + 2, h, 10, "6B7280")
    ; 右侧：深色“重新扫描”按钮、扫描信息
    bw := 94, bh := 34, bx := x + w - 20 - bw, by := y + (h - bh) / 2
    LatestUiRect(g, bx, by, bw, bh, st["hover"] = "rescan" ? "1F2329" : "2B3038", 7)
    LatestUiText(g, "重新扫描", bx, by, bw, bh, 10, "FFFFFF", true, 1)
    LatestUiHit(st, "rescan", bx, by, bw, bh)
    info := "扫描完成"
    if scan.Has("elapsed")
        info .= " · 用时 " . Format("{:.1f}", scan["elapsed"] / 1000) . " 秒"
    infoColor := "1F2329", dotColor := "2F9E5B"
    if scan["truncated"]
        info := "文件太多，只比较了前 " . scan["limit"] . " 个", infoColor := "B45309", dotColor := "D97706"
    iw := LatestUiMeasure(st, info, 10)
    ix := bx - 20 - iw
    LatestUiDot(g, ix - 10, y + h / 2, 4, dotColor)
    LatestUiText(g, info, ix, y, iw + 2, h, 10, infoColor)
    ; 中间：路径 + “含子文件夹”
    root := scan["root"] != "" ? scan["root"] : "选中的文件"
    chip := scan["folders"] ? "含子文件夹" : ""
    chipW := chip != "" ? LatestUiMeasure(st, chip, 9) + 20 : 0
    px := x + 20 + labelW + 10
    pathW := Min(LatestUiMeasure(st, root, 10.5, true) + 2, ix - 30 - px - chipW - 10)
    LatestUiText(g, root, px, y, pathW, h, 10.5, "1F2329", true, 0, 5)
    if (chip != "") {
        LatestUiRect(g, px + pathW + 10, y + (h - 24) / 2, chipW, 24, "F1F3F6", 6)
        LatestUiText(g, chip, px + pathW + 10, y + (h - 24) / 2, chipW, 24, 9, "4B5563", false, 1)
    }
}

; 统计一行字：数字加粗，其余灰色；右侧是同名判定规则
LatestUiDrawSummary(st, g, x, y, w, h) {
    scan := st["scan"]
    LatestUiRect(g, x, y + h - 1, w, 1, "E4E6EB")
    items := [["共", scan["files"], "个文件"], ["", st["groups"].Length, "组"], ["", st["multi"], "组有多份副本"]
        , ["已忽略", scan["skipped"], "个备份 / 临时文件"]]
    cx := x + 20
    for i, item in items {
        if (i > 1) {
            LatestUiText(g, "·", cx + 8, y, 10, h, 10, "C4C8CF", false, 1)
            cx += 26
        }
        for j, part in item {
            if (part = "")
                continue
            bold := j = 2
            pw := LatestUiMeasure(st, part, bold ? 10.5 : 10, bold)
            LatestUiText(g, part, cx, y, pw + 2, h, bold ? 10.5 : 10, bold ? "1F2329" : "4B5563", bold)
            cx += pw + 4
        }
    }
    rule := "同名判定已忽略「- 副本」「(1)」「v2」、日期、「最终版」等后缀"
    rw := Min(LatestUiMeasure(st, rule, 9) + 2, x + w - 20 - cx - 24)
    LatestUiText(g, rule, x + w - 20 - rw, y, rw, h, 9, "9CA3AF")
}

; 左栏：搜索框、“第一步”说明、文件列表、底部“只看有多份的”开关
LatestUiDrawList(st, g, x, y, w, h) {
    rowH := LatestUiRowH(), pad := 14
    ; 搜索框（系统 Edit 叠在画好的框上）
    sx := x + pad, sy := y + 14, sw := w - pad * 2, sh := 36
    focused := DllCall("GetFocus", "Ptr") = st["search"].Hwnd
    LatestUiRect(g, sx, sy, sw, sh, "FFFFFF", 6, focused ? "9CA3AF" : "DCDFE4")
    LatestUiGlyph(g, Chr(0xE721), sx + 6, sy, 22, sh, 8.5, "9CA3AF")
    LatestUiHit(st, "search", sx, sy, sw, sh, false)
    rect := [sx + 30, sy + (sh - 22) / 2, sw - 38, 22]
    if (st["searchRect"] = "" || st["searchRect"][1] != rect[1] || st["searchRect"][2] != rect[2] || st["searchRect"][3] != rect[3]) {
        st["searchRect"] := rect
        st["search"].Move(Round(rect[1]), Round(rect[2]), Round(rect[3]), rect[4])
    }
    rows := st["rows"]
    ; 文件类型按钮：选中深灰底白字，其余浅灰底
    cx := sx, cy := sy + sh + 12, chipH := 24, types := LatestUiTypes(), textW := 0
    for _, t in types
        textW += LatestUiMeasure(st, t[2], 9, true)
    chipPad := Max(8, Min(20, (sw - textW - 6 * (types.Length - 1)) / types.Length))  ; 窄窗口时收紧，五个都放得下
    for _, t in types {
        cid := "type:" . t[1], on := st["type"] = t[1]
        cw := LatestUiMeasure(st, t[2], 9, on) + chipPad
        if (cx + cw > sx + sw + 1)
            break
        LatestUiRect(g, cx, cy, cw, chipH, on ? "2B3038" : st["hover"] = cid ? "E5E7EB" : "F1F3F6", 5)
        LatestUiText(g, t[2], cx, cy, cw, chipH, 9, on ? "FFFFFF" : "4B5563", on, 1)
        LatestUiHit(st, cid, cx, cy, cw, chipH)
        cx += cw + 6
    }
    sy += chipH + 12
    LatestUiText(g, "第一步 · 先选一个文件（共 " . rows.Length . " 组）", x + pad + 2, sy + sh + 6, w - pad * 2, 26, 9, "9CA3AF")
    ; 底部开关
    footH := 62, fy := y + h - footH
    on := st["prefs"]["onlyMulti"]
    lw := LatestUiMeasure(st, "只看有多份的：", 9)
    LatestUiText(g, "只看有多份的：", x + pad + 2, fy + 6, lw + 2, 22, 9, "6B7280")
    tx := x + pad + 2 + lw
    tw := LatestUiMeasure(st, on ? "开" : "关", 9, true)
    LatestUiText(g, on ? "开" : "关", tx, fy + 6, tw + 2, 22, 9, st["hover"] = "toggle" ? "1F2329" : "374151", true)
    LatestUiRect(g, tx, fy + 25, tw + 1, 1, st["hover"] = "toggle" ? "1F2329" : "9CA3AF")
    LatestUiHit(st, "toggle", x + pad, fy + 4, lw + tw + 8, 26)
    hidden := st["groups"].Length - st["multi"]
    hint := on ? (hidden ? "已隐藏 " . hidden . " 组只有 1 份的文件，" : "") . "点任意一组即看气泡图"
        : "正在显示全部 " . st["groups"].Length . " 组，点任意一组即看气泡图"
    LatestUiText(g, hint, x + pad + 2, fy + 28, w - pad * 2, 24, 9, "9CA3AF")
    ; 列表
    listY := sy + sh + 36
    LatestUiRect(g, x, listY - 1, w, 1, "ECEEF1")
    area := [x, listY, w, fy - listY - 4]
    st["listArea"] := area
    if st.Has("ensureSel") {
        st.Delete("ensureSel")
        LatestUiEnsureVisible(st)
    }
    LatestUiClampScroll(st)
    contentH := rows.Length * rowH
    showBar := contentH > area[4]
    if !rows.Length {
        LatestUiText(g, (st["query"] != "" || st["type"] != "all") ? "没有找到匹配的文件" : "没有同名的多份文件" . (on ? "（可以关掉下方“只看有多份的”）" : "")
            , area[1] + pad, area[2] + 20, area[3] - pad * 2, 60, 9.5, "9CA3AF", false, 1, 3, "Microsoft YaHei UI", true)
        return
    }
    DllCall("gdiplus\GdipSetClipRect", "Ptr", g, "Float", area[1], "Float", area[2], "Float", area[3], "Float", area[4], "Int", 0)
    first := Floor(st["scroll"] / rowH) + 1
    last := Min(rows.Length, first + Ceil(area[4] / rowH) + 1)
    right := x + w - (showBar ? 18 : 14)
    i := first
    while (i <= last) {
        index := rows[i], group := st["groups"][index], newest := group["newest"]
        ry := area[2] + (i - 1) * rowH - st["scroll"]
        id := "row:" . i
        if (index = st["sel"]) {
            LatestUiRect(g, area[1], ry, area[3], rowH, "F1F7F3")
            LatestUiRect(g, area[1], ry, 3, rowH, "2F7D4A")
        } else if (st["hover"] = id) {
            LatestUiRect(g, area[1], ry, area[3], rowH, "F7F8FA")
        }
        LatestUiRect(g, area[1], ry + rowH - 1, area[3], 1, "ECEEF1")
        ext := LatestUiExtLabel(newest["name"])
        bw := LatestUiMeasure(st, ext, 7.5, true) + 12
        LatestUiRect(g, x + 18, ry + 12, bw, 18, "F1F3F6", 4)
        LatestUiText(g, ext, x + 18, ry + 12, bw, 18, 7.5, "4B5563", true, 1)
        LatestUiText(g, newest["name"], x + 18 + bw + 8, ry + 8, right - (x + 18 + bw + 8), 26, 10.5, "1F2329", true)
        n := group["copies"].Length
        badge := LatestUiStatusBadge(st, index)
        countText := n . " 份" . (IsObject(badge) ? " · " : "")
        cw := LatestUiMeasure(st, countText, 9)
        LatestUiText(g, countText, x + 18, ry + 34, cw + 2, 20, 9, "6B7280")
        if IsObject(badge)
            LatestUiText(g, badge[1], x + 18 + cw, ry + 34, right - x - 18 - cw, 20, 9, badge[2], badge[3])
        top := Max(ry, area[2]), bottom := Min(ry + rowH, area[2] + area[4])
        if (bottom > top)
            LatestUiHit(st, id, area[1], top, area[3] - (showBar ? 14 : 0), bottom - top, false)
        i++
    }
    DllCall("gdiplus\GdipResetClip", "Ptr", g)
    if showBar {
        trackX := x + w - 10, trackY := area[2] + 4, trackH := area[4] - 8
        thumbH := Max(28, trackH * area[4] / contentH)
        thumbY := trackY + (trackH - thumbH) * st["scroll"] / (contentH - area[4])
        hot := st["hover"] = "thumb" || IsObject(st["drag"])
        LatestUiRect(g, trackX + (hot ? -1 : 0), thumbY, hot ? 7 : 5, thumbH, hot ? "9CA3AF" : "D1D5DB", hot ? 3.5 : 2.5)
        LatestUiHit(st, "track", trackX - 4, trackY, 14, trackH, false)
        LatestUiHit(st, "thumb", trackX - 4, thumbY, 14, thumbH, false)
        st["bar"] := [trackY, trackH, thumbH, contentH - area[4]]
    }
}

; 右栏：“第二步”标题 + 图例、气泡连线图、底部提示和按钮
LatestUiDrawGraphPane(st, g, x, y, w, h) {
    px := x + 22, pr := x + w - 22
    ; 底部
    footY := y + h - 50
    LatestUiRect(g, px, footY, pr - px, 1, "ECEEF1")
    bx := LatestUiDrawFooter(st, g, px, footY + 9, pr - px, 32)
    LatestUiText(g, "右键任意气泡 = 打开所在文件夹 · 绿色气泡就是最新那份，它所在的文件夹就是答案"
        , px, footY + 9, bx - px - 12, 32, 9, "6B7280")
    gy := y + 56, gh := footY - 6 - gy
    st["graphRect"] := [x, gy, w, gh]
    if !st["sel"] {
        LatestUiText(g, "第二步 · 看图", px, y + 12, pr - px, 34, 11, "1F2329", true)
        LatestUiText(g, "在左侧选一个文件，这里就画出它的每一份副本分别在哪", px, gy, pr - px, gh, 10, "9CA3AF", false, 1)
        st["graphMax"] := 0
        return
    }
    group := st["groups"][st["sel"]], copies := group["copies"], n := copies.Length, newest := group["newest"]
    ; 标题：第二步 · 看图：<文件名> 的 N 份分别在哪；右侧图例
    legend := [["dot", "2F9E5B"], ["text", "最新那份", "4B5563"], ["dot", "C4C8CF"], ["text", "旧版 · 连线上的字 = 比最新早多久", "4B5563"]]
    legendW := 0
    for _, item in legend
        legendW += item[1] = "dot" ? 16 : LatestUiMeasure(st, item[2], 9) + 12
    t1 := "第二步 · 看图：", t3 := " 的 " . n . " 份分别在哪"
    w1 := LatestUiMeasure(st, t1, 11, true), w3 := LatestUiMeasure(st, t3, 11, true)
    showLegend := pr - px - w1 - w3 - 120 > legendW + 20
    nameMax := pr - px - w1 - w3 - (showLegend ? legendW + 24 : 0)
    w2 := Min(LatestUiMeasure(st, newest["name"], 11, true) + 2, Max(40, nameMax))
    LatestUiText(g, t1, px, y + 12, w1 + 2, 34, 11, "1F2329", true)
    LatestUiText(g, newest["name"], px + w1, y + 12, w2, 34, 11, "166534", true)
    LatestUiText(g, t3, px + w1 + w2, y + 12, w3 + 2, 34, 11, "1F2329", true)
    if showLegend {
        lx := pr - legendW
        for _, item in legend {
            if (item[1] = "dot") {
                LatestUiDot(g, lx + 6, y + 29, 4.5, item[2])
                lx += 16
            } else {
                iw := LatestUiMeasure(st, item[2], 9)
                LatestUiText(g, item[2], lx, y + 12, iw + 2, 34, 9, item[3])
                lx += iw + 12
            }
        }
    }
    ; 布局：中心节点在左，时间轴在中间，气泡在右
    gw := pr - px
    nodeW := Round(Min(280, Max(180, gw * 0.24)))
    cardW := Round(Min(620, Max(330, gw * 0.5))), cardH := 76
    ; 中心节点按文件名换行行数定高（最多 3 行）
    nameLines := Max(1, Min(3, Ceil(LatestUiMeasure(st, newest["name"], 10.5, true) * 1.12 / (nodeW - 36))))
    nodeH := 44 + nameLines * 22 + 36
    nodeX := px + 8, cardX := pr - cardW
    axisX := nodeX + nodeW + Max(36, (cardX - nodeX - nodeW) * 0.18)
    innerTop := gy + 34, innerH := gh - 68
    step := Max(cardH + 10, Min(cardH + 26, n > 1 ? (innerH - cardH) / (n - 1) : cardH + 26))
    st["graphStep"] := step
    totalH := (n - 1) * step + cardH
    maxScroll := Max(0, Round(totalH - innerH))
    st["graphMax"] := maxScroll
    st["graphScroll"] := Round(Max(0, Min(maxScroll, st["graphScroll"])))
    top0 := maxScroll ? innerTop - st["graphScroll"] : innerTop + (innerH - totalH) / 2
    nodeCY := maxScroll ? innerTop + innerH / 2 : top0 + totalH / 2
    ; 时间轴两端
    LatestUiText(g, "▲ 新", axisX - 40, gy + 4, 80, 22, 9, "166534", true, 1)
    LatestUiText(g, "▼ 旧", axisX - 40, gy + gh - 26, 80, 22, 9, "9CA3AF", false, 1)
    clipY := gy + 28, clipH := gh - 56
    DllCall("gdiplus\GdipSetClipRect", "Ptr", g, "Float", x, "Float", clipY, "Float", w, "Float", clipH, "Int", 0)
    if (n > 1)
        LatestUiRect(g, axisX - 0.5, top0 + cardH / 2, 1, (n - 1) * step, "EEF0F3")
    cards := LatestUiCards(st, st["sel"])
    ; 连线：先画旧版，最后画最新那份，绿线压在最上面
    loop n {
        i := n - A_Index + 1, copy := copies[i]
        cy := top0 + (i - 1) * step + cardH / 2
        if (cy < clipY - cardH || cy > clipY + clipH + cardH)
            continue
        same := i > 1 && copy["time"] = newest["time"] && copy["size"] = newest["size"]
        color := i = 1 ? "2F7D4A" : same ? "9ACBAA" : "D5D8DD"
        LatestUiCurve(g, nodeX + nodeW, nodeCY, cardX, cy, color, i = 1 ? 2.4 : 1.4)
        LatestUiDot(g, axisX, cy, i = 1 ? 4.5 : 3.5, i = 1 ? "2F7D4A" : "D1D5DB")
        LatestUiDot(g, cardX, cy, i = 1 ? 4 : 3, color)
        label := LatestUiCurveLabel(group, i)
        lw := LatestUiMeasure(st, label[1], 9, label[3]) + 4
        LatestUiText(g, label[1], cardX - 10 - lw, cy - 24, lw, 20, 9, label[2], label[3], 2)
    }
    ; 气泡卡片
    for i, copy in copies {
        top := top0 + (i - 1) * step
        if (top + cardH < clipY || top > clipY + clipH)
            continue
        LatestUiDrawCard(st, g, cardX, top, cardW, cardH, group, i, cards[i])
        vt := Max(top, clipY), vb := Min(top + cardH, clipY + clipH)
        if (vb > vt)
            LatestUiHit(st, "card:" . i, cardX, vt, cardW, vb - vt, false)   ; 左键不打开，不显示手形
    }
    DllCall("gdiplus\GdipResetClip", "Ptr", g)
    ; 中心节点（不随气泡滚动）
    ny := nodeCY - nodeH / 2
    LatestUiRect(g, nodeX, ny + 3, nodeW, nodeH, "1A000000", 12)
    LatestUiRect(g, nodeX, ny, nodeW, nodeH, st["hover"] = "node" ? "1F2124" : "2B2D31", 12)
    ext := LatestUiExtLabel(newest["name"])
    ew := LatestUiMeasure(st, ext, 7.5, true) + 14
    LatestUiRect(g, nodeX + 18, ny + 16, ew, 20, "45484F", 5)
    LatestUiText(g, ext, nodeX + 18, ny + 16, ew, 20, 7.5, "D1D5DB", true, 1)
    LatestUiText(g, newest["name"], nodeX + 18, ny + 42, nodeW - 36, nameLines * 22 + 2, 10.5, "FFFFFF", true, 0, 3, "Microsoft YaHei UI", true)
    LatestUiText(g, "同一个文件 · 共 " . n . " 份副本", nodeX + 18, ny + nodeH - 30, nodeW - 36, 20, 8.5, "A1A6AE")
    LatestUiHit(st, "node", nodeX, ny, nodeW, nodeH, false)
    ; 气泡太多时右侧滚动条
    if maxScroll {
        trackY := clipY + 4, trackH := clipH - 8
        thumbH := Max(24, trackH * innerH / totalH)
        LatestUiRect(g, pr + 8, trackY + (trackH - thumbH) * st["graphScroll"] / maxScroll, 5, thumbH, "D1D5DB", 2.5)
    }
}

LatestUiDrawCard(st, g, x, y, w, h, group, i, info) {
    copy := group["copies"][i], newest := group["newest"], isNew := i = 1
    hot := st["hover"] = "card:" . i
    if isNew {
        LatestUiRect(g, x - 6, y - 6, w + 12, h + 12, "DCEFE2", 16)
        LatestUiRect(g, x, y, w, h, "FBFDFB", 12, "2F7D4A", 2)
    } else {
        LatestUiRect(g, x, y, w, h, hot ? "FFFFFF" : "FAFAFB", 12, hot ? "9CA3AF" : "E4E6EB")
    }
    ; 第一行：文件夹名（+ “★ 最新”） …… 日期
    dateText := LatestUiShortDate(copy["time"])
    dw := LatestUiMeasure(st, dateText, 13, true) + 4
    LatestUiText(g, dateText, x + w - 24 - dw, y + 8, dw, 32, 13, isNew ? "166534" : "1F2329", true, 2)
    chipW := isNew ? LatestUiMeasure(st, "★ 最新", 8.5, true) + 22 : 0
    titleW := LatestUiMeasure(st, info["title"], 11, true) + 2
    showChip := isNew && titleW <= w - 30 - 24 - dw - 16 - chipW - 14  ; 放不下时让给文件夹名，绿框已足够醒目
    tw := Min(titleW, w - 30 - 24 - dw - 16 - (showChip ? chipW + 14 : 0))
    LatestUiText(g, info["title"], x + 30, y + 9, tw, 30, 11, "1F2329", true)
    if showChip {
        cx := x + 30 + tw + 14
        LatestUiRect(g, cx, y + 14, chipW, 20, "D3EFDC", 10)
        LatestUiText(g, "★ 最新", cx, y + 14, chipW, 20, 8.5, "166534", true, 1)
    }
    ; 第二行：路径或时间、大小 …… 时刻
    sizeText := LatestVersionSize(copy["size"])
    rightText := isNew ? FormatTime(copy["time"], "HH:mm") . " · " . sizeText : FormatTime(copy["time"], "HH:mm")
    rw := LatestUiMeasure(st, rightText, 9) + 4
    LatestUiText(g, rightText, x + w - 24 - rw, y + 42, rw, 22, 9, isNew ? "4B5563" : "9CA3AF", false, 2)
    dx := x + 30, dRight := x + w - 24 - rw - 12
    if isNew {
        ; “完整路径：”单独画，路径按中间省略，保留开头和最后一级文件夹
        pw := LatestUiMeasure(st, "完整路径：", 9)
        LatestUiText(g, "完整路径：", dx, y + 42, pw + 2, 22, 9, "6B7280")
        LatestUiText(g, info["dir"], dx + pw, y + 42, dRight - dx - pw, 22, 9, "6B7280", false, 0, 5)
    } else {
        detail := (info["ambiguous"] && info["parent"] != "" ? "上级：" . info["parent"] . " · " : "")
            . FormatTime(copy["time"], "yyyy-MM-dd HH:mm:ss") . " · " . sizeText
        LatestUiText(g, detail, dx, y + 42, dRight - dx, 22, 9, "6B7280")
    }
}

; 底部按钮，从右往左排；返回最左按钮的 x，供左侧提示文字定宽
LatestUiDrawFooter(st, g, x, y, w, h) {
    ; [id, 文字, 宽, 底色, 悬停底色, 字色, 描边]
    buttons := [["btnLocate", "定位最新文件", 122, "2B3038", "1F2329", "FFFFFF", ""]
        , ["btnCopy", "复制结果", 96, "FFFFFF", "F3F4F6", "1F2329", "D1D5DB"]
        , ["btnClose", "关闭", 68, "FFFFFF", "F3F4F6", "1F2329", "D1D5DB"]]
    bx := x + w
    for _, b in buttons {
        bx -= b[3]
        LatestUiRect(g, bx, y, b[3], h, st["hover"] = b[1] ? b[5] : b[4], 6, b[7])
        LatestUiText(g, b[2], bx, y, b[3], h, 9.5, b[6], b[1] = "btnLocate", 1)
        LatestUiHit(st, b[1], bx, y, b[3], h)
        bx -= 12
    }
    return bx + 12
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
    if (cy < LatestUiHeaderH() * scale && cx < pw - 138 * scale)
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
        page := st["listArea"][4] - LatestUiRowH()
        st["scroll"] += (y < st["bar"][1] + (st["bar"][2] - st["bar"][3]) * st["scroll"] / Max(1, st["bar"][4])) ? -page : page
        LatestUiClampScroll(st)
        LatestUiInvalidate(st)
    } else if (SubStr(id, 1, 4) = "row:") {
        ; 右栏气泡和中心节点左键不做任何事，打开文件夹改为右键菜单（用户 2026-11-12 要求）
        last := st["lastClick"]
        LatestUiSelect(st, st["rows"][Integer(SubStr(id, 5))])
        if (last[2] = id && A_TickCount - last[1] <= DllCall("GetDoubleClickTime")) {
            st["lastClick"] := [0, ""]
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
    ; 延后执行，避免在消息处理中弹出对话框
    SetTimer(LatestUiClick.Bind(st, id, hit), -1)
    return 0
}

; 右键气泡或中心节点：弹出卡片式菜单（复用电缆排序窗口的 CableSortPopup），由菜单打开所在文件夹
LatestUiOnRButtonUp(wParam, lParam, msg, hwnd) {
    states := LatestUiStates()
    if !states.Has(hwnd)
        return
    st := states[hwnd]
    if !st["sel"]
        return 0
    scale := A_ScreenDPI / 96
    point := LatestUiPoint(lParam)
    hit := LatestUiHitAt(st, point[1] / scale, point[2] / scale)
    id := IsObject(hit) ? hit[1] : ""
    copies := st["groups"][st["sel"]]["copies"]
    if (SubStr(id, 1, 5) = "card:")
        copy := copies[Integer(SubStr(id, 6))]
    else if (id = "node")
        copy := st["groups"][st["sel"]]["newest"]
    else
        return 0
    SetTimer(LatestUiCopyMenu.Bind(st, copy, id = "node"), -1)
    return 0
}

LatestUiCopyMenu(st, copy, isNode) {
    if !LatestUiStates().Has(st["gui"].Hwnd)
        return
    path := copy["path"]
    SplitPath(path, , &dir)
    e := [Map("kind", "primary", "icon", Chr(0xE838), "text", isNode ? "打开最新那份所在文件夹" : "打开所在文件夹"
        , "hint", "选中该文件", "action", () => LatestUiReveal(st, path))]
    e.Push(Map("kind", "sep"))
    e.Push(Map("text", "复制文件完整路径", "icon", Chr(0xE8C8), "action", () => (A_Clipboard := path)))
    e.Push(Map("text", "复制所在文件夹路径", "icon", Chr(0xE8C8), "action", () => (A_Clipboard := dir)))
    CableSortPopup(st, e, st["gui"].Hwnd)
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
        case "btnCopy":
            LatestUiCopyResult(st)
        case "btnLocate":
            LatestUiLocateSelected(st)
        default:
            if (SubStr(id, 1, 5) = "type:" && st["type"] != SubStr(id, 6)) {
                st["type"] := SubStr(id, 6)
                LatestUiRefill(st)
                LatestUiEnsureVisible(st)
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
    x := NumGet(pt, 0, "Int") / scale
    if (x > st["leftW"]) {
        if (st["graphMax"] <= 0)
            return 0
        st["graphScroll"] -= delta / 120 * st["graphStep"]
    } else {
        st["scroll"] -= delta / 120 * LatestUiRowH() * 2
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
    page := st.Has("listArea") ? Max(1, Floor(st["listArea"][4] / LatestUiRowH()) - 1) : 5
    switch wParam {
        case 0x26:
            LatestUiMoveSel(st, -1)
        case 0x28:
            LatestUiMoveSel(st, 1)
        case 0x21:
            LatestUiMoveSel(st, -page)
        case 0x22:
            LatestUiMoveSel(st, page)
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
