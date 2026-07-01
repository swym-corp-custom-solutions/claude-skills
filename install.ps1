# Swym Claude Skills installer (Windows / PowerShell)
# Run once from this repo root:
#   .\install.ps1
#
# What it does:
#   1. Copies all skills from .\skills\ into ~/.claude/skills/
#   2. Installs the auto-updater script to ~/.claude/
#   3. Wires a UserPromptSubmit hook in ~/.claude/settings.json so skills
#      stay up to date automatically (daily check against GitHub main).

$ErrorActionPreference = "Stop"

$RepoDir   = $PSScriptRoot
$SkillsSrc = Join-Path $RepoDir "skills"
$ClaudeDir = Join-Path $HOME ".claude"
$SkillsDst = Join-Path $ClaudeDir "skills"
$UpdaterSrc = Join-Path $RepoDir "skill-updater.ps1"
$UpdaterDst = Join-Path $ClaudeDir "skill-updater.ps1"
$Settings  = Join-Path $ClaudeDir "settings.json"

Write-Host "Swym Claude Skills installer"
Write-Host "================================"

# --- 1. Install skills ---------------------------------------------------
Write-Host ""
Write-Host "Installing skills..."
New-Item -ItemType Directory -Force -Path $SkillsDst | Out-Null

Get-ChildItem -Path $SkillsSrc -Directory | ForEach-Object {
    $skillName = $_.Name
    $dest = Join-Path $SkillsDst $skillName
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Path (Join-Path $_.FullName "*") -Destination $dest -Recurse -Force

    $skillMd = Join-Path $dest "SKILL.md"
    $version = "unknown"
    if (Test-Path $skillMd) {
        $match = Select-String -Path $skillMd -Pattern "^\s+version:\s+(\S+)" | Select-Object -First 1
        if ($match) { $version = $match.Matches[0].Groups[1].Value }
    }
    Write-Host "  installed $skillName ($version)"
}

# --- 2. Install auto-updater --------------------------------------------
Write-Host ""
Write-Host "Installing auto-updater..."
Copy-Item -Path $UpdaterSrc -Destination $UpdaterDst -Force
Write-Host "  installed $UpdaterDst"

# --- 3. Wire Claude Code hook -------------------------------------------
Write-Host ""
Write-Host "Configuring Claude Code hook..."

if (-not (Test-Path $Settings)) {
    "{}" | Set-Content -Path $Settings -Encoding UTF8
}

$json = Get-Content -Path $Settings -Raw | ConvertFrom-Json

$hookCommand = 'powershell -NonInteractive -File "$HOME\.claude\skill-updater.ps1"'
$hookEntry   = [PSCustomObject]@{ type = "command"; command = $hookCommand }
$hookBlock   = [PSCustomObject]@{ matcher = ""; hooks = @($hookEntry) }

if (-not $json.PSObject.Properties["hooks"]) {
    $json | Add-Member -MemberType NoteProperty -Name "hooks" -Value ([PSCustomObject]@{})
}
if (-not $json.hooks.PSObject.Properties["UserPromptSubmit"]) {
    $json.hooks | Add-Member -MemberType NoteProperty -Name "UserPromptSubmit" -Value @()
}

$alreadyWired = $json.hooks.UserPromptSubmit | Where-Object {
    $_.hooks | Where-Object { $_.command -eq $hookCommand }
}

if ($alreadyWired) {
    Write-Host "  hook already present -- skipped"
} else {
    $json.hooks.UserPromptSubmit += $hookBlock
    $json | ConvertTo-Json -Depth 10 | Set-Content -Path $Settings -Encoding UTF8
    Write-Host "  hook added to $Settings"
}

Write-Host ""
Write-Host "Done. Start a new Claude Code session to activate."
Write-Host "On first prompt each day, Claude will check for skill updates automatically."
