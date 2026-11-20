# Unified cleanup scope

1. Preserve the custom backup/restore machinery and legacy modes.
2. Vendor the complete pinned Win11Debloat archive and MIT license; do not concatenate modular upstream files or download upstream at runtime.
3. Default Unified entry: UAC, environment/target validation, health baseline, read-only startup/service/component/task inventories, one option menu before any cleanup. Explicit IDs replace defaults, NONE cancels, invalid/conflicting choices abort.
4. Execute selected upstream defaults through a saved config in an isolated PowerShell process. Follow upstream restore-point behavior; skip Explorer restart. Exclude upstream telemetry/widgets effects that conflict with Defender/process preservation; use custom G1 instead.
5. Apply selected custom settings/drivers/startup/review items with existing backups and original-state checks. Do not guess unknown dependencies or touch excluded services/features.
6. Selectable aged temporary-file deletion and official DISM component cleanup, no direct WinSxS deletion or ResetBase. Record bytes, exit code and pending restart. No automatic restart, logoff, application termination or global memory trimming.
7. Save resource comparison, selection, logs and consolidated summary. Restore only journaled custom changes; upstream recovery and irreversible cleanup limits must be explicit.
8. Verify syntax, isolated selection/driver/resource/cache/backup logic, actual upstream config validation and static safeguards. Never run cleanup during development; end-to-end servicing/UAC/restoration needs disposable Windows 11 validation.

Sources: pinned upstream source and `vendor/UPSTREAM.md`; Microsoft DISM component store cleanup documentation at https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder
