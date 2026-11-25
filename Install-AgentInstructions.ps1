#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Puts the shared-environment instructions (agent-instructions.md) into:
  - Claude Code: C:\Program Files\ClaudeCode\CLAUDE.md (managed policy, applies to ALL users)
  - Codex: each user's ~\.codex\AGENTS.md (Codex has no machine-wide file). Default: EVERY profile
    on the machine that has used Codex (has a .codex folder) - local, domain or Microsoft/Azure AD. Rerun when
    a new user starts using Codex, or pass -Users to target specific users (creates .codex if missing).
    If a user has a non-empty AGENTS.override.md, the block goes there (Codex reads only that file).
Content lives in a BEGIN/END block; reruns replace only that block and keep the user's own text.
  -Remove : remove the block from all of the files above.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Remove',
    Justification = 'Used inside Update-Block via script scope.')]
[CmdletBinding()]
param(
    [string[]]$Users = @(),
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'agent-instructions.md'
$begin = '<!-- BEGIN DevTools shared environment (managed by C:\DevTools\setup\Install-AgentInstructions.ps1; edit agent-instructions.md there) -->'
$end = '<!-- END DevTools shared environment -->'

if ($PSScriptRoot -ine 'C:\DevTools\setup') { throw "Run this script from C:\DevTools\setup, not from $PSScriptRoot." }
$body = ([IO.File]::ReadAllText($source, [Text.Encoding]::UTF8)).Trim()
$utf8 = [Text.UTF8Encoding]::new($false)

function Update-Block([string]$Path) {
    $dir = Split-Path $Path -Parent
    $old = ''
    if (Test-Path -LiteralPath $Path) { $old = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
    elseif ($Remove) { return }
    $pattern = '(?s)\r?\n?' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end) + '\r?\n?'
    $rest = [regex]::Replace($old, $pattern, "`r`n").Trim()
    if ($Remove) { $new = $rest }
    else {
        $block = "$begin`r`n$body`r`n$end"
        # Shared-environment block goes FIRST; the user's own text follows (read later = higher priority).
        $new = if ($rest) { "$block`r`n`r`n$rest" } else { $block }
    }
    if ($new.Trim() -eq $old.Trim()) { Write-Host "unchanged  $Path"; return }
    if (!(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($old) { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force }
    [IO.File]::WriteAllText($Path, $new.TrimEnd() + "`r`n", $utf8)
    Write-Host ("{0}  {1}" -f $(if ($Remove) { 'removed' } else { 'updated' }), $Path)
}

# Claude Code - managed policy (all users). Admin-managed folder.
$claudeDir = Join-Path $env:ProgramFiles 'ClaudeCode'
if (Test-Path -LiteralPath $claudeDir) {
    if ((Get-Item -LiteralPath $claudeDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe directory: $claudeDir" }
}
Update-Block (Join-Path $claudeDir 'CLAUDE.md')

# Codex - per user. Profiles from ProfileList by SID (never guess C:\Users\<name>).
function Get-UserProfile {
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' | ForEach-Object {
        $sid = $_.PSChildName
        if ($sid -notmatch '^S-1-(5-21|12-1)-') { return }   # local/domain/Azure AD users; skip SYSTEM & services
        $path = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -LiteralPath $_.PSPath).ProfileImagePath)
        if (!$path -or !(Test-Path -LiteralPath $path)) { return }
        $name = try { ([System.Security.Principal.SecurityIdentifier]$sid).Translate([System.Security.Principal.NTAccount]).Value } catch { $sid }
        [pscustomobject]@{ Sid = $sid; Name = $name; Path = $path }
    }
}
$profiles = @(Get-UserProfile)
if ($Users.Count) {
    $targets = @(foreach ($u in $Users) {
            $match = @($profiles | Where-Object { $_.Name -ieq $u -or ($_.Name -split '\\')[-1] -ieq $u -or $_.Sid -eq $u })
            if ($match.Count) { $match } else { Write-Warning "No profile for '$u' (never signed in?); skipped." }
        })
} else {
    $targets = @($profiles | Where-Object { Test-Path -LiteralPath (Join-Path $_.Path '.codex') -ErrorAction SilentlyContinue })
    if (!$targets.Count) { Write-Host 'No user profile has a .codex folder yet; Codex AGENTS.md skipped (rerun later or pass -Users).' }
}
foreach ($p in $targets) {
    $codexHome = Join-Path $p.Path '.codex'
    $override = Join-Path $codexHome 'AGENTS.override.md'
    $target = Join-Path $codexHome 'AGENTS.md'
    if ((Test-Path -LiteralPath $override) -and ((Get-Item -LiteralPath $override).Length -gt 0)) { $target = $override }
    Update-Block $target
}
Write-Host 'Done. New Claude Code / Codex sessions pick this up automatically (restart running sessions).'
