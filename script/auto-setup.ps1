<#
.SYNOPSIS
    Installs optional DirectStorage SDK DLL updates and applies selected config field overrides in a Darktide install.

.DESCRIPTION
    - Prompts for the Steam folder location (must point to a Steam folder like "C:\Program Files (x86)\Steam").
    - Prompts for CPU architecture (x64/x86/ARM64), defaults to x64.
    - Optionally fetches the latest Microsoft.Direct3D.DirectStorage NuGet package and extracts the appropriate DLLs.
    - Optionally copies dstorage.dll and dstoragecore.dll into the Darktide binaries folder.
    - Prompts for a config version (currently only "v4" is available) and applies matching field overrides to existing INI files.
#>

[CmdletBinding()]
param()

function Test-SteamRoot {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Accept paths ending in "Steam" (with or without a trailing backslash) and ensure it starts with a drive letter.
    $normalized = $Path.TrimEnd('\','/')

    if (-not ($normalized -match '^[A-Za-z]:\\')) {
        return $false
    }

    $leaf = Split-Path -Path $normalized -Leaf
    if ($leaf -ne 'Steam') {
        return $false
    }

    if (-not (Test-Path -Path $normalized -PathType Container)) {
        return $false
    }

    return $true
}

function Get-LatestDirectStorageVersion {
    # Uses NuGet flat container API to get the latest version available.
    $indexUrl = 'https://api.nuget.org/v3-flatcontainer/microsoft.direct3d.directstorage/index.json'
    Write-Host "Fetching latest DirectStorage version from NuGet..." -ForegroundColor Cyan

    try {
        $json = Invoke-RestMethod -Uri $indexUrl -UseBasicParsing -ErrorAction Stop
        return $json.versions[-1]
    } catch {
        throw "Failed to fetch latest DirectStorage version: $($_.Exception.Message)"
    }
}

function Get-ArchitectureSelection {
    $archOptions = @('x64', 'x86', 'ARM64')
    $selection = Read-Host 'Select architecture (x64/x86/ARM64) [x64]'
    if ([string]::IsNullOrWhiteSpace($selection)) { $selection = 'x64' }
    if (-not ($archOptions -contains $selection)) {
        Write-Warning "Unknown architecture '$selection'. Defaulting to x64."
        $selection = 'x64'
    }
    return $selection
}

function Get-ConfigVersion {
    # Add additional valid config versions here in the future
    $validVersions = @('v4')
    $selection = Read-Host "Select config version ($([string]::Join('/', $validVersions))) [v4]"
    if ([string]::IsNullOrWhiteSpace($selection)) { $selection = 'v4' }
    if (-not ($validVersions -contains $selection)) {
        Write-Warning "Unknown config version '$selection'. Defaulting to v4."
        $selection = 'v4'
    }
    return $selection
}

function Get-RamVariant {
    $ramOptions = @('8gb', '16gb', '32gb', '64gb')
    $selection = Read-Host "Select RAM variant (8gb/16gb/32gb/64gb) [32gb]"
    if ([string]::IsNullOrWhiteSpace($selection)) { $selection = '32gb' }
    if (-not ($ramOptions -contains $selection)) {
        Write-Warning "Unknown RAM variant '$selection'. Defaulting to 32gb."
        $selection = '32gb'
    }
    return $selection
}

function Load-ScriptConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptRoot
    )

    # Look for configuration.ini in the script folder and in the repo root (parent of script folder).
    $candidatePaths = @()
    $candidatePaths += Join-Path -Path $ScriptRoot -ChildPath 'configuration.ini'
    $candidatePaths += Join-Path -Path (Split-Path -Parent $ScriptRoot) -ChildPath 'configuration.ini'

    $configPath = $candidatePaths | Where-Object { Test-Path -Path $_ -PathType Leaf } | Select-Object -First 1
    if (-not $configPath) {
        return @{}
    }

    $config = @{}
    Get-Content -Path $configPath | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) {
            return
        }

        if ($line -match '^(?<key>[^=\s]+)\s*=\s*(?<value>.+)$') {
            $key = $matches['key'].Trim()
            $value = $matches['value'].Trim()
            $config[$key] = $value
        }
    }

    return $config
}

