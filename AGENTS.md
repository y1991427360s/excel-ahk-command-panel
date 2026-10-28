# 项目规则

## 项目定位

- 本项目是 Windows 上的 AutoHotkey v2 全局自动化面板，唯一入口为 `Ctrl+Shift+E`。
- 主脚本是 `src/excel-command-panel.ahk`；`install.ps1` 创建启动项并直接运行该文件，不复制脚本副本。
- 用户文档与使用方法以 `README.md` 为准；新增或修改用户流程时必须同步更新 README。

## 表格兼容边界

- Microsoft Excel 使用 `Excel.Application`，WPS 表格使用 `Ket.Application`。
- 连接表格时必须优先识别当前前台窗口，再回退到打开面板时记录的窗口；Excel 与 WPS 同时运行时不能猜测目标应用。
- 表格功能不得自动保存工作簿。正常成功不弹完成提示，只在输入、确认、参数错误或失败时提示。
- COM 写入会影响原生撤销栈。Excel 的 `Ctrl+Z` 先保留原生撤销；WPS 因缺少可靠的 `CommandBars` 状态查询，脚本撤销只走面板按钮。

## 电缆排序规则

- 排序记录固定由相邻两列组成：左列“电缆型号及截面”，右列“电缆长度”。只选型号列时自动包含右侧长度列；选择超过两列必须拒绝。
- 型号与长度必须作为一条记录同步移动，撤销也必须同时恢复。
- 排序键依次为有效截面、总芯数、复合主截面、复合辅助截面和原始行号；无法识别的记录保持相对顺序并移到末尾。
- `3×25+1×16` 按截面 25；`3×50+1×25` 是明确例外，也归入截面 25。不要擅自推广成所有复合电缆都取较小截面。

## 单元格合并与拆分规则

- “合并相同内容并居中”支持连续多列选区，但必须逐列独立纵向分组，禁止横向合并。
- 横向分页符是强制分组边界；分页符上下内容即使相同也必须分别合并，不能跨页。
- 选择整列时只处理选区与 `UsedRange` 的交集，内容使用区域批量读取，禁止逐格扫描整列造成卡顿。
- “合并相同内容并居中”须保持 `Range.MergeCells != false` $O(1)$ 预检、选区整体广播居中对齐（`-4108`）及逗号拼接分批 `.Merge()`（每批 $\le 240$ 字符），禁止逐块重复设置对齐或逐格检查合并状态。
- “拆分合并单元格并填充”拆分后必须把原合并区域左上角内容一次性填入该区域全部单元格，并保留脚本撤销能力；优先走 `Range.Value(11)` (`xlRangeValueXMLSpreadsheet`) 内存解析合并坐标 + SafeArray 矩阵一次性写回，不支持时自动回退高剪枝 COM 扫描，禁止逐格访问 `cell.MergeArea`。
- 批量合并、拆分及撤销期间必须临时关闭 `DisplayPageBreaks := false` 与 `Calculation := -4135`；读取 `HPageBreaks` 后必须恢复原视图与分页状态，禁止将工作表常驻留在 `ActiveWindow.View := 2`（分页预览），否则会触发网络打印机驱动重算导致严重卡顿或无头进程死锁。

## 文件工具边界

- 文件批量改名只处理资源管理器或桌面中选中的文件，跳过文件夹，保留扩展名。
- 执行前必须检查目标重名和已存在冲突，并展示预览要求确认。
- 文件名文字替换按普通字符串匹配，不区分大小写，只替换文件主名、不触碰扩展名；替换内容允许为空以删除匹配文字。
- DWG 打开功能只读取打开面板前的资源管理器或桌面选区，只把选中的 `.dwg` 路径传给用户选择的 CAD 软件，不修改或保存图纸。
- “强制关闭 / 保存并关闭 / 保存并重开”三个按钮必须单独成组，且不得与“重载插件”按钮相邻（中间隔其他分组），防止误点关闭图纸；它们只作用于运行中 CAD 的当前活动图纸：优先打开面板前所在的 CAD 窗口，中望 CAD 与 AutoCAD 同时运行且不在 CAD 窗口时不能猜测目标；`CMDACTIVE ≠ 0` 时拒绝；强制关闭按用户要求不弹确认（2026-10-28）；保存失败不得关闭图纸，未命名或只读图纸不得保存。保存必须通过 `SendCommand` 让 CAD 执行原生 `_.QSAVE`（随后 `_.CLOSE`），禁止从面板进程调用 COM `Document.Save()`（中望 CAD 2026 保存大图时会崩溃，2026-10-28 实测）；强制关闭用 COM `Close(False)` 已实测正常。
- Windows 11 的 `Shell.Application.SelectedItems` 可能返回旧标签页或旧选中项；DWG 当前选区必须通过资源管理器原生 `Ctrl+C` 读取，并恢复原剪贴板、避免写入 CopyQ 历史。
- 合并 PDF 时按资源管理器原生 `Ctrl+C` 取得的选择顺序处理，输出到首个 PDF 所在目录；通过临时 Python 脚本调用 `pypdf`，不修改源文件，覆盖目标前必须明确确认。
- Word 转 PDF 支持 `.doc`、`.docx`、`.docm`，通过 Microsoft Word COM 以只读方式导出到源文件同目录；覆盖同名 PDF 前必须明确确认，禁止保存或修改源文档。
- Excel 转 PDF 支持 `.xls`、`.xlsx`、`.xlsm`、`.xlsb`，通过 Microsoft Excel COM 将整个工作簿（含隐藏工作表）导出为一个同目录同名 PDF；工作簿只读打开、不保存，临时显示的隐藏工作表必须恢复原状态，覆盖目标前必须明确确认。
- 面板打开时只读取一次当前窗口 Ctrl+C 产生的原生 `CF_HDROP` 文件列表并保存选区快照；面板功能统一使用该快照，不在按钮执行时重读剪贴板或回退到可能过期的 Shell `SelectedItems`。Word 转换按路径去重，多文件时先展示清单确认。

## AutoHotkey v2 语法红线与验证部署

- AutoHotkey v2 判断字符串类型必须使用 `Type(val) = "String"`（无内置 `IsString()` 函数，误写会触发 `#Warn` 模态弹窗阻塞进程）；比较运算符仅支持 `=` / `==` / `!=` / `!==` 中的合法形式，严禁使用 JavaScript 的 `===`。
- 修改 AHK 后必须先执行静态加载检查：`& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /iLib nul /ErrorStdOut src\excel-command-panel.ahk`。
- 自动化回归测试套件：`tests\merge-split-benchmark.ahk`（合并/拆分 1000 行性能基准与撤销回归）与 `tests\spreadsheet-export-smoke.ahk`（选区信息导出冒烟测试）。
- 安装或热重载运行 `powershell -ExecutionPolicy Bypass -File .\install.ps1`。
- 启动项必须是 `excel-command-panel.lnk`，且启动文件夹内不能遗留 `.disabled` 等会被当作启动项的文件；系统自带的 `desktop.ini` 除外。
