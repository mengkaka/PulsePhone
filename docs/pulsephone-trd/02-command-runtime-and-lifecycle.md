# PulsePhone TRD 02 - Command、调度与生命周期

> 文档状态：第一阶段规范章节
>
> 上级文档：[`pulsephone-trd.md`](../pulsephone-trd.md)
>
> 负责范围：第 8～13 节；CommandCatalog、Planner、execution shape、Scheduler、OperationLifecycle、Runtime/Executor/Shutdown 生命周期和 PreparationWaitRegistry。

本章持有所有通用执行语义。逐 Product Action 的参数、candidate 和 deadline 由 TRD 06 持有；Developer Support preparation 由 TRD 03 持有；跨进程编码与 Helper 协议由 TRD 05 持有。

## 8. CommandCatalog 与规划

### 8.1 Catalog 内容

每个 Product/Supporting Action 必须由共享 Catalog 描述：

```text
commandID
argument schema / result schema
executionShape
CompatibilityRule
availability requirements
Runtime activation policy
queue policy
ResourceClaimTemplate
candidate order / preparation group
deadline / cleanup / owner disconnect policy
allowed error codes
CLI/GUI exposure
redaction policy
```

`matrixRevision=command-matrix.v17-20260822`：

```text
Product Action rows       52
Supporting Action rows    21
public CLI variants       44
GUI toolbar/window rows   14
owner-bound interactions   2
CLI argument definitions  16
```

machine-readable Command Matrix的规范data/schema路径固定为：

```text
Registries/command-catalog.v1.json
Registries/preparation-groups.v1.json
Schemas/command-catalog.v1.schema.json
Schemas/result-schemas/**/*.json
Schemas/developer-support/**/*.json
```

以上路径按TRD 05 §21.1.1构成`RepositoryContractArtifactSetV1`；两个schema目录包含其下全部`.json` regular file，missing、extra contract JSON或未被本set/ImplementationContractIdentity允许依赖解析的引用均失败。`setID=commandMatrix`，`revision=matrixRevision`，聚合身份固定为：

```text
commandMatrixSHA256 = lowercase SHA-256(
  "pulsephone.command-matrix-set.v1\0"
  + repositoryCanonicalJSON.v1 RepositoryContractArtifactSetV1 bytes
)
```

`commandMatrix.sha256`只指上述aggregate hash，不得替换为任一单文件hash、文件内容直接拼接或`executionCatalogHash`。任一成员path/bytes变化必须重新生成aggregate并bump `matrixRevision`；presentation-only变化可以保持`executionCatalogHash`不变，但不能复用旧matrix revision。

公共参数 schema：

```text
normalized coordinate
  finite ASCII decimal in [0,1]; signs, whitespace and exponent notation are not accepted

NormalizedPointV1
  lexical `<x>,<y>`；locale-independent ASCII decimal；允许小数尾随零并在边界规范化
  为 canonical decimal（例如 `0.40` -> `0.4`、`1.0` -> `1`）；禁止 NaN/Inf/百分号/空分量/符号/指数记法

gesture durationMs
  integer 1...30000

bundleID
  1...255 ASCII bytes；dot-separated segments；segment [A-Za-z0-9-]；首字符字母或数字
  该约束只适用于公共命令输入；`app.list` 的 InstallationProxy 事实输出按 TRD 06 的 opaque
  identifier 合同处理，不复用本参数校验。

ipaPath
  Client 按调用 cwd 解析为 absolute standardized UTF-8 path；RuntimeWire <=4096 bytes

outputPath
  Client-local absolute standardized UTF-8 path <=4096 bytes；不进入 RuntimeWire/HelperWire/ActionLog

type text
  valid UTF-8；encoded bytes <=64 KiB

IPA upload
  AFC/installation_proxy bounded streaming；每次 read/write <=1 MiB；禁止整包读入内存
```

相对路径只在发起 Client 中解析一次。Runtime 仍按 execution-time path content 读取 IPA，不增加 copy、spool、fingerprint 或 replacement detection。

### 8.2 Client preflight 与 Runtime planning

