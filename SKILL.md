---
name: zentao-sync
description: 把需求 md 同步到自建禅道。新建或修改需求 md 后自动使用；用户说"同步禅道/下需求/派任务/改任务/切换禅道账号/看同步日志"时使用。一个 md 对应一个禅道需求，md 更新后走禅道"变更需求"并同步修改关联任务。
version: 1.0
trigger_keywords: [禅道, 同步禅道, 下需求, 派任务, 变更需求, 切换禅道账号, 同步日志]
---

# 禅道需求同步

## 工具

所有操作都通过本文件同目录下的 `zentao.ps1` 完成，不要自己拼 HTTP 请求。调用格式：

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<本技能目录>\zentao.ps1" <动作> [参数]
```

脚本只输出一段 JSON，按其中的 `result` 字段决定下一步。数据都在 `%USERPROFILE%\.zentao-sync\`：
`config.json`（账号）、`map.json`（md 与需求/任务的对应关系）、`sync-log.csv`（日志）。不要手动改这三个文件。

## 什么时候同步

1. 你新建或修改了一个需求 md 并保存后，**立即**对该 md 执行 `sync`，不用等用户说。
2. 用户说"同步禅道"等，对他指的 md 执行 `sync`；没说哪个就同步本次对话里改过的需求 md。
3. 不是需求的 md（README、笔记等）不同步；拿不准就问一句。

## 硬规则

- **绝不在对话里索要或接收禅道密码。** 需要登录时，让用户自己打开 PowerShell 执行 login 命令（见"账号"）。
- **用户没说明的字段一律不设置**，不要自己猜评审人、指派人、迭代、日期。
- 缺了必填信息就问用户，一次只问缺的那一项。
- md 全文原样同步，不要改写、删减、总结 md 内容。
- 每次操作后用一句话告诉用户结果：需求编号、状态、改了哪些任务。

## sync 流程

```
zentao.ps1 sync -Md "<md完整路径>" [-Product <产品ID>] [-Title "<标题>"] [-Reviewer acc1,acc2] [-NoReview] [-AssignedTo <账号>] [-Comment "<变更说明>"]
```

标题默认取 md 第一个 `# ` 标题，没有就用文件名；用户指定了标题才传 `-Title`。

按返回的 `result` 处理：

| result | 含义 | 你要做的 |
|---|---|---|
| `CREATED` | 新建了需求 | 告诉用户需求编号 |
| `NEED_PRODUCT`（在 ERROR 的 message 里） | 新需求没给产品 | 执行 `products`，把列表给用户选，再带 `-Product` 重跑 |
| `NO_CHANGE` | md 没变 | 不做任何事 |
| `NEED_REVIEWER` | md 变了，变更要走评审但没给评审人 | 问用户评审人是谁（可执行 `users` 把姓名换成账号），带 `-Reviewer` 重跑。只有用户明确说"不用评审"才用 `-NoReview` |
| `CHANGED` | 已提交变更 | 看返回的 `tasks`，不为空就按"任务"一节更新受影响的任务 |
| `REMOTE_CHANGED` | 有人在禅道上改过这个需求 | **以禅道为主**，见下 |
| `ERROR` | 失败 | 把 message 原样告诉用户；`NOT_LOGGED_IN` 按"账号"处理 |

### REMOTE_CHANGED（禅道为主）

1. 读取返回里的 `htmlFile`。
2. 把它完整转成 Markdown，**直接覆盖**原 md（不用问用户，本地未同步的修改会被丢弃）。
3. 删除 `htmlFile`。
4. 执行 `zentao.ps1 sync -Md "<md>" -AcceptRemote`。
5. 告诉用户：禅道上有人改过，本地 md 已被禅道版本覆盖；如果刚才本地有改动，需要用户确认是否重新修改。

## 任务

只有用户要求拆任务/派任务时才建，不要自动拆。

```
zentao.ps1 task-add -Md "<md>" -Execution <迭代ID> -Name "<任务名>" [-AssignedTo <账号>] [-Type devel] [-EstStarted 2026-01-01] [-Deadline 2026-01-31] [-Estimate 8] [-Desc "<描述>"]
zentao.ps1 task-update -TaskId <任务ID> [-Name ..] [-Desc ..] [-AssignedTo ..] [-EstStarted ..] [-Deadline ..] [-Estimate ..]
```

- 迭代每次不同：用户没说就执行 `executions`（或 `projects` 后 `executions -Project <id>`）列出来让用户选。
- 指派人没说就不传 `-AssignedTo`，用户自己去禅道指派。
- `-Type` 可选：design devel request test study discuss ui affair misc，没说用 devel。
- 需求 `CHANGED` 后：对照新旧内容，只对受影响的关联任务执行 `task-update`（改名称/描述）。需要新增或作废任务时先问用户。
- 如果禅道因为缺日期等字段拒绝创建，把报错告诉用户并问缺的值。

## 账号

- 首次使用或 `NOT_LOGGED_IN`：让用户自己在 PowerShell 里执行（密码只在他的窗口里输入，加密存在本机）：
  ```
  powershell -NoProfile -ExecutionPolicy Bypass -File "<本技能目录>\zentao.ps1" login -Account <禅道账号> -Url <禅道地址，如 http://服务器/zentao>
  ```
  `-Url` 只在第一次登录时需要，之后会记住。
- 切换账号：`zentao.ps1 use -Account <账号>`；该账号没登录过就让用户执行上面的 login。
- 查看当前账号：`zentao.ps1 accounts`。
- 自检：`zentao.ps1 test`。

## 日志

每次登录、切换账号、建需求、变更、拉取、建任务、改任务、失败，脚本都会自动写一行到 `sync-log.csv`，字段：
时间、操作、禅道账号、Windows 用户、电脑名、操作系统、IP、md 路径、需求编号、任务编号、结果、详情。

用户要看日志：`zentao.ps1 log -Last 20`，或直接用 Excel 打开 `%USERPROFILE%\.zentao-sync\sync-log.csv`。

## 其他查询

- `zentao.ps1 status -Md "<md>"`：该 md 对应的需求编号、禅道状态、本地/禅道是否有改动、关联任务。
- `zentao.ps1 products` / `projects` / `executions` / `users`：查 ID 和账号。
