# skillhub.ps1 - single entry point for universal-skill-hub
# Usage:
#   pwsh skillhub.ps1 sync [-Full] [-Target <skill>]  # full first-time OR targeted sync
#   pwsh skillhub.ps1 new -Target <name> [-Desc <desc>]  # create skill in store, aggregate everywhere
#   pwsh skillhub.ps1 test -Target <name>            # read-only verify a skill across agents
#   pwsh skillhub.ps1 uninstall -Target <name>       # remove skill from all agents + store
#   pwsh skillhub.ps1 dry-run                        # show plan without making changes
#   pwsh skillhub.ps1 rollback                       # remove all created links
#   pwsh skillhub.ps1 list                           # list discovered skills
#   pwsh skillhub.ps1 link-to <dir>                  # aggregate into a specific target dir
#   pwsh skillhub.ps1 review                         # handle low-score skills

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('sync','dry-run','rollback','list','link-to','review','scan','evaluate','new','test','uninstall')]
    [string]$Command = 'sync',
    [Parameter(Position=1)][string]$Target = '',
    [string]$Desc = '',
    [switch]$AutoIgnore,
    [switch]$WhatIf,
    [switch]$Full
)

. (Join-Path $PSScriptRoot 'scripts\common.ps1')

$scripts = Join-Path $PSScriptRoot 'scripts'
$hubRoot = Get-HubRoot

# ---------- targeted sync for a single named skill (no full disk walk) ----------
function Invoke-TargetedSync([string]$skillName, [switch]$PlanOnly) {
    $found = Find-SkillByName $skillName
    if (-not $found) {
        Write-Error "未定位到技能: $skillName（可先全量 sync 建立索引，或确认路径）"
        exit 1
    }
    # ensure the skill is in the index so link/evaluate can see it
    $idx = Get-Index
    $already = $false
    if ($idx -and $idx.skills) { $already = @($idx.skills | Where-Object { $_.name -eq $skillName }).Count -gt 0 }
    if (-not $already) {
        $rec = Get-TargetedSkillRecord $found.sourceDir
        if (-not $idx) { $idx = [ordered]@{ generatedAt = (Get-Date).ToString('o'); scanRoots = @(); skillRoots = @(); skills = @(); newSinceLast = @() } }
        $skillsList = @($idx.skills) + @($rec)
        $idx.skills = $skillsList
        $idx | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Get-IndexPath) -Encoding UTF8
        Write-Host "  定向发现: $skillName @ $($found.sourceDir) ($($found.source))" -ForegroundColor Green
    }
    Write-Section "evaluate (single)"
    & pwsh -NoProfile -File (Join-Path $scripts 'evaluate-skills.ps1') -Name $skillName
    Write-Section "link (single)"
    if ($PlanOnly) {
        & pwsh -NoProfile -File (Join-Path $scripts 'link-skills.ps1') -Name $skillName -WhatIf
    } else {
        & pwsh -NoProfile -File (Join-Path $scripts 'link-skills.ps1') -Name $skillName
    }
}

