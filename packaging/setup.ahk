#Requires AutoHotkey v2.0
#SingleInstance Ignore
global SetupLog := EnvGet("LOCALAPPDATA") . "\SpreadsheetToolsShare-install.log"
global SetupQuiet := false
try {
    mode := A_Args.Length ? A_Args[1] : "install"
    installRoot := EnvGet("LOCALAPPDATA") . "\SpreadsheetToolsShare"
    shortcutRoot := ""
    noShortcuts := false
    noLaunch := false
    i := 2
    while i <= A_Args.Length {
        argument := A_Args[i]
        if argument = "--root" || argument = "--shortcut-root" {
            i += 1
            if i > A_Args.Length
                throw Error("安装参数缺少路径。")
            if argument = "--root"
                installRoot := A_Args[i]
            else
                shortcutRoot := A_Args[i]
        } else if argument = "--no-shortcuts"
            noShortcuts := true
        else if argument = "--no-launch"
            noLaunch := true
        else if argument = "--quiet"
            SetupQuiet := true
        else
            throw Error("无法识别的安装参数：" . argument)
        i += 1
    }
    if !RegExMatch(installRoot, "i)^[A-Z]:\\.+\\SpreadsheetToolsShare$")
        throw Error("安装目录不符合预期：" . installRoot)
    LogSetup("开始 " . mode . "；目录=" . installRoot)
    if mode = "install"
        InstallShare(installRoot, noShortcuts, noLaunch, shortcutRoot)
    else if mode = "uninstall"
        UninstallShare(installRoot, noShortcuts, shortcutRoot)
    else
        throw Error("无法识别的操作：" . mode)
    LogSetup("完成 " . mode)
    if !SetupQuiet
        MsgBox(mode = "install"
            ? "安装成功！`n`n打开 Excel 或 WPS，选中单元格，再按 Ctrl+Shift+E。`n`n已创建桌面入口和开机启动项。"
            : "卸载完成。", "表格工具面板", "Iconi")
    ExitApp(0)
} catch as err {
    details := err.Message . "`n位置：" . err.What . "`n行号：" . err.Line
    try LogSetup("失败：" . details)
    if !SetupQuiet
        MsgBox("安装或卸载失败：`n`n" . details . "`n`n日志：" . SetupLog, "表格工具面板", "Iconx")
    try FileAppend(details . "`n", "**", "UTF-8")
    ExitApp(1)
}

