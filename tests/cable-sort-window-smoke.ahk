#Requires AutoHotkey v2.0
#Warn All, StdOut  ; 警告写到标准输出，不弹窗
; 电缆排序窗口冒烟测试：窗口放在屏幕外，读 job.txt，模拟勾选放进气泡、气泡内排序、跨气泡、新增气泡、加规则、换保留端，并把窗口截图存成 PNG。
; 不连接 CAD、不点“应用”。用法：AutoHotkey64.exe /ErrorStdOut tests\cable-sort-window-smoke.ahk <job.txt> <输出PNG>
#Include ..\src\cable-sort.ahk

; 主面板里才有的函数，modern-panel-ui.ahk 引用到；测试里放个空的
RunPanelCommand(callback) => callback()

failures := 0
Check(cond, what) {
    global failures
    if !cond {
        failures++
        FileAppend("FAIL: " . what . "`n", "*", "UTF-8")
    }
}

try {
    RunWindowSmoke()
} catch as smokeErr {
    failures++
    FileAppend("FAIL: 运行出错 " . smokeErr.Message . "（" . smokeErr.What . " 第 " . smokeErr.Line . " 行）`n", "*", "UTF-8")
}
CableSortClose()
FileAppend(failures ? "FAIL (" . failures . ")`n" : "PASS cable-sort-window`n", "*", "UTF-8")
ExitApp(failures ? 1 : 0)

RunWindowSmoke() {
    global CableSortUi
    SetTimer(CableSortPoll, 0)   ; 测试期间不轮询，免得真实任务把窗口换掉
    job := CableSortParseJob(FileRead(A_Args[1], "UTF-8"))
    progress := A_Temp . "\cable-sort-window-smoke-progress.txt"
    try FileDelete(progress)
    CableSortOpen(job, "x-4000 y0 w1500 h880 NoActivate", "no", progress)   ; 不询问恢复，进度写临时目录
    st := CableSortUi
    st["rulesPath"] := A_Temp . "\cable-sort-window-smoke-rules.txt"   ; 规则文件放临时目录，不碰工程目录
    c := st["ctl"]
    Check(c["rules"].GetCount() = st["rules"].Length, "规则列表行数")
    un := 0
    for cable in st["cables"]
        un += !cable["bubble"]
    Check(c["mid"].GetCount() = un, "中间列表只放未分类：" . c["mid"].GetCount() . " / " . un)
    Check(st["bubbles"].Length = job["boxes"].Length, "初始气泡 = 分类框")
    Check(st["slots"][1]["lv"].GetCount() = st["bubbles"][1]["items"].Length, "气泡 1 行数")

    Check(un > 0, "有未分类的电缆")
    ; 勾选前两项，拖进气泡 1（自动排序的气泡：放进去后整体按编号排，不看松开位置）
    c["mid"].Modify(1, "Check"), c["mid"].Modify(2, "Check")
    picked := CableSortMidPicked(st)
    Check(picked.Length = 2, "勾选两项")
    CableSortPlace(st, picked, 1, 0)
    Check(picked[1]["bubble"] = st["bubbles"][1]["id"] && picked[2]["bubble"] = st["bubbles"][1]["id"], "放进气泡")
    Check(SameOrder(st["bubbles"][1]["items"], CableSortSortList(st["bubbles"][1]["items"])) && !st["bubbles"][1]["manual"], "放进后仍按编号排序")
    afterPlace := st["bubbles"][1]["items"].Clone()
    Check(c["mid"].GetCount() = un - 2, "未分类少两项")
    ; 撤销 / 重做
    CableSortUndo(st, "undo")
    Check(picked[1]["bubble"] = 0 && c["mid"].GetCount() = un, "撤销放进气泡")
    CableSortUndo(st, "redo")
    Check(SameOrder(st["bubbles"][1]["items"], afterPlace) && c["mid"].GetCount() = un - 2, "重做")
    ; 自动保存：等定时器写出进度文件
    Sleep(1200)
    Check(FileExist(progress) && InStr(FileRead(progress, "UTF-8"), "ITEM`t" . st["bubbles"][1]["id"] . "`t" . picked[1]["key"]), "改动后自动保存进度")
    ; 在气泡 1 里把第 1 项拖到第 3 位之后
    first := st["bubbles"][1]["items"][1]
    st["slots"][1]["lv"].Modify(0, "-Select"), st["slots"][1]["lv"].Modify(1, "Select")
    CableSortPlace(st, CableSortBubblePicked(st, 1), 1, 3)
    Check(ObjPtr(st["bubbles"][1]["items"][3]) = ObjPtr(first) && st["bubbles"][1]["manual"], "气泡内拖动排序（之后保留手动顺序）")
    CableSortFillBubble(st, 1)
    Check(InStr(st["slots"][1]["sub"].Value, "已手动调整顺序"), "副标题显示手动：" . st["slots"][1]["sub"].Value)
    ; 拖到气泡 2
    CableSortPlace(st, [first], 2)
    Check(first["bubble"] = st["bubbles"][2]["id"] && SameOrder(st["bubbles"][2]["items"], CableSortSortList(st["bubbles"][2]["items"])), "跨气泡拖动后按编号排序")
    ; 新增气泡并放入一项，再移出
    st["bubbles"].Push(Map("id", st["nextId"]++, "name", "测试分类", "box", 0, "items", []))
    CableSortRefreshBubbles(st)
    CableSortPlace(st, [first], st["bubbles"].Length)
    Check(st["slots"][st["bubbles"].Length]["lv"].GetCount() = 1, "新气泡显示")
    text := CableSortBuildResult(st["job"], st["bubbles"])
    Check(InStr(text, "CAT`t测试分类`t"), "新气泡导出")
    CableSortPlace(st, [first], 0)
    Check(first["bubble"] = 0, "移出分类")
    Check(c["mid"].GetCount() = un - 1, "移出后回到中间列表")

    ; 删除与恢复：删掉的不在中间列表、不在气泡、不导出
    gone := st["bubbles"][1]["items"][1]
    CableSortDelete(st, [first, gone])
    Check(first["bubble"] = -1 && gone["bubble"] = -1, "删除标记")
    Check(c["mid"].GetCount() = un - 2, "删除后不在未分类列表")
    text := CableSortBuildResult(st["job"], st["bubbles"])
    gr := CableSortKeepRow(gone)
    Check(!InStr(text, "`t" . (gr["box"] - 1) . ":" . gr["idx"] . "`t") && !RegExMatch(text, "`t" . (gr["box"] - 1) . ":" . gr["idx"] . "`r"), "删除的不导出")
    Check(InStr(c["trash"].Text, "（2）"), "已删除计数：" . c["trash"].Text)
    first["bubble"] := 0, gone["bubble"] := 0          ; 模拟“全部恢复”
    CableSortFillMid(st, false)
    Check(c["mid"].GetCount() = un, "恢复回到未分类")
    fresh := CableSortInitialBubbles(st["job"], [first])
    first["bubble"] := -1
    CableSortInitialBubbles(st["job"], [first])
    Check(first["bubble"] = -1, "重新分类保持删除")
    first["bubble"] := 0
    CableSortFillMid(st, false)

    ; 搜索后全选
    st["search"] := "DS-"
    CableSortFillMid(st)
    n := c["mid"].GetCount()
    CableSortMidCheckAll(st, true)
    Check(n > 0 && CableSortMidChecked(st).Length = n && CableSortSelected(c["mid"]).Length = n, "搜索结果全选（勾选并选中）：" . n)
    CableSortMidCheckAll(st, false)
    Check(CableSortMidChecked(st).Length = 0, "全部取消")
    st["search"] := ""
    CableSortFillMid(st)
    ; 搜索框叉号：输入后显示，点它清空并恢复全部
    c["search"].Value := "DS"
    st["search"] := "DS", c["searchClear"].Visible := true, CableSortFillMid(st)
    Check(c["mid"].GetCount() < un, "搜索后列表变少")
    CableSortClearSearch(st)
    Check(c["search"].Value = "" && st["search"] = "" && !c["searchClear"].Visible && c["mid"].GetCount() = un, "叉号清空搜索")

    ; 加规则：未分类里同前缀的电缆应自动进气泡
    target := ""
    for cable in st["cables"]
        if (cable["status"] = "norule" && !cable["bubble"]) {
            target := cable
            break
        }
    if IsObject(target) {
        cands := CableSortCandidates(st["cables"], target)
        c["prefix"].Value := target["parsed"]["prefix"]
        c["range"].Value := ""
        c["cab"].Text := cands[1]
        CableSortRuleEdit(st, "add")
        Check(target["status"] = "ok" || target["status"] = "nomatch", "加规则后状态：" . target["status"])
        if (target["status"] = "ok")
            Check(target["bubble"] != 0, "定下起点后自动进气泡")
        FileAppend("INFO 新规则 " . target["parsed"]["prefix"] . " → " . cands[1] . "；" . c["status"].Value . "`n", "*", "UTF-8")
    }

    ; 对调起终点（多选：一根配对 + 一根单行 + 一行其他行）
    pairC := "", singleC := "", fixedC := ""
    for cable in st["bubbles"][1]["items"]
        if (cable["kind"] = "pair" && !IsObject(pairC))
            pairC := cable
    for cable in st["cables"]
        if (cable["kind"] = "single" && !IsObject(singleC))
            singleC := cable
        else if (cable["kind"] = "fixed" && !IsObject(fixedC))
            fixedC := cable
    if (IsObject(pairC) && IsObject(singleC)) {
        before := pairC["keep"], s0 := CableSortStartCell(singleC), e0 := CableSortEndCell(singleC), p0 := CableSortStartCell(pairC)
        CableSortSwapKeep(st, IsObject(fixedC) ? [pairC, singleC, fixedC] : [pairC, singleC])
        Check(pairC["keep"] != before && pairC["status"] = "manual" && pairC["bubble"] = st["bubbles"][1]["id"], "配对电缆对调起终点不换气泡")
        Check(singleC["flip"] && CableSortStartCell(singleC) = e0 && CableSortEndCell(singleC) = s0, "单行电缆对调起终点")
        if IsObject(fixedC)
            Check(!fixedC["flip"] && fixedC["keep"] = 1, "其他行不对调")
        Check(InStr(st["undo"][st["undo"].Length]["label"], "对调起终点 2 根"), "撤销步骤名")
        CableSortUndo(st, "undo")
        Check(!singleC["flip"] && pairC["keep"] = before && CableSortStartCell(pairC) = p0, "撤销对调")
        CableSortUndo(st, "redo")
        Check(singleC["flip"] && pairC["keep"] != before, "重做对调")
    } else {
        Check(false, "真实任务里找不到配对和单行电缆")
    }

    ; 卡片右键菜单：第一项是“对调起终点（N 根）”，点它就对调并关闭菜单；未分类列表菜单列出全部气泡
    st["popupAt"] := [-4000, -4000]
    s1 := st["slots"][1]
    s1["lv"].Modify(0, "-Select"), s1["lv"].Modify(1, "Select"), s1["lv"].Modify(2, "Select")
    CableSortBubbleMenu(st, 1)
    pop := st["popup"], clickable := []
    for el in pop["elements"]
        if IsObject(el["onClick"])
            clickable.Push(el)
    Check(IsObject(pop) && clickable.Length = 4 && clickable[1]["text"] = "对调起终点（2 根）", "气泡菜单第一项：" . (clickable.Length ? clickable[1]["text"] : ""))
    a1 := s1["rows"][1], k1 := a1["keep"], f1 := a1["flip"]
    clickable[1]["onClick"]()
    Check(!IsObject(st["popup"]) && (a1["keep"] != k1 || a1["flip"] != f1), "点菜单第一项对调并关闭菜单")
    Check(CableSortSelected(s1["lv"]).Length = 2, "对调后保持选中")
    CableSortUndo(st, "undo")
    ; 局部排序：打乱后只选其中几根排序，选中的按编号排好、占原来那些位置，没选的不动
    bb := st["bubbles"][1]
    if (bb["items"].Length >= 6) {
        s1["search"].Value := "", CableSortSlotSearch(st, 1, false)
        bb["manual"] := true
        bb["items"].InsertAt(1, bb["items"].RemoveAt(5))          ; 第 5 根挪到最前，制造乱序
        CableSortFillBubble(st, 1)
        before := []
        for c0 in bb["items"]
            before.Push(c0)
        s1["lv"].Modify(0, "-Select")
        for r in [1, 3, 4, 5]
            s1["lv"].Modify(r, "Select")
        pk := CableSortViewPicked(s1)
        CableSortSortPicked(st, 1, pk)
        okKeep := ObjPtr(bb["items"][2]) = ObjPtr(before[2]) && ObjPtr(bb["items"][6]) = ObjPtr(before[6])
        want := CableSortSortList([before[1], before[3], before[4], before[5]])
        okSort := true
        for j, k in [1, 3, 4, 5]
            okSort := okSort && ObjPtr(bb["items"][k]) = ObjPtr(want[j])
        Check(okKeep && okSort && bb["manual"] && CableSortSelected(s1["lv"]).Length = 4, "局部排序只动选中的，保持选中")
        CableSortUndo(st, "undo")
        Check(ObjPtr(st["bubbles"][1]["items"][1]) = ObjPtr(before[1]) && ObjPtr(st["bubbles"][1]["items"][3]) = ObjPtr(before[3]), "撤销局部排序")
    }
    ; 拖到气泡标题区（没有位置）：手动调整过的气泡里按编号插到合适位置，原有条目顺序不变
    bh := st["bubbles"][1]
    if (bh["items"].Length >= 4) {
        bh["manual"] := true
        bh["items"].InsertAt(1, bh["items"].RemoveAt(3))
        CableSortFillBubble(st, 1)
        orig := []
        for c0 in bh["items"]
            orig.Push(c0)
        one := orig[2]
        CableSortPlace(st, [one], 0)                 ; 先移出
        CableSortPlace(st, [one], 1, -1)             ; 再按标题区方式放回
        expect := []
        for c0 in orig
            if (ObjPtr(c0) != ObjPtr(one))
                expect.Push(c0)
        CableSortInsertSorted(expect, one)
        same := bh["items"].Length = expect.Length
        for k, c0 in expect
            same := same && ObjPtr(bh["items"][k]) = ObjPtr(c0)
        Check(same && bh["manual"], "拖到气泡标题区按编号插入，其他条目不动")
    }
    ; 右键气泡名称的菜单：只有放大、按编号排序这个气泡、删除这个气泡
    CableSortBubbleTitleMenu(st, 1)
    tn := ""
    for el in st["popup"]["elements"]
        if IsObject(el["onClick"])
            tn .= el["text"] . "|"
    Check(tn = "放大…|按编号排序这个气泡|删除这个气泡（电缆回到未分类）|", "右键气泡名称的菜单：" . tn)
    CableSortPopupClose(st)
    ; 气泡菜单“移到分类”：列出其他气泡（不含自己），点了就移过去
    s1["lv"].Modify(0, "-Select"), s1["lv"].Modify(1, "Select")
    mv := s1["rows"][1]
    CableSortBubbleMenu(st, 1)
    names := "", moveEl := ""
    for el in st["popup"]["elements"] {
        names .= el["text"] . "|"
        if (el["text"] = "移到分类")
            moveEl := el
    }
    Check(IsObject(moveEl) && !InStr(names, st["bubbles"][2]["name"] . "（") && !InStr(names, "改名…") && !InStr(names, "往前移")
        && !InStr(names, "往后移") && !InStr(names, "移出分类") && !InStr(names, "这个气泡") && !InStr(names, "双击"), "右键电缆的菜单只有电缆操作，移到分类默认收起：" . names)
    old := st["popup"]
    moveEl["onClick"]()                              ; 点“移到分类”：不关菜单，原位置展开
    Check(IsObject(st["popup"]) && ObjPtr(st["popup"]) != ObjPtr(old), "点移到分类展开")
    target := "", selfListed := false
    for el in st["popup"]["elements"] {
        if (el["text"] = st["bubbles"][2]["name"] . "（" . st["bubbles"][2]["items"].Length . "）")
            target := el
        if (el["text"] = st["bubbles"][1]["name"] . "（" . st["bubbles"][1]["items"].Length . "）")
            selfListed := true
    }
    Check(IsObject(target) && IsObject(target["onClick"]) && !selfListed, "气泡菜单列出其他分类、不含自己")
    if IsObject(target)
        target["onClick"]()
    Check(mv["bubble"] = st["bubbles"][2]["id"] && !IsObject(st["popup"]), "气泡菜单移到分类")
    CableSortUndo(st, "undo")
    Check(mv["bubble"] = st["bubbles"][1]["id"], "撤销移到分类")
    st["ctl"]["mid"].Modify(0, "-Select"), st["ctl"]["mid"].Modify(1, "Select")
    CableSortMidMenu(st, true)
    names := ""
    for el in st["popup"]["elements"]
        names .= el["text"] . "|"
    Check(InStr(names, st["bubbles"][1]["name"]) && InStr(names, "移到分类") && InStr(names, "对调起终点"), "未分类菜单：" . names)
    CableSortPopupClose(st)
    Check(!IsObject(st["popup"]), "关闭菜单")
    st["popupAt"] := ""

    ; 气泡内搜索：只显示命中的，选中和插入位置按实际条目换算
    s1 := st["slots"][1], b1 := st["bubbles"][1]
    q := b1["items"][Min(5, b1["items"].Length)]["id"]
    s1["search"].Value := q
    CableSortSlotSearch(st, 1, false)
    n1 := s1["lv"].GetCount()
    Check(n1 >= 1 && n1 <= b1["items"].Length && s1["sclear"].Visible && InStr(s1["sub"].Value, "搜到"), "气泡内搜索：" . q . " → " . n1)
    s1["lv"].Modify(0, "-Select"), s1["lv"].Modify(1, "Select")
    Check(ObjPtr(CableSortBubblePicked(st, 1)[1]) = ObjPtr(s1["rows"][1]), "筛选后选中对应实际条目")
    k1 := 0
    for k, cable in b1["items"]
        if (ObjPtr(cable) = ObjPtr(s1["rows"][1]))
            k1 := k
    Check(CableSortRowPosToItemPos(s1["rows"], b1["items"], 0) = k1 - 1, "筛选后插入位置换算")
    ; 点气泡里的电缆：底部详情栏显示完整起点、终点
    pickC := s1["rows"][1]
    CableSortLoadBubbleEditor(st, 1, 1)
    dt := st["ctl"]["detail"].Value
    Check(!InStr(dt, pickC["id"]) && InStr(dt, CableSortDisplay(CableSortStartCell(pickC))) && InStr(dt, CableSortDisplay(CableSortEndCell(pickC)))
        && !InStr(dt, b1["name"]) && !InStr(dt, "芯") && st["detailStrong"], "详情栏只有起点、终点：" . dt)
    CableSortSwapKeep(st, [pickC])
    Check(InStr(st["ctl"]["detail"].Value, "起点　" . CableSortDisplay(CableSortStartCell(pickC)) . "　　→"), "对调后详情栏跟着变")
    CableSortUndo(st, "undo")
    ; 放大窗口（放在屏幕外）：继承气泡的搜索词、单独搜索、改动和主窗口同步、撤销后跟着恢复
    z := CableSortZoom(st, 1, "x-4000 y0 w1000 h640 NoActivate")
    Check(z["search"].Value = q && z["lv"].GetCount() = n1 && z["sclear"].Visible && InStr(z["gui"].Title, b1["name"]), "放大窗口继承气泡搜索词")
    CableSortZoomSearch(st, z, true)
    Check(z["lv"].GetCount() = b1["items"].Length, "放大窗口清空搜索显示全部")
    z["search"].Value := q
    CableSortZoomSearch(st, z, false)
    Check(z["lv"].GetCount() = n1 && z["sclear"].Visible, "放大窗口搜索")
    ; 全局搜索：所有气泡、未分类、放大窗口一起筛选，清空后全部恢复
    gq := "131", want := 0, got := 0, allOk := true
    for i, b in st["bubbles"] {
        cnt := 0
        for cable in b["items"]
            cnt += CableSortQueryMatch(cable, gq)
        want += cnt
    }
    st["ctl"]["gsearch"].Value := gq
    CableSortGlobalSearch(st, false)
    for i, b in st["bubbles"] {
        sl := st["slots"][i]
        got += sl["lv"].GetCount()
        allOk := allOk && sl["search"].Value = gq
        for cable in sl["rows"]
            allOk := allOk && CableSortQueryMatch(cable, gq)
    }
    Check(want > 0 && got = want && allOk && st["ctl"]["search"].Value = gq && z["search"].Value = gq
        && st["ctl"]["gclear"].Visible && InStr(st["ctl"]["detail"].Value, "全局搜索「131」"), "全局搜索：气泡里共 " . got . " / " . want)
    CableSortGlobalSearch(st, true)
    Check(st["slots"][1]["lv"].GetCount() = b1["items"].Length && z["lv"].GetCount() = b1["items"].Length
        && st["ctl"]["search"].Value = "" && !st["ctl"]["gclear"].Visible, "清空全局搜索全部恢复")
    s1["search"].Value := q
    CableSortSlotSearch(st, 1, false)
    z["search"].Value := q
    CableSortZoomSearch(st, z, false)
    z["lv"].Modify(0, "-Select"), z["lv"].Modify(1, "Select")
    moved := CableSortViewPicked(z)[1]
    CableSortPlace(st, [moved], 0)
    Check(moved["bubble"] = 0 && z["lv"].GetCount() = n1 - 1 && s1["lv"].GetCount() = n1 - 1, "放大窗口移出分类，两边同步")
    CableSortUndo(st, "undo")
    Check(moved["bubble"] = st["bubbles"][1]["id"] && z["lv"].GetCount() = n1, "撤销后放大窗口跟着恢复")
    Check(CableSortZoom(st, 1) = z, "同一气泡只开一个放大窗口")
    z["search"].Value := "", CableSortZoomSearch(st, z, false)
    ; 滚到中间选两根对调：滚动位置不变、仍然选中
    big := 1
    for i, bb in st["bubbles"]
        if (bb["items"].Length > st["bubbles"][big]["items"].Length)
            big := i
    zb := CableSortZoom(st, big, "x-4000 y0 w1000 h640 NoActivate")
    Check(zb["lv"].GetCount() > 60, "最大气泡够长，能测滚动：" . zb["lv"].GetCount())
    if (zb["lv"].GetCount() > 60) {
        z := zb
        CableSortLvScrollTo(z["lv"], 30)
        top0 := CableSortLvTop(z["lv"])
        z["lv"].Modify(0, "-Select"), z["lv"].Modify(top0 + 4, "Select"), z["lv"].Modify(top0 + 5, "Select")
        CableSortSwapKeep(st, CableSortViewPicked(z))
        Check(top0 > 0 && CableSortLvTop(z["lv"]) = top0, "对调后列表不跳动：" . top0 . " → " . CableSortLvTop(z["lv"]))
        sel := CableSortSelected(z["lv"])
        Check(sel.Length = 2 && sel[1] = top0 + 4, "对调后原位置保持选中")
        CableSortUndo(st, "undo")
        Check(CableSortLvTop(z["lv"]) = top0, "撤销后也不跳动")
        FileAppend("INFO 滚动测试：气泡 " . big . " 共 " . z["lv"].GetCount() . " 行，顶行 " . top0 . "`n", "*", "UTF-8")
    }
    z := zb
    if (big != 1)
        CableSortZoomClose(st, zb), z := CableSortZoom(st, 1)
    if (A_Args.Length >= 2) {
        DllCall("RedrawWindow", "Ptr", z["gui"].Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
        Sleep(200)
        Check(SaveWindowPng(z["gui"].Hwnd, RegExReplace(A_Args[2], "\.png$", "-zoom.png")), "放大窗口截图")
    }
    CableSortZoomClose(st, z)
    Check(!st["zooms"].Count, "关闭放大窗口")

    Sleep(300)
    st["gui"].GetClientPos(, , &cw0, &ch0)
    c["apply"].GetPos(&ax, &ay, &aw, &ah)
    c["hint"].GetPos(&hx, &hy)
    FileAppend("INFO client " . cw0 . "x" . ch0 . " apply " . ax . "," . ay . " " . aw . "x" . ah . " visible=" . c["apply"].Visible . " hint " . hx . "," . hy . " dpi=" . A_ScreenDPI . "`n", "*", "UTF-8")
    DllCall("RedrawWindow", "Ptr", st["gui"].Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)  ; 屏幕外窗口先强制整体重绘
    Sleep(200)
    c["search"].Value := "DS"                          ; 截图时搜索框里有字，能看到叉号
    st["search"] := "DS", c["searchClear"].Visible := true, CableSortFillMid(st)
    DllCall("RedrawWindow", "Ptr", st["gui"].Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
    Sleep(200)
    if (A_Args.Length >= 2) {
        Check(SaveWindowPng(st["gui"].Hwnd, A_Args[2]), "截图")
        ; 模拟最大化后的大窗口：放大到 1900x1010（仍在屏幕外）再截一张
        WinMove(-4000, 0, 1900, 1010, st["gui"].Hwnd)
        Sleep(300)
        DllCall("RedrawWindow", "Ptr", st["gui"].Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x185)
        Sleep(200)
        Check(SaveWindowPng(st["gui"].Hwnd, RegExReplace(A_Args[2], "\.png$", "-big.png")), "大窗口截图")
    }
    try FileDelete(st["rulesPath"])
    try FileDelete(progress)
}

SameOrder(a, b) {
    if (a.Length != b.Length)
        return false
    for i, x in a
        if (ObjPtr(x) != ObjPtr(b[i]))
            return false
    return true
}

; PrintWindow 截取窗口（含屏幕外），用 GDI+ 存 PNG
SaveWindowPng(hwnd, path) {
    rc := Buffer(16, 0)
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", rc)
    w := NumGet(rc, 8, "Int") - NumGet(rc, 0, "Int"), h := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
    hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    mdc := DllCall("CreateCompatibleDC", "Ptr", hdc, "Ptr")
    hbm := DllCall("CreateCompatibleBitmap", "Ptr", hdc, "Int", w, "Int", h, "Ptr")
    old := DllCall("SelectObject", "Ptr", mdc, "Ptr", hbm, "Ptr")
    DllCall("PrintWindow", "Ptr", hwnd, "Ptr", mdc, "UInt", 2)
    DllCall("SelectObject", "Ptr", mdc, "Ptr", old)
    DllCall("DeleteDC", "Ptr", mdc)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    DllCall("LoadLibrary", "Str", "gdiplus")
    si := Buffer(24, 0), NumPut("UInt", 1, si, 0)
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &token := 0, "Ptr", si, "Ptr", 0)
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", &bmp := 0)
    clsid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
    ok := DllCall("gdiplus\GdipSaveImageToFile", "Ptr", bmp, "Str", path, "Ptr", clsid, "Ptr", 0) = 0
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bmp)
    DllCall("gdiplus\GdiplusShutdown", "Ptr", token)
    DllCall("DeleteObject", "Ptr", hbm)
    return ok
}
