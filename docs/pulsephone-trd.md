# PulsePhone TRD

> 文档状态：第一阶段工程规范总览
>
> 基线日期：2026-07-18
>
> Command Matrix：`command-matrix.v17-20260822`
>
> Wire Registry：`wire-registry.v9-20260822`
>
> Standard Error Registry：`standard-errors.v3-20260822`
>
> Planner Contract：`planner-contract.v5-20260805`
>
> 默认交付规范：`default-product-delivery.v1-20260722`

## 1. 文档定位

PulsePhone TRD 是一个逻辑文档域，由本总览、规范术语和九个专题章节组成。本文件负责架构入口、全局不变量、章节职责、Agent 阅读路由和变更门槛；精确工程合同由对应专题章节唯一持有。

```text
pulsephone-ecosystem-architecture.md
  生态蓝图、四个模块的职责和阶段关系
                     |
                     v
pulsephone-prd.md
  PulsePhone 产品范围、公开行为和验收合同
                     |
                     v
pulsephone-trd.md
  工程总览、全局不变量和专题索引
                     |
       +-------------+-------------+
       |             |             |
       v             v             v
TRD 00...09      registries     schemas/fixtures
       |             |             |
       +-------------+-------------+
                     |
                     v
              implementation/tests
```

当前规范优先级：

```text
产品问题                       -> PRD
工程问题                       -> TRD root + owning chapter
精确 machine-readable contract -> registry/schema，必须与 TRD revision 一致
实现或测试                     -> 不得扩展上述合同
```

冲突处理：

```text
PRD 与 TRD 表述冲突
  -> 停止实现
  -> 先确认产品边界，再同步两个文档域

TRD 与 registry/schema/fixture 冲突
  -> 阻断实现或发布
  -> 同一变更更新章节、revision、fixture 和测试

实现与规范冲突
  -> 实现不构成新事实源
  -> 修改实现，或先通过规范变更流程修改文档
```

本 TRD 不记录候选方案、历史讨论或已废弃路径。所有正文均表示当前阶段唯一工程方案。

### 1.1 交付配置

运行时、目标安全、命令语义和生产装配合同始终适用。验收与证据有两种配置：

```text
Default Product Delivery (default)
  -> 可用 PulsePhone.app
  -> owner 当前可提供设备上的 exact end-to-end 结果
  -> 未提供环境记为 notTested

Optional High-Assurance Validation (explicit opt-in)
  -> Alpha/Beta/Formal release flow
  -> 长时/拔插/矩阵/签名公证/EvidenceStore/retention/hold/performance freeze
```

TRD 08 中 release-flow、stage manifest、Formal series 和 durable evidence 的机器合同继续保留，但只有 release owner 显式激活高保障配置时才成为当前交付依赖。默认配置的验收入口由 PRD §18 与 TRD 08 的 `Default Product Delivery` 小节持有。两个配置都不得放宽 `INV-001`～`INV-015` 的产品行为和安全边界。

## 2. 总体架构

第一阶段采用：

```text
Shared Command Catalog
+ Runtime authoritative CommandPlanner
+ Generic RuntimeKernel
+ per-canonical-UDID RuntimeProcess
+ Swift Backend Adapter
+ bundled Go Direct/CoreDevice Helpers，保持 HelperWire/FactsProbeWire 合同稳定
```

运行拓扑：

```text
+------------------------------------------------------------------+
| Client Layer                                                     |
| CLI / AppKit GUI / local hybrid orchestration                    |
+-------------------------------+----------------------------------+
                                |
                     RuntimeWire|GUIHostWire
                                |
+-------------------------------v----------------------------------+
| Shared Pure Contracts                                            |
| identity / catalog / planner / availability / wire / host paths |
+-------------------------------+----------------------------------+
                                |
+-------------------------------v----------------------------------+
| per-UDID DeviceRuntimeProcess                                    |
| coordination actor / scheduler / lifecycle / capability gate     |
| executor generations / control plane / action history            |
+-------------------------------+----------------------------------+
                                |
                       Executor | HelperWire
                                |
+-------------------------------v----------------------------------+
| Backend Adapters and Helpers                                     |
| CoreDeviceExecutor -> CoreDeviceHelper                            |
| DirectExecutor     -> DirectHelper                                |
+-------------------------------+----------------------------------+
                                |
                                v
                           USB iPhone

Independent media path:
GUIHostProcess -> AVFoundation/CoreMediaIO -> iPhone video/audio
```