```text
Client
  parse + normalize
  optional local preflight
  send CommandIntent
          |
          v
Runtime
  validate connection/target
  load same Catalog
  build RuntimePlanningContext
  run authoritative CommandPlanner
  produce RuntimeJobPlan / StreamSessionPlan
```

RuntimePlanningContext：

```text
DeviceFactsSnapshot
DeviceConditionSnapshot
CapabilitySnapshot
DisplayGeometrySnapshot?  # coordinate/orientation command only
```

RuntimeStateSnapshot、queue 和 active lease 不进入 Planner；它们由 Scheduler admission 处理。

Client 不发送 ResourceClaim、CandidatePlan、cleanup policy、backend payload 或 RuntimeJobPlan。

### 8.3 Candidate 与 fallback

```text
RuntimeJobPlan
  common claims
  ordered CandidatePlan[]

CandidatePlan
  routeID
  requiredCapabilityIDs[]
  preparationGroupID?
  candidate-specific claims
  executorOperationID
  typed backend payload
  cleanup contract
  fallback disposition
```

自动 fallback 仅在：

```text
commitState = notCommitted
+ fallbackDisposition = safe
+ next candidate claims can be granted immediately
```

contention、timeout、transport failure、committed 或 outcomeUnknown 不触发 fallback。

### 8.4 executionCatalogHash

Runtime-relevant Catalog canonical projection使用TRD 05 §21.1.1的`repositoryCanonicalJSON.v1` exact bytes，身份固定为：

```text
executionCatalogHash = lowercase SHA-256(
  "pulsephone.execution-catalog.v1\0" + canonical projection bytes
)
```

至少覆盖：

- command ID、normalized argument schema、CompatibilityRule。
- executionShape、claims、candidate order、deadline、disconnect、cleanup、fallback。
- plannerContractVersion。
- Stream frame schema、artifact FD contract、result/error schema。

不覆盖 label、localized text、icon、tooltip、layout、toolbar order 和 release metadata。

CompatibilityRule、argument normalizer 和 Planner rule 必须序列化为：

```text
ruleID
ruleVersion
parameters
```

禁止依赖 Swift closure/function identity。无语义顺序的 map/set/集合按 ASCII byte order 稳定排序；candidate/fallback 等有语义顺序数组保持声明顺序。仅 declaration order 变化不得改变 hash，执行语义变化必须改变 hash；静态字段未变化但 Planner 语义改变时必须 bump `plannerContractVersion`。

第一阶段不定义 presentation hash。`releaseGateScope`、Help summary/example等presentation和 release evidence 不进入executionCatalogHash；但它们仍属于CommandCatalog canonical bytes及`ImplementationContractIdentityV1.commandMatrix`的受控投影。capability removal 若改变 command presence、CompatibilityRule、argument/execution/result contract，仍必须改变 executionCatalogHash。CI 保存 canonical projection 和 expected lowercase 64-hex SHA-256 fixture。

### 8.5 Static CLI Help definition

公开Help和`catalog.commands`必须消费CommandCatalog中的同一组CLI定义，不允许再维护独立的`commandTokens`、Help命令表或公开command ID数组作为事实源。

每个`exposures`包含`cli`的Product Action必须具有受控Help presentation：

```text
CLIHelpPresentation
  commandPath             # button home / runtime status / logs clear ...
  groupID
  summary
  examples[]

cliVariant
  继续定义Catalog既有variant/selector投影，不负责推导命令命名空间
```

参数不在每个命令重复保存。Catalog持有有界、按`argumentSchemaID`唯一的`CLIArgumentDefinition`：

```text
argumentSchemaID
options[]:
  spelling                # --udid / --x / --force ...
  valueName?              # UDID / NUMBER / PATH ...
  required
  repeatable=false
  summary
  constraint?             # 受控短文案；不得包含运行时状态
```

parser、top-level Help、single-command Help和`commands`descriptor都从该definition取得option spelling、required/optional和约束。全局`--json`由唯一global option definition提供；Help本身是human presentation，不生成Product Action JSON envelope，machine consumer使用`commands --json`。

兼容说明不得存储逐命令重复句子。renderer读取Product Action绑定的`CompatibilityRule`、`deviceRequired`、`minimumOSMajor`、`maximumOSMajorExclusive`和`transportIDs`；分段支持再读取该action已绑定的ordered candidate/preparation group集合。每个support variant只能引用当前action已绑定的candidate/preparation identity，OS范围从被引用preparation group的CompatibilityRule派生。这样`app.launch`可稳定投影modern与conditional legacy两段，而不能由commandID或candidate名称猜测。

Catalog loader必须验证：

- 39个公开CLI variant全部有Help presentation，且不存在额外Help row。
- 每个引用的argument schema都有exactly one CLI argument definition；未公开GUI-only schema不要求CLI definition。
- Help presentation的显式command path与parser token一一闭合；不得根据commandID或不完整`cliVariant`猜命名空间。共享path的variant只允许由已声明selector option区分，例如`runtime status`的`--udid`和`logs clear`的`--all`。
- support variant引用只落在当前Product Action的policy bindings内，且其OS/transport事实可由引用的CompatibilityRule重算。

`catalog.commands`的既有`catalogCommandListResult.v1`保持immutable。完整descriptor使用新的result schema，至少返回Catalog matrix revision、command ID、cli variant/path、argument schema/options、summary/group/example和结构化compatibility/support variants；human `commands`可复用top-level Help的稳定表格投影。

## 9. 五类执行形态

### 9.1 总览

```text
product action
     |
     +-- local -----> Client local handler / FactsProbe
     |
     +-- control ---> Runtime control plane
     |
     +-- oneShot ---> Planner -> PreparationWaitRegistry? -> Scheduler -> Executor
     |
     +-- stream ----> Planner -> StreamSession -> Frame delivery
     |
     +-- hybrid ----> Client orchestrates existing substeps
```

RuntimeKernel 的执行原语只有：

```text
control plane
OneShotJob
StreamSession
```

不存在 HybridJob 或 HybridPlan。

### 9.2 local

- 在 Client 完成。
- 不生成 RuntimeJobPlan，不进入 Scheduler。
- 默认不启动 Runtime。
- LocalDeviceFactsProbe 是唯一 local device I/O 例外。

### 9.3 control

- 读取或修改 Runtime 自身状态。
- 不进入 DeviceScheduler，不调用 device Executor。
- state check/commit 由 RuntimeCoordinationActor 完成。
- 外部文件 I/O 使用短期 `controlMutation` inhibitor。
- `device.prepare` 是受控的 preparation control：它注册 `PrepareDemand/PrepareObserver`，不创建 OneShotJob、不进入 CommandQueue；内部 `PreparationAttempt` 只在 device phase 以 preparation claimant 身份进入 Scheduler。

### 9.4 oneShot

- 有限设备操作。
- Runtime 权威 planning/admission。
- accepted 后可以 pending 或 running。
- 产生一个 terminal result。
- accepted 后 Client EOF 不自动取消。

### 9.5 stream

- owner-bound 实时 interaction。
- open 后传送有序或 latest-wins frame。
- ResourceLease 覆盖 session 生命周期。
- owner EOF、focus loss、watchdog 或 absolute max 触发 cancelAndClean。
- 实时 open fail fast，不进入 pending。

### 9.6 hybrid

- Client 编排多个 local/control/oneShot/stream 子步骤。
- rootActionID 与 childActionID/parentActionID 建立关联。
- Runtime 只记录兼容子步骤，不知道整体 HybridJob。
- Client 形成最终 aggregate result。

## 10. DeviceScheduler

### 10.1 ResourceClaim

```text
ResourceClaimTemplate  Catalog 静态模板
ResourceClaim          Planner materialized claim
ResourceLease          Scheduler grant 后的运行时所有权
```

Runtime 只理解：

```text
shared key
exclusive key
```

Developer Support 使用下列稳定 key；Scheduler 仍不解释其业务含义：

```text
device.developer-environment
service.mobile-image-mounter
executor.generation-control.<routeID>
```

网络下载、hash、解压和 cache prune 不申请 device ResourceLease。

