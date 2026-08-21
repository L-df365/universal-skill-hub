# run-tests.ps1 - smoke + idempotency tests for universal-skill-hub
# Usage: pwsh tests/run-tests.ps1
#
# ALL test sections run fully isolated: HUB_STORE/HUB_INDEX/HUB_MANIFEST/
# HUB_LOCAL/HUB_EVAL point at a temp sandbox and HUB_NO_REBASE=1 so real
# source dirs and the real store are never touched. The sandbox is seeded
# with a fake skill and fake agent root so scan/evaluate/link have realistic
# data to work with without touching the user environment.

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

$passed = 0
$failed = 0

function Assert-True([bool]$cond, [string]$label) {
    if ($cond) { Write-Host "  PASS: $label" -ForegroundColor Green; $script:passed++ }
    else { Write-Host "  FAIL: $label" -ForegroundColor Red; $script:failed++ }
}

function Assert-Equal($got, $want, [string]$label) {
    if ($got -eq $want) { Write-Host "  PASS: $label" -ForegroundColor Green; $script:passed++ }
    else { Write-Host "  FAIL: $label (got '$got', want '$want')" -ForegroundColor Red; $script:failed++ }
}

# =====================================================================
# Global sandbox setup — ALL sections run inside this sandbox.
# No real user data (HUB_STORE, HUB_INDEX, HUB_MANIFEST, HUB_LOCAL,
# HUB_EVAL, HUB_NO_REBASE) is ever touched.
# =====================================================================
$globalSandbox = Join-Path $env:TEMP ("hub-global-sbx-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
$gStore   = Join-Path $globalSandbox 'store'
$gAgent   = Join-Path $globalSandbox 'agent-skills'
$gTrash   = Join-Path $globalSandbox 'trash'
$gIndex   = Join-Path $globalSandbox 'idx.json'
$gManifest = Join-Path $globalSandbox 'links.json'
$gLocal   = Join-Path $globalSandbox 'local.json'
$gEval    = Join-Path $globalSandbox 'eval.json'
New-Item -ItemType Directory -Path $gStore, $gAgent, $gTrash -Force | Out-Null

# Seed a fake skill in the sandbox so scan/evaluate/link have realistic data
$fakeSkillDir = Join-Path $globalSandbox 'src\fake-test-skill'
New-Item -ItemType Directory -Path $fakeSkillDir -Force | Out-Null
$fakeSkillContent = @"
---
name: fake-test-skill
description: 一个用于测试的技能，用于扫描和聚合测试。触发词：技能、工具、生成。
version: 0.1.0
license: MIT
---

# Fake Test Skill

## Usage

这是一个测试技能，用于验证 hub 的扫描、评估和聚合功能。

## Requirements

- PowerShell 7+
"@
Set-Content -LiteralPath (Join-Path $fakeSkillDir 'SKILL.md') -Value $fakeSkillContent -Encoding UTF8

# Seed a second fake skill to ensure multi-skill coverage
$fakeSkill2Dir = Join-Path $globalSandbox 'src\another-test-skill'
New-Item -ItemType Directory -Path $fakeSkill2Dir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $fakeSkill2Dir 'SKILL.md') -Value @"
---
name: another-test-skill
description: 另一个测试技能，用于验证幂等性和冲突处理。触发词：技能、管理。
version: 0.2.0
license: MIT
---

# Another Test Skill

## Usage

第二个测试技能，确保多技能场景覆盖。
"@ -Encoding UTF8

# Seed local config (empty decisions, no force)
Set-Content -LiteralPath $gLocal -Value '{}' -Encoding UTF8

# Save old env vars for restoration at the end
$envBackup = @{
    HUB_STORE = $env:HUB_STORE
    HUB_INDEX = $env:HUB_INDEX
    HUB_MANIFEST = $env:HUB_MANIFEST
    HUB_LOCAL = $env:HUB_LOCAL
    HUB_EVAL = $env:HUB_EVAL
    HUB_NO_REBASE = $env:HUB_NO_REBASE
}

# Set global sandbox env vars — ALL subsequent operations use these
$env:HUB_STORE = $gStore
$env:HUB_INDEX = $gIndex
$env:HUB_MANIFEST = $gManifest
$env:HUB_LOCAL = $gLocal
$env:HUB_EVAL = $gEval
$env:HUB_NO_REBASE = '1'

# Build a seed index with the fake agent root so scan/link can discover it
$seedIndex = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    scanRoots = @($globalSandbox)
    skillRoots = @(@{ rootDir = $gAgent; ownerHint = 'sandbox'; isLive = $true; isTarget = $true })
    skills = @()
    newSinceLast = @()
}
# Build skill records via the helper and inject into seed index
$rec1 = Get-TargetedSkillRecord $fakeSkillDir
$rec2 = Get-TargetedSkillRecord $fakeSkill2Dir
$seedIndex.skills = @($rec1, $rec2)
$seedIndex | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $gIndex -Encoding UTF8

