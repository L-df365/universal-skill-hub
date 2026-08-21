# scan-skills.ps1 - structural discovery: any dir containing SKILL.md is a skill root
# Structural (not name-list based): works for ANY agent/software using SKILL.md.
# Usage: pwsh scan-skills.ps1 [-DeepScan] [-RefreshIndex]

[CmdletBinding()]
param(
    [switch]$DeepScan,
    [switch]$RefreshIndex
)

. "$PSScriptRoot\common.ps1"

$cfgAll = Get-Config
$config = $cfgAll.base
$local  = $cfgAll.local

$excludeDirs = @($config.excludeDirs) + @('.git','node_modules','.Trash','.agent-backups','.system','.backups')
if ($local.excludeDirs) { $excludeDirs += @($local.excludeDirs) }
$maxDepth = 3
if ($config.scanDepth) { $maxDepth = [int]$config.scanDepth }
if ($DeepScan) { $maxDepth = [Math]::Max($maxDepth, 6) }
$storeDir = Get-StoreDir
$storeRoot = Split-Path $storeDir -Parent
$trashDir = Get-StoreTrashDir
$hubRootDir = Get-HubRoot

# ---------- candidate roots: NOT a whitelist of agent names ----------
# Walk well-known config/home locations structurally. Skill roots are detected
# by the presence of SKILL.md, not by which software owns the directory.
$candidateRoots = @()
foreach ($c in @(
    (Join-Path $HOME '*'),
    (Join-Path $HOME '.config', '*'),
    (Join-Path $HOME '.config' ),
    $HOME,
    $env:USERPROFILE
)) {
    if (-not $c -or -not (Test-Path -LiteralPath $c)) { continue }
    $candidateRoots += $c
}
if ($local.extraScanRoots) { $candidateRoots += @($local.extraScanRoots) }

# ---------- walker: find dirs that directly contain SKILL.md ----------
$skillRoots = @{}   # canonical skill-root dir (parent containing skills) -> info
$allFound = @()     # raw: name, rootDir, skillDir
$visited = @{}

function Test-HubOwned([string]$dir) {
    # the hub's own dirs (store, trash, install root) are never skills
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    $d = [System.IO.Path]::GetFullPath($dir).TrimEnd([IO.Path]::DirectorySeparatorChar)
    foreach ($base in @($storeDir, $trashDir, $hubRootDir)) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $b = [System.IO.Path]::GetFullPath((Resolve-HomePath $base)).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if ($d -eq $b -or $d.StartsWith($b + [IO.Path]::DirectorySeparatorChar)) { return $true }
    }
    return $false
}

function Test-SkillRootDir([string]$dir) {
    # a "skill root dir" is a directory whose immediate children contain SKILL.md
    try {
        foreach ($child in Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue) {
            if ($child.Name.StartsWith('.')) { continue }
            if (Test-Path -LiteralPath (Join-Path $child.FullName 'SKILL.md')) { return $true }
        }
    } catch { }
    return $false
}

