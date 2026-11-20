# Parse and import only named pure functions; never execute the cleanup script.
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'Disable-WindowsFeatures.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
$extraTokens=$null; $extraErrors=$null
$extraAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'ExtendedReview.ps1'),[ref]$extraTokens,[ref]$extraErrors)
if ($extraErrors.Count) { throw ($extraErrors.Message -join "`n") }
$comparisonFunction=$extraAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true) | Where-Object Name -eq 'Get-HealthComparison'
. ([scriptblock]::Create($comparisonFunction.Extent.Text))
$before=[pscustomobject]@{Time='before'; ProcessCount=140; TotalMemoryKB=16777216; FreeMemoryKB=8388608}
$after=[pscustomobject]@{Time='after'; ProcessCount=120; TotalMemoryKB=16777216; FreeMemoryKB=9437184}
$comparison=Get-HealthComparison $before $after
if ($comparison.ProcessCountChange -ne -20 -or $comparison.BeforeUsedMemoryMB -ne 8192 -or $comparison.AfterUsedMemoryMB -ne 7168 -or $comparison.UsedMemoryChangeMB -ne -1024) { throw 'Resource reduction comparison failed' }
$reverse=Get-HealthComparison $after $before
if ($reverse.ProcessCountChange -ne 20 -or $reverse.UsedMemoryChangeMB -ne 1024) { throw 'Resource increase comparison failed' }
$same=Get-HealthComparison $before $before
if ($same.ProcessCountChange -ne 0 -or $same.UsedMemoryChangeMB -ne 0) { throw 'Unchanged comparison failed' }
if ($extraAst.Extent.Text -match '(?i)WirelessDisplay|AppPrivacy|SysMain.*Set-Service') { throw 'Excluded changes found in extension.' }
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
foreach ($name in @('Get-DriverDecision', 'Get-StartupAdvice')) {
    $definition = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object Name -eq $name | Select-Object -First 1
    Assert ($null -ne $definition) "Missing function: $name"
    . ([scriptblock]::Create($definition.Extent.Text))
}
Assert ((Get-DriverDecision 'beep' $true 'Running' @() $false) -eq 'Eligible') 'beep may be configured without unloading'
Assert ((Get-DriverDecision 'bowser' $true 'Stopped' @() $true) -eq 'NotAllowlisted') 'Closed allowlist'
Assert ((Get-DriverDecision 'HidIr' $true 'Running' @() $true) -eq 'Running') 'Preserve running driver'
Assert ((Get-DriverDecision 'usbcir' $true 'Stopped' @('Disconnected receiver') $true) -eq 'DeviceDependency') 'Disconnected device blocks change'
Assert ((Get-DriverDecision '1394ohci' $true 'Stopped' @() $false) -eq 'UncertainInventory') 'Incomplete inventory fails closed'
Assert ((Get-DriverDecision 'circlass' $false 'Unknown' @() $true) -eq 'NotInstalled') 'Never create missing driver'
Assert ((Get-DriverDecision '1394ohci' $true 'Stopped' @() $true) -eq 'Eligible') 'Complete clean inventory'
Assert ((Get-StartupAdvice 'Windows Defender' 'C:\Windows\system.exe').Recommend -eq $false) 'Preserve security'
Assert ((Get-StartupAdvice 'Unknown helper' 'C:\Apps\unknown.exe').Recommend -eq $false) 'Unknown is not unnecessary'
Assert ((Get-StartupAdvice 'Steam' 'C:\Games\Steam\steam.exe -silent').Recommend -eq $true) 'Review optional launcher'
# Backup failure must abort before the registry writer is invoked.
$definition = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object Name -eq 'Change-Reg' | Select-Object -First 1
Assert ($null -ne $definition) 'Missing backed-up registry change function'
. ([scriptblock]::Create($definition.Extent.Text))
function Get-RegOriginal { [pscustomobject]@{ Exists=$false; Kind='DWord'; Value=$null } }
function Save-Journal { throw 'simulated backup failure' }
function Write-RegValue { $script:writeCalled=$true }
$script:writeCalled=$false
$script:journal=[pscustomobject]@{ Changes=@() }
$caught=$false
try { Change-Reg 'Fake:\Key' 'Test' 0 } catch { $caught=$true }
Assert ($caught -and -not $script:writeCalled) 'Backup failure must prevent mutation'
$source=$ast.Extent.Text
Assert ($source -notmatch '(?i)Checkpoint-Computer|Enable-ComputerRestore') 'Custom script must leave restore points to upstream'
Assert ($source -notmatch '(?i)Invoke-WebRequest|codeload\.github|RunDefaults|Start-Process') 'No upstream downloads/execution or UAC launch'
Assert ($source -notmatch '(?i)Restart-Computer|Stop-Computer|logoff\.exe|shutdown\.exe') 'No automatic restart/logoff'
Assert ($source -notmatch '(?i)Set-Service\s+[''"]?(WSearch|GamingServices|GamingServicesNet|GameInput)') 'Protected services are not modified'
Assert ($source -notmatch '(?i)Stop-Process|taskkill') 'No forced process termination'
Write-Output 'PASS: Windows PowerShell syntax, 10 decision tests, 3 resource comparison tests, backup-failure test and 5 static safety checks. No cleanup code executed.'
