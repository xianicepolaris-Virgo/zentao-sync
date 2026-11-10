# zentao-sync

把需求 Markdown 同步到自建禅道（开源版，REST API v1）的 agent 技能。

- 一个 md 对应一个禅道需求，md 全文同步
- md 更新后走禅道"变更需求"（评审），并同步修改关联任务
- 禅道上有人改过需求时，以禅道为准覆盖本地 md
- 支持多个禅道账号切换
- 每次操作记录日志：时间、禅道账号、Windows 用户、电脑名、操作系统、IP

只需要 Windows 自带的 PowerShell，不需要 Python / Node。

## 安装（给 agent 看）

把本仓库克隆到你的技能目录下，文件夹名为 `zentao-sync`：

```
git clone https://github.com/xianicepolaris-Virgo/zentao-sync "<技能目录>\zentao-sync"
```

常见技能目录：

| agent | 技能目录 |
|---|---|
| WorkBuddy | `%USERPROFILE%\.workbuddy\skills` |
| Claude Code | `%USERPROFILE%\.claude\skills` |
| 其他支持 SKILL.md 的 agent | 以该 agent 文档为准 |

没有 git 时：下载 `https://github.com/xianicepolaris-Virgo/zentao-sync/archive/refs/heads/main.zip`，解压后把文件夹改名为 `zentao-sync` 放进技能目录。

不支持技能的 agent：克隆到任意目录，在它的规则文件（如 `AGENTS.md`）里加一句：
"涉及禅道时，先读 `<路径>\zentao-sync\SKILL.md` 并照做。"

更新：在 `zentao-sync` 目录里执行 `git pull`。

## 首次登录（用户自己执行，不要让 agent 代输密码）

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<技能目录>\zentao-sync\zentao.ps1" login -Account <禅道账号> -Url http://<禅道服务器>/zentao
```

密码用 Windows DPAPI 加密后存在本机 `%USERPROFILE%\.zentao-sync\config.json`，不会上传。

## 使用

对 agent 说"同步禅道"、"给这个需求派任务"、"切换禅道账号 xxx"、"看同步日志"即可。详细规则见 [SKILL.md](SKILL.md)。

## 数据位置

`%USERPROFILE%\.zentao-sync\`：`config.json`（账号）、`map.json`（md 与需求/任务对应关系）、`sync-log.csv`（日志）。
