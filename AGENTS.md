# 项目规则

## 项目定位

- 本项目是 Windows 上的 AutoHotkey v2 全局自动化面板，唯一入口默认为 `Ctrl+Shift+E`，用户可在面板“快捷键”页改成其他组合键（配置项 `panel.open`）。
- 主脚本是 `src/excel-command-panel.ahk`；`install.ps1` 创建启动项并直接运行该文件，不复制脚本副本。
- 用户文档与使用方法以 `README.md` 为准；新增或修改用户流程时必须同步更新 README。

## 工作流程文档联动

- 本面板是用户二次接线工作流程的一部分，流程说明在 `D:\Syncthing\Oracle-Sync\工作智能体\工作流程\AutoHotkey面板-CAD与表格辅助.md`（入口为该目录 `CLAUDE.md`）。
- 面板用途、按钮、与中望插件交换数据的文件格式或 LISP 接口变化时，同步更新该流程文档（含 frontmatter 的 `updated`）；涉及插件命令时同时遵守 `D:\Syncthing\Oracle-Sync\LISP\CLAUDE.md`。

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
- “合并相同内容并居中”须保持 `Range.MergeCells != false` $O(1)$ 预检及逗号拼接分批 `.Merge()`（每批 $\le 240$ 字符）；居中对齐（`-4108`）在同一批 Range 上设置，只作用于实际合并的块（选区里单独的单元格对齐不变），合并前按批读取原对齐写入撤销项（整批不一致时才逐块读），禁止逐块重复设置对齐或逐格检查合并状态（`MergeSpreadsheetBatchCentered`）。
- “拆分合并单元格并填充”拆分后必须把原合并区域左上角内容一次性填入该区域全部单元格，并保留脚本撤销能力；优先走 `Range.Value(11)` (`xlRangeValueXMLSpreadsheet`) 内存解析合并坐标（`ss:MergeAcross=k` 的单元格之后，省略 `ss:Index` 的下一格从 k+1 列后计）+ SafeArray 矩阵一次性写回，不支持时自动回退高剪枝 COM 扫描，禁止逐格访问 `cell.MergeArea`。矩阵写回只在 `areaRange.HasFormula` 为 False 时使用；含公式（True / 混合 / 读取失败）时逐个合并块写 `Value2`，左上角公式恢复为原 `FormulaR1C1`，撤销项也记 `FormulaR1C1`，避免把公式变成数值。
- 批量合并、拆分及撤销期间必须临时关闭 `DisplayPageBreaks := false` 与 `Calculation := -4135`；读取 `HPageBreaks` 后必须恢复原视图与分页状态，禁止将工作表常驻留在 `ActiveWindow.View := 2`（分页预览），否则会触发网络打印机驱动重算导致严重卡顿或无头进程死锁。

## 文件工具边界

