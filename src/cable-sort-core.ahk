#Requires AutoHotkey v2.0
; 电缆排序（YSDL3）的纯逻辑：读中望 YSDL3 写的 job.txt，跨分类框配对、按“前缀（+编号范围）→ 起点柜”规则
; 决定保留端，把电缆放进分类“气泡”（初始为图上的分类框）并排序，生成给 (aa:ysdl3-apply) 的 result.txt（第 2 版）。不碰界面、不连 CAD，tests\cable-sort-core-smoke.ahk 直接测。
; 设计见 D:\Syncthing\Oracle-Sync\LISP\ZW-auto_lisp\docs\YSDL3.md。
;
; 约定：
; - 行的单元格顺序为 起点、编号、终点、规格、芯数、原理号…（清册原样）。
; - 编号含“-”且含字母或数字才算电缆行；其余行（框底零散文字等）作为“其他行”条目，初始留在所在分类框的气泡末尾。
; - 同编号两行起点终点互换且规格相同为一对，可以分在不同分类框；只有一行为单行；其他为“编号重复/两端对不上”。
; - 导出只按气泡：每个气泡一行 CAT，列出各条目保留行的“框号:行号”；不在任何气泡里的条目不导出。插件不移动清册文字。
; - 柜名比较同中望 hddl:cabinet：去掉全部空白、开头的“至”，忽略大小写。

CableSortNorm(s) {
    s := RegExReplace(s, "[\s\x{3000}\x{00A0}]+")
    while (SubStr(s, 1, 1) = "至")
        s := SubStr(s, 2)
    return StrUpper(s)
}

; 显示用柜名：去掉首尾空白和开头的“至”
CableSortDisplay(s) {
    return Trim(RegExReplace(Trim(s), "^(至\s*)+"))
}

CableSortCell(row, i) {
    return row["cells"].Length >= i ? row["cells"][i] : ""
}

CableSortIsCableId(id) {
    key := CableSortNorm(id)
    return InStr(key, "-") && RegExMatch(key, "[A-Z0-9]")
}

; 前缀-号码[字母]，如 1AW-132A；不是这种格式返回 ""
CableSortParseId(key) {
    if RegExMatch(key, "^([^-]+)-(\d{1,9})([A-Z]*)$", &m)
        return Map("prefix", m[1], "num", Integer(m[2]), "suffix", m[3])
    return ""
}

; 读 job.txt 文本；格式不对时抛出错误
CableSortParseJob(text) {
    job := Map("id", "", "dwg", "", "mode", "", "cad", "ZWCAD", "boxes", [])
    head := false
    for line in StrSplit(text, "`n", "`r") {
        p := StrSplit(line, "`t")
        if (p.Length = 0)
            continue
        switch p[1] {
            case "AAYSDL3", Chr(0xFEFF) . "AAYSDL3":
                head := true
            case "ID":
                job["id"] := p.Length >= 2 ? p[2] : ""
            case "DWG":
                job["dwg"] := p.Length >= 2 ? p[2] : ""
            case "MODE":
                job["mode"] := p.Length >= 2 ? p[2] : ""
            case "CAD":         ; AutoCAD 版插件写 CAD<TAB>ACAD；中望版不写，默认 ZWCAD
                job["cad"] := (p.Length >= 2 && p[2] = "ACAD") ? "ACAD" : "ZWCAD"
            case "BOX":
                if (p.Length >= 4)
                    job["boxes"].Push(Map("title", p[3], "count", Integer(p[4]), "rows", []))
            case "ROW":
                if (p.Length < 4)
                    continue
                b := Integer(p[2]) + 1
                if (b < 1 || b > job["boxes"].Length)
                    throw Error("job.txt 的 ROW 行框号超出范围：" . p[2])
                cells := []
                loop p.Length - 4
                    cells.Push(p[A_Index + 4])
                job["boxes"][b]["rows"].Push(Map("box", b, "idx", Integer(p[3]), "handles", p[4], "cells", cells, "key", ""))
        }
    }
    if (!head || job["id"] = "" || job["boxes"].Length = 0)
        throw Error("不是有效的 YSDL3 任务文件。")
    for box in job["boxes"] {
        if (box["rows"].Length != box["count"])
            throw Error("分类框“" . box["title"] . "”行数不符：应有 " . box["count"] . " 行，读到 " . box["rows"].Length . " 行。")
        for row in box["rows"]
            if (row["idx"] != A_Index - 1)
                throw Error("分类框“" . box["title"] . "”的行号不连续。")
    }
    return job
}

