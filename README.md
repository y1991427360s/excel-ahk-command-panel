# Excel AHK 快捷功能面板

这是一个 AutoHotkey v2 脚本，用来把 Excel 相关快捷功能集中到一个面板里。

## 功能

- `Ctrl+Shift+E`：打开 Excel 快捷功能面板
- 面板按钮：添加前缀
- 面板按钮：去重整理
- 脚本操作后可按 `Ctrl+Z` 撤销最近一次脚本操作
- 所有快捷键只在活动窗口是 Excel 时生效

说明：Excel COM 写入会清空 Excel 原生撤销栈，所以脚本内部记录最近 10 次脚本操作的快照。按 `Ctrl+Z` 时，如果存在脚本操作快照，就恢复最近一次脚本修改；如果没有脚本快照，就把 `Ctrl+Z` 交回 Excel 原生处理。

## 安装

在 PowerShell 中运行：

```powershell
Set-Location E:\366256\vibecoding\excel-ahk-command-panel
.\install.ps1
```

安装脚本会：

- 把主脚本复制到 `D:\Users\ys199\Documents\AutoHotkey\excel-command-panel.ahk`
- 创建开机启动项 `excel-command-panel.lnk`
- 停用旧的 `excel-prefix-selected-cells.lnk` 和 `excel-dedupe-sort-b-column.lnk`
- 重启相关 AutoHotkey 进程

旧脚本文件会保留，只停用旧启动项，避免同一快捷键被多个脚本同时监听。

## 后续添加功能

以后新增 Excel 快捷功能时，优先在 `src\excel-command-panel.ahk` 中新增函数，然后在 `ShowExcelCommandPanel()` 里增加按钮。统一入口只保留 `Ctrl+Shift+E`。
