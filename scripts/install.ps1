[CmdletBinding()]
param(
    [string]$Repo = $(if ($env:ZINDEKS_REPO) { $env:ZINDEKS_REPO } else { "sutantodadang/zindeks" }),
    [string]$Version = $(if ($env:ZINDEKS_VERSION) { $env:ZINDEKS_VERSION } else { "latest" }),
    [string]$InstallDir = $(if ($env:ZINDEKS_INSTALL_DIR) { $env:ZINDEKS_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "zindeks\bin" }),
    [switch]$NoPathUpdate
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Repo)) {
    throw "Missing repository. Pass -Repo owner/repo or set ZINDEKS_REPO."
}

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { "x86_64" }
    "ARM64" { "aarch64" }
    default { throw "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
}

$asset = "zindeks-windows-$arch.zip"
if ($Version -eq "latest") {
    $url = "https://github.com/$Repo/releases/latest/download/$asset"
} else {
    $url = "https://github.com/$Repo/releases/download/$Version/$asset"
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("zindeks-install-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    $archive = Join-Path $tmp $asset
    Invoke-WebRequest -Uri $url -OutFile $archive
    Expand-Archive -Path $archive -DestinationPath $tmp -Force

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $source = Join-Path $tmp "zindeks-windows-$arch\zindeks.exe"
    $target = Join-Path $InstallDir "zindeks.exe"
    Copy-Item -Path $source -Destination $target -Force
    Unblock-File -Path $target -ErrorAction SilentlyContinue

    if (-not $NoPathUpdate) {
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $parts = @($userPath -split ";" | Where-Object { $_ })
        if ($parts -notcontains $InstallDir) {
            $newPath = (($parts + $InstallDir) -join ";")
            [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
            $env:Path = "$env:Path;$InstallDir"
            Write-Host "Added $InstallDir to the user PATH. Restart shells to inherit it."
        }
    }

    Write-Host "Installed zindeks to $target"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
