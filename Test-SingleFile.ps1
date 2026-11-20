#Requires -Version 5.1
$ErrorActionPreference='Stop'
$text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'WindowsClean.ps1'))
$tokens=$null; $errors=$null
[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors) | Out-Null
if ($errors.Count) { throw ($errors.Message -join "`n") }
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Disable-WindowsFeatures.ps1'))
$license=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'vendor\Win11Debloat\LICENSE'))
if ($text -ne $source+"`n<#`nAdapted default settings from Raphire/Win11Debloat:`n"+$license+"`n#>`n") { throw 'Single-file release stale; rebuild.' }
if ($text -match 'embeddedUpstream|ExtractToDirectory|upstream-config.json|Win11Debloat\\Win11Debloat.ps1') { throw 'Upstream wrapper remains.' }
Write-Output 'PASS: syntax, release freshness, MIT attribution, no embedded archive/upstream executor. No cleanup executed.'
