# common.ps1 - shared helpers for universal-skill-hub
# Load with: . "$PSScriptRoot\common.ps1"

$ErrorActionPreference = 'Stop'
$env:PSModulePath = $env:PSModulePath # no-op guard

# ---------- Paths ----------
function Resolve-HomePath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $p }
    if ($p.StartsWith('~')) {
        $p = Join-Path $HOME $p.Substring(2)
    }
    return $p
}

function Get-HubRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-IndexPath {
    if ($env:HUB_INDEX) { return $env:HUB_INDEX }
    return (Join-Path (Get-HubRoot) 'skillhub-index.json')
}

function Get-PrevIndexPath {
    if ($env:HUB_INDEX) { return "$env:HUB_INDEX.prev" }
    return (Join-Path (Get-HubRoot) 'skillhub-index.prev.json')
}

function Get-LinksManifestPath {
    if ($env:HUB_MANIFEST) { return $env:HUB_MANIFEST }
    return (Join-Path (Get-HubRoot) 'skillhub-links.json')
}

function Get-EvalPath {
    if ($env:HUB_EVAL) { return $env:HUB_EVAL }
    return (Join-Path (Get-HubRoot) 'skillhub-eval.json')
}

# Central store: the single physical home of every aggregated skill.
# All agent skill dirs hold junctions pointing here. Overridable via
# $env:HUB_STORE (tests) or config.storeDir (default ~/.skillhub/skills).
function Get-StoreDir {
    if ($env:HUB_STORE) { return $env:HUB_STORE }
    $cfgAll = Get-Config
    if ($cfgAll.local -and $cfgAll.local.storeDir) { return Resolve-HomePath $cfgAll.local.storeDir }
    if ($cfgAll.base -and $cfgAll.base.storeDir) { return Resolve-HomePath $cfgAll.base.storeDir }
    return (Join-Path $HOME '.skillhub\skills')
}

function Get-StoreTrashDir {
    $cfgAll = Get-Config
    if ($cfgAll.local -and $cfgAll.local.deleteTrashDir) { return Resolve-HomePath $cfgAll.local.deleteTrashDir }
    if ($cfgAll.base -and $cfgAll.base.deleteTrashDir) { return Resolve-HomePath $cfgAll.base.deleteTrashDir }
    return (Join-Path $HOME '.skillhub\trash')
}

function Get-ConfigPath {
    return (Join-Path $PSScriptRoot 'skillhub.config.json')
}

function Get-LocalConfigPath {
    if ($env:HUB_LOCAL) { return $env:HUB_LOCAL }
    return (Join-Path $PSScriptRoot 'skillhub.local.json')
}

# ---------- Config / JSON ----------
function Read-JsonFile([string]$path, $fallback) {
    if (Test-Path -LiteralPath $path) {
        try {
            return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Warning "无法解析 $path : $($_.Exception.Message)"
        }
    }
    return $fallback
}

# Public config: generic logic only. Local config: personal overrides (optional).
function Get-Config {
    $cfg = Read-JsonFile (Get-ConfigPath) @{}
    $local = Read-JsonFile (Get-LocalConfigPath) @{}
    return @{ base = $cfg; local = $local }
}

function Get-Index {
    return Read-JsonFile (Get-IndexPath) $null
}

# ---------- Targeted discovery (no full disk walk) ----------
# Locate a single skill by name for `sync -Name X` / `new` / `uninstall`.
# Checks, in order: central store -> existing index sourceDir -> shallow scan
# of known skill roots (signal source parents + $HOME dot-dirs). Early-exit.
function Find-SkillByName([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }

    # 1. central store
    $store = Join-Path (Get-StoreDir) $name
    if (Test-Path -LiteralPath (Join-Path $store 'SKILL.md')) {
        return @{ name = $name; sourceDir = $store; source = 'store' }
    }

    # 2. existing index
    $idx = Get-Index
    if ($idx -and $idx.skills) {
        $m = @($idx.skills | Where-Object { $_.name -eq $name })
        if ($m -and $m[0].sourceDir -and (Test-Path -LiteralPath (Join-Path $m[0].sourceDir 'SKILL.md'))) {
            return @{ name = $name; sourceDir = $m[0].sourceDir; source = 'index' }
        }
    }

    # 3. shallow probe of likely skill roots (no recursion)
    $roots = @()
    foreach ($s in @(Get-SignalSourcePaths 'usage') + @(Get-SignalSourcePaths 'install')) {
        $s = Resolve-HomePath $s
        $parent = Split-Path $s -Parent
        if (Test-Path -LiteralPath $parent) { $roots += $parent }
    }
    $cfgAll = Get-Config
    foreach ($r in @($cfgAll.local.forceLinkRoots) + @($cfgAll.local.extraScanRoots)) {
        if ($r -and (Test-Path -LiteralPath $r)) { $roots += [string]$r }
    }
    if (Test-Path -LiteralPath (Join-Path $HOME '.config')) {
        foreach ($d in @(Get-ChildItem (Join-Path $HOME '.config') -Directory -Force -ErrorAction SilentlyContinue)) {
            foreach ($sub in @('skills','skill','plugin-skills')) {
                $p = Join-Path $d.FullName $sub
                if (Test-Path -LiteralPath $p) { $roots += $p }
            }
        }
    }
    foreach ($root in @($roots | Select-Object -Unique)) {
        $cand = Join-Path $root $name
        if (Test-Path -LiteralPath (Join-Path $cand 'SKILL.md')) {
            return @{ name = $name; sourceDir = $cand; source = 'shallow' }
        }
    }

    return $null
}

