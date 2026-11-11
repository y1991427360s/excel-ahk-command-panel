#Requires AutoHotkey v2.0
#Warn All, StdOut  ; 警告写到标准输出，不弹窗
; 电缆排序（YSDL3）纯逻辑冒烟测试，不连接 CAD。
; 用法：AutoHotkey64.exe /ErrorStdOut tests\cable-sort-core-smoke.ahk [真实 job.txt 路径（可省略）]
; 输出 PASS/FAIL 到标准输出，失败时退出码 1。
#Include ..\src\cable-sort-core.ahk

failures := 0
Check(cond, what) {
    global failures
    if !cond {
        failures++
        FileAppend("FAIL: " . what . "`n", "*", "UTF-8")
    }
}

try {
    RunSmoke()
} catch as smokeErr {
    failures++
    FileAppend("FAIL: 运行出错 " . smokeErr.Message . "（" . smokeErr.What . " 第 " . smokeErr.Line . " 行）`n", "*", "UTF-8")
}

; 测试都放在函数里：不产生全局变量，避免与被测函数的局部变量同名触发 #Warn
RunSmoke() {
    ; 两个分类框。1AW-132A 两行跨框；1B-144、1B-194 同框成对；X-1 只有一行；K-9 三行（编号重复）；
    ; “公用测控柜 2 701”不是电缆行，作为“其他行”条目。行格式：起点 编号 终点 规格 芯数
    rows0 := [
        ["35kV故障录波柜", "1AW-132A", "至安全稳定控制装置A柜", "4×4", "4"],   ; 0 另一端（保留端在框 1）
        ["主变及110kV故障录波柜", "1B-144", "至1#主变保护柜", "7×1.5", "5"],  ; 1 另一端
        ["1#主变保护柜", "1B-144", "至主变及110kV故障录波柜", "7×1.5", "5"],  ; 2 保留（1B → 1#主变保护柜）
        ["1#主变保护柜", "1B-194", "至1#主变本体端子箱", "4×4", "2"],        ; 3 另一端（范围规则）
        ["公用测控柜", "2", "701"],                                          ; 4 不动
        ["1#主变 本体端子箱", "1B-194", "至 1#主变保护柜", "4 × 4", "2"],     ; 5 保留（空格不影响）
        ["A柜", "X-1", "至B柜", "4×4", "4"],                                 ; 6 单行，无规则
    ]
    rows1 := [
        ["安全稳定控制装置A柜", "1AW-132A", "至35kV故障录波柜", "4×4", "4"], ; 0 保留
        ["C柜", "K-9", "至D柜", "4×4", "4"],                                 ; 1
        ["D柜", "K-9", "至C柜", "4×4", "4"],                                 ; 2
        ["E柜", "K-9", "至F柜", "4×4", "4"],                                 ; 3
        ["安全稳定控制装置A柜", "1AW-133", "至X柜", "4×4", "4"],             ; 4 单行（让 1AW 能推断出起点）
    ]
    job := CableSortParseJob(JobText([["公用部分", rows0], ["主变部分", rows1]]))
    Check(job["boxes"].Length = 2 && job["boxes"][1]["rows"].Length = 7, "解析框和行")
    cables := CableSortBuild(job)
    ids := ""
    for c in cables
        ids .= c["id"] . ":" . c["kind"] . " "
    Check(ids = "1AW-132A:pair 1B-144:pair 1B-194:pair 2:fixed X-1:single K-9:problem 1AW-133:single ", "配对：" . ids)

    rules := [CableSortNewRule("1B", "191-198", "至1#主变本体端子箱"), CableSortNewRule("1b", "", "1#主变保护柜")]
    inferred := CableSortInfer(cables, rules)
    Check(inferred.Length = 1 && inferred[0 + 1]["prefix"] = "1AW" && inferred[1]["cabinet"] = "安全稳定控制装置A柜"
        , "推断 1AW → 安全稳定控制装置A柜")
    for r in inferred
        rules.Push(r)
    CableSortResolveAll(cables, rules)
    st := ""
    for c in cables
        st .= c["id"] . "=" . c["status"] . "/" . c["keep"] . " "
    Check(st = "1AW-132A=ok/2 1B-144=ok/2 1B-194=ok/2 2=fixed/1 X-1=norule/1 K-9=problem/1 1AW-133=ok/1 ", "状态与保留端：" . st)
    Check(CableSortFindRule(cables[3], rules) = 1, "带范围的规则优先")

    bubbles := CableSortInitialBubbles(job, cables)
    Names(list) {
        out := ""
        for c in list
            out .= c["id"] . " "
        return out
    }
    ; 公用部分：同前缀 1B 按号码 1B-144 在 1B-194 前，其他行“2”最后；主变部分：1AW-132A、1AW-133；
    ; X-1（没有规则）、K-9（编号重复）待处理，留在未分类
    Check(bubbles.Length = 2 && bubbles[1]["name"] = "公用部分", "初始气泡取分类框名称")
    Check(Names(bubbles[1]["items"]) = "1B-144 1B-194 2 ", "公用部分：" . Names(bubbles[1]["items"]))
    Check(Names(bubbles[2]["items"]) = "1AW-132A 1AW-133 ", "主变部分：" . Names(bubbles[2]["items"]))
    Check(cables[5]["bubble"] = 0 && cables[6]["bubble"] = 0 && cables[1]["bubble"] = 2, "未分类与所在气泡")

    res := CableSortBuildResult(job, bubbles)
    want := "AAYSDL3RESULT`t2`r`nID`t2461354.7`r`n"
        . "CAT`t公用部分`t0:2`t0:5`t0:4`r`n"
        . "CAT`t主变部分`t1:0`t1:4`r`n"
    Check(res = want, "result.txt：`n" . res)

    ; 拖进气泡：X-1 按排序键插到其他行之前；K-9 放进新气泡（名称里的 TAB 换成空格）
    CableSortInsertSorted(bubbles[1]["items"], cables[5])
    Check(Names(bubbles[1]["items"]) = "1B-144 1B-194 X-1 2 ", "按排序键插入：" . Names(bubbles[1]["items"]))
    bubbles.Push(Map("id", 3, "name", "新`t分类", "box", 0, "items", [cables[6]]))
    res := CableSortBuildResult(job, bubbles)
    Check(InStr(res, "CAT`t新 分类`t1:1`r`n"), "新气泡导出：`n" . res)
    bubbles[2]["items"].Push(cables[5])
    try {
        CableSortBuildResult(job, bubbles)
        Check(false, "同一条目在两个气泡里应报错")
    }
    bubbles[2]["items"].Pop()
    Check(CableSortSortList(bubbles[1]["items"])[3]["id"] = "X-1", "整体按编号排序")

    ; 同前缀不管有没有命中规则都按号码排：DS-14、DS-31 命中 6-31 的范围规则，DS-01、DS-02 没命中，排序后仍是 01 02 14 31
    rowsDs := [
        ["同步时钟主机柜", "DS-14", "至甲柜", "通讯线"],
        ["同步时钟主机柜", "DS-31", "至乙柜", "通讯线"],
        ["同步时钟主机柜", "DS-02", "至丙柜", "通讯线"],
        ["同步时钟主机柜", "DS-01", "至丁柜", "通讯线"],
        ["备用柜", "DS-201", "至戊柜", "通讯线"],
    ]
    jobDs := CableSortParseJob(JobText([["公用部分", rowsDs]]))
    cDs := CableSortBuild(jobDs)
    CableSortResolveAll(cDs, [CableSortNewRule("DS", "6-31", "同步时钟主机柜")])
    Check(Names(CableSortSortList(cDs)) = "DS-01 DS-02 DS-14 DS-31 DS-201 ", "同前缀按号码排：" . Names(CableSortSortList(cDs)))
    ; 搜索：编号、柜名、规格（x / * 当 ×），空格分隔多个词都要命中
    Check(CableSortQueryMatch(cables[1], "4x4") && CableSortQueryMatch(cables[1], "1aw 4*4") && CableSortQueryMatch(cables[1], "安全稳定")
        && !CableSortQueryMatch(cables[1], "7x1.5") && !CableSortQueryMatch(cables[1], "1AW 7×1.5") && CableSortQueryMatch(cables[1], "  "), "搜索编号、柜名、规格")
    Check(CableSortQueryMatch(cDs[1], "DS 通讯线") && !CableSortQueryMatch(cDs[1], "DB 通讯线"), "多个词同时命中")

    ; 对调起终点：单行电缆 1AW-133 导出写 :R 并用第 3 版；配对的 1B-144 改留另一行；其他行不处理
    cF := CableSortBuild(job)
    CableSortResolveAll(cF, rules)
    bF := CableSortInitialBubbles(job, cF)
    Check(CableSortFlip(cF[7], rules) && cF[7]["flip"] && CableSortStartCell(cF[7]) = "至X柜"
        && CableSortEndCell(cF[7]) = "安全稳定控制装置A柜" && cF[7]["status"] = "manual", "单行电缆对调起终点")
    Check(CableSortFlip(cF[2], rules) && cF[2]["keep"] = 1 && !cF[2]["flip"] && CableSortStartCell(cF[2]) = "主变及110kV故障录波柜"
        , "配对电缆对调起终点 = 改留另一行")
    Check(!CableSortFlip(cF[4], rules), "其他行不对调")
    resF := CableSortBuildResult(job, bF)
    Check(SubStr(resF, 1, 15) = "AAYSDL3RESULT`t3" && InStr(resF, "CAT`t主变部分`t1:0`t1:4:R`r`n") && InStr(resF, "CAT`t公用部分`t0:1`t"), "对调后的 result：`n" . resF)
    progF := CableSortParseProgress(CableSortSerializeProgress(job, cF, rules, bF))
    cF2 := CableSortBuild(job)
    CableSortApplyProgress(job, cF2, progF)
    Check(cF2[7]["flip"] && cF2[7]["status"] = "manual" && !cF2[2]["flip"] && cF2[2]["keep"] = 1, "进度恢复对调起终点")
    CableSortFlip(cF[7], rules)
    Check(!cF[7]["flip"] && SubStr(CableSortBuildResult(job, bF), 1, 15) = "AAYSDL3RESULT`t2", "再对调一次复原，回到第 2 版")
    CableSortFlip(cF[7], rules)
    CableSortResolveAll(cF, rules, false)
    Check(!cF[7]["flip"] && cF[7]["status"] = "ok" && cF[2]["keep"] = 2, "全部按规则重新分类清掉对调")

    ; 整理进度：保存后重新读入同一任务，气泡、顺序、删除、手动保留端都要恢复
    c2 := CableSortBuild(job)
    CableSortResolveAll(c2, rules)
    b2 := CableSortInitialBubbles(job, c2)
    c2[2]["keep"] := 1, c2[2]["manualKeep"] := true
    CableSortResolve(c2[2], rules)                       ; 1B-144 手动改留另一端
    c2[5]["bubble"] := -1                                ; X-1 删除
    b2.Push(Map("id", 9, "name", "新`t分类", "box", 0, "items", [c2[6]]))
    c2[6]["bubble"] := 9                                 ; K-9 放进新气泡
    t1 := b2[1]["items"].RemoveAt(1), b2[1]["items"].Push(t1), b2[1]["manual"] := true   ; 公用部分手动调过顺序
    prog := CableSortParseProgress(CableSortSerializeProgress(job, c2, rules, b2))
    Check(prog["rules"].Length = rules.Length && prog["bubbles"].Length = 3, "进度文件解析")
    c3 := CableSortBuild(job)
    res := CableSortApplyProgress(job, c3, prog)
    Check(res["restored"] = c3.Length && res["added"] = 0 && res["missing"] = 0, "进度条目全部对上")
    Check(Names(res["bubbles"][1]["items"]) = Names(b2[1]["items"]) && res["bubbles"][1]["manual"], "恢复手动调整过的气泡顺序：" . Names(res["bubbles"][1]["items"]))
    ; 旧进度文件（BUBBLE 行没有“手动”列）：气泡按编号重新排序
    oldText := RegExReplace(CableSortSerializeProgress(job, c2, rules, b2), "m)^(BUBBLE`t[^`t`r`n]*`t[^`t`r`n]*`t[^`t`r`n]*)`t[01]", "$1")
    cOld := CableSortBuild(job)
    resOld := CableSortApplyProgress(job, cOld, CableSortParseProgress(oldText))
    Check(Names(resOld["bubbles"][1]["items"]) = "1B-144 1B-194 2 " && !resOld["bubbles"][1]["manual"], "旧进度按编号重排：" . Names(resOld["bubbles"][1]["items"]))
    Check(res["bubbles"][1]["box"] = 1 && res["bubbles"][3]["name"] = "新 分类" && res["bubbles"][3]["box"] = 0, "恢复气泡名称和对应分类框")
    Check(c3[6]["bubble"] = 9 && c3[5]["bubble"] = -1, "恢复新气泡里的条目和删除")
    Check(c3[2]["keep"] = 1 && c3[2]["manualKeep"] && c3[2]["status"] = "manual", "恢复手动保留端")
    Check(res["nextId"] = 10, "新气泡编号接着排")
    ; 清册改过：少了 1AW-133、多了一根新电缆 1B-150（规则 1B → 1#主变保护柜，保留端在公用部分）
    rows1b := [rows1[1], rows1[2], rows1[3], rows1[4]]
    rows0b := rows0.Clone()
    rows0b.Push(["1#主变保护柜", "1B-150", "至X柜", "4×4", "4"])
    job4 := CableSortParseJob(JobText([["公用部分", rows0b], ["主变部分", rows1b]]))
    c4 := CableSortBuild(job4)
    res4 := CableSortApplyProgress(job4, c4, prog)
    Check(res4["added"] = 1 && res4["missing"] = 1, "新增与缺少的条目计数：" . res4["added"] . "/" . res4["missing"])
    Check(InStr(Names(res4["bubbles"][1]["items"]), "1B-150"), "新电缆按规则进了公用部分")

    ; 手动换保留端：1B-144 改留另一端（框 1 第 1 行），仍在框 1
    c144 := cables[2]
    c144["keep"] := 1, c144["manualKeep"] := true
    CableSortResolve(c144, rules)
    Check(c144["status"] = "manual" && c144["keep"] = 1, "手动保留端不被规则覆盖")
    CableSortResolveAll(cables, rules, false)
    Check(c144["status"] = "ok" && c144["keep"] = 2, "重新按规则排清掉手动保留端")

    ; 规则文件读写
    tmp := A_Temp . "\cable-sort-smoke-rules.txt"
    CableSortSaveRules(tmp, rules)
    back := CableSortLoadRules(tmp)
    Check(back.Length = 3 && back[1]["range"] = "191-198" && back[3]["cabinet"] = "安全稳定控制装置A柜", "规则文件读写")
    FileDelete(tmp)
    Check(!IsObject(CableSortParseRange("19x")), "范围写错")
    cand := CableSortCandidates(cables, cables[3])
    Check(cand.Length >= 3 && cand[1] = "1#主变保护柜", "候选柜子按覆盖数排序：" . (cand.Length ? cand[1] : ""))

    ; 真实任务文件（可选）
    if (A_Args.Length >= 1 && FileExist(A_Args[1])) {
        t0 := A_TickCount
        real := CableSortParseJob(FileRead(A_Args[1], "UTF-8"))
        rc := CableSortBuild(real)
        rr := CableSortInfer(rc, [])
        CableSortResolveAll(rc, rr)
        rb := CableSortInitialBubbles(real, rc)
        rt := CableSortBuildResult(real, rb)
        placed := 0
        for bubble in rb
            placed += bubble["items"].Length
        counts := Map()
        for c in rc
            counts[c["status"]] := (counts.Has(c["status"]) ? counts[c["status"]] : 0) + 1
        s := ""
        for k, v in counts
            s .= k . "=" . v . " "
        nrows := 0
        for box in real["boxes"]
            nrows += box["rows"].Length
        Check(StrLen(rt) > 0, "真实任务生成结果")
        FileAppend("INFO real job: " . nrows . " 行，" . rc.Length . " 个条目（含其他行），推断规则 " . rr.Length . " 条；初始放进气泡 " . placed . " 个；" . s
            . "；耗时 " . (A_TickCount - t0) . " ms`n", "*", "UTF-8")
        sample := ""
        for r in rr {
            if (A_Index > 12)
                break
            sample .= r["prefix"] . "→" . r["cabinet"] . "  "
        }
        FileAppend("INFO 推断示例: " . sample . "`n", "*", "UTF-8")
    }

}

JobText(boxes) {
    text := "AAYSDL3`t1`r`nID`t2461354.7`r`nDWG`tD:\工程\清册.dwg`r`nMODE`tbox`r`n"
    for b, box in boxes {
        text .= "BOX`t" . (b - 1) . "`t" . box[1] . "`t" . box[2].Length . "`r`n"
        for i, cells in box[2] {
            line := "ROW`t" . (b - 1) . "`t" . (i - 1) . "`tH" . b . "_" . i
            for c in cells
                line .= "`t" . c
            text .= line . "`r`n"
        }
    }
    return text
}
FileAppend(failures ? "FAIL (" . failures . ")`n" : "PASS cable-sort-core`n", "*", "UTF-8")
ExitApp(failures ? 1 : 0)