RuntimeKernel 不解释 `device.app-state`、`service.installation` 等名字的业务含义。

### 10.2 Admission

```text
all claims free and no earlier conflicting waiter
  -> atomically grant all leases -> running

conflict + failFast Stream
  -> resourceBusy

conflict + finite accepted OneShot
  -> pending queue
```

多资源 lease 必须 all-or-nothing，不允许持有一部分后等待。

### 10.3 公平性

- 同一冲突域按 enqueueSequence FIFO。
- 资源完全不相交的后到 job 可以越过。
- 某资源存在更早 exclusive waiter 后，新的 shared claimant 不得插队。
- preferred candidate 仅因资源忙时不切换 backend。
- pending OneShot 无默认 queue deadline。

```text
earlier waiter: exclusive R
       |
       +---- later shared R must wait

later job with only S, S disjoint from R
       |
       +---- may run immediately
```

### 10.4 容量

```text
pending OneShot / UDID       64
PreparationWaitRegistry total 64
```

后者是同一 Runtime 内显式 PrepareObserver 的上限；每个 entry 同时贡献 demand reference，但不重复计数。start-only demand不占 observer capacity。前者满返回 `queueFull`，后者满返回 `admissionCapacityExceeded`，并携带`capacityClass=preparationWaitRegistry, limit=64, truncated=false`。

### 10.5 accepted boundary

Product accepted 只发生在 DeviceScheduler 原子提交：

```text
planning -> pending
or
planning -> running
```

Helper `Accepted` 只是已处于 running 的 backend request 被协议层接收，不是产品 accepted boundary。

## 11. OperationLifecycle

### 11.1 OneShot 状态

```text
received
   |
   v
planning <----------------------+
   |                             |
   +--> pending -----> running -----> cleaning -----> terminal
   |
   +-----------------------------------------------> terminal
```

accepted 不是额外 state；它是 `planning -> pending/running` transition 属性。

合法 transition：

| From | To | Atomic side effects |
| --- | --- | --- |
| received | planning | assign action identity；best-effort begin event scheduled |
| planning | terminal | capability missing 时启动/加入 start-only preparation demand，并 enqueue `capabilityPreparing` remediation；not accepted；no operation inhibitor |
| planning | pending | accepted；enqueue + acquire OneShot inhibitor |
| planning | running | accepted；grant all leases + bind attempt/generation + inhibitor |
| pending | running | retain inhibitor；grant all leases + bind attempt/generation |
| received/planning | terminal | reject/cancel/remediation result enqueue；no device cleanup |
| pending | terminal | dequeue + result enqueue + inhibitor release；no backend cleanup |
| running | cleaning | freeze commitState/terminationCause；retain leases/inhibitor |
| cleaning | terminal | cleanup Ack or generation fence；result enqueue/clientGone + release leases/token |

`commitState`、`terminationCause` 和 `fencing` 是 operation/generation attributes或 barrier，不是额外 OperationLifecycle state。

### 11.2 Stream 状态

Stream 复用 OperationLifecycle，并具有内部 substate：

```text
planning -> running/opening -> running/open -> cleaning/closing -> terminal
```

open 只表示 backend session ready，不隐式发送 pointer begin 或 keyboard first frame。

### 11.3 terminal bundle

每个 operation terminal 必须在 RuntimeCoordinationActor 内原子提交：

```text
phase -> terminal
+ immutable outcome/commitState
+ reliable terminal enqueue or clientGone
+ lease release after cleanup/fence barrier
+ inhibitor release
```

ActionLog `action.terminal` 是随后 best-effort side effect，不改变 terminal correctness。

### 11.4 cleanup

OneShot running deadline或 Runtime-internal abort 后进入 cleaning。2 秒内没有 candidate cleanup Ack：

```text
set cleanupTimeout
  -> fence/retire executor generation
  -> Runtime fatal fail-stop
```

不得只释放逻辑 lease 后继续复用未知 generation。

## 12. Runtime、Executor 与 Shutdown 三维生命周期

### 12.1 所有权