# Build a full scanned-style skill record for a single directory (used by
# `sync -Name X` / `new` when no full index exists for that skill).
function Get-TargetedSkillRecord([string]$sourceDir) {
    $name = Split-Path $sourceDir -Leaf
    $content = Read-SkillText (Join-Path $sourceDir 'SKILL.md')
    if (-not $content) { $content = '' }
    $fm = Parse-Frontmatter $content
    $body = $content
    if ($content -match '(?s)^---\r?\n.*?\r?\n---\r?\n') {
        $body = $content -replace '(?s)^---\r?\n.*?\r?\n---\r?\n', ''
    }
    $validFm = (-not [string]::IsNullOrWhiteSpace($fm.name)) -and (-not [string]::IsNullOrWhiteSpace($fm.description))

    $usage = 0
    $lastUsed = -1
    foreach ($r in Get-UsageRecords) {
        if ($r.skillName -ne $name) { continue }
        $usage++
        if ($r.usedAt -gt 0) {
            $d = [Math]::Max(0, [int]((Get-Date).Subtract([DateTimeOffset]::FromUnixTimeMilliseconds($r.usedAt).DateTime).TotalDays))
            if ($lastUsed -lt 0 -or $d -lt $lastUsed) { $lastUsed = $d }
        }
    }
    $port = Test-SkillPortable $sourceDir $fm $body

    $skill = [ordered]@{
        name         = $name
        sourceDir    = $sourceDir
        skillMd      = (Join-Path $sourceDir 'SKILL.md')
        rootDir      = (Split-Path $sourceDir -Parent)
        ownerHint    = (Get-OwnerName (Split-Path $sourceDir -Parent))
        agents       = @()
        crossAgentCount = 1
        frontmatter  = @{ name = $fm.name; description = $fm.description; license = $fm.license; portable = $fm.portable; runtime = $fm.runtime }
        activity     = [ordered]@{
            usageCount = $usage; lastUsedDays = $lastUsed; installedDays = -1
            fileRecentDays = -1; usedRecently = ($lastUsed -ge 0 -and $lastUsed -le 30)
            installedRecently = $false; fileRecent = $false
        }
        signals      = [ordered]@{
            hasValidFrontmatter = $validFm
            descHasTrigger = (Test-DescTrigger $fm.description)
            bodyChars = $body.Length
            hasStructure = (Test-Structure $body)
            hasSupportFiles = (Test-HasSupportFiles $sourceDir)
            hasTodo = (Test-HasTodo $body)
            crossAgentCount = 1
            recentDays = -1
            usedRecently = ($lastUsed -ge 0 -and $lastUsed -le 30)
            installedRecently = $false
            updatedRecently = $false
            usageCount = $usage
            inManifest = $false
        }
        portable     = $port.portable
        portableReason = $port.reason
    }
    $score = Get-SkillScore $skill
    $skill.completenessScore = $score.completeness
    $skill.usageScore        = $score.usage
    $skill.totalScore        = $score.total
    return $skill
}

