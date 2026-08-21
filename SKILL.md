---
name: universal-skill-hub
description: 通用技能聚合器。结构制扫描本地磁盘（不匹配软件名，只要目录含 SKILL.md 即为技能根），中央仓库统一持有每技能唯一物理副本，用 junction/symlink 聚合到所有 agent，让"装一个技能 = 拥有全部技能"。全生命周期闭环：创建(new)→聚合→修改→测试→卸载(uninstall)。零配置，AI 自动环境探测。使用时机：技能扫描/聚合/同步/迁移，"装一个技能当装全部"、"把 A 的技能同步给 B"、"新技能同步到其它 AI"、"创建并同步技能"、"测试技能聚合情况"、"卸载技能"、"哪些技能能用/可用技能清单"、"技能评分/筛选/清理低质量技能"。
version: 1.4.3
license: MIT
compatibility: Windows (NTFS junction) / macOS / Linux, PowerShell 7+ (pwsh)
metadata:
  trigger: skill hub 聚合 同步 评分 筛选 迁移 创建技能 测试技能 卸载技能 本地技能 junction symlink 低分处置 回滚
---

# Universal Skill Hub

结构制技能聚合器：**任何目录直接含 `SKILL.md` 即技能根**，不匹配软件名。
**中央仓库（`~/.skillhub/skills`）持有每技能唯一物理副本**，所有 agent 的 skills 目录以 junction/symlink 指向仓库——卸载任意软件不影响聚合，天然防环、零复制。

## 单入口命令

```powershell
pwsh skillhub.ps1 sync            # 定向提示（新技能请用 sync -Target 或 new）
pwsh skillhub.ps1 sync -Target <技能名>   # 定向同步单个技能（不重新全盘扫描）
pwsh skillhub.ps1 sync -Full      # 全量重扫 + 评估 + 聚合（仅首次安装时使用）
pwsh skillhub.ps1 new -Target <技能名> [-Desc <描述>]   # 在仓库创建技能并立即聚合到所有 agent
pwsh skillhub.ps1 test -Target <技能名>    # 只读校验：评分/可移植/来源/各 agent 链接状态
pwsh skillhub.ps1 uninstall -Target <技能名>  # 卸载：移除全软件链接 + 清单记录 + 仓库副本(进回收站)
pwsh skillhub.ps1 dry-run         # 只展示计划
pwsh skillhub.ps1 rollback        # 移除所有已创建的链接
pwsh skillhub.ps1 list            # 技能清单
pwsh skillhub.ps1 link-to <dir>   # 聚合到指定目标目录
pwsh skillhub.ps1 review          # 低分技能处置
pwsh skillhub.ps1 review -AutoIgnore   # 全部低分自动记录为 ignore
pwsh skillhub.ps1 review -WhatIf       # 只预览处置计划
```

## 生命周期（定向聚合，省 token/时间）

| 阶段 | 命令 | 行为 |
|---|---|---|
| 创建 | `new -Target X` | 仓库建技能 → 写 forceInclude（免评分）→ 立即自动聚合到所有 agent |
| 安装 | `sync -Target X` / 全量 `sync -Full` | 定向同步；仅首次安装做全盘扫描 |
| 修改 | 编辑后 `sync -Target X` | 从仓库重新聚合（链接实时指向仓库） |
| 测试 | `test -Target X` | 评分/可移植/来源/各 agent 链接状态（OK/悬空） |
| 卸载 | `uninstall -Target X` | 全链接 + 清单 + 仓库副本 → 回收站（可恢复） |

- **仅首次安装全盘扫描**；之后新技能只定向聚合（不重新发现）。
- `new`/`sync -Target` 内置自动聚合——技能创建后立即同步到所有已发现的 agent 目录。
- AI agent 在用户**通过其它途径**（手动复制、其它 skill 下载落盘）安装新技能时，**必须主动询问**是否同步（见下方 [MUST] 强制行为）；经用户确认后用官方命令聚合，**不得用 `ln -s`/`cp` 等命令绕过**受管流程。

## 新技能安装后的同步询问（[MUST] 强制行为）

每当用户**安装 / 导入 / 创建一个新技能 X**（无论经本 hub 的 `new`、其它 skill 的下载落盘，还是手动放进某软件 skills 目录），你**必须主动询问**：

> 「是否要把技能 X 同步安装到其它 AI 软件？」

**不要替用户做主**。给出以下三个选项，让用户明白我们要做什么、自己决定：

1. **同步到所有 AI 软件** → 用官方命令 `pwsh skillhub.ps1 sync -Target X`，聚合进全部已发现的 agent 目录
2. **只同步到指定目录** → 用 `pwsh skillhub.ps1 link-to <目标软件 skills 目录>`，仅聚合到用户勾选的软件
3. **暂不聚合** → 仅保留技能、不写任何链接；用户之后随时可 `pwsh skillhub.ps1 sync -Target X` 触发

无论用户选哪个，**不得用 `ln -s` / `cp` / 手动复制等系统命令绕过 hub 的受管流程**——所有聚合必须经由上述官方命令。

## 可移植性判定

聚合前判定能否在非原 AI 环境运行。**平台对称**：Windows/Unix 同一套逻辑，只是"外来主目录"方向相反。隔离**与特定 AI 软件环境强绑定**的技能：

