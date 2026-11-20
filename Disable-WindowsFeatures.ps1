#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Unified','Disable','ScanStartup','DisableStartup','Review','ApplyReview','Restore','RestoreDrivers')]
    [string]$Mode = 'Unified',
    [string]$RunDirectory,
    [int[]]$StartupIds = @(),
    [int[]]$ReviewIds = @(),
    [ValidateSet('Console','Options','Scan','Apply')]
    [string]$AgentStage = 'Console',
    [string]$Selection = 'NONE'
)

# Windows PowerShell 5.1 only. Unified mode selects everything before applying changes.
$ErrorActionPreference = 'Stop'
$script:runClock=[Diagnostics.Stopwatch]::StartNew()
$script:commandEvidenceCache=@{}
$script:taskXmlCache=@{}
Write-Host '[START] Windows cleanup: checking execution environment...' -ForegroundColor Cyan
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess) {
    throw 'Run in 64-bit Windows PowerShell 5.1 (powershell.exe), not pwsh.exe.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($Mode -eq 'Unified') {
        if ($Selection -notmatch '^(?i)[A-Z0-9,;\s]*$' -or $RunDirectory -match '"') { throw 'Invalid elevation arguments.' }
        $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode Unified -AgentStage '+$AgentStage+' -Selection "'+$Selection+'"'
        if ($RunDirectory) { $arguments+=' -RunDirectory "'+$RunDirectory+'"' }
        $process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    }
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
    ConvertTo-Json -InputObject $Object -Depth 30 | Set-Content -LiteralPath $temporary -Encoding UTF8
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
    $clock=[Diagnostics.Stopwatch]::StartNew()
    Write-Host ("[{0:N1}s] START {1}" -f $script:runClock.Elapsed.TotalSeconds,$Name) -ForegroundColor Cyan
    try { & $Action } catch { Log 'FAILED' $Name $_.Exception.Message }
    finally { Write-Host ("[{0:N1}s] END {1} ({2:N1}s)" -f $script:runClock.Elapsed.TotalSeconds,$Name,$clock.Elapsed.TotalSeconds) }
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
    $complete=$true; $devices=@(); $filters=New-Object 'System.Collections.Generic.List[object]'; $systemDrivers=@()
    try {
        Write-Host '[DRIVERS] Reading installed devices and running drivers...'
        # Win32_PnPEntity alone can miss phantom devices. Read all installed PnP devices too.
        $devices = @(Get-PnpDevice -ErrorAction Stop)
        $systemDrivers = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop)
        foreach ($root in @('HKLM:\SYSTEM\CurrentControlSet\Enum','HKLM:\SYSTEM\CurrentControlSet\Control\Class')) {
            # Stream keys and read only dependency values; do not materialize every registry property.
            $count=0
            Get-Item $root -ErrorAction Stop | ForEach-Object { Read-DriverReferences $_ $filters }
            Get-ChildItem $root -Recurse -ErrorAction Stop | ForEach-Object {
                Read-DriverReferences $_ $filters
                $count++
                if ($count % 250 -eq 0) { Write-Host "[DRIVERS] $root : $count keys checked..." }
            }
        }
        Write-Host '[DRIVERS] Reading service dependencies...'
        # Driver service dependencies may require another driver without a direct PnP reference.
        foreach ($key in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction Stop) {
            foreach ($dependency in @($key.GetValue('DependOnService'))) {
                if ($dependency) { $filters.Add([pscustomobject]@{ Source=$key.Name; Reference="$dependency" }) }
            }
        }
    } catch { $complete=$false; Log 'NOTE' 'Driver inventory' "Incomplete: $($_.Exception.Message). Non-beep targets will be preserved." }
    Write-Json @{ Complete=$complete; Devices=@($devices | Select-Object InstanceId,Class,FriendlyName,Status); References=@($filters.ToArray()) } (Join-Path $RunDirectory 'device-inventory.json')
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
    if ($script:commandEvidenceCache.ContainsKey($Command)) { return $script:commandEvidenceCache[$Command] }
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
    $result=[pscustomobject]@{ File=$file; Publisher=$publisher; Signature=$signature }
    $script:commandEvidenceCache[$Command]=$result
    return $result
}