# ---------- Frontmatter ----------
# Reads a text file, auto-detecting UTF-8 vs legacy (GB18030) encoding.
# Windows machines commonly have older Chinese skill files saved as GBK;
# forcing UTF-8 read corrupts them. Detect by strict UTF-8 validation.
function Read-SkillText([string]$path) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
    } catch { return '' }
    # strip UTF-8 BOM if present
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    # strict UTF-8 validation: if valid UTF-8, use it; else fall back to GB18030
    try {
        $strict = [System.Text.UTF8Encoding]::new($false, $true)
        return $strict.GetString($bytes)
    } catch {
        try {
            $gb = [System.Text.Encoding]::GetEncoding('GB18030')
            return $gb.GetString($bytes)
        } catch {
            return [System.Text.Encoding]::UTF8.GetString($bytes)
        }
    }
}

# Returns hashtable { name, description, license, portable, runtime, version, metadata } parsed from YAML frontmatter block.
function Parse-Frontmatter([string]$content) {
    $result = @{ name = $null; description = $null; license = $null; portable = $null; runtime = $null; version = $null; metadata = @{} }
    $lines = $content -split "`r?`n"
    if ($lines.Count -lt 2) { return $result }
    if ($lines[0].Trim() -ne '---') { return $result }
    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) { return $result }
    for ($i = 1; $i -lt $end; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Trim().StartsWith('#')) { continue }
        $idx = $line.IndexOf(':')
        if ($idx -lt 0) { continue }
        $key = $line.Substring(0, $idx).Trim().ToLower()
        $val = $line.Substring($idx + 1).Trim()
        $val = $val.TrimStart('"').TrimEnd('"')
        $val = $val.TrimStart("'").TrimEnd("'")
        if ($key -in @('name','description','license','portable','runtime','version')) {
            # portable is a YAML boolean; keep raw string, Test-SkillPortable normalizes
            $result[$key] = $val
        } elseif ($key -eq 'metadata' -and $val) {
            # metadata: key: value lines follow; capture loosely
            $j = $i + 1
            while ($j -lt $end -and $lines[$j].Trim().StartsWith(' ') -and $lines[$j].Trim() -notmatch '^\S+:') {
                $sub = $lines[$j]
                $sidx = $sub.IndexOf(':')
                if ($sidx -gt 0) {
                    $sk = $sub.Substring(0, $sidx).Trim()
                    $sv = $sub.Substring($sidx + 1).Trim().Trim('"').Trim("'")
                    if ($sk) { $result.metadata[$sk] = $sv }
                }
                $j++
            }
        }
    }
    return $result
}

# ---------- Signals ----------
function Test-DescTrigger([string]$desc) {
    $kw = @('use','when','for','tool','skill','脚本','用于','当需要','技能','生成','创建','管理','文档','pdf','docx','xlsx','email','邮件','chart','图','视频','audio','音频')
    $low = $desc.ToLower()
    foreach ($k in $kw) {
        if ($low.Contains($k.ToLower())) { return $true }
    }
    return $false
}

function Test-Structure([string]$body) {
    if ($body -match '(?m)^#{1,6}\s') { return $true }
    if ($body -match '(?m)^\s*[-*]\s') { return $true }
    if ($body -match '(?m)^\s*\d+[\.\)]\s') { return $true }
    return $false
}

function Test-HasTodo([string]$body) {
    if ($body -match '(?i)\bTODO\b|待完善|占位|placeholder|coming soon|未完成|示例：|\.\.\.') { return $true }
    return $false
}

function Test-HasSupportFiles([string]$dir) {
    foreach ($sub in @('scripts','references','assets','resources','templates')) {
        if (Test-Path -LiteralPath (Join-Path $dir $sub)) { return $true }
    }
    return $false
}

# ---------- Activity harvesting ----------
# Collect usage/recency signals already present in the environment so that
# even a brand-new user (no skill-hub history) gets meaningful activity scores.
# Harvesters never throw: a missing signal source simply contributes nothing.
# Signal source paths come from config (skillhub.config.json -> signalSources),
# so any agent ecosystem can supply them; local config (skillhub.local.json) may
# override with machine-specific paths and takes precedence.

function Get-SignalSourcePaths([string]$kind) {
    # kind: 'usage' | 'install' -> array of file paths (config overridable)
    $cfgAll = Get-Config
    $src = $cfgAll.base.signalSources
    if ($cfgAll.local -and $cfgAll.local.signalSources) { $src = $cfgAll.local.signalSources }
    if (-not $src) { $src = @{} }
    $list = @($src.$kind)
    if ($list.Count -eq 0) { return @() }
    $out = @()
    foreach ($p in $list) { $out += Resolve-HomePath $p }
    return @($out | Select-Object -Unique)
}