```text
RuntimeCoordinationActor
  +-- RuntimeLifecycleController
  |     +-- RuntimeState
  |     +-- ShutdownInhibitorRegistry
  |
  +-- DeviceScheduler
  |     +-- OperationLifecycle[]
  |
  +-- PreparationWaitRegistry
  +-- PreparationCoordinator
  |
  +-- ExecutorRegistry
  |     +-- ExecutorGenerationController[]
  |
  +-- RuntimeConnectionRegistry
```

三维正交：

```text
operation lifecycle
executor generation lifecycle
runtime shutdown lifecycle
```

不得用一个万能状态机覆盖三者。

### 12.2 RuntimeState

```text
starting -> ready -> quiescing -> stopped
```

fatal 是 terminationCause，不新增长期 Runtime state：

```text
ready --fatal--> quiescing -> stopped(exit nonzero)
```

### 12.3 ShutdownInhibitorRegistry

token owner：

```text
live
accepted OneShot
Stream
active ReplayTrace
assetAcquisition
preparingCapability
controlMutation
cleanup
fencing
```

`StopBlocker[]` 只从 token metadata 投影，不维护第二份 blocker state。

### 12.4 ExecutorGenerationController

固定合法状态：

```text
absent -> preparing -> ready
                    -> draining -> terminating -> retired
preparing ---------------------> terminating -> retired
suspectDisconnect -> draining/terminating
```

`retired` 是 generation 终态。新需求创建 `g+1` controller，不让旧 controller 回到 preparing。

旧 generation 的迟到 completion 只结算仍绑定它的 operation，不得更新新 epoch capability/facts/geometry。

RuntimeCoordinationActor 是 phase、lease、inhibitor、quiescing 和 reliable terminal queue metadata 的共同 isolation domain。以下组合转换期间禁止 external `await`：

```text
planning -> pending/running/terminal
lease all-or-nothing grant/release
owner cancel disposition
Stream first-wins closing
terminal result reservation/enqueue/clientGone
ready -> quiescing
inhibitor acquire/release/handoff
```

actor 内先提交 stable boundary；Helper/device/socket/file I/O 在 actor 外执行；callback 必须携带 requestID/jobID/sessionID、runtimeEpoch、connectionEpoch、executorGeneration、preparationAttemptID/attemptID/deliveryAttemptID 中适用的 identity。token 不匹配的迟到 callback 只写 DiagnosticLog，不提交状态或释放新代 lease。

controlMutation 固定三段式：

```text
actor: validate ready + acquire controlMutation token + commit operation identity
  -> actor outside: perform bounded external I/O
  -> actor: validate token + commit result/enqueue/clientGone + release
```

work deadline 后 token 继续覆盖 2 秒 stabilization；不能先 release 再遗留 I/O。无法证明 stable opened/closed 状态时，原子 handoff 到 cleanup/fencing token并触发 fail-stop。若 process exit 是最终 host-I/O fence，最后 token 只允许在 `exitCommitted` 后紧邻 `_exit` 的 no-await tail release。

### 12.5 统一 quiesce 与自动 idle

manual stop、automatic idle 和跨版本 retire 共用：

```text
RuntimeLifecycleController.attemptQuiesce(trigger)
  -> atomically inspect ShutdownInhibitorRegistry
  -> non-empty: return/defer with StopBlocker projection
  -> empty: ready -> quiescing and reject new external admission/token owner
```

自动 idle 时间条件：

```text
no live
+ monotonic now - idleReferenceAt >= 10 minutes
+ inhibitor registry empty

idleReferenceAt = lastCLIActivityAt ?? runtimeReadyAt
```

RuntimeWire 接收并通过基础校验的 CLI `CommandIntent`，或接收合法 `device.prepare` control request 时更新 `lastCLIActivityAt`。prepare progress、共享 attempt 的后台推进和 terminal 投影不重复刷新。以下事件不得刷新：

```text
health / runtime status
progress / command completion
live attach/activity
Stream frame
GUI action
```

10 分钟条件已满足但仍有 inhibitor 时不丢弃工作；最后一个 token release 后立即重新尝试 idle quiesce。只要 live token 存在，即使 idle 时间已过，Runtime 也不能自动退出，并必须完成同一 UDID 的必要 reconnect capability rebuild。

