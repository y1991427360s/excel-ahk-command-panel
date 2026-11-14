#Requires AutoHotkey v2.0
; 电缆排序窗口（配合中望 / AutoCAD 2018 的 YSDL3）：YSDL3 把清册各行写进 %TEMP%\AA-YSDL3\job.txt，这里每 0.3 秒检查一次，
; 出现新任务就弹出窗口。左：“前缀（+编号范围）→ 起点柜”规则（读本工程规则文件，没有规则的前缀自动推断）；
; 中：未分类的电缆（搜索、勾选多选）；右：分类气泡（初始为图上的分类框），放进气泡的电缆只在气泡里显示。
; 勾选或多选后把电缆拖进气泡，气泡内上下拖动排序，右键气泡可改名、删除、前后移、按编号排序。
; 点“导出 CSV”写 result.txt（第 2 版），在 CAD 空闲时发送 (aa:ysdl3-apply "任务号")，由插件按气泡写 CSV、文字变黄（不移动清册）。
; 每一步修改前记一份快照，可撤销 / 重做（按钮或 Ctrl+Z / Ctrl+Y）；改动自动保存进度到 dwg 文件夹，下次运行 YSDL3 可接着做。逻辑在 cable-sort-core.ahk。

#Include cable-sort-core.ahk
#Include modern-panel-ui.ahk
#Include cable-sort-look.ahk

global CableSortJobPath := EnvGet("TEMP") . "\AA-YSDL3\job.txt"
global CableSortResultPath := EnvGet("TEMP") . "\AA-YSDL3\result.txt"
global CableSortLastTime := ""
global CableSortUi := ""

CableSortInit()

CableSortInit() {
    global CableSortJobPath, CableSortLastTime
    ; 启动时已有的旧任务不弹出（重新运行 YSDL3 即可，进度会自动接上）
    if FileExist(CableSortJobPath)
        try CableSortLastTime := FileGetTime(CableSortJobPath, "M")
    SetTimer(CableSortPoll, 300)
    ; 排序窗口激活时 Ctrl+Z 撤销、Ctrl+Y 重做；焦点在输入框里时仍交给输入框自己撤销
    HotIf((*) => CableSortUiActive())
    Hotkey("$^z", (*) => CableSortUndoKey("undo"))
    Hotkey("$^y", (*) => CableSortUndoKey("redo"))
    Hotkey("$^r", (*) => CableSortFlipKey())
    Hotkey("$^f", (*) => (IsObject(CableSortUi) && CableSortUi["ctl"]["gsearch"].Focus()))
    HotIf()
}

; 排序窗口或它的放大窗口是否在前台（Ctrl+Z/Y 热键用）
CableSortUiActive() {
    global CableSortUi
    if !IsObject(CableSortUi)
        return false
    if WinActive("ahk_id " . CableSortUi["gui"].Hwnd)
        return true
    for id, z in CableSortUi["zooms"]
        if WinActive("ahk_id " . z["gui"].Hwnd)
            return true
    return false
}

CableSortPoll() {
    global CableSortJobPath, CableSortLastTime
    if !FileExist(CableSortJobPath)
        return
    try modified := FileGetTime(CableSortJobPath, "M")
    catch
        return
    if (modified = CableSortLastTime)
        return
    try text := CableSortReadTextAuto(CableSortJobPath)   ; 中望写 UTF-8，AutoCAD 2018 写 GBK
    catch
        return          ; CAD 正在改名替换文件，下一轮再读
    CableSortLastTime := modified
    try job := CableSortParseJob(text)
    catch as e {
        TrayTip("排序任务文件读取失败：" . e.Message, "电缆排序", "Iconx Mute")
        return
    }
    CableSortOpen(job)
}

; 面板按钮：打开最近一次 YSDL3 留下的任务（CAD 里的任务还在时才能导出）
; 面板按钮：选一个 YSDL / YSDL3 导出的 CSV，打开重新整理（不需要 CAD）
CableSortOpenCsv(*) {
    path := FileSelect(1, A_Desktop, "选择 YSDL / YSDL3 导出的电缆清册 CSV", "CSV 文件 (*.csv)")
    if (path = "")
        return
    try job := CableSortCsvToJob(path)
    catch as e {
        MsgBox("这个 CSV 打不开：`n" . e.Message, "电缆排序", "Icon!")
        return
    }
    CableSortOpen(job)
}

CableSortIsCsv(st) {
    return st["job"].Has("source") && st["job"]["source"] = "csv"
}

CableSortColorRef(rgb) {
    v := Integer("0x" . rgb)
    return ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
}

; ---------- 打开窗口 ----------

