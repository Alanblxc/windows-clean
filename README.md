# WindowsClean

[中文说明](README-zh.md) · [Doubao prompt](PROMPT-zh.md)

Download [WindowsClean.ps1](https://raw.githubusercontent.com/Alanblxc/windows-clean/main/WindowsClean.ps1) and run using 64-bit Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsClean.ps1
```

Default execution is one-click, elevating through standard UAC when necessary. Printing/Spooler/XPS/fax and existing protected features are retained. Unknown dependencies are skipped. No automatic restart/logoff or forced application termination.

## Direct implementation

Default registry operations adapted from Win11Debloat execute directly through the custom journal. No embedded archive, upstream extraction/config or upstream child executor remains. MIT attribution is included in the release; vendor is a reference snapshot only.

Integrated settings cover Windows suggestions, Edge ads, lockscreen tips, Bing/Cortana search policies, Copilot/Recall/ClickToDo policies, AI service startup, Chat, known extensions and Modern Standby network policies where supported. Custom telemetry/widgets preserve Defender and avoid force-stopping widget processes. Upstream Store search-suggestion database ACL denial is explicitly skipped. Copilot current-user removal remains in G1; Bing packages are not removed. This is not an indiscriminate copy of every upstream effect.

Restore-point handling runs locally: enable protection if disabled, reuse a recent point, otherwise request a new point. Failures are reported; creation is not guaranteed. Registry operations now share original-state backups and conflict-aware restoration. SysMain, WSearch, wireless display, third-party background permissions, Gaming Services/GameInput, Store, Defender/firewall and Windows Update remain protected.

Startup, service/task and legacy-component inventories still run in one-click mode. Optional launchers may stop auto-launching, Bluetooth/Xbox service startup may change and legacy media may be removed. Driver changes remain limited to five allowlisted targets with dependency checks. Temporary cleanup removes ordinary files older than seven days, skipping reparse points and protected source/run paths. WinSxS uses DISM StartComponentCleanup /NoRestart, not direct deletion or ResetBase. Deleted files, Recall snapshots, Copilot removal and component cleanup have no automatic custom undo.

## Logs and recovery

Run directories under `%ProgramData%\WindowsCustomCleanup` contain logs, journals, exact script copies, restore wrappers, selection and resource comparisons. Use the original run's Restore-CustomChanges.ps1 or Restore-SelectedDrivers.ps1 as administrator. Conflicting later changes are preserved. Reinstall Copilot through Store if needed. Immediate process/memory changes do not prove improved performance.

Elevation prints a diagnostic transcript path, retains live output in the elevated window and replays the transcript to the original caller after exit. START/exit=1 alone does not establish the original failure cause; inspect the elevated transcript before rerunning. The user's original failure remains unconfirmed without its actual exception.

`-ManualMenu` restores manual selection. Explicit agent stages and legacy modes remain supported. Source: Disable-WindowsFeatures.ps1; Build-SingleFile.ps1 publishes the same script with MIT attribution. Test-WindowsFeatures.ps1 and Test-SingleFile.ps1 run isolated tests only. Real cleanup, UAC and restoration have not been validated end to end on the development machine.
