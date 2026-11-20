# WindowsClean 单文件一键精简

下载 [WindowsClean.ps1](https://raw.githubusercontent.com/Alanblxc/windows-clean/main/WindowsClean.ps1)，使用 64 位 Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsClean.ps1
```

默认一键执行，未提权时弹标准 UAC。保留打印服务、XPS、传真，以及 SysMain、WSearch、无线显示器、第三方应用后台权限、Gaming Services/GameInput、Store、Defender、防火墙和 Windows Update。未知依赖跳过；任务禁用优先于延迟，同一任务只处理一次。不自动重启、注销或强制结束应用。

不再检测域加入、工作/学校注册或设备托管状态，也不因这些状态阻止精简和恢复。管理员权限、目标用户、备份、驱动依赖和恢复冲突检查仍保留。组织策略可能重新覆盖设置。

## 默认项目直接执行

Win11Debloat 默认注册表操作已直接合并到主脚本，包括 Windows 推荐、Edge 广告、锁屏提示、Bing/Cortana 搜索策略、Copilot/Recall/ClickToDo、AI 服务启动、聊天按钮、文件扩展名及现代待机网络策略。适用版本受限的项目跳过。

**不再内嵌压缩包、释放上游文件或调用 Win11Debloat 子脚本。** 注册表改动统一进入原值日志，vendor 仅留作来源参考。发布文件中保留 MIT 版权及许可证。

遥测与小组件沿用自定义设置，避免修改 Defender 或强制结束进程。Store 搜索建议的上游实现会拒绝 Everyone 访问 Store 数据库，因此明确跳过；Bing 搜索包不卸载。Copilot 当前用户卸载沿用 G1。这不是所有上游效果的无差别复制。

还原点逻辑直接执行：系统保护关闭时尝试启用，近期有还原点则跳过，否则请求创建；失败写报告，不保证一定创建。所有注册表值通过本轮备份函数修改。

## 范围与恢复

自动扫描支持的启动项、服务、任务和旧媒体组件。可能改变蓝牙/Xbox 服务启动方式、移除旧播放器、停止可选应用自动启动。驱动仅检查原有五项并保留依赖保护。临时目录只删超过七天的普通文件，跳过重解析点及脚本/备份路径。WinSxS 使用 DISM StartComponentCleanup /NoRestart，不直接删除目录或使用 ResetBase。

每轮目录：`%ProgramData%\WindowsCustomCleanup\<本轮>`，包含原值、脚本副本、恢复脚本、报告和资源对比。运行该轮 Restore-CustomChanges.ps1 或 Restore-SelectedDrivers.ps1 恢复可恢复的改动，冲突时保留后续修改。临时文件删除、组件清理和 Recall 快照无法通过恢复脚本找回；Copilot 按需从 Store 重装。即时进程数/内存变化不证明性能改善。

## 启动报错

提权前打印诊断日志路径；提权进程保留实时输出并写 transcript，退出后将日志回传给原调用进程。如果只见 START 或 exit=1，读取打印的 WindowsClean-elevated 日志，不要重复启动。目前缺少用户失败机器的实际异常，尚不能确定原始退出根因。

`-ManualMenu` 保留手动菜单；agent 分阶段与旧恢复模式继续支持。给豆包的指令见 [PROMPT-zh.md](PROMPT-zh.md)。维护源文件是 Disable-WindowsFeatures.ps1；Build-SingleFile.ps1 将源码附 MIT 许可发布为 WindowsClean.ps1。

测试：Test-WindowsFeatures.ps1 与 Test-SingleFile.ps1，均不执行实际精简。UAC、恢复及真实 DISM 清理尚需测试机端到端验证。
