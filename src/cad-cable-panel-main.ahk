#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
; 电缆定义总览独立版：常驻托盘，向导写入新总览时自动弹出。不装主面板的电脑用它，也是打包 EXE 的入口。
#Include modern-panel-ui.ahk
#Include cad-cable-panel.ahk

A_IconTip := "电缆定义总览"
A_TrayMenu.Delete()
A_TrayMenu.Add("显示总览", CablePanelOpen)
A_TrayMenu.Add("退出", (*) => ExitApp())
A_TrayMenu.Default := "显示总览"
CablePanelInit()

; ModernPanelTile 用到的主面板包装函数，这里只需直接调用
RunPanelCommand(callback) {
    callback()
}
