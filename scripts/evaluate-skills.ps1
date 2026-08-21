# evaluate-skills.ps1 - score skills, split into passing / low-score / conflicts
# Uses activity-weighted scoring from scan. Reads skillhub-index.json, writes skillhub-eval.json.
# Usage: pwsh evaluate-skills.ps1 [-ShowAll] [-WhatIf]

[CmdletBinding()]
param(
    [switch]$ShowAll,
    [switch]$WhatIf,
    [string]$Name = ''
)

. "$PSScriptRoot\common.ps1"

$cfgAll = Get-Config
$config = $cfgAll.base
$local  = $cfgAll.local
$index = Get-Index
if (-not $index -or -not $index.skills) {
    Write-Error "索引为空，请先运行 scan-skills.ps1"
    exit 1
}
$skills = @($index.skills)
if ($Name) {
    $skills = @($skills | Where-Object { $_.name -eq $Name })
    if ($skills.Count -eq 0) {
        Write-Error "索引中未找到技能: $Name"
        exit 1
    }
}
$threshold = 60
if ($config.scoreThreshold) { $threshold = [int]$config.scoreThreshold }
if ($local.scoreThreshold) { $threshold = [int]$local.scoreThreshold }
$forceInclude = @($config.forceInclude) + @($local.forceInclude)
$forceExclude = @($config.forceExclude) + @($local.forceExclude)
# activity free-pass: high-activity skills sync even if below threshold
$freePassUsage = 35
if ($config.freePassUsage) { $freePassUsage = [int]$config.freePassUsage }
if ($local.freePassUsage) { $freePassUsage = [int]$local.freePassUsage }

# ------- conflict detection (same name, multiple source dirs) -------
# Preference order: target (live agent) copies > non-target discovery copies;
# within the same class, higher score wins; ties broken deterministically by
# sourceDir so repeated runs never flip the kept copy.
$seen = @{}
$conflicts = @()
foreach ($s in $skills) {
    if ($seen.ContainsKey($s.name)) {
        $cur = $seen[$s.name]
        $kept = $cur
        $reason = '同名多版本，保留评分最高者'
        $preferTarget = ([bool]$s.isTarget) -and (-not [bool]$cur.isTarget)
        $preferScore  = ([bool]$cur.isTarget -eq [bool]$s.isTarget) -and ($s.totalScore -gt $cur.totalScore)
        $preferTie    = ([bool]$cur.isTarget -eq [bool]$s.isTarget) -and ($s.totalScore -eq $cur.totalScore) -and
                        ([string]$s.sourceDir -lt [string]$cur.sourceDir)
        if ($preferTarget -or $preferScore -or $preferTie) {
            $kept = $s
            if ($preferTarget) { $reason = '同名多版本，保留活跃目标目录副本' }
        }
        $conflicts += @{
            name       = $s.name
            candidates = @($cur.sourceDir, $s.sourceDir)
            kept       = $kept.sourceDir
            reason     = $reason
        }
        $seen[$s.name] = $kept
    } else {
        $seen[$s.name] = $s
    }
}
$uniqueSkills = @($seen.Values)

# ------- classify -------
$passing  = @()
$lowScore = @()
foreach ($s in $uniqueSkills) {
    $force = $false
    $excluded = $false
    if ($s.name -in $forceInclude) { $force = $true }
    if ($s.name -in $forceExclude) { $excluded = $true }
    $decision = if ($force) { 'force' } elseif ($excluded) { 'exclude' } else { '' }
    $s | Add-Member -NotePropertyName 'decision' -NotePropertyValue $decision -Force
    if ($excluded) {
        $lowScore += $s
        $s | Add-Member -NotePropertyName 'excludeReason' -NotePropertyValue 'forceExclude 黑名单' -Force
        continue
    }
    # platform-aware portability: skills that cannot run in a different AI
    # environment must NOT be aggregated (they only spread errors).
    $port = Test-SkillPortableFromIndex $s
    if (-not $port.portable) {
        $lowScore += $s
        $s | Add-Member -NotePropertyName 'excludeReason' -NotePropertyValue ("不可移植: {0}" -f $port.reason) -Force
        continue
    }
    $usage = if ($null -eq $s.usageScore) { 0 } else { [int]$s.usageScore }
    $isActive = ($usage -ge $freePassUsage)
    if ($force -or $isActive -or $s.totalScore -ge $threshold) {
        $passing += $s
        if ($isActive -and $s.totalScore -lt $threshold) {
            $s | Add-Member -NotePropertyName 'passReason' -NotePropertyValue ('活性加权免检 (usage {0} >= {1})' -f $usage, $freePassUsage) -Force
        }
    } else {
        $lowScore += $s
        $s | Add-Member -NotePropertyName 'excludeReason' -NotePropertyValue ('评分 {0} 低于阈值 {1}，活性 {2} 未达免检线 {3}' -f $s.totalScore, $threshold, $usage, $freePassUsage) -Force
    }
}

$eval = [ordered]@{
    evaluatedAt = (Get-Date).ToString('o')
    threshold   = $threshold
    freePassUsage = $freePassUsage
    passing     = $passing
    lowScore    = $lowScore
    conflicts   = $conflicts
    summary     = @{
        total    = $uniqueSkills.Count
        passing  = $passing.Count
        lowScore = $lowScore.Count
        conflicts= $conflicts.Count
    }
}
$evalPath = Get-EvalPath
$eval | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $evalPath -Encoding UTF8

# ------- print report -------
Write-Section ("评估报告 (阈值 {0} | 活性免检线 {1})" -f $threshold, $freePassUsage)
Write-Host ("总计 {0} | 达标 {1} | 低分 {2} | 冲突 {3}" -f $uniqueSkills.Count, $passing.Count, $lowScore.Count, $conflicts.Count) -ForegroundColor Cyan

Write-Section "达标技能 (将被聚合)"
$passing | Sort-Object @{ Expression = { -$_.totalScore } }, @{ Expression = { $_.name } } | ForEach-Object {
    $tag = ''
    if ($_.passReason) { $tag = "  [$($_.passReason)]" }
    Write-Host ("  [{0,3}] {1,-40} {2}{3}" -f $_.totalScore, $_.name, $_.sourceDir, $tag)
}

Write-Section "低分技能 (不聚合，可 review)"
$lowScore | Sort-Object @{ Expression = { $_.totalScore } }, @{ Expression = { $_.name } } | ForEach-Object {
    Write-Host ("  [{0,3}] {1,-40} {2}" -f $_.totalScore, $_.name, $_.excludeReason) -ForegroundColor DarkYellow
}

if ($conflicts.Count -gt 0) {
    Write-Section "同名冲突"
    foreach ($c in $conflicts) {
        Write-Host ("  {0} -> 保留 {1}" -f $c.name, $c.kept) -ForegroundColor Magenta
    }
}

Write-Host ""
Write-Host ("完整报告: {0}" -f $evalPath) -ForegroundColor Green