function Get-UsageRecords {
    # Merge records from any *usage*.json files under $HOME dot-dirs.
    $records = @()   # list of @{ skillName; usedAt }
    $seen = @{}
    foreach ($p in (Get-SignalSourcePaths 'usage')) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.records) {
                foreach ($r in @($j.records)) {
                    $n = $r.skillName
                    if (-not $n) { continue }
                    if (-not $seen[$n] -or $r.usedAt -gt $seen[$n]) { $seen[$n] = $r.usedAt }
                }
            }
            if ($j.skills) {
                foreach ($k in $j.skills.PSObject.Properties) {
                    $n = $k.Name
                    $v = $k.Value
                    $at = $null
                    if ($v.installed_at) { $at = $v.installed_at }
                    elseif ($v.installedAt) { $at = $v.installedAt }
                    elseif ($v.updatedAt) { $at = $v.updatedAt }
                    if ($n -and $at) { $seen[$n] = $at }
                }
            }
        } catch { }
    }
    foreach ($n in $seen.Keys) {
        $ts = $seen[$n]
        if ($ts -is [datetime]) {
            $records += @{ skillName = $n; usedAt = [DateTimeOffset]::new($ts).ToUnixTimeMilliseconds() }
        } elseif ($ts -is [string]) {
            try { $dt = [datetime]::Parse($ts) } catch { $dt = [datetime]::MinValue }
            $records += @{ skillName = $n; usedAt = [DateTimeOffset]::new($dt).ToUnixTimeMilliseconds() }
        } elseif ($ts -is [long] -or $ts -is [int] -or $ts -is [int64]) {
            $records += @{ skillName = $n; usedAt = [long]$ts }
        } else {
            $records += @{ skillName = $n; usedAt = 0 }
        }
    }
    return $records
}

# skillhub's own usage log (grows over time; merged into activity score).
function Get-SkillHubUsageLog {
    $p = Join-Path (Get-HubRoot) 'skillhub-usage.json'
    $j = Read-JsonFile $p @{ records = @() }
    return @($j.records)
}

function Get-ActivitySignal([string]$skillName) {
    # Returns a hashtable of activity signals for one skill:
    #   usedRecently / installedRecently / updatedRecently / crossAgentCount / inManifest
    $now = Get-Date
    $signals = @{
        usedRecently      = $false
        installedRecently = $false
        updatedRecently   = $false
        usageCount        = 0
        lastUsedDays      = -1
        installedDays     = -1
        updatedDays       = -1
    }

    foreach ($r in Get-UsageRecords) {
        if ($r.skillName -ne $skillName) { continue }
        $signals.usageCount++
        if ($r.usedAt -gt 0) {
            $dt = [DateTimeOffset]::FromUnixTimeMilliseconds($r.usedAt).DateTime
            $days = [Math]::Max(0, [int]($now.Subtract($dt).TotalDays))
            if ($signals.lastUsedDays -lt 0 -or $days -lt $signals.lastUsedDays) {
                $signals.lastUsedDays = $days
            }
        }
    }
    $signals.usedRecently = ($signals.lastUsedDays -ge 0 -and $signals.lastUsedDays -le 30)

    $meta = Get-RecentInstallDates
    if ($meta.ContainsKey($skillName)) {
        $signals.installedDays = $meta[$skillName]
        $signals.installedRecently = ($meta[$skillName] -ge 0 -and $meta[$skillName] -le 30)
    }
    return $signals
}

function Get-RecentInstallDates {
    # Map skillName -> days since last install/update (from agent lock/metadata files).
    $out = @{}
    foreach ($p in (Get-SignalSourcePaths 'install')) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $j.skills) { continue }
            foreach ($k in $j.skills.PSObject.Properties) {
                $v = $k.Value
                $ts = $null
                if ($v.installed_at) { $ts = $v.installed_at }
                elseif ($v.installedAt) { $ts = $v.installedAt }
                elseif ($v.updatedAt) { $ts = $v.updatedAt }
                if (-not $ts) { continue }
                try { $dt = [datetime]::Parse([string]$ts) } catch { continue }
                $days = [Math]::Max(0, [int]((Get-Date).Subtract($dt).TotalDays))
                if (-not $out.ContainsKey($k.Name) -or $days -lt $out[$k.Name]) { $out[$k.Name] = $days }
            }
        } catch { }
    }
    return $out
}

