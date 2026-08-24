# PulsePhone TRD 00 - 规范术语

> 文档状态：第一阶段规范术语表
>
> 上级文档：[`pulsephone-trd.md`](../pulsephone-trd.md)
>
> 边界：本章只定义名称、职责边界和 owning chapter，不复制状态机、deadline、Wire字段或实现步骤。

## 使用规则

- 正文、registry、schema、代码和测试优先使用本章名称。
- `DeviceRuntimeProcess` 可简称 `RuntimeProcess`；`RuntimeHost`、`DeviceRuntime daemon` 为禁止旧称。
- 术语的精确行为以 owning chapter 为准；本章不形成第二事实源。

## 进程与所有者

| Term | Definition | Owner |
| --- | --- | --- |
| `ClientProcess` | 一次CLI调用或GUI所在前台进程；拥有本地参数解析、AppKit/AVFoundation状态和展示。 | TRD 01/06 |
| `DeviceRuntimeProcess` / `RuntimeProcess` | 每个canonical UDID最多一个的后台协调进程；按需启动、空闲退出。 | TRD 01/04 |
| `HelperProcess` | 执行设备协议的受监督进程总称；不拥有产品queue、Catalog或ActionLog。 | TRD 05 |
| `CoreDeviceHelperProcess` | 执行iOS 17+ personalized DDI、tunnel/RSD/RemoteXPC/CoreDevice协议的Helper。 | TRD 03/05 |
| `DirectHelperProcess` | 执行usbmux/Lockdown/mobile_image_mounter/installation/legacy service的Helper。 | TRD 03/05 |
| `GUIHostProcess` | 长期GUI、TCC owner和AVFoundation media owner。 | TRD 01/06 |
| `AssetAcquisitionOwner` | 持有host-wide asset-store lock和目标asset exclusive lock的唯一下载Runtime。 | TRD 03 |

## Command 与执行

| Term | Definition | Owner |
| --- | --- | --- |
| `CommandDescriptor` | commandID、schema、exposure、compatibility和ExecutionPolicy的静态定义。 | TRD 02/06 |
| `CommandCatalog` | 全部CommandDescriptor的唯一集合。 | TRD 02 |
| `CommandIntent` | Client对目标设备发起的一次高层command请求。 | TRD 02/05 |
| `ExecutionPolicy` | executionShape、candidate、resource、queue、deadline、cleanup和owner规则。 | TRD 02 |
| `CompatibilityRule` | 只依据稳定DeviceFacts判断静态兼容的纯规则。 | TRD 02 |
| `CommandPlanner` | 根据Intent和RuntimePlanningContext生成权威plan的纯组件。 | TRD 02 |
| `CandidatePlan` | 一个候选route的capability requirement、preparation group、claims和backend payload。 | TRD 02 |
| `RuntimeJobPlan` | 有限OneShot command的不可变权威执行计划。 | TRD 02 |
| `StreamSessionPlan` | realtime interaction的不可变打开、buffer和cleanup计划。 | TRD 02 |
| `DeviceScheduler` | 统一ResourceLease仲裁、OneShot queue和Stream admission。 | TRD 02 |
| `CapabilityGate` | capability未ready时保存尚未accepted finite command的bounded waiter机制。 | TRD 02/03 |
| `PreparationWaitRegistry` | CapabilityGate waiter和显式PrepareObserver的统一bounded registry。 | TRD 02/03 |
| `ResourceClaim` | Planner或PreparationGroup解析出的shared/exclusive逻辑资源请求。 | TRD 02 |
| `ResourceLease` | Scheduler实际授予job、stream或PreparationAttempt的资源所有权。 | TRD 02 |

## Runtime 与代际

