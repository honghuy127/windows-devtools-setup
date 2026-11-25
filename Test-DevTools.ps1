#Requires -Version 5.1
# Run NON-elevated for every account on the machine, and from inside agents (e.g. Codex) to test sandbox accounts.
$ErrorActionPreference = 'Stop'
$root = 'C:\DevTools'
$bin = Join-Path $root 'bin'
$python = Join-Path $root 'python'
$cache = Join-Path $root 'cache'
$marker = Join-Path $root '.devtools-managed'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this test without elevation.' }
Write-Host "Testing as $($identity.Name)"

$failures = New-Object System.Collections.Generic.List[string]
function Test-Step([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "[OK]   $Name" -ForegroundColor Green }
    catch { $failures.Add("$Name : $($_.Exception.Message)"); Write-Host "[FAIL] $Name : $($_.Exception.Message)" -ForegroundColor Red }
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
function Test-CanWrite([string]$Dir) {
    $probe = Join-Path $Dir ('.devtools-probe-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::Create($probe).Dispose(); Remove-Item -LiteralPath $probe -Force; $true }
    catch [UnauthorizedAccessException] { $false }
}

$state = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
$shared = [bool]$state.ShareCaches
$cacheVars = [ordered]@{
    'UV_CACHE_DIR'             = Join-Path $cache 'uv'
    'HF_HUB_CACHE'             = Join-Path $cache 'huggingface'
    'HF_XET_CACHE'             = Join-Path $cache 'huggingface-xet'
    'TORCH_HOME'               = Join-Path $cache 'torch'
    'PLAYWRIGHT_BROWSERS_PATH' = Join-Path $cache 'playwright'
}

Test-Step 'Machine environment variables (and loaded in this session)' {
    $expected = [ordered]@{
        'UV_PYTHON_INSTALL_DIR'  = $python
        'UV_PYTHON_BIN_DIR'      = $bin
        'UV_PYTHON_DOWNLOADS'    = 'never'
        'PIP_REQUIRE_VIRTUALENV' = '1'
        'PYTHONUTF8'             = '1'
    }
    if ($shared) { foreach ($k in $cacheVars.Keys) { $expected[$k] = $cacheVars[$k] } }
    $bad = @()
    foreach ($k in $expected.Keys) {
        $m = [Environment]::GetEnvironmentVariable($k, 'Machine')
        $p = [Environment]::GetEnvironmentVariable($k, 'Process')
        if ($m -ne $expected[$k]) { $bad += "$k machine='$m'" }
        elseif ($p -ne $expected[$k]) { $bad += "$k process='$p' (sign out/in, or a user-level variable overrides it)" }
    }
    if ($bad.Count) { throw ($bad -join '; ') }
}

# If Install-AgentEnv.ps1 made the agent venv the default, python/python3 must resolve to it.
$agentScripts = Join-Path $root 'envs\agent\Scripts'
$agentDefault = @([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ieq $agentScripts }).Count -gt 0
$pyDir = if ($agentDefault) { $agentScripts } else { $bin }
Test-Step "uv -> $bin; python/python3 -> $pyDir" {
    $expect = [ordered]@{ 'uv' = (Join-Path $bin 'uv.exe'); 'python' = (Join-Path $pyDir 'python.exe'); 'python3' = (Join-Path $pyDir 'python3.exe') }
    foreach ($c in $expect.Keys) {
        $src = (Get-Command $c -CommandType Application | Select-Object -First 1).Source
        if ($src -ine $expect[$c]) { throw "$c resolves to '$src' (sign out/in to refresh PATH)" }
    }
}

Test-Step "Pinned versions (uv $($state.UvVersion), Python $($state.PythonVersion))" {
    $uvOut = Get-CheckedOutput 'uv' @('--version')
    if ($uvOut -notmatch ('^uv ' + [regex]::Escape($state.UvVersion) + '(\s|$)')) { throw "uv reports '$uvOut'" }
    $pyOut = Get-CheckedOutput 'python' @('--version')
    if ($pyOut -ne "Python $($state.PythonVersion)") { throw "python reports '$pyOut'" }
    $found = Get-CheckedOutput 'uv' @('python', 'find', $state.PythonVersion)
    if ($found -notlike "$python*") { throw "uv python find -> '$found' (expected under $python)" }
}

Test-Step 'Tool directories are read-only for this account' {
    $writable = @($root, $bin, $python) | Where-Object { Test-CanWrite $_ }
    if ($writable) { throw "Writable: $($writable -join ', ')" }
}

if ($shared) {
    Test-Step "Member of '$($state.WritersGroup)' in current token" {
        $sid = [Security.Principal.SecurityIdentifier]::new($state.WritersSid)
        if (-not ($identity.Groups -contains $sid)) { throw 'Not in token: add the account to the group, then sign out/in.' }
    }
    Test-Step 'Shared cache directories are writable' {
        $dirs = @($cacheVars.Values) + (Join-Path $root 'models')
        $ro = $dirs | Where-Object { !(Test-CanWrite $_) }
        if ($ro) { throw "Not writable: $($ro -join ', ')" }
    }
}

Test-Step 'Unprivileged symlink (Hugging Face cache needs it)' {
    $dir = Join-Path $env:TEMP ('devtools-symlink-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $code = "import os,sys; d=sys.argv[1]; open(os.path.join(d,'t'),'w').close(); os.symlink(os.path.join(d,'t'), os.path.join(d,'l'))"
        $out = (& python -I -c $code $dir 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "symlink failed (enable Developer Mode: Setup-DevTools.ps1 -EnableDeveloperMode): $out" }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
}

Test-Step 'uv project: init, add, run' {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }
    $tmp = Join-Path $base ('devtools-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Push-Location $tmp
    try {
        Invoke-Checked 'uv' @('init', '--python', $state.PythonVersion, '--no-workspace')
        Invoke-Checked 'uv' @('add', 'requests')
        Invoke-Checked 'uv' @('run', 'python', '-c', 'import sys, requests; print(sys.executable); print(requests.__version__)')
    } finally { Pop-Location; Remove-Item -LiteralPath $tmp -Recurse -Force }
}

if ($shared) {
    Test-Step 'Read uv cache files created by other accounts' {
        $me = $identity.User.Value
        $others = @(Get-ChildItem -LiteralPath $cacheVars['UV_CACHE_DIR'] -Recurse -File -Force -ErrorAction SilentlyContinue |
            Select-Object -First 3000 |
            Where-Object { (Get-Acl -LiteralPath $_.FullName).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $me } |
            Select-Object -First 5)
        if (!$others.Count) { Write-Host '       (no files from other accounts yet; rerun after another account has run this test)'; return }
        foreach ($f in $others) { [IO.File]::OpenRead($f.FullName).Dispose() }
        Write-Host "       read $($others.Count) file(s) owned by other accounts"
    }
}

$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    Test-Step 'git system config core.longpaths=true' {
        $v = (& $git.Source config --system --get core.longpaths 2>$null)
        if ($v -ne 'true') { throw "core.longpaths='$v'" }
    }
}

$code = Get-Command code -ErrorAction SilentlyContinue
if ($code) {
    Test-Step 'VS Code is the machine-wide (System) install' {
        if ($code.Source -notlike "$env:ProgramFiles\*") { throw "code resolves to '$($code.Source)' (per-user install?)" }
    }
}

$agentPy = Join-Path $root 'envs\agent\Scripts\python.exe'
if (Test-Path -LiteralPath $agentPy) {
    Test-Step 'Agent env: DEVTOOLS_AGENT_PYTHON and agent-python' {
        $v = [Environment]::GetEnvironmentVariable('DEVTOOLS_AGENT_PYTHON', 'Process')
        if ($v -ne $agentPy) { throw "DEVTOOLS_AGENT_PYTHON='$v' (sign out/in)" }
        $prefix = (& agent-python.cmd -I -c 'import sys; print(sys.prefix)' 2>&1 | Out-String).Trim()
        if ($prefix -ine (Join-Path $root 'envs\agent')) { throw "agent-python -> '$prefix'" }
    }
    Test-Step 'Agent env is read-only for this account' {
        if (Test-CanWrite (Join-Path $root 'envs\agent\Lib\site-packages')) { throw 'site-packages is writable' }
    }
    Test-Step 'Agent env: office / PDF / markdown / web / Playwright / LibreOffice / Pandoc / OCR smoke test' {
        $smoke = Join-Path $PSScriptRoot 'agent-env\smoke_agent_env.py'
        $prevEnc = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)   # smoke in UTF-8
            $out = (& $agentPy -I $smoke --browser --system-tools 2>&1 | Out-String).Trim()
        } finally { [Console]::OutputEncoding = $prevEnc }
        $out -split "`r?`n" | Where-Object { $_ -match '^\[' } | ForEach-Object { Write-Host "       $_" }
        if ($LASTEXITCODE -ne 0) { throw 'smoke test failed (see lines above)' }
    }
}

