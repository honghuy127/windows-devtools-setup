#Requires -Version 5.1
#Requires -RunAsAdministrator
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'WriterMembers',
    Justification = 'Used inside Initialize-WritersGroup via script scope.')]
[CmdletBinding()]
param(
    [switch]$ShareCaches,
    [switch]$SkipExtras,
    [switch]$InstallBuildTools,
    # Let standard users create symlinks (the Hugging Face cache needs them, otherwise files are duplicated).
    [switch]$EnableDeveloperMode,
    # Who may WRITE the shared caches (with -ShareCaches), via the local group $WritersGroup:
    #   AllUsers (default): every account that can sign in to this machine (NT AUTHORITY\Authenticated Users),
    #            including users created later and agent sandbox accounts (e.g. Codex). No per-machine edits needed.
    #   Members: only the accounts in -WriterMembers (plus anyone an admin adds to the group later).
    [ValidateSet('AllUsers', 'Members')][string]$Writers = 'AllUsers',
    [string[]]$WriterMembers = @(),
    [string]$WritersGroup = 'DevTools Writers',
    # Folders holding repos shared between users/agents -> added to git safe.directory (system level).
    [string[]]$SharedRepoRoots = @(),
    [ValidateSet('', 'true', 'false', 'input')][string]$GitAutoCrlf = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest on PS 5.1 is very slow when showing progress

# ============================================================================
# AGREED VERSIONS - edit only here. Never use 'latest'.
#   uv hash: from uv-<target>.zip.sha256 on the release page of that exact version
#            https://github.com/astral-sh/uv/releases/tag/<version>
#   Python: pinned by MINOR ('3.13'). The patch is decided by the pinned uv version
#           (uv 0.13.10 -> 3.13.18), so installs stay reproducible; bumping uv = security patch bump.
#   Winget: '' = not pinned (warns). List versions: winget show --id <id> --versions
#   Versions below were current on 2026-11-25.
# ============================================================================
$Pinned = @{
    Uv         = '0.13.10'
    UvSha256   = @{
        'x86_64-pc-windows-msvc'  = '297b3881fe1adfb922becc2c1613202abb41dc83ea5ff43d472aa087ca1f8683'
        'aarch64-pc-windows-msvc' = 'f223bcd3fa010174ffeeb885cc1d5334bb81388640c65baa5b8b42b47017337e'
    }
    # 3.13: newest version for which every major library ships Windows wheels (TensorFlow 2.21 stops at 3.13;
    # torch, numpy, scipy, pandas, onnxruntime, numba... all support it). 3.14/3.15 are not broad enough yet.
    Python     = '3.13'
    Winget     = [ordered]@{
        'Git.Git'                    = '2.56.1'
        'OpenJS.NodeJS.LTS'          = '26.13.1'
        'Gyan.FFmpeg'                = '9.1'
        'Kitware.CMake'              = '4.4.4'   # CMake 4 drops support for cmake_minimum_required < 3.5
        'Ninja-build.Ninja'          = '1.13.2'
        'BurntSushi.ripgrep.MSVC'    = '16.0.0'
        'jqlang.jq'                  = '1.8.2'
        'GitHub.cli'                 = '2.105.0'
        'Microsoft.VisualStudioCode' = '1.146.0' # System (machine-wide) installer
        # Documents / OCR for agents (used with the venv C:\DevTools\envs\agent)
        'TheDocumentFoundation.LibreOffice' = '26.8.3.1'   # soffice --headless --convert-to pdf
        'JohnMacFarlane.Pandoc'      = '3.14'
        'tesseract-ocr.tesseract'    = '5.5.3'   # official build; UB-Mannheim has no machine-wide installer
    }
    # Tesseract language data, pinned by repo + commit + SHA256 (repo tesseract-ocr/<Repo>).
    # Compared on 2026-11-25: Vietnamese is more accurate with standard (tessdata) than fast;
    # Japanese/Chinese are much better with fast. eng/jpn fast equal the files bundled by the installer.
    TessdataCommits = @{
        'tessdata'      = 'ced78752cc61322fb554c280d13360b35b8684e4'
        'tessdata_fast' = '87416418657359cb625c412a48b6e1d6d41c29bd'
    }
    Tessdata   = @(
        @{ Lang = 'eng';          Repo = 'tessdata_fast'; Sha256 = '7D4322BD2A7749724879683FC3912CB542F19906C83BCC1A52132556427170B2' }
        @{ Lang = 'vie';          Repo = 'tessdata';      Sha256 = '164D9BED7E5A6444586D39434CC1ADF4DF976CFE23CFFD6468E444C94703640A' }
        @{ Lang = 'jpn';          Repo = 'tessdata_fast'; Sha256 = '1F5DE9236D2E85F5FDF4B3C500F2D4926F8D9449F28F5394472D9E8D83B91B4D' }
        @{ Lang = 'jpn_vert';     Repo = 'tessdata_fast'; Sha256 = 'BF1E2640954691797E2DC14F38533E601B59EE37958698AE0F0B81DC6F09C71B' }
        @{ Lang = 'chi_sim';      Repo = 'tessdata_fast'; Sha256 = 'A5FCB6F0DB1E1D6D8522F39DB4E848F05984669172E584E8D76B6B3141E1F730' }
        @{ Lang = 'chi_sim_vert'; Repo = 'tessdata_fast'; Sha256 = '20590DE84725BAB69CDE93BD6E8ED360A13CC5421A7E7364DDEB93E9AF53D6DA' }
        @{ Lang = 'chi_tra';      Repo = 'tessdata_fast'; Sha256 = '529C5B5797D64B126065CD55F2BB4C7FD7B15790798091B1FF259941A829330B' }
        @{ Lang = 'chi_tra_vert'; Repo = 'tessdata_fast'; Sha256 = '1DF02A4B210E5C217B783819538B63E9DFE6904E2B5E53B62664F1B9F7A989D0' }
    )
    BuildToolsId = 'Microsoft.VisualStudio.BuildTools'   # VS 2026; for 2022: Microsoft.VisualStudio.2022.BuildTools
    BuildTools   = '18.12.1'
}

$root = 'C:\DevTools'
$bin = Join-Path $root 'bin'
$python = Join-Path $root 'python'
$cache = Join-Path $root 'cache'
$uv = Join-Path $bin 'uv.exe'
$marker = Join-Path $root '.devtools-managed'
$SidSystem = 'S-1-5-18'
$SidAdmins = 'S-1-5-32-544'
$SidUsers = 'S-1-5-32-545'
$SidAuthUsers = 'S-1-5-11'
# On the first run, $root may only contain $root\setup (scripts, agent-env...) and/or
# these scripts directly in $root (legacy layout).
$BootstrapFiles = @('Setup-DevTools.ps1', 'Test-DevTools.ps1')
$BootstrapDir = 'setup'
# Kit contents (copied into $root\setup when the kit is run from somewhere else).
$KitItems = @('Install-DevTools.ps1', 'Setup-DevTools.ps1', 'Install-AgentEnv.ps1', 'Install-AgentInstructions.ps1',
    'Test-DevTools.ps1', 'agent-instructions.md', 'README.md', 'agent-env')
# winget exit codes treated as success: 0, already installed (0x8A150061), no applicable upgrade (0x8A15002B).
$WingetOkCodes = @(0, -1978335135, -1978335189)

function Get-Sid([string]$Sid) { [System.Security.Principal.SecurityIdentifier]::new($Sid) }

# SID-based ACLs (work on localized Windows). Only Admins/SYSTEM can write tools;
# the writers group (if any) gets Modify; Users get read/execute.
function Set-DevAcl([string]$Path, [string]$WriterSid) {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((Get-Sid $SidAdmins))
    $entries = @(
        @{ Sid = $SidSystem; Rights = 'FullControl' },
        @{ Sid = $SidAdmins; Rights = 'FullControl' },
        @{ Sid = $SidUsers; Rights = 'ReadAndExecute' }
    )
    if ($WriterSid) { $entries += @{ Sid = $WriterSid; Rights = 'Modify' } }
    foreach ($entry in $entries) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new((Get-Sid $entry.Sid), [System.Security.AccessControl.FileSystemRights]$entry.Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function New-DevDir([string]$Path, [string]$WriterSid = '') {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unsafe directory: $Path" }
    } else { New-Item -ItemType Directory -Path $Path | Out-Null }
    Set-DevAcl $Path $WriterSid
}
function Set-MachineVar([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')   # also broadcasts WM_SETTINGCHANGE
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}
function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed (exit $LASTEXITCODE)" }
}
function Get-CheckedOutput([string]$Exe, [string[]]$Arguments) {
    $out = (& $Exe @Arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed (exit $LASTEXITCODE): $out" }
    $out
}
# Append $Dir to the END of Machine PATH, keeping %SystemRoot%-style entries and REG_EXPAND_SZ.
function Add-MachinePath([string]$Dir) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $parts = @($raw -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $Dir.TrimEnd('\') })
        $key.SetValue('Path', (($parts + $Dir) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Close() }
    $env:Path = ((@($env:Path -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $Dir.TrimEnd('\') }) + $Dir) -join ';')
}
function Initialize-WritersGroup {
    $group = Get-LocalGroup -Name $WritersGroup -ErrorAction SilentlyContinue
    if (!$group) {
        $group = New-LocalGroup -Name $WritersGroup -Description "Write access to shared caches in $root"
        Write-Host "Created local group '$WritersGroup'."
    }
    $current = @(Get-LocalGroupMember -Group $group | ForEach-Object { $_.SID.Value })
    if ($Writers -eq 'AllUsers') {
        if ($current -notcontains $SidAuthUsers) {
            Add-LocalGroupMember -Group $group -Member $SidAuthUsers
            Write-Host "Added Authenticated Users to '$WritersGroup': every account on this machine can write shared caches (next sign-in)."
        }
    } elseif ($current -contains $SidAuthUsers) {
        Remove-LocalGroupMember -Group $group -Member $SidAuthUsers
        Write-Host "Removed Authenticated Users from '$WritersGroup' (Members mode)."
    }
    foreach ($name in $WriterMembers) {
        # Accepts a local name, MACHINE\user, AzureAD\user or a SID.
        try { $sid = ([System.Security.Principal.NTAccount]$name).Translate([System.Security.Principal.SecurityIdentifier]).Value }
        catch { if ($name -match '^S-1-') { $sid = $name } else { Write-Warning "Account '$name' not found; skipped."; continue } }
        if ($current -notcontains $sid) {
            Add-LocalGroupMember -Group $group -Member $sid
            Write-Host "Added '$name' to '$WritersGroup' (takes effect at next sign-in)."
        }
    }
    if ($Writers -eq 'Members' -and !@(Get-LocalGroupMember -Group $group).Count) {
        Write-Warning "'$WritersGroup' has no members: nobody can write shared caches. Pass -WriterMembers or add accounts to the group."
    }
    $group.SID.Value
}
function Install-WingetPackage([string]$Exe, [string]$Id, [string]$Version, [string[]]$Extra = @()) {
    $wgArgs = @('install', '--id', $Id, '--exact', '--source', 'winget', '--scope', 'machine',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($Version) { $wgArgs += @('--version', $Version) }
    else { Write-Warning "$Id has no pinned version; installing latest." }
    # Out-Host: keep winget output out of the function's return value (true/false).
    & $Exe @($wgArgs + $Extra) | Out-Host
    if ($WingetOkCodes -notcontains $LASTEXITCODE) { Write-Warning "Check installation of $Id (exit $LASTEXITCODE)"; return $false }
    $true
}

# ---------------------------------------------------------------------------
# 0. Validate version config before changing anything
# ---------------------------------------------------------------------------
$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$target = switch ($arch) { 'X64' { 'x86_64-pc-windows-msvc' } 'Arm64' { 'aarch64-pc-windows-msvc' } default { throw "Unsupported architecture: $arch" } }
if ($Pinned.Uv -notmatch '^\d+\.\d+\.\d+$') { throw "Set `$Pinned.Uv to the agreed uv version (current: '$($Pinned.Uv)')." }
if ($Pinned.UvSha256[$target] -notmatch '^[0-9a-fA-F]{64}$') { throw "Set `$Pinned.UvSha256['$target'] to the SHA256 from uv-$target.zip.sha256 of release $($Pinned.Uv)." }
if ($Pinned.Python -notmatch '^\d+\.\d+(\.\d+)?$') { throw "Set `$Pinned.Python to a minor ('3.13') or exact ('3.13.18') version (current: '$($Pinned.Python)')." }
# Smart App Control blocks the unsigned python.exe (python-build-standalone) -> stop early, before any change.
$sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
if ($sac -eq 1) { throw 'Smart App Control is ON and will block the unsigned python.exe this setup installs. Turn it off (Windows Security > App & browser control > Smart App Control) and rerun.' }
if ($sac -eq 2) { Write-Warning 'Smart App Control is in evaluation mode; Windows may switch it ON later and block python.exe. Consider turning it off.' }

# ---------------------------------------------------------------------------
# 1. Make sure $root is trustworthy before running anything elevated
# ---------------------------------------------------------------------------
# C:\ lets Authenticated Users create folders, so a marker file alone proves nothing.
# Later runs: $root must be owned by Administrators/SYSTEM.
# First run: only adopt an existing $root if it contains NOTHING but the setup kit.
$adoptFiles = @()
if (Test-Path -LiteralPath $root) {
    $rootItem = Get-Item -LiteralPath $root -Force
    if (!$rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unsafe root: $root" }
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        $owner = (Get-Acl -LiteralPath $root).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin @($SidAdmins, $SidSystem)) { throw "$root has a marker but is owned by $owner, not Administrators. Possible tampering; inspect manually." }
        $state = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        if ([bool]$state.ShareCaches -ne [bool]$ShareCaches) { throw "Existing setup has ShareCaches=$($state.ShareCaches). Do not switch cache mode in place; review/migrate caches manually." }
    } else {
        $isReparse = { param($i) [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint) }
        $setupDir = Join-Path $root $BootstrapDir
        # In $root: only the scripts and the 'setup' folder are allowed.
        $unexpected = @(Get-ChildItem -LiteralPath $root -Force | Where-Object {
                (& $isReparse $_) -or $(if ($_.PSIsContainer) { $_.Name -ne $BootstrapDir } else { $BootstrapFiles -notcontains $_.Name })
            })
        # In 'setup': admin-run kit (setup, test, agent-env...) - any content,
        # but no reparse points (junctions/symlinks) at any depth.
        if (Test-Path -LiteralPath $setupDir -PathType Container) {
            $unexpected += @(Get-ChildItem -LiteralPath $setupDir -Recurse -Force | Where-Object { & $isReparse $_ } |
                ForEach-Object { [pscustomobject]@{ Name = $_.FullName.Substring($root.Length + 1) + ' (reparse point)' } })
        }
        if ($unexpected.Count) { throw "$root exists without setup marker and contains unexpected items: $(($unexpected | ForEach-Object Name) -join ', '). Inspect or rename it first." }
        $adoptFiles = @(Get-ChildItem -LiteralPath $root -Force -File)
        if (Test-Path -LiteralPath $setupDir -PathType Container) { $adoptFiles += @(Get-Item -LiteralPath $setupDir -Force) }
    }
}

$writerSid = ''
if ($ShareCaches) { $writerSid = Initialize-WritersGroup }

New-DevDir $root
foreach ($f in $adoptFiles) {
    # Make Administrators the owner, drop explicit ACEs, inherit only the new ACL of $root.
    # 'setup' folder: apply to the whole tree (/T).
    $tree = @(); if ($f.PSIsContainer) { $tree = @('/T') }
    Invoke-Checked "$env:SystemRoot\System32\icacls.exe" (@($f.FullName, '/setowner', "*$SidAdmins") + $tree + '/Q')
    Invoke-Checked "$env:SystemRoot\System32\icacls.exe" (@($f.FullName, '/reset') + $tree + '/Q')
}
function Save-Marker([hashtable]$Extra = @{}) {
    $data = [ordered]@{ ShareCaches = [bool]$ShareCaches; WritersMode = $(if ($ShareCaches) { $Writers } else { '' }); WritersGroup = $(if ($ShareCaches) { $WritersGroup } else { '' }); WritersSid = $writerSid }
    foreach ($k in $Extra.Keys) { $data[$k] = $Extra[$k] }
    $data | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
}
Save-Marker

# Kit run from elsewhere (USB, Downloads, git clone...) -> copy it into $root\setup so that
# Install-AgentEnv / Test / later runs use the admin-owned copy.
$kitDir = Join-Path $root $BootstrapDir
if ($PSScriptRoot -ine $kitDir -and $PSScriptRoot -ine $root) {
    if (!(Test-Path -LiteralPath $kitDir)) { New-Item -ItemType Directory -Path $kitDir | Out-Null }   # inherits the ACL of $root
    # Copy only the kit items (not the whole folder, e.g. when run from Downloads).
    foreach ($item in $KitItems) {
        $src = Join-Path $PSScriptRoot $item
        if (Test-Path -LiteralPath $src -PathType Leaf) { Copy-Item -LiteralPath $src -Destination $kitDir -Force }
        elseif (Test-Path -LiteralPath $src -PathType Container) {
            # copy the folder CONTENTS (avoids agent-env\agent-env nesting when the target exists)
            $dst = Join-Path $kitDir $item
            if (!(Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst | Out-Null }
            Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
        }
    }
    Write-Host "Copied setup kit from $PSScriptRoot to $kitDir"
}

New-DevDir $bin
New-DevDir $python
New-DevDir $cache
$cacheDirs = [ordered]@{
    'uv'              = 'UV_CACHE_DIR'
    'huggingface'     = 'HF_HUB_CACHE'
    'huggingface-xet' = 'HF_XET_CACHE'
    'torch'           = 'TORCH_HOME'
    'playwright'      = 'PLAYWRIGHT_BROWSERS_PATH'
}
foreach ($name in $cacheDirs.Keys) { New-DevDir (Join-Path $cache $name) $writerSid }
# Shared model folder, no variable assigned (e.g. point OLLAMA_MODELS here if you use Ollama).
New-DevDir (Join-Path $root 'models') $writerSid

# ---------------------------------------------------------------------------
# 2. uv: download the pinned version, verify SHA256
# ---------------------------------------------------------------------------
$uvStamp = Join-Path $bin 'uv.version'
$installedUv = ''
if (Test-Path -LiteralPath $uvStamp) { $installedUv = (Get-Content -LiteralPath $uvStamp -Raw).Trim() }
if (!(Test-Path -LiteralPath $uv) -or $installedUv -ne $Pinned.Uv) {
    $tmp = Join-Path $root ('install-' + [guid]::NewGuid().ToString('N'))
    New-DevDir $tmp
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $tmp 'uv.zip'
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/astral-sh/uv/releases/download/$($Pinned.Uv)/uv-$target.zip" -OutFile $zip
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($hash -ne $Pinned.UvSha256[$target].ToUpperInvariant()) { throw "uv archive SHA256 mismatch: got $hash" }
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'expanded')
        foreach ($exe in @('uv.exe', 'uvx.exe', 'uvw.exe')) {
            $file = Get-ChildItem (Join-Path $tmp 'expanded') -Filter $exe -Recurse -File | Select-Object -First 1
            if (!$file) {
                if ($exe -eq 'uvw.exe') { continue }
                throw "Missing $exe in uv archive"
            }
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $bin $exe) -Force
        }
        Set-Content -LiteralPath $uvStamp -Value $Pinned.Uv -Encoding ASCII
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
$uvOut = Get-CheckedOutput $uv @('--version')
if ($uvOut -notmatch ('^uv ' + [regex]::Escape($Pinned.Uv) + '(\s|$)')) { throw "Unexpected uv version: $uvOut" }
Write-Host $uvOut

# ---------------------------------------------------------------------------
# 3. Machine environment variables. PATH first so the later broadcasts cover it.
# ---------------------------------------------------------------------------
Add-MachinePath $bin
Set-MachineVar 'UV_PYTHON_INSTALL_DIR' $python
Set-MachineVar 'UV_PYTHON_BIN_DIR' $bin
Set-MachineVar 'UV_PYTHON_DOWNLOADS' 'never'
Set-MachineVar 'UV_LINK_MODE' 'hardlink'
# Keep pip from installing outside a venv (into each user's %APPDATA%) - agents tend to do that.
Set-MachineVar 'PIP_REQUIRE_VIRTUALENV' '1'
# On non-UTF-8 locales (e.g. ja-JP / cp932) Python's open()/subprocess default to the ANSI code page
# -> breaks Vietnamese/CJK text. UTF-8 mode only affects Python, not the Windows locale.
Set-MachineVar 'PYTHONUTF8' '1'

# ---------------------------------------------------------------------------
# 4. Shared Python. The elevated process uses its own cache, never the user-writable shared cache.
# ---------------------------------------------------------------------------
$adminCache = Join-Path $root 'admin-cache'
New-DevDir $adminCache
$env:UV_CACHE_DIR = $adminCache
$env:UV_PYTHON_CACHE_DIR = $adminCache
$env:UV_PYTHON_DOWNLOADS = 'manual'
try {
    # Resolve '3.13' to the exact patch the pinned uv knows; otherwise uv treats an older 3.13.x
    # already installed as good enough and never bumps the patch when uv is upgraded.
    $json = (& $uv --no-config python list $Pinned.Python --only-downloads --output-format json | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "uv python list failed (exit $LASTEXITCODE)" }
    $downloads = @($json | ConvertFrom-Json | Where-Object { $_.implementation -eq 'cpython' -and $_.variant -eq 'default' })
    if (!$downloads.Count) { throw "uv $($Pinned.Uv) has no CPython download matching $($Pinned.Python)" }
    $pythonResolved = $downloads[0].version
    Write-Host "Python $($Pinned.Python) -> $pythonResolved"
    Invoke-Checked $uv @('--no-config', 'python', 'install', $pythonResolved, '--default')
} finally {
    $env:UV_PYTHON_DOWNLOADS = 'never'
    Remove-Item Env:UV_PYTHON_CACHE_DIR -ErrorAction SilentlyContinue
    # Delete the downloaded Python archive, not needed anymore.
    Get-ChildItem -LiteralPath $adminCache -Force | Remove-Item -Recurse -Force
}
$pyOut = Get-CheckedOutput (Join-Path $bin 'python.exe') @('--version')
if ($pyOut -ne "Python $pythonResolved") { throw "bin\python.exe reports '$pyOut', expected Python $pythonResolved. Check 'uv python list' / reinstall with --default." }
Write-Host $pyOut

# ---------------------------------------------------------------------------
# 5. Shared caches
# ---------------------------------------------------------------------------
if ($ShareCaches) {
    foreach ($name in $cacheDirs.Keys) { Set-MachineVar $cacheDirs[$name] (Join-Path $cache $name) }
    $who = if ($Writers -eq 'AllUsers') { 'every account on this machine (incl. agent sandbox accounts)' } else { 'its members' }
    Write-Warning "Shared caches are writable by '$WritersGroup' = $who. Code running as any of them can alter packages used by the others. Never run project code elevated."
} else {
    Remove-Item Env:UV_CACHE_DIR -ErrorAction SilentlyContinue
    Write-Host 'Using default per-user caches (only the Python interpreter is shared).'
}

# ---------------------------------------------------------------------------
# 6. Windows settings: long paths, Developer Mode (symlinks for standard users)
# ---------------------------------------------------------------------------
$fsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
if ((Get-ItemProperty -Path $fsKey -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled -ne 1) {
    Set-ItemProperty -Path $fsKey -Name LongPathsEnabled -Value 1 -Type DWord
    Write-Host 'Enabled Win32 long paths.'
}
$devKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$devMode = (Get-ItemProperty -Path $devKey -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense -eq 1
if ($EnableDeveloperMode -and !$devMode) {
    if (!(Test-Path -LiteralPath $devKey)) { New-Item -Path $devKey | Out-Null }
    New-ItemProperty -Path $devKey -Name AllowDevelopmentWithoutDevLicense -PropertyType DWord -Value 1 -Force | Out-Null
    $devMode = $true
    Write-Host 'Enabled Developer Mode (unprivileged symlinks).'
}
if ($ShareCaches -and !$devMode) { Write-Warning 'Developer Mode is off: Hugging Face cache cannot use symlinks and will duplicate model files. Rerun with -EnableDeveloperMode.' }

# ---------------------------------------------------------------------------
# 7. Extra tools via winget (machine scope)
# ---------------------------------------------------------------------------
$failed = @()
if (!$SkipExtras -or $InstallBuildTools) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (!$winget) { Write-Warning 'winget not found; install/update App Installer and rerun for extras.'; $failed += 'winget' }
    else {
        if (!$SkipExtras) {
            foreach ($id in $Pinned.Winget.Keys) {
                if (!(Install-WingetPackage $winget.Source $id $Pinned.Winget[$id])) { $failed += $id }
            }
            # The System VS Code auto-updates and would drift from the agreed version -> disable via machine policy.
            # To upgrade: change the version in $Pinned and rerun.
            $vscodePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'
            if (!(Test-Path -LiteralPath $vscodePolicy)) { New-Item -Path $vscodePolicy -Force | Out-Null }
            New-ItemProperty -Path $vscodePolicy -Name 'UpdateMode' -PropertyType String -Value 'none' -Force | Out-Null
        }
        if ($InstallBuildTools) {
            $ok = Install-WingetPackage $winget.Source $Pinned.BuildToolsId $Pinned.BuildTools @('--override', '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
            if (!$ok) { $failed += 'Visual Studio Build Tools' }
        }
    }
}

# ---------------------------------------------------------------------------
# 7b. PATH for tools whose installers don't add it; OCR language data
# ---------------------------------------------------------------------------
foreach ($dir in @((Join-Path $env:ProgramFiles 'LibreOffice\program'), (Join-Path $env:ProgramFiles 'Pandoc'), (Join-Path $env:ProgramFiles 'Tesseract-OCR'))) {
    if (Test-Path -LiteralPath $dir) { Add-MachinePath $dir }
}
$tessdata = Join-Path $env:ProgramFiles 'Tesseract-OCR\tessdata'
if (Test-Path -LiteralPath $tessdata) {
    foreach ($t in $Pinned.Tessdata) {
        $lang = $t.Lang
        $file = Join-Path $tessdata "$lang.traineddata"
        $want = $t.Sha256
        $url = "https://raw.githubusercontent.com/tesseract-ocr/$($t.Repo)/$($Pinned.TessdataCommits[$t.Repo])/$lang.traineddata"
        if ((Test-Path -LiteralPath $file) -and ((Get-FileHash -LiteralPath $file).Hash -eq $want)) { continue }
        $tmp = "$file.download"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
            if ((Get-FileHash -LiteralPath $tmp).Hash -ne $want) { throw "SHA256 mismatch" }
            Move-Item -LiteralPath $tmp -Destination $file -Force
            Write-Host "Installed Tesseract language data: $lang"
        } catch {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            Write-Warning "Tesseract language data '$lang' not installed: $($_.Exception.Message)"; $failed += "tessdata-$lang"
        }
    }
} elseif (!$SkipExtras) {
    Write-Warning 'Tesseract not found; skipped language data.'; $failed += 'tessdata'
}

# ---------------------------------------------------------------------------
# 8. System-level Git config (applies to every user and agent)
# ---------------------------------------------------------------------------
$git = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
if (Test-Path -LiteralPath $git) {
    Invoke-Checked $git @('config', '--system', 'core.longpaths', 'true')
    if ($GitAutoCrlf) { Invoke-Checked $git @('config', '--system', 'core.autocrlf', $GitAutoCrlf) }
    $safeDirs = @(& $git config --system --get-all safe.directory 2>$null)
    foreach ($repoRoot in $SharedRepoRoots) {
        # '/*' matches every repo below it (Git >= 2.46).
        $pattern = ($repoRoot.TrimEnd('\', '/') -replace '\\', '/') + '/*'
        if ($safeDirs -notcontains $pattern) {
            Invoke-Checked $git @('config', '--system', '--add', 'safe.directory', $pattern)
            Write-Host "git safe.directory += $pattern"
        }
    }
} elseif (!$SkipExtras) {
    Write-Warning 'git.exe not found; skipped system git config.'
    $failed += 'git config'
}

Save-Marker @{ UvVersion = $Pinned.Uv; PythonVersion = $pythonResolved }
Write-Host 'Core setup complete. Every user must sign out/in (and restart agents such as Codex) to pick up environment variables and group membership.'
if ($failed.Count) { Write-Warning ('Extras requiring verification: ' + ($failed -join ', ')) }
Write-Host 'Run Test-DevTools.ps1 in a NON-elevated PowerShell for each account.'