RuntimeKernel 的稳定执行原语只有：

```text
control plane
OneShotJob
StreamSession
```

`local` 在 Client 完成，`hybrid` 由 Client 编排既有原语；二者都不形成新的 Runtime job 类型。

## TRD 文档域导航

| 章节 | 全局节号 | 唯一职责 |
| --- | --- | --- |
| [TRD 00 - 规范术语](pulsephone-trd/00-normative-terminology.md) | - | process/command/lifecycle/DDI术语和旧称禁用；不持有行为合同 |
| [TRD 01 - 平台、进程与身份](pulsephone-trd/01-platform-process-and-identity.md) | 3～7 | 平台、bundle、模块、进程、canonical identity、target、availability |
| [TRD 02 - Command、调度与生命周期](pulsephone-trd/02-command-runtime-and-lifecycle.md) | 8～13 | Catalog、Planner、五种 shape、Scheduler、三维 lifecycle、PreparationWaitRegistry |
| [TRD 03 - Developer Support 与准备](pulsephone-trd/03-developer-support-and-preparation.md) | 14～18 | Catalog/AssetStore、DDI/TSS、single-flight、PreparationAttempt和deadline |
| [TRD 04 - Runtime 监督与恢复](pulsephone-trd/04-runtime-supervision-and-recovery.md) | 19～20 | Runtime singleton/generation、orphan、USB detach/attach、fatal fail-stop |
| [TRD 05 - IPC、Helper 与 Probe](pulsephone-trd/05-ipc-helper-and-probe.md) | 21～24 | Runtime/GUIHost/Bootstrap/Helper/FactsProbe Wire 和 Helper generation |
| [TRD 06 - 产品执行与 Client](pulsephone-trd/06-product-execution-and-client.md) | 25～28 | 47 个 Product Action、21 个 Supporting Action、input、GUI、CLI |
| [TRD 07 - Artifact、可观察性与安全](pulsephone-trd/07-artifacts-observability-and-security.md) | 29～34 | PNG ArtifactFD、host path/cache、日志、结果/错误、hard cap、安全与隐私 |
| [TRD 08 - 交付与验证](pulsephone-trd/08-delivery-and-verification.md) | 35～42 | 分发、许可证、release gate、性能、目录、实施与验证矩阵 |
| [TRD 09 - Current-Viewport Element Snapshot](pulsephone-trd/09-element-current-viewport.md) | 43～48 | SnapshotFrame、capture provider、并行视觉 analyzer、融合/矫正、结果与生命周期 |

全局节号 1～48 在整个 TRD 文档域内唯一。专题章节之间可以引用节号，但不能复制另一个章节拥有的精确规则。

## 全局不变量

以下不变量跨越所有专题章节，任何实现都不得局部放宽：

