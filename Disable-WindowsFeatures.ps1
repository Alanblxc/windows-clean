#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Disable','ScanStartup','DisableStartup','Review','ApplyReview','Restore','RestoreDrivers')]
    [string]$Mode = 'Disable',
    [string]$RunDirectory,
    [int[]]$StartupIds = @(),
    [int[]]$ReviewIds = @()
)

# Windows PowerShell 5.1 only. No downloads, UAC, restart or Win11Debloat execution.
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess) {
    throw 'Run in 64-bit Windows PowerShell 5.1 (powershell.exe), not pwsh.exe.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Escapes keep this file compatible with Windows PowerShell 5.1 without a UTF-8 BOM.
    throw ([regex]::Unescape('\u8bf7\u4ee5\u7ba1\u7406\u5458\u8eab\u4efd\u542f\u52a8 AI \u6240\u5728\u5e94\u7528\u540e\u91cd\u65b0\u6267\u884c'))
}
$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ([int]$os.CurrentBuildNumber -lt 22000) { throw 'Windows 11 required.' }

function Get-DriverDecision($Name, $Exists, $State, $Dependencies, $Complete) {
    if ($Name -notin @('1394ohci','beep','HidIr','circlass','usbcir')) { return 'NotAllowlisted' }
    if (-not $Exists) { return 'NotInstalled' }
    if ($Name -eq 'beep') { return 'Eligible' }
    if ($State -ne 'Stopped') { return 'Running' }
    if (@($Dependencies).Count -gt 0) { return 'DeviceDependency' }
    if (-not $Complete) { return 'UncertainInventory' }
    return 'Eligible'
}

function Get-StartupAdvice($Name, $Command) {
    $text = "$Name $Command"
    if ($text -match '(?i)defender|security|antivirus|backup|encrypt|credential|accessibility|nvidia|amd|intel|realtek|synaptics|touchpad|hotkey|audio|power|driver|vpn|remote|onedrive|dropbox|sync|logitech|razer|corsair') {
        return @{ Recommend=$false; Purpose='Security, hardware or needs-dependent component'; Impact='Keep unless its role and personal requirements are confirmed.' }
    }
    if ($text -match '(?i)(steam\.exe|epicgameslauncher\.exe|spotify\.exe|discord\.exe)(\s|"|$)') {
        return @{ Recommend=$true; Purpose='Optional launcher / chat / media startup'; Impact='No automatic launch or tray notifications until opened manually; application remains installed.' }
    }
    return @{ Recommend=$false; Purpose='Unknown or not confidently optional'; Impact='Keep; identify purpose and dependencies before changing.' }
}

