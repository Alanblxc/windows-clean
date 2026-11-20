# Windows 11 精简执行提示词

**启动后的第一步：先取得管理员权限，再进行下载或其他操作。** 已是管理员则直接继续；否则立即通过 `Start-Process -Verb RunAs` 弹出标准 UAC，启动 **64 位 Windows PowerShell 5.1（powershell.exe）** 作为本轮执行环境。允许为触发 UAC 创建必要的启动脚本；用户取消或提权失败则停止。后续下载和修改都在已提权的执行环境中完成，不要等到脚本报权限错误才提权，也不要反复弹窗。

请直接在本机完成以下操作。已授权列出的修改，不要反复确认或逐项讲解；只有额外自启动和扩展审核清单需要等待我选择。所有脚本使用 Windows PowerShell 5.1 执行，不使用 pwsh.exe。

## 1. 运行 Win11Debloat

从官方地址下载完整压缩包并解压：
https://codeload.github.com/Raphire/Win11Debloat/zip/refs/heads/master

使用默认模式，不更改默认应用列表，不增加其他精简参数：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<解压路径>\Win11Debloat.ps1" -RunDefaults -Silent -LogPath "<日志目录>"
```

还原点按上游默认行为处理，允许按需启用系统保护，不额外重复创建。

**我的排除项优先：不修改 SysMain、WSearch，不卸载无线显示器，不处理第三方应用逐个后台权限；保留 Microsoft Store、Defender、防火墙和 Windows Update。** 运行前仅核对默认模式是否与这些要求冲突；存在冲突或无法确定则跳过上游步骤，继续下面的自定义脚本，不擅自修改上游参数。

## 2. 运行自定义脚本

将下面两个文件下载到同一持久文件夹：

- https://raw.githubusercontent.com/Alanblxc/windows-clean/main/Disable-WindowsFeatures.ps1
- https://raw.githubusercontent.com/Alanblxc/windows-clean/main/ExtendedReview.ps1

下载后一次性核对 SHA256，不匹配则停止该步骤：

```text
Disable-WindowsFeatures.ps1
9166C58541FB490D77B7CD630657003A8193B8D8210C8EB5FF64B56FCE9FF995
ExtendedReview.ps1
411BEDDF36A8E2D7B7ADCBE34D47AAEA636C974615945827CBD65761E87409D4
```

然后直接执行一次：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<下载路径>\Disable-WindowsFeatures.ps1"
```

按脚本完成无线电管理、遥测、Copilot/Recall、小组件、Xbox/Game Bar 和五个指定驱动的处理。保留脚本自带备份和保护检查；跳过项如实记录，不另写命令绕过。正确识别实际登录用户，不误改提权管理员的用户设置。

## 3. 选择额外项目

读取本轮 `startup-review.md` 和 `extended-review.md`，只展示可操作候选项的编号、名称、影响，问我选哪些或全部保留。没有候选项就略过。不把沉默当同意，不重复执行整套精简。

获选后在管理员 Windows PowerShell 5.1 中执行对应模式，编号替换为我实际选择的编号：

```powershell
& "<下载路径>\Disable-WindowsFeatures.ps1" -Mode DisableStartup -RunDirectory "<真实本轮目录>" -StartupIds 3,7
& "<下载路径>\Disable-WindowsFeatures.ps1" -Mode ApplyReview -RunDirectory "<真实本轮目录>" -ReviewIds 2,5
```

## 4. 简明汇报

等待进程结束后读取实际日志；超时先确认原进程状态，不重复启动。不要自动重启、注销或结束无关应用。

最后只报告：已完成、跳过/失败、待选择项目；自定义脚本运行前后的进程数和已用内存及变化量；本轮日志、备份和恢复脚本绝对路径。即时数据不代表重启后效果，不承诺固定进程数或性能收益。
