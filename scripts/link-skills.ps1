# link-skills.ps1 - aggregate passing skills into discovered skill root dirs
# Central-store model: the store (~/.skillhub/skills) holds the single physical
# copy of every aggregated skill; every agent skill dir holds a junction to it.
# Flow per skill: import (copy source -> store) -> rebase (source dir becomes a
# junction to store) -> aggregate (junction store -> every target root).
# Dangling junctions (source deleted / agent uninstalled) are removed & rebuilt.
# Usage: pwsh link-skills.ps1 [-Agents <rootDirs>] [-Name <skill>] [-WhatIf]

[CmdletBinding()]
param(
    [string]$Agents = '',
    [string]$Name = '',
    [switch]$WhatIf
)

. "$PSScriptRoot\common.ps1"

$cfgAll = Get-Config
$config = $cfgAll.base
$local  = $cfgAll.local

$index = Get-Index
$eval = Read-JsonFile (Get-EvalPath) $null
if (-not $index -or -not $index.skills) {
    Write-Error "索引为空，请先运行 scan-skills.ps1"
    exit 1
}
if (-not $eval) {
    Write-Error "无评估报告，请先运行 evaluate-skills.ps1"
    exit 1
}

$storeDir = Get-StoreDir
$trashDir = Get-StoreTrashDir
$threshold = if ($config.scoreThreshold) { [int]$config.scoreThreshold } else { 60 }
if ($local.scoreThreshold) { $threshold = [int]$local.scoreThreshold }

# local decisions override which skills sync (personal taste, optional)
$decisions = @{}
if ($local.decisions) {
    foreach ($p in $local.decisions.PSObject.Properties) { $decisions[$p.Name] = $p.Value }
}

# ------- determine which skills to link -------
$selected = @()
if ($Name) {
    $match = @($index.skills | Where-Object { $_.name -eq $Name })
    if (-not $match) { Write-Error "未找到技能: $Name"; exit 1 }
    $selected = $match
} else {
    foreach ($s in @($eval.passing)) {
        $d = $decisions.$($s.name)
        if ($d -in @('ignore','deleted','skip')) { continue }
        $selected += $s
    }
}

# never link the hub itself into a circular location
$selected = @($selected | Where-Object { $_.name -ne 'universal-skill-hub' -and -not $_.sourceDir.StartsWith((Get-HubRoot)) })
if ($selected.Count -eq 0) {
    Write-Host "没有需要聚合的技能。" -ForegroundColor Yellow
    exit 0
}

# ------- resolve targets: all discovered skill root dirs (structural) -------
# Exclude: the hub's own root, the central store, any source dir. Dedupe.
# When -Agents is given, ONLY those explicit targets are used (explicit wins).
# Safety: when the store is overridden (HUB_STORE set, i.e. sandbox/test mode),
# auto-discovery must NEVER link real agent dirs — only targets under the
# sandbox root qualify. Real-world runs (no override) keep full auto-discovery.
$hubRoot = (Get-HubRoot)
$sandboxRoot = if ($env:HUB_STORE) { Split-Path $env:HUB_STORE -Parent } else { $null }
$targetRoots = @{}
if (-not $Agents) {
    if ($index.skillRoots) {
        foreach ($r in @($index.skillRoots)) {
            $dir = $r.rootDir
            if (-not $dir) { continue }
            if ($r.isTarget -eq $false) { continue }
            if ($r.ownerHint -eq 'hub-store' -or $dir.StartsWith($storeDir + [IO.Path]::DirectorySeparatorChar) -or $dir -eq $storeDir) { continue }
            $dir = (Resolve-Path -LiteralPath $dir -ErrorAction SilentlyContinue).Path
            if (-not $dir) { continue }
            if ($dir.StartsWith($hubRoot)) { continue }
            if ($sandboxRoot -and -not ($dir -eq $sandboxRoot -or $dir.StartsWith($sandboxRoot + [IO.Path]::DirectorySeparatorChar))) { continue }
            $targetRoots[$dir] = $r.ownerHint
        }
    }
}
# user-specified explicit targets (optional; overrides auto-discovery)
if ($Agents) {
    foreach ($a in ($Agents -split ',')) {
        $a = $a.Trim()
        if (-not $a) { continue }
        $p = Resolve-HomePath $a
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Warning "目标目录不存在: $p"
            continue
        }
        if (-not (Test-Path -LiteralPath $p -PathType Container)) {
            Write-Warning "目标不是目录，跳过: $p"
            continue
        }
        $targetRoots[(Resolve-Path -LiteralPath $p).Path] = 'manual'
    }
}