switch ($Command) {
    'scan' {
        & pwsh -NoProfile -File (Join-Path $scripts 'scan-skills.ps1') -RefreshIndex
    }
    'evaluate' {
        & pwsh -NoProfile -File (Join-Path $scripts 'evaluate-skills.ps1')
    }
    'sync' {
        if ($Target) {
            Invoke-TargetedSync $Target
        } elseif (-not $Full) {
            # default: targeted mode — no full re-scan (token/time saving)
            Write-Host "定向模式：新技能请用「sync -Target <技能名>」或「new -Target <技能名>」。" -ForegroundColor Yellow
            Write-Host "需要全量重扫请用「sync -Full」。" -ForegroundColor Yellow
        } else {
            Write-Section "scan"
            & pwsh -NoProfile -File (Join-Path $scripts 'scan-skills.ps1') -RefreshIndex
            Write-Section "evaluate"
            & pwsh -NoProfile -File (Join-Path $scripts 'evaluate-skills.ps1')
            Write-Section "link"
            & pwsh -NoProfile -File (Join-Path $scripts 'link-skills.ps1')
        }
    }
    'dry-run' {
        Write-Section "scan"
        & pwsh -NoProfile -File (Join-Path $scripts 'scan-skills.ps1') -RefreshIndex
        Write-Section "evaluate"
        & pwsh -NoProfile -File (Join-Path $scripts 'evaluate-skills.ps1')
        Write-Section "link (plan only)"
        & pwsh -NoProfile -File (Join-Path $scripts 'link-skills.ps1') -WhatIf
    }
    'rollback' {
        & pwsh -NoProfile -File (Join-Path $scripts 'unlink-skills.ps1') -All
    }
    'list' {
        & pwsh -NoProfile -File (Join-Path $scripts 'load-skill.ps1') -List
    }
    'link-to' {
        if (-not $Target) {
            Write-Error "用法: skillhub.ps1 link-to <目标技能根目录>"
            exit 1
        }
        & pwsh -NoProfile -File (Join-Path $scripts 'link-skills.ps1') -Agents $Target
    }
    'review' {
        if ($AutoIgnore) {
            & pwsh -NoProfile -File (Join-Path $scripts 'review-skills.ps1') -AutoIgnore $(if ($WhatIf) { '-WhatIf' } else { '' })
        } elseif ($WhatIf) {
            & pwsh -NoProfile -File (Join-Path $scripts 'review-skills.ps1') -WhatIf
        } else {
            & pwsh -NoProfile -File (Join-Path $scripts 'review-skills.ps1')
        }
    }
    'new' {
        if (-not $Target) {
            Write-Error "用法: skillhub.ps1 new -Target <技能名> [-Desc <描述>]"
            exit 1
        }
        $storeDir = Get-StoreDir
        $storePath = Join-Path $storeDir $Target
        if (Test-Path -LiteralPath (Join-Path $storePath 'SKILL.md')) {
            Write-Host "技能已存在: $Target（若需重建请先 uninstall）" -ForegroundColor Yellow
            exit 1
        }
        New-Item -ItemType Directory -Path $storePath -Force | Out-Null
        $desc = if ($Desc) { $Desc } else { "通用技能 $Target。用于 $Target 相关任务。" }
        $template = @"
---
name: $Target
description: $desc
version: 0.1.0
license: MIT
compatibility: Windows / macOS / Linux
metadata:
  trigger: $Target
---

# $Target

## Usage

如何使用本技能完成任务。

## Requirements

- PowerShell 7+ (pwsh) 或对应运行时
"@
        Set-Content -LiteralPath (Join-Path $storePath 'SKILL.md') -Value $template -Encoding UTF8
        Write-Host "已在仓库创建技能: $storePath" -ForegroundColor Green
        # skip scoring: add to local forceInclude, then aggregate everywhere
        $localCfg = Read-JsonFile (Get-LocalConfigPath) @{}
        $fi = @($localCfg.forceInclude | Where-Object { $_ })
        if ($Target -notin $fi) {
            $fi += $Target
            $localCfg | Add-Member -NotePropertyName 'forceInclude' -NotePropertyValue $fi -Force
            $localCfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Get-LocalConfigPath) -Encoding UTF8
        }
        Write-Section "聚合新技能"
        Invoke-TargetedSync $Target
    }
    'test' {
        if (-not $Target) {
            Write-Error "用法: skillhub.ps1 test -Target <技能名>"
            exit 1
        }
        $idx = Get-Index
        $rec = $null
        if ($idx -and $idx.skills) { $rec = @($idx.skills | Where-Object { $_.name -eq $Target }) | Select-Object -First 1 }
        if (-not $rec) {
            $found = Find-SkillByName $Target
            if (-not $found) { Write-Error "未定位到技能: $Target"; exit 1 }
            $rec = Get-TargetedSkillRecord $found.sourceDir
        }
        $port = Test-SkillPortableFromIndex $rec
        Write-Section ("test: {0}" -f $Target)
        Write-Host ("  评分: {0} (完整 {1} + 活性 {2})" -f $rec.totalScore, $rec.completenessScore, $rec.usageScore) -ForegroundColor Cyan
        Write-Host ("  可移植: {0}" -f $(if ($port.portable) { '是' } else { "否 ($($port.reason))" })) -ForegroundColor $(if ($port.portable) { 'Green' } else { 'Red' })
        Write-Host ("  来源: {0}" -f $rec.sourceDir)
        $manifest = Read-JsonFile (Get-LinksManifestPath) @{ links = @() }
        $mine = @($manifest.links | Where-Object { $_.name -eq $Target })
        Write-Host ("  已聚合到 {0} 个 agent:" -f $mine.Count)
        foreach ($l in $mine) {
            $ok = Test-Path -LiteralPath $l.link
            $it = Get-Item -LiteralPath $l.link -Force -ErrorAction SilentlyContinue
            $status = if (-not $ok) { '悬空!' } elseif ($it -and $it.LinkType) { 'OK(junction)' } else { '真实目录?' }
            Write-Host ("    {0,-60} [{1}]" -f $l.link, $status) -ForegroundColor $(if ($ok) { 'DarkGray' } else { 'Red' })
        }
        if ($mine.Count -eq 0) { Write-Host "    未聚合。运行 sync -Target $Target 或 new 立即聚合。" -ForegroundColor Yellow }
    }
    'uninstall' {
        if (-not $Target) {
            Write-Error "用法: skillhub.ps1 uninstall -Target <技能名>"
            exit 1
        }
        Write-Section "卸载技能 (全软件移除)"
        & pwsh -NoProfile -File (Join-Path $scripts 'unlink-skills.ps1') -Name $Target -Uninstall
        # drop from local forceInclude if present
        $localCfg = Read-JsonFile (Get-LocalConfigPath) @{}
        if (@($localCfg.forceInclude | Where-Object { $_ }) -contains $Target) {
            $localCfg.forceInclude = @($localCfg.forceInclude | Where-Object { $_ -and $_ -ne $Target })
            $localCfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Get-LocalConfigPath) -Encoding UTF8
        }
    }
}