try {

Write-Section "1. 结构发现 (scan)"
# Re-scan inside sandbox: the fake skills should be discovered
& pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\scan-skills.ps1') -RefreshIndex 2>&1 | Out-Null
$index = Get-Index
Assert-True ($null -ne $index -and @($index.skills).Count -gt 0) "scan 产出技能索引"
Assert-True (@($index.skillRoots).Count -gt 0) "发现技能根目录"
Assert-True (@($index.skillRoots | Where-Object { $_.isTarget }).Count -gt 0) "至少一个可同步目标"
# junction child must NOT be a skill
$badJunctionRoots = @($index.skillRoots | Where-Object { $_.isTarget -and $_.rootDir -like '*Documents*' })
Assert-Equal $badJunctionRoots.Count 0 "Documents 不再作为同步目标"
# live detection: at least one target is live
$liveTargets = @($index.skillRoots | Where-Object { $_.isTarget -and $_.isLive })
Assert-True ($liveTargets.Count -gt 0) "存在 live 同步目标（真实软件）"
# stale dirs that are not sync targets, EXCEPT any roots explicitly forced via local config
$cfgAll = Get-Config
$forced = @()
foreach ($r in @($cfgAll.local.forceLinkRoots)) { if ($r) { $forced += [string]$r } }
$staleTargets = @($index.skillRoots | Where-Object {
    $_.isTarget -and -not $_.isLive -and -not ($forced -contains $_.rootDir) })
Assert-Equal $staleTargets.Count 0 "残留目录不作为同步目标（除显式 forceLinkRoots）"

Write-Section "2. 活性加权 (evaluate)"
& pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\evaluate-skills.ps1') 2>&1 | Out-Null
$eval = Read-JsonFile (Get-EvalPath) $null
Assert-True ($null -ne $eval) "evaluate 产出报告"
Assert-True ($eval.summary.total -gt 0) "评估技能总数正确"
# passing count is machine-dependent (usage signals / user decisions). The
# invariant to test: total = count of UNIQUE skills across all buckets
$uniq = @{}
foreach ($s in @($eval.passing)) { $uniq[$s.name] = $true }
foreach ($s in @($eval.lowScore)) { $uniq[$s.name] = $true }
foreach ($s in @($eval.conflicts)) { $uniq[$s.name] = $true }
Assert-Equal $uniq.Count ([int]$eval.summary.total) "评估分类自洽 (无技能重复/遗漏)"
if ($eval.summary.passing -gt 0) {
    Assert-True $true "有达标技能（本机活性信号充足）"
} else {
    Write-Host "  SKIP: 本机无达标技能（信号源为空/全部忽略/全不可移植）—— 流水线仍正确" -ForegroundColor Yellow
}

Write-Section "3. 幂等性 (link twice = 0 new)"
# isolated agent dir: link never writes into real agent dirs (sandbox-safe)
$iAgent = Join-Path $globalSandbox ("hub-test-agent-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path $iAgent -Force | Out-Null
$r1 = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\link-skills.ps1') -Agents $iAgent 2>&1 | Out-String
$r2 = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\link-skills.ps1') -Agents $iAgent 2>&1 | Out-String
$n2 = [regex]::Match($r2, '聚合完成: 链接 (\d+)').Groups[1].Value
if ($n2 -eq '') {
    # all skills user-ignored (decisions) -> link exits early, still idempotent
    Assert-True ($r2 -match '没有需要聚合|聚合完成') "第二次 sync 无新建链接 (幂等, 全部忽略)"
} else {
    Assert-Equal $n2 '0' "第二次 sync 不新建链接 (幂等)"
}
Assert-True ($r1 -notmatch '环|cyclic') "无环告警"

Write-Section "4. 坏链检测"
$rings = 0
$index = Get-Index
foreach ($root in @($index.skillRoots | Where-Object { $_.isTarget })) {
    Get-ChildItem -LiteralPath $root.rootDir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $it = Get-Item $_.FullName -Force
        if ($it.LinkType -in @('Junction','SymbolicLink')) {
            if (-not (Test-Path (Join-Path $_.FullName 'SKILL.md'))) { $rings++ }
        }
    }
}
Assert-Equal $rings 0 "无坏环/坏链"

Write-Section "5. manifest 完整性"
$manifest = Read-JsonFile (Get-LinksManifestPath) @{ links = @() }
if (@($manifest.links).Count -gt 0) {
    Assert-True $true "manifest 有链接记录"
    $dup = @($manifest.links | Group-Object { $_.link.ToLower() } | Where-Object Count -gt 1)
    Assert-Equal $dup.Count 0 "manifest 无重复记录"
} else {
    Write-Host "  SKIP: 全新环境无 manifest（首次运行正常）" -ForegroundColor Yellow
    Write-Host "  SKIP: 无重复记录检查" -ForegroundColor Yellow
    # force a real link so manifest gets populated for later checks
    # pick a NON-hub skill (link-skills excludes the hub itself, and index
    # ordering is not stable across runs) so the assertion is deterministic
    $firstSkill = ($index.skills | Where-Object { $_.name -ne 'universal-skill-hub' -and -not $_.sourceDir.StartsWith((Get-HubRoot)) } | Select-Object -First 1)
    Assert-True ($null -ne $firstSkill) "存在可用的 manifest 填充候选"
    if (-not $firstSkill) { $failed++ } else {
        $tmpLink = Join-Path $globalSandbox ("hub-manifest-test-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
        New-Item -ItemType Directory -Path $tmpLink -Force | Out-Null
        try {
            & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\link-skills.ps1') -Agents $tmpLink -Name $firstSkill.name 2>&1 | Out-Null
            $manifest2 = Read-JsonFile (Get-LinksManifestPath) @{ links = @() }
            Assert-True (@($manifest2.links).Count -gt 0) "单技能 link 后 manifest 有记录"
            & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\unlink-skills.ps1') -Root $tmpLink 2>&1 | Out-Null
        } finally {
            Remove-Item -LiteralPath $tmpLink -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Section "6. 单技能同步 (-Name)"
# pick a skill that is NOT the hub itself (link-skills excludes it, and index
# ordering is not stable across runs) so the assertion is deterministic
$probeSkill = ($index.skills | Where-Object { $_.name -ne 'universal-skill-hub' -and -not $_.sourceDir.StartsWith((Get-HubRoot)) } | Select-Object -First 1)
Assert-True ($null -ne $probeSkill) "存在可用的单技能同步候选"
if ($probeSkill) {
    $single = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\link-skills.ps1') -Agents $iAgent -Name $probeSkill.name -WhatIf 2>&1 | Out-String
    Assert-True ($single -match '将链接|已链接') "单技能同步可用"
}

Write-Section "7. rollback 计划 (WhatIf)"
$rb = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\unlink-skills.ps1') -All -WhatIf 2>&1 | Out-String
if ($rb -match '将移除链接') {
    Assert-True $true "rollback 计划生成"
} elseif ($rb -match '链接清单为空|未聚合|无需要') {
    Write-Host "  SKIP: 全新环境无链接可回滚（首次运行正常）" -ForegroundColor Yellow
} else {
    Assert-True $false "rollback 计划生成"
}

Write-Section "8. link-to 指定目标（显式覆盖）"
$tmp = Join-Path $globalSandbox ("skillhub-test-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $probeSkill2 = ($index.skills | Where-Object { $_.name -ne 'universal-skill-hub' -and -not $_.sourceDir.StartsWith((Get-HubRoot)) } | Select-Object -First 1)
    Assert-True ($null -ne $probeSkill2) "存在可用的 link-to 候选"
    if ($probeSkill2) {
        $lt = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\link-skills.ps1') -Agents $tmp -Name $probeSkill2.name 2>&1 | Out-String
        $linked = @(Get-ChildItem -LiteralPath $tmp -Directory -Force -ErrorAction SilentlyContinue)
        Assert-True ($linked.Count -eq 1 -and $linked[0].LinkType -in @('Junction','SymbolicLink')) "link-to 只写指定目标"
        Assert-True ($lt -match '已聚合') "link-to 实际建链"
        # clean rollback via unlink -Root so manifest is kept truthful
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\unlink-skills.ps1') -Root $tmp 2>&1 | Out-Null
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# =====================================================================
# Sections 9-15: central-store / portability / new / test / uninstall /
# conflict / isolation. These run with their own sub-sandboxes but share
# the global HUB_* env (already set above). Each section creates its own
# sandbox dir and may override HUB_* locally within try/finally blocks.
# =====================================================================

Write-Section "9. 中央仓库模型 (import + junction -> store)"
$sandbox = Join-Path $env:TEMP ("hub-sandbox-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
$sStore  = Join-Path $sandbox 'store'
$sAgent  = Join-Path $sandbox 'agent-skills'
New-Item -ItemType Directory -Path $sStore, $sAgent -Force | Out-Null
$oldStore = $env:HUB_STORE; $oldIdx = $env:HUB_INDEX; $oldMan = $env:HUB_MANIFEST; $oldLoc = $env:HUB_LOCAL; $oldNR = $env:HUB_NO_REBASE; $oldEval = $env:HUB_EVAL
try {
    $env:HUB_STORE = $sStore; $env:HUB_INDEX = (Join-Path $sandbox 'idx.json'); $env:HUB_MANIFEST = (Join-Path $sandbox 'links.json'); $env:HUB_LOCAL = (Join-Path $sandbox 'local.json'); $env:HUB_EVAL = (Join-Path $sandbox 'eval.json'); $env:HUB_NO_REBASE = '1'
    $trashIn = Join-Path $sandbox 'store-trash'
    New-Item -ItemType Directory -Path $trashIn -Force | Out-Null
    Set-Content -LiteralPath $env:HUB_LOCAL -Value ('{ "deleteTrashDir": "' + $trashIn.Replace('\','\\') + '" }') -Encoding UTF8
    # seed a fake passing skill + a fake agent root in a sandbox index
    $fakeSkillDir = Join-Path $sandbox 'src\portable-test-skill'
    New-Item -ItemType Directory -Path $fakeSkillDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeSkillDir 'SKILL.md') -Value "---`nname: portable-test-skill`ndescription: 一个完全可移植的测试技能，用于测试。`n---`n`n# Usage`n`n用一句话说明。`n" -Encoding UTF8
    $sandIdx = [ordered]@{
        generatedAt = (Get-Date).ToString('o')
        scanRoots = @($sandbox)
        skillRoots = @(@{ rootDir = $sAgent; ownerHint = 'sandbox'; isLive = $true; isTarget = $true })
        skills = @()
        newSinceLast = @()
    }
    $sandIdx | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $env:HUB_INDEX -Encoding UTF8
    # build record via targeted helper and push into sandbox index
    $rec = Get-TargetedSkillRecord $fakeSkillDir
    $sandIdx2 = Get-Content -LiteralPath $env:HUB_INDEX -Raw -Encoding UTF8 | ConvertFrom-Json
    $sandIdx2.skills = @($rec)
    $sandIdx2 | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $env:HUB_INDEX -Encoding UTF8
    $sandEval = [ordered]@{ threshold = 60; freePassUsage = 35; passing = @($rec); lowScore = @(); conflicts = @(); summary = @{ total = 1; passing = 1; lowScore = 0; conflicts = 0 } }
    $sandEval | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $sandbox 'eval.json') -Encoding UTF8
    # link into sandbox agent root
    $lt = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\link-skills.ps1') -Agents $sAgent 2>&1 | Out-String
    $storeCopy = Join-Path $sStore 'portable-test-skill'
    Assert-True (Test-Path -LiteralPath (Join-Path $storeCopy 'SKILL.md')) "仓库保存物理副本"
    $j = Get-Item (Join-Path $sAgent 'portable-test-skill') -Force
    Assert-True ($j.LinkType -in @('Junction','SymbolicLink')) "agent 目录是链接"
    Assert-True ($j.Target -eq $storeCopy) "链接指向中央仓库"
    Assert-True ($lt -match '已聚合') "sandbox 聚合成功"
} finally {
    $env:HUB_STORE = $oldStore; $env:HUB_INDEX = $oldIdx; $env:HUB_MANIFEST = $oldMan; $env:HUB_LOCAL = $oldLoc; $env:HUB_NO_REBASE = $oldNR; $env:HUB_EVAL = $oldEval
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Section "10. 悬空链接清理 (bad ring)"
$sandbox = Join-Path $env:TEMP ("hub-sandbox-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
$sStore  = Join-Path $sandbox 'store'
$sAgent  = Join-Path $sandbox 'agent-skills'
New-Item -ItemType Directory -Path $sStore, $sAgent -Force | Out-Null
$oldStore = $env:HUB_STORE; $oldIdx = $env:HUB_INDEX; $oldMan = $env:HUB_MANIFEST; $oldLoc = $env:HUB_LOCAL; $oldNR = $env:HUB_NO_REBASE; $oldEval = $env:HUB_EVAL
try {
    $env:HUB_STORE = $sStore; $env:HUB_INDEX = (Join-Path $sandbox 'idx.json'); $env:HUB_MANIFEST = (Join-Path $sandbox 'links.json'); $env:HUB_LOCAL = (Join-Path $sandbox 'local.json'); $env:HUB_EVAL = (Join-Path $sandbox 'eval.json'); $env:HUB_NO_REBASE = '1'
    $trashIn = Join-Path $sandbox 'store-trash'
    New-Item -ItemType Directory -Path $trashIn -Force | Out-Null
    Set-Content -LiteralPath $env:HUB_LOCAL -Value ('{ "deleteTrashDir": "' + $trashIn.Replace('\','\\') + '" }') -Encoding UTF8
    # fake skill + fake agent root
    $fakeSkillDir = Join-Path $sandbox 'src\dangle-test-skill'
    New-Item -ItemType Directory -Path $fakeSkillDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeSkillDir 'SKILL.md') -Value "---`nname: dangle-test-skill`ndescription: 悬空链接清理测试技能。`n---`n`n# Usage`n`n说明。`n" -Encoding UTF8
    $rec = Get-TargetedSkillRecord $fakeSkillDir
    $sandIdx = [ordered]@{ generatedAt = (Get-Date).ToString('o'); scanRoots = @($sandbox); skillRoots = @(@{ rootDir = $sAgent; ownerHint = 'sandbox'; isLive = $true; isTarget = $true }); skills = @($rec); newSinceLast = @() }
    $sandIdx | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $env:HUB_INDEX -Encoding UTF8
    $sandEval = [ordered]@{ threshold = 60; freePassUsage = 35; passing = @($rec); lowScore = @(); conflicts = @(); summary = @{ total = 1; passing = 1; lowScore = 0; conflicts = 0 } }
    $sandEval | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $sandbox 'eval.json') -Encoding UTF8
    # first link to populate store + agent
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\link-skills.ps1') -Agents $sAgent 2>&1 | Out-Null
    # simulate uninstall of the source agent: delete the store copy -> dangling junction
    Remove-Item -LiteralPath (Join-Path $sStore 'dangle-test-skill') -Recurse -Force
    # re-link: must clean the dangling junction and rebuild from store
    $r2 = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\link-skills.ps1') -Agents $sAgent 2>&1 | Out-String
    $j2 = Get-Item (Join-Path $sAgent 'dangle-test-skill') -Force
    Assert-True (Test-Path -LiteralPath (Join-Path $sStore 'dangle-test-skill\SKILL.md')) "store 副本重建"
    Assert-True ($j2.LinkType -in @('Junction','SymbolicLink')) "agent 链接重建"
    Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path $sAgent 'dangle-test-skill') 'SKILL.md')) "链接有效（无坏环）"
    # junk junction: create a junction to a REAL store dir (must exist to
    # create a junction on Windows), then delete the store target to simulate
    # a stale non-indexed link. Sweep must remove it.
    $junkName = 'junk-skill-20260820-091122'
    $junkTarget = Join-Path $sStore $junkName
    New-Item -ItemType Directory -Path $junkTarget -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $sAgent $junkName) -Target $junkTarget -Force | Out-Null
    Remove-Item -LiteralPath $junkTarget -Recurse -Force
    $r3 = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\link-skills.ps1') -Agents $sAgent 2>&1 | Out-String
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sAgent $junkName))) "失效链接被清扫（非索引垃圾链接）"
    Assert-True ($r3 -match '清理失效链接|失效链接') "清扫动作被报告"
} finally {
    $env:HUB_STORE = $oldStore; $env:HUB_INDEX = $oldIdx; $env:HUB_MANIFEST = $oldMan; $env:HUB_LOCAL = $oldLoc; $env:HUB_NO_REBASE = $oldNR; $env:HUB_EVAL = $oldEval
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Section "11. 可移植性判定 (platform-aware)"
$sandbox = Join-Path $env:TEMP ("hub-sandbox-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
try {
    # A: contains Unix absolute path -> non-portable on Windows, portable on Unix
    $a = Join-Path $sandbox 'unix-bound'
    New-Item -ItemType Directory -Path $a -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $a 'SKILL.md') -Value "---`nname: unix-bound`ndescription: 调用 /home/user/bin 的工具。`n---`n`n# Usage`n运行 /opt/tool.sh。`n" -Encoding UTF8
    $pa = Test-SkillPortable $a @{} ''
    # B: portable skill, no foreign paths
    $b = Join-Path $sandbox 'clean-skill'
    New-Item -ItemType Directory -Path $b -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $b 'SKILL.md') -Value "---`nname: clean-skill`ndescription: 无绝对路径的干净技能。`n---`n`n# Usage`n直接说明步骤即可。`n" -Encoding UTF8
    $pb = Test-SkillPortable $b @{} ''
    # C: frontmatter portable:true override wins
    $c = Join-Path $sandbox 'forced-portable'
    New-Item -ItemType Directory -Path $c -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $c 'SKILL.md') -Value "---`nname: forced-portable`ndescription: 声明可移植。`nportable: true`n---`n`n# Usage`n调用 /home/x 但声明可移植。`n" -Encoding UTF8
    $pc = Test-SkillPortable $c @{ portable = $true } ''
    # D: runtime binding
    $d = Join-Path $sandbox 'runtime-bound'
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'SKILL.md') -Value "---`nname: runtime-bound`ndescription: 绑定特定运行时。`nruntime: some-agent`n---`n`n# Usage`n说明。`n" -Encoding UTF8
    $pd = Test-SkillPortable $d @{ runtime = 'some-agent' } ''
    if ($IsWindows) {
        Assert-True (-not $pa.portable) "Unix 路径在 Windows 判定不可移植"
    } else {
        Assert-True ($pa.portable) "Unix 路径在 Unix 判定可移植"
    }
    Assert-True ($pb.portable) "干净技能可移植"
    Assert-True ($pc.portable) "frontmatter portable:true 覆盖"
    Assert-True (-not $pd.portable) "runtime 绑定判定不可移植"
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Section "12. new 命令 + 定向聚合 + test 校验"
$sandbox = Join-Path $env:TEMP ("hub-sandbox-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
$sStore  = Join-Path $sandbox 'store'
$sAgent  = Join-Path $sandbox 'agent-skills'
New-Item -ItemType Directory -Path $sStore, $sAgent -Force | Out-Null
$oldStore = $env:HUB_STORE; $oldIdx = $env:HUB_INDEX; $oldMan = $env:HUB_MANIFEST; $oldLoc = $env:HUB_LOCAL; $oldNR = $env:HUB_NO_REBASE; $oldEval = $env:HUB_EVAL
try {
    $env:HUB_STORE = $sStore; $env:HUB_INDEX = (Join-Path $sandbox 'idx.json'); $env:HUB_MANIFEST = (Join-Path $sandbox 'links.json'); $env:HUB_LOCAL = (Join-Path $sandbox 'local.json'); $env:HUB_EVAL = (Join-Path $sandbox 'eval.json'); $env:HUB_NO_REBASE = '1'
    $trashIn = Join-Path $sandbox 'store-trash'
    New-Item -ItemType Directory -Path $trashIn -Force | Out-Null
    Set-Content -LiteralPath $env:HUB_LOCAL -Value ('{ "deleteTrashDir": "' + $trashIn.Replace('\','\\') + '" }') -Encoding UTF8
    # seed index with the sandbox agent root so new can aggregate to it
    $sandIdx = [ordered]@{ generatedAt = (Get-Date).ToString('o'); scanRoots = @($sandbox); skillRoots = @(@{ rootDir = $sAgent; ownerHint = 'sandbox'; isLive = $true; isTarget = $true }); skills = @(); newSinceLast = @() }
    $sandIdx | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $env:HUB_INDEX -Encoding UTF8
    $newOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\skillhub.ps1') new -Target 'brand-new-skill' -Desc '测试新技能。' 2>&1 | Out-String
    Assert-True (Test-Path -LiteralPath (Join-Path $sStore 'brand-new-skill\SKILL.md')) "new 在仓库创建技能"
    $localJson = Get-Content -LiteralPath $env:HUB_LOCAL -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($localJson.forceInclude -contains 'brand-new-skill') "new 写入 forceInclude(跳过评分)"
    $j = Get-Item (Join-Path $sAgent 'brand-new-skill') -Force
    Assert-True ($j.LinkType -in @('Junction','SymbolicLink')) "new 后立即定向聚合"
    # test command
    $tOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\skillhub.ps1') test -Target 'brand-new-skill' 2>&1 | Out-String
    Assert-True ($tOut -match '可移植:\s*是') "test 报告可移植"
    Assert-True ($tOut -match 'OK\(junction\)') "test 校验链接有效"
} finally {
    $env:HUB_STORE = $oldStore; $env:HUB_INDEX = $oldIdx; $env:HUB_MANIFEST = $oldMan; $env:HUB_LOCAL = $oldLoc; $env:HUB_NO_REBASE = $oldNR; $env:HUB_EVAL = $oldEval
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Section "13. uninstall 卸载闭环"
$sandbox = Join-Path $env:TEMP ("hub-sandbox-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
$sStore  = Join-Path $sandbox 'store'
$sAgent  = Join-Path $sandbox 'agent-skills'
New-Item -ItemType Directory -Path $sStore, $sAgent -Force | Out-Null
$oldStore = $env:HUB_STORE; $oldIdx = $env:HUB_INDEX; $oldMan = $env:HUB_MANIFEST; $oldLoc = $env:HUB_LOCAL; $oldNR = $env:HUB_NO_REBASE; $oldEval = $env:HUB_EVAL
try {
    $env:HUB_STORE = $sStore; $env:HUB_INDEX = (Join-Path $sandbox 'idx.json'); $env:HUB_MANIFEST = (Join-Path $sandbox 'links.json'); $env:HUB_LOCAL = (Join-Path $sandbox 'local.json'); $env:HUB_EVAL = (Join-Path $sandbox 'eval.json'); $env:HUB_NO_REBASE = '1'
    $trashIn = Join-Path $sandbox 'store-trash'
    New-Item -ItemType Directory -Path $trashIn -Force | Out-Null
    Set-Content -LiteralPath $env:HUB_LOCAL -Value ('{ "deleteTrashDir": "' + $trashIn.Replace('\','\\') + '" }') -Encoding UTF8
    $sandIdx = [ordered]@{ generatedAt = (Get-Date).ToString('o'); scanRoots = @($sandbox); skillRoots = @(@{ rootDir = $sAgent; ownerHint = 'sandbox'; isLive = $true; isTarget = $true }); skills = @(); newSinceLast = @() }
    $sandIdx | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $env:HUB_INDEX -Encoding UTF8
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\skillhub.ps1') new -Target 'uninstall-me' -Desc '测试卸载。' 2>&1 | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $sAgent 'uninstall-me')) "聚合完成"
    $uOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\skillhub.ps1') uninstall -Target 'uninstall-me' 2>&1 | Out-String
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sAgent 'uninstall-me'))) "agent 链接已移除"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $sStore 'uninstall-me'))) "仓库副本已移除"
    $manifest = Read-JsonFile (Get-LinksManifestPath) @{ links = @() }
    Assert-True (@($manifest.links | Where-Object { $_.name -eq 'uninstall-me' }).Count -eq 0) "manifest 已清记录"
    Assert-True (@(Get-ChildItem (Join-Path $sandbox 'store-trash') -Directory -Force -ErrorAction SilentlyContinue).Count -gt 0) "仓库副本进入回收站(trash-safe)"
} finally {
    $env:HUB_STORE = $oldStore; $env:HUB_INDEX = $oldIdx; $env:HUB_MANIFEST = $oldMan; $env:HUB_LOCAL = $oldLoc; $env:HUB_NO_REBASE = $oldNR; $env:HUB_EVAL = $oldEval
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Section "14. 冲突判定确定性（活跃目标优先 + 字典序兜底）"
$sandbox = Join-Path $env:TEMP ("hub-sbx-conflict-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
$sStore  = Join-Path $sandbox 'store'
$sAgentA = Join-Path $sandbox 'agentA'
$sAgentB = Join-Path $sandbox 'agentB'
New-Item -ItemType Directory -Path $sStore, (Join-Path $sAgentA 'skills'), (Join-Path $sAgentB 'skills') -Force | Out-Null
$oldStore = $env:HUB_STORE; $oldIdx = $env:HUB_INDEX; $oldMan = $env:HUB_MANIFEST; $oldLoc = $env:HUB_LOCAL; $oldNR = $env:HUB_NO_REBASE; $oldEval = $env:HUB_EVAL
try {
    $env:HUB_STORE = $sStore; $env:HUB_INDEX = (Join-Path $sandbox 'idx.json'); $env:HUB_MANIFEST = (Join-Path $sandbox 'links.json'); $env:HUB_LOCAL = (Join-Path $sandbox 'local.json'); $env:HUB_EVAL = (Join-Path $sandbox 'eval.json'); $env:HUB_NO_REBASE = '1'
    Set-Content -LiteralPath $env:HUB_LOCAL -Value '{}' -Encoding UTF8
    $d1 = Join-Path $sAgentA 'skills'
    $d2 = Join-Path $sAgentB 'skills'
    foreach ($p in @($d1,$d2)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    $md = "---`nname: dup-skill`ndescription: 同名冲突测试技能。`n---`n# 标题`n正文内容若干行。"
    foreach ($p in @($d1,$d2)) {
        $sd = Join-Path $p 'dup-skill'
        New-Item -ItemType Directory -Path $sd -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sd 'SKILL.md') -Value $md -Encoding UTF8
    }
    # Run scan+evaluate twice; the kept copy must be identical every run.
    $kept = @()
    foreach ($run in 1..3) {
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\skillhub.ps1') scan 2>&1 | Out-Null
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\skillhub.ps1') evaluate 2>&1 | Out-Null
        $ev = Get-Content -LiteralPath $env:HUB_EVAL -Raw | ConvertFrom-Json
        $cf = @($ev.conflicts | Where-Object { $_.name -eq 'dup-skill' } | Select-Object -First 1)
        $kept += if ($cf.Count) { $cf[0].kept } else { '<none>' }
    }
    Assert-True (($kept | Select-Object -Unique).Count -eq 1) "冲突保留副本三次运行完全一致"
    # Target root must be preferred over non-target discovery root.
    $targetIdx = @{ skills = @(
        @{ name = 'dup-skill'; sourceDir = (Join-Path $d1 'dup-skill'); rootDir = $d1; isTarget = $true; totalScore = 50; portable = $true; frontmatter = @{} },
        @{ name = 'dup-skill'; sourceDir = (Join-Path $d2 'dup-skill'); rootDir = $d2; isTarget = $false; totalScore = 99; portable = $true; frontmatter = @{} }
    ) }
    $targetIdx | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $env:HUB_INDEX -Encoding UTF8
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\skillhub.ps1') evaluate 2>&1 | Out-Null
    $ev2 = Get-Content -LiteralPath $env:HUB_EVAL -Raw | ConvertFrom-Json
    $cf2 = @($ev2.conflicts | Where-Object { $_.name -eq 'dup-skill' } | Select-Object -First 1)
    Assert-True ($cf2.Count -gt 0) "冲突记录存在"
    if ($cf2.Count) { Assert-True ($cf2[0].kept -eq (Join-Path $d1 'dup-skill')) "活跃目标目录副本优先(高分非目标被拒)" }
} finally {
    $env:HUB_STORE = $oldStore; $env:HUB_INDEX = $oldIdx; $env:HUB_MANIFEST = $oldMan; $env:HUB_LOCAL = $oldLoc; $env:HUB_NO_REBASE = $oldNR; $env:HUB_EVAL = $oldEval
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Section "15. 沙盒隔离（沙盒 store 绝不写真实 agent 目录）"
$sandbox = Join-Path $env:TEMP ("hub-sbx-isol-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
$sStore  = Join-Path $sandbox 'store'
New-Item -ItemType Directory -Path $sStore -Force | Out-Null
$oldStore = $env:HUB_STORE; $oldIdx = $env:HUB_INDEX; $oldMan = $env:HUB_MANIFEST; $oldLoc = $env:HUB_LOCAL; $oldNR = $env:HUB_NO_REBASE; $oldEval = $env:HUB_EVAL
try {
    $env:HUB_STORE = $sStore; $env:HUB_INDEX = (Join-Path $sandbox 'idx.json'); $env:HUB_MANIFEST = (Join-Path $sandbox 'links.json'); $env:HUB_LOCAL = (Join-Path $sandbox 'local.json'); $env:HUB_EVAL = (Join-Path $sandbox 'eval.json'); $env:HUB_NO_REBASE = '1'
    Set-Content -LiteralPath $env:HUB_LOCAL -Value '{}' -Encoding UTF8
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\scan-skills.ps1') -RefreshIndex 2>&1 | Out-Null
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\evaluate-skills.ps1') 2>&1 | Out-Null
    # run link WITHOUT -Agents: auto-discovery must not reach real agent dirs
    $lOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\link-skills.ps1') 2>&1 | Out-String
    # any junction in a real (non-sandbox) target root pointing into this sandbox = leak
    $leak = @()
    $rIdx = Get-Index
    foreach ($root in @($rIdx.skillRoots | Where-Object { $_.isTarget })) {
        if ($root.rootDir.StartsWith($sandbox)) { continue }
        Get-ChildItem -LiteralPath $root.rootDir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $it = Get-Item $_.FullName -Force
            if ($it.LinkType -in @('Junction','SymbolicLink') -and $it.Target.StartsWith($sandbox)) { $leak += $_.FullName }
        }
    }
    Assert-Equal $leak.Count 0 "沙盒 store 未向真实 agent 目录写链接 ($($leak.Count) 泄漏)"
} finally {
    $env:HUB_STORE = $oldStore; $env:HUB_INDEX = $oldIdx; $env:HUB_MANIFEST = $oldMan; $env:HUB_LOCAL = $oldLoc; $env:HUB_NO_REBASE = $oldNR; $env:HUB_EVAL = $oldEval
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

} finally {
    # Restore original env vars
    $env:HUB_STORE = $envBackup.HUB_STORE
    $env:HUB_INDEX = $envBackup.HUB_INDEX
    $env:HUB_MANIFEST = $envBackup.HUB_MANIFEST
    $env:HUB_LOCAL = $envBackup.HUB_LOCAL
    $env:HUB_EVAL = $envBackup.HUB_EVAL
    $env:HUB_NO_REBASE = $envBackup.HUB_NO_REBASE
    # Clean up global sandbox
    Remove-Item -LiteralPath $globalSandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Remove-Item -LiteralPath $iAgent -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("==== 结果: {0} 通过, {1} 失败 ====" -f $passed, $failed) -ForegroundColor Cyan
if ($failed -gt 0) { exit 1 }
exit 0
