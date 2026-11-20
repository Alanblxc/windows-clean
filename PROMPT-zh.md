# Windows 11 精简提示词

下载并完整解压 https://codeload.github.com/Alanblxc/windows-clean/zip/refs/heads/main 到持久目录（已有完整副本直接复用），全程使用 64 位 Windows PowerShell 5.1。不额外审查源码、核对哈希、比对约定或先做全盘扫描，不单独运行 Win11Debloat。

**由 agent 弹出多选窗口，不让我在控制台输入编号。** 按以下协议执行：

1. 运行 `Disable-WindowsFeatures.ps1 -AgentStage Options`，读取输出的本轮目录中的 `available-options.json`。用 agent 的交互选择窗口展示中文名称、作用和影响（OpenChamber 用 `openchamber_render` 的 `ui` 多选 `Choice` 配合 `awaitAnswer`）。Id 为传参值，Default 只用于标注推荐，必须等我提交；取消就停止，不能用默认项代替同意。
2. 把窗口所选 Id 用逗号连接，运行 `Disable-WindowsFeatures.ps1 -AgentStage Scan -RunDirectory "<本轮目录>" -Selection "<所选编号或NONE>"`。只有 X1/X2 会扫描额外候选。读取 `agent-candidates.json`，有候选则再弹多选窗口（默认不选），无候选直接进入执行；取消整个操作就停止。
3. 运行 `Disable-WindowsFeatures.ps1 -AgentStage Apply -RunDirectory "<同一本轮目录>" -Selection "<候选编号或NONE>"`。基础选择已保存，无需再次传入；NONE 表示保留全部额外候选，仍执行已提交的基础选择。复用本轮扫描，不重新整套扫描。不重复 Apply；超时先查原进程及日志。

提权、备份、实时输出、WinSxS 清理、资源对比与日志由脚本处理。执行结束后简报实际结果和日志/备份路径。