CableSortMirror(a, b) {
    return CableSortNorm(CableSortCell(a, 1)) = CableSortNorm(CableSortCell(b, 3))
        && CableSortNorm(CableSortCell(a, 3)) = CableSortNorm(CableSortCell(b, 1))
        && CableSortNorm(CableSortCell(a, 4)) = CableSortNorm(CableSortCell(b, 4))
}

; 按编号把各框的电缆行配成电缆（跨框）。返回电缆数组，按编号首次出现的先后
CableSortBuild(job) {
    cables := [], byKey := Map(), fixedSeen := Map()
    for b, box in job["boxes"] {
        for row in box["rows"] {
            id := CableSortCell(row, 2)
            if !CableSortIsCableId(id) {
                ; 其他行：单独成一个条目，不参与配对和规则
                text := ""
                for cell in row["cells"]
                    text .= "|" . CableSortNorm(cell)
                fixedSeen[text] := (fixedSeen.Has(text) ? fixedSeen[text] : 0) + 1
                key := "#" . text . "#" . fixedSeen[text]
                cables.Push(Map("key", key, "id", Trim(id), "rows", [row], "pos", cables.Length + 1
                    , "parsed", "", "kind", "fixed", "keep", 1, "manualKeep", false, "flip", false, "rule", 0, "status", "fixed", "bubble", 0))
                row["key"] := key
                continue
            }
            key := CableSortNorm(id)
            if !byKey.Has(key) {
                cable := Map("key", key, "id", Trim(id), "rows", [], "pos", cables.Length + 1
                    , "parsed", CableSortParseId(key), "kind", "", "keep", 1, "manualKeep", false, "flip", false
                    , "rule", 0, "status", "", "bubble", 0)
                byKey[key] := cable
                cables.Push(cable)
            }
            byKey[key]["rows"].Push(row)
            row["key"] := key
        }
    }
    prefixFirst := Map()
    for cable in cables {
        if (cable["kind"] = "fixed")
            continue
        if IsObject(cable["parsed"]) {
            pf := cable["parsed"]["prefix"]
            if !prefixFirst.Has(pf)
                prefixFirst[pf] := cable["pos"]
            cable["prefixPos"] := prefixFirst[pf]
        }
        rows := cable["rows"]
        cable["kind"] := rows.Length = 1 ? "single" : (rows.Length = 2 && CableSortMirror(rows[1], rows[2])) ? "pair" : "problem"
    }
    return cables
}

; “191-195”“191”或空；返回 [下限, 上限]、空数组（不限）或 ""（写错）
CableSortParseRange(text) {
    text := RegExReplace(text, "\s+")
    if (text = "")
        return []
    if RegExMatch(text, "^(\d{1,9})$", &m)
        return [Integer(m[1]), Integer(m[1])]
    if RegExMatch(text, "^(\d{1,9})[-~～—－](\d{1,9})$", &m)
        return [Min(Integer(m[1]), Integer(m[2])), Max(Integer(m[1]), Integer(m[2]))]
    return ""
}

CableSortNewRule(prefix, range, cabinet, source := "本工程") {
    r := CableSortParseRange(range)
    if !IsObject(r)
        throw Error("编号范围写法不对：" . range . "（应为 191-195 或单个号码）")
    return Map("prefix", Trim(prefix), "range", r.Length ? (r[1] = r[2] ? r[1] . "" : r[1] . "-" . r[2]) : ""
        , "lo", r.Length ? r[1] : "", "hi", r.Length ? r[2] : "", "cabinet", CableSortDisplay(cabinet), "source", source)
}

; 匹配规则：同前缀中带编号范围且命中的优先，其次不带范围的；同级取靠前的。返回规则序号，0 为没有
CableSortFindRule(cable, rules) {
    parsed := cable["parsed"]
    if !IsObject(parsed)
        return 0
    plain := 0
    for i, r in rules {
        if (CableSortNorm(r["prefix"]) != parsed["prefix"])
            continue
        if (r["lo"] != "") {
            if (parsed["num"] >= r["lo"] && parsed["num"] <= r["hi"])
                return i
        } else if !plain {
            plain := i
        }
    }
    return plain
}