StopBlocker 只允许：

```text
live runningJob pendingJob stream activeTrace assetAcquisition
preparingCapability controlMutation cleanup fencing
```

blocker 中不得包含命令参数、路径、文本或敏感 payload；未知完成时间使用 `retryWhen`，不伪造 `retryAfterMs`。

## 13. PreparationWaitRegistry 与通用准备门

Runtime `coordinatorReady` 与 capability ready 分离：

```text
coordinatorReady:
  socket、Catalog、Scheduler、Runtime state、control plane 可用

capability:
  unknown | loading | available | unavailable(reason)
```

通用门只负责登记显式 PrepareObserver 或 start-only demand，并触发/加入共享准备。DDI source、mount、TSS 和服务初始化由 TRD 03 唯一持有；普通命令不在此处等待 completion，也不在 preparation terminal 后恢复 planning。

每个 Runtime 的以下 key 最多一个 `PreparationAttempt`：

```text
runtimeEpoch + connectionEpoch + preparationGroupID
```

`preparationAttemptID` 是独立 fence。它不进入 single-flight key，也不能用 executor generation 代替；同一 connection epoch 内的新 attempt 必须让旧 callback 失效。

```text
finite OneShot needs capability
  -> start/join shared PreparationAttempt
  -> terminal capabilityPreparing remediation
  -> no Scheduler admission / no automatic replay

realtime Stream needs loading capability
  -> capabilityPreparing / fail fast
```

显式 `device.prepare` 不进入 command waiter 或 Scheduler；外部`runtime.prepareCapabilities`以 `waitForTerminal` mode 提交target，Runtime派生目标PreparationGroup，再建立epoch-bound PrepareDemand/PrepareObserver并驱动同一共享attempt。每个 observer 加入时重放最新 progress，且获得同一 terminal。attempt 的 device phase 通过 Scheduler 的 internal preparation claimant 获取 phase-scoped lease，网络 acquisition 不占设备 lease。非 DDI 且资源不相交的命令可继续执行。

finite command由权威CandidatePlan派生`epochBound` start-only demand；它返回 `capabilityPreparing` remediation，原命令没有 accepted boundary。`live` launcher 在 GUIHost/Resolver 前以 `startOnly` mode 调用 control；未 ready 时不创建 live owner。USB detach终止所有epoch-bound demand；不存在跨连接保留的 live prewarm。

Runtime generation restart 后，新的 Coordinator 从空 capability projection 开始，且它的 `connectionEpoch` 不得被误解为旧进程的
epoch。对已确定的 current connected target，可在创建 start-only demand 前执行一次 bounded
`queryMounted -> required-service warm` rehydration：只有 mounted fact 与 warm terminal 均成功，才在新 Coordinator
标记该 group ready 并继续本次 admission。eligibility receipt 仅记录历史成功资格，不是当前 readiness 的硬门槛，也不单独
表达 readiness；此路径不下载/TSS/mount，不进入 PreparationAttempt，不产生 original-command accepted boundary，也不重放命令。
未mounted、状态查询失败、service warm 失败、timeout、protocol failure 或 epoch 变化都保持 unready，返回带具体 reason 的
`capabilityPreparing` remediation，原命令不执行。物理 detach/reconnect 仍一律清除当前 projection，不得通过该规则复用旧
Helper、tunnel、service 或 command。

所有准备 phase deadline、显式 prepare Runtime-terminal wait、detach/reconnect 和 observer terminal 规则见 TRD 03 第 18 节；不存在统一 10 秒 preparation deadline。

普通 command 没有 preparation waiter。`device prepare` 的 SIGINT 由 CLI 忽略；client EOF 可移除其 observer transport，但不因单个观察者离开取消仍被其他 demand 引用的共享 attempt。USB detach 终止依赖该 connection epoch 的 device phase、observer和epoch-bound demand；host asset acquisition 可在仍有 owner 时继续，并且永远不由 progress/PID 文件推断 ownership。
