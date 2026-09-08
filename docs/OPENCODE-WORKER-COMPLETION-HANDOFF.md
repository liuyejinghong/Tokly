# OpenCode Worker：异步任务完成后缺少主代理跟进

日期：2026-09-08。用途：带到插件项目中评估和优化。本次只读取插件源码，没有修改插件。

## 问题描述

当前插件解决了“Codex 分派 → OpenCode/Muse 后台执行 → 状态和产物落盘”，但没有闭合“执行停止 → 唤醒原 Codex 会话 → 验收或返工 → 继续下一包”。

当 Codex 调用 start 后结束当前响应，Muse 可以继续工作；然而它结束时，不会仅凭现有这套插件实现自动触发原会话的新一轮处理。文件和结果可能已经可读，主代理却仍处于暂停状态。用户需要再发消息，或另行建立宿主定时跟进。

这同时是插件能力边界与主代理编排问题：start 成功不代表跟进已建立；主代理不应在没有托管跟进的情况下暗示会自动验收后续结果。

## 已核实的代码依据

查看目录：/Users/ethan/plugins/opencode-worker/src，版本常量为0.1.0。这里只陈述本次读到的实现，不假设其他版本或宿主已有未公开功能。

- [store.ts:32](/Users/ethan/plugins/opencode-worker/src/store.ts:32)：reserve 写任务记录，spawn detached runner，child.unref()，随后返回 publicTask。后台执行与调用方响应生命周期分离。
- [mcp.ts:44](/Users/ethan/plugins/opencode-worker/src/mcp.ts:44)：wait 最长30秒，在这次调用内轮询 lookup；调用结束后不继续替主代理订阅/等待。
- [runner.ts:208](/Users/ethan/plugins/opencode-worker/src/runner.ts:208)：结束时先停专属服务、收集差异，设置 state/finished_at，再保存 task/result.json。该路径没有原 Codex 会话的完成投递或唤醒调用。
- [core.ts:31](/Users/ethan/plugins/opencode-worker/src/core.ts:31)：Task 有 OpenCode session_id，但没有原 Codex thread/host 的路由和完成投递状态。
- [core.ts:27](/Users/ethan/plugins/opencode-worker/src/core.ts:27)：acceptance 保持 pending。这一点是正确边界：Worker 执行完成不是主代理验收通过。
- 当前 MCP 入口注册 status/start/wait/followup/cancel 五个工具，未看到完成订阅、消费确认或宿主续跑适配。

## 最小复现

1. 在一个 Codex 会话中调用 start，派发需要几分钟的任务，记录 task_id。
2. 确认 returned state 为 submitted/running、finished=false。
3. 主代理结束本轮响应；不要再手动询问，不创建 heartbeat。
4. 等后台 runner 完成。
5. 再发一条消息手动触发 status，可以读到结束状态和产物，但此前没有自动验收或下一包分派。

实际业务影响：看起来已有人持续指挥，实际只是一个无人接手的后台任务；失败同样可能无人发现。

## 建议的解决路径

### 1. 先确认宿主能否真正唤醒原会话

先做一个端到端能力探针：模型响应结束后，宿主是否允许受控事件使指定原 thread 进入下一轮处理？明确其权限、用户可见性、本机在线条件和忙碌时的排队方式。

不能假定 MCP 日志、资源通知、系统通知或某个任务通知天然等于“启动新的模型轮次”。即便通知能够到达 UI，也需要验证是否真的触发了正确会话的主代理。

若宿主没有可用机制，插件单方面不能保证这个目标。应明确报告不支持，使用宿主原生 heartbeat 作为显式降级；不要通过写宿主私有数据库、伪造用户消息或另开 CLI 流程冒充原会话续跑。

### 2. 在现有持久化状态上增加完成事件

复用当前 task/turn 存储，不必新增消息服务或 Web 管理页面。

- 只有停止已确认、结果/差异已落盘，才产生该轮的“执行已停止”事件。
- 事件至少包含 task_id、turn、终态、产物位置、原调用方路由标识和稳定事件ID。
- 支持 completed、failed、cancelled、needs_attention；unknown 且 finished=false 只能发送“需要恢复/关注”，不能释放文件所有权或冒充完成。
- 增加轻量持久化待投递记录，MCP 重连/宿主恢复时可以补发。
- 复用 reconcile：处理 runner 在保存终态、结果与事件之间崩溃的情况，避免状态已结束但事件永远缺失。