; 定规则、保留端和状态：ok 按规则 / manual 手动指定保留端 / nomatch 两端都不是规则起点柜 / fixed 其他行（不变）
; / norule 没有规则 / unparsed 编号格式无法识别 / problem 编号重复或两端对不上
CableSortResolve(cable, rules, keepManual := true) {
    if (cable["kind"] = "fixed")
        return
    if !keepManual
        cable["manualKeep"] := false, cable["flip"] := false
    cable["rule"] := CableSortFindRule(cable, rules)
    ; 排序用：该前缀第一条规则的序号（不看编号范围），0 为该前缀没有规则
    cable["prefixRule"] := 0
    if IsObject(cable["parsed"])
        for i, r in rules
            if (CableSortNorm(r["prefix"]) = cable["parsed"]["prefix"]) {
                cable["prefixRule"] := i
                break
            }
    hits := []
    if cable["rule"] {
        target := CableSortNorm(rules[cable["rule"]]["cabinet"])
        for i, row in cable["rows"]
            if (CableSortNorm(CableSortCell(row, 1)) = target)
                hits.Push(i)
    }
    if !cable["manualKeep"]
        cable["keep"] := hits.Length ? hits[1] : 1
    if (cable["kind"] = "problem")
        cable["status"] := "problem"
    else if cable["manualKeep"]
        cable["status"] := "manual"
    else if cable["rule"]
        cable["status"] := hits.Length ? "ok" : "nomatch"
    else
        cable["status"] := IsObject(cable["parsed"]) ? "norule" : "unparsed"
}

CableSortResolveAll(cables, rules, keepManual := true) {
    for cable in cables
        CableSortResolve(cable, rules, keepManual)
}

CableSortKeepRow(cable) {
    return cable["rows"][cable["keep"]]
}

; 导出时的起点 / 终点：保留行的第 1 / 3 列；单行电缆对调过（flip）则反过来
CableSortStartCell(cable) {
    return CableSortCell(CableSortKeepRow(cable), cable.Has("flip") && cable["flip"] ? 3 : 1)
}

CableSortEndCell(cable) {
    return CableSortCell(CableSortKeepRow(cable), cable.Has("flip") && cable["flip"] ? 1 : 3)
}

; 对调起点和终点：两行以上的电缆轮换保留哪一行；只有一行的电缆导出时对调起点、终点两列（result 里写 框号:行号:R）。
; 其他行不处理，返回是否对调了
CableSortFlip(cable, rules) {
    if (cable["kind"] = "fixed")
        return false
    if (cable["rows"].Length >= 2)
        cable["keep"] := Mod(cable["keep"], cable["rows"].Length) + 1
    else
        cable["flip"] := !(cable.Has("flip") && cable["flip"])
    cable["manualKeep"] := true
    CableSortResolve(cable, rules, true)
    return true
}

; 排序键：凡“前缀-号码”格式的电缆都按 前缀分组 → 号码 → 尾缀 → 原先后 自然排序（不管有没有命中规则），
; 前缀分组的先后：有规则的前缀按其第一条规则的顺序，没有规则的前缀排在后面、按该前缀在清册里首次出现的先后；
; 编号无法识别的电缆随后按原先后，其他行最后
CableSortKey(cable) {
    p := cable["parsed"]
    if IsObject(p) {
        rank := cable.Has("prefixRule") && cable["prefixRule"] ? cable["prefixRule"] : 99999
        ppos := cable.Has("prefixPos") ? cable["prefixPos"] : cable["pos"]
        return "0" . Format("{:05}{:07}{:010}{:-10}{:07}", rank, ppos, p["num"], SubStr(p["suffix"], 1, 10), cable["pos"])
    }
    return (cable["kind"] = "fixed" ? "2" : "1") . Format("{:07}", cable["pos"])
}

CableSortSortList(list) {
    if (list.Length < 2)
        return list.Clone()
    text := ""
    for i, cable in list
        text .= CableSortKey(cable) . "`t" . i . "`n"
    out := []
    for line in StrSplit(Sort(RTrim(text, "`n"), "C"), "`n")
        out.Push(list[Integer(StrSplit(line, "`t")[2])])
    return out
}

; 按排序键插到第一个比它大的条目前（不打乱已有的手动顺序）
CableSortInsertSorted(list, cable) {
    key := CableSortKey(cable)
    for i, c in list
        if (StrCompare(CableSortKey(c), key, true) > 0) {
            list.InsertAt(i, cable)
            return
        }
    list.Push(cable)
}

; 规格比较用：去空白、大写，乘号的各种写法（x X * ＊ ×）统一成 ×
CableSortSpecNorm(s) {
    return RegExReplace(CableSortNorm(s), "[X*＊]", "×")
}

