#Requires -Version 5.1
# Build only: packages local source, never runs cleanup or downloads dependencies.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$source=Join-Path $PSScriptRoot 'vendor\Win11Debloat'
$memory=New-Object IO.MemoryStream
$zip=New-Object IO.Compression.ZipArchive($memory,[IO.Compression.ZipArchiveMode]::Create,$true)
try {
    foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File -Force | Sort-Object FullName) {
        $relative='Win11Debloat/'+$file.FullName.Substring($source.Length+1).Replace('\','/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$file.FullName,$relative,[IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $zip.Dispose() }
$payload=[Convert]::ToBase64String($memory.ToArray())
$memory.Dispose()
$text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Disable-WindowsFeatures.ps1'))
$anchor='# Windows PowerShell 5.1 only.'
if (-not $text.Contains($anchor)) { throw 'Missing payload insertion anchor.' }
$text=$text.Replace($anchor,('$script:embeddedUpstream='''+$payload+"'`n"+$anchor))
$destination=Join-Path $PSScriptRoot 'WindowsClean.ps1'
[IO.File]::WriteAllText($destination,$text,(New-Object Text.UTF8Encoding($true)))
Write-Output "Built single-file cleanup: $destination ($((Get-Item $destination).Length) bytes)"
