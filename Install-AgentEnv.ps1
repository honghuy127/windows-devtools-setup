#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Install/update the shared Python venv for AI agents & users at C:\DevTools\envs\agent.
  - Packages: agent-env\pyproject.toml; versions locked in agent-env\uv.lock (with hashes).
  - Only admins can write the venv; every user/agent can read & run it.
  - Playwright's Chromium goes into the shared cache (PLAYWRIGHT_BROWSERS_PATH).
  - Entry points: DEVTOOLS_AGENT_PYTHON variable, agent-python command (cmd/PowerShell/Git Bash).
Safe to rerun; by default installs EXACTLY what uv.lock says.
  -Relock  : after adding/removing packages in pyproject.toml (keeps current versions of the others)
  -Upgrade : upgrade every package to the latest compatible version (updates uv.lock)
By default this venv is the machine's DEFAULT python: envs\agent\Scripts sits right before C:\DevTools\bin
in Machine PATH, so `python`/`python3` have all packages. Per-project venvs (uv run,
an activated .venv) still take precedence as usual.
  -NoDefault : remove the venv from PATH (python = bare interpreter; use agent-python for the venv)
#>
[CmdletBinding()]
param(
    [switch]$Relock,
    [switch]$Upgrade,
    [switch]$SkipBrowser,
    [switch]$NoDefault
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = 'C:\DevTools'
$bin = Join-Path $root 'bin'
$uv = Join-Path $bin 'uv.exe'
$project = Join-Path $PSScriptRoot 'agent-env'
$envsDir = Join-Path $root 'envs'
$envDir = Join-Path $envsDir 'agent'
$agentPy = Join-Path $envDir 'Scripts\python.exe'
$adminCache = Join-Path $root 'admin-cache'
$marker = Join-Path $root '.devtools-managed'
$SidAdmins = 'S-1-5-32-544'
$SidSystem = 'S-1-5-18'

function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed (exit $LASTEXITCODE)" }
}
function Set-MachineVar([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}
# Add/remove $Dir in Machine PATH; when adding, place it right before $Before. Keeps %SystemRoot% & REG_EXPAND_SZ.
function Update-MachinePath([string]$Dir, [string]$Before, [bool]$Present) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($p in ($raw -split ';')) { if ($p -and $p.TrimEnd('\') -ine $Dir.TrimEnd('\')) { $list.Add($p) } }
        if ($Present) {
            $i = 0
            while ($i -lt $list.Count -and $list[$i].TrimEnd('\') -ine $Before.TrimEnd('\')) { $i++ }
            $list.Insert($i, $Dir)   # $Before not found -> append
        }
        $key.SetValue('Path', ($list -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Close() }
}
function Assert-SafeDir([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unsafe directory: $Path" }
    }
}

# ---------------------------------------------------------------------------
# 1. Checks: run from C:\DevTools\setup, base environment already built by Setup-DevTools.ps1
# ---------------------------------------------------------------------------
if ($Relock -and $Upgrade) { throw 'Use either -Relock or -Upgrade, not both.' }
if ($PSScriptRoot -ine (Join-Path $root 'setup')) { throw "Run this script from $root\setup (admin-owned), not from $PSScriptRoot." }
if (!(Test-Path -LiteralPath $marker -PathType Leaf) -or !(Test-Path -LiteralPath $uv -PathType Leaf)) { throw 'Base environment missing; run Setup-DevTools.ps1 first.' }
$owner = (Get-Acl -LiteralPath $root).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
if ($owner -notin @($SidAdmins, $SidSystem)) { throw "$root is owned by $owner, not Administrators. Inspect manually." }
foreach ($f in 'pyproject.toml', 'uv.lock') {
    if (!(Test-Path -LiteralPath (Join-Path $project $f) -PathType Leaf)) { throw "Missing $project\$f" }
}
$state = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
$pythonMinor = ($state.PythonVersion -split '\.')[0..1] -join '.'
Assert-SafeDir $envsDir
Assert-SafeDir $envDir
Assert-SafeDir $adminCache

# ---------------------------------------------------------------------------
# 2. Create/update the venv from uv.lock. Admin-only cache, copy files (no hardlinks into the
#    user-writable shared cache), precompile .pyc because users can't write __pycache__.
# ---------------------------------------------------------------------------
if (!(Test-Path -LiteralPath $envsDir)) { New-Item -ItemType Directory -Path $envsDir | Out-Null }   # inherits the admin-only ACL of C:\DevTools
if (!(Test-Path -LiteralPath $adminCache)) { New-Item -ItemType Directory -Path $adminCache | Out-Null }
$saved = @{}
foreach ($n in 'UV_CACHE_DIR', 'UV_PROJECT_ENVIRONMENT', 'UV_LINK_MODE', 'UV_COMPILE_BYTECODE', 'UV_PYTHON_DOWNLOADS') { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
$env:UV_CACHE_DIR = $adminCache
$env:UV_PROJECT_ENVIRONMENT = $envDir
$env:UV_LINK_MODE = 'copy'
$env:UV_COMPILE_BYTECODE = '1'
$env:UV_PYTHON_DOWNLOADS = 'never'
Push-Location -LiteralPath $project
try {
    if ($Upgrade) { Invoke-Checked $uv @('--no-config', 'lock', '--upgrade', '--python', $pythonMinor) }
    elseif ($Relock) { Invoke-Checked $uv @('--no-config', 'lock', '--python', $pythonMinor) }
    # --frozen: install exactly uv.lock (hashes verified); exact sync by default: removes packages not in the lock.
    Invoke-Checked $uv @('--no-config', 'sync', '--frozen', '--no-install-project', '--python', $pythonMinor)
} finally {
    Pop-Location
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
    Get-ChildItem -LiteralPath $adminCache -Force | Remove-Item -Recurse -Force
}
if (!(Test-Path -LiteralPath $agentPy -PathType Leaf)) { throw "Venv python not found: $agentPy" }

# ---------------------------------------------------------------------------
# 3. Playwright Chromium into the shared cache
# ---------------------------------------------------------------------------
if (!$SkipBrowser) {
    $browsers = [Environment]::GetEnvironmentVariable('PLAYWRIGHT_BROWSERS_PATH', 'Machine')
    if (!$browsers) {
        Write-Warning 'PLAYWRIGHT_BROWSERS_PATH is not set machine-wide (Setup without -ShareCaches); skipping browser install. Each user runs: agent-python -m playwright install chromium'
    } else {
        $env:PLAYWRIGHT_BROWSERS_PATH = $browsers
        Invoke-Checked $agentPy @('-I', '-m', 'playwright', 'install', 'chromium')
    }
}

# ---------------------------------------------------------------------------
# 4. Entry points for users/agents
# ---------------------------------------------------------------------------
# The venv only has python.exe; copies of the launcher named python3 / python3.13 still resolve to the venv.
$scripts = Join-Path $envDir 'Scripts'
foreach ($alias in @('python3.exe', "python$pythonMinor.exe")) { Copy-Item -LiteralPath $agentPy -Destination (Join-Path $scripts $alias) -Force }
# PATH first; Set-MachineVar below broadcasts the change.
Update-MachinePath $scripts $bin (!$NoDefault)
if ($NoDefault) { Write-Host 'Agent env is NOT the default python (removed from PATH).' }
else { Write-Host "Agent env is the default python: $scripts precedes $bin in Machine PATH." }
Set-MachineVar 'DEVTOOLS_AGENT_PYTHON' $agentPy
Set-Content -LiteralPath (Join-Path $bin 'agent-python.cmd') -Value "@`"$agentPy`" %*" -Encoding ASCII
# Git Bash (Claude Code, Codex): extensionless file with a shebang.
$shPath = '/' + ($agentPy.Substring(0, 1).ToLowerInvariant()) + ($agentPy.Substring(2) -replace '\\', '/')
[IO.File]::WriteAllText((Join-Path $bin 'agent-python'), "#!/bin/sh`nexec `"$shPath`" `"`$@`"`n", [Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
# Count installed distributions directly (uv pip list prints to stderr, which PS 5.1 shows as an error).
$pkgCount = @(Get-ChildItem -LiteralPath (Join-Path $envDir 'Lib\site-packages') -Directory -Filter '*.dist-info').Count
$sizeMb = (Get-ChildItem -LiteralPath $envDir -Recurse -File -Force | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Agent env ready: {0} ({1} packages, {2:N0} MB)" -f $envDir, $pkgCount, $sizeMb)
Write-Host 'Use: python script.py (default)  |  agent-python script.py  |  "$DEVTOOLS_AGENT_PYTHON" script.py'
Write-Host 'Sign out/in to pick up PATH and DEVTOOLS_AGENT_PYTHON, then run Test-DevTools.ps1 (non-elevated) to smoke-test office/PDF/OCR/web/browser.'