- 文件批量改名只处理资源管理器或桌面中选中的文件，跳过文件夹，保留扩展名。
- 执行前必须检查目标重名和已存在冲突，并展示预览要求确认。
- 文件名文字替换（含“将 ML 替换为目录”）按普通字符串匹配，不区分大小写，只替换文件主名、不触碰扩展名；替换内容允许为空以删除匹配文字。
- DWG 打开功能只读取打开面板前的资源管理器或桌面选区，只把选中的 `.dwg` 路径传给用户选择的 CAD 软件，不修改或保存图纸。
- “强制关闭 / 保存并关闭 / 保存并重开”三个按钮必须单独成组，且不得与“重载插件”按钮相邻（中间隔其他分组），防止误点关闭图纸；它们只作用于运行中 CAD 的当前活动图纸：优先打开面板前所在的 CAD 窗口，中望 CAD 与 AutoCAD 同时运行且不在 CAD 窗口时不能猜测目标；`CMDACTIVE ≠ 0` 时拒绝；强制关闭按用户要求不弹确认（2026-10-28）；保存失败不得关闭图纸，未命名或只读图纸不得保存。保存必须通过 `SendCommand` 让 CAD 执行原生 `_.QSAVE`（随后 `_.CLOSE`），禁止从面板进程调用 COM `Document.Save()`（中望 CAD 2026 保存大图时会崩溃，2026-10-28 实测）；强制关闭用 COM `Close(False)` 已实测正常。
- “批量转可信 DWG”只把选区里的 `.dwg` 和文件夹写进临时清单，交给 `AutoCAD2018_lisp\tools\trusted_dwg_batch.py --from-file` 在可见命令行窗口运行；脚本用 `accoreconsole` 导出副本到 `可信DWG\`，不改原文件、不连接运行中的 CAD。转换逻辑只在该脚本维护，面板不复制一份。
- 桌面（Progman/WorkerW）在酷呆桌面运行时（`IsDesktopOrganizerRunning`）必须用 Ctrl+C，未运行时与资源管理器一样直接读 Shell 视图：酷呆桌面（Coodesker）接管桌面图标，系统桌面视图的 `GetSelection`/`SelectedItems` 停留在旧选中项（2026-11-06 实测读成 4 个文件，实际只选 1 个），代价是选中文件时图绳会多挂卡片。
- 资源管理器窗口选区用 `GetShellViewSelectedFilePaths` 读取：`IShellBrowser::QueryActiveShellView` → `IFolderView2::GetSelection`，完全不碰剪贴板。Win11 多标签共用一个 `CabinetWClass`，必须用 `IOleWindow::GetWindow` 与 `ShellTabWindowClass1`（当前标签）比对；跨进程 `IShellView::GetItemObject` 取 IDataObject 会返回 E_FAIL，不要用。原因：任何剪贴板写入（Ctrl+C 复制文件、写回原剪贴板）都会被图绳 PicRope 等不认排除标记的工具挂成新卡片（2026-11-06 用户反馈）。只有 Shell 方式抛错才回退到 Ctrl+C：回退时不清空剪贴板，用 `GetClipboardSequenceNumber` 判断是否写入，变了才用 `RestoreClipboardWithoutHistory` 写回。
- 合并 PDF 时用 `Ctrl+C` 取得选中文件后，按文件名自然排序（`StrCmpLogicalW`，与资源管理器“名称”排序一致）再合并，不依赖选择顺序；输出到首个 PDF 所在目录；通过临时 Python 脚本调用 `pypdf`，不修改源文件，覆盖目标前必须明确确认。
- 合并 PDF、图片合并为 PDF 和统计图幅都只通过 `PdfToolCommand()` 调用 `tools\pdf_tools.py`（`merge` / `images` / `sizes` 子命令；`images` 自写最小 PDF，PNG 以 IDAT 流 + Predictor 15 无损嵌入、JPEG 原样 DCTDecode，不引入 img2pdf/PyMuPDF）；分享版在 `packaging\share-panel.ahk` 覆盖该函数改用包内 `pdf-tools.exe`，不要在这两个功能里直接写 `python`。统计图幅：短边定基本图幅、长边按 0.25 倍取加长倍数，列顺序与《图纸打印明细》表头（A0 ~ A4 共 23 列）一致；压缩包只解压到临时目录，不改源文件。改判定规则时用真实图纸 PDF 回归验证。
- MP4 转 GIF 只通过 `tools\video_tools.py gif` 转换（ffmpeg 两遍调色板，优先 `imageio-ffmpeg` 自带 ffmpeg），输出同目录同名 `.gif`，先写临时文件再替换，覆盖前必须确认，不改源视频；分享版未包含。“压缩视频”同样只走 `video_tools.py compress`（x264 CRF，输出到源文件夹下“压缩视频\原名.mp4”，文件夹名在 `video_tools.py` 的 `COMPRESS_FOLDER` 与面板 `CompressSelectedVideos` 两处须一致，结果不比原文件小时不保留）；两个按钮共用 `GetSelectedVideoPaths` / `RunVideoTool`，不要再各写一份。用脚本改这几处源码时注意 `\video_tools`、`\video-tool-` 里的 `\v` 会被转义成控制字符（2026-11-06 踩坑），优先用编辑工具。
- Word 转 PDF 支持 `.doc`、`.docx`、`.docm`，通过 Microsoft Word COM 以只读方式导出到源文件同目录；覆盖同名 PDF 前必须明确确认，禁止保存或修改源文档。
- Excel 转 PDF 支持 `.xls`、`.xlsx`、`.xlsm`、`.xlsb`，通过 Microsoft Excel COM 将整个工作簿（含隐藏工作表）导出为一个同目录同名 PDF；工作簿只读打开、不保存，临时显示的隐藏工作表必须恢复原状态，覆盖目标前必须明确确认。
- PPT 转 PDF 支持 `.ppt`、`.pptx`、`.pptm`、`.pps`、`.ppsx`，通过 PowerPoint COM `Presentations.Open(路径, -1, 0, 0)`（只读、无窗口）+ `SaveAs(临时文件, 32)` 导出到同目录同名 PDF，再替换目标；不保存源文件，覆盖前必须确认。PowerPoint 是单实例程序，转换前已在运行时禁止 `Quit()`，只关闭本次打开的演示文稿。
- HTML 转 PDF 只通过 `tools\html_to_pdf.py --report` 转换（Playwright `channel="msedge"`，A4、`print_background`、`prefer_css_page_size`；无 Playwright 退回 `msedge --print-to-pdf`）。它单独成文件，不并入 `pdf_tools.py`，免得分享版 `pdf-tools.exe` 打进 Playwright。退回路径里 Edge 加载失败时退出码仍为 0，必须以是否生成 PDF 判断，且传给 Edge 的路径必须是绝对路径（相对路径会写到 Edge 的工作目录，报拒绝访问）。
- 读取 `CF_HDROP` 时必须在约 1 秒内每 50ms 重试：资源管理器分多次写入剪贴板格式，`ClipWait` 返回时可能还没有 `CF_HDROP`（错误码 1418），剪贴板也可能仍被资源管理器或 CopyQ 占用（`OpenClipboard` 错误码 5）；只读一次会让首次打开面板时文件类按钮变灰（2026-11-04 实测）。
- 面板打开时只读取一次当前窗口选区并保存选区快照；面板功能统一使用该快照，不在按钮执行时重读，也不用可能指向旧标签的 Shell `SelectedItems`。Word 转换按路径去重，多文件时先展示清单确认。

## 自定义快捷键边界

- `src/custom-hotkeys.ahk`：给面板功能绑定全局快捷键。按作用域（每个面板一个）分开：各有功能清单、配置文件、入口快捷键和设置窗口，设置窗口与“快捷键”页只列本作用域的功能。本文件只定义自动化面板作用域 `main`（配置 `%LOCALAPPDATA%\AutoHotkeyPanel\hotkeys.ini`），不得引用 2号面板；其他面板在自己的文件里用 `CustomHotkeyAddScope` 登记。所有作用域共用一张绑定表，组合键全进程唯一。快捷键只是“不开面板直接点按钮”，触发时必须先调 `CaptureAutomationContext()`（与打开面板共用）取选区快照，再经 `RunPanelCommand` 执行，不得另写一套读选区逻辑。
- 新增自动化面板按钮时同步在 `CustomHotkeyCommands()` 登记；登记的 id 写在用户配置里，改名只改显示名，不改 id。
- 两个面板的入口快捷键（`OpenAutomationPanelFromHotkey` / `OpenAutomationPanel2FromHotkey`）是开关：窗口可见就隐藏，否则打开；托盘入口传 `true` 只打开（快捷键回调第一个参数是按键名，不能当真值用）。
- 打开面板也是一条可改的快捷键（id `panel.open`，回调 `OpenAutomationPanelFromHotkey`），不再用 `^+e::` 写死：启动时先注册它，配置无效或被清除时回退 `Ctrl+Shift+E`，任何时候都必须有入口。界面和提示文字里的面板快捷键一律用 `AutomationPanelHotkeyText()`；分享版在 `share-panel.ahk` 覆盖该函数固定返回 `Ctrl+Shift+E`。
- 所有自定义快捷键用 `HotIf(CustomHotkeyCriterion)` 注册，设置窗口在前台时暂停；改绑走 `CustomHotkeyRebind`，新键失败要恢复旧键。
- 保留组合键（`Ctrl+Z`、`Ctrl+Tab`、`Ctrl+Shift+Tab`）不得分配；不带 Ctrl/Alt/Win 的普通键不允许（F1~F24 除外）；同一组合键不能分给两个功能。启动时无效条目只记日志，不弹窗。
- 回归：`tests/custom-hotkeys-smoke.ahk`，运行前把 `LOCALAPPDATA` 指到含 `hotkey-smoke` 的临时目录（测试会自检，防止改到真实配置）。

## 2号自动化面板边界

- `modern-panel-ui.ahk` 为此新增的通用能力（自动化面板与分享版也可用）：元素回调 `onDoubleClick` / `onRightClick`；拖动（元素 `dragGroup` + `ui["onDragMove"]` / `ui["onDragEnd"]`，拖动中 `SetCapture`，被拖元素最后画、用 `dragStyle`）；滚动区（`ModernPanelAddScrollRegion`，元素 `scroll` 归区，滚轮滚动并画细滚动条）；缓动（`ModernPanelAnimate`，元素 `tx/ty`）；样式键 `shadow`（1 常态 / 2 悬停 / 3 拖动）、`image`（GDI+ 位图）、`imageGrid` / `imageGridFill`（2×2 图标网格）、`folder`（彩色文件夹图标的主色）、`imageSize`、`subtext` / `subColor`。系统图标用 `ModernPanelFileIcon` 取（48px，按路径缓存）。踩坑：GDI+ 用外部内存创建或 `GdipCloneBitmapAreaI` 克隆的位图会一直引用那块内存，内存释放后会出噪点甚至访问越界，必须让 GDI+ 自己分配再 `LockBits` 拷像素；单独加载组件文件做测试时要加 `#Warn All, StdOut`，否则缺函数的警告框会弹到用户屏幕上。

- 个人专用面板，`src/panel2.ahk`，默认 `Alt+Q`。外观复用 `modern-panel-ui.ahk`，与自动化面板同进程但相互独立：自动化面板的源码（`excel-command-panel.ahk`、`custom-hotkeys.ahk`、`modern-panel-ui.ahk`、`share-panel.ahk`）除 `#Include panel2.ahk` 一行外不得出现 2号面板的任何引用；2号面板自带 `#HotIf` 切页热键和托盘项。面板互斥由 `ModernPanelCreate` 销毁旧的非常驻面板、`RunPanelCommand` 调 `ModernPanelHideAll()` 实现。
- 快捷键自成作用域 `panel2`（`Panel2HotkeysInit` 延后一拍登记，配置 `panel2-hotkeys.ini`，入口 `panel2.open` 默认 `!q`），只在 2号面板“快捷键”页设置。可绑定：入口、MP4 转 GIF、压缩视频、HTML 转 PDF、每个常用软件 / 文件夹（id `panel2.shortcut.<类型+路径的 FNV-1a 哈希>`，命令带 `noContext` 不读选区；删除条目时同时注销并保存）。
- 搜索：常用软件 / 文件夹页右上角的输入框是唯一的子控件（Edit，`-E0x200`、底色同圆角框），所以 2号面板窗口必须带 `+0x2000000`（WS_CLIPCHILDREN），否则自绘画布会盖住它。筛选在 `Panel2ApplySearch`：给卡片设 `hidden`（`ModernPanelIsVisible` 会跳过）、匹配项按序设 `tx/ty` 补位、重算滚动区，有搜索词时删掉 `dragGroup` 暂停拖动。匹配规则在 `Panel2SearchMatch`（名称 / 拼音首字母 / 2 字以上路径，多词全中），拼音首字母 `Panel2PinyinInitials` 用 CP936 区位码分段。回车、上下键、Esc 由 `#HotIf Panel2SearchKeysActive()` 热键处理（输入框会吞掉 Esc，面板的 Escape 事件收不到）。测试按真实按键时注意：截图用的 PowerShell 等会短暂抢走前台，按键前要重新激活面板。
- 右键菜单是自绘弹窗（`Panel2ShortcutMenu`，`ModernPanelCreate(..., keep=true)`，`-Caption +ToolWindow +E0x08000000` 不抢焦点、`+Owner` 2号面板），不要换回系统 `Menu`（用户嫌难看）。关闭由 60ms 定时器 `Panel2PopupWatch` 判断：菜单外新按下鼠标、`Esc`、面板隐藏或失去前台；`Panel2SearchEscape` / `Panel2OnEscape` 在菜单开着时只关菜单。局部变量别叫 `menu`（与内置 `Menu` 类同名会触发警告）。
- 不进分享包：分享版不得引用 `Panel2*` / `AutomationPanel2*` 函数。
- 2026-11-14 起默认输入法、MP4 转 GIF、压缩视频、HTML 转 PDF 的按钮只在 2号面板，自动化面板不再放；实现函数仍在原文件，规则不变。
- 快捷方式清单在 `%LOCALAPPDATA%\AutoHotkeyPanel\panel2-shortcuts.tsv`（带 BOM 的 UTF-8，`类型<Tab>名称<Tab>路径[<Tab>颜色序号]`），写入先写临时文件再替换；管理按钮（添加、右键菜单）不关闭面板，改完用 `Panel2Build(page, true)` 原位重建。卡片两列（`Panel2GridLayout`），样式由 `Panel2CardStyle` 统一生成（柔和底色 + 主色，配色表 `Panel2Palette`，按路径自动分配，同一路径颜色固定）。集合：路径 `group:<编号>`、第 5 列成员路径以 `|` 分隔，条目带 `members` 即集合（`Panel2IsGroup`）；成员用 `Panel2MemberItem` 按路径实际类型生成普通条目（快捷键 id 因此与移入前一致）；去重用 `Panel2FindPath`（含集合成员）；展开方框 `Panel2GroupPopup`（居中在内容区，成员用 `Panel2CardStyle` 卡片网格，不要做成菜单列表——用户嫌难看）、成员右键 `Panel2MemberMenu`、移入 `Panel2MoveToGroupMenu` 与右键菜单共用 `Panel2PopupNew` / `Panel2PopupShow`；卡片图标用 `modern-panel-ui` 的样式键 `imageGrid`（位图句柄或颜色串，2×2 最多 4 个）+ `imageGridFill`。拖动排序：卡片设 `dragGroup`，`Panel2OnDragMove` 按鼠标格子把卡片插入新位置、其余卡片设 `tx/ty` 缓动让位，`Panel2OnDragEnd` 用 `Panel2SaveOrder` 只重排同类型条目。
- 回归：`tests/panel2-smoke.ahk`，`LOCALAPPDATA` 指到含 `panel2-smoke` 的临时目录。

## AI 改 CAD 文字边界

- `src/cad-ai-text.ahk` + `tools/cad_ai_text.py`：AI 只返回 JSON 替换规则，文字一律由脚本展开，禁止改成让 AI 重打全部文字。校验不过不得输出结果。
- 调用 `claude -p` 必须用 `--setting-sources local --tools "" --no-session-persistence`：不触发 Stop 钩子通知、不读全局记忆；不能用 `--bare`，它不读登录凭据，会报 Not logged in。
- AI 设置的接口格式固定两个选项：Anthropic 兼容、OpenAI 兼容，二选一，用标准库 `urllib` 请求，不引入 SDK；Claude Code 登录是单独的勾选项。API Key 只能以 DPAPI 密文写入 `%LOCALAPPDATA%` 下的配置，错误信息和报告里不得出现明文。
- 发给 AI 前由脚本把“x,y 文字”参照表按行整理、模板去重，不要让 AI 自己还原坐标：2026-10-31 实测带思考的模型会因此把 8192 token 全耗在思考上。参照表取了值却没被规则用到的变量必须判校验失败。
- 图片识别只负责把表格转成制表符文字并填入参照表，必须由用户核对后才进入规则生成，不得直接串到写回。
- 回归：`python tests/cad-ai-text-smoke.py`、`python tests/cad-ai-provider-smoke.py`（离线，后者用本地模拟服务）；`tests/cad-ai-settings-smoke.ahk` 用临时配置测保存与解密；`tests/cad-ai-text-window-smoke.ahk` 真实调用 AI 并改写剪贴板。均不连接 CAD。

