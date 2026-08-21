# unlink-skills.ps1 - remove junctions/copies created by link-skills.ps1
# Two modes:
#   rollback   (-All or -Root/-Name): remove links only, keep central store.
#   uninstall  (-Uninstall -Name X):   remove ALL links for X + drop manifest
#                                      records + move the store copy to trash.
# Usage: pwsh unlink-skills.ps1 [-Root <rootDir>] [-Name <skill>] [-All] [-Uninstall] [-WhatIf]

[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$Name = '',
    [switch]$All,
    [switch]$Uninstall,
    [switch]$WhatIf
)

. "$PSScriptRoot\common.ps1"

$manifest = Read-JsonFile (Get-LinksManifestPath) @{ links = @() }
$links = @($manifest.links)
if ($links.Count -eq 0) {
    Write-Host "链接清单为空（可能之前未聚合或已清理）。" -ForegroundColor Yellow
}

$targets = $links
if ($Root) { $targets = @($targets | Where-Object { $_.agent -eq $Root -or $_.link.StartsWith($Root + [IO.Path]::DirectorySeparatorChar) }) }
if ($Name) { $targets = @($targets | Where-Object { $_.name -eq $Name }) }

$removed = @()
foreach ($t in $targets) {
    $p = $t.link
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        Write-Host "  已不存在，清理记录: $p" -ForegroundColor DarkGray
        $removed += $t
        continue
    }
    if ($item.LinkType -in @('Junction','SymbolicLink')) {
        if ($WhatIf) {
            Write-Host "  (WhatIf) 将移除链接: $p -> $($t.source)" -ForegroundColor DarkGray
        } else {
            Remove-Item -LiteralPath $p -Force
            Write-Host "  已移除链接: $p" -ForegroundColor Green
            $removed += $t
        }
    } else {
        Write-Warning "非链接（真实目录），不动: $p"
    }
}

# uninstall mode: also drop the central-store physical copy into trash
$storePath = $null
if ($Uninstall -and $Name) {
    $storePath = Join-Path (Get-StoreDir) $Name
    if (Test-Path -LiteralPath $storePath) {
        if ($WhatIf) {
            Write-Host "  (WhatIf) 将仓库副本移入回收站: $storePath" -ForegroundColor DarkGray
        } else {
            $trashDir = Get-StoreTrashDir
            $trash = Join-Path $trashDir (($Name) + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            New-Item -ItemType Directory -Path $trashDir -Force | Out-Null
            Move-Item -LiteralPath $storePath -Destination $trash -Force
            Write-Host "  仓库副本已移入回收站: $trash" -ForegroundColor DarkGreen
        }
    }
}

if (-not $WhatIf -and ($removed.Count -gt 0 -or $storePath)) {
    $remaining = @($links | Where-Object { $removed -notcontains $_ })
    if ($remaining.Count -eq 0) {
        Remove-Item -LiteralPath (Get-LinksManifestPath) -Force -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "链接清单已清空。" -ForegroundColor Green
    } else {
        @{ links = $remaining } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Get-LinksManifestPath) -Encoding UTF8
    }
}
Write-Host ""
Write-Host ("清理完成: 移除 {0} 个" -f $removed.Count) -ForegroundColor Cyan