; 搜索：空格分隔多个词，每个词都要命中编号、任一行的起点/终点柜名或规格之一（不分大小写、忽略空格）
CableSortQueryMatch(cable, query) {
    for term in StrSplit(Trim(RegExReplace(query, "[\s\x{3000}]+", " ")), " ") {
        if (term = "")
            continue
        t := CableSortNorm(term), ts := CableSortSpecNorm(term), hit := InStr(CableSortNorm(cable["id"]), t)
        if !hit
            for row in cable["rows"]
                if InStr(CableSortNorm(CableSortCell(row, 1)), t) || InStr(CableSortNorm(CableSortCell(row, 3)), t)
                    || InStr(CableSortSpecNorm(CableSortCell(row, 4)), ts) {
                    hit := true
                    break
                }
        if !hit
            return false
    }
    return true
}

; 气泡默认按编号自动排序；用户在气泡内手动拖动过（manual）才保留手动顺序
CableSortTidy(bubble) {
    if !(bubble.Has("manual") && bubble["manual"])
        bubble["items"] := CableSortSortList(bubble["items"])
}

; 初始气泡：每个分类框一个气泡（名称取框的分类名称，没有分类框时为“全部”）。
; 按规则或手动定了保留端的电缆放进保留行所在框的气泡，其他行放进所在框的气泡；待处理的电缆留在“未分类”。
; 条目的 bubble：0 未分类，-1 已删除（不显示、不导出，保持删除），其他为所在气泡的 id。
CableSortInitialBubbles(job, cables) {
    bubbles := []
    for b, box in job["boxes"]
        bubbles.Push(Map("id", b, "name", box["title"] != "" ? box["title"] : "全部", "box", b, "items", [], "manual", false))
    for cable in cables {
        if (cable["bubble"] = -1)
            continue
        cable["bubble"] := 0
        if (cable["status"] = "ok" || cable["status"] = "manual" || cable["status"] = "fixed") {
            b := CableSortKeepRow(cable)["box"]
            bubbles[b]["items"].Push(cable)
            cable["bubble"] := bubbles[b]["id"]
        }
    }
    for bubble in bubbles
        bubble["items"] := CableSortSortList(bubble["items"])
    return bubbles
}

; 生成 result.txt：每个有条目的气泡一行 CAT 名称 框号:行号…（框号、行号从 0 开始）。
; 单行电缆对调了起终点写成 框号:行号:R，这时用第 3 版；没有对调的仍写第 2 版，旧插件也能用
CableSortBuildResult(job, bubbles) {
    body := "", seen := Map(), ver := 2
    for bubble in bubbles {
        if !bubble["items"].Length
            continue
        name := RegExReplace(Trim(bubble["name"]), "[`t`r`n]+", " ")
        line := "CAT`t" . name
        for cable in bubble["items"] {
            row := CableSortKeepRow(cable)
            ref := (row["box"] - 1) . ":" . row["idx"]
            if seen.Has(ref)
                throw Error("同一行出现在两个气泡里：" . cable["id"])
            seen[ref] := true
            if (cable.Has("flip") && cable["flip"])
                ref .= ":R", ver := 3
            line .= "`t" . ref
        }
        body .= line . "`r`n"
    }
    if !seen.Count
        throw Error("气泡里没有电缆，没有可导出的内容。")
    return "AAYSDL3RESULT`t" . ver . "`r`nID`t" . job["id"] . "`r`n" . body
}

; 自动推断：某前缀还没有任何规则时，若有一个柜子出现在该前缀全部电缆上，推断它为起点柜。按前缀首次出现的先后返回新规则
CableSortInfer(cables, rules) {
    have := Map()
    for r in rules
        have[CableSortNorm(r["prefix"])] := true
    groups := Map(), seen := []
    for cable in cables {
        p := cable["parsed"]
        if (!IsObject(p) || have.Has(p["prefix"]))
            continue
        if !groups.Has(p["prefix"]) {
            groups[p["prefix"]] := []
            seen.Push(p["prefix"])
        }
        groups[p["prefix"]].Push(cable)
    }
    out := []
    for prefix in seen {
        inter := "", names := Map()
        for cable in groups[prefix] {
            set := CableSortCabinets(cable, names)
            if !IsObject(inter) {
                inter := set
            } else {
                next := Map()
                for n in inter
                    if set.Has(n)
                        next[n] := true
                inter := next
            }
            if (inter.Count = 0)
                break
        }
        if (inter.Count = 1)
            for n in inter
                out.Push(CableSortNewRule(prefix, "", names[n], "推断"))
    }
    return out
}