function Write-Json($Object, $Path) {
    $temporary = "$Path.new"
    $Object | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Log($Status, $Item, $Detail) {
    $line = [pscustomobject]@{ Time=(Get-Date).ToString('o'); Status=$Status; Item=$Item; Detail=$Detail }
    $script:report.Add($line)
    Write-Host "[$Status] $Item : $Detail"
    Write-Json @($script:report.ToArray()) (Join-Path $RunDirectory 'report.json')
}
function Save-Journal { Write-Json $script:journal (Join-Path $RunDirectory 'original-values.json') }
function Try-Operation($Name, [scriptblock]$Action) {
    try { & $Action } catch { Log 'FAILED' $Name $_.Exception.Message }
}
function Get-RegOriginal($Path, $Name) {
    $key = if (Test-Path -LiteralPath $Path) { Get-Item -LiteralPath $Path } else { $null }
    $exists = $null -ne $key -and $key.GetValueNames() -contains $Name
    return [pscustomobject]@{
        Path=$Path; Name=$Name; Exists=$exists
        Kind=$(if ($exists) { $key.GetValueKind($Name).ToString() } else { 'DWord' })
        Value=$(if ($exists) { $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null })
    }
}
function Write-RegValue($Path, $Name, $Value, $Kind) {
    # JSON deserialization does not retain the CLR array/integer type expected by the registry provider.
    switch ($Kind) {
        'Binary' { $Value=[byte[]]$Value }
        'MultiString' { $Value=[string[]]$Value }
        'DWord' { $Value=[int]$Value }
        'QWord' { $Value=[long]$Value }
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
    $check = Get-RegOriginal $Path $Name
    if ($check.Kind -ne $Kind -or ($check.Value | ConvertTo-Json -Compress) -ne ($Value | ConvertTo-Json -Compress)) { throw 'Registry readback failed.' }
}
function Change-Reg($Path, $Name, $Value, $Kind='DWord', $Group='Settings') {
    $old = Get-RegOriginal $Path $Name
    if ($old.Exists -and $old.Kind -eq $Kind -and "$($old.Value)" -eq "$Value") { Log 'ALREADY' $Name 'Original value already matches.'; return }
    $entry = [pscustomobject]@{ Type='Registry'; Group=$Group; Original=$old; Applied=$Value; AppliedKind=$Kind; Pending=$true; Restored=$false }
    $script:journal.Changes += $entry
    Save-Journal # Fail before mutation if backup cannot be written.
    Write-RegValue $Path $Name $Value $Kind
    $entry.Pending = $false; Save-Journal
    Log 'WRITTEN' $Name 'Backed up and read back; runtime effect not tested.'
}
function Get-ProtectedServices {
    @(foreach ($name in @('WSearch','SysMain','GamingServices','GamingServicesNet')) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service) {
            $key = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
            [pscustomobject]@{ Name=$name; Start=$key.Start; Delayed=$key.DelayedAutoStart; Status="$($service.Status)" }
        }
    })
}
function Get-TargetUser {
    # Session-scoped Explorer owners avoid confusing elevated credentials with the user.
    $session = (Get-Process -Id $PID).SessionId
    $owners = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$session" | ForEach-Object {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid
        if ($owner.ReturnValue -ne 0) { throw 'Cannot determine Explorer owner.' }
        $owner.Sid
    } | Sort-Object -Unique)
    if ($owners.Count -ne 1) { throw 'No unique interactive Explorer owner in the current session; user changes skipped.' }
    if (-not (Test-Path "Registry::HKEY_USERS\$($owners[0])")) { throw 'Target user hive is not loaded.' }
    $profile = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($owners[0])"
    [pscustomobject]@{ Sid=$owners[0]; Hive="Registry::HKEY_USERS\$($owners[0])"; Profile=$profile.ProfileImagePath; Session=$session }
}
function Get-ManagementState {
    # Conservative: registered work/school enrollment also causes a skip.
    try {
        $domain = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
        $enrolled = $false
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Enrollments') {
            $enrolled = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop | Where-Object {
                $p = Get-ItemProperty $_.PSPath
                $p.ProviderID -or $p.EnrollmentType
            }).Count -gt 0
        }
        $join = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo'
        if ($domain -or $enrolled -or $join) { return 'ManagedOrEnrolled' }
        return 'Personal'
    } catch { return 'Unknown' }
}
function Disable-ServiceBackedUp($Name) {
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) { Log 'SKIP' $Name 'Not installed.'; return }
    $key = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if ($key.Start -eq 4 -and $service.Status -eq 'Stopped') { Log 'ALREADY' $Name 'Disabled and stopped.'; return }
    $entry = [pscustomobject]@{ Type='Service'; Group='Settings'; Name=$Name; Start=$key.Start; Delayed=($key.DelayedAutoStart -eq 1); Running=($service.Status -eq 'Running'); Pending=$true; Restored=$false }
    $script:journal.Changes += $entry; Save-Journal
    Set-Service $Name -StartupType Disabled
    Stop-Service $Name -ErrorAction Stop
    $service = Get-Service $Name
    if ($service.StartType -ne 'Disabled' -or $service.Status -ne 'Stopped') { throw 'Service readback failed.' }
    $entry.Pending=$false; Save-Journal
    Log 'VERIFIED' $Name 'Startup Disabled, current status Stopped.'
}

function Invoke-BaseSettings {
    $telemetry = if ($os.EditionID -match '^(Enterprise|Education|IoTEnterprise)') { 0 } else { 1 }
    foreach ($setting in @(
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection','AllowTelemetry',$telemetry),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI','DisableAIDataAnalysis',1),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI','AllowRecallEnablement',0),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Dsh','AllowNewsAndInterests',0)
    )) { Try-Operation $setting[1] { Change-Reg $setting[0] $setting[1] $setting[2] } }
    foreach ($name in @('RmSvc','DiagTrack','dmwappushservice')) { Try-Operation $name { Disable-ServiceBackedUp $name } }
    Log 'NOTE' 'Telemetry' 'Lowest supported policy requested; Home/Pro cannot guarantee zero telemetry. Policies may not be honored by every edition.'
    if (-not $script:target) { return }
    $hive = $script:target.Hive
    foreach ($setting in @(
        @("$hive\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot",'TurnOffWindowsCopilot',1),
        @("$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced",'ShowCopilotButton',0),
        @("$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced",'TaskbarDa',0)
    )) { Try-Operation $setting[1] { Change-Reg $setting[0] $setting[1] $setting[2] } }
    if ($script:target.Sid -eq $identity.User.Value) {
        Try-Operation 'Copilot app' {
            $apps = @(Get-AppxPackage -Name Microsoft.Copilot)
            if (-not $apps.Count) { Log 'ALREADY' 'Copilot app' 'Not installed for target user.'; return }
            $script:journal.CopilotPackages = @($apps | Select-Object Name,PackageFullName,PackageFamilyName)
            Save-Journal
            $apps | Remove-AppxPackage -ErrorAction Stop
            if (Get-AppxPackage -Name Microsoft.Copilot) { throw 'Copilot still installed.' }
            Log 'REMOVED' 'Copilot app' 'Current target user only. Restore manually from Microsoft Store.'
        }
    } else { Log 'SKIP' 'Copilot app' 'Executing account differs from target user; no cross-account Appx removal.' }
}