# Install-DesktopApps.ps1 records which apps it provisioned; they are registered at sign-in.
$desktopState = Join-Path $root '.desktop-apps.json'
if (Test-Path -LiteralPath $desktopState) {
    $desktop = @((Get-Content -LiteralPath $desktopState -Raw | ConvertFrom-Json).Packages)
    Test-Step "Desktop apps registered for this account ($($desktop -join ', '))" {
        $missing = @($desktop | Where-Object { !(Get-AppxPackage -Name $_ -ErrorAction SilentlyContinue) })
        if ($missing.Count) { throw "not registered yet: $($missing -join ', ') (sign out/in once after provisioning)" }
    }
}

Test-Step 'Agent instructions (Claude Code managed CLAUDE.md, Codex AGENTS.md)' {
    $marker = 'BEGIN DevTools shared environment'
    $claudeMd = Join-Path $env:ProgramFiles 'ClaudeCode\CLAUDE.md'
    if (!(Test-Path -LiteralPath $claudeMd) -or !((Get-Content -LiteralPath $claudeMd -Raw) -match $marker)) { throw "missing in $claudeMd" }
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $agents = @('AGENTS.override.md', 'AGENTS.md') | ForEach-Object { Join-Path $codexHome $_ } |
        Where-Object { (Test-Path -LiteralPath $_) -and (Get-Item -LiteralPath $_).Length -gt 0 } | Select-Object -First 1
    if (!$agents -or !((Get-Content -LiteralPath $agents -Raw) -match $marker)) { throw "missing in $codexHome\AGENTS(.override).md" }
}

foreach ($tool in @('git', 'node', 'ffmpeg', 'cmake', 'ninja', 'rg', 'jq', 'gh', 'code', 'soffice', 'pandoc', 'tesseract')) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) { Write-Host "$tool : $($cmd.Source)" } else { Write-Warning "$tool not found on PATH" }
}

if ($failures.Count) {
    Write-Host "`n$($failures.Count) check(s) failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "`nAll checks passed." -ForegroundColor Green