; 一根电缆两端出现的柜子（规范化名 → true），names 记规范化名 → 显示名
CableSortCabinets(cable, names) {
    set := Map()
    for row in cable["rows"] {
        for col in [1, 3] {
            t := CableSortCell(row, col), n := CableSortNorm(t)
            if (n = "")
                continue
            set[n] := true
            if !names.Has(n)
                names[n] := CableSortDisplay(t)
        }
    }
    return set
}

; 给规则编辑框的候选柜子：同前缀电缆两端的柜子，按覆盖的电缆数从多到少
CableSortCandidates(cables, cable) {
    names := Map(), counts := Map()
    p := cable["parsed"]
    for c in cables {
        if !(ObjPtr(c) = ObjPtr(cable) || (IsObject(p) && IsObject(c["parsed"]) && c["parsed"]["prefix"] = p["prefix"]))
            continue
        for n in CableSortCabinets(c, names)
            counts[n] := (counts.Has(n) ? counts[n] : 0) + 1
    }
    text := ""
    for n, cnt in counts
        text .= Format("{:07}", 9999999 - cnt) . "`t" . names[n] . "`n"
    out := []
    if (text != "")
        for line in StrSplit(Sort(RTrim(text, "`n")), "`n")
            out.Push(StrSplit(line, "`t")[2])
    return out
}

; ---------- 整理进度（自动保存，下次继续） ----------
; 文件：dwg 所在文件夹的“电缆排序进度-<图名>.txt”，UTF-8、TAB 分隔：
;   AAYSDL3PROGRESS 1 / DWG 路径 / TIME 时间
;   RULE 前缀 编号范围 起点柜 来源
;   BUBBLE 气泡号 名称 对应分类框名称（新增的气泡为空） 是否手动调整过顺序（1/0；旧文件没有这一列，按 0 处理即重新按编号排序）
;   ITEM 气泡号 条目键（按气泡内顺序）
;   CABLE 条目键 状态（气泡号 / 0 未分类 / -1 已删除） 起点（规范化） 是否手动指定起点 单行电缆是否对调起终点（旧文件没有第 6 列按 0）
; 条目键：电缆为规范化编号，其他行为规范化内容加出现次序。重新运行 YSDL3（行号变了）也按键对上。

CableSortProgressPath(dwg) {
    SplitPath(dwg, , &dir, , &name)
    return dir . "\电缆排序进度-" . name . ".txt"
}

CableSortTabSafe(s) {
    return RegExReplace(s, "[`t`r`n]+", " ")
}

CableSortSerializeProgress(job, cables, rules, bubbles) {
    text := "AAYSDL3PROGRESS`t1`r`nDWG`t" . job["dwg"] . "`r`nTIME`t" . FormatTime(, "yyyy-MM-dd HH:mm:ss") . "`r`n"
    for r in rules
        text .= "RULE`t" . CableSortTabSafe(r["prefix"]) . "`t" . r["range"] . "`t" . CableSortTabSafe(r["cabinet"]) . "`t" . r["source"] . "`r`n"
    for b in bubbles {
        boxTitle := b["box"] ? job["boxes"][b["box"]]["title"] : ""
        text .= "BUBBLE`t" . b["id"] . "`t" . CableSortTabSafe(b["name"]) . "`t" . CableSortTabSafe(boxTitle) . "`t" . (b.Has("manual") && b["manual"] ? 1 : 0) . "`r`n"
        for cable in b["items"]
            text .= "ITEM`t" . b["id"] . "`t" . cable["key"] . "`r`n"
    }
    for cable in cables
        text .= "CABLE`t" . cable["key"] . "`t" . cable["bubble"] . "`t"
            . CableSortNorm(CableSortStartCell(cable)) . "`t" . (cable["manualKeep"] ? 1 : 0) . "`t" . (cable.Has("flip") && cable["flip"] ? 1 : 0) . "`r`n"
    return text
}