function Invoke-GameSettings {
    if (-not $script:target) { Log 'SKIP' 'Game Bar' 'No reliable target user.'; return }
    $hive=$script:target.Hive
    Log 'SKIP' 'Xbox internal settings' 'App-private launch/background preferences are not reliably configurable here. Startup entry inventory handled separately.'
    $apps = @(Get-AppxPackage -User $script:target.Sid -Name Microsoft.XboxGamingOverlay)
    if (-not $apps.Count) { Log 'NOT_APPLICABLE' 'Game Bar' 'App is not installed for the target user.'; return }
    foreach ($setting in @(
        @("$hive\Software\Microsoft\Windows\CurrentVersion\GameDVR",'AppCaptureEnabled'),
        @("$hive\System\GameConfigStore",'GameDVR_Enabled'),
        @("$hive\Software\Microsoft\GameBar",'UseNexusForGameBarEnabled')
    )) { Try-Operation $setting[1] { Change-Reg $setting[0] $setting[1] 0 } }
    # HistoricalCaptureEnabled is version-sensitive: modify only a pre-existing DWORD.
    $capture = Get-RegOriginal "$hive\Software\Microsoft\Windows\CurrentVersion\GameDVR" 'HistoricalCaptureEnabled'
    if ($capture.Exists -and $capture.Kind -eq 'DWord') {
        Try-Operation 'HistoricalCaptureEnabled' { Change-Reg $capture.Path $capture.Name 0 }
    } else { Log 'SKIP' 'Historical capture toggle' 'No existing recognized DWORD. Capture is disabled above; no guessed value created.' }
    Log 'SKIP' 'Game recording policy' 'AllowGameDVR CSP documented as enforced on Windows 10 desktop only; not claimed effective on Windows 11.'
    Log 'SKIP' 'Game Bar master/background permission' 'No verified version-independent independent setting; no global background-app policy used.'
}

function Invoke-SelectedDrivers {
    $complete=$true; $devices=@(); $filters=@(); $systemDrivers=@()
    try {
        # Win32_PnPEntity alone can miss phantom devices. Read all installed PnP devices too.
        $devices = @(Get-PnpDevice -ErrorAction Stop)
        $systemDrivers = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop)
        foreach ($root in @('HKLM:\SYSTEM\CurrentControlSet\Enum','HKLM:\SYSTEM\CurrentControlSet\Control\Class')) {
            $keys = @(Get-Item $root) + @(Get-ChildItem $root -Recurse -ErrorAction Stop)
            foreach ($key in $keys) {
                $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                foreach ($field in @('Service','UpperFilters','LowerFilters')) {
                    foreach ($value in @($p.$field)) { if ($value) { $filters += [pscustomobject]@{ Source=$key.Name; Reference="$value" } } }
                }
            }
        }
        # Driver service dependencies may require another driver without a direct PnP reference.
        foreach ($key in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction Stop) {
            $p = Get-ItemProperty $key.PSPath -ErrorAction Stop
            foreach ($dependency in @($p.DependOnService)) { if ($dependency) { $filters += [pscustomobject]@{ Source=$key.Name; Reference="$dependency" } } }
        }
    } catch { $complete=$false; Log 'NOTE' 'Driver inventory' "Incomplete: $($_.Exception.Message). Non-beep targets will be preserved." }
    Write-Json @{ Complete=$complete; Devices=@($devices | Select-Object InstanceId,Class,FriendlyName,Status); References=$filters } (Join-Path $RunDirectory 'device-inventory.json')
    foreach ($name in @('1394ohci','beep','HidIr','circlass','usbcir')) {
        Try-Operation "Driver $name" {
            $path="HKLM:\SYSTEM\CurrentControlSet\Services\$name"
            $exists=Test-Path $path
            $driver=@($systemDrivers | Where-Object Name -eq $name)
            $state=if ($driver.Count -eq 1) { "$($driver[0].State)" } else { 'Unknown' }
            $refs=@($filters | Where-Object Reference -eq $name | ForEach-Object { "$($_.Source) [$($_.Reference)]" })
            # Broad hardware matches deliberately err toward preserving drivers.
            $pattern=if ($name -eq '1394ohci') { '1394|firewire|i[ .]?link' } else { 'infrared|consumer.?ir|\bcir\b|\u7ea2\u5916' }
            if ($name -ne 'beep') {
                $refs += @($devices | Where-Object { "$($_.Class) $($_.FriendlyName) $($_.InstanceId)" -match $pattern } | ForEach-Object InstanceId)
            }
            $decision=Get-DriverDecision $name $exists $state $refs $complete
            $old=$null; $final=$null
            if ($exists) {
                $original=Get-RegOriginal $path 'Start'
                $old=$original.Value; $final=$old
                if (-not $original.Exists -or $original.Kind -ne 'DWord') { $decision='InvalidStartValue' }
            }
            if ($exists -and $old -eq 4) { $decision='AlreadyDisabled' }
            if ($decision -eq 'Eligible') {
                $export=Join-Path $RunDirectory "$name-original.reg"
                & "$env:SystemRoot\System32\reg.exe" export "HKLM\SYSTEM\CurrentControlSet\Services\$name" $export /y | Out-Null
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path $export)) { throw 'reg.exe export failed; driver not changed.' }
                Change-Reg $path 'Start' 4 'DWord' 'Drivers'
                $final=(Get-ItemProperty $path).Start
            }
            $row=[pscustomobject]@{ Name=$name; OriginalStart=$old; FinalStart=$final; CurrentState=$state; Decision=$decision; Dependencies=$refs; NeedsRestart=($decision -eq 'Eligible') }
            $script:journal.Drivers += $row; Save-Journal
            Log $decision "Driver $name" "Start $old -> $final; running state=$state; references=$($refs -join '; '). Startup configuration does not unload a driver."
        }
    }
}

