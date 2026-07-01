# Swym skill auto-updater (Windows / PowerShell)
# Installed to ~/.claude/skill-updater.ps1 by install.ps1.
# Runs via Claude Code UserPromptSubmit hook -- at most once per calendar day.

$SkillsDir = Join-Path $HOME ".claude\skills"
$LockFile  = Join-Path $env:TEMP "swym-skill-check-$(Get-Date -Format 'yyyyMMdd').lock"
$Repo      = "swym-corp-custom-solutions/claude-skills"

# Only run once per calendar day
if (Test-Path $LockFile) { exit 0 }
New-Item -ItemType File -Force -Path $LockFile | Out-Null

# Requires gh CLI
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { exit 0 }

# Discover all skills in the repo's main branch
$skillNames = gh api "repos/$Repo/contents/skills?ref=main" --jq ".[].name" 2>$null
if (-not $skillNames) { exit 0 }

function Compare-Semver($a, $b) {
    # Returns 1 if $a > $b, -1 if $a < $b, 0 if equal
    $pa = $a -split "\." | ForEach-Object { [int]$_ }
    $pb = $b -split "\." | ForEach-Object { [int]$_ }
    for ($i = 0; $i -lt 3; $i++) {
        if ($pa[$i] -gt $pb[$i]) { return 1 }
        if ($pa[$i] -lt $pb[$i]) { return -1 }
    }
    return 0
}

foreach ($skillName in $skillNames) {
    $remotePath = "skills/$skillName/SKILL.md"
    $localSkill = Join-Path $SkillsDir "$skillName\SKILL.md"

    # Fetch remote SKILL.md content
    $encoded = gh api "repos/$Repo/contents/${remotePath}?ref=main" --jq ".content" 2>$null
    if (-not $encoded) { continue }
    $remoteContent = [System.Text.Encoding]::UTF8.GetString(
        [System.Convert]::FromBase64String(($encoded -replace "`n","" -replace "`r",""))
    )

    $remoteVersion = ($remoteContent | Select-String "^\s+version:\s+(\S+)" |
        Select-Object -First 1).Matches[0].Groups[1].Value

    # --- Install (first time) ---
    if (-not (Test-Path $localSkill)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $localSkill) | Out-Null
        $remoteContent | Set-Content -Path $localSkill -Encoding UTF8
        Write-Host "[skill-updater] installed $skillName $remoteVersion"
        continue
    }

    # --- Update (version check) ---
    $localVersion = (Select-String -Path $localSkill -Pattern "^\s+version:\s+(\S+)" |
        Select-Object -First 1).Matches[0].Groups[1].Value

    if (-not $localVersion -or -not $remoteVersion) { continue }
    if ($localVersion -eq $remoteVersion) { continue }
    if ((Compare-Semver $localVersion $remoteVersion) -ge 0) { continue }  # local is ahead

    # Archive current version before overwriting
    $versionsDir = Join-Path (Split-Path $localSkill) "versions"
    New-Item -ItemType Directory -Force -Path $versionsDir | Out-Null
    Copy-Item -Path $localSkill -Destination (Join-Path $versionsDir "SKILL-${localVersion}.md") -Force

    $remoteContent | Set-Content -Path $localSkill -Encoding UTF8
    Write-Host "[skill-updater] updated $skillName $localVersion -> $remoteVersion (previous saved to versions\SKILL-${localVersion}.md)"
}
