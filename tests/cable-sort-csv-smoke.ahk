#Requires AutoHotkey v2.0
#Warn All, StdOut  ; 警告写到标准输出，不弹窗
; 电缆排序“打开 CSV 重新整理”冒烟测试：读插件导出的 CSV（GBK / UTF-8，有无分类列）、原样写回、窗口里对调和移动后另存、进度恢复。
; 不连接 CAD，窗口放屏幕外，文件都写在 %TEMP%。用法：AutoHotkey64.exe /ErrorStdOut tests\cable-sort-csv-smoke.ahk [真实 output.csv]
#Include ..\src\cable-sort.ahk

RunPanelCommand(callback) => callback()

failures := 0
Check(cond, what) {
    global failures
    if !cond {
        failures++
        FileAppend("FAIL: " . what . "`n", "*", "UTF-8")
    }
}

SetTimer(CableSortPoll, 0)
dir := A_Temp . "\cable-sort-csv-smoke"
DirCreate(dir)

SplitLines(text) => StrSplit(RTrim(StrReplace(text, "`r`n", "`n"), "`n"), "`n")

; 1. 有分类列（YSDL3 / 分类框模式），GBK，含编号重复、不足 5 格的其他行、带引号和开头 Tab 的字段
boxCsv := '"公用部分","1","网络通信柜","TX-02","2","通讯线","网络通信柜","安全稳定控制装置B柜","485+","485-"' . "`r`n"
    . '"公用部分","1","网络通信柜","TX-01","2","通讯线","网络通信柜","安全稳定控制装置A柜","485+","485-"' . "`r`n"
    . '"公用部分","2","关口计量柜","DB-01","4","4×4","关口计量柜","主变电度表柜","A""411","' . "`t" . '-5"' . "`r`n"
    . '"公用部分","3","公用测控柜","公用测控柜","2","701"' . "`r`n"
    . '"电源部分","1","事故照明柜","SG-01","2","2×4","事故照明柜","110kV GIS1#主变汇控柜","L1","N1"' . "`r`n"
    . '"电源部分","1","事故照明柜","TX-01","2","通讯线","事故照明柜","网络通信柜","485+","485-"' . "`r`n"
pBox := dir . "\有分类.csv"
f := FileOpen(pBox, "w", "CP936"), f.Write(boxCsv), f.Close()
job := CableSortCsvToJob(pBox)
Check(job["mode"] = "box" && job["boxes"].Length = 2 && job["boxes"][1]["title"] = "公用部分" && job["boxes"][1]["rows"].Length = 4, "识别分类列和分类")
r1 := job["boxes"][1]["rows"][1]["cells"]
Check(r1[1] = "网络通信柜" && r1[2] = "TX-02" && r1[3] = "安全稳定控制装置B柜" && r1[4] = "通讯线" && r1[5] = "2" && r1[6] = "485+", "还原成清册单元格顺序")
Check(job["boxes"][1]["rows"][3]["cells"][7] = "`t-5" && job["boxes"][1]["rows"][3]["cells"][6] = 'A"411', "引号和开头 Tab 原样保留")
cables := CableSortBuildCsv(job)
Check(cables.Length = 6 && job["dupCount"] = 1 && cables[6]["key"] = "TX-01#2" && cables[4]["kind"] = "fixed", "每行一个条目，重复编号不合并：" . cables.Length . "/" . job["dupCount"])
bubbles := CableSortCsvBubbles(job, cables)
Check(bubbles[1]["manual"] && bubbles[1]["items"][1]["id"] = "TX-02", "保持 CSV 原顺序")
Check(CableSortBuildCsvText(job, bubbles) = CableSortReadTextAuto(pBox), "有分类列原样写回")

