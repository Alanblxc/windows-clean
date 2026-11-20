# Windows 11 精简提示词

下载并完整解压 https://codeload.github.com/Alanblxc/windows-clean/zip/refs/heads/main 到持久目录（已有完整副本直接复用），使用 64 位 Windows PowerShell 5.1 运行 `Disable-WindowsFeatures.ps1`。不要额外审查源码、核对哈希、比对约定或先做全盘扫描，也不要单独运行 Win11Debloat。

显示脚本菜单让我选择，按所选项执行到底并简报实际结果。默认不扫描额外候选；仅选择 X1/X2 时扫描并让我选择具体项目。提权、备份、实时输出、WinSxS 清理、资源对比与日志均由脚本处理，不另行重复操作。
