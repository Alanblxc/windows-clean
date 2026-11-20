# Direct Windows settings, no preflight or inventory. HKCU is the executing user.
<# Settings adapted from Raphire/Win11Debloat. MIT License
Copyright (c) 2020 Raphire (https://github.com/Raphire)
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>
$ErrorActionPreference = 'Stop'
$failed = [Collections.Generic.List[string]]::new()
function Step($label, [scriptblock]$action) {
    try { & $action; Write-Host "[OK] $label" }
    catch { $failed.Add($label); Write-Warning "[FAILED] $label : $($_.Exception.Message)" }
}
function Values($key, [int]$data, [string[]]$names) {
    foreach ($name in $names) {
        Step "$key\$name" {
            & "$env:SystemRoot\System32\reg.exe" add $key /v $name /t REG_DWORD /d $data /f /reg:64
            if ($LASTEXITCODE -ne 0) { throw "reg.exe exit $LASTEXITCODE" }
        }
    }
}
$up = 'HKCU\Software\Policies\Microsoft\Windows'
$mp = 'HKLM\SOFTWARE\Policies\Microsoft\Windows'
$cv = 'HKCU\Software\Microsoft\Windows\CurrentVersion'
Values "$cv\Explorer\Advanced" 0 @('HideFileExt','TaskbarDa','ShowCopilotButton','Start_IrisRecommendations','ShowSyncProviderNotifications','Start_AccountNotifications')
Values "$cv\ContentDeliveryManager" 0 @('SubscribedContent-310093Enabled','SubscribedContent-338388Enabled','SystemPaneSuggestionsEnabled','SubscribedContent-338389Enabled','SoftLandingEnabled','SubscribedContent-338393Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-353698Enabled','SilentInstalledAppsEnabled','SubscribedContent-338387Enabled','RotatingLockScreenOverlayEnabled')
Values "$cv\SystemSettings\AccountNotifications" 0 'EnableAccountNotifications'
Values "$cv\UserProfileEngagement" 0 'ScoobeSystemSettingEnabled'
Values "$cv\Notifications\Settings\Windows.SystemToast.Suggested" 0 'Enabled'
Values "$cv\Notifications\Settings\Windows.SystemToast.BackupReminder" 0 'Enabled'
Values "$cv\Mobility" 0 'OptedIn'
Values "$cv\GameDVR" 0 'AppCaptureEnabled'
Values 'HKCU\System\GameConfigStore' 0 'GameDVR_Enabled'
Values 'HKCU\Software\Microsoft\GameBar' 0 'UseNexusForGameBarEnabled'
Values "$up\Explorer" 1 'DisableSearchBoxSuggestions'
Values "$mp\Windows Search" 0 @('AllowCortana','CortanaConsent')
Values "$mp\DataCollection" 0 'AllowTelemetry'
Values "$mp\Explorer" 1 'HideRecommendedPersonalizedSites'
Values "$mp\CloudContent" 1 'DisableCopilotPinScreen'
Values 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' 0 'AllowNewsAndInterests'
foreach ($p in @($up,$mp)) {
    Values "$p\WindowsCopilot" 1 'TurnOffWindowsCopilot'
    Values "$p\WindowsAI" 1 @('DisableAIDataAnalysis','DisableClickToDo')
}
Values "$mp\WindowsAI" 1 'TurnOffSavingSnapshots'
Values "$mp\WindowsAI" 0 'AllowRecallEnablement'
$edge = 'HKLM\SOFTWARE\Policies\Microsoft\Edge'
Values $edge 0 @('NewTabPageContentEnabled','EdgeShoppingAssistantEnabled','TabServicesEnabled','AlternateErrorPagesEnabled','UserFeedbackAllowed','ShowRecommendationsEnabled','WalletDonationEnabled','ShowMicrosoftRewards','DefaultBrowserSettingEnabled','DefaultBrowserSettingsCampaignEnabled','SpotlightExperiencesAndRecommendationsEnabled','ShowAcrobatSubscriptionButton')
Values $edge 1 @('NewTabPageHideDefaultTopSites','HideFirstRunExperience')
foreach ($svc in @('RmSvc','DiagTrack','dmwappushservice')) {
    Step "Disable $svc" { Set-Service -Name $svc -StartupType Disabled }
    Step "Stop $svc" { Stop-Service -Name $svc }
}
Step 'Set WSAIFabricSvc to manual' { Set-Service -Name WSAIFabricSvc -StartupType Manual }
Step 'Remove current-user Copilot package if installed' {
    Get-AppxPackage -Name Microsoft.Copilot | Remove-AppxPackage
}
Step 'Windows component cleanup' {
    & "$env:SystemRoot\System32\dism.exe" /Online /Cleanup-Image /StartComponentCleanup /NoRestart
    if ($LASTEXITCODE -eq 3010) { Write-Host 'Restart required; restart manually.' }
    elseif ($LASTEXITCODE -ne 0) { throw "DISM exit $LASTEXITCODE" }
}
Write-Host "Finished. Failed commands: $($failed.Count)"
if ($failed.Count) { $failed | ForEach-Object { Write-Host " - $_" }; exit 1 }
exit 0
