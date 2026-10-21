#Requires -Version 7.0
[CmdletBinding()]
param([switch]$Check, [switch]$ConfirmChanges, [string]$ArchivePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$url = 'https://github.com/1openwindow/wiqd/raw/refs/heads/temp/validation-plugin/downloads/validation-plugin.zip'
$archiveFile = 'validation-plugin.zip'
$marketName = 'wiqd-validation-next-preview'
$previewId = "wiqd@$marketName"
$work = $null

function Run-Native {
    param([string]$Program, [string[]]$Arguments)
    $output = & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program $($Arguments -join ' ') failed (exit $LASTEXITCODE)." }
    return ($output -join "`n")
}

function Plugin-Id {
    param($Plugin)
    if ($Plugin.marketplace) { return "wiqd@$($Plugin.marketplace)" }
    if ($Plugin.sourceId) { return [string]$Plugin.sourceId }
    if ($Plugin.id) { return [string]$Plugin.id }
    return 'wiqd'
}

function Read-Flag {
    $result = (Run-Native $script:wiqd @('config', 'flags', 'show', 'validation-next', '--json')) | ConvertFrom-Json
    if ($result.status -ne 'success' -or $result.data.name -ne 'validation-next' -or $result.data.value -isnot [bool]) { throw 'Cannot read the validation-next flag.' }
    return $result.data
}

try {
    $script:wiqd = (Get-Command wiqd -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $copilot = (Get-Command copilot -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $provider = (Run-Native $script:wiqd @('ext', 'show', 'microsoft.validate.next', '--json')) | ConvertFrom-Json
    if ($provider.status -ne 'success') { throw 'WIQD must already include Validate Next. Install a compatible WIQD separately.' }
    $flag = Read-Flag
    if ($flag.source -eq 'env' -and -not $flag.value) { throw 'An environment variable disables validation-next. Resolve that override first.' }

    $plugins = ConvertFrom-Json -InputObject (Run-Native $copilot @('plugin', 'list', '--json')) -NoEnumerate
    $markets = ConvertFrom-Json -InputObject (Run-Native $copilot @('plugin', 'marketplace', 'list', '--json')) -NoEnumerate
    if ($plugins -isnot [array] -or $markets -isnot [array]) { throw 'Copilot CLI must support JSON plugin and marketplace lists.' }
    foreach ($plugin in $plugins | Where-Object name -ieq 'wiqd') {
        if ($plugin.enabled -isnot [bool]) { throw 'Cannot determine a WIQD plugin enabled state.' }
    }
    if (@($plugins | Where-Object { $_.marketplace -eq $marketName -and $_.name -ine 'wiqd' }).Count) { throw 'The preview marketplace has another plugin consumer. Inspect it before replacing it.' }
    $preview = @($plugins | Where-Object { $_.name -ieq 'wiqd' -and (Plugin-Id $_) -eq $previewId })
    $old = @($plugins | Where-Object { $_.name -ieq 'wiqd' -and $_.enabled -ne $false -and (Plugin-Id $_) -ne $previewId })
    $market = @($markets | Where-Object name -eq $marketName)

    $work = Join-Path $HOME ('.wiqd/validation-next/plugin-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
    $zip = if ($ArchivePath) { [IO.Path]::GetFullPath($ArchivePath) } else { Join-Path $work 'validation-plugin.zip' }
    $candidate = Join-Path $work 'candidate'
    if (-not $ArchivePath) {
        if ($url) { Invoke-WebRequest -Uri $url -OutFile $zip }
        else { $zip = Join-Path $PSScriptRoot $archiveFile }
    }
    if ((Get-Item -LiteralPath $zip).Length -gt 64MB) { throw 'ZIP is oversized. No plugin changes were made.' }
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        if ($archive.Entries.Count -gt 4096) { throw 'ZIP has too many entries.' }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $total = 0L
        $expanded = 0L
        $buffer = [byte[]]::new(65536)
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.TrimEnd('/')
            $type = ([long]$entry.ExternalAttributes -shr 16) -band 0xf000
            if ($name.Length -gt 1024 -or $name -notmatch '^[A-Za-z0-9._/-]+$' -or $name.Split('/').Count -gt 32 -or
                ($name.Split('/') | Where-Object { $_ -in @('', '.', '..') -or $_.EndsWith('.') -or $_ -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)' }) -or
                $type -notin @(0, 0x4000, 0x8000) -or ($entry.ExternalAttributes -band [int][IO.FileAttributes]::ReparsePoint) -or
                -not $names.Add($name)) { throw "Unsafe or duplicate ZIP entry: $($entry.FullName)" }
            if (-not $entry.FullName.EndsWith('/')) { [void]$files.Add($name) }
            $total += $entry.Length
            if ($entry.Length -gt 16MB -or $total -gt 64MB) { throw 'ZIP expanded content is oversized.' }
            if (-not $entry.FullName.EndsWith('/')) {
                $stream = $entry.Open()
                try {
                    $actual = 0L
                    while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $actual += $count; $expanded += $count
                        if ($actual -gt 16MB -or $expanded -gt 64MB) { throw 'ZIP expanded content is oversized.' }
                    }
                    if ($actual -ne $entry.Length) { throw 'ZIP entry length is inconsistent.' }
                } finally { $stream.Dispose() }
            }
        }
        foreach ($name in $names) {
            while ($name.Contains('/')) {
                $name = $name.Substring(0, $name.LastIndexOf('/'))
                if ($files.Contains($name)) { throw "ZIP file/directory collision: $name" }
            }
        }
    } finally { $archive.Dispose() }
    Expand-Archive -LiteralPath $zip -DestinationPath $candidate
    $descriptor = Get-Content -LiteralPath (Join-Path $candidate '.github/plugin/marketplace.json') -Raw | ConvertFrom-Json
    if ($descriptor.name -ne $marketName -or $descriptor.plugins.Count -ne 1 -or $descriptor.plugins[0].name -ne 'wiqd' -or $descriptor.plugins[0].source -ne './plugins/wiqd') { throw 'The ZIP is not the validation preview marketplace.' }

    Write-Host "Plugin ZIP checked. New source: $candidate"
    foreach ($plugin in $old) { Write-Host "Disable old plugin: $(Plugin-Id $plugin)" }
    if ($preview.Count) { Write-Host "Replace preview plugin: $previewId" }
    if ($market.Count) { Write-Host "Replace preview marketplace: $marketName" }
    Write-Host "Install and enable: $previewId"
    Write-Host 'This does not upgrade WIQD, sign in, accept terms or run project validation.'
    if ($Check) { Write-Host 'CHECK PASSED. No flag/plugin changes made.'; return }
    if (-not $ConfirmChanges -and ([Console]::IsInputRedirected -or (Read-Host 'Continue? Type yes [default: no]') -ine 'yes')) {
        Write-Host 'Cancelled. No flag/plugin changes made.'
        exit 1
    }

    [IO.File]::WriteAllLines((Join-Path $work 'disabled-plugins.txt'), [string[]]@($old | ForEach-Object { Plugin-Id $_ }), [Text.UTF8Encoding]::new($false))
    if (-not $flag.value) { Run-Native $script:wiqd @('config', 'flags', 'set', 'validation-next', 'true', '--json') | Out-Host }
    if (-not (Read-Flag).value) { throw 'validation-next is not effectively enabled.' }
    # Disable bare-name direct installs before adding another wiqd to avoid ambiguous names.
    foreach ($plugin in $old) { Run-Native $copilot @('plugin', 'disable', (Plugin-Id $plugin)) | Out-Host }
    if ($preview.Count) { Run-Native $copilot @('plugin', 'uninstall', $previewId) | Out-Host }
    if ($market.Count) { Run-Native $copilot @('plugin', 'marketplace', 'remove', $marketName) | Out-Host }
    Run-Native $copilot @('plugin', 'marketplace', 'add', $candidate) | Out-Host
    Run-Native $copilot @('plugin', 'install', $previewId) | Out-Host
    Run-Native $copilot @('plugin', 'enable', $previewId) | Out-Host

    $after = ConvertFrom-Json -InputObject (Run-Native $copilot @('plugin', 'list', '--json')) -NoEnumerate
    $afterMarkets = ConvertFrom-Json -InputObject (Run-Native $copilot @('plugin', 'marketplace', 'list', '--json')) -NoEnumerate
    if ($after -isnot [array] -or $afterMarkets -isnot [array]) { throw 'Cannot verify the final plugin state.' }
    $enabled = @($after | Where-Object { $_.name -ieq 'wiqd' -and $_.enabled -ne $false })
    $selectedMarket = @($afterMarkets | Where-Object name -eq $marketName)
    if ($enabled.Count -ne 1 -or (Plugin-Id $enabled[0]) -ne $previewId -or $enabled[0].enabled -ne $true -or
        $selectedMarket.Count -ne 1 -or $selectedMarket[0].source -ine "Local: $candidate" -or
        $enabled[0].version -ne $descriptor.plugins[0].version -or
        [IO.Path]::GetFullPath($enabled[0].installedFrom) -ine [IO.Path]::GetFullPath($candidate) -or -not (Read-Flag).value) {
        throw 'Plugin switching was not verified. Do not start testing yet.'
    }
    Write-Host "`nValidate Next is installed. Restart Copilot CLI before testing."
    Write-Host "Keep this live plugin directory: $work"
    Write-Host "Previously enabled old plugin IDs: $(Join-Path $work 'disabled-plugins.txt')"
} catch {
    [Console]::Error.WriteLine("Installation stopped: $($_.Exception.Message)")
    if ($work) { [Console]::Error.WriteLine("Keep $work. If changes already started, inspect Copilot before retrying.") }
    exit 2
}
