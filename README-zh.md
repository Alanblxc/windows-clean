# Windows 11 自定义精简脚本

## 扩展审核（新增）

每次模式运行结束时，控制台输出运行前后进程总数、系统已用物理内存（MB）和变化量，并在本轮目录保存 `health-comparison-模式-时间.json`。变化量为“之后减之前”，负数表示减少；内存按系统可见总物理内存减可用内存计算，不累加进程工作集。前置采样失败时跳过对比，不编造数据。即时数据可能受其他后台活动影响，不能代替重启后的同负载验证；若从提示词执行 Win11Debloat，则这里的“前”是自定义脚本运行前，不包含上游执行前的资源。

下载时必须把 `ExtendedReview.ps1` 与主脚本放在同一文件夹。默认执行新增资源和登录会话前后快照，以及 `extended-review.md/json`。还原点按提示词中的 Win11Debloat 上游默认逻辑处理，允许其按需启用系统盘系统保护；自定义脚本不重复创建，也不在上游跳过或失败时自动补建。单独运行自定义脚本不会创建还原点，逐项备份和恢复仍保留。

扩展清单包含 Fax、Xbox 配套服务、打印和蓝牙服务的按需启动调整；旧媒体播放器、XPS、传真可选功能；所有触发类型的第三方计划任务和第三方自动服务。未知服务/任务只读，不凭名称陌生禁用。可选择项目需要阅读影响后指定编号：

```powershell
& ".\Disable-WindowsFeatures.ps1" -Mode ApplyReview -RunDirectory "C:\ProgramData\WindowsCustomCleanup\实际运行目录" -ReviewIds 2,5
```

编号仅是示例。延迟启动仅支持已存在且符合条件的交互式登录任务，延迟 60 秒，不自动把 Run 项迁移为任务。相同任务的禁用和延迟不可同时选择。可选功能恢复可能需要联网或安装源；不自动重启。

每季度或软件更新后可手动运行 `-Mode Review`，只读创建新一轮清单和资源快照。不会安装定期自动精简任务。会话只列出，不注销；CPU 单进程字段是累计时间，不是瞬时百分比。需人工在相近负载、重启后空闲 3～5 分钟对比，不用进程总数判断是否一定更快。

**明确排除 SysMain、WSearch、无线显示器和第三方应用逐个后台权限修改。** 不调整 Windows 系统维护任务。扩展修改同样由本轮 `Restore-CustomChanges.ps1` 恢复。

仅生成脚本，不会因为下载或阅读而运行。**不包含 Win11Debloat，也不下载或运行任何上游精简工具。**

## 运行

将 `Disable-WindowsFeatures.ps1` 放在固定位置。在该文件夹用管理员身份打开 **64 位 Windows PowerShell 5.1**（不是 PowerShell 7 / pwsh）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Disable-WindowsFeatures.ps1"
```

不自动弹 UAC、重启或注销。权限不足直接停止。每次运行在 `%ProgramData%\WindowsCustomCleanup\日期时间-随机标识` 新建独立持久目录，控制台打印绝对路径。目录只授权管理员和 SYSTEM。备份含程序路径等隐私信息，分享前检查。

默认执行：
- 保留原先的 RmSvc、诊断服务、遥测策略、Copilot / Recall / 小组件处理；Copilot 仅在提权账户与目标登录用户相同的情况下卸载。
- 修改 Game Bar 用户录制偏好及控制器唤起开关；已有的历史录制 DWORD 才修改，不凭空创建版本不确定的键。
- 检查五个指定驱动；除 beep 外，驱动停止、设备与过滤器/服务依赖清单完整且无相关依赖时才禁用。
- 扫描自启动。明确识别为 Xbox 主应用包启动命令、并能备份恢复的入口直接处理；其他入口先列清单，不自动禁用。

**系统管理状态不明或检测到域/工作学校注册时，所有修改都跳过，仅生成扫描报告。** 无法唯一识别当前会话登录用户时跳过用户范围修改，绝不误改提权管理员的 HKCU。

## 自启动：先扫描，后明确选择

默认运行已包含扫描。也可以只扫描，不执行精简：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Disable-WindowsFeatures.ps1" -Mode ScanStartup
```