CableSortParseProgress(text) {
    prog := Map("time", "", "dwg", "", "rules", [], "bubbles", [], "cables", Map())
    head := false
    for line in StrSplit(text, "`n", "`r") {
        f := StrSplit(line, "`t")
        if (f.Length = 0)
            continue
        switch f[1] {
            case "AAYSDL3PROGRESS", Chr(0xFEFF) . "AAYSDL3PROGRESS":
                head := true
            case "TIME":
                prog["time"] := f.Length >= 2 ? f[2] : ""
            case "DWG":
                prog["dwg"] := f.Length >= 2 ? f[2] : ""
            case "RULE":
                if (f.Length >= 5)
                    try prog["rules"].Push(CableSortNewRule(f[2], f[3], f[4], f[5]))
            case "BUBBLE":
                if (f.Length >= 4)
                    prog["bubbles"].Push(Map("id", Integer(f[2]), "name", f[3], "boxTitle", f[4], "keys", [], "manual", f.Length >= 5 && f[5] = "1"))
            case "ITEM":
                if (f.Length >= 3)
                    for b in prog["bubbles"]
                        if (b["id"] = Integer(f[2]))
                            b["keys"].Push(f[3])
            case "CABLE":
                if (f.Length >= 5)
                    prog["cables"][f[2]] := [Integer(f[3]), f[4], f[5] = "1", f.Length >= 6 && f[6] = "1"]
        }
    }
    if !head
        throw Error("不是有效的电缆排序进度文件。")
    return prog
}

; 按进度恢复：规则、气泡（名称、顺序、条目）、删除、手动保留端。进度里没有的新条目按规则放进对应分类框的气泡（没有就留在未分类）。
; 返回 Map(rules, bubbles, nextId, restored 对上的条目数, added 新条目数, missing 进度里有、这次没有的条目数)
CableSortApplyProgress(job, cables, prog) {
    rules := prog["rules"]
    byKey := Map()
    for cable in cables {
        byKey[cable["key"]] := cable
        cable["bubble"] := 0, cable["manualKeep"] := false, cable["flip"] := false
    }
    CableSortResolveAll(cables, rules, false)
    restored := 0, missing := 0
    for key, v in prog["cables"] {
        if !byKey.Has(key) {
            missing++
            continue
        }
        cable := byKey[key]
        restored++
        if (v[3] && v[4] && cable["rows"].Length = 1 && cable["kind"] != "fixed") {
            cable["flip"] := true, cable["manualKeep"] := true
            CableSortResolve(cable, rules, true)
        } else if v[3] {
            for i, row in cable["rows"]
                if (CableSortNorm(CableSortCell(row, 1)) = v[2]) {
                    cable["keep"] := i, cable["manualKeep"] := true
                    break
                }
            CableSortResolve(cable, rules, true)
        }
        if (v[1] = -1)
            cable["bubble"] := -1
    }
    bubbles := [], nextId := 1
    for pb in prog["bubbles"] {
        box := 0
        if (pb["boxTitle"] != "")
            for bi, jb in job["boxes"]
                if (jb["title"] = pb["boxTitle"] || (jb["title"] = "" && pb["boxTitle"] = "全部")) {
                    box := bi
                    break
                }
        b := Map("id", pb["id"], "name", pb["name"], "box", box, "items", [], "manual", pb["manual"])
        for key in pb["keys"]
            if (byKey.Has(key) && byKey[key]["bubble"] = 0) {
                b["items"].Push(byKey[key])
                byKey[key]["bubble"] := b["id"]
            }
        bubbles.Push(b)
        nextId := Max(nextId, pb["id"] + 1)
    }
    ; 新条目：按规则放进保留行所在框的气泡
    added := 0
    for cable in cables {
        if prog["cables"].Has(cable["key"])
            continue
        added++
        if !(cable["status"] = "ok" || cable["status"] = "manual" || cable["status"] = "fixed")
            continue
        box := CableSortKeepRow(cable)["box"]
        for b in bubbles
            if (b["box"] = box) {
                CableSortInsertSorted(b["items"], cable)
                cable["bubble"] := b["id"]
                break
            }
    }
    for b in bubbles
        CableSortTidy(b)
    return Map("rules", rules, "bubbles", bubbles, "nextId", nextId, "restored", restored, "added", added, "missing", missing)
}

CableSortRulesPath(dwg) {
    SplitPath(dwg, , &dir)
    return dir . "\电缆排序规则.txt"
}

; 本工程规则文件：UTF-8，TAB 分隔，表头“前缀 编号范围 起点柜”
CableSortLoadRules(path) {
    rules := []
    if !FileExist(path)
        return rules
    for line in StrSplit(FileRead(path, "UTF-8"), "`n", "`r") {
        p := StrSplit(line, "`t")
        if (p.Length < 3 || p[1] = "前缀" || Trim(p[1]) = "" || Trim(p[3]) = "")
            continue
        try rules.Push(CableSortNewRule(p[1], p[2], p[3], "本工程"))
    }
    return rules
}

