#Requires -Version 5.1
# Publish the self-contained source; never execute cleanup.
$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Disable-WindowsFeatures.ps1'))
$license=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'vendor\Win11Debloat\LICENSE'))
$text=$source+"`n<#`nAdapted default settings from Raphire/Win11Debloat:`n"+$license+"`n#>`n"
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'WindowsClean.ps1'),$text,(New-Object Text.UTF8Encoding($true)))
Write-Output 'Built WindowsClean.ps1: direct operations, no embedded archive or upstream executor.'