| Term | Definition | Owner |
| --- | --- | --- |
| `coordinatorReady` | Runtime socket、Catalog、Scheduler、state和control plane可接收外部请求；不表示设备capability ready。 | TRD 02/04 |
| `runtimeEpoch` | 一次RuntimeProcess generation；Runtime重启即变化。 | TRD 01/04 |
| `connectionEpoch` | 同一Runtime中目标设备的一次USB attachment generation。 | TRD 01/04 |
| `executorGeneration` | 一次受监督Helper/tunnel/service generation。 | TRD 02/04/05 |
| `attemptID` | 一次Scheduler/Executor执行尝试token。 | TRD 02/05 |
| `preparationAttemptID` | 同一connectionEpoch/group内一次PreparationAttempt token。 | TRD 03 |
| `ShutdownInhibitorRegistry` | Runtime quiesce的唯一blocker owner；不维护平行busy布尔值。 | TRD 02 |
| `live owner` | 同一UDID唯一GUI live交互所有者；同时持有live inhibitor。 | TRD 01/06 |

## Device 状态

| Term | Definition | Owner |
| --- | --- | --- |
| `DeviceFactsSnapshot` | OS/build、product type、device class、USB transport等连接代稳定事实。 | TRD 01 |
| `DeviceConditionSnapshot` | connected、trust、lock、Developer Mode readiness等动态条件。 | TRD 01 |
| `CapabilitySnapshot` | 当前连接代的动态capability事实和preparation state。 | TRD 01/03 |
| `DisplayGeometrySnapshot` | orientation、logical size和geometryRevision。 | TRD 01 |
| `RuntimeStateSnapshot` | queue、lease、operation、generation、inhibitor和last error的bounded projection。 | TRD 01/05 |

## Developer Support 与 DDI

| Term | Definition | Owner |
| --- | --- | --- |
| `Developer Support` | 产品术语；为特定设备开放目标developer service所需的approved asset、mount和connection service准备。 | PRD 10 / TRD 03 |
| `DDI` | Developer Disk Image的统称；是运行时developer service前提，不是仅供开发学习的资料。 | TRD 03 |
| `classic DDI` | iOS 14～16使用的DeveloperDiskImage.dmg和signature pair。 | TRD 03 |
| `personalized DDI` | iOS 17+使用的Image、BuildManifest和trust cache集合。 | TRD 03 |
| `DeveloperImageCatalog` | 随app发布的immutable approved source/hash/compatibility metadata。 | TRD 03/08 |
| `DeveloperImageAssetStore` | 负责source解析、下载、校验、解压、cache、lock和prune的Runtime模块。 | TRD 03/07 |
| `DeveloperImageAsset` | catalog验证后的immutable classic或personalized host asset。 | TRD 03 |
| `AssetAcquisitionTask` | 与device connection独立的host asset获取任务；可以在detach后继续。 | TRD 03 |
| `DemandSpec` | Runtime从explicit prepare、finite command或live prewarm派生的内部准备需求；Client不能提交group或origin。 | TRD 03 |
| `DemandPersistence` | 准备需求的连接代策略：`epochBound`或`persistentAcrossReconnect`。 | TRD 03/04 |
| `PrepareDemand` | `DemandSpec`在PreparationCoordinator中的有界owner reference。 | TRD 03 |
| `PrepareObserver` | 显式device.prepare请求的progress/terminal订阅；不是普通command waiter。 | TRD 03/05 |
| `PreparationAttempt` | 每device/connectionEpoch/group唯一的权威设备准备状态机。 | TRD 03 |
| `PreparationGroup` | produced capabilities、image requirement、service probes、claims和deadline的静态定义。 | TRD 03 |
| `mobile_image_mounter` | 查询、上传和mount developer image的设备service。 | TRD 03/05 |
| `TSS` | Apple personalization service；仅personalized mount需要时访问。 | TRD 03 |
| `ApImg4Ticket` | TSS依据当前设备personalization inputs生成的临时ticket；不持久化。 | TRD 03 |
| `RSD` | Remote Service Discovery；iOS 17+ tunnel后的service discovery层。 | TRD 03/05 |
| `RemoteXPC` | iOS 17+ tunnel/RSD路径中的远程XPC通信层。 | TRD 03/05 |
| `mountedUnknownUnverified` | service probe成功但mounted image来源无法映射；只可当前connectionEpoch使用，不计release evidence。 | TRD 03/08 |
| `DeveloperSupportProvenance` | preparation结果的来源判定：`approved`或`mountedUnknownUnverified`。 | TRD 03/05/08 |