function Read-DriverReferences($Key,$References) {
    foreach ($field in @('Service','UpperFilters','LowerFilters')) {
        foreach ($value in @($Key.GetValue($field))) {
            if ($value) { $References.Add([pscustomobject]@{ Source=$Key.Name; Reference="$value" }) }
        }
    }
}
function Get-InventoryTasks {
    if ($null -eq $script:inventoryTasks) {
        Write-Host '[SCAN] Loading scheduled tasks once for both review reports...'
        $script:inventoryTasks=@(Get-ScheduledTask -ErrorAction Stop)
    }
    return $script:inventoryTasks
}
function Get-InventoryTaskXml($Task) {
    $key=$Task.TaskPath+$Task.TaskName
    if (-not $script:taskXmlCache.ContainsKey($key)) {
        $script:taskXmlCache[$key]=Export-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath
    }
    return $script:taskXmlCache[$key]
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
        foreach ($task in Get-InventoryTasks) {
            if (-not @($task.Triggers | Where-Object { $_.CimClass.CimClassName -in @('MSFT_TaskLogonTrigger','MSFT_TaskBootTrigger') }).Count) { continue }
            Write-Host "[SCAN] Startup task: $($task.TaskPath)$($task.TaskName)"
            $xml=Get-InventoryTaskXml $task
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
                Write-Host "[SCAN] App startup manifest: $($app.Name)"
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

function Get-HealthComparison($Before,$After) {
    $beforeMB=([double]$Before.TotalMemoryKB-[double]$Before.FreeMemoryKB)/1024
    $afterMB=([double]$After.TotalMemoryKB-[double]$After.FreeMemoryKB)/1024
    [pscustomobject]@{
        BeforeTime=$Before.Time; AfterTime=$After.Time
        BeforeProcessCount=$Before.ProcessCount; AfterProcessCount=$After.ProcessCount
        ProcessCountChange=([int]$After.ProcessCount-[int]$Before.ProcessCount)
        BeforeUsedMemoryMB=[math]::Round($beforeMB,2); AfterUsedMemoryMB=[math]::Round($afterMB,2)
        UsedMemoryChangeMB=[math]::Round(($afterMB-$beforeMB),2)
        Note='Change = after minus before; negative means reduced. System-wide used physical memory = visible total minus free. Immediate observations are not proof of performance improvement.'
    }
}
function Write-HealthSnapshot($Label) {
    Try-Operation "Health $Label" {
        $osInfo=Get-CimInstance Win32_OperatingSystem
        $processes=@(Get-Process)
        $snapshot=[pscustomobject]@{
            Time=(Get-Date).ToString('o'); LastBoot=$osInfo.LastBootUpTime
            ProcessCount=$processes.Count; FreeMemoryKB=$osInfo.FreePhysicalMemory; TotalMemoryKB=$osInfo.TotalVisibleMemorySize
            CpuLoadPercent=(Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
            Processes=@($processes | Select-Object Id,ProcessName,SessionId,CPU,WorkingSet64)
            Sessions=(& "$env:SystemRoot\System32\quser.exe" 2>&1 | Out-String)
            Note='Process CPU is cumulative time. No sessions terminated. Compare equivalent workloads after manual reboot.'
        }
        Write-Json $snapshot (Join-Path $RunDirectory "health-$Label-$(Get-Date -Format yyyyMMdd-HHmmss).json")
        if ($Label -eq 'before') { $script:healthBefore=$snapshot }
        elseif ($Label -eq 'after' -and $script:healthBefore) {
            $comparison=Get-HealthComparison $script:healthBefore $snapshot
            $script:healthComparison=$comparison
            Write-Json $comparison (Join-Path $RunDirectory ("health-comparison-"+$Mode+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.json'))
            Write-Host 'Resource comparison (before -> after; change = after - before)'
            Write-Host ("Processes: {0} -> {1}; change {2:+0;-0;0}" -f $comparison.BeforeProcessCount,$comparison.AfterProcessCount,$comparison.ProcessCountChange)
            Write-Host ("Used physical memory: {0:N2} MB -> {1:N2} MB; change {2:+0.00;-0.00;0.00} MB" -f $comparison.BeforeUsedMemoryMB,$comparison.AfterUsedMemoryMB,$comparison.UsedMemoryChangeMB)
            Write-Host 'Immediate observations only; background activity and pending restart affect results.'
        } elseif ($Label -eq 'after') { Log 'SKIP' 'Resource comparison' 'Before snapshot unavailable.' }
    }
}
function Add-Review($Kind,$Name,$Original,$Action,$Impact,$Supported=$true) {
    $script:review.Add([pscustomobject]@{ Id=$script:review.Count+1; Kind=$Kind; Name=$Name; Original=$Original; Action=$Action; Impact=$Impact; Supported=$Supported })
}
function Write-ExtendedReview {
    $script:review=New-Object 'System.Collections.Generic.List[object]'
    Try-Operation 'Review services' {
        foreach ($service in Get-CimInstance Win32_Service) {
            if ($service.Name -in @('Fax','XboxGipSvc','XboxNetApiSvc','XblAuthManager','XblGameSave','Spooler','bthserv')) {
                $key=Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$($service.Name)"
                $wanted=if ($service.Name -eq 'Fax') {4} else {3}
                if ($key.Start -ne $wanted) {
                    Add-Review 'Service' $service.Name @{ Start=$key.Start; Wanted=$wanted; Path=$service.PathName } 'Change startup only' 'Confirm no need for automatic fax/Xbox/printing (including PDF)/Bluetooth. No running service stopped.'
                }
            } elseif ($service.StartMode -eq 'Auto') {
                Write-Host "[SCAN] Automatic service: $($service.Name)"
                $e=Get-CommandEvidence $service.PathName
                if ($e.File -and $e.File -notlike "$env:SystemRoot\*" -and $e.Publisher -notmatch 'Microsoft') {
                    Add-Review 'ThirdPartyService' $service.Name @{ Path=$service.PathName; Publisher=$e.Publisher; Signature=$e.Signature } 'ReadOnly' 'Dependencies/security/hardware needs not established; no automatic disable.' $false
                }
            }
        }
    }
    Try-Operation 'Review optional Windows features (DISM may take time)' {
        foreach ($feature in Get-WindowsOptionalFeature -Online | Where-Object { $_.State -eq 'Enabled' -and $_.FeatureName -in @('WindowsMediaPlayer','Printing-XPSServices-Features','FaxServicesClientPackage') }) {
            Add-Review 'Feature' $feature.FeatureName @{ State='Enabled' } 'Disable, keep payload' 'Legacy player, XPS printing or fax may be needed. Manual restart may be needed.'
        }
    }
    Try-Operation 'Review media capability (DISM may take time)' {
        foreach ($cap in Get-WindowsCapability -Online -Name 'Media.WindowsMediaPlayer*' | Where-Object State -eq 'Installed') {
            Add-Review 'Capability' $cap.Name @{ State='Installed' } 'Remove capability' 'Legacy media. Restore may require network/installation media and a restart.'
        }
    }
    Try-Operation 'Review all third-party task triggers' {
        foreach ($task in Get-InventoryTasks | Where-Object TaskPath -NotLike '\Microsoft\*') {
            Write-Host "[SCAN] Review task: $($task.TaskPath)$($task.TaskName)"
            $xml=Get-InventoryTaskXml $task
            $command=(@($task.Actions | ForEach-Object { '"'+$_.Execute+'" '+$_.Arguments }) -join ' ; ')
            $advice=Get-StartupAdvice $task.TaskName $command
            $original=@{ Xml=$xml; TaskPath=$task.TaskPath; TaskName=$task.TaskName; Command=$command; Triggers=@($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }); Enabled=$task.Settings.Enabled }
            if ($task.Settings.Enabled -and $advice.Recommend) {
                Add-Review 'Task' ($task.TaskPath+$task.TaskName) $original 'Disable' 'Optional launcher task. Read actions/triggers; updates/background actions stop.'
            } else { Add-Review 'TaskInventory' ($task.TaskPath+$task.TaskName) $original 'ReadOnly' 'Unknown purpose/dependencies or already disabled; retained.' $false }
            if ($task.Settings.Enabled -and $advice.Recommend -and @($task.Actions).Count -eq 1 -and @($task.Triggers).Count -eq 1 -and $original.Triggers[0] -eq 'MSFT_TaskLogonTrigger' -and $task.Principal.LogonType -eq 'Interactive') {
                Add-Review 'Delay' ($task.TaskPath+$task.TaskName) $original 'Delay login by 60 seconds' 'Keeps auto-launch; do not select both disable and delay.'
            }
        }
    }
    Write-Json @($script:review.ToArray()) (Join-Path $RunDirectory 'extended-review.json')
    $lines=@('# Extended review: explicit ReviewIds required; no selection means keep.','Excluded: SysMain, WSearch, wireless display, third-party app background permissions. System maintenance retained.')
    foreach ($item in $script:review) {
        $lines += "`n## #$($item.Id) $($item.Name)`nType: $($item.Kind); action: $($item.Action); selectable: $($item.Supported)`nImpact: $($item.Impact)`nEvidence/original:`n$($item.Original | ConvertTo-Json -Depth 15)"
    }
    $lines | Set-Content (Join-Path $RunDirectory 'extended-review.md') -Encoding UTF8
    Log 'AWAITING_SELECTION' 'Extended review' 'Read extended-review.md; ApplyReview/ReviewIds required. Unknown services/tasks read-only.'
}
function Apply-ExtendedItem($Item) {
    if (-not $Item.Supported) { throw 'Read-only item.' }
    switch ($Item.Kind) {
        'Service' {
            if ($Item.Name -notin @('Fax','XboxGipSvc','XboxNetApiSvc','XblAuthManager','XblGameSave','Spooler','bthserv')) { throw 'Not allowlisted.' }
            $path="HKLM:\SYSTEM\CurrentControlSet\Services\$($Item.Name)"
            if ((Get-ItemProperty $path).Start -ne $Item.Original.Start) { throw 'State changed since review.' }
            Change-Reg $path 'Start' $Item.Original.Wanted 'DWord' 'Review'
            Log 'NOTE' $Item.Name 'Startup read back; takes effect after manual restart, current service untouched.'
            return
        }
        { $_ -in @('Feature','Capability','Delay') } {
            if ($Item.Kind -eq 'Feature' -and ($Item.Name -notin @('WindowsMediaPlayer','Printing-XPSServices-Features','FaxServicesClientPackage') -or (Get-WindowsOptionalFeature -Online -FeatureName $Item.Name).State -ne 'Enabled')) { throw 'Ineligible feature.' }
            if ($Item.Kind -eq 'Capability' -and ($Item.Name -notmatch '^Media\.WindowsMediaPlayer\.' -or (Get-WindowsCapability -Online -Name $Item.Name).State -ne 'Installed')) { throw 'Ineligible capability.' }
            if ($Item.Kind -eq 'Delay' -and (Export-ScheduledTask -TaskName $Item.Original.TaskName -TaskPath $Item.Original.TaskPath) -ne $Item.Original.Xml) { throw 'Task changed since review.' }
            $entry=[pscustomobject]@{ Type='Extended'; Group='Review'; Item=$Item; Pending=$true; Restored=$false; AppliedXml=$null }
            $script:journal.Changes += $entry; Save-Journal
            if ($Item.Kind -eq 'Feature') {
                $result=Disable-WindowsOptionalFeature -Online -FeatureName $Item.Name -NoRestart
                if ((Get-WindowsOptionalFeature -Online -FeatureName $Item.Name).State -notin @('Disabled','DisablePending')) { throw 'Feature readback failed.' }
            } elseif ($Item.Kind -eq 'Capability') {
                $result=Remove-WindowsCapability -Online -Name $Item.Name
                if ((Get-WindowsCapability -Online -Name $Item.Name).State -notin @('NotPresent','UninstallPending')) { throw 'Capability readback failed.' }
            } else {
                $old=$Item.Original
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
            Log 'NOTE' $Item.Name 'Configuration verified; manual restart may be needed.'
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

function Resolve-CleanupSelection($Text, $Options) {
    $ids=if ([string]::IsNullOrWhiteSpace($Text)) { @($Options | Where-Object Default | ForEach-Object Id) } else { @($Text.ToUpperInvariant() -split '[,;\s]+' | Where-Object { $_ }) }
    if ($ids -contains 'NONE') {
        if ($ids.Count -ne 1) { throw 'NONE cannot be combined with other choices.' }
        return
    }
    foreach ($id in ($ids | Select-Object -Unique)) {
        if (@($Options | Where-Object Id -eq $id).Count -ne 1) { throw "Unknown selection: $id" }
        $id
    }
}
function Invoke-TempCleanup {
    $result=[pscustomobject]@{ DeletedFiles=0; DeletedBytes=[long]0; Skipped=0; Cutoff=(Get-Date).AddDays(-7); Irreversible=$true }
    $roots=@((Join-Path $env:SystemRoot 'Temp'))
    if ($script:target) { $roots+=Join-Path $script:target.Profile 'AppData\Local\Temp' }
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $pending=New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($root)
        while ($pending.Count) {
            $directory=$pending.Pop()
            try {
                $info=Get-Item -LiteralPath $directory -Force
                if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                foreach ($entry in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
                    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    # Preserve the running source, downloads, logs and run backups even under Temp.
                    if ($entry.FullName -eq $RunDirectory -or $entry.FullName -eq $PSScriptRoot -or $PSScriptRoot.StartsWith($entry.FullName+'\',[StringComparison]::OrdinalIgnoreCase) -or $RunDirectory.StartsWith($entry.FullName+'\',[StringComparison]::OrdinalIgnoreCase)) { continue }
                    if ($entry.PSIsContainer) { $pending.Push($entry.FullName); continue }
                    if ($entry.LastWriteTime -ge $result.Cutoff) { continue }
                    try {
                        $size=$entry.Length
                        Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction Stop
                        $result.DeletedFiles++; $result.DeletedBytes+=$size
                    } catch { $result.Skipped++ }
                }
            } catch { $result.Skipped++ }
        }
    }
    Write-Json $result (Join-Path $RunDirectory 'temp-cleanup.json')
    Log 'VERIFIED' 'Temporary files' "Deleted=$($result.DeletedFiles); bytes=$($result.DeletedBytes); skipped=$($result.Skipped)"
    $script:tempCleanupResult=$result
}
function Invoke-ComponentCleanup {
    $logPath=Join-Path $RunDirectory 'component-cleanup-dism.log'
    & "$env:SystemRoot\System32\dism.exe" /Online /Cleanup-Image /StartComponentCleanup /NoRestart "/LogPath:$logPath"
    $code=$LASTEXITCODE
    $script:componentCleanupResult=[pscustomobject]@{ ExitCode=$code; RestartRequired=($code -eq 3010); ResetBase=$false; Log=$logPath }
    Write-Json $script:componentCleanupResult (Join-Path $RunDirectory 'component-cleanup.json')
    if ($code -notin @(0,3010)) { throw "DISM component cleanup failed: $code. See $logPath" }
    Log 'VERIFIED' 'WinSxS' "DISM exit=$code; restart required=$($code -eq 3010). Component cleanup has no custom undo."
}
function Invoke-UnifiedCleanup {
    if ($AgentStage -in @('Scan','Apply') -and (Test-Path (Join-Path $RunDirectory 'selection.json'))) { throw 'This run has already started applying. Inspect its logs; do not apply it twice.' }
    if ($management -ne 'Personal') { throw 'Managed/enrolled or unknown management state: no unified changes permitted.' }
    $vendor=Join-Path $PSScriptRoot 'vendor\Win11Debloat'
    if (-not (Test-Path (Join-Path $vendor 'Win11Debloat.ps1'))) { throw 'Download/extract the complete windows-clean repository, including vendor.' }
    $rows=@()
    $script:review=@()
    $options=@(
        [pscustomobject]@{Id='G1';Default=$true;Label='Custom privacy/Copilot/Recall/widgets and RmSvc/diagnostic services; removal of Recall snapshots cannot be undone'},
        [pscustomobject]@{Id='G2';Default=$true;Label='Disable game capture and Game Bar controller launch; keep gaming services'},
        [pscustomobject]@{Id='G3';Default=$true;Label='Check five allowlisted drivers; disable only eligible drivers'},
        [pscustomobject]@{Id='G4';Default=$true;Label='Delete ordinary temporary files older than 7 days (irreversible)'},
        [pscustomobject]@{Id='G5';Default=$true;Label='WinSxS: DISM StartComponentCleanup, no ResetBase (no custom undo)'},
        [pscustomobject]@{Id='X1';Default=$false;Label='Scan startup candidates (including Xbox); choose individual items after scanning'},
        [pscustomobject]@{Id='X2';Default=$false;Label='Scan service/task/optional-component candidates (DISM may take time); choose items after scanning'}
    )
    $defaults=Get-Content (Join-Path $vendor 'Config\DefaultSettings.json') -Raw | ConvertFrom-Json
    $labels=(Get-Content (Join-Path $vendor 'Config\Languages\zh-CN\Features.json') -Raw -Encoding UTF8 | ConvertFrom-Json).Features
    # Upstream telemetry edits Defender; widgets force-kills processes. Use custom settings instead.
    $upstream=@($defaults.Settings | Where-Object { $_.Name -notin @('CreateRestorePoint','DisableTelemetry','DisableWidgets') })
    $n=0
    foreach ($setting in $upstream) {
        $n++
        $options+=[pscustomobject]@{Id="U$n";Default=$true;Label="Win11Debloat: $($setting.Name) - $($labels.($setting.Name).Label)"}
    }
    Write-Host "`nSelect BEFORE scanning/applying. Enter comma-separated IDs; Enter=G/U defaults; NONE=cancel. X1/X2 scans are opt-in." -ForegroundColor Yellow
    Write-Host 'Upstream restore point follows its own behavior; not guaranteed. Upstream backups and custom restore are separate.'
    Write-Host 'Upstream telemetry/widgets excluded to preserve Defender and avoid forced process termination; G1 covers custom settings.'
    foreach ($option in $options) { Write-Host ("{0} {1}: {2}" -f $(if ($option.Default) {'[*]'} else {'[ ]'}),$option.Id,$option.Label) }
    Write-Json $options (Join-Path $RunDirectory 'available-options.json')
    if ($AgentStage -eq 'Options') {
        Log 'AWAITING_SELECTION' 'Agent window' "Options exported: $RunDirectory\available-options.json. Show a multi-select window; Scan/Apply require this RunDirectory."
        return
    }
    if ($AgentStage -eq 'Console') { $selected=@(Resolve-CleanupSelection (Read-Host 'IDs') $options) }
    elseif ($AgentStage -eq 'Scan') {
        if ([string]::IsNullOrWhiteSpace($Selection)) { throw 'Explicit agent selection required; use NONE to cancel.' }
        $selected=@(Resolve-CleanupSelection $Selection $options)
        Write-Json ([pscustomobject]@{Selected=$selected}) (Join-Path $RunDirectory 'agent-base-selection.json')
    } else {
        $selected=@((Get-Content (Join-Path $RunDirectory 'agent-base-selection.json') -Raw | ConvertFrom-Json).Selected)
        $selected=@(Resolve-CleanupSelection $(if ($selected.Count) {$selected -join ','} else {'NONE'}) $options)
    }
    if ('X1' -in $selected) {
        if ($AgentStage -eq 'Apply') { $rows=@(Get-Content (Join-Path $RunDirectory 'startup-review.json') -Raw | ConvertFrom-Json) }
        else { $rows=@(Get-StartupInventory); Write-StartupReview $rows }
    }
    if ('X2' -in $selected) {
        if ($AgentStage -eq 'Apply') { $script:review=@(Get-Content (Join-Path $RunDirectory 'extended-review.json') -Raw | ConvertFrom-Json) }
        else { Write-ExtendedReview }
    }
    if (@($script:report | Where-Object Status -eq 'FAILED').Count) { throw 'Inventory failed; no changes applied.' }
    $candidates=@()
    foreach ($row in $rows | Where-Object { $_.Supported -and $_.Enabled -eq 'Enabled' -and ($_.Recommend -or $_.Command -match '(?i)Microsoft\.GamingApp_8wekyb3d8bbwe!Microsoft\.Xbox\.App(?:\s|"|$)') }) {
        $candidates+=[pscustomobject]@{Id="S$($row.Id)";Default=$false;Label="Startup: $($row.Name); $($row.Impact)"}
    }
    foreach ($item in $script:review | Where-Object Supported) {
        $candidates+=[pscustomobject]@{Id="R$($item.Id)";Default=$false;Label="$($item.Kind): $($item.Name); $($item.Action); $($item.Impact)"}
    }
    Write-Json @($candidates) (Join-Path $RunDirectory 'agent-candidates.json')
    if ($AgentStage -eq 'Scan') {
        Log 'AWAITING_SELECTION' 'Agent candidate window' "Candidates exported: $RunDirectory\agent-candidates.json. Apply reuses saved inventories; no cleanup performed."
        return
    }
    if ($AgentStage -eq 'Apply') {
        if ([string]::IsNullOrWhiteSpace($Selection)) { throw 'Explicit candidate selection required; use NONE to keep all.' }
        $selected+=@(Resolve-CleanupSelection $Selection $candidates)
    } elseif ($candidates.Count) {
        Write-Host 'Optional candidates: enter IDs; Enter or NONE keeps all. No changes applied yet.'
        foreach ($candidate in $candidates) { Write-Host "$($candidate.Id): $($candidate.Label)" }
        Write-Json @($options+$candidates) (Join-Path $RunDirectory 'available-options.json')
        $selected+=@(Resolve-CleanupSelection (Read-Host 'Candidate IDs') $candidates)
    }
    $selected=@($selected | Where-Object { $_ -notin @('X1','X2') })
    $selectedReview=@($script:review | Where-Object { "R$($_.Id)" -in $selected })
    if (@($selectedReview | Group-Object Name | Where-Object Count -gt 1).Count) { throw 'Choose disable OR delay for each task, not both.' }
    $taskNames=@($selectedReview | Where-Object { $_.Kind -in @('Task','Delay') } | ForEach-Object Name)
    foreach ($row in $rows | Where-Object { "S$($_.Id)" -in $selected }) {
        if ($row.Kind -eq 'Task' -and ($row.Original.TaskPath+$row.Original.TaskName) -in $taskNames) { throw 'Same task selected in startup and extended review; select it once.' }
    }
    Write-Json ([pscustomobject]@{Selected=$selected;Time=(Get-Date).ToString('o')}) (Join-Path $RunDirectory 'selection.json')
    $script:selectedCleanupIds=$selected
    if (-not $selected.Count) { Log 'NOTE' 'Selection' 'Cancelled; no cleanup performed.'; return }
    # Isolate upstream script scope and retain the exact source used for this run.
    if (-not $script:target -or $identity.User.Value -ne $script:target.Sid) { throw 'Unified upstream execution requires the active user and administrator to be the same account.' }
    Copy-Item -LiteralPath $vendor -Destination (Join-Path $RunDirectory 'Win11Debloat') -Recurse
    $tweaks=@(); $n=0
    foreach ($setting in $upstream) { $n++; if ("U$n" -in $selected) { $tweaks+=@{Name=$setting.Name;Value=$true} } }
    $configPath=Join-Path $RunDirectory 'upstream-config.json'
    Write-Json @{Version='1.0';Tweaks=$tweaks;Deployment=@(@{Name='CreateRestorePoint';Value=$true},@{Name='RestartExplorer';Value=$false})} $configPath
    $upstreamLogs=Join-Path $RunDirectory 'upstream-logs'
    Try-Operation 'Win11Debloat selected settings and restore point' {
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RunDirectory 'Win11Debloat\Win11Debloat.ps1') -Config $configPath -Silent -SkipExplorerRestart -LogPath $upstreamLogs
        if ($LASTEXITCODE -ne 0) { throw "Win11Debloat exit=$LASTEXITCODE; inspect upstream logs." }
        Log 'NOTE' 'Win11Debloat' 'Process completed; consult upstream logs for individual failures and actual restore point status.'
    }
    if ('G1' -in $selected) { Try-Operation 'Custom privacy settings' { Invoke-BaseSettings } }
    if ('G2' -in $selected) { Try-Operation 'Game settings' { Invoke-GameSettings } }
    if ('G3' -in $selected) { Try-Operation 'Selected drivers' { Invoke-SelectedDrivers } }
    foreach ($row in $rows | Where-Object { "S$($_.Id)" -in $selected }) { Try-Operation "Startup #$($row.Id)" { Disable-StartupRow $row } }
    foreach ($item in $selectedReview) { Try-Operation "Review #$($item.Id)" { Apply-ExtendedItem $item } }
    if ('G4' -in $selected) { Try-Operation 'Temporary file cleanup' { Invoke-TempCleanup } }
    if ('G5' -in $selected) { Try-Operation 'WinSxS component cleanup (may take time)' { Invoke-ComponentCleanup } }
}
# Main: fresh independent run directories; follow-up modes require the exact original directory.
$newRun=($Mode -in @('Unified','Disable','ScanStartup','Review')) -and $AgentStage -notin @('Scan','Apply')
if ($Mode -ne 'Unified' -and $AgentStage -ne 'Console') { throw 'AgentStage is supported only with Unified mode.' }
if ($newRun) {
    if ($RunDirectory) { throw 'Disable/ScanStartup creates a new run. Do not supply RunDirectory.' }
    $RunDirectory=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ("WindowsCustomCleanup\"+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
    # Administrators/SYSTEM only: backups contain commands and executable restore code.
    & "$env:SystemRoot\System32\icacls.exe" $RunDirectory /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not secure backup directory; stopped before system changes.' }
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $RunDirectory 'Cleanup.ps1')
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
        'Unified' { Invoke-UnifiedCleanup }
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
    if ($Mode -eq 'Unified') {
        Write-Json ([pscustomobject]@{ Directory=$RunDirectory; Selected=$script:selectedCleanupIds; Completed=@($script:report | Where-Object Status -eq 'VERIFIED').Count; Failed=@($script:report | Where-Object Status -eq 'FAILED').Count; Skipped=@($script:report | Where-Object Status -eq 'SKIP').Count; Resources=$script:healthComparison; TemporaryFiles=$script:tempCleanupResult; ComponentCleanup=$script:componentCleanupResult; Note='Counts are custom report events; upstream outcomes and restore point status are in upstream logs.' }) (Join-Path $RunDirectory 'final-cleanup-summary.json')
    }
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
