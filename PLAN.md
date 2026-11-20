# Windows custom cleanup script

Scope: extend the existing script; no Win11Debloat and no cleanup execution during development.

1. Per-run persistent backup/log/report directories and restore entry points. Require Windows PowerShell 5.1 and elevation without UAC.
2. Resolve interactive user from Explorer owners in the invoking session; use the loaded HKEY_USERS hive, not blindly HKCU. Fail closed for ambiguous users or organizational management.
3. Retain radio/telemetry/Copilot/Recall/widgets changes. Add Game Bar/controller preferences. Skip uncertain app-private settings rather than guessing.
4. Inventory five allowlisted drivers and device/filter dependencies. Back up actual Start and export each key before eligible changes; never unload drivers.
5. Read-only startup inventory: Run/RunOnce (both views), Startup folders, packaged StartupTask manifests/state, boot/logon scheduled tasks. Numbered review records include evidence and uncertainty. Disabling requires explicit IDs and scanned-state validation.
6. Restore only journaled changes from this run. Preserve Store, Gaming Services, Game Mode and WSearch; compare protected services before/after.
7. Run Windows PowerShell parser and isolated tests without executing cleanup.

Sources:
- https://learn.microsoft.com/en-us/windows/apps/develop/settings/settings-windows-11
- https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-applicationmanagement#allowgamedvr
- https://learn.microsoft.com/en-us/windows/client-management/manage-windows-copilot
- https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-windowsai
- https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-newsandinterests
- https://learn.microsoft.com/en-us/windows/privacy/configure-windows-diagnostic-data-in-your-organization

Microsoft documents AllowGameDVR CSP as enforced only on Windows 10 desktop. On Windows 11 use user capture preferences and record this policy limitation instead of claiming enforcement.