## 电缆排序（YSDL3）边界

- `src/cable-sort-core.ahk` 只放纯逻辑（解析 job、配对、规则匹配、推断、气泡初始分类、排序、生成 result），不碰界面和 CAD；`src/cable-sort.ahk` 是窗口。job/result 文件格式以中望 `AA整合版本.lsp` 的 YSDL3 段注释为准，改格式必须两边同时改（result 现为第 2 版，插件会拒绝其他版本）。
- 同编号两行跨分类框配对；第 2 列不是电缆编号的行作为“其他行”条目。分类气泡初始为图上的分类框，导出只按气泡（气泡名 = CSV 分类列，气泡顺序与气泡内顺序 = 导出顺序），未分类的不导出。用户 2026-11-09 确认：不再移动 CAD 清册文字。
- 柜名比较同中望 `hddl:cabinet`（去全部空白、开头的“至”，忽略大小写）。
- “导出”只在 CAD 空闲（`CMDACTIVE = 0`）且 job 里的图纸已打开时发送 `(aa:ysdl3-apply "任务号")`；写 CSV、变色、校验都由插件做，面板不直接改图。
- 回归：`tests/cable-sort-core-smoke.ahk`、`tests/cable-sort-window-smoke.ahk`（窗口放屏幕外，截图前先 `RedrawWindow` 整体重绘），均不连接 CAD；测试代码放在函数里并用 `#Warn All, StdOut`，避免弹出警告对话框。

