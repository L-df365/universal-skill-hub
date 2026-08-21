# review-skills.ps1 - interactively decide what to do with low-score skills
# Decisions are persisted into skillhub.local.json (personal, gitignored).
# Actions: keep-ignore / force / delete / merge-note / skip
# Usage: pwsh review-skills.ps1 [-AutoIgnore] [-DeleteLowest N] [-WhatIf]

[CmdletBinding()]
param(
    [switch]$AutoIgnore,
    [int]$DeleteLowest = 0,
    [switch]$WhatIf
)

. "$PSScriptRoot\common.ps1"

$cfgAll = Get-Config
$config = $cfgAll.base
$local  = $cfgAll.local
$evalPath = Get-EvalPath
$eval = Read-JsonFile $evalPath $null
if (-not $eval) {
    Write-Error "无评估报告，请先运行 scan + evaluate"
    exit 1
}
$lowScore = @($eval.lowScore)

if ($lowScore.Count -eq 0) {
    Write-Host "没有低分技能需要处理。" -ForegroundColor Green
    exit 0
}

$decisions = @{}
if ($local.decisions) {
    foreach ($p in $local.decisions.PSObject.Properties) { $decisions[$p.Name] = $p.Value }
}
$trashDir = Get-StoreTrashDir

Write-Section ("低分技能处置 ({0} 个)" -f $lowScore.Count)
Write-Host "操作: [k]eep忽略  [f]orce强制聚合  [d]elete删除到回收站  [m]erge标记待整合  [s]kip跳过(暂不处理)" -ForegroundColor Cyan
Write-Host ""

$i = 0
foreach ($s in $lowScore | Sort-Object @{ Expression = { $_.totalScore } }, @{ Expression = { $_.name } }) {
    $i++
    if ($s.name -in $decisions.Keys) {
        Write-Host ("  [{0}] {1} (已决定: {2})" -f $i, $s.name, $decisions[$s.name])
        continue
    }
    Write-Host ("  [{0}] {1}" -f $i, $s.name) -ForegroundColor White
    Write-Host ("      评分: {0} | 原因: {1}" -f $s.totalScore, $s.excludeReason)
    Write-Host ("      位置: {0}" -f $s.sourceDir)
    $desc = $s.frontmatter.description
    if ($desc) { Write-Host ("      描述: {0}" -f $desc.Substring(0, [Math]::Min(80, $desc.Length))) }

    $action = 's'
    if ($AutoIgnore) {
        $action = 'k'
    } elseif ($WhatIf) {
        $action = 'k'
        Write-Host "      (WhatIf: 默认忽略)" -ForegroundColor DarkGray
    } else {
        $ans = Read-Host "      处置 (k/f/d/m/s)"
        if ($ans) { $action = $ans.Substring(0,1).ToLower() }
    }

    switch ($action) {
        'k' { $decisions[$s.name] = 'ignore' }
        'f' { $decisions[$s.name] = 'force' }
        'd' {
            if ($WhatIf) {
                Write-Host "      (WhatIf: 将删除到 $trashDir)" -ForegroundColor DarkGray
                $decisions[$s.name] = 'ignore'
            } else {
                $src = $s.sourceDir
                if (-not (Test-Path -LiteralPath $src)) {
                    Write-Warning "源目录不存在，跳过: $src"
                    $decisions[$s.name] = 'ignore'
                } else {
                    $trash = Join-Path $trashDir ((Split-Path -Leaf $src) + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                    New-Item -ItemType Directory -Path $trashDir -Force | Out-Null
                    Move-Item -LiteralPath $src -Destination $trash -Force
                    Write-Host "      -> 已移动到回收站: $trash" -ForegroundColor DarkGreen
                    $decisions[$s.name] = 'deleted'
                }
            }
        }
        'm' {
            $note = Read-Host "      整合备注(回车表示无)"
            $decisions[$s.name] = 'merge'
            if (-not $local.mergeNotes) { $local | Add-Member -NotePropertyName 'mergeNotes' -NotePropertyValue (@{}) -Force }
            $local.mergeNotes | Add-Member -NotePropertyName $s.name -NotePropertyValue ($note ? $note : '') -Force
        }
        default { $decisions[$s.name] = 'skip' }
    }
}

# persist decisions + mergeNotes into local (personal) config
if (-not $local) { $local = @{} }
$local | Add-Member -NotePropertyName 'decisions' -NotePropertyValue $decisions -Force
if (-not $local.PSObject.Properties['mergeNotes']) {
    $local | Add-Member -NotePropertyName 'mergeNotes' -NotePropertyValue (@{}) -Force
}
$cfgPath = Get-LocalConfigPath
if (-not $WhatIf) {
    $local | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    Write-Host ""
    Write-Host "处置记录已写入 $cfgPath (本地个人配置，不进版本库)" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "WhatIf 模式：未写入任何更改。" -ForegroundColor DarkGray
}