- **agent 专属目录**：动态探测 `$HOME` 下结构含 `skills` 子目录的 `.名称` 目录即 AI 环境（不硬编码产品名）。引用 `~/.<agent>/...` 或 `$HOME/.<agent>/...` → 不可移植
- **通用约定可移植**：`~/.config`、`~/.local`、`~/.cache`、`~/.mcporter`、`~/.ssh`、`~/.npm`、`/tmp`、`/dev/stdin`、`/usr/bin` 等跨平台约定不算绑定
- **其它 OS 主目录**：Windows 上真实 `/home/<用户>/`、`/Users/<用户>/`、`/root/`；Unix 上真实 `C:\Users\<用户>\`、`%USERPROFILE%` → 不可移植。占位符（`/Users/xxx`、`<name>`、`$user`）不误判
- **硬编码引擎二进制**：`nodeBinary`/`binaryPath`/`executablePath` 指向 `.exe`/`.mjs`，或引用 dot 目录下 `.mjs` 引擎 → 不可移植
- frontmatter `portable: true|false` 强制覆盖；`runtime: <agent>` → 绑定运行时，不可移植
- 结果写入索引 `portable`/`portableReason`；不可移植技能在 evaluate 中被排除

## 架构

1. **scan**：从 `$HOME` 隐藏目录 + `~/.config` 结构制遍历，判定「直接含 SKILL.md」为技能根。junction/symlink 子项**不算**技能（防环）；只读根（如 Documents）只发现不聚合；产出 `skillhub-index.json`
2. **evaluate**：完整性(60) + 活性加权(40)。活性信号多源收割（使用记录、安装/更新、文件 mtime、跨 agent 数、自记）；`freePassUsage` 活性免检；同名冲突：**活跃目标目录优先 > 评分最高 > 源路径字典序兜底**（全确定）；不可移植排除；产出 `skillhub-eval.json`
3. **link**：导入（源 → 仓库唯一副本）→ rebase（原目录变 junction，原目录进回收站）→ 聚合（junction 仓库 → 各 agent 根）。悬空/旧链接自动清理重建；真实目录冲突跳过并报告；记录 `skillhub-links.json`
4. **unlink**：回滚模式（仅删链接）与卸载模式（`-Uninstall`：删全链接 + 清单 + 仓库副本进回收站）。

## 评分构成（回答评分/处置问题时必须完整说明）

技能总分 = **完整性分（最高 60）** + **活性加权分（最高 40）**，满分 100，默认达标阈值 `scoreThreshold` = 60。

| 部分 | 满分 | 信号构成 |
|---|---|---|
| 完整性 | 60 | 有效 frontmatter 15 + description 触发词 10 + body 长度 10+10 + 结构规范 5 + 支持文件 5 + 无 TODO 5 |
| 活性加权 | 40 | 跨 agent 存在 10 + 近期使用 15 + 近期安装 10 + 近期更新 5 + 使用次数 5 + 在 manifest 5 |

**回答「评分/低分处置/阈值/是否聚合」问题时必须含上述构成**，不得只讲操作步骤。

## 低分技能处置（review）

`pwsh skillhub.ps1 review` 逐项处置，选项：
- **k** keep → `ignore`：保留在盘上不聚合
- **f** force → `force`：强制聚合（评分不足但想要）
- **d** delete → `deleted`：目录移回收站（默认 `~/.skillhub/trash`），同名加后缀防冲突
- **m** merge → `merge`：整合说明写入 `skillhub.local.json` 的 `mergeNotes`
- **s** skip → `skip`：暂不处理，后续不再提示

decision 记录在 `scripts/skillhub.local.json`；已决策技能不再重复提示，可手动编辑撤销。

## 模式 B：运行时加载（无需重启）

任务命中本地技能但目标 agent 未聚合时：`load-skill.ps1 -Query <词>` 读取 SKILL.md 按其执行。某目标 agent 无法聚合时，这是读取其技能内容的替代方式，**不得用系统 shell 命令（如 `ln -s`）绕过 hub 的受管流程**。

## 关键设计点

- **结构制**：不匹配软件名，天然适配未知软件
- **中央仓库**：每技能唯一物理副本；所有 agent 链接指向仓库；卸载任意软件不影响聚合
- **防环**：junction 子项不参与技能根判定；只读根与仓库不做聚合目标
- **零复制**：junction/symlink 指向仓库；不覆盖真实目录；删除进回收站；幂等
- **可移植优先**：不可移植技能（绑定路径/运行时）自动隔离
- **配置分离**：公开版 `skillhub.config.json` 零个人数据；个人偏好写入 `skillhub.local.json`（gitignore）

## 配置文件

`scripts/skillhub.config.json`（通用，提交）：
- `scoreThreshold` 默认 60；`freePassUsage` 默认 35（活性分≥35 时总分低于阈值也聚合）
- `scanDepth` 3、`excludeDirs`、`deleteTrashDir`、`storeDir`（默认 `~/.skillhub/skills`）
- `signalSources`：活性信号源路径表（`usage` + `install` 两类），让任何 agent 生态都能供给活性信号

`scripts/skillhub.local.json`（个人，gitignore）：
- `scoreThreshold`/`freePassUsage` 覆盖（先读 config 再被 local 覆盖）、`decisions`、`forceInclude`（`new` 自动写入）、`forceLinkRoots`、`extraScanRoots`、`storeDir`/`deleteTrashDir` 覆盖、`signalSources` 覆盖（机器特定信号路径）

## 测试

```powershell
pwsh tests/run-tests.ps1   # 结构发现/活性加权/幂等/坏链/manifest/单技能/rollback/中央仓库/悬空清理/可移植性/new/test/uninstall/冲突确定性/沙盒隔离
```

**测试全程隔离**：从测试入口第一行起即设置 `HUB_STORE`/`HUB_INDEX`/`HUB_MANIFEST`/`HUB_LOCAL`/`HUB_EVAL` 环境变量指向临时沙盒目录，并设置 `HUB_NO_REBASE=1` 禁止源目录重定向。所有 scan/evaluate/link 操作均作用于临时沙盒中的 fake 技能和 fake agent 目录，绝不触碰用户真实数据。测试结束后自动清理沙盒并恢复原始环境变量。