InstallShare(root, noShortcuts, noLaunch, shortcutRoot) {
    if !A_Is64bitOS
        throw Error("此安装包需要 64 位 Windows。")
    entries := []
    seen := Map()
    for line in StrSplit(FileRead(A_ScriptDir . "\manifest.sha256", "UTF-8"), "`n", "`r") {
        if Trim(line) = ""
            continue
        if !RegExMatch(line, "i)^([a-f0-9]{64})  ([a-z0-9_.-]+)$", &match)
            throw Error("安装包文件清单无效。")
        name := match[2]
        if seen.Has(name)
            throw Error("安装包文件清单重复。")
        seen[name] := true
        source := A_ScriptDir . "\app\" . name
        if FileSHA256(source) != StrLower(match[1])
            throw Error("文件损坏，请重新解压：" . name)
        entries.Push(Map("name", name, "hash", StrLower(match[1])))
    }
    if !seen.Has("AutoHotkey64.exe") || !seen.Has("spreadsheet-panel.ahk")
        throw Error("安装包缺少主程序。")
    StopInstalledShare(root)
    DirCreate(root)
    for entry in entries {
        name := entry["name"]
        FileCopy(A_ScriptDir . "\app\" . name, root . "\" . name, true)
        if FileSHA256(root . "\" . name) != entry["hash"]
            throw Error("复制后文件校验失败：" . name)
    }
    FileCopy(A_ScriptDir . "\使用说明.txt", root . "\使用说明.txt", true)
    if !noShortcuts {
        for directory in SetupShortcutDirectories(shortcutRoot) {
            DirCreate(directory)
            FileCreateShortcut(root . "\AutoHotkey64.exe", directory . "\表格工具面板（分享版）.lnk",
                root, Chr(34) . root . "\spreadsheet-panel.ahk" . Chr(34), "表格工具面板：Ctrl+Shift+E")
        }
    }
    if !noLaunch {
        Run(Chr(34) . root . "\AutoHotkey64.exe" . Chr(34) . " " . Chr(34) . root . "\spreadsheet-panel.ahk" . Chr(34), root, "", &pid)
        Sleep(1000)
        if !ProcessExist(pid)
            throw Error("主程序未能启动，请查看日志。")
    }
}

UninstallShare(root, noShortcuts, shortcutRoot) {
    StopInstalledShare(root)
    if !noShortcuts {
        for directory in SetupShortcutDirectories(shortcutRoot) {
            link := directory . "\表格工具面板（分享版）.lnk"
            if FileExist(link) {
                FileGetShortcut(link, &target)
                if StrLower(target) = StrLower(root . "\AutoHotkey64.exe")
                    FileDelete(link)
            }
        }
    }
    for name in ["AutoHotkey64.exe", "spreadsheet-panel.ahk", "AutoHotkey-license.txt", "AutoHotkey-source.txt", "AutoHotkey-source.zip", "使用说明.txt"] {
        path := root . "\" . name
        if FileExist(path)
            FileDelete(path)
    }
    if DirExist(root) {
        empty := true
        Loop Files root . "\*", "FD"
            empty := false
        if empty
            DirDelete(root)
    }
}

StopInstalledShare(root) {
    DetectHiddenWindows(true)
    for hwnd in WinGetList("ahk_class AutoHotkey") {
        title := WinGetTitle(hwnd)
        if InStr(StrLower(title), StrLower(root . "\spreadsheet-panel.ahk - AutoHotkey")) = 1 {
            pid := WinGetPID(hwnd)
            WinClose(hwnd)
            ProcessWaitClose(pid, 5)
            if ProcessExist(pid)
                throw Error("旧版面板未能退出。请从托盘退出旧版后重试。")
        }
    }
}

SetupShortcutDirectories(root) {
    return root = "" ? [A_Startup, A_Desktop] : [root . "\Startup", root . "\Desktop"]
}

LogSetup(text) {
    global SetupLog
    FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") . " " . text . "`r`n", SetupLog, "UTF-8")
}

FileSHA256(path) {
    provider := 0
    hash := 0
    try {
        if !DllCall("advapi32\CryptAcquireContextW", "Ptr*", &provider, "Ptr", 0, "Ptr", 0, "UInt", 24, "UInt", 0xF0000000)
            throw Error("无法初始化文件校验。")
        if !DllCall("advapi32\CryptCreateHash", "Ptr", provider, "UInt", 0x800C, "Ptr", 0, "UInt", 0, "Ptr*", &hash)
            throw Error("无法创建文件校验。")
        file := FileOpen(path, "r")
        file.Pos := 0 ; 校验包含 BOM 在内的原始字节。
        chunkBuffer := Buffer(1048576)
        while count := file.RawRead(chunkBuffer, chunkBuffer.Size) {
            if !DllCall("advapi32\CryptHashData", "Ptr", hash, "Ptr", chunkBuffer, "UInt", count, "UInt", 0)
                throw Error("无法校验文件：" . path)
        }
        file.Close()
        result := Buffer(32)
        size := result.Size
        if !DllCall("advapi32\CryptGetHashParam", "Ptr", hash, "UInt", 2, "Ptr", result, "UInt*", &size, "UInt", 0)
            throw Error("无法读取校验结果。")
        hex := ""
        Loop size
            hex .= Format("{:02x}", NumGet(result, A_Index - 1, "UChar"))
        return hex
    } finally {
        if hash
            DllCall("advapi32\CryptDestroyHash", "Ptr", hash)
        if provider
            DllCall("advapi32\CryptReleaseContext", "Ptr", provider, "UInt", 0)
    }
}