; 2. 窗口：CSV 模式，对调单行电缆、移到别的分类后另存
CableSortOpen(job, "x-4000 y0 w1500 h880 NoActivate", "no", dir . "\progress.txt")
st := CableSortUi
Check(InStr(st["gui"].Title, "CSV") && st["ctl"]["apply"].Text = "另存 CSV…" && InStr(st["ctl"]["summary"].Value, "原文件和图纸都不动"), "CSV 模式窗口")
Check(st["bubbles"].Length = 2 && st["bubbles"][2]["items"].Length = 2, "按分类还原气泡")
db := st["byKey"]["DB-01"], sg := st["byKey"]["SG-01"]
CableSortSwapKeep(st, [db])
Check(db["flip"] && CableSortStartCell(db) = "主变电度表柜", "CSV 里对调起终点")
CableSortPlace(st, [sg], 1, -1)
out := dir . "\另存.csv"
try FileDelete(out)
CableSortSaveCsv(st, out)
raw := FileRead(out, "RAW")
Check(raw.Size > 3 && NumGet(raw, 0, "UChar") = 0xEF, "另存为 UTF-8 带 BOM")
lines := SplitLines(CableSortReadTextAuto(out))
dbLine := "", sgLine := ""
for l in lines
    if InStr(l, '"DB-01"')
        dbLine := l
    else if InStr(l, '"SG-01"')
        sgLine := l
Check(InStr(dbLine, '"主变电度表柜","DB-01","4","4×4","主变电度表柜","关口计量柜"'), "另存时起点终点对调：" . dbLine)
Check(SubStr(sgLine, 1, 6) = '"公用部分"' && lines.Length = 6, "移到别的分类后分类列跟着变：" . sgLine)
; 进度：关窗口自动保存，按进度恢复对调和分类
st["dirty"] := true
CableSortClose()
prog := CableSortParseProgress(FileRead(dir . "\progress.txt", "UTF-8"))
c2 := CableSortBuildCsv(job)
res := CableSortApplyProgress(job, c2, prog)
for c in c2
    if (c["key"] = "DB-01")
        Check(c["flip"], "进度恢复对调")
    else if (c["key"] = "SG-01")
        Check(c["bubble"] = res["bubbles"][1]["id"], "进度恢复分类")

; 3. 没有分类列（YSDL / 无分类框），UTF-8 带 BOM
plainCsv := '"1AW-131","8","10×1.5","安全稳定控制装置A柜","公用测控柜","1D1"' . "`r`n"
    . '"1AW-130","4","4×1.5","安全稳定控制装置A柜","公用测控柜"' . "`r`n"
pPlain := dir . "\无分类.csv"
f := FileOpen(pPlain, "w", "UTF-8"), f.Write(plainCsv), f.Close()
jp := CableSortCsvToJob(pPlain)
cp := CableSortBuildCsv(jp)
Check(jp["mode"] = "plain" && jp["boxes"].Length = 1 && cp.Length = 2 && cp[1]["rows"][1]["cells"][1] = "安全稳定控制装置A柜", "识别无分类列")
Check(CableSortBuildCsvText(jp, CableSortCsvBubbles(jp, cp)) = plainCsv, "无分类列原样写回")
try {
    bad := dir . "\不是.csv"
    f := FileOpen(bad, "w", "UTF-8"), f.Write("a,b,c`r`n1,2,3`r`n"), f.Close()
    CableSortCsvToJob(bad)
    Check(false, "不是插件导出的 CSV 应报错")
}

; 4. 可选：真实导出的 CSV 原样往返
if (A_Args.Length >= 1) {
    jr := CableSortCsvToJob(A_Args[1])
    cr := CableSortBuildCsv(jr)
    a := SplitLines(CableSortReadTextAuto(A_Args[1])), b := SplitLines(CableSortBuildCsvText(jr, CableSortCsvBubbles(jr, cr)))
    same := a.Length = b.Length
    loop Min(a.Length, b.Length)
        same := same && a[A_Index] = b[A_Index]
    Check(same, "真实 CSV 原样往返")
    FileAppend("INFO 真实 CSV：" . cr.Length . " 行，" . jr["boxes"].Length . " 个分类，重复编号 " . jr["dupCount"] . "`n", "*", "UTF-8")
}

try DirDelete(dir, true)
FileAppend(failures ? "FAIL (" . failures . ")`n" : "PASS cable-sort-csv`n", "*", "UTF-8")
ExitApp(failures ? 1 : 0)