CableSortSaveRules(path, rules) {
    text := "前缀`t编号范围`t起点柜`r`n"
    for r in rules
        text .= r["prefix"] . "`t" . r["range"] . "`t" . r["cabinet"] . "`r`n"
    tmp := path . ".tmp"
    f := FileOpen(tmp, "w", "UTF-8")
    f.Write(text)
    f.Close()
    FileMove(tmp, path, 1)
}

; ---------- CSV 模式：打开 YSDL / YSDL2 / YSDL3 导出的 CSV 重新整理，另存为新 CSV（不经过 CAD，用户 2026-11-10 要求） ----------
; 插件导出的 CSV 没有表头。有分类框：分类,序号,安装单位,编号,芯数,型号,起点,终点,原理号…；
; 没有分类框：编号,芯数,型号,起点,终点,…；不足 5 格的行（其他行）原样（有分类框时前面加 分类,序号,第 1 格）。
; 读入后还原成清册行的单元格顺序（起点、编号、终点、规格、芯数、原理号…），窗口照常使用；每一行单独成一个条目，不配对。

; 读文本：有 BOM 或是合法 UTF-8 按 UTF-8，否则按 GBK（中望写的 CSV 是 GBK）
CableSortReadTextAuto(path) {
    buf := FileRead(path, "RAW")
    if (buf.Size >= 3 && NumGet(buf, 0, "UChar") = 0xEF && NumGet(buf, 1, "UChar") = 0xBB && NumGet(buf, 2, "UChar") = 0xBF)
        return StrGet(buf.Ptr + 3, buf.Size - 3, "UTF-8")
    if (buf.Size = 0)
        return ""
    if DllCall("MultiByteToWideChar", "UInt", 65001, "UInt", 8, "Ptr", buf, "Int", buf.Size, "Ptr", 0, "Int", 0)  ; MB_ERR_INVALID_CHARS
        return StrGet(buf, buf.Size, "UTF-8")
    return StrGet(buf, buf.Size, "CP936")
}

; 一行 CSV 拆成字段（支持引号和引号内的 ""）
CableSortParseCsvLine(line) {
    out := [], cur := "", inQ := false, i := 1, n := StrLen(line)
    while (i <= n) {
        ch := SubStr(line, i, 1)
        if inQ {
            if (ch = '"') {
                if (SubStr(line, i + 1, 1) = '"')
                    cur .= '"', i++
                else
                    inQ := false
            } else {
                cur .= ch
            }
        } else if (ch = '"') {
            inQ := true
        } else if (ch = ",") {
            out.Push(cur), cur := ""
        } else {
            cur .= ch
        }
        i++
    }
    out.Push(cur)
    return out
}

CableSortCsvField(s) {
    return '"' . StrReplace(s, '"', '""') . '"'
}

; 读 CSV 生成任务（job["source"] = "csv"）；不是插件导出的格式时抛出错误
CableSortCsvToJob(path) {
    rows := []
    for line in StrSplit(CableSortReadTextAuto(path), "`n", "`r")
        if (Trim(line) != "")
            rows.Push(CableSortParseCsvLine(line))
    boxN := 0, plainN := 0
    for f in rows {
        boxN += f.Length >= 8 && RegExMatch(Trim(f[2]), "^\d+$") && CableSortIsCableId(f[4])
        plainN += f.Length >= 5 && CableSortIsCableId(f[1])
    }
    if (!boxN && !plainN)
        throw Error("没有认出电缆行。请选择 YSDL / YSDL2 / YSDL3 导出的 CSV（第 1 列为分类或电缆编号）。")
    box := boxN >= plainN
    job := Map("id", "CSV", "dwg", path, "mode", box ? "box" : "plain", "boxes", [], "source", "csv")
    byTitle := Map()
    for f in rows {
        title := box ? Trim(f[1]) : "全部"
        if (title = "")
            title := "未命名分类"
        if box
            cells := f.Length >= 8 ? [f[7], f[4], f[8], f[6], f[5]] : []
        else
            cells := f.Length >= 5 ? [f[4], f[1], f[5], f[3], f[2]] : []
        if cells.Length {
            loop f.Length - (box ? 8 : 5)
                cells.Push(f[A_Index + (box ? 8 : 5)])
        } else {                                     ; 不足 5 格的行原样
            loop f.Length - (box ? 3 : 0)
                cells.Push(f[A_Index + (box ? 3 : 0)])
        }
        if !byTitle.Has(title) {
            job["boxes"].Push(Map("title", title, "count", 0, "rows", []))
            byTitle[title] := job["boxes"].Length
        }
        b := byTitle[title], bx := job["boxes"][b]
        bx["rows"].Push(Map("box", b, "idx", bx["rows"].Length, "handles", "", "cells", cells, "key", ""))
        bx["count"] := bx["rows"].Length
    }
    return job
}