function Get-BooleanConfigValue {
    param(
        [Parameter(Mandatory)]
        [hashtable]$ConfigValues,
        [Parameter(Mandatory)]
        [string]$Key,
        [Parameter(Mandatory)]
        [bool]$Default
    )

    if (-not $ConfigValues.ContainsKey($Key)) {
        return $Default
    }

    $rawValue = $ConfigValues[$Key]
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return $Default
    }

    $normalized = $rawValue.Trim().Trim('"').Trim("'").ToLowerInvariant()

    switch -Regex ($normalized) {
        '^(true|1|yes|y|on)$' {
            return $true
        }
        '^(false|0|no|n|off)$' {
            return $false
        }
        default {
            Write-Warning "Invalid boolean value '$rawValue' for '$Key'. Defaulting to '$Default'."
            return $Default
        }
    }
}

function Get-RootSettingValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,
        [Parameter(Mandatory)]
        [string]$Key
    )

    $pattern = "(?im)^(?!\s*[#;])\s*" + [regex]::Escape($Key) + "\s*=\s*(?<value>[^\r\n]+)"
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) {
        throw "Expected root key '$Key' was not found."
    }

    return $match.Groups['value'].Value.Trim()
}

function Get-BlockSettingValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,
        [Parameter(Mandatory)]
        [string]$BlockName,
        [Parameter(Mandatory)]
        [string]$Key
    )

    $pattern = "(?ms)" + [regex]::Escape($BlockName) + "\s*=\s*\{.*?^\s*" + [regex]::Escape($Key) + "\s*=\s*(?<value>[^\r\n]+)"
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) {
        throw "Expected key '$Key' in block '$BlockName' was not found."
    }

    return $match.Groups['value'].Value.Trim()
}

function Set-RootSettingValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,
        [Parameter(Mandatory)]
        [string]$Key,
        [Parameter(Mandatory)]
        [string]$NewValue
    )

    $pattern = "(?im)^(?!\s*[#;])(?<prefix>\s*" + [regex]::Escape($Key) + "\s*=\s*)(?<value>[^\r\n]+)"
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) {
        throw "Expected root key '$Key' was not found in target file."
    }

    $valueStart = $match.Groups['value'].Index
    $valueLength = $match.Groups['value'].Length

    return $Content.Substring(0, $valueStart) + $NewValue + $Content.Substring($valueStart + $valueLength)
}

function Set-BlockSettingValue {
    param(
        [Parameter(Mandatory)]
        [string]$Content,
        [Parameter(Mandatory)]
        [string]$BlockName,
        [Parameter(Mandatory)]
        [string]$Key,
        [Parameter(Mandatory)]
        [string]$NewValue
    )

    $pattern = "(?ms)(?<prefix>" + [regex]::Escape($BlockName) + "\s*=\s*\{.*?^\s*" + [regex]::Escape($Key) + "\s*=\s*)(?<value>[^\r\n]+)"
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) {
        throw "Expected key '$Key' in block '$BlockName' was not found in target file."
    }

    $valueStart = $match.Groups['value'].Index
    $valueLength = $match.Groups['value'].Length

    return $Content.Substring(0, $valueStart) + $NewValue + $Content.Substring($valueStart + $valueLength)
}

function Write-TextFileUtf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Content
    )

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Apply-SettingsCommonOverrides {
    param(
        [Parameter(Mandatory)]
        [string]$SourceFile,
        [Parameter(Mandatory)]
        [string]$TargetFile
    )

    $sourceContent = Get-Content -Path $SourceFile -Raw
    $targetContent = Get-Content -Path $TargetFile -Raw

    $blockUpdates = @(
        @{ Block = 'feedback_streamer_settings'; Key = 'max_age_out_tiles_per_frame' }
        @{ Block = 'feedback_streamer_settings'; Key = 'max_streaming_tiles_per_frame' }
        @{ Block = 'feedback_streamer_settings'; Key = 'tile_staging_buffer_size' }
        @{ Block = 'mesh_streamer_settings'; Key = 'limit' }
        @{ Block = 'texture_streamer_settings'; Key = 'streaming_texture_pool_size' }
    )

    foreach ($update in $blockUpdates) {
        $value = Get-BlockSettingValue -Content $sourceContent -BlockName $update.Block -Key $update.Key
        $targetContent = Set-BlockSettingValue -Content $targetContent -BlockName $update.Block -Key $update.Key -NewValue $value
    }

    $rootUpdates = @(
        'streaming_max_open_streams'
        'streaming_texture_pool_size'
    )

    foreach ($key in $rootUpdates) {
        $value = Get-RootSettingValue -Content $sourceContent -Key $key
        $targetContent = Set-RootSettingValue -Content $targetContent -Key $key -NewValue $value
    }

    Write-TextFileUtf8NoBom -Path $TargetFile -Content $targetContent
}

