# Windows 11 一次精简

## 一键模式（无需选择）

运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Disable-WindowsFeatures.ps1 -OneClick`。自动提权后，扫描并执行支持的可选项，保留打印服务 Spooler、XPS、传真和所有原有排除项。任务统一选禁用而非延迟，同一任务只处理一次；未知依赖保持跳过。不会出现选择窗口或控制台编号询问。扫描、驱动检查和 DISM 仍需时间，不会为了“一键”跳过必要保护。可能改变蓝牙/Xbox 服务启动方式、移除旧播放器、停止可选应用自动启动；临时文件删除和组件清理不可撤销。

[发给豆包的提示词](PROMPT-zh.md)已默认使用此模式。豆包必须具备本机执行权限；UAC 被取消则停止，上游还原点失败等系统问题不能保证自动成功。

完整内置固定版本 Win11Debloat，把自定义精简、自启动/服务/组件选择、临时文件、WinSxS 清理及资源对比放进同一入口。**先扫描并选择，再连续执行**。下载解压整个仓库，包括 `vendor`，不能再只下载主脚本。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Disable-WindowsFeatures.ps1
```

使用 64 位 Windows PowerShell 5.1；默认入口未提权时弹标准 UAC。融合模式要求管理员与当前桌面登录用户是同一账户，组织管理/注册状态不明时停止。

**通过 agent 执行时使用弹窗多选**，按 [PROMPT-zh.md](PROMPT-zh.md) 操作：`-AgentStage Options` 导出菜单，由 agent 弹出窗口；`-AgentStage Scan -RunDirectory ... -Selection "G1,G2,X1"` 保存基础选择并仅扫描所选类别；有候选时再弹窗口；`-AgentStage Apply -RunDirectory ... -Selection "S1,R2"` 复用本轮清单执行。候选传 `NONE` 表示不选额外候选。所有阶段不读取控制台输入，不隐式同意推荐项。Scan/Apply 必须使用 Options 的同一本轮目录，已经开始执行的目录禁止再次 Scan/Apply。直接手动运行仍保留控制台菜单。

入口直接显示 G/U 功能菜单，不先扫描自启动、服务、任务或可选组件。输入逗号分隔编号，**替换**默认选择；直接回车采用显示为 `[*]` 的默认项；`NONE` 取消。需要额外候选时，在所选编号中加入 `X1`（自启动）或 `X2`（服务/任务/组件），才执行对应扫描并在精简前显示候选编号菜单；候选菜单回车或 NONE 均保留全部候选。Xbox 候选也需明确选择。同一任务不能同时选禁用和延迟，也不能在两类清单重复选择。驱动依赖检查仅在执行 G3 时进行，保留必要保护检查。

- `G1`：自定义隐私、Copilot/Recall、小组件与 RmSvc/诊断服务；Recall 快照删除不可恢复。
- `G2`：关闭游戏录制与手柄启动 Game Bar，保留游戏服务。
- `G3`：检查 `1394ohci、beep、HidIr、circlass、usbcir`，仅调整符合条件的驱动启动值，先备份，不卸载驱动。
- `G4`：删除实际用户 Temp 和 Windows Temp 超过七天的普通文件，跳过重解析点、占用文件、脚本目录及本轮日志/备份；删除不可恢复。
- `G5`：WinSxS 通过 `DISM /Online /Cleanup-Image /StartComponentCleanup /NoRestart` 清理。不直接删目录，不用 `/ResetBase`。3010 记录为待手动重启；清理没有自定义撤销功能。
- `U…`：逐项选择固定版本上游默认设置。排除会改 Defender 样本提交策略的上游遥测项，以及会强制结束小组件进程的上游小组件项；这两项由 `G1` 的自定义设置处理。目前上游默认配置不包含批量卸载应用包。只要选择执行清理，就先按上游逻辑请求还原点，可能因近期已有还原点而跳过，也可能失败，应查看实际日志。
- `S… / R…`：自启动、服务启动方式、旧播放器/XPS/传真、第三方任务禁用或延迟 60 秒。未知依赖的服务/任务只读保留。

继续保留 SysMain、WSearch、无线显示器、第三方应用后台权限、Gaming Services/GameInput、Store、Defender、防火墙与 Windows Update。不上来结束应用，不强制清空系统内存，不重启资源管理器，不自动重启或注销。按所选项目，打印/蓝牙/传真/无线开关/媒体/Xbox 功能可能受影响。

控制台实时显示阶段、项目、耗时及 DISM 进度。开始与结束记录进程数量、系统已用物理内存和差值；即时资源变化不证明性能提升。驱动扫描和 DISM 仍可能较慢。

每轮备份位于 `%ProgramData%\WindowsCustomCleanup\<本轮>`，保存原值、自定义恢复脚本、选项与实际选择、上游源码副本及配置、日志、临时文件删除数量/字节、WinSxS 退出码、健康快照/对比及 `final-cleanup-summary.json`。汇总计数为自定义报告事件，上游逐项成败另看上游日志。上游注册表备份还可能在 `%LOCALAPPDATA%\Win11Debloat\Backups`。

以管理员身份运行本轮 `Restore-CustomChanges.ps1` 或 `Restore-SelectedDrivers.ps1`，仅恢复自定义日志中的改动。上游改动使用其备份/撤销文件或有效系统还原点恢复；自定义备份在上游执行后记录，不能撤销上游重叠设置。临时文件、WinSxS 清理和 Recall 快照不能靠自定义恢复找回；Copilot 按需从 Store 重装。

旧 `Disable/ScanStartup/Review/DisableStartup/ApplyReview/Restore/RestoreDrivers` 模式保留，只有默认 `Unified` 提供完整融合流程与 UAC；旧 `Disable` 会直接应用自定义默认设置。

上游固定版本和 MIT 许可证说明：[vendor/UPSTREAM.md](vendor/UPSTREAM.md)。供 AI 执行的简短指令：[PROMPT-zh.md](PROMPT-zh.md)。开发测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-WindowsFeatures.ps1
```

测试只解析脚本并隔离验证判断/配置，不执行精简。没有在开发机器进行实际精简、UAC、恢复或端到端组件清理验证。不承诺遥测归零、内存下降或游戏性能提升。