function Get-CommandEvidence($Command) {
    $file=$null
    if ($Command -match '^\s*"([^"]+)"') { $file=$matches[1] }
    elseif ($Command -match '^\s*(.+?\.(?:exe|com|bat|cmd|ps1|lnk))(?=\s|$)') { $file=$matches[1] }
    $publisher='Unknown'; $signature='Unknown'
    if ($file -and [IO.Path]::IsPathRooted($file) -and $file -notmatch '%') {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            try {
                $sig=Get-AuthenticodeSignature -LiteralPath $file
                $signature="$($sig.Status)"
                if ($sig.SignerCertificate) { $publisher=$sig.SignerCertificate.Subject }
                else { $publisher=(Get-Item -LiteralPath $file).VersionInfo.CompanyName }
            } catch { $signature='Read failed' }
        }
    }
    [pscustomobject]@{ File=$file; Publisher=$publisher; Signature=$signature }
}
function Add-StartupRow($Kind, $Name, $Location, $Command, $Enabled, $Original, $Supported) {
    $evidence=Get-CommandEvidence $Command
    $advice=Get-StartupAdvice $Name $Command
    $script:startup.Add([pscustomobject]@{
        Id=($script:startup.Count+1); Kind=$Kind; Name=$Name; Location=$Location; Command=$Command
        Enabled=$Enabled; Publisher=$evidence.Publisher; Signature=$evidence.Signature; Executable=$evidence.File
        Recommend=($advice.Recommend -and $Enabled -eq 'Enabled' -and $Supported)
        Purpose=$advice.Purpose; Impact=$advice.Impact
        Uncertainty='Signature is identity evidence only. Dependencies and personal need are not proven. Arguments/wrappers may obscure identity.'
        Method=$(switch ($Kind) { 'Registry' {'Back up then remove only this startup value'} 'Folder' {'Back up then move only this shortcut/file out of startup'} 'Task' {'Export XML then disable only this task'} default {'Read-only: unsupported automatic disable'} })
        Supported=$Supported; Original=$Original; XboxHandled=$false
    })
}
function Get-StartupInventory {
    $script:startup=New-Object 'System.Collections.Generic.List[object]'
    $roots=@('HKLM:\SOFTWARE','HKLM:\SOFTWARE\WOW6432Node')
    if ($script:target) { $roots+=@("$($script:target.Hive)\SOFTWARE","$($script:target.Hive)\SOFTWARE\WOW6432Node") }
    foreach ($root in $roots) {
        foreach ($leaf in @('Run','RunOnce')) {
            $path="$root\Microsoft\Windows\CurrentVersion\$leaf"
            Try-Operation "Scan $path" {
                if (-not (Test-Path $path)) { return }
                $key=Get-Item $path
                foreach ($name in $key.GetValueNames()) {
                    $original=Get-RegOriginal $path $name
                    if ($original.Kind -notin @('String','ExpandString')) { continue }
                    # StartupApproved State: 2 enabled, 3 disabled. Unknown states are not guessed.
                    $approved=$null; $state='Enabled'
                    if ($leaf -eq 'Run') {
                        $base=if ($root -like 'HKLM:*') { 'HKLM:\SOFTWARE' } else { "$($script:target.Hive)\SOFTWARE" }
                        $bucket=if ($root -like '*WOW6432Node') { 'Run32' } else { 'Run' }
                        $approved=Get-RegOriginal "$base\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$bucket" $name
                        if ($approved.Exists) { $state=if ($approved.Value[0] -eq 3) { 'Disabled' } elseif ($approved.Value[0] -eq 2) { 'Enabled' } else { 'Unknown' } }
                    }
                    Add-StartupRow 'Registry' $name $path $original.Value $state @{ Value=$original; Approval=$approved } $true
                }
            }
        }
    }
    $folders=@([Environment]::GetFolderPath('CommonStartup'))
    if ($script:target) {
        $shell=Get-RegOriginal "$($script:target.Hive)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" 'Startup'
        if ($shell.Exists) { $folders += ($shell.Value -replace '(?i)%USERPROFILE%', $script:target.Profile -replace '(?i)%APPDATA%', "$($script:target.Profile)\AppData\Roaming") }
        else { $folders+=Join-Path $script:target.Profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' }
    }
    foreach ($folder in $folders) {
        Try-Operation "Scan folder $folder" {
            if ($folder -match '%' -or -not (Test-Path -LiteralPath $folder)) { Log 'SKIP' 'Startup folder' "Unresolved/unavailable: $folder"; return }
            foreach ($file in Get-ChildItem -LiteralPath $folder -File -Force | Where-Object Name -ne 'desktop.ini') {
                $command=$file.FullName
                if ($file.Extension -eq '.lnk') {
                    $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($file.FullName)
                    $command='"' + $shortcut.TargetPath + '" ' + $shortcut.Arguments
                }
                $base=if ($folder -eq [Environment]::GetFolderPath('CommonStartup')) { 'HKLM:\SOFTWARE' } else { "$($script:target.Hive)\SOFTWARE" }
                $approved=Get-RegOriginal "$base\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder" $file.Name
                $state='Enabled'
                if ($approved.Exists) { $state=if ($approved.Value[0] -eq 3) { 'Disabled' } elseif ($approved.Value[0] -eq 2) { 'Enabled' } else { 'Unknown' } }
                Add-StartupRow 'Folder' $file.Name $file.FullName $command $state @{ Hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash; Approval=$approved } $true
            }
        }
    }
    Try-Operation 'Scan boot/logon scheduled tasks' {
        foreach ($task in Get-ScheduledTask -ErrorAction Stop) {
            if (-not @($task.Triggers | Where-Object { $_.CimClass.CimClassName -in @('MSFT_TaskLogonTrigger','MSFT_TaskBootTrigger') }).Count) { continue }
            $xml=Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
            $command=(@($task.Actions | ForEach-Object { '"'+$_.Execute+'" '+$_.Arguments }) -join ' ; ')
            $enabled=if ($task.Settings.Enabled) { 'Enabled' } else { 'Disabled' }
            # Do not offer Microsoft system tasks for automatic disabling.
            $supported=$task.TaskPath -notlike '\Microsoft\*'
            Add-StartupRow 'Task' $task.TaskName ($task.TaskPath+$task.TaskName) $command $enabled @{ Xml=$xml; TaskPath=$task.TaskPath; TaskName=$task.TaskName } $supported
        }
    }
    if ($script:target) {
        Try-Operation 'Scan packaged application startup tasks' {
            foreach ($app in Get-AppxPackage -User $script:target.Sid) {
                if (-not $app.InstallLocation) { continue }
                $manifest=Join-Path $app.InstallLocation 'AppxManifest.xml'
                if (-not (Test-Path -LiteralPath $manifest)) { continue }
                [xml]$xml=Get-Content -LiteralPath $manifest -Raw
                foreach ($node in $xml.SelectNodes("//*[local-name()='StartupTask']")) {
                    $taskId=$node.GetAttribute('TaskId')
                    $statePath="$($script:target.Hive)\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\$($app.PackageFamilyName)\$taskId"
                    $state=Get-RegOriginal $statePath 'State'
                    $enabled=if ($state.Exists -and $state.Value -in @(0,1,3)) { 'Disabled' } elseif ($state.Exists -and $state.Value -in @(2,4)) { 'Enabled' } else { 'Unknown' }
                    Add-StartupRow 'AppStartupTask' "$($app.Name):$taskId" $statePath $app.InstallLocation $enabled @{ State=$state; Package=$app.PackageFullName; Manifest=$manifest } $false
                }
            }
        }
    }
    return @($script:startup.ToArray())
}

function Disable-StartupRow($Row) {
    if (-not $Row.Supported -or $Row.Enabled -ne 'Enabled') { throw 'Unsupported or not known enabled; preserved.' }
    switch ($Row.Kind) {
        'Registry' {
            $old=$Row.Original.Value
            $current=Get-RegOriginal $old.Path $old.Name
            if (($current | ConvertTo-Json -Compress) -ne ($old | ConvertTo-Json -Compress)) { throw 'Startup value changed since scan; rescan first.' }
            $entry=[pscustomobject]@{ Type='StartupRegistry'; Group='Startup'; Original=$current; Pending=$true; Restored=$false }
            $script:journal.Changes += $entry; Save-Journal
            Remove-ItemProperty -LiteralPath $old.Path -Name $old.Name
            if ((Get-RegOriginal $old.Path $old.Name).Exists) { throw 'Startup removal readback failed.' }
        }
        'Folder' {
            if ((Get-FileHash -LiteralPath $Row.Location -Algorithm SHA256).Hash -ne $Row.Original.Hash) { throw 'Startup file changed; rescan first.' }
            $backup=Join-Path $RunDirectory ("startup-$($Row.Id)-"+[IO.Path]::GetFileName($Row.Location))
            Copy-Item -LiteralPath $Row.Location -Destination $backup -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $backup).Hash -ne $Row.Original.Hash) { throw 'Startup file backup verification failed.' }
            $entry=[pscustomobject]@{ Type='StartupFile'; Group='Startup'; Path=$Row.Location; Backup=$backup; Hash=$Row.Original.Hash; Pending=$true; Restored=$false }
            $script:journal.Changes += $entry; Save-Journal
            Remove-Item -LiteralPath $Row.Location -ErrorAction Stop
            if (Test-Path -LiteralPath $Row.Location) { throw 'Startup file remains.' }
        }
        'Task' {
            $old=$Row.Original
            if ((Export-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath) -ne $old.Xml) { throw 'Task changed; rescan first.' }
            $backup=Join-Path $RunDirectory "task-$($Row.Id).xml"
            $old.Xml | Set-Content -LiteralPath $backup -Encoding UTF8
            if (-not (Test-Path $backup)) { throw 'Task backup failed.' }
            $entry=[pscustomobject]@{ Type='StartupTask'; Group='Startup'; TaskName=$old.TaskName; TaskPath=$old.TaskPath; Xml=$old.Xml; Pending=$true; Restored=$false }
            $script:journal.Changes += $entry; Save-Journal
            Disable-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath | Out-Null
            if ((Get-ScheduledTask -TaskName $old.TaskName -TaskPath $old.TaskPath).Settings.Enabled) { throw 'Task still enabled.' }
        }
        default { throw 'Unsupported startup type.' }
    }
    $entry.Pending=$false; Save-Journal
    Log 'DISABLED' "Startup #$($Row.Id) $($Row.Name)" 'Entry disabled only; application/process retained.'
}

