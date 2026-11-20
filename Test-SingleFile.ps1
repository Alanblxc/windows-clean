#Requires -Version 5.1
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
$text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'WindowsClean.ps1'))
$tokens=$null; $errors=$null
[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors) | Out-Null
if ($errors.Count) { throw ($errors.Message -join "`n") }
$match=[regex]::Match($text,'(?m)^\$script:embeddedUpstream=''([A-Za-z0-9+/=]+)''')
if (-not $match.Success) { throw 'Missing embedded source.' }
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Disable-WindowsFeatures.ps1'))
if ($text.Remove($match.Index,$match.Length+1) -ne $source) { throw 'Single-file script is stale; rebuild it.' }
$bytes=[Convert]::FromBase64String($match.Groups[1].Value)
$memory=New-Object IO.MemoryStream(,$bytes)
$zip=New-Object IO.Compression.ZipArchive($memory,[IO.Compression.ZipArchiveMode]::Read)
$sha=[Security.Cryptography.SHA256]::Create()
try {
    $files=@(Get-ChildItem (Join-Path $PSScriptRoot 'vendor\Win11Debloat') -Recurse -File -Force)
    if ($zip.Entries.Count -ne $files.Count) { throw 'Embedded source file count mismatch.' }
    foreach ($entry in $zip.Entries) {
        $relative=$entry.FullName.Substring('Win11Debloat/'.Length)
        $local=Join-Path (Join-Path $PSScriptRoot 'vendor\Win11Debloat') $relative
        $stream=$entry.Open()
        try { $actual=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') } finally { $stream.Dispose() }
        if ($actual -ne (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash) { throw "Embedded content mismatch: $relative" }
    }
} finally { $sha.Dispose(); $zip.Dispose(); $memory.Dispose() }
Write-Output "PASS: single-file syntax, current entry source and all $($files.Count) embedded files match. No cleanup executed."