function Walk-Scan([string]$dir, [int]$depth) {
    if ($depth -gt $maxDepth) { return }
    if ($visited.ContainsKey($dir)) { return }
    $visited[$dir] = $true
    try {
        $children = @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)
    } catch { return }

    $hasSkills = $false
    foreach ($child in $children) {
        $name = $child.Name
        if ($name.StartsWith('.') -and $dir -ne $HOME -and $dir -ne (Join-Path $HOME '.config')) { continue }
        if ($name -in $excludeDirs) { continue }
        # exclude the hub itself to avoid circular discovery
        if ($child.FullName.StartsWith((Get-HubRoot))) { continue }
        # the central store / trash are owned by the hub, never skills
        if (Test-HubOwned $child.FullName) { continue }
        # junctions/symlinks point elsewhere: never treat the host dir as a skill root
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if (Test-Path -LiteralPath (Join-Path $child.FullName 'SKILL.md')) {
            $hasSkills = $true
        }
    }

    if ($hasSkills) {
        # A dir is a *sync target* only if it looks like a real agent skill dir
        # (dot-dir under HOME/.config, or explicitly configured). Documents-like
        # folders are discovery-only to avoid polluting user folders with links.
        $owner = Get-OwnerName $dir
        $isLive = Test-AgentLive $owner
        $isTarget = $false
        $leaf = Split-Path $dir -Leaf
        # central store: single physical source, never a sync target, never rebased
        if ($dir -eq $storeDir -or $dir.StartsWith($storeDir + [IO.Path]::DirectorySeparatorChar)) {
            $owner = 'hub-store'
            $isTarget = $false
            $isLive = $true
        } else {
            if ($leaf -in @('skills','skill','plugin-skills','skillhub-skills')) { $isTarget = $true }
            elseif ($dir -like (Join-Path $HOME '.config','*')) { $isTarget = $true }
            elseif ($dir -like (Join-Path $HOME '.*')) { $isTarget = $true }
            # stale dirs (no real owning software) are NOT sync targets
            if (-not $isLive) { $isTarget = $false }
            if ($local.forceLinkRoots -and $dir -in @($local.forceLinkRoots)) { $isTarget = $true }
        }
        $skillRoots[$dir] = @{ rootDir = $dir; ownerHint = $owner; isLive = $isLive; isTarget = $isTarget }
        # do not recurse deeper into a skill root (skills are flat)
        return
    }

    # Empty-but-agent-typical dirs (dot-dir named skills/skill under HOME) are
    # still valid sync targets: they exist, are agent skill dirs, just empty.
    # forceLinkRoots always win (user explicitly asked).
    $leaf = Split-Path $dir -Leaf
    if (($local.forceLinkRoots -and $dir -in @($local.forceLinkRoots)) -or
        ($leaf -in @('skills','skill','plugin-skills') -and $dir -like (Join-Path $HOME '.*'))) {
        $owner = Get-OwnerName $dir
        $isLive = Test-AgentLive $owner
        $isTarget = $isLive -or ($local.forceLinkRoots -and $dir -in @($local.forceLinkRoots))
        if ($isTarget) {
            $skillRoots[$dir] = @{ rootDir = $dir; ownerHint = $owner; isLive = $isLive; isTarget = $true }
            return
        }
    }

    foreach ($child in $children) {
        $name = $child.Name
        if ($name.StartsWith('.') -and $dir -ne $HOME -and $dir -ne (Join-Path $HOME '.config')) { continue }
        if ($name -in $excludeDirs) { continue }
        if ($child.FullName.StartsWith((Get-HubRoot))) { continue }
        if (Test-HubOwned $child.FullName) { continue }
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        Walk-Scan $child.FullName ($depth + 1)
    }
}

Write-Host "扫描起点:" -ForegroundColor Yellow
foreach ($r in @($candidateRoots | Select-Object -Unique)) {
    Write-Host ("  {0}" -f $r)
}

foreach ($c in @($candidateRoots | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $c) {
        Walk-Scan $c 0
    }
}

# ownerHint: best-effort inference from path, display-only
foreach ($k in $skillRoots.Keys) {
    $skillRoots[$k].ownerHint = Get-OwnerName $k
}

