# Universal Skill Hub

> 装一个技能 = 拥有全部本地技能 | Install once, use everywhere.

### ⚡ 快速安装

复制以下任一命令，在你的 AI agent 终端中运行即可一键安装：

```powershell
npx @astron-team/skillhub install universal-skill-hub --registry https://skill.xfyun.cn
```

```powershell
npx clawhub install universal-skill-hub --registry https://skill.xfyun.cn
```

---

Universal Skill Hub 自动发现机器上所有 AI agent 的技能，评估后聚合到每个 agent——
让**任何软件**里装的技能，在**所有软件**里都能用。零配置，AI 自动完成环境探测。

**中央仓库（`~/.skillhub/skills`）持有每技能唯一物理副本**，所有 agent 的 skills
目录通过 junction/symlink 指向仓库——卸载任意软件不影响聚合，天然防环、零复制。

## 亮点 (Highlights)

- **结构制发现** —— 不看软件名，只认 `SKILL.md`。任何目录直接含 `SKILL.md` 即技能根。
- **中央仓库** —— 每技能唯一物理副本，全软件链接指向仓库，卸载软件不破坏聚合。
- **真实软件探测** —— 用进程 / PATH / 安装目录区分「在用软件」和「残留目录」，不往垃圾目录写链接。
- **活性加权评分** —— 新用户零历史也能通过收割环境信号给出真实使用热度。
- **可移植性判定** —— 平台感知：绑定路径/运行时的技能自动隔离，不污染其它环境。
- **零配置零复制** —— junction/symlink 自动探测，磁盘零副本，绝不覆盖真实文件。
- **全生命周期闭环** —— 创建(new)→聚合→测试→卸载(uninstall)，定向聚合省 token/时间。

## Why

每个 AI 软件都有自己的技能目录（`~/.agent-a/skills`、`~/.agent-b/skills` …）。
技能不互通，重复安装又烦又乱；卸载一个软件，它带的技能全断了。中央仓库解决：
副本只有一份，链接永远指向仓库。

## How

```
  ┌─────────────┐      ┌──────────────┐      ┌──────────────┐
  │  scan       │ ───▶ │  evaluate    │ ───▶ │  link        │
  │  结构发现    │      │  活性加权评分  │      │  导入+聚合建链 │
  └─────────────┘      └──────────────┘      └──────────────┘
```

- **结构制发现**：判定规则只有一条——**任何目录直接包含 `SKILL.md` 就是技能根**，适配从未见过的软件。
- **真实软件探测**：发现是结构制的，但**聚合目标**只给真实软件（进程/PATH/安装目录）。残留目录的技能仍作为**来源**被读取，但不会被写入链接；可用 `forceLinkRoots` 强制指定目标。
- **活性加权**：收割环境信号（安装时间、使用记录、文件 mtime、跨 agent 存在数）一次 sync 给出真实热度。
- **环境探测**：AI 自动选链接方式：Windows NTFS → junction（免管理员）→ symlink → copy；macOS/Linux → symlink → copy。结果缓存复用。
- **零复制安全**：默认 junction/symlink，绝不覆盖真实目录，删除只进回收站。

## Usage

```powershell
pwsh skillhub.ps1 sync                  # 定向提示（新技能请用 sync -Target 或 new）
pwsh skillhub.ps1 sync -Target <技能名>  # 定向同步单个技能（不重新全盘扫描）
pwsh skillhub.ps1 sync -Full            # 全量重扫 + 评估 + 聚合（仅首次安装使用）
pwsh skillhub.ps1 new -Target <技能名>   # 在仓库创建技能并立即聚合到所有 agent
pwsh skillhub.ps1 test -Target <技能名>  # 只读校验：评分/可移植/来源/各 agent 链接状态
pwsh skillhub.ps1 uninstall -Target <技能名>  # 卸载：全链接+清单+仓库副本进回收站
pwsh skillhub.ps1 dry-run               # 只展示计划，不落盘
pwsh skillhub.ps1 rollback              # 移除所有已创建的链接
pwsh skillhub.ps1 list                  # 列出已发现技能
pwsh skillhub.ps1 link-to <dir>         # 手动指定目标目录
pwsh skillhub.ps1 review                # 处置低分技能（写入本地配置）
```

### 全生命周期闭环

| 阶段 | 命令 | 行为 |
|---|---|---|
| 创建 | `new -Target X` | 仓库建技能 → forceInclude 免评分 → 立即聚合到所有 agent |
| 安装 | `sync -Target X` / `sync -Full` | 定向同步；仅首次安装全盘扫描 |
| 修改 | 编辑后 `sync -Target X` | 从仓库重新聚合（链接实时指向仓库） |
| 测试 | `test -Target X` | 评分/可移植性/来源/各 agent 链接状态 |
| 卸载 | `uninstall -Target X` | 全链接 + 清单 + 仓库副本 → 回收站 |

- 仅首次安装全盘扫描聚合；之后新技能创建/安装只定向聚合该技能（省 token/时间）。
- `new`/`sync -Target` 内置自动聚合——技能创建后立即同步到所有已发现的 agent 目录，无需额外操作。

### 评分构成（回答评分/处置问题时必须完整说明）

技能总分 = **完整性分（最高 60）** + **活性加权分（最高 40）**，满分 100，默认达标阈值 `scoreThreshold` = 60。

