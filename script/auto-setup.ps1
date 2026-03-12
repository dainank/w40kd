<#
.SYNOPSIS
    Installs the latest DirectStorage SDK DLLs and copies the selected config files into a Darktide install.

.DESCRIPTION
    - Prompts for the Steam folder location (must point to a Steam folder like "C:\Program Files (x86)\Steam").
    - Prompts for CPU architecture (x64/x86/ARM64), defaults to x64.
    - Fetches the latest Microsoft.Direct3D.DirectStorage NuGet package and extracts the appropriate DLLs.
    - Copies dstorage.dll and dstoragecore.dll into the Darktide binaries folder.
    - Prompts for a config version (currently only "v4" is available) and copies the matching INI files.
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
    $ramOptions = @('16gb', '32gb', '64gb')
    $selection = Read-Host "Select RAM variant (16gb/32gb/64gb) [32gb]"
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

    Get-ChildItem -Path $sourceConfigDir -Filter '*.ini' -File | ForEach-Object {
        $dest = Join-Path $targetConfigDir $_.Name
        Copy-Item -Path $_.FullName -Destination $dest -Force

        # Show shorter paths for readability
        $sourceShort = $_.FullName -replace "^" + [regex]::Escape("$repoRoot\\"), "${repoName}\\"

        $destShort = $dest
        $marker = 'Warhammer 40,000 DARKTIDE'
        $markerIndex = $dest.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
        if ($markerIndex -ge 0) {
            $destShort = $dest.Substring($markerIndex)
        }

        Write-Host "Copied $sourceShort -> $destShort" -ForegroundColor Green
    }

    Write-Host "Config files copied successfully." -ForegroundColor Green
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
    Write-Host ""  # spacer
}

$ramVariant = $configValues.RamVariant
if (-not $ramVariant) {
    $ramVariant = Get-RamVariant
} else {
    Write-Host "Using RAM variant from configuration: $ramVariant" -ForegroundColor Magenta
}

Copy-DirectStorageDlls -SteamRoot $steamRoot -Arch $arch
Write-Host ""  # spacer between DLL and config steps
Copy-ConfigFiles -SteamRoot $steamRoot -ConfigVersion $configVersion -RamVariant $ramVariant

Write-Host ""  # newline separator
Write-Host "All done! Enjoy the extra FPS." -ForegroundColor Cyan
Write-Host ""  # final newline