function Write-StartupReview($Rows) {
    Write-Json @($Rows) (Join-Path $RunDirectory 'startup-review.json')
    $text=New-Object 'System.Collections.Generic.List[string]'
    $text.Add('# Startup review: no extra entries disabled without explicit IDs')
    foreach ($row in $Rows) {
        $text.Add("`n## #$($row.Id) $($row.Name)`n- Publisher: $($row.Publisher)`n- Signature: $($row.Signature)`n- Type: $($row.Kind)`n- Location: $($row.Location)`n- Command: $($row.Command)`n- Enabled: $($row.Enabled)`n- Recommended optional: $($row.Recommend)`n- Purpose/reason: $($row.Purpose)`n- Impact: $($row.Impact)`n- Unknown: $($row.Uncertainty)`n- Method: $($row.Method)`n- Xbox handled: $($row.XboxHandled)")
    }
    $candidates=@($Rows | Where-Object { $_.Recommend -and -not $_.XboxHandled })
    if ($candidates.Count) {
        $text.Add("`nDisable these startup items? Explicitly select IDs, all recommended IDs, or keep all. No response means KEEP. Candidate IDs: $($candidates.Id -join ', ')")
        Log 'AWAITING_SELECTION' 'Extra startup entries' "Review startup-review.md; suggested IDs: $($candidates.Id -join ', '). Nothing selected automatically."
    } else { Log 'NOTE' 'Extra startup entries' 'No confidently optional enabled candidates; other entries preserved.' }
    $text | Set-Content (Join-Path $RunDirectory 'startup-review.md') -Encoding UTF8
}

