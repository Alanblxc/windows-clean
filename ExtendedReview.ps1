# Loaded by Disable-WindowsFeatures.ps1, never execute directly.
function Write-HealthSnapshot($Label) {
    Try-Operation "Health $Label" {
        $osInfo=Get-CimInstance Win32_OperatingSystem
        $processes=@(Get-Process)
        Write-Json @{
            Time=(Get-Date).ToString('o'); LastBoot=$osInfo.LastBootUpTime
            ProcessCount=$processes.Count; FreeMemoryKB=$osInfo.FreePhysicalMemory; TotalMemoryKB=$osInfo.TotalVisibleMemorySize
            CpuLoadPercent=(Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
            Processes=@($processes | Select-Object Id,ProcessName,SessionId,CPU,WorkingSet64)
            Sessions=(& "$env:SystemRoot\System32\quser.exe" 2>&1 | Out-String)
            Note='Process CPU is cumulative time, not instantaneous load. No sessions terminated. Compare equivalent workloads after manual restart and 3-5 minutes idle; no inferred boot-time improvement.'
        } (Join-Path $RunDirectory "health-$Label-$(Get-Date -Format yyyyMMdd-HHmmss).json")
    }
}
function Add-Review($Kind,$Name,$Original,$Action,$Impact,$Supported=$true) {
    $script:review.Add([pscustomobject]@{ Id=$script:review.Count+1; Kind=$Kind; Name=$Name; Original=$Original; Action=$Action; Impact=$Impact; Supported=$Supported })
}
function Write-ExtendedReview {
    $script:review=New-Object 'System.Collections.Generic.List[object]'
    Try-Operation 'Review services' {
        foreach ($service in Get-CimInstance Win32_Service) {
            $key=Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($service.Name)"
            if ($service.Name -in @('Fax','XboxGipSvc','XboxNetApiSvc','XblAuthManager','XblGameSave','Spooler','bthserv')) {
                $wanted=if ($service.Name -eq 'Fax') {4} else {3}
                if ($key.Start -ne $wanted) {
                    Add-Review 'Service' $service.Name @{ Start=$key.Start; Wanted=$wanted; Path=$service.PathName } 'Change startup only' 'Confirm no need for automatic fax/Xbox/printing (including PDF)/Bluetooth. No running service stopped.'
                }
            } elseif ($service.StartMode -eq 'Auto') {
                $e=Get-CommandEvidence $service.PathName
                if ($e.File -and $e.File -notlike "$env:SystemRoot\*" -and $e.Publisher -notmatch 'Microsoft') {
                    Add-Review 'ThirdPartyService' $service.Name @{ Path=$service.PathName; Publisher=$e.Publisher; Signature=$e.Signature } 'ReadOnly' 'Dependencies/security/hardware needs not established; no automatic disable.' $false
                }
            }
        }
    }
    Try-Operation 'Review optional features' {
        foreach ($feature in Get-WindowsOptionalFeature -Online | Where-Object { $_.State -eq 'Enabled' -and $_.FeatureName -in @('WindowsMediaPlayer','Printing-XPSServices-Features','FaxServicesClientPackage') }) {
            Add-Review 'Feature' $feature.FeatureName @{ State='Enabled' } 'Disable, keep payload' 'Legacy player, XPS printing or fax may be needed by apps/workflows. Manual restart may be needed.'
        }
        foreach ($cap in Get-WindowsCapability -Online | Where-Object { $_.State -eq 'Installed' -and $_.Name -match '^Media\.WindowsMediaPlayer\.' }) {
            Add-Review 'Capability' $cap.Name @{ State='Installed' } 'Remove capability' 'Legacy media capability. Restore may require network or matching installation media; restart may be needed.'
        }
    }
    Try-Operation 'Review all third-party task triggers' {
        foreach ($task in Get-ScheduledTask | Where-Object TaskPath -NotLike '\Microsoft\*') {
            $xml=Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
            $command=(@($task.Actions | ForEach-Object { '"'+$_.Execute+'" '+$_.Arguments }) -join ' ; ')
            $advice=Get-StartupAdvice $task.TaskName $command
            $original=@{ Xml=$xml; TaskPath=$task.TaskPath; TaskName=$task.TaskName; Command=$command; Triggers=@($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }); Enabled=$task.Settings.Enabled }
            if ($task.Settings.Enabled -and $advice.Recommend) {
                Add-Review 'Task' ($task.TaskPath+$task.TaskName) $original 'Disable' 'Optional launcher task. Read full XML/actions/triggers; updates/background actions stop.'
            } else { Add-Review 'TaskInventory' ($task.TaskPath+$task.TaskName) $original 'ReadOnly' 'Unknown purpose/dependencies or already disabled; retained.' $false }
            # Existing tasks only: never migrate Run entries into tasks with different security context.
            if ($task.Settings.Enabled -and $advice.Recommend -and @($task.Actions).Count -eq 1 -and @($task.Triggers).Count -eq 1 -and $original.Triggers[0] -eq 'MSFT_TaskLogonTrigger' -and $task.Principal.LogonType -eq 'Interactive') {
                Add-Review 'Delay' ($task.TaskPath+$task.TaskName) $original 'Delay login by 60 seconds' 'Keeps auto-launch; do not select both disable and delay for the same task.'
            }
        }
    }
    Write-Json @($script:review.ToArray()) (Join-Path $RunDirectory 'extended-review.json')
    $lines=@('# Extended review: select explicit ReviewIds; no selection means keep all.','Excluded: SysMain, WSearch, wireless display, third-party app background permissions. System maintenance tasks retained.')
    foreach ($item in $script:review) {
        $lines += "`n## #$($item.Id) $($item.Name)`nType: $($item.Kind); action: $($item.Action); selectable: $($item.Supported)`nImpact: $($item.Impact)`nEvidence/original:`n$($item.Original | ConvertTo-Json -Depth 15)"
    }
    $lines | Set-Content (Join-Path $RunDirectory 'extended-review.md') -Encoding UTF8
    Log 'AWAITING_SELECTION' 'Extended review' 'Read extended-review.md; explicit ApplyReview/ReviewIds required. Unknown services/tasks read-only. Run Review periodically, not via automatic startup.'
}
function Apply-ExtendedItem($Item) {
    if (-not $Item.Supported) { throw 'Read-only item.' }
    switch ($Item.Kind) {
        'Service' {
            if ($Item.Name -notin @('Fax','XboxGipSvc','XboxNetApiSvc','XblAuthManager','XblGameSave','Spooler','bthserv')) { throw 'Not allowlisted.' }
            $path="HKLM:\SYSTEM\CurrentControlSet\Services\$($Item.Name)"
            if ((Get-ItemProperty $path).Start -ne $Item.Original.Start) { throw 'State changed since review.' }
            # Registry Start is journaled by the shared restore mechanism. Do not stop current service.
            Change-Reg $path 'Start' $Item.Original.Wanted 'DWord' 'Review'
            if ((Get-ItemProperty $path).Start -ne $Item.Original.Wanted) { throw 'Startup readback failed.' }
            Log 'NOTE' $Item.Name 'Startup configuration read back; takes effect after manual restart, current service untouched.'
            return
        }
        { $_ -in @('Feature','Capability','Delay') } {
            # Validate the scanned state before creating a recoverable change entry.
            if ($Item.Kind -eq 'Feature' -and ($Item.Name -notin @('WindowsMediaPlayer','Printing-XPSServices-Features','FaxServicesClientPackage') -or (Get-WindowsOptionalFeature -Online -FeatureName $Item.Name).State -ne 'Enabled')) { throw 'Ineligible feature.' }
            if ($Item.Kind -eq 'Capability' -and ($Item.Name -notmatch '^Media\.WindowsMediaPlayer\.' -or (Get-WindowsCapability -Online -Name $Item.Name).State -ne 'Installed')) { throw 'Ineligible capability.' }
            if ($Item.Kind -eq 'Delay' -and (Export-ScheduledTask -TaskName $Item.Original.TaskName -TaskPath $Item.Original.TaskPath) -ne $Item.Original.Xml) { throw 'Task changed since review.' }
            $entry=[pscustomobject]@{ Type='Extended'; Group='Review'; Item=$Item; Pending=$true; Restored=$false; AppliedXml=$null }
            $script:journal.Changes += $entry; Save-Journal
            if ($Item.Kind -eq 'Feature') {
                if ($Item.Name -notin @('WindowsMediaPlayer','Printing-XPSServices-Features','FaxServicesClientPackage') -or (Get-WindowsOptionalFeature -Online -FeatureName $Item.Name).State -ne 'Enabled') { throw 'Ineligible feature.' }
                $result=Disable-WindowsOptionalFeature -Online -FeatureName $Item.Name -NoRestart
                if ((Get-WindowsOptionalFeature -Online -FeatureName $Item.Name).State -notin @('Disabled','DisablePending')) { throw 'Feature readback failed.' }
            } elseif ($Item.Kind -eq 'Capability') {
                if ($Item.Name -notmatch '^Media\.WindowsMediaPlayer\.' -or (Get-WindowsCapability -Online -Name $Item.Name).State -ne 'Installed') { throw 'Ineligible capability.' }
                $result=Remove-WindowsCapability -Online -Name $Item.Name
                if ((Get-WindowsCapability -Online -Name $Item.Name).State -notin @('NotPresent','UninstallPending')) { throw 'Capability readback failed.' }
            } else {
                $old=$Item.Original
                if ((Export-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath) -ne $old.Xml) { throw 'Task changed since scan.' }
                [xml]$xml=$old.Xml
                $ns=New-Object Xml.XmlNamespaceManager($xml.NameTable); $ns.AddNamespace('t',$xml.DocumentElement.NamespaceURI)
                $trigger=$xml.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger',$ns)
                if (-not $trigger) { throw 'No login trigger.' }
                $delay=$trigger.SelectSingleNode('t:Delay',$ns)
                if (-not $delay) { $delay=$xml.CreateElement('Delay',$xml.DocumentElement.NamespaceURI); $trigger.AppendChild($delay) | Out-Null }
                $delay.InnerText='PT60S'; $entry.AppliedXml=$xml.OuterXml; Save-Journal
                Register-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath -Xml $xml.OuterXml -Force | Out-Null
                [xml]$actual=Export-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath
                if ($actual.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:Delay',$ns).InnerText -ne 'PT60S') { throw 'Delay readback failed.' }
                $entry.AppliedXml=$actual.OuterXml
            }
            Log 'NOTE' $Item.Name 'Configuration verified; restart may be needed. No restart requested.'
        }
        'Task' {
            Disable-StartupRow ([pscustomobject]@{ Id="review-$($Item.Id)"; Kind='Task'; Name=$Item.Name; Supported=$true; Enabled='Enabled'; Original=$Item.Original })
            return
        }
        default { throw 'Unsupported action.' }
    }
    $entry.Pending=$false; Save-Journal
    Log 'VERIFIED' $Item.Name "Selected review #$($Item.Id) applied."
}
function Restore-Extended($Entry) {
    $item=$Entry.Item
    switch ($item.Kind) {
        'Feature' {
            $result=Enable-WindowsOptionalFeature -Online -FeatureName $item.Name -NoRestart
            if ((Get-WindowsOptionalFeature -Online -FeatureName $item.Name).State -notin @('Enabled','EnablePending')) { throw 'Feature restore readback failed.' }
        }
        'Capability' {
            $result=Add-WindowsCapability -Online -Name $item.Name
            if ((Get-WindowsCapability -Online -Name $item.Name).State -notin @('Installed','InstallPending')) { throw 'Capability restore readback failed.' }
        }
        'Delay' {
            $old=$item.Original
            [xml]$current=Export-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath
            if ($current.OuterXml -ne $Entry.AppliedXml) { throw 'Task changed after delay; preserve it.' }
            Register-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath -Xml $old.Xml -Force | Out-Null
            [xml]$check=Export-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath
            [xml]$original=$old.Xml
            if ($check.OuterXml -ne $original.OuterXml) { throw 'Delay restore readback failed.' }
        }
        default { throw 'Unknown extended backup.' }
    }
}