## Artifact 与可观察性

| Term | Definition | Owner |
| --- | --- | --- |
| `ActionLog` | best-effort产品动作历史；不是强一致审计或可靠回放源。 | TRD 07 |
| `ReplayTrace` | 用户显式启停的临时语义操作轨迹。 | TRD 07 |
| `DiagnosticLog` | 脱敏技术诊断输出；显式session时写有界临时文件。 | TRD 07 |
| `PreparationProgressV1` | preparation phase和bounded byte progress的Wire projection。 | TRD 05 |
| `PreparationResultV1` | explicit prepare的唯一Wire terminal DTO。 | TRD 05 |
| `PreparationStatusV1` | runtime status/live observation共用的bounded Wire projection。 | TRD 05 |

## Verification 与 Release Evidence

| Term | Definition | Owner |
| --- | --- | --- |
| `repositoryCanonicalJSON.v1` | registry、schema、fixture/evidence manifest等repository contract document共用的strict exact-byte JSON profile；不要求普通Wire payload使用canonical形态。 | TRD 05 |
| `RepositoryContractArtifactSetV1` | 以normalized repository-relative path与exact file digest聚合一个owner-defined多文件contract set的canonical identity projection。 | TRD 05 |
| `AppBundleContentManifestV1` | 对`.app`内normalized path/type/mode/file bytes/safe symlink建立的deterministic candidate identity manifest。 | TRD 08 |
| `ReleaseCandidateInputV1` | 将candidate kind、source、最终bundle content identity、implementation contract和Catalog公开投影绑定为build-profile唯一输入的canonical artifact。 | TRD 08 |
| candidate source | `ReleaseCandidateInputV1.sourceCommit`；证明被测/发布app bytes来自哪个clean source HEAD，并投影到ReleaseEvidence manifest。 | TRD 08 |
| runner source | `EvidenceRunManifestV1.runnerSource`；证明adapter/test/probe实际从哪个Git commit执行，不要求等于candidate source，M3-009 candidate producer和M3-010 reviewed assembly是两个窄equality入口。 | TRD 08 |
| `reviewedDevelopmentCandidateInput` | M3-010 legal package保存的exact development `ReleaseCandidateInputV1` file role；M3-013 fresh input除sourceCommit及派生hash/pathKey外必须与其相同。 | TRD 08 |
| `ArtifactPathKeyV1` | 由exact artifact domain与tool-owned opaque ID派生的安全working-path key；只解决objects root内定位与domain separation，不替代artifact、candidate或store identity。 | TRD 08 |
| `ImplementationGateContractArtifactSetV1` | `RepositoryContractArtifactSetV1`的专用四member实例：六Gate definition root及definition/report/source-snapshot三个schema；独立于EvidencePolicy hash。 | TRD 08 |
| `RepositorySourceSnapshotV1` | 对Gate运行时全部non-ignored HEAD差异、mode和exact bytes建立的canonical投影；`clean`恰对应空entries，task-owned zero-write可合法使用该组合。 | TRD 08 |
| `ImplementationGateReportV1` | 由tracked Gate definition机械约束owner、输入、检查、source snapshot、identity和三态outcome的统一milestone/remediation/freeze/final aggregate报告。 | TRD 08 |
| `EvidenceRunManifestV1` | 一次测试、设备、candidate或legal evidence run的immutable machine-readable结果、artifact完整性和validation状态。 | TRD 08 |
| `EvidenceStoreBindingResolverV1` | 按显式record binding打开read-only adapter；只服务pre-Alpha reviewed-input比较、flow-neutral import和prior-plan审计三个窄入口，不提供scan/failover或跨binding任意写入。 | TRD 08 |
| `EvidenceStoreV1` | 保存结构验证通过的immutable EvidenceRun、candidate tree或release stage package并通过opaque ref取回/复验的release-tooling接口；支持受限flow-neutral import，不是产品Application Support存储。 | TRD 08 |
| `EvidenceStoreRecordV1` | 将opaque store ref绑定到package kind/state、package ID、manifest hash、policy、retention和四项valid状态的immutable canonical record。 | TRD 08 |
| `EvidenceReleaseHoldV1` | 将一个store package绑定到release flow/candidate/policy并禁止retention清理的immutable hold记录。 | TRD 08 |
| `ReleaseHoldSetV1` | 从Formal provisional lineage机械派生、持久化于final stage package并精确绑定全部selected EvidenceRun与三份lineage stage manifest hold的canonical集合；caller不能提供ID或成员。 | TRD 08 |
| `EvidenceEnvironmentProfileV1` | requirement所需clean-machine、Xcode、network、path、permission等环境facet集合及其hash。 | TRD 08 |
| `EvidencePolicyArtifactSetV1` | evidence policy root、concrete release requirement shards及其owning schemas组成的tracked多文件contract set；其aggregate hash是EvidenceRun与ReleaseEvidence共用的policy identity。 | TRD 08 |
| `ReleaseRequirementV1` | 一个可进入ReleaseGateProfile的concrete case/variant及其stage、scope、environment绑定；family ID不能替代。 | TRD 08 |
| `ExecutionSuiteV1` | 为由requirement shard反向派生的member集合指定bounded generic runner；suite不重复保存membership且总结果不能替代逐requirement scenario。 | TRD 08 |
| `ScopeBindingPresetV1` | 只冻结global/host/device scope来源与partition规则的policy preset；行为适用性由SubjectSetV1持有。 | TRD 08 |
| `StageBindingPresetV1` | 用stable binding ID显式列出release stage、environment profile和scope preset tuple；多scope/多环境不靠隐式展开。 | TRD 08 |
| `SubjectSetV1` | requirement适用的exact Product Action、non-command feature、PreparationGroup和route集合；是合法`notApplicable`的机器依据之一。 | TRD 08 |
| `ApplicabilityRuleV1` | 以固定predicate判断broad OS claim或legacy OS claim是否适用；不允许自由表达式或runner本地推断。 | TRD 08 |
| `FailurePolicyV1` | 将requirement固定分类为不可移除product gate或只允许沿指定维度撤销的removable capability。 | TRD 08 |
| `EvidenceRolePolicyV1` | 冻结requirement允许由current candidate、threshold provenance或reusable legal material中的哪一种selection role闭合。 | TRD 08 |
| fixture execution profile | `syntheticContract`、`isolatedHost`或`processHarness`之一；只描述deterministic fixture runner，不等同release environment。 | TRD 08 / Verification Conventions |
| `RequirementOwnerMapV1` | concrete requirement到唯一fixture/runner task owner的实施治理映射；不进入release policy hash。 | TRD 08 |
| `RunnerAdapterV1` | concrete requirement的typed runner、external artifact input slot与oracle入口；只引用suite identity，不复制suite membership，也不允许raw shell、scan latest或自由路径。 | TRD 08 |
| `NegativeRemovalWriteGrantV1` | clean preflight在passing Alpha flow锚点和三分支source anchor上生成的exact path授权；保存repository base commit及prior-plan pointer。 | TRD 08 |
| `NegativeRemovalPlanV1` | 对removable capability执行全surface撤销的canonical结果；嵌入grant/M0-M2 reports，保存clean repository result commit，并由clean plan EvidenceRun与M3 Gate共同验证。 | TRD 08 |
| `RemovalTargetV1` | action、feature、preparation或device scope的discriminated monotone-narrowing selector；默认same-kind subtraction，唯一cross-kind operator把bounded OS claim替换为同flow证据派生的verified exact set。 | TRD 08 |
| `ImplementationContractIdentityV1` | EvidenceRun与Release manifest共用的Command/Wire/error/planner/execution/DeveloperImageCatalog identity投影。 | TRD 08 |
| `ReleaseGateScopeV1` | 一个`T-xxx`结果的exact global/host/device与公开Product Action/feature范围；以canonical projection hash参与聚合。 | TRD 08 |
| `ReleaseGateProfileV1` | 从exact EvidencePolicy、stage、scope和validated NegativeRemovalPlan确定性派生的required tuple集合；Beta/Formal同时绑定冻结performance threshold profile。 | TRD 08 |
| `EvidenceSelectionSetV1` | `run --profile`生成并持久化于stage package、对ReleaseGateProfile tuple精确列出selected scenario/store identity、multiplicity和Formal attempt ledger的canonical artifact。 | TRD 08 |
| `StageRunAttemptLedgerV1` | 从首个Formal cohort attempt开始的append-only三态journal；failed/unknown关闭series，防止跨失败挑选三轮passing evidence。 | TRD 08 |
| `StageRunAttemptLedgerWALV1` | Formal runner前后在flow durable store binding中CAS checkpoint的working journal；crash留下started时机械形成unknown，只有seal后的ledger可被selection消费。 | TRD 08 |
| `releaseStageRun` | 仅Formal稳定性/性能multiplicity cohort使用、并绑定selection/series/attempt ledger的ordinal identity；不是把整个Formal矩阵重复三遍。 | TRD 08 |
| `stageManifestID` | aggregate/finalize生成的bounded opaque stage artifact identity；Formal provisional与final必须不同。 | TRD 08 |
| `ReleaseEvidenceManifestV1` | 当前candidate、contract identity、selected EvidenceRun、exact-scope结果和公开release scope的immutable stage manifest；Formal可先形成受限provisional再finalize。 | TRD 08 |
| `releaseFlowID` | 将threshold freeze、Beta、Formal和全部release hold绑定为同一发布流程的bounded opaque identity。 | TRD 08 |
| `evidenceStoreBindingID` | EvidenceStore adapter对受控durable backend给出的非敏感opaque identity；同一release flow从Alpha开始固定且禁止自动切换。 | TRD 08 |
| `PublicReleaseScopeIdentityV1` | 只绑定proposed/released公开capability与OS scope、不包含每阶段可变化EvidenceRun provenance的canonical identity；Formal逐字段继承Beta。 | TRD 08 |
| `BroadOSCoverageV1` | 为有finite maximum的broad OS claim冻结lower/intermediate/upper三个互斥三态slot；只有passed slot含canonical representative，failed/unknown保留refs与blockers。 | TRD 08 |
| `BroadOSCoverageArtifactSetV1` | 针对一个candidate/plan/Catalog一次覆盖全部broad OS claim、records与claim exact一一对应的三态canonical集合；即使缺slot证据也生成，Beta/freeze只接受passed set。 | TRD 08 |
| `StageGateOutcomeReportV1` | 从immutable stage store record运行统一evaluator得到的deterministic三态审计投影；consumer必须重算，不能把report path当authority。 | TRD 08 |
| `FinalReleaseEvidenceGateReportV1` | 在final manifest之外绑定其store record/hold、stored selection/hold-set、held T-002 candidate tree及dist exact bytes，避免final manifest自引用并证明最终app来自store authority的canonical Gate报告。 | TRD 08 |
| `PerformanceContractIdentityV1` | performance metric registry及metrics/measurement/threshold decision/profile/approval/evaluation schemas组成的tracked contract identity。 | TRD 08 |
| `PerformanceMeasurementProfileV1` | 一轮可比较performance run的build、host、device、capture、process-set、environment和reconnect profile。 | TRD 08 |
| `PerformanceThresholdDecisionV1` | release owner对final signed candidate、最终公开scope、至少三轮已入库baseline及每条rule的scaled-integer limit/applicability作出的restricted canonical输入；原字节随freeze package持久化。 | TRD 08 |
| `PerformanceThresholdProfileV1` | 由至少三轮有效baseline生成并freeze hold的immutable scaled-integer阈值集合；External Beta与Formal共用同一flow/profile identity。 | TRD 08 |
| `PerformanceThresholdApprovalV1` | release owner对exact flow/profile/baseline集合的机器可验批准artifact；不保存人员身份。 | TRD 08 |
| `PerformanceEvaluationV1` | current candidate对冻结threshold profile逐rule重新计算后的机器结果；不能信任metrics文件中的自报passed。 | TRD 08 |