function Apply-Win32Overrides {
    param(
        [Parameter(Mandatory)]
        [string]$SourceFile,
        [Parameter(Mandatory)]
        [string]$TargetFile
    )

    $sourceContent = Get-Content -Path $SourceFile -Raw
    $targetContent = Get-Content -Path $TargetFile -Raw

    $updates = @(
        @{ Block = 'renderer'; Key = 'fullscreen' }
        @{ Block = 'win32'; Key = 'streaming_texture_pool_size' }
    )

    foreach ($update in $updates) {
        $value = Get-BlockSettingValue -Content $sourceContent -BlockName $update.Block -Key $update.Key
        $targetContent = Set-BlockSettingValue -Content $targetContent -BlockName $update.Block -Key $update.Key -NewValue $value
    }

    Write-TextFileUtf8NoBom -Path $TargetFile -Content $targetContent
}

function Copy-DirectStorageDlls {
    param(
        [Parameter(Mandatory)]
        [string]$SteamRoot,
        [Parameter(Mandatory)]
        [string]$Arch
    )

    # Target directories
    $targetBinaries = Join-Path $SteamRoot 'steamapps\common\Warhammer 40,000 DARKTIDE\binaries'
    if (-not (Test-Path -Path $targetBinaries)) {
        Write-Host "Creating binaries folder: $targetBinaries" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $targetBinaries -Force | Out-Null
    }

    $version = Get-LatestDirectStorageVersion
    Write-Host "Latest DirectStorage version: $version" -ForegroundColor Green

    $packageName = 'microsoft.direct3d.directstorage'
    $nugetUrl = "https://api.nuget.org/v3-flatcontainer/$packageName/$version/$packageName.$version.nupkg"

    $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "dstorage-install-$(Get-Random)"
    $tempExtract = Join-Path $tempRoot 'extracted'
    New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null

    try {
        $nupkgPath = Join-Path $tempRoot ('$packageName.' + $version + '.nupkg')
        Write-Host "Downloading DirectStorage package from NuGet..." -ForegroundColor Cyan
        Write-Host ""  # spacer
        Invoke-WebRequest -Uri $nugetUrl -OutFile $nupkgPath -UseBasicParsing -ErrorAction Stop

        Expand-Archive -Path $nupkgPath -DestinationPath $tempExtract -Force

        $sourcePath = Join-Path $tempExtract "native\bin\$Arch"
        if (-not (Test-Path -Path $sourcePath -PathType Container)) {
            throw "Expected native binaries not found for architecture '$Arch' in package (looked under '$sourcePath')."
        }

        $filesToCopy = @('dstorage.dll', 'dstoragecore.dll')
        foreach ($file in $filesToCopy) {
            $sourceFile = Join-Path $sourcePath $file
            if (-not (Test-Path -Path $sourceFile -PathType Leaf)) {
                throw "Expected file not found in package: $file"
            }

            $destFile = Join-Path $targetBinaries $file
            Copy-Item -Path $sourceFile -Destination $destFile -Force
            Write-Host "Copied $file -> $destFile" -ForegroundColor Green
        }

        Write-Host "DirectStorage DLLs copied successfully." -ForegroundColor Green
    } finally {
        if (Test-Path -Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Copy-ConfigFiles {
    param(
        [Parameter(Mandatory)]
        [string]$SteamRoot,
        [Parameter(Mandatory)]
        [string]$ConfigVersion,
        [Parameter(Mandatory)]
        [string]$RamVariant
    )

    # Prefer $PSScriptRoot (works reliably when the script is invoked directly).
    # Fall back to MyInvocation in case $PSScriptRoot is not set.
    $scriptRoot = $PSScriptRoot
    if (-not $scriptRoot) {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
    }

    $sourceConfigDir = Resolve-Path -Path (Join-Path $scriptRoot "..\config\$ConfigVersion\$RamVariant") -ErrorAction Stop

    $targetConfigDir = Join-Path $SteamRoot 'steamapps\common\Warhammer 40,000 DARKTIDE\bundle\application_settings'
    if (-not (Test-Path -Path $targetConfigDir)) {
        Write-Host "Creating config folder: $targetConfigDir" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $targetConfigDir -Force | Out-Null
    }

    $repoRoot = Split-Path -Parent $scriptRoot
    $repoName = Split-Path -Leaf $repoRoot

    $fileOperations = @(
        @{
            Name = 'settings_common.ini'
            Updater = 'Apply-SettingsCommonOverrides'
        }
        @{
            Name = 'win32_settings.ini'
            Updater = 'Apply-Win32Overrides'
        }
    )

    foreach ($operation in $fileOperations) {
        $sourceFile = Join-Path $sourceConfigDir $operation.Name
        $targetFile = Join-Path $targetConfigDir $operation.Name

        if (-not (Test-Path -Path $sourceFile -PathType Leaf)) {
            throw "Expected source config file not found: $sourceFile"
        }

        $sourceShort = $sourceFile -replace "^" + [regex]::Escape("$repoRoot\\"), "${repoName}\\"
        $destShort = $targetFile
        $marker = 'Warhammer 40,000 DARKTIDE'
        $markerIndex = $targetFile.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
        if ($markerIndex -ge 0) {
            $destShort = $targetFile.Substring($markerIndex)
        }

        if (-not (Test-Path -Path $targetFile -PathType Leaf)) {
            # First-time setup fallback: copy full file when the target file does not exist yet.
            Copy-Item -Path $sourceFile -Destination $targetFile -Force
            Write-Host "Copied $sourceShort -> $destShort (target missing)" -ForegroundColor Yellow
            continue
        }

        & $operation.Updater -SourceFile $sourceFile -TargetFile $targetFile
        Write-Host "Updated relevant fields from $sourceShort -> $destShort" -ForegroundColor Green
    }

    Write-Host "Config files updated successfully (non-targeted values preserved)." -ForegroundColor Green
}

## Main
Write-Host "=== Darktide DirectStorage Installer ===" -ForegroundColor DarkRed
Write-Host ""  # spacer

# Detect script location (supports running from repo root or script folder)
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$configValues = Load-ScriptConfiguration -ScriptRoot $scriptRoot

$steamRoot = $configValues.SteamRoot
if (-not $steamRoot) {
    $steamRoot = Read-Host 'Enter your Steam folder (e.g. C:\Program Files (x86)\Steam)'
} else {
    Write-Host "Using Steam folder from configuration: $steamRoot" -ForegroundColor Magenta
}

if (-not (Test-SteamRoot -Path $steamRoot)) {
    Write-Host "Invalid Steam folder. Ensure it is a valid path ending in '\\Steam' (e.g. C:\Program Files (x86)\Steam)." -ForegroundColor Red
    exit 1
}

$arch = $configValues.Architecture
if (-not $arch) {
    $arch = Get-ArchitectureSelection
} else {
    Write-Host "Using architecture from configuration: $arch" -ForegroundColor Magenta
}

$configVersion = $configValues.ConfigVersion
if (-not $configVersion) {
    $configVersion = Get-ConfigVersion
} else {
    Write-Host "Using config version from configuration: $configVersion" -ForegroundColor Magenta
}

$ramVariant = $configValues.RamVariant
if (-not $ramVariant) {
    $ramVariant = Get-RamVariant
} else {
    Write-Host "Using RAM variant from configuration: $ramVariant" -ForegroundColor Magenta
}

$replaceBinaries = Get-BooleanConfigValue -ConfigValues $configValues -Key 'ReplaceBinaries' -Default $true
if ($configValues.ContainsKey('ReplaceBinaries')) {
    Write-Host "Using binary replacement flag from configuration: $replaceBinaries" -ForegroundColor Magenta
} else {
    Write-Host "Binary replacement flag not set in configuration. Defaulting to: $replaceBinaries" -ForegroundColor DarkGray
}
Write-Host ""  # spacer

if ($replaceBinaries) {
    Copy-DirectStorageDlls -SteamRoot $steamRoot -Arch $arch
} else {
    Write-Host "Skipping DirectStorage DLL replacement (ReplaceBinaries=false)." -ForegroundColor Yellow
}
Write-Host ""  # spacer between DLL and config steps
Copy-ConfigFiles -SteamRoot $steamRoot -ConfigVersion $configVersion -RamVariant $ramVariant

Write-Host ""  # newline separator
Write-Host "All done! Enjoy the extra FPS." -ForegroundColor Cyan
Write-Host ""  # final newline
