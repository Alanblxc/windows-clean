# 发给豆包的一键精简提示词

请直接在本机执行：每次从 https://raw.githubusercontent.com/Alanblxc/windows-clean/main/WindowsClean.ps1 下载单文件脚本到持久目录，使用 64 位 Windows PowerShell 5.1 运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<下载目录>\WindowsClean.ps1"
```

只让我确认一次标准 UAC，不弹选择窗口、不询问编号、不额外审查源码、核对哈希或比对约定，也不单独运行 Win11Debloat。脚本自动扫描并执行支持的可选项，保留打印服务、XPS、传真及原有排除项；未知依赖继续跳过。备份、实时进度、临时文件及 WinSxS 清理和资源对比均由脚本完成，不重复操作，不自动重启或注销。等待结束并简报实际结果与日志/恢复路径；超时先检查原进程，不重复启动。如果你没有本机命令执行权限，请明确说明，不要声称已执行。