建议投递语义为“至少一次＋接收端幂等”，不承诺无依据的 exactly-once。

### 3. 把跟进机制变成 start 的显式结果

由宿主适配层提供可信的原 thread/host 路由，不能只靠工作目录猜原会话。多个任务可以共享同一目录。

建议新增的能力/结果信息（字段名是草案，不是现有API）：

    completionTracking:
      mode: nativeWakeup | heartbeat | manual
      attached: true | false
      originThreadId: ...
      deliveryState: pending | acknowledged | unsupported

调用方若要求无人值守跟进，应先确认 nativeWakeup 或 heartbeat 已绑定，再让后台任务进入无人值守执行。跟进注册失败应明确返回并按约定处理，不能仍把它说成“会自动跟进”。

手动模式可以保留，但工具说明和返回值都必须明确：任务完成后需要调用方再次查询。

### 4. 接收、验收与重复事件分别处理

- 事件消费确认只表示已收到，不表示代码验收通过。
- 主代理被唤醒后重新读取权威状态与当前 turn，检查差异、测试、文件范围和真实产物，再决定接受、返工或暂停。
- 以 task_id/turn/事件版本去重；旧轮次事件在 followup 已启动后到达时，不得触发第二次返工或错误分派。
- start/followup 继续使用稳定 request_id。人工继续与自动事件同时到达，不能派出两份相同任务。
- 主会话正在运行时合并或排队；不要再开一个同时改同一目录的主代理。
- 原 thread 不可达时保留待处理事件，不投给另一个会话，也不无限重复通知。

已有单 Worker 槽与文件所有权规则应保留；完成投递不授权插件自行验收代码。

### 5. 明确权限与暂停条件

数据发送授权、后台持续跟进授权、代码写权限、签名/安装/发布权限是不同边界。只沿用已有明确授权，不让“任务完成事件”扩大权限。

对手机 remote 用户，必要确认应能用普通文字回复，不依赖只能在桌面看到的申请框。插件可以返回结构化的具体需求，但不能替用户批准。

## 验收标准

必须包含端到端验证，不能只断言“事件文件已写出”：

1. 主代理结束响应后，成功/失败任务均能使正确原会话获得一次有效处理机会。
2. 没有宿主唤醒能力时，明确显示手动模式或已绑定的 heartbeat，不能虚报自动跟进。
3. 宿主关闭、MCP重连、本机恢复后，未消费事件可补处理；不保证本机离线时执行。
4. 重复投递、人工同时继续、followup新轮次和旧事件晚到，均不重复分派、不重叠改文件。
5. finished=false/unknown 时不冒充任务已停止；取消后保留编辑并按现有规则恢复。
6. 事件到达后确实执行验收动作；Worker completed 仍不能自动变成 accepted。
7. 用户停止跟进后停止自动唤醒；失败不形成无限收费/重试循环。

## 当前项目的临时方案

用户已授权 Tokens macOS 使用每5分钟的原生线程 heartbeat，检查当前Worker、验收/返工并按批准开发包继续。无变化保持安静，只在有意义的完成、失败或需要用户动作时通知；本机开发包完成或必须等待用户时暂停。

这是宿主侧补偿方案，不是插件完成回调已经修复。本机 Codex/宿主具备运行条件时才能跟进。

## 可直接作为插件项目任务的摘要

请为 OpenCode Worker 设计并验证“异步任务停止后，原 Codex 会话能够继续验收”的完整链路。当前 detached runner 只写终态与产物，status/wait 是被动查询，主代理结束响应后没有自动消费结果。先验证宿主真正的会话唤醒能力；在现有task/turn存储上增加可补发、可去重的完成事件和消费确认，保持执行完成与验收通过分离。没有宿主支持时，明确降级到宿主 heartbeat 或手动模式，不伪装成原生子代理，不新增Web管理页面，不绕过权限。以“主代理已结束、随后任务完成且原会话确实恢复验收”的端到端测试作为通过标准。