| ID | 不变量 |
| --- | --- |
| `INV-001` | 目标 canonicalUDID、Runtime target、Helper raw transport identity 和 GUI video binding 必须可证明一致；无法证明时 fail closed。 |
| `INV-002` | 同一 canonical UDID 同时最多一个 Runtime generation owner；不同 UDID 的故障互相隔离。 |
| `INV-003` | Client 只做本地 preflight；OneShot/Stream 的 authoritative planning、admission、route 和 lease 均在 Runtime。 |
| `INV-004` | 每个 actionID 最多一个 begin 和一个 terminal；hybrid root/child 使用独立 ID 和 parent linkage。 |
| `INV-005` | 第一阶段不自动重试 mutating command，不重放 crash/断连前 accepted work，不提供跨连接 terminal recovery。 |
| `INV-006` | 所有 IPC payload、queue、rate、artifact、fan-out、deadline 和 cleanup 都有 hard cap；不能以扩容或无限等待处理饱和。 |
| `INV-007` | operation、executor generation 和 Runtime shutdown 分属三个生命周期；cleanup、token release 和 fencing 各自 exactly once。 |
| `INV-008` | LocalDeviceFactsProbe 是 Client 直接启动 Helper 的唯一设备 I/O 例外，并且只能执行严格只读 allowlist。 |
| `INV-009` | AVFoundation media 与 Runtime control 独立降级；Camera/video 失败不能阻断目标明确的非视频控制。 |
| `INV-010` | epochScratch、userTempArtifact、persistentHistory、persistentBinding 和 developerImageStore 的存储生命周期不得交叉清理。 |
| `INV-011` | CommandCatalog、Wire/error registry、schemas、CLI help、GUI exposure和测试fixture必须绑定同一份已闭合、已验证的`ImplementationContractIdentityV1`及其各owner revision/hash投影；禁止全局revision或任一投影独立漂移。 |
| `INV-012` | 错目标、错帧、重复 Runtime/generation、foreign signal、敏感泄漏、重复 terminal 和无界增长始终阻断发布。 |
| `INV-013` | host DeveloperImageAsset、device image mount和Helper/tunnel/service generation是三个独立生命周期；detach不得回滚已拥有的host acquisition。 |
| `INV-014` | host acquisition和remount只允许使用immutable catalog批准的cache、selected release Xcode local hit或approved remote source；设备上已存在但来源不可映射的mount只能按`mountedUnknownUnverified`受限复用，禁止caller URL、nearest-version和任意路径。 |
| `INV-015` | asset acquisition不持有device ResourceLease；显式PrepareObserver和command waiter总量、internal demand、download并发、cache、progress和deadline全部有hard cap。 |
| `INV-016` | 高保障配置一旦显式激活，其release required set、typed runner input、evidence policy、preflight narrowing grant/final plan、performance threshold、durable store binding、held final candidate tree和stage lineage只能由冻结的machine-readable artifact及exact identity派生；caller、TODO或临场人工输入不得增删requirement、替换环境、移除product gate、放宽阈值、在flow中切换store、跨release flow复用阶段、覆盖聚合结果或替换最终发布app bytes。默认配置不隐式激活这些release-flow要求。 |
| `INV-017` | AV source identity、session-local sample presentation format、current-connection interaction geometry和AppKit window state是四个独立authority；同一sourceEpoch下合法format变化不能伪造source reconnect，presentation/geometry未收敛时坐标输入fail closed。visual normalized coordinate只表示current presentation方向；Runtime基于exact current geometry执行唯一一次orientation projection，Helper不得二次旋转。稳定windowed状态的canvas host必须与current presentation ratio完全一致，minimum/maximum resize约束必须同步裁限两轴，不得用letterbox掩盖窗口几何偏差；fullscreen和有界format过渡除外。一次live resize必须冻结presentation ratio与driver，普通同方向帧继续展示；期间出现方向变化时继续capture/format tracking但暂不展示不兼容帧，结束后一次采用最新稳定presentation。用户尚未建立windowed尺度时使用`375 pt` preferred canvas短边的compact initial reservation，用户resize时使用`320 pt` minimum canvas短边；Retina `2x`只作约值说明，points是唯一布局authority。toolbar overflow与自适应source controls必须优先于把窗口扩大到接近screen visible bounds。 |
| `INV-018` | Element snapshot 的所有 analyzer、融合、坐标和可选标注图必须绑定同一个 target/epoch/geometry/fresh SnapshotFrame；查询不得滚动、移动Accessibility focus、发送发现用输入或显示overlay，任一不确定性fail closed或显式降级。 |

核心安全闭环：

```text
discover raw identity
  -> canonicalize and collision check
  -> select exact target
  -> connect per-target Runtime
  -> HelloAck canonical target assertion
  -> Runtime revalidates current raw mapping
  -> Helper generation bound to Runtime target
  -> GUI frame bound to target + connection/source epoch

any mismatch
  -> no fallback to another target
  -> protocol failure or capability unavailable
  -> cleanup/fence as required
```

## 合同所有权与依赖

专题依赖必须保持单向：

