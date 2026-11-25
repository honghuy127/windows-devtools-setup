#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Provisions the Claude and Codex desktop apps (MSIX) for every account on the machine.

A provisioned app is registered for each user when they sign in - including people who already
have an account and accounts created later - so nobody has to install it themselves. The app files
live once in C:\Program Files\WindowsApps either way; what this changes is that every account
gets the app automatically, with the same package that per-user installs use (same identity, so
existing installs are simply taken over).

Both apps update themselves after installation, so by default the latest version from winget is
used. Set a Version below to pin the starting version for new accounts.

Not shared: per-user app data. Claude's Cowork VM (several GB under %LOCALAPPDATA%\Claude-Data)
is created per user the first time they turn Cowork on, and holds that user's own session disk.

  -Remove : stop provisioning the apps for new accounts. Users who already have them keep them.
#>
[CmdletBinding()]
param([switch]$Remove)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Apps = @(
    @{ WingetId = 'Anthropic.Claude'; Package = 'Claude';       Version = '' }   # Claude (includes Cowork)
    @{ WingetId = 'OpenAI.ChatGPT';   Package = 'OpenAI.Codex'; Version = '' }   # Codex desktop app
)
$root = 'C:\DevTools'
$stateFile = Join-Path $root '.desktop-apps.json'
$failed = @()

function Get-Provisioned([string]$Package) {
    Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq $Package |
        Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
}
function Read-MsixIdentity([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.GetEntry('AppxManifest.xml')
        if (!$entry) { $entry = $zip.GetEntry('AppxMetadata/AppxBundleManifest.xml') }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Close() }
    } finally { $zip.Dispose() }
    $manifest.DocumentElement.Identity
}

if ($Remove) {
    foreach ($app in $Apps) {
        $p = Get-Provisioned $app.Package
        if ($p) {
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName | Out-Null
            Write-Host "No longer provisioning $($app.Package) (existing users keep it)."
        }
    }
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    return
}

$winget = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
if (!$winget) { throw 'winget not found; install/update App Installer first.' }
if (!(Test-Path -LiteralPath $root)) { throw "$root not found; run Setup-DevTools.ps1 first." }

$provisioned = @()
foreach ($app in $Apps) {
    # Download into an admin-only folder under C:\DevTools (inherits its ACL).
    $tmp = Join-Path $root ('install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $wgArgs = @('download', '--id', $app.WingetId, '--exact', '--source', 'winget', '--scope', 'machine',
            '--download-directory', $tmp, '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
        if ($app.Version) { $wgArgs += @('--version', $app.Version) }
        & $winget @wgArgs | Out-Host   # winget verifies the installer hash from its manifest
        if ($LASTEXITCODE -ne 0) { throw "winget download failed (exit $LASTEXITCODE)" }

        $msix = Get-ChildItem -LiteralPath $tmp -Recurse -File -Include *.msix, *.msixbundle | Select-Object -First 1
        if (!$msix) { throw 'winget did not return an MSIX installer' }
        $sig = Get-AuthenticodeSignature -LiteralPath $msix.FullName
        if ($sig.Status -ne 'Valid') { throw "MSIX signature is $($sig.Status)" }
        $id = Read-MsixIdentity $msix.FullName
        if ($id.Name -ne $app.Package) { throw "MSIX is '$($id.Name)', expected '$($app.Package)'" }

        $current = Get-Provisioned $app.Package
        if ($current -and [version]$current.Version -ge [version]$id.Version) {
            Write-Host "$($app.Package) $($current.Version) is already provisioned."
        } else {
            Add-AppxProvisionedPackage -Online -PackagePath $msix.FullName -SkipLicense | Out-Null
            Write-Host "Provisioned $($app.Package) $($id.Version) for all accounts."
        }
        $provisioned += $app.Package
    } catch {
        Write-Warning "$($app.WingetId): $($_.Exception.Message)"
        $failed += $app.WingetId
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Read by Test-DevTools.ps1 (which runs non-elevated and can't query provisioning itself).
[ordered]@{ Packages = $provisioned } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
if ($failed.Count) { Write-Warning ('Not provisioned: ' + ($failed -join ', ')) }
Write-Host 'Existing accounts get the apps at their next sign-in.'