| 部分 | 满分 | 信号构成 |
|---|---|---|
| 完整性 | 60 | 有效 frontmatter 15 + description 触发词 10 + body 长度 10+10 + 结构规范 5 + 支持文件 5 + 无 TODO 5 |
| 活性加权 | 40 | 跨 agent 存在 10 + 近期使用 15 + 近期安装 10 + 近期更新 5 + 使用次数 5 + 在 manifest 5 |

**回答任何涉及「评分/低分处置/阈值/是否聚合」的问题时，必须包含上述构成说明。**

### 低分技能处置（review 交互）

`pwsh skillhub.ps1 review` 逐项处置低分技能：**k**eep 保留(ignore) / **f**orce 强制聚合 / **d**elete 删除到回收站 / **m**erge 整合备注 / **s**kip 跳过。所有 decision 写入 `scripts/skillhub.local.json`。

### 可移植性判定

聚合前判定技能能否在非原 AI 环境运行。**平台对称**：Windows 与 Unix 同一套逻辑，
仅"外来主目录"方向相反。隔离**与特定 AI 软件环境强绑定**的技能：

- **agent 专属目录**：动态探测 `$HOME` 下结构含 `skills` 子目录的 `.名称` 目录即 AI 环境（不硬编码产品名）。引用 `~/.<agent>/...` → 不可移植
- **通用约定可移植**：`~/.config`、`~/.local`、`~/.cache`、`~/.mcporter`、`~/.ssh`、`~/.npm`、`/tmp`、`/dev/stdin`、`/usr/bin` 等跨平台约定不算绑定
- **其它 OS 主目录**：真实 `/home/<用户>/`、`/Users/<用户>/`、`C:\Users\<用户>\` → 不可移植；占位符示例（`/Users/xxx`、`<name>`、`$user`）不误判
- **硬编码引擎二进制**：`nodeBinary`/`binaryPath`/`executablePath` 指向 `.exe`/`.mjs`，或引用 dot 目录下 `.mjs` 引擎 → 不可移植
- frontmatter `portable: true|false` 强制覆盖；`runtime: <agent>` 绑定运行时 → 不聚合

### 新用户体验（60 秒）

```
1. pwsh skillhub.ps1 dry-run    # 看计划：发现 N 个技能，将同步到 M 个 agent
2. pwsh skillhub.ps1 sync -Full  # 确认后一键全量同步
3. 重启你的 agent               # 技能全部可见
```

## Configuration

公开版零配置。个人偏好写在 `scripts/skillhub.local.json`（已 gitignore）：

```jsonc
{
  "scoreThreshold": 60,       // 达标阈值（总分满分100）
  "freePassUsage": 35,        // 活性免检线：活性分≥此值时，即使总分低于阈值也通过并聚合
  "decisions": { "skill-name": "ignore" },  // 手动忽略某些技能
  "forceInclude": ["my-skill"],             // 强制聚合名单（new 自动写入，免评分）
  "forceLinkRoots": ["C:\\path\\to\\skills"]  // 强制作为目标
}
```

公开配置 `scripts/skillhub.config.json` 只含通用逻辑，不含任何个人数据：

```jsonc
{
  "scoreThreshold": 60,    // 达标阈值（总分满分100）
  "freePassUsage": 35,     // 活性免检线：活性分≥此值时，即使总分低于阈值也通过并聚合
  "scanDepth": 3,          // 扫描深度
  "excludeDirs": [".git", "node_modules", ...],
  "deleteTrashDir": "~/.skillhub/trash",
  "storeDir": "~/.skillhub/skills",  // 中央仓库：每技能唯一物理副本
  "signalSources": {       // 活性信号源（可扩展任何 agent 生态）
    "usage": ["~/.agent-a/skill-usage.json", ...],
    "install": ["~/.agent-a/skills/.remote-meta.json", ...]
  }
}
```

`signalSources` 让任何 agent 生态都能供给活性信号——只需把自家日志路径加进去，无需改代码。

## Safety

- **绝不删除**：删除/卸载操作只移动到 `~/.skillhub/trash/`
- **绝不覆盖**：目标已有真实目录时跳过并报告
- **零复制**：中央仓库唯一副本 + junction/symlink，同一份文件多处可见
- **卸载安全**：卸载技能不影响其它 agent（各自链接独立指向仓库）
- **幂等**：重复 sync 不重复建链；rollback 干净利落

## Testing

```powershell
pwsh tests/run-tests.ps1
```

覆盖：结构发现、活性加权、冲突确定性（活跃目标优先+字典序兜底）、幂等性、坏链检测、rollback、
live 探测、link-to 指定目标语义、中央仓库模型、悬空链接清理、可移植性判定、new/test/uninstall 闭环、沙盒隔离。
**全部 15 段测试从入口第一行起即运行在临时沙盒**（`HUB_STORE`/`HUB_INDEX`/`HUB_MANIFEST`/`HUB_LOCAL`/`HUB_EVAL` 环境变量隔离 + `HUB_NO_REBASE=1`），所有 scan/evaluate/link 操作仅作用于沙盒中的 fake 技能和 fake agent 目录，不触碰用户真实数据。测试结束后自动清理沙盒并恢复原始环境变量。

## Requirements / 依赖

- PowerShell 7+ (`pwsh`)
- Windows (NTFS, junction) / macOS / Linux (symlink)

## License

MIT