if ($targetRoots.Count -eq 0) {
    Write-Host "未发现任何技能根目录（请先 scan）。" -ForegroundColor Yellow
    exit 0
}

$linksCreated = @()
$conflictsReport = @()

# ---- 0. sweep dangling junctions in every target root ----
# Junctions that point into the central store but whose store target no longer
# exists are stale (store copy was cleaned/removed). They are NOT indexed skill
# names (e.g. timestamp-suffixed junk dirs), so the per-skill loop never sees
# them — sweep structurally here so no bad rings survive a re-link.
$swept = 0
foreach ($targetRoot in $targetRoots.Keys) {
    foreach ($entry in @(Get-ChildItem -LiteralPath $targetRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($entry.LinkType -notin @('Junction','SymbolicLink')) { continue }
        $t = $entry.Target
        if (-not $t) { continue }
        $resolvedT = $t
        if ($t -is [string] -and -not [IO.Path]::IsPathRooted($t)) {
            $resolvedT = Join-Path $targetRoot $t
        }
        $isStoreJunction = ($resolvedT -eq $storeDir -or $resolvedT.StartsWith($storeDir + [IO.Path]::DirectorySeparatorChar))
        if (-not $isStoreJunction) { continue }
        if (-not (Test-Path -LiteralPath $resolvedT)) {
            Write-Host "  清理失效链接: $($entry.FullName) -> 仓库目标已删除" -ForegroundColor DarkYellow
            if (-not $WhatIf) { Remove-Item -LiteralPath $entry.FullName -Force; $swept++ }
        }
    }
}
if ($swept -gt 0) { Write-Host "  共清理 $swept 个失效链接" -ForegroundColor DarkYellow }

foreach ($s in $selected) {
    $name = $s.name

    # ---- 1. ensure the central store holds the physical copy ----
    $storePath = Join-Path $storeDir $name
    $src = $s.sourceDir
    $isStoreSource = ($src -eq $storePath -or $src.StartsWith($storeDir + [IO.Path]::DirectorySeparatorChar))

    if (-not $isStoreSource) {
        # import: copy source -> store (single physical copy lives here)
        if (-not (Test-Path -LiteralPath (Join-Path $storePath 'SKILL.md'))) {
            if (-not (Test-Path -LiteralPath $src)) {
                Write-Warning "源目录不存在，跳过: $name ($src)"
                continue
            }
            if ($WhatIf) {
                Write-Host "  (WhatIf) 将导入仓库: $name -> $storePath" -ForegroundColor DarkGray
            } else {
                New-Item -ItemType Directory -Path $storeDir -Force | Out-Null
                try {
                    Copy-Item -LiteralPath $src -Destination $storePath -Recurse -Force
                    Write-Host "  已导入仓库: $name -> $storePath" -ForegroundColor Green
                } catch {
                    Write-Host "  导入失败: $name : $($_.Exception.Message)" -ForegroundColor Red
                    continue
                }
            }
        }
        # rebase: original agent dir becomes a junction to the store copy
        # (trash-safe: the physical original goes to trash, never deleted)
        # $env:HUB_NO_REBASE=1 disables source-dir mutation (test isolation).
        # The central store is the core rule: EVERY skill source is rebased to
        # the store (single physical copy), including dirs of uninstalled
        # software. Non-live dirs are just never used as sync TARGETS (they are
        # not written to during aggregation) — their skills are still read as
        # sources and rebased into the store.
        if (-not $WhatIf -and $env:HUB_NO_REBASE -ne '1' -and (Test-Path -LiteralPath $src) -and -not $src.StartsWith($storeDir)) {
            $item = Get-Item -LiteralPath $src -Force
            if ($item.LinkType -in @('Junction','SymbolicLink')) {
                if ($item.Target -ne $storePath) {
                    Remove-Item -LiteralPath $src -Force
                    New-Item -ItemType Junction -Path $src -Target $storePath -Force | Out-Null
                    Write-Host "  rebase(重定向): $name -> $storePath" -ForegroundColor Green
                }
            } else {
                $trash = Join-Path $trashDir (($name) + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                New-Item -ItemType Directory -Path $trashDir -Force | Out-Null
                Move-Item -LiteralPath $src -Destination $trash -Force
                New-Item -ItemType Junction -Path $src -Target $storePath -Force | Out-Null
                Write-Host "  rebase: $name 原目录 -> 回收站, 原位 junction -> 仓库" -ForegroundColor DarkGreen
            }
        }
    }

    # ---- 2. aggregate: junction store -> every target root ----
    foreach ($targetRoot in $targetRoots.Keys) {
        $linkPath = Join-Path $targetRoot $name

        # skip if store source physically lives inside this target root
        if ($storePath.StartsWith($targetRoot + [IO.Path]::DirectorySeparatorChar) -or $storePath -eq $targetRoot) { continue }

        $linkItem = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
        if ($linkItem) {
            if ($linkItem.LinkType -in @('Junction','SymbolicLink')) {
                if ($linkItem.Target -eq $storePath) {
                    Write-Host "  已链接，跳过: $name" -ForegroundColor DarkGray
                    continue
                }
                # dangling or stale junction: remove & rebuild (kills bad rings)
                Write-Host "  清理悬空/旧链接并重建: $name" -ForegroundColor DarkYellow
                if (-not $WhatIf) { Remove-Item -LiteralPath $linkPath -Force }
            } else {
                $conflictsReport += "$targetRoot/$name - 目标已有真实目录，跳过"
                Write-Host "  冲突（真实目录已存在，跳过）: $targetRoot/$name" -ForegroundColor Magenta
                continue
            }
        }

        # environment probe picks junction/symlink/copy automatically
        $method = Get-LinkMethod $targetRoot
        if ($WhatIf) {
            Write-Host "  (WhatIf) 将链接: $name -> $targetRoot [$method]" -ForegroundColor DarkGray
            continue
        }

        try {
            $created = New-SkillLink $storePath $linkPath $method
        } catch {
            Write-Host "  失败: $name : $($_.Exception.Message)" -ForegroundColor Red
            continue
        }
        if ($created) {
            $linksCreated += @{ name = $name; agent = $targetRoot; link = $linkPath; source = $storePath; method = $method }
            Write-Host "  已聚合: $name -> $targetRoot [$method]" -ForegroundColor Green
        }
    }
}

# ------- persist links manifest -------
$manifest = Read-JsonFile (Get-LinksManifestPath) @{ links = @() }
$old = @($manifest.links)
# self-heal: drop ghost records whose link path no longer exists (target dir
# was removed by the user/OS). Keeps manifest truthful across rollbacks.
$kept = @()
$pruned = 0
foreach ($l in $old) {
    if (-not $l.link) { continue }
    if (Test-Path -LiteralPath $l.link) { $kept += $l } else { $pruned++ }
}
if ($pruned -gt 0 -and -not $WhatIf) {
    Write-Host "  已清理 $pruned 条失效链接记录（目标目录已删除）" -ForegroundColor DarkYellow
}
if ($linksCreated.Count -gt 0 -and -not $WhatIf) {
    # dedupe: skip entries whose link path already recorded
    $knownLinks = @{}
    foreach ($l in $kept) { if ($l.link) { $knownLinks[$l.link.ToLower()] = $true } }
    $newEntries = @($linksCreated | Where-Object { -not $knownLinks[$_.link.ToLower()] })
    @{ links = @($kept) + @($newEntries) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Get-LinksManifestPath) -Encoding UTF8
} elseif ($pruned -gt 0 -and -not $WhatIf) {
    @{ links = $kept } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Get-LinksManifestPath) -Encoding UTF8
}

Write-Host ""
Write-Host ("聚合完成: 链接 {0} | 冲突 {1}" -f $linksCreated.Count, $conflictsReport.Count) -ForegroundColor Cyan
if ($conflictsReport.Count -gt 0) {
    Write-Section "冲突明细"
    $conflictsReport | ForEach-Object { Write-Host "  $_" -ForegroundColor Magenta }
}