# ---------- Live agent detection ----------
# Distinguish REAL installed AI software from leftover/stale skill dirs.
# A skill root is a live target only if its owning software has strong
# existence evidence: running process / command on PATH / install dirs.
function Get-OwnerName([string]$rootDir) {
    $hint = Split-Path $rootDir -Leaf
    if ($hint -in @('skills','skill','plugin-skills','skillhub-skills')) {
        $parent = Split-Path (Split-Path $rootDir -Parent) -Leaf
        if ($parent) { $hint = $parent }
    }
    return $hint
}

function Test-AgentLive([string]$owner) {
    if ([string]::IsNullOrWhiteSpace($owner)) { return $false }
    # normalize: '.<agent>' -> '<agent>'
    $base = $owner.TrimStart('.')
    if ([string]::IsNullOrWhiteSpace($base)) { return $false }
    $pat = '(?i)' + [regex]::Escape($base)

    # 1. running process (strongest evidence)
    try {
        if (@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $pat }).Count -gt 0) { return $true }
    } catch { }

    # 2. command resolvable on PATH
    try {
        if (Get-Command $base -ErrorAction SilentlyContinue) { return $true }
    } catch { }

    # 3. real install dirs only (NOT $HOME - owner's own dot-dir would self-match)
    foreach ($baseDir in @(
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path $HOME '.local'),
        (Join-Path $HOME 'node_modules\.bin'),
        (Join-Path $HOME 'AppData\Local\Programs')
    )) {
        if (-not $baseDir -or -not (Test-Path -LiteralPath $baseDir)) { continue }
        try {
            foreach ($c in @(Get-ChildItem -LiteralPath $baseDir -Force -ErrorAction SilentlyContinue)) {
                if ($c.Name -match $pat) { return $true }
            }
        } catch { }
    }

    # 4. owner home has a main config that points at a real install (nodeBinary/exe)
    #    e.g. <agent>.json -> cli.nodeBinary = D:\SoftWare\ai\<agent>\... (weak but useful)
    $homeDir = Join-Path $HOME ".$base"
    if (Test-Path -LiteralPath $homeDir) {
        $cfg = Get-ChildItem -LiteralPath $homeDir -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "^(\.?$base|config)\.(json|jsonc|yaml|yml|toml)$" } |
            Select-Object -First 1
        if ($cfg) {
            try {
                $raw = Get-Content -LiteralPath $cfg.FullName -Raw -ErrorAction SilentlyContinue
                if ($raw -match '(?i)(nodeBinary|binaryPath|executablePath|node_modules[\\.]\w+|\.exe"|\.mjs")') {
                    # config references a real engine file -> live
                    $m = [regex]::Match($raw, '(?i)"(nodeBinary|binaryPath|executablePath)"\s*:\s*"([^"]+)"')
                    if ($m.Success -and (Test-Path -LiteralPath $m.Groups[2].Value)) { return $true }
                    if ($raw -match '(?i)' + [regex]::Escape($base) + '\.mjs' -and (Test-Path -LiteralPath $homeDir)) { return $true }
                }
            } catch { }
        }
    }
    return $false
}

# ---------- Link method probe (AI environment detection) ----------
# Decides junction vs symlink vs copy without any user configuration.

function Test-FilesystemSupportsJunction([string]$dir) {
    # NTFS supports directory junctions. Try creating one in a temp sibling.
    if (-not $IsWindows) { return $false }
    $fs = (Get-Item -LiteralPath $dir -Force).PSDrive
    return $fs.Name -ne ''  # junction works on NTFS/ReFS; detection via attempt is authoritative below
}

function Get-LinkMethod([string]$targetDir) {
    # Probe decision chain: junction -> symlink -> copy. Result is cached in index.
    $index = Get-Index
    if ($index -and $index.linkMethods -and $index.linkMethods.$targetDir) {
        return $index.linkMethods.$targetDir
    }
    $method = 'copy'
    $probeBase = Join-Path (Get-HubRoot) '.probe'
    New-Item -ItemType Directory -Path $probeBase -Force | Out-Null
    $probeName = "probe-$([guid]::NewGuid().ToString('N'))"
    $probeSrc = Join-Path $probeBase $probeName
    New-Item -ItemType Directory -Path $probeSrc -Force | Out-Null

    try {
        if ($IsWindows) {
            # junction: does NOT require admin. Prefer it.
            $probeLink = Join-Path (Split-Path $targetDir) "$probeName-junction"
            try {
                New-Item -ItemType Junction -Path $probeLink -Target $probeSrc -Force | Out-Null
                Remove-Item -LiteralPath $probeLink -Force -ErrorAction SilentlyContinue
                $method = 'junction'
            } catch {
                # fall back to symbolic link (may need developer mode); then copy
                $method = 'copy'
            }
        } else {
            $probeLink = Join-Path (Split-Path $targetDir) "$probeName-symlink"
            try {
                New-Item -ItemType SymbolicLink -Path $probeLink -Target $probeSrc -Force | Out-Null
                Remove-Item -LiteralPath $probeLink -Force -ErrorAction SilentlyContinue
                $method = 'symlink'
            } catch {
                $method = 'copy'
            }
        }
    } finally {
        Remove-Item -LiteralPath $probeSrc -Force -ErrorAction SilentlyContinue
    }

    if ($index) {
        if (-not $index.linkMethods) { $index | Add-Member -NotePropertyName 'linkMethods' -NotePropertyValue @{} -Force }
        $index.linkMethods | Add-Member -NotePropertyName $targetDir -NotePropertyValue $method -Force
        $index | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Get-IndexPath) -Encoding UTF8
    }
    return $method
}

