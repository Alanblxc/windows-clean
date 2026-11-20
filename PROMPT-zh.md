# Windows 11 一次精简提示词

请下载并完整解压 https://codeload.github.com/Alanblxc/windows-clean/zip/refs/heads/main 到持久目录，使用 64 位 Windows PowerShell 5.1 执行 `Disable-WindowsFeatures.ps1`。不要只下载单文件，不另行下载或单独执行 Win11Debloat，不额外审查源码、核对哈希或逐项检查约定。

入口会先通过标准 UAC 提权，再扫描并展示上游、自定义、自启动、服务、组件及清理选项。把编号、作用和影响展示给我，精简前等我一次选择，再将所选编号传入入口菜单并让整套流程执行完。默认推荐项不是自动同意；输入具体编号会替换默认选择，NONE 取消。保留实时进度、备份及脚本内保护检查。

WinSxS 使用入口提供的 DISM StartComponentCleanup，不直接删除目录、不加 ResetBase。临时文件清理不可恢复。上游还原点按上游逻辑处理；不自动重启或注销，不结束应用或强制清系统内存。结束后读实际日志，简报所选项目、完成/跳过/失败、清理数量及字节、前后进程数和内存对比，以及日志/备份/恢复脚本路径；超时先查原进程，避免重复执行。