; showOptions、resume（ask 询问 / no 不恢复）、progressPath 供冒烟测试把窗口放到屏幕外、不碰工程目录
CableSortOpen(job, showOptions := "w1500 h880", resume := "ask", progressPath := "") {
    global CableSortUi
    static slots := 12
    CableSortClose()
    st := Map("job", job)
    isCsv := job.Has("source") && job["source"] = "csv"
    st["cables"] := isCsv ? CableSortBuildCsv(job) : CableSortBuild(job)
    st["rulesPath"] := CableSortRulesPath(job["dwg"])
    try st["rules"] := CableSortLoadRules(st["rulesPath"])
    catch
        st["rules"] := []
    for r in CableSortInfer(st["cables"], st["rules"])
        st["rules"].Push(r)
    CableSortResolveAll(st["cables"], st["rules"])
    st["bubbles"] := isCsv ? CableSortCsvBubbles(job, st["cables"]) : CableSortInitialBubbles(job, st["cables"])
    st["nextId"] := st["bubbles"].Length + 1
    ; 上次的整理进度：询问是否接着做
    st["progressPath"] := progressPath != "" ? progressPath : CableSortProgressPath(job["dwg"])
    st["dirty"] := false, resumeMsg := ""
    if (resume = "ask" && FileExist(st["progressPath"])) {
        try {
            prog := CableSortParseProgress(FileRead(st["progressPath"], "UTF-8"))
            if (MsgBox("发现这" . (isCsv ? "个 CSV" : "张图") . "上次的整理进度（保存于 " . prog["time"] . "）。`n`n是：接着上次的进度做`n否：按规则重新开始（上次的进度会被覆盖）"
                , "电缆排序 · 继续上次的进度？", "YesNo Icon? 262144") = "Yes") {
                res := CableSortApplyProgress(job, st["cables"], prog)
                st["rules"] := res["rules"], st["bubbles"] := res["bubbles"], st["nextId"] := res["nextId"]
                resumeMsg := "已恢复上次的进度（" . prog["time"] . "）：对上 " . res["restored"] . " 项"
                    . (res["added"] ? "，新出现 " . res["added"] . " 项（按规则放进气泡或未分类）" : "")
                    . (res["missing"] ? "，上次有、这次没有 " . res["missing"] . " 项" : "") . "。"
            }
        } catch as e {
            resumeMsg := "上次的进度读取失败（" . e.Message . "），已按规则重新开始。"
        }
    }
    st["undo"] := [], st["redo"] := [], st["byKey"] := Map()
    for cable in st["cables"]
        st["byKey"][cable["key"]] := cable
    st["search"] := "", st["zooms"] := Map()
    st["midRows"] := [], st["midColors"] := [], st["ruleColors"] := []

    SplitPath(job["dwg"], &dwgName)
    dlg := Gui("+Resize +MinSize1200x680", "电缆排序 · " . (isCsv ? "CSV 重新整理" : "YSDL3") . " · " . dwgName)
    st["gui"] := dlg
    dlg.BackColor := "FFFFFF"
    dlg.MarginX := 16, dlg.MarginY := 12
    dlg.SetFont("s10 c1F2329", "Microsoft YaHei UI")
    c := Map()
    st["ctl"] := c
    ; 版式（沉稳灰白风格，2026-11-11 按用户给的设计稿）：顶栏（全局搜索 + 气泡按钮）→ 浅灰摘要行 → 左中右三栏（细竖线分隔）→ 底栏。
    ; 先建的控件在 Z 序上层：叉号、空列表提示要盖在别的控件上就先建；卡片、输入框描边这类底图建好后压到最下层（见 cable-sort-look.ahk）。

    ; 顶栏：全局搜索（同时筛选所有气泡、未分类列表和放大窗口）
    dlg.SetFont("s9 c9CA3AF")
    c["gclear"] := dlg.AddText("x0 y0 w18 h18 Center Hidden BackgroundWhite +0x100", "✕")
    dlg.SetFont("s11 c1F2329 Norm")
    c["gsearch"] := dlg.AddEdit("x16 y10 w720 h22 -E0x200 +0x4000000")
    DllCall("SendMessage", "Ptr", c["gsearch"].Hwnd, "UInt", 0x1501, "Ptr", 1, "WStr", "全局搜索：所有气泡和未分类列表一起搜编号、柜名或规格（Ctrl+F）…")
    c["gframe"] := CableSortFrameEdit(dlg, c["gsearch"], Chr(0xE721))
    dlg.SetFont("s10 c1F2329 Norm")
    c["newBubble"] := CableSortButton(dlg, "x0 y0 w136 h34", "＋ 新增分类气泡")
    c["reclass"] := CableSortButton(dlg, "x0 y0 w172 h34", "全部按规则重新分类")
    for key in ["divHead", "divSum", "divFoot", "ruleSep", "midSep"]
        c[key] := dlg.AddText("x0 y0 w10 h1 BackgroundECEEF1")
    for key in ["divL", "divM"]
        c[key] := dlg.AddText("x0 y0 w1 h10 BackgroundECEEF1")
    c["summary"] := CableSortAddPic(dlg, "x0 y0 w10 h38")     ; 摘要一行：数字加粗，待处理用浅琥珀胶囊

    ; 左：规则
    dlg.SetFont("s11 c1F2329 Bold")
    c["ruleTitle"] := dlg.AddText("x16 y104 w320", "前缀规则")
    dlg.SetFont("s9 c9CA3AF Norm")
    c["ruleSub"] := dlg.AddText("x16 y126 w320", "前缀（+编号范围）→ 起点柜，决定保留哪一端")
    dlg.SetFont("s10 c1F2329")
    c["rules"] := dlg.AddListView("x16 y148 w320 h300 -Multi NoSort NoSortHdr -E0x200 +0x4000000", ["前缀", "范围", "起点柜", "根数", "来源"])
    CableSortStyleLv(c["rules"], 28)
    dlg.SetFont("s10 c6B7280")
    c["prefixLabel"] := dlg.AddText("x0 y0 w34", "前缀")
    c["rangeLabel"] := dlg.AddText("x0 y0 w34", "范围")
    c["cabLabel"] := dlg.AddText("x0 y0 w48", "起点柜")
    dlg.SetFont("s10 c1F2329")
    c["prefix"] := dlg.AddEdit("x0 y0 w70 h20 -E0x200 +0x4000000")
    c["range"] := dlg.AddEdit("x0 y0 w100 h20 -E0x200 +0x4000000")
    c["prefixFrame"] := CableSortFrameEdit(dlg, c["prefix"])
    c["rangeFrame"] := CableSortFrameEdit(dlg, c["range"])
    c["cab"] := dlg.AddComboBox("x0 y0 w270")
    c["add"] := CableSortButton(dlg, "x0 y0 w60 h30", "添加", "primary")
    c["modify"] := CableSortButton(dlg, "x0 y0 w56 h30", "修改")
    c["delete"] := CableSortButton(dlg, "x0 y0 w56 h30", "删除")
    c["ruleUp"] := CableSortButton(dlg, "x0 y0 w56 h30", "上移")
    c["ruleDown"] := CableSortButton(dlg, "x0 y0 w56 h30", "下移")
    dlg.SetFont("s9 c9CA3AF")
    c["ruleHint"] := dlg.AddText("x0 y0 w320 h52", "灰色为自动推断。点中间的电缆会填入它的前缀和两端柜子，选好起点柜后点“添加”；带编号范围的规则优先。改规则后，未分类里定下起点的电缆自动放进对应气泡。")

    ; 中：未分类电缆
    dlg.SetFont("s11 c1F2329 Bold")
    c["midTitle"] := dlg.AddText("x0 y0 w300", "未分类电缆")
    dlg.SetFont("s9 c9CA3AF Norm")
    c["midSub"] := dlg.AddText("x0 y0 w300", "")
    c["searchClear"] := dlg.AddText("x0 y0 w18 h18 Center Hidden BackgroundWhite +0x100", "✕")
    ; 列表空了时盖在列表上的提示（全部已分类 / 没有搜到）
    c["emptyPic"] := CableSortAddPic(dlg, "x0 y0 w56 h56 Hidden")
    dlg.SetFont("s11 c1F2329 Bold")
    c["emptyTitle"] := dlg.AddText("x0 y0 w240 h26 Center Hidden BackgroundWhite", "全部已分类")
    dlg.SetFont("s9 c9CA3AF Norm")
    c["emptySub"] := dlg.AddText("x0 y0 w240 h40 Center Hidden BackgroundWhite", "")
    dlg.SetFont("s10 c1F2329 Norm")
    c["search"] := dlg.AddEdit("x0 y0 w300 h20 -E0x200 +0x4000000")
    DllCall("SendMessage", "Ptr", c["search"].Hwnd, "UInt", 0x1501, "Ptr", 1, "WStr", "搜索编号、柜名或规格，空格分隔多个词…")  ; EM_SETCUEBANNER
    c["searchFrame"] := CableSortFrameEdit(dlg, c["search"], Chr(0xE721))
    c["mid"] := dlg.AddListView("x0 y0 w480 h420 Checked NoSort NoSortHdr -E0x200 +0x4000000"
        , ["编号", "起点（保留端）", "终点", "规格", "状态"])
    CableSortStyleLv(c["mid"], 28)
    c["moveTo"] := CableSortButton(dlg, "x0 y0 w100 h30", "移到分类 ▸")
    c["swap"] := CableSortButton(dlg, "x0 y0 w100 h30", "对调起终点")
    c["del"] := CableSortButton(dlg, "x0 y0 w64 h30", "删除")
    c["trash"] := CableSortButton(dlg, "x0 y0 w120 h30", "已删除（0）…")
    c["checkAll"] := CableSortButton(dlg, "x0 y0 w96 h30", "全选/清空")
    dlg.SetFont("s9 c9CA3AF")
    c["selInfo"] := dlg.AddText("x0 y0 w480 h36", "")

    ; 右：分类气泡（白底描边卡片；气泡内搜索按设计稿收起，统一用顶上的全局搜索，放大窗口里仍可单独搜）
    dlg.SetFont("s11 c1F2329 Bold")
    c["bubTitle"] := dlg.AddText("x0 y0 w200", "分类气泡")
    dlg.SetFont("s9 c9CA3AF Norm")
    c["hint"] := dlg.AddText("x0 y0 w600 h18 +0x4000", "勾选或多选后拖到气泡（从气泡拖回左边列表 = 移出分类）；气泡内上下拖动排序；双击气泡名称改名；右键电缆可对调起终点、移到分类、删除；右键气泡名称可放大、排序、删除气泡")
    st["slots"] := []
    loop slots {
        s := Map()
        dlg.SetFont("s11 Bold c1F2329")
        s["title"] := dlg.AddText("x0 y0 w280 h24 Hidden BackgroundWhite +0x100 +0x4000 +0x4000000", "")
        dlg.SetFont("s9 Norm c9CA3AF")
        s["sub"] := dlg.AddText("x0 y0 w280 h18 Hidden BackgroundWhite +0x100 +0x4000 +0x4000000", "")
        s["foot"] := dlg.AddText("x0 y0 w280 h18 Hidden BackgroundWhite +0x100 +0x4000 +0x4000000", "")
        s["sclear"] := dlg.AddText("x0 y0 w16 h16 Center Hidden BackgroundWhite +0x100", "✕")
        s["search"] := dlg.AddEdit("x0 y0 w120 h24 Hidden +0x4000000")     ; 收起不显示，全局搜索仍经它记下每个气泡的搜索词
        dlg.SetFont("s9 Norm c6B7280")
        s["zoomBtn"] := dlg.AddText("x0 y0 w60 h20 Hidden BackgroundWhite Right +0x100 +0x4000000", "⤢ 放大")
        dlg.SetFont("s10 Norm c1F2329")
        s["lv"] := dlg.AddListView("x0 y0 w280 h140 Hidden NoSort -Hdr -E0x200 +0x4000000", ["序", "编号", "起点 → 终点", "规格"])
        CableSortStyleLv(s["lv"], 27)
        s["back"] := CableSortAddPic(dlg, "x0 y0 w300 h200 Hidden", true)   ; 卡片底图：拖放、右键的目标
        CableSortToBottom(s["back"])
        s["lv"].ModifyCol(1, "36 Integer"), s["lv"].ModifyCol(2, 100), s["lv"].ModifyCol(4, "72 Right")
        s["colors"] := [], s["bubble"] := "", s["rows"] := [], s["query"] := ""
        idx := A_Index
        s["lv"].OnNotify(-12, ((i, lv, lp) => CableSortCustomDraw(st["slots"][i]["colors"], lp, -1, 1, [0, 3], true)).Bind(idx))
        s["lv"].OnNotify(-109, ((i, lv, lp) => CableSortBeginDrag(st, lv, st["slots"][i])).Bind(idx))
        s["lv"].OnNotify(-155, ((i, lv, lp) => CableSortKeyDown(st, lp, i)).Bind(idx))
        s["lv"].OnEvent("ItemFocus", ((i, lv, row) => CableSortLoadBubbleEditor(st, i, row)).Bind(idx))
        s["search"].OnEvent("Change", ((i, *) => st["slots"][i]["search"].Value != st["slots"][i]["query"] && CableSortSlotSearch(st, i, false)).Bind(idx))
        s["sclear"].OnEvent("Click", ((i, *) => CableSortSlotSearch(st, i, true)).Bind(idx))
        s["zoomBtn"].OnEvent("Click", ((i, *) => CableSortZoom(st, i)).Bind(idx))
        s["title"].OnEvent("DoubleClick", ((i, *) => i <= st["bubbles"].Length && CableSortRenameBubble(st, i)).Bind(idx))
        st["slots"].Push(s)
    }

    ; 底栏：状态 · 起终点胶囊 · 撤销 重做 导出 关闭
    dlg.SetFont("s9 c6B7280")
    c["status"] := dlg.AddText("x0 y0 w300 h20 +0x4000 +0x200", "")      ; SS_ENDELLIPSIS + 竖直居中
    c["detail"] := CableSortAddPic(dlg, "x0 y0 w300 h32")
    dlg.SetFont("s10 c1F2329")
    c["undoBtn"] := CableSortButton(dlg, "x0 y0 w100 h34", "↶ 撤销")
    c["redoBtn"] := CableSortButton(dlg, "x0 y0 w84 h34", "↷ 重做")
    c["preview"] := CableSortButton(dlg, "x0 y0 w84 h34", "预览")   ; 2026-11-11 用户要求：先看导出后的样子
    c["apply"] := CableSortButton(dlg, "x0 y0 w120 h34", "导出 CSV", "primary")   ; 经中望 CAD 写 CSV；2026-11-11 用户要求去掉括号里的“中望 CAD”
    c["close"] := CableSortButton(dlg, "x0 y0 w84 h34", "关闭")

    c["rules"].ModifyCol(1, 56), c["rules"].ModifyCol(2, 40), c["rules"].ModifyCol(3, 120)
    c["rules"].ModifyCol(4, "40 Integer"), c["rules"].ModifyCol(5, 52)

    c["rules"].OnEvent("ItemFocus", (lv, row) => CableSortLoadRuleEditor(st, row))
    c["mid"].OnEvent("ItemFocus", (lv, row) => CableSortLoadMidEditor(st, row))
    c["mid"].OnEvent("ItemCheck", (lv, item, checked) => CableSortMidItemCheck(st, item, checked))
    c["search"].OnEvent("Change", (ctrl, *) => ctrl.Value != st["search"] && (st["search"] := ctrl.Value, c["searchClear"].Visible := ctrl.Value != "", CableSortFillMid(st)))
    c["searchClear"].OnEvent("Click", (*) => CableSortClearSearch(st))
    c["add"].OnEvent("Click", (*) => CableSortRuleEdit(st, "add"))
    c["modify"].OnEvent("Click", (*) => CableSortRuleEdit(st, "modify"))
    c["delete"].OnEvent("Click", (*) => CableSortRuleEdit(st, "delete"))
    c["ruleUp"].OnEvent("Click", (*) => CableSortRuleEdit(st, "up"))
    c["ruleDown"].OnEvent("Click", (*) => CableSortRuleEdit(st, "down"))
    c["moveTo"].OnEvent("Click", (*) => CableSortMoveToMenu(st))
    c["swap"].OnEvent("Click", (*) => CableSortSwapKeep(st, CableSortMidPicked(st)))
    c["checkAll"].OnEvent("Click", (*) => CableSortMidCheckAll(st, CableSortMidChecked(st).Length != c["mid"].GetCount()))
    c["del"].OnEvent("Click", (*) => CableSortDelete(st, CableSortMidPicked(st)))
    c["trash"].OnEvent("Click", (*) => CableSortTrashWindow(st))
    c["newBubble"].OnEvent("Click", (*) => CableSortNewBubble(st))
    st["gsTimer"] := () => CableSortGlobalSearch(st, false)
    c["gsearch"].OnEvent("Change", (*) => SetTimer(st["gsTimer"], -120))   ; 停顿 0.12 秒再筛，快速连打不丢字
    c["gclear"].OnEvent("Click", (*) => CableSortGlobalSearch(st, true))
    c["reclass"].OnEvent("Click", (*) => CableSortReclassAll(st))
    c["apply"].OnEvent("Click", (*) => CableSortApply(st))
    c["preview"].OnEvent("Click", (*) => CableSortPreview(st))
    c["undoBtn"].OnEvent("Click", (*) => CableSortUndo(st, "undo"))
    c["redoBtn"].OnEvent("Click", (*) => CableSortUndo(st, "redo"))
    c["close"].OnEvent("Click", (*) => CableSortClose())
    c["mid"].OnNotify(-12, (lv, lp) => CableSortCustomDraw(st["midColors"], lp, 4, 0))   ; NM_CUSTOMDRAW，只给“状态”列着色，编号加粗
    c["rules"].OnNotify(-12, (lv, lp) => CableSortCustomDraw(st["ruleColors"], lp, 4, 0)) ; 只给“来源”列着色，前缀加粗
    c["mid"].OnNotify(-109, (lv, lp) => CableSortBeginDrag(st, lv, 0))                 ; LVN_BEGINDRAG
    c["mid"].OnNotify(-155, (lv, lp) => CableSortMidKeyDown(st, lp))   ; Delete 删除，Ctrl+A 全选
    dlg.OnEvent("ContextMenu", (g, ctrl, item, isRC, x, y) => CableSortContextMenu(st, ctrl, item))
    dlg.OnEvent("Size", (g, mm, w, h) => CableSortLayout(st, mm, w, h))
    dlg.OnEvent("Close", (*) => CableSortClose())
    dlg.OnEvent("Escape", (*) => CableSortClose())

    CableSortUi := st
    st["saveTimer"] := () => CableSortSaveProgress(st)
    CableSortUpdateUndoButtons(st)
    CableSortFillRules(st)
    CableSortRefreshBubbles(st)
    CableSortFillMid(st)
    if (resumeMsg = "")
        resumeMsg := "改动会自动保存到 " . st["progressPath"] . (isCsv ? "，下次打开同一个 CSV 可以接着做。" : "，关掉窗口后再运行 YSDL3 可以接着做。")
    if (isCsv && job["dupCount"])
        resumeMsg := "注意：CSV 里有 " . job["dupCount"] . " 行编号重复（可能是几次导出追加在同一个文件里），已各自保留。" . resumeMsg
    c["status"].Value := resumeMsg
    CableSortSetDetail(st, "点一下任意电缆，这里显示它的起点和终点", false)
    if isCsv
        c["apply"].Text := "另存 CSV…"
    dlg.Show(showOptions)
}