function New-SkillLink([string]$sourceDir, [string]$linkPath, [string]$method) {
    if (Test-Path -LiteralPath $linkPath) {
        $item = Get-Item -LiteralPath $linkPath -Force
        if ($item.LinkType -in @('Junction','SymbolicLink')) {
            if ($item.Target -eq $sourceDir) { return $false }  # already linked, skip
            Remove-Item -LiteralPath $linkPath -Force
        } else {
            throw "目标已有真实目录，拒绝覆盖: $linkPath"
        }
    }
    if ($method -eq 'copy') {
        Copy-Item -LiteralPath $sourceDir -Destination $linkPath -Recurse -Force
    } else {
        New-Item -ItemType $method -Path $linkPath -Target $sourceDir -Force | Out-Null
    }
    return $true
}

# ---------- Portability (cross-platform, agent-bound detection) ----------
# A skill is "portable" if it can run in a DIFFERENT AI harness than the one it
# was authored in. The point is to isolate skills that are BOUND to a specific
# AI environment (its dot-dir, runtime, engine binary) — those would error in
# any other agent and have no sync value.
#
# Platform neutrality is structural, not a name list:
#   * agent dot-dirs are detected DYNAMICALLY: any ~/.<name> that structurally
#     looks like an AI agent dir (contains skills/skill/plugin-skills) OR is not
#     a known generic tool dir is treated as agent-bound.
#   * generic tool/config dirs (~/.config, ~/.local, ~/.cache, ~/.mcporter,
#     ~/.ssh, ~/.npm, ~/.tencent ...) are portable — they run on any machine
#     with that tool installed.
#   * no product names are hardcoded anywhere.
# frontmatter may override: `portable: true|false`, `runtime:` (bound to one env).
# Returns hashtable { portable, reason }.

# Generic user-level tool/config dirs that are NOT agent-specific. A skill that
# reads ~/.config or ~/.local works in any harness on the same machine.
$script:GenericDotDirs = @(
    'config','local','cache','ssh','aws','npm','nvm','gradle','m2','maven',
    'docker','kube','kubectl','git','gitconfig','vim','vimrc','bashrc',
    'bash_profile','zshrc','profile','gnupg','bundle','pki','pyenv','rvm',
    'sdkman','cargo','rustup','go','oh-my-zsh','tmux','npmrc','vscode',
    'code-server','node_modules','snap','mcporter','tencent','tme','xiaomei',
    'cliguard','agents','ai','cursor'
)

# Return the set of names that look like AI-agent dot-dirs under $HOME
# (structural: a dot-dir containing skills/skill/plugin-skills subdirs).
function Get-AgentDotDirNames {
    $out = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($d in @(Get-ChildItem -LiteralPath $HOME -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith('.') } | Sort-Object { $_.Name })) {
        foreach ($sub in @('skills','skill','plugin-skills','.config')) {
            $p = Join-Path $d.FullName $sub
            if ($sub -eq '.config') {
                if (Test-Path -LiteralPath (Join-Path $p 'skills')) {
                    $name = $d.Name.TrimStart('.')
                    if ($name) { [void]$out.Add($name) }
                }
            } elseif (Test-Path -LiteralPath $p) {
                $name = $d.Name.TrimStart('.')
                if ($name) { [void]$out.Add($name) }
            }
        }
    }
    return $out
}