```text
TRD 01 foundations
  +-> TRD 02 command/lifecycle
  +-> TRD 03 developer support/preparation
  +-> TRD 04 runtime supervision
  +-> TRD 05 ipc/helper/probe

TRD 02 command/lifecycle
  +-> TRD 03 developer support/preparation
  +-> TRD 04 runtime supervision
  +-> TRD 06 product execution

TRD 03 developer support/preparation
  +-> TRD 04 runtime supervision
  +-> TRD 05 ipc/helper/probe
  +-> TRD 06 product execution
  +-> TRD 07 artifact/security

TRD 04 runtime supervision
  +-> TRD 05 ipc/helper/probe
  +-> TRD 06 product execution

TRD 05 ipc/helper/probe
  +-> TRD 06 product execution
  +-> TRD 07 artifact/security

TRD 06 product execution
  +-> TRD 08 release verification

TRD 07 artifact/security
  +-> TRD 08 release verification

TRD 01/02/04/05/06/07 foundations
  +-> TRD 09 element snapshot
  +-> TRD 08 release verification
```

规则所有权示例：

```text
Product Action 是否存在、用户看到什么          -> PRD
Product Action 如何映射 execution profile       -> TRD 06
Scheduler fairness / lifecycle                   -> TRD 02
Developer Support / DDI / preparation             -> TRD 03
Runtime process supervision / orphan recovery    -> TRD 04
RuntimeWire message direction / DTO              -> TRD 05
Product Action execution/client                  -> TRD 06
ArtifactFD content/path/security                  -> TRD 07
如何证明上述行为已经实现                         -> TRD 08
```

## Agent 阅读路由

Agent 不应默认加载整个 TRD 文档域。开始任务时先读取本总览，再按变更面读取最小章节集合：

| 任务 | 必读文档 |
| --- | --- |
| 修改产品入口、CLI grammar、GUI 行为 | PRD + TRD 06；涉及底层机制时再读 owning chapter |
| 新增或修改 command/candidate/resource | PRD Action row + TRD 02 + TRD 06 |
| 修改 Developer Support、DDI、TSS、cache 或 preparation | PRD 10 + TRD 02 + TRD 03；Wire读TRD05，路径读TRD07 |
| 修改 Runtime/Scheduler/cleanup/stop | TRD 02 + TRD 04；涉及preparation再读TRD03 |
| 修改 Wire、Bootstrap、Helper、FactsProbe | TRD 01 + TRD 05；Runtime supervision 另读 TRD 04；FD/路径另读 TRD 07 |
| 修改 Screenshot、日志、trace、diagnostics | PRD 对应行为 + TRD 06 + TRD 07 |
| 修改 Element snapshot、视觉 analyzer、融合或坐标 | PRD 8.9 + TRD 09；命令读TRD02/06，Wire/FD读TRD05/07 |
| 修改 bundle、签名、目录、发布或性能 | TRD 01 + TRD 08；DeveloperImages路径另读TRD03/07 |
| 修改生态模块关系或阶段路线 | ecosystem；若改变 PulsePhone 产品边界，再同步 PRD/TRD |

读取到引用的 contract owner 时，以 owner 章节为准；摘要和调用方章节不得覆盖 owner。

## 变更流程

任何规范或实现变更按以下顺序处理：

```text
identify affected product action / feature / invariant
  -> update PRD when user-visible contract changes
  -> update exactly one owning TRD chapter
  -> update command/wire/error/schema revision when applicable
  -> regenerate or validate fixtures
  -> update unit/integration/device/performance evidence
  -> run cross-document coverage and contradiction checks
```

完成定义：

- 不存在未注册 public command、GUI action、Runtime operation、Helper message 或 error code。
- 每个 Product Action 有唯一 TRD 06 row、适用 execution profile 和 release scope。
- 每个 Supporting Action 有明确 parent/caller，不形成隐藏产品入口。
- 每个精确常量、enum、deadline 和 hard cap 只有一个 owner。
- 所有引用链接有效，代码块配对，规范 revision 与 fixture hash 一致。
- 受影响的 T-001～T-021 验证项具有实现或明确的未通过状态，不能静默省略。

## 覆盖基线

第一阶段规范域必须持续满足：

```text
Product Actions                 47
Supporting Actions              21
public CLI variants              39
non-command product features     6
Runtime operations              19
transport registries             5
command-matrix catalog registry  1
error/developer/group registries 3
known evidence boundaries       11
release verification groups     21
```

这些计数是完整性下限，不是新增入口的许可。任何增删都必须同时更新 PRD、TRD 06、适用 registry/schema、TRD 08 验证矩阵和 revision。