打开输出目录的 `startup-review.md` 查看编号、发布者/签名、准确位置、完整命令、启用状态、用途、影响、未知信息及拟用方法。建议采用保守白名单，未知项目和硬件、安全、同步等项目默认保留；签名不是必需性的证明。应用包 StartupTask 读取清单和状态，但不猜测修改其内部状态。

选择要禁用的编号后，在同一管理员 Windows PowerShell 窗口直接调用脚本（这样数组参数可正确传递）：

```powershell
& ".\Disable-WindowsFeatures.ps1" -Mode DisableStartup -RunDirectory "C:\ProgramData\WindowsCustomCleanup\实际运行目录" -StartupIds 3,7
```

编号是示例，必须替换成你看过且明确同意的实际编号。全部保留则不执行这个命令。不会把沉默、超时或缺省参数当作同意。选中条目会再次检查原命令/文件哈希/任务定义，发生变化则跳过。计划任务只禁用不删除；注册表入口先备份再移除；启动文件先复制校验再移出，不删除程序本体，不结束进程。

## 备份、日志和恢复

输出目录包括：
- `original-values.json`：本轮注册表存在性、类型、原值、服务原配置及逐项变更日志。
- `report.json` 和各模式 `.log`：完成、原已符合、跳过、失败、待选择信息。
- `device-inventory.json`、各驱动 `*-original.reg`：设备/依赖证据与驱动键导出。
- `startup-review.json` / `.md`：自启动清单。
- `*-protected-before.json` / `*-protected-after.json`：WSearch / Gaming Services 配置与状态对照。
- `Restore-CustomChanges.ps1`：恢复本轮自定义修改。
- `Restore-SelectedDrivers.ps1`：只恢复本轮驱动修改。

恢复命令（替换成真实绝对路径）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\WindowsCustomCleanup\实际运行目录\Restore-CustomChanges.ps1"
```

只恢复驱动则改用 `Restore-SelectedDrivers.ps1`。使用本轮真实原值；原来不存在的注册表值恢复时删除。待完成写入也记入日志，防止操作中断后失去备份。注册表/任务若已被外部修改则保留并报告，不擅自覆盖。恢复不会重新下载应用；Copilot 按需从 Microsoft Store 重装；Recall 已删除的快照无法恢复。新格式恢复入口不读取旧版 `WindowsFeatures-backup.json`。

## 明确限制

- 这是安全优先的尽力处理，不承诺所有项目都能自动关闭。Xbox 应用私有设置、应用包启动任务禁用、Game Bar 独立后台权限和总开关无法可靠配置时报告跳过，不用全局后台策略替代。
- 微软文档注明 AllowGameDVR CSP 仅在 Windows 10 桌面版强制执行，本脚本不声称该策略能在 Win11 生效。用户录制设置回读成功不等于实测录制功能；不会自动开游戏测试。
- 不修改游戏模式、GameInput、WSearch、GamingServices、GamingServicesNet、Store、Edge、显卡录制或安全软件。保护服务前后自然变化仅报告，不反向强制修改。
- 不禁用 bowser，不卸载 Xbox / Game Bar，不修改驱动文件、权限或其他驱动数值。beep 可能仍处于加载状态；配置禁用不等于立即卸载，需要手动重启验证。
- 遥测不保证归零，策略受系统版本/版本 SKU 支持程度限制。禁用 RmSvc 可能影响飞行模式、Wi-Fi / 蓝牙开关。
- 不保证提升 FPS 或降低延迟。每次默认执行都会新建一轮备份，不要重复运行整套精简来代替按编号处理自启动。

验证：`Test-WindowsFeatures.ps1` 只解析脚本并隔离测试纯判断/备份失败路径，不执行系统修改。完整运行效果仍需在目标机器上运行后查看日志，并在必要时手动重启验证。