# ---------- collect skills per discovered skill root ----------
$nameCounts = @{}
foreach ($k in $skillRoots.Keys) {
    foreach ($child in @(Get-ChildItem -LiteralPath $k -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($child.Name.StartsWith('.')) { continue }
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if (Test-Path -LiteralPath (Join-Path $child.FullName 'SKILL.md')) {
            $allFound += @{ name = $child.Name; rootDir = $k; owner = $skillRoots[$k].ownerHint; isTarget = $skillRoots[$k].isTarget; dir = $child.FullName }
        }
    }
}
foreach ($f in $allFound) { $nameCounts[$f.name] = ($nameCounts[$f.name] ?? 0) + 1 }
$nameRoots = @{}
foreach ($f in $allFound) { $nameRoots[$f.name] = @($nameRoots[$f.name]) + $f.owner }

# ---------- activity signals ----------
$usageRecords = Get-UsageRecords
$skillHubLog   = Get-SkillHubUsageLog
$recentInstall = Get-RecentInstallDates

function Get-LastUsedDays([string]$name, [long]$usedAt) {
    if ($usedAt -le 0) { return -1 }
    $dt = [DateTimeOffset]::FromUnixTimeMilliseconds($usedAt).DateTime
    return [Math]::Max(0, [int]((Get-Date).Subtract($dt).TotalDays))
}

$inManifestNames = @{}
foreach ($r in $usageRecords) { if ($r.skillName) { $inManifestNames[$r.skillName] = $true } }
foreach ($r in $skillHubLog) { if ($r.skillName) { $inManifestNames[$r.skillName] = $true } }

# ---------- build skill records (all candidates kept; evaluate resolves conflicts) ----------
$skills = @()
foreach ($f in $allFound) {
    $name = $f.name

    $content = Read-SkillText (Join-Path $f.dir 'SKILL.md')
    if (-not $content) { $content = '' }
    $fm = Parse-Frontmatter $content
    $body = $content
    if ($content -match '(?s)^---\r?\n.*?\r?\n---\r?\n') {
        $body = $content -replace '(?s)^---\r?\n.*?\r?\n---\r?\n', ''
    }
    $bodyChars = $body.Length
    $validFm = (-not [string]::IsNullOrWhiteSpace($fm.name)) -and (-not [string]::IsNullOrWhiteSpace($fm.description))

    $lastWrite = $null
    try { $lastWrite = (Get-Item -LiteralPath $f.dir -Force).LastWriteTime } catch { }
    $recentDays = -1
    if ($lastWrite) { $recentDays = [Math]::Max(0, [int]((Get-Date).Subtract($lastWrite).TotalDays)) }

    $act = @{
        usageCount      = 0
        lastUsedDays    = -1
        installedDays   = $recentInstall[$name]
    }
    foreach ($r in @($usageRecords) + @($skillHubLog)) {
        if ($r.skillName -ne $name) { continue }
        $act.usageCount++
        if ($r.usedAt -gt 0) {
            $d = Get-LastUsedDays $name $r.usedAt
            if ($d -ge 0 -and ($act.lastUsedDays -lt 0 -or $d -lt $act.lastUsedDays)) { $act.lastUsedDays = $d }
        }
    }

    $skill = [ordered]@{
        name           = $name
        sourceDir      = $f.dir
        skillMd        = (Join-Path $f.dir 'SKILL.md')
        rootDir        = $f.rootDir
        isTarget       = $f.isTarget -eq $true
        ownerHint      = $f.owner
        agents         = @($nameRoots[$name] | Select-Object -Unique)
        crossAgentCount= $nameCounts[$name]
        frontmatter    = @{ name = $fm.name; description = $fm.description; license = $fm.license }
        activity       = [ordered]@{
            usageCount    = $act.usageCount
            lastUsedDays  = $act.lastUsedDays
            installedDays = $act.installedDays
            fileRecentDays= $recentDays
            usedRecently  = ($act.lastUsedDays -ge 0 -and $act.lastUsedDays -le 30)
            installedRecently = ($act.installedDays -ge 0 -and $act.installedDays -le 30)
            fileRecent    = ($recentDays -ge 0 -and $recentDays -le 30)
        }
        signals        = [ordered]@{
            hasValidFrontmatter = $validFm
            descHasTrigger      = (Test-DescTrigger $fm.description)
            bodyChars           = $bodyChars
            hasStructure        = (Test-Structure $body)
            hasSupportFiles     = (Test-HasSupportFiles $f.dir)
            hasTodo             = (Test-HasTodo $body)
            crossAgentCount     = $nameCounts[$name]
            recentDays          = $recentDays
            usedRecently        = $skill.activity.usedRecently
            installedRecently  = $skill.activity.installedRecently
            updatedRecently    = ($recentDays -ge 0 -and $recentDays -le 30)
            usageCount          = $act.usageCount
            inManifest          = $inManifestNames[$name] -eq $true
        }
    }
    $port = Test-SkillPortable $f.dir $fm $body
    $skill.portable = $port.portable
    $skill.portableReason = $port.reason
    $score = Get-SkillScore $skill
    $skill.completenessScore = $score.completeness
    $skill.usageScore        = $score.usage
    $skill.totalScore        = $score.total
    $skills += $skill
}

# ---------- snapshot diff ----------
$prev = Read-JsonFile (Get-PrevIndexPath) $null
$newSinceLast = @()
if ($prev -and $prev.skills) {
    $prevNames = @{}
    foreach ($p in $prev.skills) { $prevNames[$p.name] = $true }
    foreach ($s in $skills) {
        if (-not $prevNames[$s.name]) { $newSinceLast += $s.name }
    }
} elseif ($RefreshIndex) {
    foreach ($s in $skills) { $newSinceLast += $s.name }
}

$index = [ordered]@{
    generatedAt    = (Get-Date).ToString('o')
    scanRoots      = @($skillRoots.Keys | Select-Object -Unique)
    skillRoots     = @($skillRoots.Values)
    skills         = $skills
    newSinceLast   = $newSinceLast
}

$idxPath = Get-IndexPath
$index | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $idxPath -Encoding UTF8
Copy-Item -LiteralPath $idxPath -Destination (Get-PrevIndexPath) -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("发现技能根目录: {0}" -f $skillRoots.Count) -ForegroundColor Green
Write-Host ("发现技能: {0}" -f $skills.Count) -ForegroundColor Green
Write-Host ("新技能: {0}" -f ($newSinceLast -join ', ')) -ForegroundColor Yellow
Write-Host ("索引已写入: {0}" -f $idxPath) -ForegroundColor Green