; CSV 模式：按气泡另存为新 CSV（UTF-8 带 BOM，Excel 直接打开不乱码），格式同插件导出
CableSortSaveCsv(st, path := "") {             ; path 供测试直接指定，不弹另存对话框
    title := "电缆排序", owner := " Owner" . st["gui"].Hwnd
    try text := CableSortBuildCsvText(st["job"], st["bubbles"])
    catch as e {
        MsgBox("生成 CSV 失败：`n" . e.Message, title, "Iconx" . owner)
        return
    }
    un := 0
    for cable in st["cables"]
        un += cable["bubble"] = 0
    quiet := path != ""
    if (!quiet && un && MsgBox("还有 " . un . " 项未分类，不会写进 CSV。继续？", title, "YesNo Icon!" . owner) != "Yes")
        return
    SplitPath(st["job"]["dwg"], , &dir, , &name)
    st["gui"].Opt("+OwnDialogs")
    if !quiet
        path := FileSelect("S16", dir . "\" . name . "-整理.csv", "另存为 CSV", "CSV 文件 (*.csv)")
    if (path = "")
        return
    if !RegExMatch(path, "i)\.csv$")
        path .= ".csv"
    try {
        f := FileOpen(path, "w", "UTF-8")
        f.Write(text)
        f.Close()
    } catch as e {
        MsgBox("写不进去（可能正在 Excel/WPS 里打开，关掉后再试）：`n" . path . "`n`n" . e.Message, title, "Iconx" . owner)
        return
    }
    st["dirty"] := true
    CableSortSaveProgress(st)                       ; 规则文件不写到 CSV 旁边（CSV 多在桌面，免得多出文件）
    lines := StrSplit(RTrim(text, "`r`n"), "`n").Length
    st["ctl"]["status"].Value := "已另存 " . lines . " 行到 " . path
    if !quiet
        MsgBox("已按 " . st["bubbles"].Length . " 个分类另存 " . lines . " 行到：`n" . path . "`n`n原来的 CSV 没有改动。", title, "Iconi" . owner)
}

; 保存整理进度（先写临时文件再改名）；失败时只在状态栏提示
CableSortSaveProgress(st) {
    if !st["dirty"]
        return
    try {
        tmp := st["progressPath"] . ".tmp"
        f := FileOpen(tmp, "w", "UTF-8")
        f.Write(CableSortSerializeProgress(st["job"], st["cables"], st["rules"], st["bubbles"]))
        f.Close()
        FileMove(tmp, st["progressPath"], 1)
        st["dirty"] := false
    } catch as e {
        try st["ctl"]["status"].Value := "进度保存失败：" . e.Message
    }
}

; 改动后 0.8 秒内合并保存一次
CableSortScheduleSave(st) {
    st["dirty"] := true
    if st.Has("saveTimer")
        SetTimer(st["saveTimer"], -800)
}

CableSortClose(*) {
    global CableSortUi
    if !IsObject(CableSortUi)
        return
    st := CableSortUi
    CableSortUi := ""
    ToolTip()
    if st.Has("saveTimer")
        SetTimer(st["saveTimer"], 0)
    CableSortSaveProgress(st)
    CableSortPopupClose(st)
    for id, z in st["zooms"].Clone()
        try z["gui"].Destroy()
    st["zooms"] := Map()
    try st["gui"].Destroy()
}

; ---------- 布局 ----------

CableSortLayout(st, minMax, w, h) {
    if (minMax = -1)
        return
    st["w"] := w, st["h"] := h
    c := st["ctl"]
    pad := 16
    ; 顶栏：全局搜索在左，“新增分类气泡”“全部按规则重新分类”在右
    headH := 60
    c["reclass"].GetPos(, , &rw, &bh)
    c["newBubble"].GetPos(, , &nw)
    c["reclass"].Move(w - pad - rw, (headH - bh) // 2)
    c["newBubble"].Move(w - pad - rw - 10 - nw, (headH - bh) // 2)
    gw := Max(240, Min(740, w - pad * 2 - rw - nw - 40))
    CableSortPlaceFramed(c["gframe"], c["gsearch"], pad, 12, gw, 36, 32)
    c["gclear"].Move(pad + gw - 28, 12 + (36 - 18) // 2)
    c["divHead"].Move(0, headH, w, 1)
    ; 摘要行
    sumY := headH + 1, sumH := 38
    c["summary"].Move(0, sumY, w, sumH)
    CableSortDrawSummary(st)
    c["divSum"].Move(0, sumY + sumH, w, 1)
    top := sumY + sumH + 1
    ; 底栏：右边四个按钮，左边状态文字和起终点胶囊
    footH := 58, fy := h - footH
    c["divFoot"].Move(0, fy, w, 1)
    c["close"].GetPos(, , , &bh)
    by := fy + (footH - bh) // 2
    x := w - pad
    for key in ["close", "apply", "preview", "redoBtn", "undoBtn"] {
        c[key].GetPos(, , &kw)
        x -= kw
        c[key].Move(x, by)
        x -= key = "redoBtn" ? 8 : 10
    }
    rowR := x - 14
    statusW := Min(340, Max(150, Round((rowR - pad) * 0.32)))
    c["status"].Move(pad, by, statusW, bh)
    st["detailArea"] := [pad + statusW + 14, fy + (footH - 32) // 2, Max(80, rowR - pad - statusW - 14), 32]
    CableSortDrawDetail(st)
    ; 三栏
    leftW := 368, midW := Max(440, Round((w - leftW) * 0.37)), midX := leftW + 1, bubX := midX + midW + 1
    c["divL"].Move(leftW, top, 1, fy - top)
    c["divM"].Move(midX + midW, top, 1, fy - top)
    colTop := top + 14, bottom := fy - 14
    ; 左：规则列表 + 编辑区
    lx := pad, lw := leftW - pad * 2
    c["ruleTitle"].Move(lx, colTop, lw, 24)
    c["ruleSub"].Move(lx, colTop + 26, lw, 18)
    hintH := 52
    ruleHintY := bottom - hintH
    btnRuleY := ruleHintY - 10 - 30
    cabY := btnRuleY - 10 - 32
    preY := cabY - 8 - 32
    c["ruleSep"].Move(lx, preY - 12, lw, 1)
    c["ruleHint"].Move(lx, ruleHintY, lw, hintH)
    x := lx
    for key in ["add", "modify", "delete", "ruleUp", "ruleDown"] {
        c[key].GetPos(, , &kw)
        c[key].Move(x, btnRuleY)
        x += kw + 6
    }
    c["prefixLabel"].Move(lx, preY + 7)
    CableSortPlaceFramed(c["prefixFrame"], c["prefix"], lx + 38, preY, 86, 32)
    c["rangeLabel"].Move(lx + 138, preY + 7)
    CableSortPlaceFramed(c["rangeFrame"], c["range"], lx + 176, preY, lw - 176, 32)
    c["cabLabel"].Move(lx, cabY + 7)
    c["cab"].Move(lx + 52, cabY + 3, lw - 52)
    rt := colTop + 52
    c["rules"].Move(lx - 4, rt, lw + 4, preY - 24 - rt)
    c["rules"].ModifyCol(3, Max(80, lw - SysGet(2) - 4 - 56 - 40 - 40 - 52))
    ; 中：未分类列表
    mx := midX + pad, mw := midW - pad * 2
    c["midTitle"].Move(mx, colTop, mw, 24)
    c["midSub"].Move(mx, colTop + 26, mw, 18)
    CableSortPlaceFramed(c["searchFrame"], c["search"], mx, colTop + 52, mw, 34, 32)
    c["searchClear"].Move(mx + mw - 28, colTop + 52 + 8)
    hy := bottom - 36
    c["selInfo"].Move(mx, hy, mw, 36)
    b2 := hy - 10 - 30, b1 := b2 - 6 - 30
    for row in [[["moveTo", "swap", "del"], b1], [["trash", "checkAll"], b2]] {
        x := mx
        for key in row[1] {
            c[key].GetPos(, , &kw)
            c[key].Move(x, row[2])
            x += kw + 6
        }
    }
    c["midSep"].Move(mx, b1 - 12, mw, 1)
    lt := colTop + 52 + 34 + 10, lh := b1 - 24 - lt
    c["mid"].Move(mx - 4, lt, mw + 4, lh)
    ; 列宽按列表宽度分：编号、规格固定，“状态”约 1/3，其余平分给起点、终点（扣掉竖向滚动条，不出横向滚动条）
    rest := mw - SysGet(2) - 4 - 96 - 52
    endW := Max(64, (rest - Max(110, rest // 3)) // 2)
    c["mid"].ModifyCol(1, 96), c["mid"].ModifyCol(2, endW), c["mid"].ModifyCol(3, endW), c["mid"].ModifyCol(4, 52)
    c["mid"].ModifyCol(5, Max(60, rest - endW * 2))
    ; 列表空了时的提示，放在列表中间偏上
    ey := lt + Max(44, lh // 2 - 90)
    c["emptyPic"].Move(mx + (mw - 56) // 2, ey, 56, 56)
    CableSortDrawEmptyMark(c["emptyPic"])
    c["emptyTitle"].Move(mx, ey + 68, mw, 26)
    c["emptySub"].Move(mx, ey + 98, mw, 40)
    ; 右：气泡
    rx := bubX + pad, rw2 := w - bubX - pad * 2
    c["bubTitle"].Move(rx, colTop, rw2, 24)
    c["hint"].Move(rx, colTop + 26, rw2, 18)
    st["bubArea"] := [rx, colTop + 52, rw2, bottom - colTop - 52]
    CableSortLayoutBubbles(st)
    ; 控件挪位后整窗重画一次：首次显示时窗口还没画完就挪了位，旧位置会留下残影（2026-11-11 前台截屏发现）
    DllCall("RedrawWindow", "Ptr", st["gui"].Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x85)   ; INVALIDATE | ERASE | ALLCHILDREN
}

; 气泡按网格排：不超过 4 个时 2 列，更多时宽度够就 3 列
CableSortLayoutBubbles(st) {
    if !st.Has("bubArea")
        return
    area := st["bubArea"], n := st["bubbles"].Length
    cols := n <= 4 ? 2 : (area[3] >= 900 ? 3 : 2)
    cols := Max(1, Min(cols, n))
    rows := Max(1, Ceil(n / cols))
    gap := 14
    cw := (area[3] - gap * (cols - 1)) // cols
    ch := (area[4] - gap * (rows - 1)) // rows
    for i, s in st["slots"] {
        if (i > n) {
            for key in ["back", "title", "sub", "foot", "lv", "search", "sclear", "zoomBtn"]
                s[key].Visible := false
            continue
        }
        x := area[1] + Mod(i - 1, cols) * (cw + gap)
        y := area[2] + ((i - 1) // cols) * (ch + gap)
        s["back"].Move(x, y, cw, ch)
        if !(s.Has("cardSize") && s["cardSize"] = cw . "x" . ch) {
            s["cardSize"] := cw . "x" . ch
            CableSortDrawCard(s["back"])
        }
        s["title"].Move(x + 30, y + 10, Max(40, cw - 30 - 84), 24)
        s["zoomBtn"].Move(x + cw - 16 - 60, y + 13, 60, 20)
        s["sub"].Move(x + 16, y + 36, cw - 32, 18)
        s["foot"].Move(x + 16, y + ch - 27, cw - 32, 18)
        s["lv"].Move(x + 10, y + 60, cw - 20, Max(30, ch - 60 - 42))
        ; 列宽按客户区算（扣掉竖向滚动条），不出现横向滚动条
        s["lv"].ModifyCol(3, Max(60, cw - 20 - 36 - 100 - 72 - SysGet(2) - 6))
        for key in ["back", "title", "sub", "foot", "lv", "zoomBtn"]
            s[key].Visible := true
        s["search"].Visible := false, s["sclear"].Visible := false
    }
}

; 气泡卡片底图：白底、浅灰描边、8 圆角；标题前灰色小圆点；底部一条细线隔开“共 N 项”
CableSortDrawCard(pic) {
    k := A_ScreenDPI / 96
    CableSortPaint(pic, (g, w, h) => (
        CableSortRound(g, 0, 0, w, h, 8 * k, "FFFFFF", "E4E6EB"),
        CableSortRound(g, 16 * k, 18 * k, 8 * k, 8 * k, 4 * k, "9CA3AF"),
        CableSortRect(g, 16 * k, h - 36 * k, w - 32 * k, 1, "F0F1F4")))
}

; 未分类列表空了时的对勾圆标
CableSortDrawEmptyMark(pic) {
    CableSortPaint(pic, (g, w, h) => (
        CableSortRound(g, 1, 1, w - 2, h - 2, (h - 2) / 2, "EEF7F1", "CFE8D6"),
        CableSortDrawText(g, Chr(0xE73E), 0, 0, w, h, 15, false, "166534", 1, "Segoe MDL2 Assets")))
}

; 摘要行：宽度不够时换成精简版（待处理只写总数，去掉末尾说明）
CableSortDrawSummary(st) {
    if !st.Has("summaryRuns")
        return
    full := st["summaryRuns"], compact := st["summaryCompact"], k := A_ScreenDPI / 96
    CableSortPaint(st["ctl"]["summary"], (g, w, h) => CableSortDrawRuns(g
        , CableSortRunsWidth(full, 9.5) + 32 * k <= w ? full : compact, 16 * k, h, 9.5, w - 12 * k), "F7F8FA")
}

; 底栏胶囊：选中电缆时浅绿底、深绿粗体起终点；否则浅灰底灰字提示。宽度随内容，最多占满可用宽度
CableSortDrawDetail(st) {
    if !(st.Has("detailArea") && st.Has("detailRuns"))
        return
    a := st["detailArea"], runs := st["detailRuns"], strong := st["detailStrong"], k := A_ScreenDPI / 96
    want := Ceil((CableSortRunsWidth(runs, 10) + 30 * k) / k)
    d := st["ctl"]["detail"]
    d.Move(a[1], a[2], Min(a[3], Max(120, want)), a[4])
    CableSortPaint(d, (g, w, h) => (
        CableSortRound(g, 0, 0, w, h, 8 * k, strong ? "EEF7F1" : "F7F8FA", strong ? "D3EFDC" : "ECEEF1"),
        CableSortDrawRuns(g, runs, 14 * k, h, 10, w - 10 * k)))
}

; ---------- 填充 ----------

CableSortBubbleOf(st, cable) {
    for b in st["bubbles"]
        if (b["id"] = cable["bubble"])
            return b
    return ""
}

CableSortRed(cable) {
    return !(cable["status"] = "ok" || cable["status"] = "manual" || cable["status"] = "fixed")
}

; 未分类列表“状态”列的颜色：待处理橙色，其他行灰色，其余默认
CableSortStatusColor(cable) {
    return cable["status"] = "fixed" ? "9CA3AF" : CableSortRed(cable) ? "C2410C" : ""
}

; 气泡里不标红：只把“其他行”显示成灰色
CableSortBubbleColor(cable) {
    return cable["status"] = "fixed" ? "9CA3AF" : ""
}

CableSortStatusText(st, cable) {
    rules := st["rules"]
    rule := cable["rule"] ? rules[cable["rule"]] : ""
    ruleText := IsObject(rule) ? rule["prefix"] . (rule["range"] != "" ? "(" . rule["range"] . ")" : "") . " → " . rule["cabinet"] : ""
    switch cable["status"] {
        case "ok": return "按规则 " . ruleText
        case "manual": return cable.Has("flip") && cable["flip"] ? "手动对调起终点" : "手动指定起点"
        case "nomatch": return "规则 " . ruleText . "：两端都不是这个柜"
        case "norule": return "没有规则（前缀 " . cable["parsed"]["prefix"] . "）"
        case "unparsed": return "编号格式无法识别"
        case "problem": return "编号重复或两端对不上（" . cable["rows"].Length . " 行）"
        case "fixed": return "其他行（第 2 列不是电缆编号）"
    }
    return cable["status"]
}

CableSortFillRules(st, select := 0) {
    lv := st["ctl"]["rules"]
    counts := Map()
    for cable in st["cables"]
        if cable["rule"]
            counts[cable["rule"]] := (counts.Has(cable["rule"]) ? counts[cable["rule"]] : 0) + 1
    colors := []
    lv.Opt("-Redraw")
    lv.Delete()
    for i, r in st["rules"] {
        lv.Add(, r["prefix"], r["range"], r["cabinet"], counts.Has(i) ? counts[i] : 0, r["source"])
        colors.Push(r["source"] = "推断" ? "9CA3AF" : (counts.Has(i) ? "" : "C2410C"))
    }
    st["ruleColors"] := colors
    lv.Opt("+Redraw")
    if select
        lv.Modify(select, "Select Focus Vis")
}

CableSortMatches(st, cable) {
    return !cable["bubble"] && CableSortQueryMatch(cable, st["search"])
}

; 中间列表：只放未分类的条目（按原先后），已放进气泡的只在气泡里显示；保留勾选状态
; 点搜索框右端的叉号：清空搜索、列表恢复全部，焦点回到搜索框
CableSortClearSearch(st) {
    c := st["ctl"]
    c["search"].Value := ""
    st["search"] := ""
    c["searchClear"].Visible := false
    CableSortFillMid(st)
    c["search"].Focus()
}

; 全局搜索：把同一个搜索词填进未分类、每个气泡和放大窗口的搜索框，状态栏汇总各处搜到几根
CableSortGlobalSearch(st, clear) {
    c := st["ctl"]
    if clear
        c["gsearch"].Value := "", SetTimer(st["gsTimer"], 0)
    ; 筛选期间又打了字：筛完再按最新内容筛一遍，保证所有框和全局框一致
    loop {
        q := c["gsearch"].Value
        CableSortGlobalApply(st, q)
    } until c["gsearch"].Value = q
    if clear
        c["gsearch"].Focus()
}

CableSortGlobalApply(st, q) {
    c := st["ctl"]
    c["gclear"].Visible := q != ""
    c["search"].Value := q, st["search"] := q, c["searchClear"].Visible := q != ""
    CableSortFillMid(st)
    for i, sl in st["slots"] {
        sl["search"].Value := q, sl["query"] := q
        sl["sclear"].Visible := q != "" && sl["search"].Visible
        if (i <= st["bubbles"].Length)
            CableSortFillBubble(st, i)
    }
    for id, z in st["zooms"] {
        z["search"].Value := q, z["query"] := q, z["sclear"].Visible := q != ""
        CableSortFillZoom(st, z)
    }
    if (q = "") {
        c["status"].Value := "已清空全局搜索"
    } else {
        total := st["midRows"].Length, parts := st["midRows"].Length ? "未分类 " . st["midRows"].Length : ""
        for i, b in st["bubbles"] {
            n := st["slots"][i]["rows"].Length
            total += n
            if n
                parts .= (parts = "" ? "" : "、") . b["name"] . " " . n
        }
        c["status"].Value := "全局搜索「" . q . "」共 " . total . " 根"
        st["detailCable"] := ""
        CableSortSetDetail(st, "  全局搜索「" . q . "」共 " . total . " 根" . (parts != "" ? "　｜　" . parts : ""), false)
    }
}

CableSortFillMid(st, keepChecked := true) {
    lv := st["ctl"]["mid"]
    checked := Map()
    if keepChecked
        for cable in CableSortMidChecked(st)
            checked[cable["key"]] := true
    rows := [], colors := []
    for cable in st["cables"]
        if CableSortMatches(st, cable)
            rows.Push(cable)
    q := st["ctl"]["search"].Value
    top := (st.Has("midFilledQuery") && st["midFilledQuery"] = q) ? CableSortLvTop(lv) : 0
    st["midFilledQuery"] := q
    lv.Opt("-Redraw")
    lv.Delete()
    for cable in rows {
        row := CableSortKeepRow(cable)
        lv.Add(checked.Has(cable["key"]) ? "Check" : "", cable["id"], CableSortDisplay(CableSortStartCell(cable))
            , CableSortDisplay(CableSortEndCell(cable)), CableSortCell(row, 4), CableSortStatusText(st, cable))
        colors.Push(CableSortStatusColor(cable))
    }
    st["midRows"] := rows, st["midColors"] := colors, st["lastCheck"] := 0
    lv.Opt("+Redraw")
    ; 列表空了：盖一块“全部已分类 / 没有搜到”的提示
    c := st["ctl"], empty := !rows.Length
    if empty {
        placed := 0
        for cable in st["cables"]
            placed += cable["bubble"] > 0
        c["emptyTitle"].Value := Trim(q) != "" ? "没有搜到" : "全部已分类"
        c["emptySub"].Value := Trim(q) != "" ? "未分类电缆里没有匹配「" . q . "」的。" : placed . " 项都已放进气泡，`n没有待分类的电缆。"
    }
    for key in ["emptyPic", "emptyTitle", "emptySub"]
        if (c[key].Visible != empty)
            c[key].Visible := empty
    CableSortLvScrollTo(lv, top)
    CableSortUpdateSummary(st)
    CableSortUpdateSelInfo(st)
}

CableSortFillBubble(st, i, select := "") {
    s := st["slots"][i], bubble := st["bubbles"][i]
    s["bubble"] := bubble
    s["title"].Value := bubble["name"]
    rows := CableSortFilterRows(bubble["items"], s["query"])
    s["sub"].Value := CableSortBubbleSub(bubble, rows, s["query"])
    s["foot"].Value := (Trim(s["query"]) != "" ? "搜到 " . rows.Length . " 项 · " : "") . "共 " . bubble["items"].Length . " 项 · 拖动可微调顺序"
    CableSortFillItemsLv(s, bubble, rows, false, "FFFFFF", select)
    if st["zooms"].Has(bubble["id"])
        CableSortFillZoom(st, st["zooms"][bubble["id"]], select)
}

; 气泡副标题：条目数、搜索结果数、排序方式
CableSortBubbleSub(bubble, rows, query) {
    return "已包含 " . bubble["items"].Length . " 项电缆" . (Trim(query) != "" ? "，搜到 " . rows.Length . " 项" : "") . " · "
        . (bubble.Has("manual") && bubble["manual"] ? "已手动调整顺序（右键可恢复按编号排序）" : "按编号自动排序，拖动可微调")
}

; 按搜索词筛选气泡条目（顺序不变）
CableSortFilterRows(items, query) {
    if (Trim(query) = "")
        return items.Clone()
    out := []
    for cable in items
        if CableSortQueryMatch(cable, query)
            out.Push(cable)
    return out
}

; 把 rows（筛选后要显示的条目）填进视图 v 的列表，记下 v["rows"]（显示行 → 条目）和每行颜色。
; wide 为放大窗口（起点、终点分两列）；“序”是条目在气泡里的实际位置；select 为要选中的条目位置（气泡内序号）
CableSortFillItemsLv(v, bubble, rows, wide, bg, select := "") {
    pos := Map()
    for k, cable in bubble["items"]
        pos[cable["key"]] := k
    lv := v["lv"], colors := []
    ; 搜索词没变时记住滚动位置，重新填完再滚回去（对调起终点等刷新后列表不跳动）
    q := v.Has("query") ? v["query"] : ""
    top := (v.Has("filledQuery") && v["filledQuery"] = q) ? CableSortLvTop(lv) : 0
    v["filledQuery"] := q
    lv.Opt("-Redraw Background" . bg)
    lv.Delete()
    for cable in rows {
        row := CableSortKeepRow(cable)
        if wide
            lv.Add(, pos[cable["key"]], cable["id"], CableSortDisplay(CableSortStartCell(cable)), CableSortDisplay(CableSortEndCell(cable)), CableSortCell(row, 4))
        else
            lv.Add(, pos[cable["key"]], cable["id"], CableSortDisplay(CableSortStartCell(cable)) . " → " . CableSortDisplay(CableSortEndCell(cable)), CableSortCell(row, 4))
        colors.Push(CableSortBubbleColor(cable))
    }
    v["rows"] := rows, v["colors"] := colors
    lv.Opt("+Redraw")
    CableSortLvScrollTo(lv, top)                     ; 关着重绘时 LVM_SCROLL 在可见窗口里不生效，放在恢复重绘之后
    if IsObject(select) {
        want := Map()
        for k in select
            if (k >= 1 && k <= bubble["items"].Length)
                want[bubble["items"][k]["key"]] := true
        first := 0, last := 0
        for r, cable in rows
            if want.Has(cable["key"]) {
                lv.Modify(r, "Select" . (first ? "" : " Focus Vis"))
                if !first
                    first := r
                last := r
            }
        if last
            lv.Modify(last, "Vis")
    }
}

; 列表最上面一行的序号（0 起）
CableSortLvTop(lv) {
    return SendMessage(0x1027, 0, 0, lv)             ; LVM_GETTOPINDEX
}

; 把第 top 行（0 起）滚到最上面
CableSortLvScrollTo(lv, top) {
    n := lv.GetCount()
    if (top <= 0 || n = 0)
        return
    top := Min(top, n - 1)
    rc := Buffer(16, 0)                              ; LVIR_BOUNDS = 0
    SendMessage(0x100E, 0, rc, lv)                   ; LVM_GETITEMRECT 第 0 行
    h := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
    if (h > 0)
        SendMessage(0x1014, 0, (top - CableSortLvTop(lv)) * h, lv)   ; LVM_SCROLL
}

; 气泡标题行的搜索框：输入时筛选，点叉号清空
CableSortSlotSearch(st, i, clear) {
    s := st["slots"][i]
    if clear
        s["search"].Value := ""
    s["query"] := s["search"].Value
    s["sclear"].Visible := s["query"] != "" && s["search"].Visible
    if (i <= st["bubbles"].Length)
        CableSortFillBubble(st, i)
    if clear
        s["search"].Focus()
}

CableSortRefreshBubbles(st) {
    gone := []                                       ; 气泡已删除的放大窗口一起关掉
    for id, z in st["zooms"]
        if !CableSortZoomIndex(st, z)
            gone.Push(z)
    for z in gone
        CableSortZoomClose(st, z)
    loop st["bubbles"].Length
        CableSortFillBubble(st, A_Index)
    CableSortLayoutBubbles(st)
}

CableSortUpdateSummary(st) {
    job := st["job"], counts := Map(), un := 0, deleted := 0
    for cable in st["cables"] {
        counts[cable["status"]] := (counts.Has(cable["status"]) ? counts[cable["status"]] : 0) + 1
        un += cable["bubble"] = 0
        deleted += cable["bubble"] = -1
    }
    Cnt(k) => counts.Has(k) ? counts[k] : 0
    trashText := "已删除（" . deleted . "）…"
    if (st["ctl"]["trash"].Text != trashText)
        st["ctl"]["trash"].Text := trashText, st["ctl"]["trash"].Redraw()
    red := 0
    for cable in st["cables"]
        red += CableSortRed(cable)
    total := st["cables"].Length
    c := st["ctl"]
    st["placedCount"] := total - un - deleted
    c["midTitle"].Value := "未分类电缆（" . un . " 项）"
    c["midSub"].Value := "已放进气泡 " . (total - un - deleted) . " 项" . (deleted ? "，已删除 " . deleted . " 项" : "")
    ; 摘要一行：数字加粗深色，说明灰色，“·”分隔；只有待处理用浅琥珀胶囊（设计稿）
    G(t) => [t, "6B7280", false]
    B(n) => [String(n), "1F2329", true]
    sep := ["  ·  ", "C4C8CF", false]
    head := [G("共配成 "), B(total - Cnt("fixed")), G(" 根电缆（非电缆行 " . Cnt("fixed") . "）"), sep
        , G("分类气泡 "), B(st["bubbles"].Length), G(" 个"), sep
        , G("规则 "), B(st["rules"].Length), G(" 条（" . (FileExist(st["rulesPath"]) ? "已读取" : "本工程还没有规则文件") . "）"), sep
        , G("按规则 "), B(Cnt("ok")), G(" 根"), sep, G("手动 "), B(Cnt("manual")), G(" 根"), sep]
    tail := [sep, G("未分类 "), B(un), G(" 项"), sep, G("已删除 "), B(deleted), G(" 项（不导出）")]
    pend := "待处理 " . red . " 根"
    full := head.Clone(), compact := head.Clone()
    if red {
        full.Push([pend . "：无规则 " . Cnt("norule") . " · 无法识别 " . Cnt("unparsed") . " · 两端对不上 " . Cnt("nomatch")
            . " · 编号重复 " . Cnt("problem"), "8A5A12", false, "FCF0DA"])
        compact.Push([pend, "8A5A12", false, "FCF0DA"])
    } else {
        full.Push(G(pend)), compact.Push(G(pend))
    }
    full.Push(tail*), compact.Push(tail*)
    full.Push(sep, G(CableSortIsCsv(st) ? "另存为新的 CSV，原文件和图纸都不动" : "导出只写 CSV"))
    st["summaryRuns"] := full, st["summaryCompact"] := compact
    text := ""                                       ; 摘要行是位图，留一份纯文字（测试和排查用）
    for seg in full
        text .= seg[1]
    st["summaryText"] := text
    CableSortDrawSummary(st)
}

CableSortUpdateSelInfo(st) {
    n := CableSortMidChecked(st).Length
    st["ctl"]["selInfo"].Value := n ? "已勾选 " . n . " 项：拖到右边的气泡，或点“移到分类”“删除”。"
        : "Ctrl+A 全选当前列表（搜索后即全部结果）；按住 Shift 点勾选框可整段勾选；“状态”列橙色为待处理。"
}

; 勾选当前列表的全部（勾上时同时选中，方便直接拖动）或全部取消
CableSortMidCheckAll(st, on) {
    lv := st["ctl"]["mid"]
    st["bulkCheck"] := true
    lv.Modify(0, on ? "Check Select" : "-Check -Select")
    st["bulkCheck"] := false
    st["lastCheck"] := 0
    CableSortUpdateSelInfo(st)
}

; 勾选框：按住 Shift 点时，把上一次点的那项到这一项整段设成同样的勾选状态
CableSortMidItemCheck(st, item, checked) {
    if (st.Has("bulkCheck") && st["bulkCheck"])
        return
    last := st.Has("lastCheck") ? st["lastCheck"] : 0
    lv := st["ctl"]["mid"]
    if (GetKeyState("Shift") && last && last != item && last <= lv.GetCount()) {
        st["bulkCheck"] := true
        loop Abs(item - last) + 1 {
            r := Min(item, last) + A_Index - 1
            lv.Modify(r, checked ? "Check" : "-Check")
        }
        st["bulkCheck"] := false
    }
    st["lastCheck"] := item
    CableSortUpdateSelInfo(st)
}

CableSortMidKeyDown(st, lParam) {
    vk := NumGet(lParam, 24, "UShort")
    if (vk = 0x2E)                                   ; Delete：删除
        CableSortDelete(st, CableSortMidPicked(st))
    else if (vk = 0x41 && GetKeyState("Ctrl"))       ; Ctrl+A：全选并勾上
        CableSortMidCheckAll(st, true)
}

; ---------- 选取 ----------

CableSortSelected(lv) {
    out := [], row := 0
    while (row := lv.GetNext(row))
        out.Push(row)
    return out
}

CableSortMidChecked(st) {
    out := [], row := 0, lv := st["ctl"]["mid"]
    while (row := lv.GetNext(row, "C"))
        if (row <= st["midRows"].Length)
            out.Push(st["midRows"][row])
    return out
}

; 中间列表要操作的电缆：有勾选用勾选的，否则用选中的
CableSortMidPicked(st) {
    out := CableSortMidChecked(st)
    if out.Length
        return out
    for row in CableSortSelected(st["ctl"]["mid"])
        out.Push(st["midRows"][row])
    return out
}

CableSortBubblePicked(st, i) {
    return CableSortViewPicked(st["slots"][i])
}

; 视图（气泡或放大窗口）里选中的条目：显示行经 v["rows"] 换成条目（搜索筛选后行号和气泡位置不同）
CableSortViewPicked(v) {
    out := []
    for k in CableSortSelected(v["lv"])
        if (k <= v["rows"].Length)
            out.Push(v["rows"][k])
    return out
}

; 显示行之间的插入位置 p（0 起）换成气泡内的插入位置（插在气泡第 pos+1 项之前）
CableSortRowPosToItemPos(rows, items, p) {
    idx := Map()
    for k, cable in items
        idx[cable["key"]] := k
    if (p < rows.Length)
        return idx[rows[p + 1]["key"]] - 1
    return rows.Length ? idx[rows[rows.Length]["key"]] : items.Length
}

; ---------- 放置 ----------

; 把 cables 放进第 target 个气泡的 pos（0 起，插在原第 pos+1 项之前）处；target 为 0 表示移出分类。
CableSortPlace(st, cables, target, pos := -1, record := true) {
    if !cables.Length
        return
    if record
        CableSortPushUndo(st, (target ? "移到「" . st["bubbles"][target]["name"] . "」" : "移出分类") . " " . cables.Length . " 项")
    moving := Map()
    for cable in cables
        moving[cable["key"]] := true
    dest := target ? st["bubbles"][target] : ""
    ins := 0, dropAt := pos >= 0
    if IsObject(dest) {
        if (pos < 0)
            pos := dest["items"].Length
        for k, cable in dest["items"]
            if (k <= pos && !moving.Has(cable["key"]))
                ins++
    }
    touched := Map()
    for b in st["bubbles"] {
        keep := []
        for cable in b["items"]
            if !moving.Has(cable["key"])
                keep.Push(cable)
        if (keep.Length != b["items"].Length)
            touched[b["id"]] := true
        b["items"] := keep
    }
    newSel := []
    if IsObject(dest) {
        ; 气泡内上下拖动 = 手动调整顺序，此后这个气泡保留手动顺序；从别处放进来时，自动排序的气泡重新按编号排，
        ; 手动调整过的气泡放在松开的位置；没有位置（拖到气泡标题区、用“移到分类”）时按编号插到合适位置，其他条目不动
        reorder := true
        for cable in cables
            if (cable["bubble"] != dest["id"])
                reorder := false
        if reorder
            dest["manual"] := true
        manual := dest.Has("manual") && dest["manual"]
        for cable in cables {
            if (manual && dropAt)
                dest["items"].InsertAt(++ins, cable)
            else
                CableSortInsertSorted(dest["items"], cable)
            cable["bubble"] := dest["id"]
        }
        CableSortTidy(dest)
        for k, cable in dest["items"]
            if moving.Has(cable["key"])
                newSel.Push(k)
        touched[dest["id"]] := true
    } else {
        for cable in cables
            cable["bubble"] := 0
    }
    for i, b in st["bubbles"]
        if touched.Has(b["id"])
            CableSortFillBubble(st, i, (IsObject(dest) && b["id"] = dest["id"]) ? newSel : "")
    CableSortFillMid(st, false)
}

CableSortMoveToMenu(st) {
    cables := CableSortMidPicked(st)
    if !cables.Length {
        MsgBox("请先在电缆列表里勾选或选中电缆。", "电缆排序", "Iconi Owner" . st["gui"].Hwnd)
        return
    }
    CableSortMidMenu(st, true)                       ; 按钮专门用来移动，直接展开
}

; 拖动：源为中间列表（src=0）或第 src 个气泡。按住左键时跟随鼠标找目标气泡并显示插入线，松开后放置
; 拖动：源为中间列表（src=0）或一个视图（气泡 slot / 放大窗口）。按住左键时跟随鼠标找目标并显示插入线，松开后放置
CableSortBeginDrag(st, srcLv, src) {
    cables := IsObject(src) ? CableSortViewPicked(src) : CableSortMidPicked(st)
    if !cables.Length
        return
    mark := Buffer(16, 0), pt := Buffer(8, 0), hit := Buffer(24, 0), rc := Buffer(16, 0)
    NumPut("UInt", 16, mark, 0)
    lastLv := 0, target := -1, pos := -1
    ClearMark(lv) {
        NumPut("Int", -1, mark, 8)
        SendMessage(0x10A6, 0, mark, lv)             ; LVM_SETINSERTMARK
    }
    while GetKeyState("LButton", "P") {
        DllCall("GetCursorPos", "Ptr", pt)
        hwnd := DllCall("WindowFromPoint", "Int64", NumGet(pt, 0, "Int64"), "Ptr")
        target := -1, pos := -1, tlv := 0, view := ""
        if (hwnd = st["ctl"]["mid"].Hwnd) {
            target := 0
        } else {
            for i, s in st["slots"] {
                if (i > st["bubbles"].Length)
                    break
                if (hwnd = s["lv"].Hwnd || hwnd = s["back"].Hwnd || hwnd = s["title"].Hwnd || hwnd = s["sub"].Hwnd
                    || hwnd = s["foot"].Hwnd || hwnd = s["zoomBtn"].Hwnd) {
                    target := i, view := s
                    if (hwnd = s["lv"].Hwnd)
                        tlv := s["lv"]
                    break
                }
            }
            if (target < 0)
                for id, z in st["zooms"]
                    if (hwnd = z["lv"].Hwnd) {
                        zi := CableSortZoomIndex(st, z)
                        if zi
                            target := zi, view := z, tlv := z["lv"]
                        break
                    }
        }
        if (lastLv && (!tlv || tlv.Hwnd != lastLv.Hwnd))
            ClearMark(lastLv)
        tip := ""
        if (target > 0) {
            items := st["bubbles"][target]["items"], rows := view["rows"], count := rows.Length
            pos := items.Length
            if tlv {
                DllCall("ScreenToClient", "Ptr", tlv.Hwnd, "Ptr", pt)
                y := NumGet(pt, 4, "Int")
                DllCall("GetClientRect", "Ptr", tlv.Hwnd, "Ptr", rc)
                ch := NumGet(rc, 12, "Int")
                if (y < 24)
                    SendMessage(0x1014, 0, -18, tlv)  ; LVM_SCROLL：拖到顶部往上滚
                else if (y > ch - 12)
                    SendMessage(0x1014, 0, 18, tlv)
                NumPut("Int", 6, hit, 0), NumPut("Int", y, hit, 4)
                item := SendMessage(0x1012, 0, hit, tlv)   ; LVM_HITTEST
                item := item > 0x7FFFFFFF ? -1 : item
                after := 0
                if (item >= 0 && item < count) {
                    NumPut("Int", 0, rc, 0)
                    SendMessage(0x100E, item, rc, tlv)  ; LVM_GETITEMRECT
                    after := y > (NumGet(rc, 4, "Int") + NumGet(rc, 12, "Int")) // 2
                    p := item + after
                } else {
                    item := count - 1, after := 1, p := count
                }
                pos := CableSortRowPosToItemPos(rows, items, p)
                NumPut("UInt", after ? 1 : 0, mark, 4)   ; LVIM_AFTER
                NumPut("Int", item, mark, 8)
                SendMessage(0x10A6, 0, mark, tlv)
                lastLv := tlv
            }
            if tlv
                tip := "移到「" . st["bubbles"][target]["name"] . "」第 " . (pos + 1) . " 位（" . cables.Length . " 项）"
            else                                     ; 拖到气泡名称、副标题、搜索框等标题区：按编号自动插到合适位置
                pos := -1, tip := "放进「" . st["bubbles"][target]["name"] . "」，按编号自动插到合适位置（" . cables.Length . " 项）"
        } else if (target = 0 && IsObject(src)) {
            tip := "移出分类（" . cables.Length . " 项）"
        }
        ToolTip(tip)
        Sleep(15)
    }
    ToolTip()
    if lastLv
        ClearMark(lastLv)
    if (target > 0)
        CableSortPlace(st, cables, target, pos)
    else if (target = 0 && IsObject(src))
        CableSortPlace(st, cables, 0)
}

CableSortKeyDown(st, lParam, i) {
    if (NumGet(lParam, 24, "UShort") = 0x2E)         ; Delete：移出分类
        CableSortPlace(st, CableSortBubblePicked(st, i), 0)
}

; ---------- 气泡 ----------

CableSortAskName(st, title, default := "") {
    r := InputBox("分类名称（导出 CSV 的“分类”列）：", title, "w320 h130", default)
    if (r.Result != "OK")
        return ""
    return Trim(RegExReplace(r.Value, "[`t`r`n]+", " "))
}

CableSortNewBubble(st, cables := "") {
    if (st["bubbles"].Length >= st["slots"].Length) {
        MsgBox("最多 " . st["slots"].Length . " 个分类气泡。", "电缆排序", "Icon! Owner" . st["gui"].Hwnd)
        return
    }
    name := CableSortAskName(st, "新增分类气泡")
    if (name = "")
        return
    CableSortPushUndo(st, "新增气泡「" . name . "」")
    st["bubbles"].Push(Map("id", st["nextId"]++, "name", name, "box", 0, "items", [], "manual", false))
    CableSortFillBubble(st, st["bubbles"].Length)
    CableSortLayoutBubbles(st)
    if IsObject(cables)
        CableSortPlace(st, cables, st["bubbles"].Length, -1, false)
    else
        CableSortUpdateSummary(st)
}

CableSortContextMenu(st, ctrl, item) {
    if !IsObject(ctrl)
        return
    if (ctrl.Hwnd = st["ctl"]["mid"].Hwnd) {
        CableSortMidMenu(st)
        return
    }
    for i, s in st["slots"] {
        if (i > st["bubbles"].Length)
            break
        if (ctrl.Hwnd = s["lv"].Hwnd) {                  ; 右键电缆：电缆菜单
            CableSortBubbleMenu(st, i)
            return
        }
        if (ctrl.Hwnd = s["back"].Hwnd || ctrl.Hwnd = s["title"].Hwnd || ctrl.Hwnd = s["sub"].Hwnd || ctrl.Hwnd = s["foot"].Hwnd || ctrl.Hwnd = s["zoomBtn"].Hwnd) {
            CableSortBubbleTitleMenu(st, i)              ; 右键气泡名称：气泡菜单
            return
        }
    }
}

; 右键电缆（气泡或放大窗口的列表里）的菜单：只有对电缆的操作（用户 2026-11-10 要求；气泡本身的操作在右键气泡名称的菜单里，改名为双击名称）
; expand：“移到分类”是否展开（点它在原位置重开菜单切换展开 / 收起）
CableSortBubbleMenu(st, i, view := "", expand := false) {
    picked := CableSortViewPicked(IsObject(view) ? view : st["slots"][i])
    k := picked.Length
    e := [CableSortFlipEntry(st, picked), Map("kind", "sep")]
    CableSortMoveEntries(st, e, picked, i, expand, (*) => CableSortBubbleMenu(st, i, view, !expand))
    e.Push(Map("text", "只把所选按编号排序（" . k . " 根）", "icon", Chr(0xE8CB), "enabled", k >= 2, "action", () => CableSortSortPicked(st, i, picked)))
    e.Push(Map("text", "删除所选电缆（" . k . "，不导出）", "icon", Chr(0xE74D), "kind", "danger", "enabled", k > 0, "action", () => CableSortDelete(st, picked)))
    CableSortPopup(st, e, IsObject(view) ? view["gui"].Hwnd : st["gui"].Hwnd)
}

; 右键气泡名称（标题区）的菜单：只管整个气泡——放大、按编号排序这个气泡、删除这个气泡（用户 2026-11-10 要求与电缆菜单分开）
CableSortBubbleTitleMenu(st, i, view := "") {
    e := []
    if !IsObject(view)
        e.Push(Map("text", "放大…", "icon", Chr(0xE740), "action", () => CableSortZoom(st, i)))
    e.Push(Map("text", "按编号排序这个气泡", "icon", Chr(0xE8CB), "action", () => CableSortResortBubble(st, i)))
    e.Push(Map("kind", "sep"))
    e.Push(Map("text", "删除这个气泡（电缆回到未分类）", "icon", Chr(0xE74D), "kind", "danger", "action", () => CableSortDeleteBubble(st, i)))
    CableSortPopup(st, e, IsObject(view) ? view["gui"].Hwnd : st["gui"].Hwnd)
}

; “移到分类 ▸”一行，展开时下面缩进列出其他气泡和“新建分类气泡…”；skip 为当前所在气泡（不列出）
CableSortMoveEntries(st, e, picked, skip, expand, toggle) {
    k := picked.Length
    e.Push(Map("text", "移到分类", "icon", Chr(0xE8B7), "enabled", k > 0, "hint", expand ? "▾" : "▸", "stay", true, "action", toggle))
    if !(expand && k > 0)
        return
    for j, ob in st["bubbles"]
        if (j != skip)
            e.Push(Map("text", ob["name"] . "（" . ob["items"].Length . "）", "indent", true, "action", CableSortPlaceAction(st, picked, j)))
    e.Push(Map("text", "＋ 新建分类气泡…", "indent", true, "action", () => CableSortNewBubble(st, picked)))
}

; 局部排序：只把选中的电缆按编号排好，放回它们原来占的那些位置，其他电缆一个都不动；气泡记为手动调整
CableSortSortPicked(st, i, picked) {
    b := st["bubbles"][i], keys := Map()
    for cable in picked
        keys[cable["key"]] := true
    pos := [], sel := []
    for k, cable in b["items"]
        if keys.Has(cable["key"])
            pos.Push(k), sel.Push(cable)
    if (sel.Length < 2)
        return
    CableSortPushUndo(st, "「" . b["name"] . "」所选 " . sel.Length . " 根按编号排序")
    for j, cable in CableSortSortList(sel)
        b["items"][pos[j]] := cable
    b["manual"] := true
    CableSortFillBubble(st, i, pos)
    st["ctl"]["status"].Value := "已把所选 " . sel.Length . " 根按编号排序，其他电缆位置不变（Ctrl+Z 撤销）"
}

CableSortResortBubble(st, i) {
    b := st["bubbles"][i]
    CableSortPushUndo(st, "按编号排序「" . b["name"] . "」")
    b["manual"] := false
    b["items"] := CableSortSortList(b["items"])
    CableSortFillBubble(st, i)
}

; 未分类列表的右键菜单（“移到分类 ▸”按钮也用它）：对调起终点、移到各气泡、删除
CableSortMidMenu(st, expand := false) {
    picked := CableSortMidPicked(st), k := picked.Length
    e := [CableSortFlipEntry(st, picked), Map("kind", "sep")]
    CableSortMoveEntries(st, e, picked, 0, expand, (*) => CableSortMidMenu(st, !expand))
    e.Push(Map("kind", "sep"))
    e.Push(Map("text", "删除所选电缆（" . k . "，不导出）", "icon", Chr(0xE74D), "kind", "danger", "enabled", k > 0, "action", () => CableSortDelete(st, picked)))
    CableSortPopup(st, e, st["gui"].Hwnd)
}

CableSortPlaceAction(st, picked, i) {
    return () => CableSortPlace(st, picked, i)
}

; 菜单第一项：对调起终点（最常用，突出显示）
CableSortFlipEntry(st, picked) {
    k := picked.Length
    return Map("kind", "primary", "icon", Chr(0xE8AB), "enabled", k > 0, "hint", k ? "Ctrl+R" : "先选中电缆"
        , "text", k ? "对调起终点（" . k . " 根）" : "对调起终点", "action", () => CableSortSwapKeep(st, picked))
}

; Ctrl+R：对焦点所在列表（未分类、气泡或放大窗口）里选中的电缆对调起终点
CableSortFlipKey() {
    global CableSortUi
    st := CableSortUi
    if !IsObject(st)
        return
    try fc := ControlGetFocus("A")
    catch
        fc := 0
    picked := ""
    if (fc && fc = st["ctl"]["mid"].Hwnd)
        picked := CableSortMidPicked(st)
    for i, sl in st["slots"]
        if (fc && i <= st["bubbles"].Length && fc = sl["lv"].Hwnd)
            picked := CableSortViewPicked(sl)
    for id, z in st["zooms"]
        if (fc && fc = z["lv"].Hwnd)
            picked := CableSortViewPicked(z)
    if !IsObject(picked) {
        TrayTip("先点一下列表，选中要对调的电缆再按 Ctrl+R。", "电缆排序", "Iconi Mute")
        return
    }
    CableSortSwapKeep(st, picked)
}

; ---------- 卡片式右键菜单（桌宠风格：白底、浅灰描边、左侧线性图标、悬停浅灰底图标变蓝） ----------
; entries：Map 数组。kind：primary（置顶突出的常用项）/ item（默认）/ danger（红色）/ sep（分隔线）/ header（小标题）；
; text、icon（Segoe MDL2 字形）、enabled（默认 true）、action（无参函数）、hint（primary 右侧的灰色提示）。
; 不抢焦点（WS_EX_NOACTIVATE），在菜单外按下鼠标、按 Esc 或切到别的程序即关闭
CableSortPopup(st, entries, ownerHwnd) {
    CableSortPopupClose(st)
    colors := ModernPanelColors()
    ui := ModernPanelCreate("电缆排序菜单", "-Caption +ToolWindow +AlwaysOnTop +E0x08000000 +Owner" . ownerHwnd, true)
    g := ui["gui"]
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 34, "UInt*", ModernPanelColorRef(colors["tileBorder"]), "UInt", 4)
    w := 272, pad := 6, y := pad
    for en in entries {
        kind := en.Has("kind") ? en["kind"] : "item"
        if (kind = "sep") {
            sep := ModernPanelStyle(colors["separator"], colors["text"])
            sep["radius"] := 0
            ModernPanelLabelAt(ui, 12, y + 4, w - 24, 1, "", sep)
            y += 9
            continue
        }
        if (kind = "header") {
            ModernPanelLabelAt(ui, 16, y + 2, w - 32, 22, en["text"], ModernPanelTextStyle(colors["secondary"], 9))
            y += 24
            continue
        }
        enabled := !en.Has("enabled") || en["enabled"]
        primary := kind = "primary"
        h := primary ? 38 : 30
        textColor := !enabled ? colors["disabled"] : kind = "danger" ? colors["error"] : colors["text"]
        iconColor := !enabled ? colors["iconDisabled"] : kind = "danger" ? colors["error"] : primary ? colors["iconHover"] : colors["icon"]
        icon := en.Has("icon") ? en["icon"] : ""
        style := CableSortPopupStyle(primary ? "F3F7FF" : "", textColor, primary, primary ? "D6E4FD" : "", icon, iconColor)
        hover := enabled ? CableSortPopupStyle(primary ? "E6EFFE" : colors["tileHover"], textColor, primary, primary ? "C7DAFC" : ""
            , icon, kind = "danger" ? colors["error"] : colors["iconHover"]) : ""
        if en.Has("indent") {                        ; 展开的子项：比上级图标再缩进一格
            style["padding"] := 48
            if IsObject(hover)
                hover["padding"] := 48
        }
        ModernPanelAddElement(ui, pad, y, w - pad * 2, h, en["text"], style, hover
            , enabled ? (en.Has("stay") ? CableSortPopupReopen(st, en["action"]) : CableSortPopupClick(st, en["action"])) : "")
        if en.Has("hint")
            ModernPanelLabelAt(ui, w - pad - 92, y, 82, h, en["hint"], ModernPanelTextStyle(enabled ? colors["secondary"] : colors["disabled"], 9, false, "right"))
        y += h + (primary ? 4 : 0)
    }
    hTotal := y + pad
    scale := A_ScreenDPI / 96
    if (st.Has("popupAt") && IsObject(st["popupAt"])) {
        x := st["popupAt"][1], yy := st["popupAt"][2]
    } else if (st.Has("popupReopenAt") && IsObject(st["popupReopenAt"])) {
        x := st["popupReopenAt"][1], yy := st["popupReopenAt"][2]   ; 展开 / 收起：左上角不动，放不下再往上挪
        st["popupReopenAt"] := ""
        wa := CableSortWorkArea(ownerHwnd)
        if (yy + hTotal * scale > wa[4])
            yy := Max(wa[2], wa[4] - Round(hTotal * scale) - 4)
    } else {
        CoordMode("Mouse", "Screen")
        MouseGetPos(&x, &yy)
        wa := CableSortWorkArea(ownerHwnd)
        x := Max(wa[1], Min(x + 2, wa[3] - Round(w * scale) - 4)), yy := yy + 2
        if (yy + hTotal * scale > wa[4])
            yy := Max(wa[2], yy - Round(hTotal * scale) - 4)
    }
    st["popup"] := ui
    g.Show("NA x" . x . " y" . yy . " w" . w . " h" . hTotal)
    st["popupDown"] := CableSortMouseDown()
    st["popupTimer"] := () => CableSortPopupWatch(st)
    SetTimer(st["popupTimer"], 60)
    return ui
}

; 菜单项样式：左对齐、6px 圆角、左右留白 10
CableSortPopupStyle(fill, textColor, bold, border, icon, iconColor) {
    style := ModernPanelDecorate(ModernPanelStyle(fill, textColor, bold, "left"), border, icon, iconColor)
    style["radius"] := 6
    style["padding"] := 10
    return style
}

; 点了不关菜单：在原位置按新的展开状态重开
CableSortPopupReopen(st, action) {
    return () => (st["popupReopenAt"] := CableSortPopupPos(st), action())
}

CableSortPopupPos(st) {
    if !(st.Has("popup") && IsObject(st["popup"]))
        return ""
    WinGetPos(&x, &y, , , "ahk_id " . st["popup"]["gui"].Hwnd)
    return [x, y]
}

CableSortPopupClick(st, action) {
    return () => (CableSortPopupClose(st), action())
}

CableSortMouseDown() {
    return GetKeyState("LButton", "P") || GetKeyState("RButton", "P") || GetKeyState("MButton", "P")
}

; 菜单外新按下鼠标、按 Esc、切到别的程序时关闭菜单
CableSortPopupWatch(st) {
    ui := st.Has("popup") ? st["popup"] : ""
    if !IsObject(ui)
        return CableSortPopupClose(st)
    down := CableSortMouseDown()
    pressed := down && !st["popupDown"]
    st["popupDown"] := down
    if GetKeyState("Escape", "P")
        return CableSortPopupClose(st)
    if pressed {
        CoordMode("Mouse", "Screen")
        MouseGetPos(, , &win)
        if (win != ui["gui"].Hwnd)
            return CableSortPopupClose(st)
    }
    owner := DllCall("GetWindow", "Ptr", ui["gui"].Hwnd, "UInt", 4, "Ptr")   ; GW_OWNER
    active := WinExist("A")
    if (active && active != owner && active != ui["gui"].Hwnd && active != st["gui"].Hwnd)
        CableSortPopupClose(st)
}

CableSortPopupClose(st) {
    if (st.Has("popupTimer") && IsObject(st["popupTimer"])) {
        SetTimer(st["popupTimer"], 0)
        st["popupTimer"] := ""
    }
    ui := st.Has("popup") ? st["popup"] : ""
    st["popup"] := ""
    if !IsObject(ui)
        return
    hwnd := ui["gui"].Hwnd
    ModernPanelReleaseCanvas(ui)
    ModernPanelRegistry().Delete(hwnd)
    try ui["gui"].Destroy()
}

CableSortRenameBubble(st, i) {
    name := CableSortAskName(st, "气泡改名", st["bubbles"][i]["name"])
    if (name = "")
        return
    CableSortPushUndo(st, "气泡改名")
    st["bubbles"][i]["name"] := name
    CableSortFillBubble(st, i)
    CableSortFillMid(st)
}

CableSortShiftBubble(st, i, d) {
    j := i + d, list := st["bubbles"]
    if (j < 1 || j > list.Length)
        return
    CableSortPushUndo(st, "移动气泡")
    t := list[i], list[i] := list[j], list[j] := t
    CableSortRefreshBubbles(st)
}

CableSortDeleteBubble(st, i) {
    b := st["bubbles"][i]
    if (b["items"].Length && MsgBox("删除气泡「" . b["name"] . "」？里面的 " . b["items"].Length . " 项电缆回到未分类。"
        , "电缆排序", "YesNo Icon? Owner" . st["gui"].Hwnd) != "Yes")
        return
    CableSortPushUndo(st, "删除气泡「" . b["name"] . "」")
    for cable in b["items"]
        cable["bubble"] := 0
    st["bubbles"].RemoveAt(i)
    CableSortRefreshBubbles(st)
    CableSortFillMid(st)
}

CableSortReclassAll(st) {
    if (MsgBox("按当前规则重新分类？所有手动拖动、排序和对调起终点都会清掉，新增的气泡保留但清空。", "电缆排序"
        , "YesNo Icon? Owner" . st["gui"].Hwnd) != "Yes")
        return
    CableSortPushUndo(st, "全部按规则重新分类")
    CableSortResolveAll(st["cables"], st["rules"], false)
    extra := []
    for b in st["bubbles"]
        if !b["box"]
            extra.Push(b)
    fresh := CableSortInitialBubbles(st["job"], st["cables"])
    ; 分类框气泡保留原名称和编号（改过的名称不丢）；已删除的分类框气泡不再恢复
    keep := []
    for f in fresh {
        found := ""
        for b in st["bubbles"]
            if (b["box"] = f["box"])
                found := b
        if IsObject(found) {
            f["name"] := found["name"], f["id"] := found["id"]
            for cable in f["items"]
                cable["bubble"] := f["id"]
            keep.Push(f)
        } else {
            for cable in f["items"]
                cable["bubble"] := 0
        }
    }
    for b in extra
        b["items"] := [], b["manual"] := false, keep.Push(b)
    st["bubbles"] := keep
    CableSortRefreshBubbles(st)
    CableSortFillMid(st, false)
}

; 删除：从气泡或未分类里拿掉，不再显示、不导出；可在“已删除”里恢复到未分类
CableSortDelete(st, cables) {
    if !cables.Length {
        MsgBox("请先勾选或选中要删除的电缆。", "电缆排序", "Iconi Owner" . st["gui"].Hwnd)
        return
    }
    CableSortPushUndo(st, "删除 " . cables.Length . " 项")
    CableSortPlace(st, cables, 0, -1, false)
    for cable in cables
        cable["bubble"] := -1
    CableSortFillMid(st, false)
    st["ctl"]["status"].Value := "已删除 " . cables.Length . " 项（不导出）；点“已删除”可恢复。"
}

; 已删除列表：多选后恢复到未分类
CableSortTrashWindow(st) {
    owner := st["gui"]
    dlg := Gui("+Owner" . owner.Hwnd . " +Resize -MinimizeBox", "已删除的电缆")
    dlg.BackColor := "FFFFFF"
    dlg.SetFont("s10 c1F2329", "Microsoft YaHei UI")
    dlg.AddText("x16 y12 w620", "这些电缆不显示、不导出。选中后点“恢复”，会回到未分类电缆列表。")
    lv := dlg.AddListView("x16 y40 w620 h360 NoSortHdr", ["编号", "起点（保留端）", "终点", "规格"])
    CableSortStyleLv(lv, 28)
    lv.OnNotify(-12, (l, lp) => CableSortCustomDraw([], lp, -1, 0, "", true))
    rows := []
    Fill() {
        rows.Length := 0
        lv.Delete()
        for cable in st["cables"]
            if (cable["bubble"] = -1) {
                row := CableSortKeepRow(cable)
                lv.Add(, cable["id"], CableSortDisplay(CableSortStartCell(cable)), CableSortDisplay(CableSortEndCell(cable)), CableSortCell(row, 4))
                rows.Push(cable)
            }
        lv.ModifyCol(1, 110), lv.ModifyCol(2, 200), lv.ModifyCol(3, 200), lv.ModifyCol(4, "AutoHdr")
    }
    Restore(all) {
        picked := []
        if all {
            picked := rows.Clone()
        } else {
            r := 0
            while (r := lv.GetNext(r))
                picked.Push(rows[r])
        }
        if !picked.Length
            return
        CableSortPushUndo(st, "恢复 " . picked.Length . " 项")
        for cable in picked
            cable["bubble"] := 0
        Fill()
        CableSortFillMid(st, false)
        st["ctl"]["status"].Value := "已恢复 " . picked.Length . " 项到未分类。"
    }
    btn := CableSortButton(dlg, "x16 y410 w110 h32", "恢复所选", "primary")
    btn.OnEvent("Click", (*) => Restore(false))
    CableSortButton(dlg, "x+8 w110 h32", "全部恢复").OnEvent("Click", (*) => Restore(true))
    CableSortButton(dlg, "x+8 w90 h32", "关闭").OnEvent("Click", (*) => dlg.Destroy())
    dlg.OnEvent("Escape", (*) => dlg.Destroy())
    Fill()
    dlg.Show("w652 h452")
}

; ---------- 撤销 / 重做 ----------

; 快照：规则、气泡（名称、顺序、条目）、每个条目的所在气泡和保留端
CableSortSnapshot(st, label) {
    rules := []
    for r in st["rules"]
        rules.Push(r.Clone())
    bubbles := []
    for b in st["bubbles"] {
        keys := []
        for cable in b["items"]
            keys.Push(cable["key"])
        bubbles.Push(Map("id", b["id"], "name", b["name"], "box", b["box"], "keys", keys, "manual", b.Has("manual") && b["manual"]))
    }
    cables := []
    for cable in st["cables"]
        cables.Push([cable["bubble"], cable["keep"], cable["manualKeep"], cable.Has("flip") && cable["flip"]])
    return Map("label", label, "rules", rules, "bubbles", bubbles, "cables", cables, "nextId", st["nextId"])
}

CableSortRestore(st, snap) {
    st["rules"] := []
    for r in snap["rules"]
        st["rules"].Push(r.Clone())
    for i, cable in st["cables"] {
        v := snap["cables"][i]
        cable["bubble"] := v[1], cable["keep"] := v[2], cable["manualKeep"] := v[3], cable["flip"] := v[4]
    }
    st["bubbles"] := []
    for b in snap["bubbles"] {
        items := []
        for key in b["keys"]
            items.Push(st["byKey"][key])
        st["bubbles"].Push(Map("id", b["id"], "name", b["name"], "box", b["box"], "items", items, "manual", b["manual"]))
    }
    st["nextId"] := snap["nextId"]
    CableSortResolveAll(st["cables"], st["rules"], true)
    CableSortFillRules(st)
    CableSortRefreshBubbles(st)
    CableSortFillMid(st, false)
}

; 修改前调用：记下当前状态（snap 为事先拍好的快照），清空重做
CableSortPushUndo(st, label, snap := "") {
    st["undo"].Push(IsObject(snap) ? snap : CableSortSnapshot(st, label))
    if (st["undo"].Length > 100)
        st["undo"].RemoveAt(1)
    st["redo"] := []
    CableSortUpdateUndoButtons(st)
    CableSortScheduleSave(st)   ; 定时器在本次改动完成后才触发
}

CableSortUndo(st, which) {
    from := which = "undo" ? st["undo"] : st["redo"]
    to := which = "undo" ? st["redo"] : st["undo"]
    if !from.Length {
        st["ctl"]["status"].Value := which = "undo" ? "没有可撤销的操作。" : "没有可重做的操作。"
        return
    }
    snap := from.Pop()
    to.Push(CableSortSnapshot(st, snap["label"]))
    CableSortRestore(st, snap)
    CableSortUpdateUndoButtons(st)
    CableSortScheduleSave(st)
    st["ctl"]["status"].Value := (which = "undo" ? "已撤销：" : "已重做：") . snap["label"]
    CableSortShowDetail(st)
}

CableSortUpdateUndoButtons(st) {
    c := st["ctl"]
    c["undoBtn"].Text := "↶ 撤销" . (st["undo"].Length ? "（" . st["undo"].Length . "）" : "")
    c["undoBtn"].Enabled := st["undo"].Length > 0
    c["redoBtn"].Enabled := st["redo"].Length > 0
    c["undoBtn"].Redraw(), c["redoBtn"].Redraw()      ; 自绘按钮改字后要重画
}

CableSortUndoKey(which) {
    global CableSortUi
    try cls := WinGetClass("ahk_id " . ControlGetFocus("A"))
    catch
        cls := ""
    if (cls = "Edit") {                              ; 输入框里按 Ctrl+Z/Y 照常撤销输入
        Send(which = "undo" ? "^z" : "^y")
        return
    }
    if IsObject(CableSortUi)
        CableSortUndo(CableSortUi, which)
}

; 对调起终点（可多选，所在气泡不变）：配对的电缆换成保留另一行，只有一行的电缆导出时对调起点、终点两列；其他行跳过
CableSortSwapKeep(st, cables) {
    n := 0
    for cable in cables
        n += cable["kind"] != "fixed"
    if !n {
        TrayTip(cables.Length ? "所选的是其他行（不是电缆），没有起终点可对调。" : "请先勾选或选中要对调的电缆。", "电缆排序", "Iconi Mute")
        return
    }
    CableSortPushUndo(st, "对调起终点 " . n . " 根")
    keys := Map()
    for cable in cables
        if CableSortFlip(cable, st["rules"])
            keys[cable["key"]] := true
    ; 刷新后保持选中，方便接着检查或再对调
    CableSortRefreshBubbles(st)
    for i, b in st["bubbles"] {
        sel := []
        for k, cable in b["items"]
            if keys.Has(cable["key"])
                sel.Push(k)
        if sel.Length
            CableSortFillBubble(st, i, sel)
    }
    CableSortFillMid(st)
    for r, cable in st["midRows"]
        if keys.Has(cable["key"])
            st["ctl"]["mid"].Modify(r, "Select")
    st["ctl"]["status"].Value := "已对调起终点 " . keys.Count . " 根（Ctrl+Z 撤销）"
    CableSortShowDetail(st)
}

; ---------- 规则 ----------

CableSortLoadRuleEditor(st, row) {
    if (row < 1 || row > st["rules"].Length)
        return
    r := st["rules"][row], c := st["ctl"]
    c["prefix"].Value := r["prefix"]
    c["range"].Value := r["range"]
    c["cab"].Text := r["cabinet"]
}

CableSortLoadCableEditor(st, cable) {
    c := st["ctl"]
    CableSortShowDetail(st, cable)
    if (cable["kind"] = "fixed")
        return
    if IsObject(cable["parsed"])
        c["prefix"].Value := cable["parsed"]["prefix"]
    c["range"].Value := ""
    cands := CableSortCandidates(st["cables"], cable)
    c["cab"].Delete()
    if cands.Length
        c["cab"].Add(cands)
    c["cab"].Text := cable["rule"] ? st["rules"][cable["rule"]]["cabinet"] : (cands.Length ? cands[1] : "")
}

; 底部详情栏：选中电缆的起点 → 终点（气泡里显示不下时看这里）
CableSortShowDetail(st, cable := "") {
    if !IsObject(cable)
        cable := st.Has("detailCable") ? st["detailCable"] : ""
    if !IsObject(cable)
        return
    st["detailCable"] := cable
    row := CableSortKeepRow(cable)
    if (cable["kind"] = "fixed") {
        text := ""
        for cell in row["cells"]
            text .= (text = "" ? "" : "  ") . cell
        CableSortSetDetail(st, "  其他行：" . text, false)
        return
    }
    ; 编号 + 起点 → 终点，起终点深绿粗体加浅绿底，一眼能看到（2026-11-10 只要起终点；2026-11-11 用户要求加回编号，规格、芯数仍不要）
    s := CableSortDisplay(CableSortStartCell(cable)), e := CableSortDisplay(CableSortEndCell(cable))
    CableSortSetDetail(st, "  " . cable["id"] . "　　起点　" . s . "　　→　　终点　" . e, true
        , [[cable["id"], "1F2329", true], ["    ·    ", "C4C8CF"], ["起点  ", "6B7280"], [s, "166534", true], ["    →    ", "9CA3AF"], ["终点  ", "6B7280"], [e, "166534", true]])
}

; strong：电缆起终点（浅绿底、深绿粗体 #166534）；否则为提示或搜索汇总（浅灰底、灰字）。
; 底栏胶囊是 GDI+ 画的位图，st["detailText"] 留一份纯文字（测试和排查用）
CableSortSetDetail(st, text, strong, runs := "") {
    st["detailStrong"] := strong, st["detailText"] := text
    st["detailRuns"] := IsObject(runs) ? runs : [[Trim(text), strong ? "166534" : "6B7280", strong]]
    CableSortDrawDetail(st)
}

CableSortLoadMidEditor(st, row) {
    if (row >= 1 && row <= st["midRows"].Length)
        CableSortLoadCableEditor(st, st["midRows"][row])
}

CableSortLoadBubbleEditor(st, i, row) {
    rows := st["slots"][i]["rows"]
    if (row >= 1 && row <= rows.Length)
        CableSortLoadCableEditor(st, rows[row])
}

CableSortRuleEdit(st, action) {
    snap := CableSortSnapshot(st, "修改规则")
    c := st["ctl"], rules := st["rules"]
    sel := c["rules"].GetNext(0)
    title := "电缆排序", owner := " Owner" . st["gui"].Hwnd
    if (action = "add" || action = "modify") {
        prefix := Trim(c["prefix"].Value), cab := Trim(c["cab"].Text)
        if (prefix = "" || cab = "") {
            MsgBox("请填写前缀和起点柜。", title, "Icon!" . owner)
            return
        }
        try rule := CableSortNewRule(prefix, c["range"].Value, cab, "本工程")
        catch as e {
            MsgBox(e.Message, title, "Icon!" . owner)
            return
        }
        if (action = "modify") {
            if !sel {
                MsgBox("请先在规则列表里选中要修改的一条。", title, "Icon!" . owner)
                return
            }
            rules[sel] := rule
        } else {
            ; 放在同前缀的最后一条规则之后，没有同前缀时放最后
            at := 0
            for i, r in rules
                if (CableSortNorm(r["prefix"]) = CableSortNorm(prefix))
                    at := i
            if at
                rules.InsertAt(at + 1, rule), sel := at + 1
            else
                rules.Push(rule), sel := rules.Length
        }
    } else {
        if !sel
            return
        if (action = "delete") {
            rules.RemoveAt(sel)
            sel := Min(sel, rules.Length)
        } else if (action = "up" && sel > 1) {
            r := rules.RemoveAt(sel), rules.InsertAt(sel - 1, r), sel--
        } else if (action = "down" && sel < rules.Length) {
            r := rules.RemoveAt(sel), rules.InsertAt(sel + 1, r), sel++
        } else {
            return
        }
    }
    CableSortPushUndo(st, "", snap)
    ; 规则变了：重新定保留端和状态（手动换的保留端保留）；未分类里定下起点的电缆放进保留行所在框的气泡
    CableSortResolveAll(st["cables"], rules, true)
    placed := 0
    for cable in st["cables"] {
        if (cable["bubble"] || !(cable["status"] = "ok" || cable["status"] = "manual"))
            continue
        box := CableSortKeepRow(cable)["box"]
        for b in st["bubbles"]
            if (b["box"] = box) {
                CableSortInsertSorted(b["items"], cable)
                cable["bubble"] := b["id"]
                placed++
                break
            }
    }
    for b in st["bubbles"]                     ; 规则顺序可能变了：自动排序的气泡重新按编号排
        CableSortTidy(b)
    CableSortFillRules(st, sel)
    CableSortRefreshBubbles(st)
    CableSortFillMid(st)
    if placed
        st["ctl"]["status"].Value := "规则生效：" . placed . " 根电缆从未分类放进了对应的气泡。"
}

; 列表自绘 CableSortCustomDraw 在 cable-sort-look.ahk

; ---------- 导出 ----------

CableSortApply(st) {
    global CableSortResultPath
    if CableSortIsCsv(st)
        return CableSortSaveCsv(st)
    title := "电缆排序", owner := " Owner" . st["gui"].Hwnd
    job := st["job"]
    try text := CableSortBuildResult(job, st["bubbles"])
    catch as e {
        MsgBox("生成导出内容失败：`n" . e.Message, title, "Iconx" . owner)
        return
    }
    un := 0, red := 0
    for cable in st["cables"] {
        if (cable["bubble"] = 0)
            un++
        else if (cable["bubble"] > 0)
            red += CableSortRed(cable)
    }
    if (un || red) {
        msg := (un ? "还有 " . un . " 项未分类，不会导出。`n" : "") . (red ? "气泡里有 " . red . " 根没有按规则定下起点，将按当前保留端导出。`n" : "")
        if (MsgBox(msg . "继续导出？", title, "YesNo Icon!" . owner) != "Yes")
            return
    }
    ; 任务来自哪个 CAD 就发回哪个：AutoCAD 2018 的插件按系统 ANSI（GBK）读 result.txt
    isAcad := job.Has("cad") && job["cad"] = "ACAD"
    cadName := isAcad ? "AutoCAD" : "中望 CAD"
    try cadApp := ComObjActive(isAcad ? "AutoCAD.Application" : "ZWCAD.Application")
    catch {
        MsgBox("没有找到运行中的" . cadName . "。", title, "Icon!" . owner)
        return
    }
    try {
        doc := ""
        for d in cadApp.Documents
            if (StrLower(d.FullName) = StrLower(job["dwg"])) {
                doc := d
                break
            }
        if !IsObject(doc) {
            MsgBox("运行 YSDL3 的图纸没有打开：`n" . job["dwg"], title, "Icon!" . owner)
            return
        }
        if (doc.GetVariable("CMDACTIVE") != 0) {
            MsgBox(cadName . " 正在执行命令，请先按 Esc 结束命令再导出。", title, "Icon!" . owner)
            return
        }
        tmp := CableSortResultPath . ".tmp"
        f := FileOpen(tmp, "w", isAcad ? "CP936" : "UTF-8-RAW")
        f.Write(text)
        f.Close()
        FileMove(tmp, CableSortResultPath, 1)
    } catch as e {
        MsgBox("准备导出时出错：`n" . e.Message, title, "Iconx" . owner)
        return
    }
    st["dirty"] := true
    CableSortSaveProgress(st)
    ; 规则存进本工程规则文件（推断的也一起存下，下次直接用）
    saved := ""
    try {
        CableSortSaveRules(st["rulesPath"], st["rules"])
        for r in st["rules"]
            r["source"] := "本工程"
        CableSortFillRules(st)
        saved := "规则已保存到 " . st["rulesPath"]
    } catch as e {
        saved := "规则保存失败：" . e.Message
    }
    try {
        if (cadApp.ActiveDocument.FullName != doc.FullName)
            doc.Activate()
        doc.SendCommand('(aa:ysdl3-apply "' . job["id"] . '")`n')
        try WinActivate(isAcad ? "ahk_exe acad.exe" : "ahk_exe ZWCAD.exe")
    } catch as e {
        MsgBox("发送到" . cadName . "失败：`n" . e.Message . "`n`n如果插件没加载，请先在 CAD 里加载（或重载）AA 整合插件。", title, "Iconx" . owner)
        return
    }
    st["ctl"]["status"].Value := FormatTime(, "HH:mm:ss") . " 已发送到" . cadName . "，结果以 CAD 的提示为准；" . saved
        . "。成功后这次任务已用掉，要再导出请重新运行 YSDL3。"
}

; ---------- 导出预览 ----------
; 按当前气泡生成导出后的 CSV 内容，用表格显示（不写文件、不连 CAD）。列和插件写出的一致，“至”去掉、首尾空白修剪；
; 未分类、已删除的不在里面。窗口里可直接点“导出 CSV”（另存模式为“另存 CSV…”）。
CableSortPreview(st, showOptions := "") {
    if (st.Has("previewGui") && IsObject(st["previewGui"])) {
        try st["previewGui"].Destroy()
        st["previewGui"] := ""
    }
    job := st["job"], box := job["mode"] = "box"
    rows := CableSortExportRows(job, st["bubbles"], true)
    un := 0, deleted := 0
    for cable in st["cables"]
        un += cable["bubble"] = 0, deleted += cable["bubble"] = -1
    cols := 0
    for r in rows
        cols := Max(cols, r.Length)
    names := box ? ["分类", "序号", "起点", "电缆编号", "芯数", "型号", "起点", "终点"] : ["电缆编号", "芯数", "型号", "起点", "终点"]
    heads := []
    loop Max(cols, 1)
        heads.Push(A_Index <= names.Length ? names[A_Index] : "第 " . A_Index . " 列")

    g := Gui("+Owner" . st["gui"].Hwnd . " +Resize +MinSize640x400", "导出预览 · " . CableSortDwgName(st))
    st["previewGui"] := g
    g.BackColor := "FFFFFF"
    g.SetFont("s12 Bold c1F2329", "Microsoft YaHei UI")
    title := g.AddText("x16 y12 w600 h26", "导出预览")
    g.SetFont("s9 Norm c6B7280")
    sub := g.AddText("x16 y42 w900 h18 +0x4000", "共 " . rows.Length . " 行 · " . st["bubbles"].Length . " 个分类"
        . (un ? " · 未分类 " . un . " 项不导出" : "") . (deleted ? " · 已删除 " . deleted . " 项不导出" : "")
        . " · " . (CableSortIsCsv(st) ? "另存为新的 CSV（UTF-8 带 BOM）" : "由中望 CAD 追加写到桌面 CSV")
        . " · 没有表头，下面的列名只是说明")
    g.SetFont("s10 Norm c1F2329")
    lv := g.AddListView("x16 y70 w900 h500 NoSort NoSortHdr -E0x200 +0x4000000", heads)
    CableSortStyleLv(lv, 28)
    boldCol := box ? 3 : 0
    lv.OnNotify(-12, (l, lp) => CableSortCustomDraw([], lp, -1, boldCol, box ? [1, 2] : "", true))
    apply := CableSortButton(g, "x0 y0 w120 h34", CableSortIsCsv(st) ? "另存 CSV…" : "导出 CSV", "primary")
    close := CableSortButton(g, "x0 y0 w84 h34", "关闭")
    lv.Opt("-Redraw")
    for r in rows
        lv.Add(, r*)
    loop heads.Length
        lv.ModifyCol(A_Index, "AutoHdr")
    lv.Opt("+Redraw")
    apply.OnEvent("Click", (*) => (g.Destroy(), st["previewGui"] := "", CableSortApply(st)))
    close.OnEvent("Click", (*) => (g.Destroy(), st["previewGui"] := ""))
    g.OnEvent("Close", (*) => (st["previewGui"] := ""))
    g.OnEvent("Escape", (*) => (g.Destroy(), st["previewGui"] := ""))
    g.OnEvent("Size", (g2, mm, w, h) => mm != -1 && (
        title.Move(16, 12, w - 32), sub.Move(16, 42, w - 32),
        close.Move(w - 16 - 84, h - 12 - 34), apply.Move(w - 16 - 84 - 10 - 120, h - 12 - 34),
        lv.Move(16, 70, w - 32, h - 70 - 12 - 34 - 12),
        DllCall("RedrawWindow", "Ptr", g.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x85)))
    if (showOptions != "") {
        g.Show(showOptions)
    } else {
        wa := CableSortWorkArea(st["gui"].Hwnd)
        aw := wa[3] - wa[1], ah := wa[4] - wa[2]
        w := Min(aw, Max(900, Round(aw * 0.7))), h := Min(ah, Max(500, Round(ah * 0.8)))
        g.Show("w" . w . " h" . h)
        WinMove(wa[1] + (aw - w) // 2, wa[2] + (ah - h) // 2, , , "ahk_id " . g.Hwnd)
    }
    st["previewRows"] := rows                         ; 测试用
    return g
}

CableSortDwgName(st) {
    SplitPath(st["job"]["dwg"], &name)
    return name
}

; ---------- 放大窗口 ----------
; 每个气泡可单独放大成一个窗口：默认在屏幕中间，可全屏、可拖边框自己调大小；有自己的搜索框。
; 和主窗口共用同一份数据：上下拖动排序、拖到主窗口的气泡或未分类列表、右键菜单都照常可用，改动两边同步。

CableSortZoomIndex(st, z) {
    for i, b in st["bubbles"]
        if (b["id"] = z["id"])
            return i
    return 0
}

; showOptions 供冒烟测试把窗口放到屏幕外
CableSortZoom(st, i, showOptions := "") {
    b := st["bubbles"][i]
    q := (i <= st["slots"].Length) ? st["slots"][i]["query"] : ""   ; 继承气泡里的搜索词
    if st["zooms"].Has(b["id"]) {
        z := st["zooms"][b["id"]]
        if (WinGetMinMax("ahk_id " . z["gui"].Hwnd) = -1)
            WinRestore("ahk_id " . z["gui"].Hwnd)
        if (q != "" && q != z["query"])
            CableSortZoomSetQuery(st, z, q)
        WinActivate("ahk_id " . z["gui"].Hwnd)
        return z
    }
    z := Map("id", b["id"], "query", "", "rows", [], "colors", [])
    g := Gui("+Owner" . st["gui"].Hwnd . " +Resize +MinSize560x360", "放大 · " . b["name"])
    z["gui"] := g
    g.BackColor := "FFFFFF"
    g.SetFont("s12 Bold c1F2329", "Microsoft YaHei UI")
    z["title"] := g.AddText("x16 y12 w400 h26", "")
    g.SetFont("s9 Norm c9CA3AF")
    z["sub"] := g.AddText("x16 y42 w600 h18 +0x4000", "")
    g.SetFont("s10 Norm c1F2329")
    z["full"] := CableSortButton(g, "x600 y10 w72 h32", "全屏")
    z["center"] := CableSortButton(g, "x+6 w72 h32", "居中")
    z["close"] := CableSortButton(g, "x+6 w72 h32", "关闭")
    g.SetFont("s9 c9CA3AF")
    z["sclear"] := g.AddText("x0 y0 w18 h18 Center Hidden BackgroundWhite +0x100", "✕")
    g.SetFont("s10 c1F2329")
    z["search"] := g.AddEdit("x16 y66 w400 h20 -E0x200 +0x4000000")
    DllCall("SendMessage", "Ptr", z["search"].Hwnd, "UInt", 0x1501, "Ptr", 1, "WStr", "搜索编号、柜名或规格，空格分隔多个词…")
    z["frame"] := CableSortFrameEdit(g, z["search"], Chr(0xE721))
    z["lv"] := g.AddListView("x16 y100 w800 h500 NoSort NoSortHdr -E0x200 +0x4000000", ["序", "编号", "起点（保留端）", "终点", "规格"])
    CableSortStyleLv(z["lv"], 28)
    z["search"].OnEvent("Change", (*) => z["search"].Value != z["query"] && CableSortZoomSearch(st, z, false))
    z["sclear"].OnEvent("Click", (*) => CableSortZoomSearch(st, z, true))
    z["full"].OnEvent("Click", (*) => CableSortZoomPlace(st, z, "full"))
    z["center"].OnEvent("Click", (*) => CableSortZoomPlace(st, z, "center"))
    z["close"].OnEvent("Click", (*) => CableSortZoomClose(st, z))
    z["title"].OnEvent("DoubleClick", (*) => (zi := CableSortZoomIndex(st, z)) && CableSortRenameBubble(st, zi))
    g.OnEvent("Close", (*) => CableSortZoomClose(st, z))
    g.OnEvent("Escape", (*) => CableSortZoomClose(st, z))
    g.OnEvent("Size", (g2, mm, w, h) => CableSortZoomLayout(z, mm, w, h))
    g.OnEvent("ContextMenu", (g2, ctrl, *) => CableSortZoomContext(st, z, ctrl))
    z["lv"].OnNotify(-12, (lv, lp) => CableSortCustomDraw(z["colors"], lp, -1, 1, [0, 4], true))
    z["lv"].OnNotify(-109, (lv, lp) => CableSortBeginDrag(st, lv, z))
    z["lv"].OnNotify(-155, (lv, lp) => CableSortZoomKeyDown(st, z, lp))
    z["lv"].OnEvent("ItemFocus", (lv, row) => CableSortZoomFocus(st, z, row))
    st["zooms"][b["id"]] := z
    CableSortFillZoom(st, z)
    if (showOptions != "")
        g.Show(showOptions)
    else
        CableSortZoomPlace(st, z, "center")
    if (q != "")
        CableSortZoomSetQuery(st, z, q)
    z["search"].Focus()
    return z
}

CableSortZoomSetQuery(st, z, q) {
    z["search"].Value := q
    CableSortZoomSearch(st, z, false)
    SendMessage(0xB1, StrLen(q), StrLen(q), z["search"])   ; EM_SETSEL 光标放到末尾
}

CableSortZoomContext(st, z, ctrl) {
    if !IsObject(ctrl)
        return
    i := CableSortZoomIndex(st, z)
    if !i
        return
    if (ctrl.Hwnd = z["lv"].Hwnd)
        CableSortBubbleMenu(st, i, z)
    else if (ctrl.Hwnd = z["title"].Hwnd || ctrl.Hwnd = z["sub"].Hwnd)
        CableSortBubbleTitleMenu(st, i, z)
}

CableSortZoomKeyDown(st, z, lParam) {
    if (NumGet(lParam, 24, "UShort") = 0x2E)         ; Delete：移出分类
        CableSortPlace(st, CableSortViewPicked(z), 0)
}

CableSortZoomFocus(st, z, row) {
    if (row >= 1 && row <= z["rows"].Length)
        CableSortLoadCableEditor(st, z["rows"][row])
}

; 主窗口所在显示器的工作区 [左, 上, 右, 下]
CableSortWorkArea(hwnd) {
    mon := DllCall("MonitorFromWindow", "Ptr", hwnd, "UInt", 2, "Ptr")
    mi := Buffer(40, 0)
    NumPut("UInt", 40, mi, 0)
    DllCall("GetMonitorInfoW", "Ptr", mon, "Ptr", mi)
    return [NumGet(mi, 20, "Int"), NumGet(mi, 24, "Int"), NumGet(mi, 28, "Int"), NumGet(mi, 32, "Int")]
}

; full：最大化（全屏）；center：还原成屏幕中间约 60%×80% 的大小。之后都可以拖边框自己调
CableSortZoomPlace(st, z, mode) {
    g := z["gui"]
    if (mode = "full") {
        g.Show("Maximize")
        return
    }
    wa := CableSortWorkArea(st["gui"].Hwnd)
    aw := wa[3] - wa[1], ah := wa[4] - wa[2]
    w := Min(aw, Max(640, Round(aw * 0.6))), h := Min(ah, Max(420, Round(ah * 0.8)))
    g.Show("Restore")
    WinMove(wa[1] + (aw - w) // 2, wa[2] + (ah - h) // 2, w, h, "ahk_id " . g.Hwnd)
}

CableSortZoomLayout(z, mm, w, h) {
    if (mm = -1)
        return
    z["close"].GetPos(, , &bw)
    bx := w - 16 - bw
    z["close"].Move(bx, 10), z["center"].Move(bx - 6 - bw, 10), z["full"].Move(bx - 12 - 2 * bw, 10)
    z["title"].Move(16, 12, Max(80, bx - 12 - 2 * bw - 28))
    z["sub"].Move(16, 42, w - 32)
    sw := Min(480, w - 32), sh := 34
    CableSortPlaceFramed(z["frame"], z["search"], 16, 66, sw, sh, 32)
    z["sclear"].Move(16 + sw - 28, 66 + (sh - 18) // 2)
    top := 66 + sh + 10
    z["lv"].Move(16, top, w - 32, Max(60, h - top - 12))
    rest := Max(160, w - 32 - 4 - SysGet(2) - 50 - 130 - 110)
    z["lv"].ModifyCol(1, "50 Integer"), z["lv"].ModifyCol(2, 130), z["lv"].ModifyCol(3, rest // 2)
    z["lv"].ModifyCol(4, rest - rest // 2), z["lv"].ModifyCol(5, 110)
    DllCall("RedrawWindow", "Ptr", z["gui"].Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x85)   ; 挪位后整窗重画，免得首次显示留残影
}

CableSortZoomSearch(st, z, clear) {
    if clear
        z["search"].Value := ""
    z["query"] := z["search"].Value
    z["sclear"].Visible := z["query"] != ""
    CableSortFillZoom(st, z)
    if clear
        z["search"].Focus()
}

CableSortFillZoom(st, z, select := "") {
    i := CableSortZoomIndex(st, z)
    if !i {
        CableSortZoomClose(st, z)
        return
    }
    b := st["bubbles"][i]
    z["gui"].Title := "放大 · " . b["name"]
    z["title"].Value := b["name"]
    rows := CableSortFilterRows(b["items"], z["query"])
    z["sub"].Value := CableSortBubbleSub(b, rows, z["query"]) . "｜上下拖动排序，可拖到主窗口的其他气泡或未分类列表，右键有更多操作"
    CableSortFillItemsLv(z, b, rows, true, "FFFFFF", select)
}

CableSortZoomClose(st, z) {
    if st["zooms"].Has(z["id"]) && st["zooms"][z["id"]] = z
        st["zooms"].Delete(z["id"])
    try z["gui"].Destroy()
}