function Test-SkillPortable([string]$skillDir, $frontmatter, [string]$body) {
    $reason = @()
    $portable = $true

    # 1. frontmatter explicit override wins
    $fmPort = $frontmatter.portable
    if ($null -ne $fmPort -and "$fmPort" -ne '') {
        $pf = "$fmPort".ToLower()
        if ($pf -in @('true','yes','1')) { return @{ portable = $true; reason = 'frontmatter portable: true' } }
        if ($pf -in @('false','no','0')) { return @{ portable = $false; reason = 'frontmatter portable: false' } }
    }
    if ($frontmatter.runtime) {
        return @{ portable = $false; reason = ("frontmatter runtime 绑定: {0}" -f $frontmatter.runtime) }
    }

    # 2. collect all text content under the skill dir (SKILL.md + scripts/references)
    $texts = @()
    if ($body) { $texts += $body }
    if (Test-Path -LiteralPath $skillDir) {
        $files = @(Get-ChildItem -LiteralPath $skillDir -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.(ps1|py|js|ts|sh|bat|cmd|json|yaml|yml|toml|md|rb|lua|m|mjs|cjs|go|rs)$' } |
            Sort-Object { $_.FullName })
        foreach ($f in $files | Select-Object -First 30) {
            try { $texts += (Read-SkillText $f.FullName) } catch { }
        }
    }
    $joined = $texts -join "`n"

    # 3. agent-specific dot-dirs: ~/.<agent>/... or $HOME/.<agent>/...
    #    PRIMARY binding signal, fully structural: we only flag a dot-dir if it
    #    LOOKS like an AI agent directory on THIS machine (it contains a
    #    skills/skill/plugin-skills subdir). Generic tool dirs (~/.config,
    #    ~/.local, ~/.mcporter, ...) are never agents and stay portable.
    $agentNames = @(Get-AgentDotDirNames | Where-Object { $_ -notin $script:GenericDotDirs })
    $isAgentBound = $false
    if ($agentNames.Count -gt 0) {
        $agentRe = '(?m)~\$?[\\/]\.(' + (($agentNames | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')[\\/]'
        foreach ($mm in [regex]::Matches($joined, $agentRe)) {
            $isAgentBound = $true
            $reason += ("引用特定 AI 软件用户目录 ~/.{0}/，离开原环境不可用" -f $mm.Groups[1].Value)
        }
        $homeRe = '(?m)(\$HOME|%USERPROFILE%)[\\/]\.(' + (($agentNames | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')[\\/]'
        foreach ($mm in [regex]::Matches($joined, $homeRe)) {
            $isAgentBound = $true
            $reason += ("引用特定 AI 软件用户目录 `$HOME/.{0}/，离开原环境不可用" -f $mm.Groups[2].Value)
        }
    }
    if ($isAgentBound) { $portable = $false }

    # 4. hardcoded engine binaries of a specific harness
    if ($joined -match '(?i)(nodeBinary|binaryPath|executablePath)\s*[:=]\s*["''][^"'']+\.(exe|mjs)["'']') {
        $portable = $false
        $reason += "硬编码某软件引擎二进制路径"
    }
    # an absolute path directly into another agent install dir: a dot-dir that
    # holds an .mjs engine (agent harnesses run from .mjs entrypoints). The
    # dot-dir name itself is not needed — structure alone is the signal.
    if ($joined -match '(?i)[\\/]\.\w+[\\/][^"''\s]*\.mjs["'']') {
        $portable = $false
        $reason += "引用其它 AI 软件安装目录中的引擎/脚本"
    }

    # 5. unambiguous foreign USER-HOME paths (authored for another OS).
    #    Only real user-home dirs are flagged; placeholder tokens (`xxx`,
    #    `<name>`, `<user>`, `$user`, `username`) are documentation examples.
    $placeholderTok = '(?i)^(xxx|<name>|<user>|\$user|username)$'
    if ($IsWindows) {
        $flagForeign = $false
        foreach ($mm in [regex]::Matches($joined, '(?m)(^|[\s"''=\(])(/home/([^/\s<]+)/|/Users/([^/\s<]+)/|/root/)')) {
            $u = if ($mm.Groups[3].Value) { $mm.Groups[3].Value } else { $mm.Groups[4].Value }
            if ($u -and $u -match $placeholderTok) { continue }
            $flagForeign = $true
            break
        }
        if ($flagForeign) {
            $portable = $false
            $reason += "包含 Unix/macOS 用户主目录路径（Windows 上不可运行）"
        }
    } else {
        $flagForeign = $false
        foreach ($mm in [regex]::Matches($joined, '(?m)(^|[\s"''=\(])([A-Za-z]:[\\/]Users[\\/]([^\\/\s<]+)|%USERPROFILE%[\\/])')) {
            $u = $mm.Groups[3].Value
            if ($u -and $u -match $placeholderTok) { continue }
            $flagForeign = $true
            break
        }
        if ($flagForeign) {
            $portable = $false
            $reason += "包含 Windows 用户主目录路径（Unix 上不可运行）"
        }
    }

    return @{ portable = $portable; reason = ((($reason | Select-Object -Unique) | Sort-Object) -join '; ') }
}

function Test-SkillPortableFromIndex($skill) {
    # Convenience wrapper over a scanned skill record (PSCustomObject or hashtable).
    if ($null -ne $skill.portable) { return @{ portable = [bool]$skill.portable; reason = [string]$skill.portableReason } }
    $fm = @{}
    if ($skill.frontmatter) { $fm = @{ portable = $skill.frontmatter.portable; runtime = $skill.frontmatter.runtime } }
    return Test-SkillPortable $skill.sourceDir $fm ''
}

# ---------- Scoring ----------
# Returns hashtable { completeness, usage, total }
function Get-SkillScore($skill) {
    $s = $skill.signals
    $c = 0
    if ($s.hasValidFrontmatter) { $c += 15 }
    $descWords = if ($skill.frontmatter.description) { ($skill.frontmatter.description -split '\s+').Count } else { 0 }
    if ($descWords -ge 10 -and $s.descHasTrigger) { $c += 10 }
    $bc = $s.bodyChars
    if ($bc -ge 200) { $c += 10 }
    if ($bc -ge 500) { $c += 10 }
    if ($s.hasStructure) { $c += 5 }
    if ($s.hasSupportFiles) { $c += 5 }
    if (-not $s.hasTodo) { $c += 5 }
    $c = [Math]::Min($c, 60)

    $u = 0
    if ($s.crossAgentCount -ge 2) { $u += 10 }
    if ($s.usedRecently) { $u += 15 }
    if ($s.installedRecently) { $u += 10 }
    if ($s.updatedRecently) { $u += 5 }
    if ($s.usageCount -ge 1) { $u += 5 }
    if ($s.inManifest) { $u += 5 }
    $u = [Math]::Min($u, 40)

    return @{ completeness = $c; usage = $u; total = $c + $u }
}

# ---------- Output ----------
function Write-Section([string]$title) {
    Write-Host ""
    Write-Host ("==== " + $title + " ====") -ForegroundColor Cyan
}

# ---------- Git exclude protection ----------
# Prevents personal config and runtime artifacts from being committed.
# Uses .git/info/exclude (repository-local, never committed) instead of a
# .gitignore file, so no extra tracked file is needed.
# Runs once on dot-source; silent if not in a git repo or already protected.
function Protect-LocalFiles {
    if ($env:HUB_NO_REBASE -eq '1') { return }
    $hubRoot = Get-HubRoot
    $gitDir = & git -C $hubRoot rev-parse --git-dir 2>$null
    if (-not $gitDir -or $LASTEXITCODE -ne 0) { return }
    $excludePath = (Resolve-Path (Join-Path $hubRoot $gitDir) -ErrorAction SilentlyContinue)
    if (-not $excludePath) { return }
    $excludeFile = Join-Path $excludePath.Path 'info'
    if (-not (Test-Path -LiteralPath $excludeFile)) { New-Item -ItemType Directory -Path $excludeFile -Force | Out-Null }
    $excludeFile = Join-Path $excludeFile 'exclude'
    $patterns = @(
        'scripts/skillhub.local.json'
        'skillhub-index.json'
        'skillhub-index.prev.json'
        'skillhub-eval.json'
        'skillhub-links.json'
    )
    $existing = ''
    if (Test-Path -LiteralPath $excludeFile) {
        $existing = Get-Content -LiteralPath $excludeFile -Raw -ErrorAction SilentlyContinue
    }
    $missing = @($patterns | Where-Object { $existing -notlike "*$_*" })
    if ($missing.Count -eq 0) { return }
    $marker = '# universal-skill-hub local files'
    if ($existing -notlike "*$marker*") {
        Add-Content -LiteralPath $excludeFile -Value "`n$marker" -Encoding UTF8
    }
    foreach ($p in $missing) {
        Add-Content -LiteralPath $excludeFile -Value $p -Encoding UTF8
    }
}
Protect-LocalFiles