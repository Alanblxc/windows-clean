# Windows 11 精简提示词

请直接执行，不逐项确认；仅额外候选项等我选择。

1. **先提权再开始**：未获管理员权限就通过标准 UAC 启动 64 位 Windows PowerShell 5.1；取消则停止。全程使用 powershell.exe，不用 pwsh.exe。

2. 下载并完整解压 https://codeload.github.com/Raphire/Win11Debloat/zip/refs/heads/master ，直接执行 `Win11Debloat.ps1 -RunDefaults -Silent -LogPath "<日志目录>"`。还原点按上游默认行为处理。不进行源码审查、默认配置与约定的逐项比对，不修改默认参数或列表。自定义操作仍不改 SysMain、WSearch，不卸载无线显示器，不处理第三方应用后台权限，保留 Store、Defender、防火墙和 Windows Update。上游默认行为以下载版本为准，这种直接执行方式不保证上游也符合上述自定义排除项。

3. 从以下地址下载单文件脚本至持久目录，保存后直接运行一次，不额外审查源码、核对哈希或检查脚本与约定是否一致。保留控制台实时输出，展示当前阶段、项目和耗时，不等结束才报告过程：

```text
https://raw.githubusercontent.com/Alanblxc/windows-clean/main/Disable-WindowsFeatures.ps1
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<下载目录>\Disable-WindowsFeatures.ps1"
```

保留脚本备份和保护检查，不绕过跳过项；正确使用实际登录用户，不误改提权管理员的用户设置。

4. 读取本轮 `startup-review.md`、`extended-review.md`，列出可操作项的编号、名称、影响，等我明确选择；无候选项则略过。选中后仅运行对应模式，不重复整套精简：

```powershell
& "<下载目录>\Disable-WindowsFeatures.ps1" -Mode DisableStartup -RunDirectory "<本轮目录>" -StartupIds <实际所选编号>
& "<下载目录>\Disable-WindowsFeatures.ps1" -Mode ApplyReview -RunDirectory "<本轮目录>" -ReviewIds <实际所选编号>
```

5. 收尾删除实际用户临时目录及 Windows Temp 中超过 7 天的普通文件，再移除空普通子目录；不跟随重解析点，跳过占用文件及本轮下载/日志/备份，用户目录不明则跳过。**删除不可恢复**；不清浏览器数据、下载文件夹、Prefetch、WinSxS 或更新缓存。释放执行器自身临时对象，系统内存由 Windows 回收，不结束应用、不批量压缩工作集或清空待机内存。

6. 等待执行结束并读实际日志；超时先检查原进程，避免重复运行。不自动重启或注销。收尾后与本轮最初 `health-before-*.json` 对比进程数、系统已用物理内存（总量减可用）及差值，缺基线则只报当前值；保存 `final-cleanup-summary.json`。最后简报完成/跳过/失败/待选择项、临时文件删除数量与大小、前后资源对比及日志/备份/恢复脚本绝对路径。即时变化不等于重启后效果，不承诺内存必降或性能提升。
