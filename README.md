# Windows clean

[中文说明](README-zh.md) · [AI 执行提示词](PROMPT-zh.md)

A Windows 11 cleanup entry that combines custom cleanup with a complete, pinned copy of [Win11Debloat](https://github.com/Raphire/Win11Debloat). Scan, choose options before changes, then execute the selection in one run. Download/extract the **whole repository**, including `vendor`; the entry is no longer a standalone download.

Run from 64-bit Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Disable-WindowsFeatures.ps1
```

The entry requests UAC if needed. Windows 11 and an administrator account matching the active desktop user are required for unified execution. Managed/enrolled or uncertain systems are blocked. No actual cleanup has been run on the development machine.

The console first scans startup entries, services, scheduled tasks and optional components. It prints all selectable IDs with effects. Enter comma-separated IDs to replace the default selection; press Enter for the displayed defaults, or enter `NONE` to cancel. Invalid or conflicting choices abort before cleanup. Unknown third-party services/tasks remain read-only.

- `G1`–`G3`: custom privacy/AI/widgets and diagnostic services, game capture settings, and the five allowlisted driver checks. Drivers are backed up before any eligible startup change.
- `G4`: remove ordinary files older than seven days from the active user's Temp and Windows Temp. Skip reparse points, busy/inaccessible files, source and run backups. File deletion is irreversible.
- `G5`: WinSxS cleanup through `DISM /Online /Cleanup-Image /StartComponentCleanup /NoRestart`. No direct component-store deletion or `/ResetBase`. Exit code 3010 is recorded as restart required; there is no automatic restart or custom undo.
- `U…`: individually selectable settings from the pinned upstream defaults. Upstream telemetry/widgets are excluded because they change Defender sample submission/force-stop widget processes; `G1` supplies custom settings instead. Upstream app-removal packs are not part of these defaults. A restore point is requested through upstream behavior when any cleanup is selected; creation may be skipped or fail. Consult upstream logs.
- `S…`, `R…`: optional startup changes, service startup changes, legacy media/XPS/fax removal and task disable/delay. Supported exact Xbox startup entries are default-selected; other candidates need explicit selection. Choose one action per task.

Preserves SysMain, WSearch, wireless display, third-party app background permissions, Gaming Services/GameInput, Store, Defender/firewall and Windows Update. Does not kill unrelated applications, trim all working sets, restart Explorer, restart Windows or log off. Changes can still affect fax, printing, Bluetooth, wireless controls, media and Xbox integrations according to selected options.

Progress includes stage/item names, elapsed times and live DISM output. Initial/final process count and used physical memory are saved and compared; snapshots are not proof of improved performance. Driver enumeration and DISM can take time.

Each run creates a secured folder under `%ProgramData%\WindowsCustomCleanup`. It contains the exact custom script, journal, restore wrappers, review inventories, `available-options.json`, `selection.json`, copied upstream source/config, logs, `temp-cleanup.json`, `component-cleanup.json`, health comparisons and `final-cleanup-summary.json` where applicable. Summary counts cover custom report events; upstream per-setting results must be read from its logs. Upstream may also store registry backups under `%LOCALAPPDATA%\Win11Debloat\Backups`.

Use `Restore-CustomChanges.ps1` or `Restore-SelectedDrivers.ps1` from the **exact original run folder** as administrator. These restore only custom journaled changes, preserving intervening conflicts. Upstream changes use upstream backups/undo files or an available Windows restore point. Temporary files, component cleanup, removed Recall snapshots and Copilot app removal have no automatic custom undo; reinstall Copilot through Store. Custom backup state is captured after upstream, so it does not reverse upstream changes to overlapping values.

Legacy modes remain available: `-Mode Disable`, `ScanStartup`, `Review`, `DisableStartup -RunDirectory ... -StartupIds ...`, `ApplyReview -RunDirectory ... -ReviewIds ...`, `Restore`, `RestoreDrivers`. Only default `Unified` performs the combined sequence and offers UAC. Legacy `Disable` applies custom defaults immediately.

Upstream revision/license and update notes: [vendor/UPSTREAM.md](vendor/UPSTREAM.md), [MIT license](vendor/Win11Debloat/LICENSE). Updating the pinned source is a deliberate repository change, not a runtime download.

Non-destructive verification:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-WindowsFeatures.ps1
```

Tests parse the entry and exercise isolated decision/config helpers without running cleanup. Real system cleanup, restoration, UAC and end-to-end servicing require a disposable Windows 11 machine for validation. No guarantee of zero telemetry, reduced memory use or improved game performance.