; CSV 模式的条目：每行单独一个（同编号出现多次的不合并，键后加 #2、#3…），不配对
CableSortBuildCsv(job) {
    cables := [], seen := Map(), prefixFirst := Map(), dup := 0
    for b, box in job["boxes"] {
        for row in box["rows"] {
            id := CableSortCell(row, 2), isCable := CableSortIsCableId(id)
            if isCable {
                base := CableSortNorm(id)
            } else {
                base := "#"
                for cell in row["cells"]
                    base .= "|" . CableSortNorm(cell)
            }
            seen[base] := (seen.Has(base) ? seen[base] : 0) + 1
            if (isCable && seen[base] > 1)
                dup++
            key := isCable ? (seen[base] > 1 ? base . "#" . seen[base] : base) : base . "#" . seen[base]
            cable := Map("key", key, "id", Trim(id), "rows", [row], "pos", cables.Length + 1
                , "parsed", isCable ? CableSortParseId(CableSortNorm(id)) : "", "kind", isCable ? "single" : "fixed"
                , "keep", 1, "manualKeep", false, "flip", false, "rule", 0, "status", isCable ? "" : "fixed", "bubble", 0)
            if IsObject(cable["parsed"]) {
                pf := cable["parsed"]["prefix"]
                if !prefixFirst.Has(pf)
                    prefixFirst[pf] := cable["pos"]
                cable["prefixPos"] := prefixFirst[pf]
            }
            row["key"] := key
            cables.Push(cable)
        }
    }
    job["dupCount"] := dup
    return cables
}

; CSV 模式的初始气泡：每个分类一个，保持 CSV 里的原顺序（记为手动调整，不自动重排）
CableSortCsvBubbles(job, cables) {
    bubbles := []
    for b, box in job["boxes"]
        bubbles.Push(Map("id", b, "name", box["title"], "box", b, "items", [], "manual", true))
    for cable in cables {
        if (cable["bubble"] = -1)
            continue
        b := CableSortKeepRow(cable)["box"]
        bubbles[b]["items"].Push(cable)
        cable["bubble"] := bubbles[b]["id"]
    }
    return bubbles
}

; 按气泡生成 CSV 文本，列格式同插件 YSDL3 导出：有分类框时 分类=气泡名、序号在每个气泡内按起点聚类重排；
; 单行电缆对调过起终点的交换起点、终点两列
; 按气泡生成导出的各行（每行一个字段数组），列格式同插件 aa:ysdl3-csv-rows：
; 分类框模式为 分类、序号（气泡内按起点聚类）、起点、编号、芯数、型号、起点、终点、其余列；无分类列模式为 编号、芯数、型号、起点、终点、其余列。
; clean 为真时按插件写出时的处理去掉“至”、修剪首尾空白（导出预览用）；另存 CSV 保持原样，与读入的 CSV 往返一致
CableSortExportRows(job, bubbles, clean := false) {
    box := job["mode"] = "box", rows := []
    for bubble in bubbles {
        seq := 0, prev := ""
        for cable in bubble["items"] {
            cells := CableSortKeepRow(cable)["cells"].Clone()
            if (cable.Has("flip") && cable["flip"] && cells.Length >= 3)
                t := cells[1], cells[1] := cells[3], cells[3] := t
            fields := []
            if (cells.Length >= 5) {
                fields.Push(cells[2], cells[5], cells[4], cells[1], cells[3])
                loop cells.Length - 5
                    fields.Push(cells[A_Index + 5])
            } else {
                for c in cells
                    fields.Push(c)
            }
            if box {
                start := cells.Length ? Trim(StrReplace(cells[1], "至")) : ""
                if (seq = 0 || start != prev)
                    seq++, prev := start
                fields.InsertAt(1, bubble["name"], seq . "", cells.Length ? cells[1] : "")
            }
            if clean
                for i, v in fields
                    fields[i] := Trim(StrReplace(v, "至"), " `t`r`n")
            rows.Push(fields)
        }
    }
    return rows
}

CableSortBuildCsvText(job, bubbles) {
    out := ""
    for fields in CableSortExportRows(job, bubbles) {
        line := ""
        for i, v in fields
            line .= (i > 1 ? "," : "") . CableSortCsvField(v)
        out .= line . "`r`n"
    }
    if (out = "")
        throw Error("气泡里没有电缆，没有可保存的内容。")
    return out
}
