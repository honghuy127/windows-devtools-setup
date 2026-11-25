#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Installs the whole shared environment on a Windows machine, in this order:
  1. Setup-DevTools.ps1           uv, Python, shared caches, winget tools, Windows/Git settings
  2. Install-AgentEnv.ps1         Python venv for agents (the machine's default python) + Chromium
  3. Install-AgentInstructions.ps1  instructions for Claude Code (all users) and Codex (users who use Codex)
  4. Install-DesktopApps.ps1      Claude and Codex desktop apps, provisioned for every account
Runs from anywhere (USB, Downloads, git clone); Setup copies the kit into C:\DevTools\setup.
Safe to rerun. See README.md.

Examples:
  .\Install-DevTools.ps1                          # default: shared caches, every user may write
  .\Install-DevTools.ps1 -Writers Members -WriterMembers alice,bob
  .\Install-DevTools.ps1 -SharedRepoRoots D:\Projects -InstallBuildTools
#>
[CmdletBinding()]
param(
    [switch]$PrivateCaches,     # no shared caches (per-user caches; only Python is shared)
    [switch]$NoDeveloperMode,   # don't enable Developer Mode (Hugging Face can't use symlinks)
    [switch]$SkipAgentEnv,
    [switch]$SkipAgentInstructions,
    [switch]$SkipDesktopApps,
    # --- passed through to Setup-DevTools.ps1 (see the descriptions there) ---
    [ValidateSet('AllUsers', 'Members')][string]$Writers,
    [string[]]$WriterMembers,
    [string]$WritersGroup,
    [string[]]$SharedRepoRoots,
    [ValidateSet('', 'true', 'false', 'input')][string]$GitAutoCrlf,
    [switch]$SkipExtras,
    [switch]$InstallBuildTools
)
$ErrorActionPreference = 'Stop'
$wrapperOnly = @('PrivateCaches', 'NoDeveloperMode', 'SkipAgentEnv', 'SkipAgentInstructions', 'SkipDesktopApps')
$setupParams = @{}
foreach ($k in $PSBoundParameters.Keys) { if ($wrapperOnly -notcontains $k) { $setupParams[$k] = $PSBoundParameters[$k] } }
if (!$PrivateCaches) { $setupParams['ShareCaches'] = $true }
if (!$NoDeveloperMode) { $setupParams['EnableDeveloperMode'] = $true }

& (Join-Path $PSScriptRoot 'Setup-DevTools.ps1') @setupParams
$kit = 'C:\DevTools\setup'   # Setup copied the kit here if it was run from elsewhere
if (!$SkipAgentEnv) { & (Join-Path $kit 'Install-AgentEnv.ps1') }
if (!$SkipAgentInstructions) { & (Join-Path $kit 'Install-AgentInstructions.ps1') }
if (!$SkipDesktopApps) { & (Join-Path $kit 'Install-DesktopApps.ps1') }
Write-Host ''
Write-Host 'All done. Every user: sign out/in, then run (non-elevated):  C:\DevTools\setup\Test-DevTools.ps1'