function Restore-Journal {
    $changes=@($script:journal.Changes)
    [array]::Reverse($changes)
    foreach ($entry in $changes) {
        if ($entry.Restored -or ($Mode -eq 'RestoreDrivers' -and $entry.Group -ne 'Drivers')) { continue }
        Try-Operation "Restore $($entry.Type)" {
            switch ($entry.Type) {
                'Extended' { Restore-Extended $entry }
                { $_ -in @('Registry','StartupRegistry') } {
                    $old=$entry.Original
                    $current=Get-RegOriginal $old.Path $old.Name
                    # Avoid overwriting intervening user/organization changes.
                    if ($current.Exists -eq $old.Exists -and $current.Kind -eq $old.Kind -and ($current.Value | ConvertTo-Json -Compress) -eq ($old.Value | ConvertTo-Json -Compress)) { }
                    elseif ($entry.Type -eq 'StartupRegistry' -and $current.Exists) { throw 'Startup value recreated since disable; preserve it.' }
                    elseif ($entry.Type -eq 'Registry' -and (-not $current.Exists -or $current.Kind -ne $entry.AppliedKind -or "$($current.Value)" -ne "$($entry.Applied)")) { throw 'Setting changed since disable; preserved for manual review.' }
                    elseif ($old.Exists) { Write-RegValue $old.Path $old.Name $old.Value $old.Kind }
                    elseif (Test-Path $old.Path) { Remove-ItemProperty -LiteralPath $old.Path -Name $old.Name -ErrorAction Stop }
                }
                'Service' {
                    $startup=switch ([int]$entry.Start) { 2 { if ($entry.Delayed) { 'delayed-auto' } else { 'auto' } } 3 {'demand'} 4 {'disabled'} default {throw 'Unexpected startup type'} }
                    & "$env:SystemRoot\System32\sc.exe" config $entry.Name start= $startup | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw 'Service restore failed.' }
                    if ($entry.Running) { Start-Service $entry.Name } else { Stop-Service $entry.Name }
                    if ((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($entry.Name)").Start -ne $entry.Start) { throw 'Service restore readback failed.' }
                }
                'StartupFile' {
                    if (Test-Path -LiteralPath $entry.Path) { throw 'Startup file path occupied; no overwrite.' }
                    if ((Get-FileHash -LiteralPath $entry.Backup).Hash -ne $entry.Hash) { throw 'Backup hash mismatch.' }
                    Copy-Item -LiteralPath $entry.Backup -Destination $entry.Path
                    if ((Get-FileHash -LiteralPath $entry.Path).Hash -ne $entry.Hash) { throw 'Restored file hash mismatch.' }
                }
                'StartupTask' {
                    $task=Get-ScheduledTask -TaskName $entry.TaskName -TaskPath $entry.TaskPath
                    # Compare definition except the Enabled field; never re-register an absent task.
                    [xml]$current=Export-ScheduledTask -TaskName $entry.TaskName -TaskPath $entry.TaskPath
                    [xml]$old=$entry.Xml
                    $current.Task.Settings.Enabled='true'; $old.Task.Settings.Enabled='true'
                    if ($current.OuterXml -ne $old.OuterXml) { throw 'Task definition changed; preserve for manual review.' }
                    Enable-ScheduledTask -TaskName $entry.TaskName -TaskPath $entry.TaskPath | Out-Null
                    if (-not (Get-ScheduledTask -TaskName $entry.TaskName -TaskPath $entry.TaskPath).Settings.Enabled) { throw 'Task restore readback failed.' }
                }
                default { throw 'Unknown journal entry type.' }
            }
            $entry.Restored=$true; Save-Journal
            Log 'RESTORED' $entry.Type 'Original state restored from this run backup.'
        }
    }
    Log 'NOTE' 'Copilot app' 'If removed, reinstall Microsoft Copilot manually from Microsoft Store. Recall snapshots cannot be restored.'
}

# Main: fresh independent run directories; follow-up modes require the exact original directory.
$newRun=$Mode -in @('Disable','ScanStartup','Review')
if ($newRun) {
    if ($RunDirectory) { throw 'Disable/ScanStartup creates a new run. Do not supply RunDirectory.' }
    $RunDirectory=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ("WindowsCustomCleanup\"+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
    # Administrators/SYSTEM only: backups contain commands and executable restore code.
    & "$env:SystemRoot\System32\icacls.exe" $RunDirectory /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not secure backup directory; stopped before system changes.' }
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $RunDirectory 'Cleanup.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ExtendedReview.ps1') -Destination (Join-Path $RunDirectory 'ExtendedReview.ps1')
    $script:journal=[pscustomobject]@{ Version=2; Computer=$env:COMPUTERNAME; Executor=$identity.User.Value; Target=$null; Created=(Get-Date).ToString('o'); Changes=@(); Drivers=@(); CopilotPackages=@() }
    foreach ($restore in @(@('Restore-CustomChanges.ps1','Restore'),@('Restore-SelectedDrivers.ps1','RestoreDrivers'))) {
        @"
#Requires -Version 5.1
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path `$PSScriptRoot 'Cleanup.ps1') -Mode $($restore[1]) -RunDirectory `$PSScriptRoot
exit `$LASTEXITCODE
"@ | Set-Content (Join-Path $RunDirectory $restore[0]) -Encoding UTF8
    }
} else {
    if (-not $RunDirectory) { throw 'Specify the absolute -RunDirectory from the original run.' }
    $RunDirectory=(Resolve-Path -LiteralPath $RunDirectory).Path
    $script:journal=Get-Content (Join-Path $RunDirectory 'original-values.json') -Raw | ConvertFrom-Json
    if ($script:journal.Computer -ne $env:COMPUTERNAME -or $script:journal.Executor -ne $identity.User.Value) { throw 'Wrong computer or executing account for this backup.' }
}
$script:report=New-Object 'System.Collections.Generic.List[object]'
if (Test-Path (Join-Path $RunDirectory 'report.json')) {
    foreach ($line in @(Get-Content (Join-Path $RunDirectory 'report.json') -Raw | ConvertFrom-Json)) { $script:report.Add($line) }
}
Start-Transcript -Path (Join-Path $RunDirectory ("$Mode-"+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')) -ErrorAction Stop | Out-Null
. (Join-Path $PSScriptRoot 'ExtendedReview.ps1')
try {
    $protectedBefore=Get-ProtectedServices
    Write-Json $protectedBefore (Join-Path $RunDirectory "$Mode-protected-before.json")
    $script:target=$null
    try { $script:target=Get-TargetUser } catch { Log 'SKIP' 'User settings' $_.Exception.Message }
    $management=Get-ManagementState
    Write-HealthSnapshot 'before'
    Log 'NOTE' 'Environment' "Build=$($os.CurrentBuildNumber); Edition=$($os.EditionID); Management=$management; Directory=$RunDirectory"
    if ($newRun) { $script:journal.Target=$script:target; Save-Journal }
    elseif ($script:journal.Target -and (-not $script:target -or $script:target.Sid -ne $script:journal.Target.Sid)) { throw 'Original target user is no longer uniquely active in this session; stopped.' }

    if ($Mode -in @('Restore','RestoreDrivers','DisableStartup','ApplyReview') -and $management -ne 'Personal') {
        throw 'Managed/enrolled or unknown management state: no writes permitted.'
    }
    switch ($Mode) {
        'Disable' {
            if ($management -eq 'Personal') {
                Invoke-BaseSettings
                Try-Operation 'Game settings' { Invoke-GameSettings }
                Invoke-SelectedDrivers
            } else { Log 'SKIP' 'System changes' 'Organization management detected or uncertain; no policy/service/driver changes.' }
            $rows=Get-StartupInventory
            if ($management -eq 'Personal') {
                foreach ($row in $rows) {
                    # Xbox name alone is insufficient. Only exact Xbox package launch identity.
                    if ($row.Enabled -eq 'Enabled' -and $row.Supported -and $row.Command -match '(?i)Microsoft\.GamingApp_8wekyb3d8bbwe!Microsoft\.Xbox\.App(?:\s|"|$)') {
                        Try-Operation 'Xbox startup' { Disable-StartupRow $row; $row.XboxHandled=$true; $row.Enabled='Disabled' }
                    }
                }
            }
            Write-StartupReview $rows
            Write-ExtendedReview
            Log 'NOTE' 'Xbox packaged StartupTask' 'Manifest/state inventoried. Direct registry State editing is not a supported external API; uncertain Xbox startup mechanisms are preserved and reported.'
        }
        'ScanStartup' { Write-StartupReview (Get-StartupInventory) }
        'Review' { Write-StartupReview (Get-StartupInventory); Write-ExtendedReview }
        'ApplyReview' {
            if (-not $ReviewIds.Count) { throw 'Explicit ReviewIds required.' }
            $items=@(Get-Content (Join-Path $RunDirectory 'extended-review.json') -Raw | ConvertFrom-Json)
            foreach ($id in ($ReviewIds | Sort-Object -Unique)) {
                $found=@($items | Where-Object Id -eq $id)
                if ($found.Count -ne 1 -or -not $found[0].Supported) { throw "Invalid or read-only review ID: $id" }
            }
            $selected=@($items | Where-Object { $_.Id -in $ReviewIds })
            if (@($selected | Group-Object Name | Where-Object Count -gt 1).Count) { throw 'Choose only one action per item: disable OR delay.' }
            foreach ($id in ($ReviewIds | Sort-Object -Unique)) {
                Try-Operation "Review #$id" { Apply-ExtendedItem ($items | Where-Object Id -eq $id) }
            }
        }
        'DisableStartup' {
            if (-not $StartupIds.Count) { throw 'Explicit -StartupIds required. Silence is not consent.' }
            $rows=@(Get-Content (Join-Path $RunDirectory 'startup-review.json') -Raw | ConvertFrom-Json)
            foreach ($id in ($StartupIds | Sort-Object -Unique)) {
                $match=@($rows | Where-Object Id -eq $id)
                if ($match.Count -ne 1 -or $match[0].XboxHandled) { throw "Invalid/already handled ID: $id" }
            }
            foreach ($id in ($StartupIds | Sort-Object -Unique)) {
                $row=$rows | Where-Object Id -eq $id
                Try-Operation "Startup #$id" { Disable-StartupRow $row; $row.Enabled='Disabled'; $row.Recommend=$false }
            }
            Write-StartupReview $rows
        }
        default { Restore-Journal }
    }
} catch { Log 'FAILED' $Mode $_.Exception.Message }
finally {
    Write-HealthSnapshot 'after'
    Try-Operation 'Protected services check' {
        $after=Get-ProtectedServices
        Write-Json $after (Join-Path $RunDirectory "$Mode-protected-after.json")
        if (($protectedBefore | ConvertTo-Json -Compress) -ne ($after | ConvertTo-Json -Compress)) {
            Log 'WARNING' 'WSearch/Gaming Services' 'Observed configuration/status difference. Script does not write these services; review before/after files. No attempt to overwrite natural/external changes.'
        } else { Log 'VERIFIED' 'WSearch/Gaming Services' 'Configuration and observed running state unchanged.' }
    }
    Log 'NOTE' 'Finish' "No restart/logoff. Settings readback is not runtime validation. Reboot manually to validate driver startup. Backups/logs/restore scripts: $RunDirectory"
    Stop-Transcript | Out-Null
}
if (@($script:report | Where-Object Status -eq 'FAILED').Count) { exit 1 }