## AutoHotkey v2 语法红线与验证部署

- AutoHotkey v2 判断字符串类型必须使用 `Type(val) = "String"`（无内置 `IsString()` 函数，误写会触发 `#Warn` 模态弹窗阻塞进程）；比较运算符仅支持 `=` / `==` / `!=` / `!==` 中的合法形式，严禁使用 JavaScript 的 `===`。
- 修改 AHK 后必须先执行静态加载检查：`& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /iLib nul /ErrorStdOut src\excel-command-panel.ahk`。
- 自动化回归测试套件：`tests\merge-split-benchmark.ahk`（合并/拆分 1000 行性能基准与撤销回归）与 `tests\spreadsheet-export-smoke.ahk`（选区信息导出冒烟测试）。
- 安装或热重载运行 `powershell -ExecutionPolicy Bypass -File .\install.ps1`。
- 启动项必须是 `excel-command-panel.lnk`，且启动文件夹内不能遗留 `.disabled` 等会被当作启动项的文件；系统自带的 `desktop.ini` 除外。
- 分享包名为“自动化工具面板”，`python packaging\build-share.py` 默认输出到桌面；桌面只保留最新一个分享包，旧包（含旧名“表格工具面板-*.zip”）由构建脚本移到回收站。改分享包内容后要重新构建，并做隔离安装（`setup.ahk install --root ... --shortcut-root ... --quiet --no-launch`）和 `--self-test` 验证；测试解压用 `Expand-Archive`，MSYS `unzip` 会弄乱中文文件名。`build-share.py` 只按 `名称(...) {` 块提取顶层函数，单行 `名称() => 值` 写法不会被带进分享包（2026-11-11 踩坑），`src` 里的顶层函数一律写成块形式。`packaging\share-panel.ahk` 只是模板，不能直接静态检查（会弹 `CablePanelInit` 警告框）；要检查就先用 `build_panel_script()` 拼出脚本，把 `#Warn` 改成 `#Warn All, StdOut` 再加载，避免弹窗打扰用户。
