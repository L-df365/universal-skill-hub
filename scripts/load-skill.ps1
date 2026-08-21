# load-skill.ps1 - mode B: resolve a keyword to a skill and print its SKILL.md
# Usage: pwsh load-skill.ps1 -Query <keyword> [-List] [-Top 20]

[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Query = '',
    [switch]$List,
    [int]$Top = 20
)

. "$PSScriptRoot\common.ps1"

$index = Get-Index
if (-not $index -or -not $index.skills) {
    Write-Error "索引为空，请先运行 scan-skills.ps1"
    exit 1
}

$skills = @($index.skills)

if ($List) {
    Write-Section ("已发现技能 Top {0}" -f $Top)
    $skills | Sort-Object @{ Expression = { -$_.totalScore } }, @{ Expression = { $_.name } } | Select-Object -First $Top | ForEach-Object {
        $d = $_.frontmatter.description
        if ($d -and $d.Length -gt 90) { $d = $d.Substring(0,90) + '...' }
        Write-Host ("  [{0,3}] {1,-40} {2}" -f $_.totalScore, $_.name, $d)
    }
    exit 0
}

if (-not $Query) {
    Write-Host "用法: pwsh load-skill.ps1 -Query <关键词>  或  -List" -ForegroundColor Yellow
    exit 1
}

$q = $Query.Trim()
# exact name match first
$match = @($skills | Where-Object { $_.name -eq $q })
# then substring on name
if (-not $match) { $match = @($skills | Where-Object { $_.name -like "*$q*" }) }
# then substring on description
if (-not $match) { $match = @($skills | Where-Object { $_.frontmatter.description -and $_.frontmatter.description -like "*$q*" }) }

if (-not $match) {
    Write-Host "未找到匹配技能: $q" -ForegroundColor Red
    Write-Host "可用 -List 查看技能清单。" -ForegroundColor Yellow
    exit 1
}

$match = @($match | Sort-Object @{ Expression = { -$_.totalScore } }, @{ Expression = { $_.name } })
$pick = $match[0]
$desc = $pick.frontmatter.description
if ($desc -and $desc.Length -gt 120) { $desc = $desc.Substring(0,120) + '...' }

Write-Host ("匹配 [{0}] 分 {1} 来源 {2}" -f $pick.name, $pick.totalScore, $pick.sourceDir) -ForegroundColor Cyan
Write-Host ("描述: {0}" -f $desc)
if ($match.Count -gt 1) {
    Write-Host ("另有 {0} 个相近匹配: {1}" -f ($match.Count - 1), (($match | Select-Object -Skip 1 | ForEach-Object { $_.name }) -join ', ')) -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "===== SKILL.md 内容 =====" -ForegroundColor Green
Write-Host ""
if (Test-Path -LiteralPath $pick.skillMd) {
    Write-Host (Read-SkillText $pick.skillMd)
} else {
    Write-Warning "SKILL.md 不存在: $($pick.skillMd)"
}
