# Unified cleanup scope

Single-file release: Build-SingleFile.ps1 embeds the complete local vendor archive as base64 into the entry, producing WindowsClean.ps1. The release extracts only its embedded archive into the secured run directory and uses it without additional downloads. Test-SingleFile.ps1 verifies syntax, exact entry freshness and every embedded file hash. Rebuild after entry/vendor changes. Prompt always downloads the raw single-file release, never reuses an old copy.

OneClick: default Unified/Console execution opts into G/U defaults and supported startup/extended candidates without prompts, excluding all printing/fax/XPS items. -ManualMenu restores the manual menu and is forwarded through elevation. Deduplicate tasks across inventories, choose disable not delay, preserve unknown/read-only items and existing exclusions. Forward switch through the single UAC launch. Agent stages and legacy modes do not inherit the default.

1. Preserve the custom backup/restore machinery and legacy modes.
2. Vendor the complete pinned Win11Debloat archive and MIT license; do not concatenate modular upstream files or download upstream at runtime.
3. Default Unified entry: UAC, environment/target validation, health baseline, immediate G/U menu before expensive inventories. X1 opts into startup inventory; X2 opts into service/component/task inventory. Only requested inventories run, followed by a candidate menu before cleanup. Explicit IDs replace defaults, NONE cancels, invalid/conflicting choices abort. Candidate defaults are empty, including Xbox. Driver checks remain within selected G3 execution.
4. Execute selected upstream defaults through a saved config in an isolated PowerShell process. Follow upstream restore-point behavior; skip Explorer restart. Exclude upstream telemetry/widgets effects that conflict with Defender/process preservation; use custom G1 instead.
5. Apply selected custom settings/drivers/startup/review items with existing backups and original-state checks. Do not guess unknown dependencies or touch excluded services/features.
6. Selectable aged temporary-file deletion and official DISM component cleanup, no direct WinSxS deletion or ResetBase. Record bytes, exit code and pending restart. No automatic restart, logoff, application termination or global memory trimming.
7. Save resource comparison, selection, logs and consolidated summary. Restore only journaled custom changes; upstream recovery and irreversible cleanup limits must be explicit.
8. Verify syntax, isolated selection/driver/resource/cache/backup logic, actual upstream config validation and static safeguards. Never run cleanup during development; end-to-end servicing/UAC/restoration needs disposable Windows 11 validation.

Agent UI protocol: Options exports base menu; Scan saves explicit choices and exports only requested candidates; Apply reuses the same run inventories and validates originals before mutation. Agent owns host multi-select windows, never console input. Cancel stops; empty candidate selection maps to NONE. Reject repeated Scan/Apply after application starts. Manual console mode remains supported.

Sources: pinned upstream source and `vendor/UPSTREAM.md`; Microsoft DISM component store cleanup documentation at https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder
