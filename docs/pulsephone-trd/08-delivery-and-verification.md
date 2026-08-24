# PulsePhone TRD 08 - 交付与验证

> 文档状态：第一阶段规范章节
>
> 上级文档：[`pulsephone-trd.md`](../pulsephone-trd.md)
>
> 负责范围：第 35～42 节；分发与许可证、Release Gate、性能测量、项目目录、实施顺序、验证要求、事实边界和发布验证矩阵。
>
> 默认交付规范：`default-product-delivery.v1-20260722`

本章持有“如何证明已经实现”的合同，不重新定义其他章节的运行时行为。任何发布声明都必须同时满足 PRD 产品范围和本章证据门槛。

## Delivery Profile Selection

默认配置是 `Default Product Delivery`。除非 release owner 记录了显式激活决定，§36～§42 中专属于 Alpha/Beta/Formal stage、release flow、完整环境矩阵、长时稳定性、实体拔插计数、签名公证、EvidenceStore、retention、hold、performance threshold 和 final publication 的 `must/必须` 只描述 `Optional High-Assurance Validation`，不构成默认产品交付阻塞项。保留的完整配置见 [`../OPTIONAL_HIGH_ASSURANCE_VALIDATION.md`](../OPTIONAL_HIGH_ASSURANCE_VALIDATION.md)。

这项范围选择不放宽运行时行为、目标安全、错误语义、资源上限或生产装配。高保障配置未激活时，`Verification/evidence-policy.v1.json`、release requirement shards 和 M3 release-flow tooling 仍是可执行的可选 profile；不得因它们存在就自动启动旧 M3-013～M3-017 流程。

### Default Product Delivery Acceptance

默认交付必须从正式 packaging 入口构建并运行真实 `PulsePhone.app`，并在 owner 当时提供的 USB iPhone 上至少闭合：

- `live` 在产品 deadline 内打开正确 target 的生产 AppKit 窗口；
- 真实视频帧显示，画面宽高比、方向、工具栏预留和 logical geometry 一致；
- 首次在PulsePhone内Preview + Use Source确认后，关闭/重启packaged app，第二次`live`从target-local cache自动恢复同一iPhone画面；cache missing/stale/corrupt/ambiguous时保持placeholder并回退picker，Change/Clear Mapping可用；
- 窗口内 tap、drag 和适用 edge gesture 经坐标转换进入该 target 的真实 Runtime/Helper 执行链；
- 生产 toolbar、Keyboard Capture、Toggle Software Keyboard、audio、overlay、screenshot、install picker/drop 和 preparation projection 按设备 capability 正确出现、禁用或执行；
- packaged Runtime 的 availability、`command.submit`、`stream.open`、prepare、attach/detach 与 cleanup 使用真实 backend，不得以固定失败或空 catalog 冒充集成完成；
- 关闭窗口、再次启动和正常退出后，无 owner、Stream、Runtime/Helper/GUIHost endpoint 或 capture session 泄漏；
- 适用 L0～L3 自动化测试通过，并对实际设备记录 exact model/productType、OS version/build 和通过的 capability。

缺少其他设备、OS、clean host、TCC reset、签名凭据、2FA、网络矩阵或自动化 USB reconnect 环境时，默认结果为 `notTested`。`notTested` 不增加 `actuallyVerified`，也不把已经执行且失败的 case 改写为通过。

组件/model/golden test 只能证明对应组件；只有通过正式 app 入口、真实 process transport 和实际设备形成的端到端结果，才能把 GUI 或 command 标为默认产品交付完成。错误目标、错误帧、stale epoch、production stub、无法操作的画面窗口或虚假的成功结果始终阻断默认交付。

### Physical Keyboard Modifier/Chord Acceptance

当默认交付声明 Keyboard Capture 已完整支持 modifier/chord 时，至少一次最终验收必须使用实体 Mac 键盘产生真实 `keyDown`、`keyUp` 和 `flagsChanged`。Computer Use、CGEvent 注入、AppleScript、Accessibility synthetic key event 或其他软件合成键盘事件不得作为 modifier/chord forwarding 的 passing evidence；这些路径可能经过不同的 Event Tap/系统快捷键处理，或触发 `tapDisabledByUserInput`，不能证明物理输入已经按 device-first 语义进入 iPhone。

Computer Use 或其他自动化仍可用于打开 packaged app、建立设备文本焦点、聚焦 live canvas、读取 toolbar 状态、截图和观察结果；只禁止用它们生成本验收所依赖的组合键。合成 modifier/chord 可以验证 Event Tap disable、fail-closed、release-all、状态投影和恢复，但该结果必须标记为 non-qualifying forwarding evidence，不能关闭实体组合键检查。

有效人工 checkpoint 必须同时满足：

1. 使用正式 packaged、签名身份稳定且已获得 Input Monitoring 授权的 `PulsePhone.app`，目标 iPhone、Runtime connection、Keyboard Capture active 和 live canvas first responder 均已确认。
2. 设备处于可观察输入或系统动作的受控状态。至少验证一个 Shift + printable key 的修饰状态，以及一个同时被 macOS 保留、但在 iPhone 上具有可观察结果的固定 chord，例如 `Command+Space` / `Control+Space` 的输入法切换或 `Command+Tab` 的设备 App 切换。
3. 固定 chord 必须作用于 iPhone，且不得在 Mac 上打开 Spotlight、切换 Mac App、退出 PulsePhone 或关闭窗口。不得只以“Mac 没有动作”推断 iPhone 已收到事件。
4. 全部按键释放后，再输入一个无 modifier 的固定测试键或执行等价观察，证明没有残留 Shift、Command、Control 或 Option pressed state；窗口失焦、toggle关闭和 cleanup 仍符合release-all合同。
5. 验收记录包含 packaged candidate/commit、签名Team ID、Mac/macOS、设备型号与exact iOS build、Input Monitoring状态、固定case ID、设备前后结果和Mac无本地副作用结论。记录不得包含用户真实文本、任意键盘内容或敏感设备数据。

该 checkpoint 在自动化、普通键和故障恢复检查全部完成后集中执行一次，不要求开发期间持续人工值守，也不得因自动化无法合成合格事件而反复重试 Computer Use。owner 当前无法提供实体键盘操作时，该 modifier/chord row 记录为 `notTested`，主 Agent继续完成其他不依赖该证据的工作；但不得据此声明 Keyboard Capture modifier/chord 已完整验证、关闭对应 observed issue 或把该 row 计入 `actuallyVerified`。

## 35. 分发与许可证

### 35.1 Go Helper packaging

第一阶段发布包内置两个 arm64、无 cgo、标准库 Go Helper executable。发布运行不得依赖 Python runtime、Python wheels、system Python、Homebrew Python、pip 或 developer venv；构建和 CI 中保留的 Python tooling 不进入 app bundle。

```text
system Python（发布运行时）
Homebrew Python（发布运行时）
pip（发布运行时）
developer venv（发布运行时）
caller cwd
hard-coded local path
```

Go Helper 必须从 `Contents/Helpers/PulsePhoneDirectHelper` 与 `Contents/Helpers/PulsePhoneCoreDeviceHelper` 启动，并通过 regular-file、签名、架构和路径校验。Internal Alpha 可以使用开发环境；External Beta 必须 clean-machine 闭合。

### 35.2 Go protocol implementation and Developer Support

Go helper 不携带 pymobiledevice3 或其 Python dependency graph。协议实现只覆盖 PulsePhone 当前需要的窄子集；External Beta 前仍必须完成 Go toolchain/依赖、Developer Support source/use、LICENSE/NOTICE 和源码可获得性审查。TRD 不给出法律结论。

### 35.3 DDI

第一阶段 app bundle 不携带 DDI、personalization ticket 或下载产物。Runtime 使用 immutable bundled `DeveloperImageCatalogV1` 维持 execution/handshake contract。只有 bundled catalog 对当前 iOS major/build 没有 exact entry 时，Runtime 才可读取 TRD 03 §15.2.1 所定义的 owner-controlled remote catalog，作为不进入 handshake 的 acquisition extension；它不能改写 bundled catalog identity、command matrix 或已启动 Runtime 的兼容判断。

source 顺序固定为：已挂载可复用状态、受控 Application Support verified cache、通过绝对 `/usr/bin/xcode-select -p` 定位的 Apple-signed release Xcode local optimization、catalog 批准的 remote source。beta/pre-release Xcode、caller URL/path、任意复制目录、未批准第三方 cache 和 nearest-version guess 均禁止。

禁止让任意上游实现绕过 PulsePhone catalog、锁、hash、缓存和 progress 合同；禁止写入 Xcode。approved remote acquisition 只允许 TRD 03 §15.2.1 的固定 raw catalog URL 和受限 archive prefix，禁止 Tree/Contents/Search discovery API；每次 accepted entry 仍须具备 exact URL/hash/file manifest、bounded resume/fallback 和原子 publish。iOS 17+ personalization/TSS 只允许固定 Apple egress allowlist；离线仅在 mounted/reusable manifest 已满足时成功。

device image mount、目标 service probe 和所需 Helper/tunnel generation ready 共同构成 preparation Complete。来源、使用、再分发、LICENSE/NOTICE/source availability 未闭合时，精确 capability 不得发布；但受控 cache 的存在不等于 bundle redistribution。

### 35.4 Go implementation boundary

保持 CommandCatalog、RuntimeWire、HelperWire、Executor contract 稳定，仅重写 PulsePhone 实际需要的协议子集。不要 fork/copy 大型上游后长期魔改。

## 36. Release Gate

四阶段：

```text
Design Freeze -> Internal Alpha -> External Beta -> Formal Release
```

ReleaseStage 是设计/测试 metadata，不进入 Runtime state、Planner、Scheduler、Wire 或 executionCatalogHash。

失败分为 product/capability：

```text
shared safety/product invariant failure -> block stage

isolated capability failure
  -> only if exact command/feature/device class/OS/exposure can be removed
  -> revoke all Catalog/CLI/GUI/docs/help/tests
  -> rerun affected matrix
```

Packaging、Target safety、shared lifecycle、shared IPC/security、unbounded resource growth 是 product gate。

每个候选build必须输出符合TRD 05 §21.1.1 `repositoryCanonicalJSON.v1`的`ReleaseEvidenceManifestV1`：

```text
ReleaseEvidenceManifestV1:
  schemaVersion = 1
  stageManifestID                    # 1..64 byte bounded opaque ASCII
  manifestState = immutableStageResult | formalProvisional
  stageOutcome = passed | failed | unknown
  releaseFlowID
  evidenceStoreBindingID
  releaseStage
  generatedAtUTC
  sourceCommit                         # exact release candidate source, not runner source
  worktreeState = clean
  candidate{buildID,appVersion,appBundleContentHash}
  implementationContractIdentity:
    commandMatrix{revision,sha256}
    wireRegistry{revision,sha256}
    standardErrorRegistry{revision,sha256}
    plannerContractVersion
    executionCatalogHash
    developerImageCatalog{revision,hash}
  evidencePolicy{policyID,hash}
  releaseGateProfile
  releaseGateProfileHash
  evidenceSelectionSet:
    selectionSetID
    selectionSetHash
    artifactRelativePath = artifacts/evidence-selection-set.v1.json
  performanceThresholdProfile?          # full canonical profile; Beta/Formal only
  performanceThresholdProfileHash?
  performanceThresholdFreeze?:          # Beta/Formal only
    freezeEvidenceRunID
    freezeManifestStoreRef
    freezeManifestSHA256
    decisionArtifactID
    decisionArtifactSHA256
    profileArtifactID
    profileArtifactSHA256
    approvalArtifactID
    approvalArtifactSHA256
    freezeStoreRecordSHA256
    freezeHoldID
    freezeHoldAppliedAtUTC
  previousStageManifest?:               # Beta -> passing Alpha; Formal -> passing Beta
    releaseStage
    stageManifestID
    manifestStoreRef
    storeRecordSHA256
    manifestSHA256
  formalFinalization?:                  # final Formal only
    releaseHoldSetID
    releaseHoldSetHash
    artifactRelativePath = artifacts/release-hold-set.v1.json
  selectedEvidenceRuns[]:
    evidenceRunID
    manifestStoreRef
    storeRecordSHA256
    manifestSHA256
    selectionRole = currentCandidateEvidence |
                    thresholdProvenance |
                    reusableLegalMaterial
    releaseHoldID?
    holdAppliedAtUTC?
  verificationResults[]:
    requirementID
    verificationID
    scopeProjection
    scopeProjectionHash
    environmentProfileID
    environmentProfileHash
    required
    applicability = applicable | notApplicable
    outcome = passed | failed | unknown
    evidenceRunIDs[]
  proposedReleaseScopes[]
  actuallyVerifiedScopes[]
  releasedCapabilityScopes[]
  publicReleaseScopeIdentity            # full canonical PublicReleaseScopeIdentityV1
  publicReleaseScopeIdentityHash
  broadOSCoverageSet?                 # Beta/Formal only when broad claims exist
  broadOSCoverageSetHash?
  reconnectReadinessProfiles[]
```

`releaseFlowID`是1～64 byte bounded ASCII opaque ID，不得是path、URL、时间戳或mutable `current`名称。生成/验证能力由`M3-012A`实现，本次flow的实际ID和`evidenceStoreBindingID`只能由`M3-013`创建并写入Internal Alpha manifest；`M3-014`及后续阶段只从该manifest继承，禁止caller另传或重新生成。同一Alpha -> External Beta -> Formal流程内两者不可改变，`releaseFlowID`不得复用；同一durable `evidenceStoreBindingID`可以服务多个flow，它标识backend而不是per-flow namespace，所有record/checkpoint/hold仍必须携带或验证各自flow identity。Internal Alpha不得携带threshold/freeze/previous-stage对象。

`stageManifestID`只能由`release aggregate`或`release finalize`在canonical bytes形成时生成，caller不得传入。Formal provisional与final manifest必须使用不同ID；同一ID出现不同hash、同一bytes在不同flow/profile下复用ID、或finalize沿用provisional ID均fail closed。`manifestState=formalProvisional`只允许Formal、且只允许selected/final-stage release hold与dist finalization尚未闭合；它是immutable可审计输入，不是passing stage，也不能成为下一stage lineage。`formalFinalization`和hold-set artifact必须在provisional及非Formal stage省略，只允许final Formal exact各一份。`stageOutcome`必须由validator从required result重算，caller字段不具authority。

`release create-flow`输出canonical：

```text
ReleaseFlowV1:
  schemaVersion = 1
  releaseFlowID
  evidenceStoreBindingID
  createdAtUTC
```

`evidenceStoreBindingID`是当前configured durable EvidenceStore返回的1～128 byte bounded opaque ID，不含path、host、account或credential。`release create-flow`必须先验证该binding可读写，再把它与flow ID一起冻结；Internal Alpha build-profile从该artifact读取两者，External Beta从passing Alpha lineage继承，Formal从passing Beta lineage继承。后两阶段API不接受独立flow或store binding参数，同一flow禁止自动failover到另一binding。

opaque ID永远不是filesystem component。所有release/evidence tooling落盘统一使用：

```text
ArtifactPathKeyV1:
  schemaVersion = 1
  artifactDomain = releaseFlow | evidenceRunPackage | releaseStagePackage |
                   evidenceRunValidation | releaseStageValidation |
                   evidenceStoreRecord | evidenceReleaseHold |
                   releaseGateProfile | negativeRemovalWriteGrant |
                   performanceThresholdDecision | formalAttemptLedgerWAL |
                   evidenceSelectionSet | broadOSCoverageSet |
                   releaseHoldSet | stageGateOutcomeReport |
                   developmentCandidateInput | releaseCandidateInput |
                   releaseCandidateAppTree
  opaqueID

pathKey = lowercase-hex SHA-256(
  "pulsephone.artifact-path-key.v1\0"
  + repositoryCanonicalJSON.v1 ArtifactPathKeyV1 bytes
)

working root = build/evidence/objects/<64-byte-lowercase-hex-pathKey>/
```

CLI path参数只允许指向owned `build/evidence/` root内由tool派生的pathKey目录，或规范明确列出的exact `dist/`与`build/gates/*.json`输出；不能把caller提供的opaque ID直接拼接到path。创建、遍历、rename和读取必须从verified owned root使用dirfd/no-follow语义，拒绝symlink、hardlink、foreign node和escape。pathKey只解决安全定位，不提供package identity或release authority；读取后仍必须逐字段验证opaque ID、manifest hash和store record。六个`ImplementationGateReportV1` path只能由tracked definition row选择，`FinalReleaseEvidenceGateReportV1`固定写`build/gates/final-release-evidence.json`；两者都没有独立opaque ID且不占用ArtifactPathKey domain，禁止新增泛化`gateReport` domain。

任何会生成新opaque ID的命令都只接受verified owned `objects root`，不得要求caller预先给出最终path。以`release create-flow`为例：tool先在root内private temporary directory生成`releaseFlowID`和canonical `ReleaseFlowV1`，再计算`artifactDomain=releaseFlow` pathKey、原子rename到`<objects-root>/<pathKey>/release-flow.v1.json`，并在stdout返回该derived relative path；后续命令只能消费这个tool-returned path。artifact domain必须对应exact schema/用途，禁止用泛化`profile/decision/gateReport`让不同类型的相同opaque ID碰撞。store ref/record、release hold、selection、coverage set和hold set使用同一ID-first模式。TODO中的`<canonical-...-path>`均表示前序tool返回或由`artifact-path`子命令按typed domain+opaque ID计算的owned path，不授权caller任意命名。

candidate producer也服从同一规则，且三个candidate domain固定使用`opaqueID = lowercase releaseCandidateInputHash`，不引入隐藏的assembly/candidate object ID。M3-008 `package-app`先在private temp生成并验证canonical `candidateKind=developmentAssembly`输入，从其exact bytes重算hash/pathKey，再原子写入`artifactDomain=developmentCandidateInput`目录并只通过stdout返回path；`build/staging/`可以保留为assembly工作目录，但任何release/evidence CLI都不得直接消费其中的JSON。正常 `package-app` 在clean source校验后从受锁保护、ignored 的`build/package-app-build-number.v1.json`保留一个strictly increasing decimal build ID：tracked configuration的build ID只在该app version没有既有保留值时作为下限，保留值同时写入Info.plist和candidate input；更高的semantic `appVersion`自动重置build为`1`，同一新version后续只按已保留值递增，version rollback或任何state/lock形状或所有权异常均fail closed。无staging发布的cold reproducibility verifier只预览同一next build ID，不保留计数，保证其两个assembly仍是同一candidate。M3-009 `finalize-candidate`在签名、notarization和staple完成后先在private temp闭合input/tree，使用同一final input hash分别计算`artifactDomain=releaseCandidateInput`和`artifactDomain=releaseCandidateAppTree` pathKey，原子写入并在stdout同时返回两个typed path。consumer先从input exact bytes重算hash，再对file/tree分别重算domain-separated expected pathKey并验证内嵌manifest和`appBundleContentHash`；wrong domain/opaqueID、swapped path或path内bytes mutation全部失败。两者不能靠同目录、文件名或扫描`latest`建立关联；pathKey本身仍不替代candidate identity。

`developmentCandidateInput`是clean source snapshot，不是可以跨后续Git commit复用的mutable handoff。M3-008只负责实现并验证producer；M3-010先materialize并提交owner map派生的两个legal `RunnerAdapterV1`形成source closure，再从该结果clean HEAD进入只读review execution，重新执行`package-app`并把exact reviewed bytes作为唯一`reviewedDevelopmentCandidateInput` file artifact写入flow-neutral legal package。review execution开始后不得再修改tracked product、contract或adapter source。M3-013在自己的clean implementation HEAD再次执行`package-app`并由Internal Alpha入口同时取回该M3-010 legal record；continuity validator只允许`sourceCommit`和由完整input bytes派生的`releaseCandidateInputHash/pathKey`随之变化，`schemaVersion`、`candidateKind=developmentAssembly`、`candidate`三元组、完整`appBundleContentManifest`、`implementationContractIdentity`、`catalogExposedScopes[]`和`catalogExposureHash`必须逐字段相同。任一其他差异表示法律审查针对的不是当前Alpha assembly，必须回到M3-008/M3-010重建，禁止只改hash、复制旧path或由M3-013自行宣告等价。

milestone/remediation/freeze/final aggregate verification不再各自发明自由JSON。除已有专用`FinalReleaseEvidenceGateReportV1`外，六个implementation Gate共用一个tracked definition set和一个report schema：

```text
ImplementationGateDefinitionSetV1:
  schemaVersion = 1
  revision
  gates[]:                              # exactly six; sorted by gateID
    gateID = M0-900 | M1-900 | M2-900 |
             M3-010A | M3-014 | M3-900
    makeTarget
    ownerTaskID
    outputRelativePath                  # exact build/gates/*.json
    baseRequiredIdentityFields[] = implementationContract | evidencePolicy |
                                   releaseFlow | candidate | negativeRemovalPlan |
                                   negativeRemovalWriteGrant
    baseInputSlots[]:
      inputRole
      schemaRef
      cardinality = exactlyOne | zeroOrOne | oneOrMore | zeroOrMore
      locator:
        kind = fixedRelativePath | commandLineMakeVariable
        value
    baseChecks[]:
      checkID
      checkerID
      resultSchemaRef
    sourcePolicies[]:
      sourcePolicyID
      mode = clean | taskOwnedSnapshot
      pathAuthority = none | definitionAllowlist |
                      negativeRemovalWriteGrant
      allowedPathRules[]?:              # definitionAllowlist only
        kind = exactFile | directoryPrefix
        path
      pathAuthorityInputRole?           # negativeRemovalWriteGrant only
      additionalRequiredIdentityFields[]
      additionalInputSlots[]            # same shape as baseInputSlots
      additionalChecks[]                # same shape as baseChecks

RepositorySourceSnapshotV1:
  schemaVersion = 1
  gitHeadCommit
  worktreeState = clean | taskOwnedDirty
  entries[]:                             # all non-ignored paths differing from HEAD
    relativePath
    pathState = added | modified | deleted
    gitMode? = 100644 | 100755             # present regular file only
    byteLength?                          # present node only
    sha256?                              # present regular-file exact bytes only

ImplementationGateReportV1:
  schemaVersion = 1
  gateContract{revision,hash}
  gateID
  makeTarget
  ownerTaskID
  outputRelativePath
  sourcePolicyID
  sourceSnapshot                         # full canonical RepositorySourceSnapshotV1
  sourceSnapshotHash
  implementationContractIdentity?
  evidencePolicy?{policyID,hash}
  releaseFlow?{releaseFlowID,evidenceStoreBindingID}
  candidate?{buildID,appVersion,appBundleContentHash,releaseCandidateInputHash}
  negativeRemovalPlan?{planID,planHash}
  negativeRemovalWriteGrant?{grantID,writeGrantHash}
  inputResults[]:
    inputRole
    schemaRef
    artifacts[]:
      artifactSHA256
    resolutionOutcome = passed | failed | unknown
    reasonCodes[]
  checkResults[]:
    checkID
    checkerID
    resultSchemaRef
    resultSHA256
    outcome = passed | failed | unknown
  overallOutcome = passed | failed | unknown   # aggregate inputs + checks

implementationGateContractHash = SHA-256(
  "pulsephone.implementation-gate-contract-artifact-set.v1\0"
  + repositoryCanonicalJSON.v1 RepositoryContractArtifactSetV1 bytes
)

repositorySourceSnapshotHash = SHA-256(
  "pulsephone.repository-source-snapshot.v1\0"
  + repositoryCanonicalJSON.v1 RepositorySourceSnapshotV1 bytes
)

implementationGateReportHash = SHA-256(
  "pulsephone.implementation-gate-report.v1\0"
  + repositoryCanonicalJSON.v1 ImplementationGateReportV1 bytes
)
```

`Verification/implementation-gates.v1.json`是六个Gate的唯一required input/check/owner/output真源，并与definition/report/source-snapshot三个schema共同组成`ImplementationGateContractArtifactSetV1`；report的`gateContract`必须绑定该aggregate revision/hash。M0-011建立schema、codec、generator和validator。selected policy的effective identity/input/check集合固定为`base + additional` canonical union；additional只能增加，不能删除或覆盖base，重复identity/inputRole/checkID直接使definition invalid。report中的gate/target/owner/output、selected source policy、optional identity present/absent、input和check集合必须与该effective row exact一致；数组按`gateID`、`sourcePolicyID`、`relativePath`、`inputRole`、`checkID`排序且unique。每个effective input slot在report中恰有一条同role/schema result，即使实际为零也保留空`artifacts[]`；每个role只出现一次，artifact hash按ASCII排序、unique并按slot cardinality计数。`commandLineMakeVariable` locator只接受GNU Make `origin=command line`且变量名/value与definition exact；environment/file/default或额外变量均拒绝。`allowedPathRules`只允许normalized `exactFile`或以`/`结尾的非root `directoryPrefix`，rules不得重叠，每个snapshot entry必须exact命中一条；不解析glob。`worktreeState=clean`当且仅当`entries=[]`，`worktreeState=taskOwnedDirty`当且仅当`entries[]`非空；两种交叉组合均structural invalid。selected mode为`clean`只接受前者；`taskOwnedSnapshot`同时允许合法的zero-write `clean + []`和有写入的`taskOwnedDirty + non-empty entries`，后者必须覆盖全部tracked/untracked content、delete和chmod变化且只能落在definition allowlist或同次validated write grant。no-change grant因此保持clean，不伪造dirty entry。所有模式都拒绝symlink、hardlink、submodule、foreign node、漏记untracked和grant外路径。M0-900与M2-900 definition必须同时提供普通owner policy和`negative-removal-rerun` additive overlay；后者恰增加一个`negativeRemovalWriteGrant` exactly-one slot/identity、grant-to-snapshot check，并以`pathAuthorityInputRole`绑定该slot，不能减少normal checks。M3-010A/M3-014分别把plan record、freeze record/hold定义为base command-line input。每个slot row始终存在：低于最小cardinality或locator暂不可用写`resolutionOutcome=unknown`和固定reason code；已取得artifact但schema/hash/identity不符写`failed`；extra role、duplicate、超过maximum cardinality、unknown reason code或definition/report schema损坏才是structural invalid。结构合法report的`overallOutcome`机械聚合input和check outcome：任一failed则failed，否则任一unknown则unknown，否则passed；Make target只有passed才返回0，failed/unknown仍写canonical report并非零退出。dispatcher每次先在owned root安全移除旧fixed projection，再在同一repository Gate lock内捕获before snapshot、执行只读checker、捕获after snapshot；两份snapshot必须exact一致后才原子发布新report，checker写入任一non-ignored source时hard fail。若contract/definition/report schema损坏到无法形成canonical report，fixed output保持absent且命令非零，禁止遗留旧passing projection。

Implementation Gate canonical bytes不含wall-clock字段；时间只记录在TODO Timeline。相同contract/source/input/check result必须重建相同report/hash，固定`build/gates/*.json`只是可覆盖的current projection。report先在attempt的validation HEAD/worktree形成，随后governance-only close commit才回填Result/Timeline中的exact `implementationGateReportHash`；该close commit不回写或重算历史report，也不要求report snapshot等于未来HEAD。downstream只接受记录的hash、report内`gitHeadCommit/sourceSnapshot`和需要时已嵌入EvidenceStore的exact bytes，并按§36.1判断中间commit是否仅治理变化。历史不变的是这些bytes/hash，不是ignored fixed-path文件本身。

M0-001一次建立七个稳定`.PHONY` wrapper；`Scripts/implementation-gate`尚不存在时wrapper首行输出target/owner-specific stub marker并非零。M0-011创建唯一dispatcher、六Gate definition/report validator和`verify-final-release-evidence`专用路由；此后Makefile不再由Gate owner修改。缺owner checker/input时dispatcher生成canonical unknown report并非零，合同/definition自身损坏到无法形成canonical report时只允许hard failure。`M0-900/M1-900/M2-900/M3-010A/M3-014/M3-900`只补齐自己已分配的checker/input并首次产出accepted report，不“替换stub”。M0/M2 target无额外参数时只能选择normal policy；M3-010A remediation rerun必须显式成对传`GATE_SOURCE_POLICY_ID=negative-removal-rerun GATE_WRITE_GRANT=<same-grant-path>`。`verify-negative-removal`必须显式传`GATE_WRITE_GRANT=<same-grant-path> GATE_NEGATIVE_REMOVAL_PLAN_RECORD=<finalized-plan-store-record>`；`verify-threshold-freeze`必须显式传`GATE_THRESHOLD_FREEZE_RECORD=<freeze-record> GATE_THRESHOLD_FREEZE_HOLD=<freeze-hold>`。所有变量只接受GNU Make command-line origin，缺失/extra/foreign record或独立scope/flow参数一律拒绝；dispatcher从record/hold派生并重验Alpha、candidate、plan、coverage和baseline identity。M3-010A finalize还必须验证同次M0/M2 report的schema/definition/source/write-grant identity/outcome，把两份exact canonical bytes复制进NegativeRemoval EvidenceRun package并由plan artifact pointer引用；不能只信本地path或caller填入的hash。`verify-final-release-evidence`继续生成/验证专用`FinalReleaseEvidenceGateReportV1`，不再包一层平行implementation report。

六个Gate的definition row冻结为以下最小集合；`checks`中的ID解析到`Scripts/implementation-gate`内typed checker registry且每Gate非空，owner不得换名或减少：

| Gate | Source policy | Base identities | Base inputs | Base checks | Additive overlay |
| --- | --- | --- | --- | --- | --- |
| `M0-900` | `normal: clean/none`; `negative-removal-rerun: taskOwnedSnapshot/negativeRemovalWriteGrant` | implementationContract, evidencePolicy | none | `m0.repository-structure`, `m0.contract-foundation`, `m0.evidence-policy-structural` | remediation增加`GATE_WRITE_GRANT` exactly-one、write-grant identity和`m0.grant-snapshot-binding` |
| `M1-900` | `normal: clean/none` | implementationContract, evidencePolicy | none | `m1.runtime-foundation`, `m1.device-access-foundation`, `m1.full-check` | none |
| `M2-900` | `normal: taskOwnedSnapshot/definitionAllowlist`; `negative-removal-rerun: taskOwnedSnapshot/negativeRemovalWriteGrant` | implementationContract, evidencePolicy | none | `m2.product-integration`, `m2.public-surface-projection`, `m2.full-check` | normal allowlist只含`README.md` exact file、`Fixtures/product-matrix/`和`Tests/Integration/ProductMatrixTests/` prefixes；remediation增加`GATE_WRITE_GRANT` exactly-one、write-grant identity和`m2.grant-snapshot-binding`且不继承normal allowlist |
| `M3-010A` | `normal: clean/none` | implementationContract, evidencePolicy, releaseFlow, negativeRemovalPlan, negativeRemovalWriteGrant | `GATE_WRITE_GRANT`, `GATE_NEGATIVE_REMOVAL_PLAN_RECORD` exactly-one | `m3.negative-removal-plan`, `m3.remediation-gate-lineage`, `m3.full-surface-revocation` | none |
| `M3-014` | `normal: clean/none` | implementationContract, evidencePolicy, releaseFlow, candidate, negativeRemovalPlan | `GATE_THRESHOLD_FREEZE_RECORD`, `GATE_THRESHOLD_FREEZE_HOLD` exactly-one | `m3.threshold-freeze-record`, `m3.threshold-freeze-hold`, `m3.baseline-comparability` | none |
| `M3-900` | `normal: clean/none` | implementationContract, evidencePolicy, releaseFlow, candidate, negativeRemovalPlan | fixed `build/gates/final-release-evidence.json` exactly-one | `m3.final-release-evidence`, `m3.store-dist-candidate`, `m3.external-resource-closure` | none |

M2 remediation policy使用grant exact paths而不是normal directory prefixes。M0/M2 remediation reports的`sourceSnapshot.gitHeadCommit`都等于grant `repositoryBaseCommit`：非空remediation使用`taskOwnedDirty`和exact grant entries/hash，no-change使用`clean + []`；M3-010A report在plan `repositoryResultCommit`上同样使用`clean + []`。三份report只绑定同一write grant exact bytes，不共享source commit；非空变更时plan证明result是base的唯一grant-only child，no-change时两者相等。任一不一致使Gate/finalize失败。

第一阶段release/evidence canonical artifact共用以下hard cap，schema、generator和validator不得各自维护另一份数值：

| Boundary | Frozen maximum |
| --- | ---: |
| normalized repository/bundle relative path | 1024 UTF-8 bytes |
| `ImplementationGateDefinitionSetV1.gates[]` | exactly 6 |
| source policies per implementation Gate | 2 |
| base/additional identity fields per Gate policy | 8 |
| effective input slots per Gate policy | 32 |
| effective checks per Gate policy | 256 |
| `allowedPathRules[]` per Gate policy | 256 |
| `RepositorySourceSnapshotV1.entries[]` | 65536 |
| artifacts per implementation Gate input slot | 65536 |
| reason codes per implementation Gate input/check result | 32 |
| `AppBundleContentManifestV1.entries[]` | 65536 |
| `ReleaseGateProfileV1.requirements[]` | 65536 |
| `EvidenceSelectionSetV1` selected scenarios | 131072 |
| selected EvidenceRun entries across the Alpha/Beta/Formal lineage | 65536 |
| lineage release stage manifest hold entries | 3 |
| `ReleaseHoldSetV1.holds[]` total | 65539 |
| canonical `AppBundleContentManifestV1` bytes | 32 MiB |
| any other single canonical release/evidence document | 64 MiB |

parser必须在JSON解析前执行byte cap，generator必须在array展开前执行count cap，canonicalization后再次验证exact byte length。达到cap允许，超过cap统一fail closed；exact-count字段只接受该值。不得截断、分页后分别签名，或靠当前candidate规模动态放宽。`ReleaseHoldSetV1.holds[]`必须恰好等于lineage全部selected EvidenceRun的去重集合加Internal Alpha、External Beta和Formal provisional三个stage manifest；final manifest自身hold由Gate report承载，不进入该集合。M0-011必须覆盖Gate definition/source snapshot/path rule/input/check/reason数组及其余每个相关cap的`cap-1/cap/cap+1`，不能用65536 selected-run合法输入制造65539 hold时再临时放宽。

candidate bundle identity使用：

```text
AppBundleContentManifestV1:
  schemaVersion = 1
  entries[]:                         # normalized relativePath UTF-8 byte order
    relativePath
    nodeType = directory | file | symlink
    mode
    byteLength?                      # file only
    sha256?                          # file exact bytes only
    linkTarget?                      # safe relative symlink only

appBundleContentHash = SHA-256(
  "pulsephone.app-bundle-content.v1\0"
  + repositoryCanonicalJSON.v1 AppBundleContentManifestV1 bytes
)
```

manifest覆盖输入bundle的actual full tree和全部nested code/file bytes；`candidateKind=signedNotarized`时必须包含并验证`Contents/_CodeSignature/CodeResources`及nested signatures，`developmentAssembly`允许这些签名节点absent且不得冒充final candidate。两者都拒绝absolute/outside symlink、hardlink和其他node type。mtime、inode、xattr、resource fork和Finder复制顺序不进入identity；这些仍由packaging/codesign/Gatekeeper单独验证，不能用临时tar/zip bytes代替content manifest。

因此assembly阶段的pre-sign manifest只能验证generator与目录映射，不能作为最终candidate identity。dependency/license/negative-removal必须先稳定；最终`AppBundleContentManifestV1`和hash只能在所有bundle bytes完成、nested/outer signing结束后从实际候选`.app`重算。后续clean-machine、device、Beta和Formal evidence必须绑定该final identity；签名后复用旧hash一律invalid。

Release与EvidenceRun共用唯一实现合同投影：

```text
ImplementationContractIdentityV1:
  commandMatrix{revision,sha256}
  wireRegistry{revision,sha256}
  standardErrorRegistry{revision,sha256}
  plannerContractVersion
  executionCatalogHash
  developerImageCatalog{revision,hash}
```

build-profile唯一接受typed candidate input，不把`AppBundleContentManifestV1`路径误当完整release input：

```text
ReleaseCandidateInputV1:
  schemaVersion = 1
  candidateKind = developmentAssembly | signedNotarized
  sourceCommit
  worktreeState = clean
  candidate{buildID,appVersion,appBundleContentHash}
  appBundleContentManifest             # full canonical AppBundleContentManifestV1
  implementationContractIdentity       # full canonical tuple
  catalogExposedScopes[]               # full host/device public exposure projection
  catalogExposureHash

releaseCandidateInputHash = SHA-256(
  "pulsephone.release-candidate-input.v1\0"
  + repositoryCanonicalJSON.v1 ReleaseCandidateInputV1 bytes
)
```

`catalogExposureHash`按canonical `catalogExposedScopes[]`计算；数组只能从exact Command/DeveloperImage Catalog、CompatibilityRule和PRD ceiling投影，caller不能编辑。Internal Alpha只接受M3-013在自己的clean HEAD重新生成、且已通过M3-010 reviewed-input continuity验证的`developmentAssembly` input；M3-008输出只验证producer资格，不是跨commit handoff。External Beta只接受M3-009的`signedNotarized` input；Formal从Beta lineage继承。candidate三元组、content manifest/hash、source、contract或exposure任一不一致均失败。

M3-009的`T-002/signed-notarized-stapled-bundle-l5` EvidenceRun是最终candidate bytes的唯一发布来源。其package必须恰好包含一个`releaseCandidateInput` file artifact和一个`releaseCandidateAppTree` tree artifact；后者的tree manifest必须逐byte等于前者内嵌的`AppBundleContentManifestV1`，`treeContentHash`必须等于`candidate.appBundleContentHash`。M3-011、M3-014～M3-020和最终publish只能从该immutable store record取回candidate tree，不能把签名工作目录、`build/`残留或预先存在的`dist/PulsePhone.app`当authority。

三个`sha256`不是caller输入或任意single-file digest：`commandMatrix.sha256`必须等于TRD 02 §8.1的`commandMatrixSHA256`，`wireRegistry.sha256`必须等于TRD 05 §21.1的`wireRegistrySHA256`，`standardErrorRegistry.sha256`必须等于TRD 07 §32.3的`standardErrorRegistrySHA256`。validator在每次实际使用时必须从profile声明的exact source set重建对应`RepositoryContractArtifactSetV1`并逐字段比较revision/hash；member缺失、extra、unresolved reference或aggregate mismatch均使该profile invalid。

M0阶段的contract verification采用两个显式、各自fail-closed的profile：

```text
M0-011 commit
  make check -> verify-contracts-bootstrap
                current wire/error
                + versioned synthetic command/cross-set fixtures

M0-012 ... M0-017
  make check -> verify-contracts-bootstrap
  task card  -> targeted validator for the partial current-tree owner

M0-018 commit
  create first complete current-tree identity
  + atomically change tracked Makefile dependency
  make check -> verify-contracts-current

M0-900
  require verify-contracts-current + complete identity
```

`verify-contracts-bootstrap`不得auto-discover尚未完成的current command/Developer Support set，也不得因missing而skip其声明的synthetic set。`verify-contracts-current`必须验证完整current source tree，缺少任一member或cross-set closure即失败；在`M0-018`之前不得被`make check`调用。`M0-012`～`M0-017`的targeted validator只能验证任务卡声明的partial owner，不能生成或冒充完整`ImplementationContractIdentityV1`。profile选择由Git tracked Makefile依赖固定，禁止environment override、working-copy active pointer或运行时自动切换；`M0-018`在一个commit中同时完成完整set与切换，避免任何commit处于半启用状态。

cross-set reference dependency graph固定为：

```text
standardErrorRegistry -> none
wireRegistry          -> standardErrorRegistry
commandMatrix         -> wireRegistry, standardErrorRegistry
developerImageCatalog -> commandMatrix
```

同一contract file只属于一个set。reference resolver必须在同一`ImplementationContractIdentityV1`tuple中按exact target revision/hash查找schemaID、errorCode、CompatibilityRule或其他registered ID；目标set缺失、ID不存在、依赖边未允许、同一ID多义或引用另一revision均失败。cross-set target file不复制进source set，防止双重ownership和hash循环。

`evidencePolicy`单独逐字段比较；`releaseGateProfile`只属于ReleaseEvidenceManifest；reconnect profile和performance contract/threshold集合按metrics/run与release profile另行校验，不进入ImplementationContractIdentity。

Release required set与evidence治理的唯一tracked真源是：

```text
EvidencePolicyArtifactSetV1
|
+-- Verification/evidence-policy.v1.json
+-- Verification/execution-suites.v1.json
+-- Verification/release-requirements/
|   +-- T-001/<requirement-slug>.v1.json
|   ...
|   `-- T-021/<requirement-slug>.v1.json
`-- Schemas/evidence/
    +-- evidence-policy.v1.schema.json
    +-- execution-suites.v1.schema.json
    +-- release-requirement.v1.schema.json
    +-- release-flow.v1.schema.json
    +-- app-bundle-content-manifest.v1.schema.json
    +-- release-candidate-input.v1.schema.json
    +-- evidence-selection-set.v1.schema.json
    +-- stage-run-attempt-ledger.v1.schema.json
    +-- stage-run-attempt-ledger-wal.v1.schema.json
    +-- broad-os-coverage-set.v1.schema.json
    +-- public-release-scope-identity.v1.schema.json
    +-- stage-gate-outcome-report.v1.schema.json
    +-- fixture-case.v1.schema.json
    +-- evidence-run-manifest.v1.schema.json
    +-- evidence-store-record.v1.schema.json
    +-- evidence-release-hold.v1.schema.json
    +-- release-hold-set.v1.schema.json
    +-- legal-material-record.v1.schema.json
    +-- negative-removal-write-grant.v1.schema.json
    +-- negative-removal-plan.v1.schema.json
    +-- release-gate-profile.v1.schema.json
    +-- release-evidence-manifest.v1.schema.json
    `-- final-release-evidence-gate-report.v1.schema.json
```

它复用TRD 05 §21.1.1 `RepositoryContractArtifactSetV1`的normalized path、exact digest、node和missing/extra规则：

```text
setID = evidencePolicy
revision = EvidencePolicyV1.policyID

evidencePolicyHash = SHA-256(
  "pulsephone.evidence-policy-artifact-set.v1\0"
  + repositoryCanonicalJSON.v1 EvidencePolicyArtifactSetV1 bytes
)
```

EvidenceRun和ReleaseEvidence只携带`evidencePolicy{policyID,hash}`；该identity同时绑定policy root、全部concrete requirement、environment、artifact/retention rules和owning schemas，不再建立可独立漂移的第二个requirement catalog hash。

`policyID`是immutable revision，不是mutable `current`名称。set中任一member、stage binding、environment、allowlist或schema语义变化都必须生成新policyID/hash并使旧candidate evidence不能混入新profile；禁止environment override、symlink或working-copy active pointer选择policy。

Implementation Gate治理独立于release EvidencePolicy hash，使用同一artifact-set规则形成：

```text
ImplementationGateContractArtifactSetV1
|
+-- Verification/implementation-gates.v1.json
`-- Schemas/implementation/
    +-- implementation-gate-definition-set.v1.schema.json
    +-- implementation-gate-report.v1.schema.json
    `-- repository-source-snapshot.v1.schema.json
```

该set使用前述`implementationGateContractHash`，definition revision变化或任一member/schema bytes变化都会改变aggregate hash；report不得只绑定root definition文件。

`ImplementationGateContractArtifactSetV1`不是第五种自由schema，而是`RepositoryContractArtifactSetV1`的专用实例：`setID=implementationGateContract`，`revision`必须等于definition set revision，members必须exact包含`Verification/implementation-gates.v1.json`和三个`Schemas/implementation/{implementation-gate-definition-set,implementation-gate-report,repository-source-snapshot}.v1.schema.json`，不得missing/extra。aggregate hash始终按本章`implementationGateContractHash`公式覆盖该四member set的canonical bytes。

```text
EvidencePolicyV1:
  schemaVersion = 1
  policyID
  implementationEnvironmentProfileID = env.implementation.clean-source
  environmentFacets[]:
    facetID
    dimension = cleanliness | distribution | xcode | network | appPath |
                deviceTopology | developerSupportCache | tccControl |
                cameraPermission | microphonePermission |
                inputMonitoringPermission
    valueID
  environmentProfiles[]:
    profileID
    facetIDs[]                         # unique; ASCII sorted
  scopeBindingPresets[]               # full ScopeBindingPresetV1
  stageBindingPresets[]               # full StageBindingPresetV1
  subjectSets[]                       # full SubjectSetV1
  applicabilityRules[]                # full ApplicabilityRuleV1
  failurePolicies[]                   # full FailurePolicyV1
  evidenceRolePolicies[]              # full EvidenceRolePolicyV1
  currentCandidateMultiplicity:
    defaultRequiredDistinctPassingScenarioCount = 1
    cohorts[]:
      cohortID
      releaseStage
      requirementIDs[]
      requiredDistinctPassingScenarioCount
      requiredStageRunOrdinals[]
      requireConsecutiveNonOverlappingRuns
      requireSameRunnerSourceCommit
  maximumScenarioCountPerSuite = 4096
  stageRules[]:
    releaseStage = internalAlpha | externalBeta | formalRelease
    eligibleEvidenceStages[]
    candidateRequired = true                # currentCandidateEvidence
    sameCandidateRequired = true            # currentCandidateEvidence
    runnerSourcePolicy = cleanRecorded      # currentCandidateEvidence
    releaseHoldRequired
  artifactRoleRules[]:
    role
    artifactKind = file | tree
    allowedMediaTypes[]?                 # file only
    byteLengthRule:
      source = fixedPolicyMaximum | candidateManifestTotalFileByteLength
      maximumByteLength?                 # fixedPolicyMaximum only
    allowedSensitivityClasses[]
    allowedRedactionStates[]
    allowedOwnerRoles[]
  retentionRules[]:
    retentionClass
    storeClass
    minimumRetentionDays?
    manualHoldRequired
    orphanCleanupHours?
  validationRules:
    unknownFieldDisposition = reject
    unknownArtifactDisposition = reject
    forbiddenDataClassIDs[]
    requiredValidationStates[]
```

`artifactRoleRules[].role`必须唯一并冻结role到kind的映射：第一阶段只有`releaseCandidateAppTree`使用`artifactKind=tree`和`byteLengthRule.source=candidateManifestTotalFileByteLength`；其余role全部使用`artifactKind=file + fixedPolicyMaximum`。file rule把effective maximum应用于`file.byteLength`；tree rule把effective maximum应用于`tree.totalFileByteLength`。candidate tree的effective maximum恰好等于同package `releaseCandidateInput.appBundleContentManifest.entries[]`中全部file `byteLength`之和，二者必须相等；tree role省略media type，file role必须命中allowlist。role/kind不匹配、computed total不等或整数溢出使package structural invalid；固定上限或store quota无法容纳完整产物时producer outcome为`unknown`且不得生成candidate record。两类情况都禁止截断、分片或改用另一artifact role。

`reviewedDevelopmentCandidateInput`是internal file role，media/schema固定为canonical `ReleaseCandidateInputV1`，只允许M3-010 flow-neutral legal package exact一份；其`candidateKind`必须为`developmentAssembly`。它只证明法律审查输入并供M3-013/M3-010A continuity复验，不是candidate tree、不能作为`--candidate-input`直接执行、不能替代M3-009 `releaseCandidateInput`，也不能进入公开manifest。

`runnerSourceSnapshot`是internal file role，schema固定为`RepositorySourceSnapshotV1`。`runnerSource.worktreeState=dirty`时必须exact一份并由`sourceSnapshotArtifactID`引用，覆盖相对HEAD的staged/unstaged/untracked content、delete和chmod；`clean`时字段与artifact都必须absent。dirty run只供诊断，`claimEffect=none`，永不可进入Implementation Gate、release selection或法律结论。

`implementationGateReport`是internal file role，只允许canonical `ImplementationGateReportV1` media/schema和通用64 MiB document cap。普通EvidenceRun不得使用；M3-010A plan package必须恰有两份，分别由`reopenedGateResults[gateID=M0-900|M2-900].reportArtifactID`唯一引用，missing/extra/duplicate gate或hash mismatch均invalid。

`implementationEnvironmentProfileID`是M0～M2/CI implementation EvidenceRun的唯一默认环境profile，必须解析到policy中的exact profile；它计入used profile但禁止进入任一release StageBindingPreset或ReleaseGateProfile。普通requirement在每个stage/profile tuple默认只需要1个passing scenario并省略`releaseStageRun`。第一阶段唯一multiplicity cohort为：

```text
cohortID = formal.stability-performance.v1
releaseStage = formalRelease
requirementIDs = [
  T-018/performance-threshold-evaluation-l5,
  T-018/stability-stage-run-l5
]
requiredDistinctPassingScenarioCount = 3
requiredStageRunOrdinals = [1,2,3]
requireConsecutiveNonOverlappingRuns = true
requireSameRunnerSourceCommit = true
```

cohort member集合是policy真源，不允许按`T-018`前缀、title或level扩大。Formal仅对这两个exact requirement执行三轮；签名、clean-machine、法务、设备矩阵、命令和其他current-candidate requirement不因该规则重复三次。三个ordinal必须来自同一clean `runnerSource.gitCommit`，避免在series中途替换measurement/runner实现。threshold/legal role始终省略`releaseStageRun`并按其exact policy各选择一次。`stageRules`的candidate/runner-source约束只描述`currentCandidateEvidence`；`thresholdProvenance`和`reusableLegalMaterial`只能走本章随后定义的窄复用规则，不能借role绕过current requirement。

初始stage rule exact seed：

| Stage | eligibleEvidenceStages | default count | releaseHoldRequired |
| --- | --- | ---: | --- |
| `internalAlpha` | `[internalAlpha]` | 1 | false |
| `externalBeta` | `[externalBeta]` | 1 | false |
| `formalRelease` | `[externalBeta, formalRelease]` | 1 | true |

三阶段`candidateRequired/sameCandidateRequired`均为true，`runnerSourcePolicy`均为`cleanRecorded`；不存在把所有run强制到candidate source commit的通用规则。Formal复用的External Beta scenario必须已被passing previous-stage manifest选择且与当前profile逐字段同candidate/contract/policy identity；不能从其他Beta flow或未进入Beta manifest的run补选。Formal-specific requirement和上述multiplicity cohort必须使用`evidenceStage=formalRelease`。Formal provisional只延迟创建hold，不修改stage rule；finalize前仍不能称为passing Formal。threshold/legal复用只按EvidenceRolePolicy窄规则进入selection，不扩大`eligibleEvidenceStages`。

scope、stage/environment和失败处置先由policy root冻结为可复用preset，requirement shard只引用ID，禁止inline override：

```text
ScopeBindingPresetV1:
  scopeBindingID
  source = global |
           eachMatchingProposedHostScope |
           eachMatchingProposedDeviceScope
  partitionBy[] = productActionID | nonCommandFeatureID |
                  preparationGroupID | route

StageBindingPresetV1:
  stageBindingPresetID
  bindings[]:
    bindingID
    releaseStage
    environmentProfileID
    scopeBindingID

SubjectSetV1:
  subjectSetID
  selectionMode = none | allMatched | explicit
  productActionIDs[]
  nonCommandFeatureIDs[]
  preparationGroupIDs[]
  routes[]                         # values: none | classic | personalized
  applicabilityRuleID?

ApplicabilityRuleV1:
  applicabilityRuleID
  predicate = proposedDeviceOSClaimIsBroadRange |
              proposedDeviceOSClaimIntersectsLegacy14To16

FailurePolicyV1:
  failurePolicyID
  failureDisposition = productGate | removableCapability
  allowedRemovalDimensions[] = action | feature | preparationGroup |
                               route | deviceClass | osRange
  requireCompleteSurfaceRemoval

EvidenceRolePolicyV1:
  evidenceRolePolicyID
  allowedSelectionRoles[] = currentCandidateEvidence |
                            thresholdProvenance |
                            reusableLegalMaterial
```

`ScopeBindingPresetV1`只决定global/host/device来源和partition，不持有行为适用性。`SubjectSetV1`是requirement的exact subject/route真源：`none`要求全部数组为空；`allMatched`从对应proposed scope继承且数组为空；`explicit`至少包含一个exact ID/route。数组按ASCII排序，未知ID失败。`ApplicabilityRuleV1`只允许上述固定predicate enum，不提供表达式、脚本或caller参数；第一条只匹配`claimKind=broadVersionRange`，第二条只匹配与`[14.0,17.0)`相交的device OS claim。`notApplicable`只能由subject set/applicability rule或owner-defined OS matrix证明。`StageBindingPresetV1.bindings[]`按`bindingID` ASCII排序；`bindingID`和`releaseStage + environmentProfileID + scopeBindingID`tuple都必须唯一。多scope或多environment通过多个binding明确表达，禁止隐式笛卡尔积。

跨host/device的同一oracle必须使用一个显式列出全部scope kind的StageBindingPreset。profile generator对每个explicit subject检查scope coverage：任一公开subject没有可生成的native scope tuple、或生成了subject之外的tuple都fail closed。第一阶段公开CLI human/JSON与budget/SIGINT使用`stage-bind.host-device-action-bf.v1`。aggregate partial outcome是host aggregate command的一条scenario，在`env.release.multi-device-online`中验证typed per-device subresults，使用`stage-bind.host-multi-target-bf.v1`；它不额外生成device-scope requirement tuple，也不得退化为只覆盖device action的preset。

初始failure policy至少包含：

```text
failure.product.v1
  -> productGate; removal dimensions = []; requireCompleteSurfaceRemoval=false

failure.capability-action.v1
  -> removableCapability; [action, deviceClass, osRange]; requireCompleteSurfaceRemoval=true

failure.capability-feature.v1
  -> removableCapability; [feature, deviceClass, osRange]; requireCompleteSurfaceRemoval=true

failure.capability-preparation.v1
  -> removableCapability; [preparationGroup, route, deviceClass, osRange]; requireCompleteSurfaceRemoval=true

failure.capability-device.v1
  -> removableCapability; [deviceClass, osRange]; requireCompleteSurfaceRemoval=true

role.current-candidate.v1
  -> [currentCandidateEvidence]

role.threshold-provenance.v1
  -> [thresholdProvenance]

role.reusable-legal.v1
  -> [reusableLegalMaterial]
```

`productGate`不得因negative-removal、空scope或`notApplicable`从profile消失；环境缺失只能形成`unknown`。`removableCapability`只能沿policy列出的dimension缩小，并且`requireCompleteSurfaceRemoval=true`时必须先完成Catalog、CLI、GUI、docs、help、tests和release policy的一致撤销。

selection role必须由requirement的`evidenceRolePolicyID`精确允许：普通product/device/contract requirement只接受current candidate；threshold baseline/freeze只接受threshold provenance；legal/source material只接受reusable legal。一个scenario/run被caller标成其他role、一个role试图闭合未授权requirement或同一requirement跨role拼接时均fail closed。

每个requirement shard只描述一个concrete case/variant：

```text
ReleaseRequirementV1:
  schemaVersion = 1
  requirementID
  verificationID
  executionSuiteID
  title
  contractRefs[]
  level = L0 | L1 | L2 | L3 | L4 | L5
  caseClass = positive | negative | boundary | fault | concurrency
  stageBindingPresetID
  subjectSetID
  failurePolicyID
  evidenceRolePolicyID
  fixtureMode = required | optional | none
  fixtureCaseKey?                       # required/optional only; equals requirementID
  fixtureExecutionProfileID?            # required/optional only

ExecutionSuiteV1:
  executionSuiteID
  primaryVerificationID
  runnerID
```

实施ownership使用独立治理artifact，不把TODO task ID写入release policy hash：

```text
RequirementOwnerMapV1:
  schemaVersion = 1
  evidencePolicyID
  routes[]:
    requirementID
    fixtureOwnerTaskID?            # fixtureMode=none时 absent
    fixtureRelativePath?           # required/optional; exact derived path
    runnerOwnerTaskID
    runnerAdapterRelativePath       # exact derived path

RunnerAdapterV1:
  schemaVersion = 1
  requirementID
  executionSuiteID
  adapterKind = swiftTest | pythonTest | evidenceCommand |
                releaseStageOperation
  invocation:                         # exactly one branch matching adapterKind
    swiftTest? {testTarget,filter}
    pythonTest? {makeTarget=test-python,selector}
    evidenceCommand? {entrypointID,argumentSchemaRef}
    releaseStageOperation? {operationID}
  inputArtifacts[]?:                  # exact typed external inputs; role unique
    role
    artifactDomain
    artifactKind = file | tree
    schemaRef?                        # file only
    treeManifestSchemaRef?            # tree only
    cardinality = exactlyOne | zeroOrOne | oneOrMore
    identityBindings[] = releaseFlow | storeBinding | candidate |
                         negativeRemovalPlan | evidencePolicy
  oracleKind = fixtureExpected | testAssertion |
               evidencePredicate | releaseStagePredicate
  oracle:                             # exactly one branch matching oracleKind
    fixtureExpected? {fixtureRelativePath}
    testAssertion? {assertionID}
    evidencePredicate? {predicateID,resultSchemaRef}
    releaseStagePredicate? {predicateID}
```

path不是147条手写配置，而由requirement ID机械派生：

```text
fixtureRelativePath(requirementID)
  = "Fixtures/requirements/" + requirementID + "/"

runnerAdapterRelativePath(requirementID)
  = "Verification/runner-adapters/" + requirementID + ".v1.json"
```

`requirementID`格式已经固定为`T-xxx/<concrete-slug>-lN`且只含路径安全字符，因此上述拼接injective；禁止去掉level、再次slugify或按family猜目录。`Verification/requirement-owners.v1.json`必须与全部requirement shard形成exact一一对应，task ID必须存在于TODO且不能是milestone range表达式。`fixtureMode=required|optional`必须保存上述fixture path且`none`必须省略；每条route必须保存上述runner adapter path。normalized path必须严格等于纯函数结果、位于冻结root、无symlink/escape且全局唯一。

`RunnerAdapterV1.requirementID/executionSuiteID`必须与shard一致；adapter只描述调用、typed input和oracle入口，不维护第二份suite membership。所有identifier/filter/selector最多256 byte bounded ASCII；`testTarget`必须解析到SwiftPM test target，`argumentSchemaRef/resultSchemaRef`必须解析到tracked schema，file input恰有`schemaRef`，tree input恰有`treeManifestSchemaRef`，两者不能同时存在或同时省略；`fixtureExpected.fixtureRelativePath`必须等于同route的derived path，其他predicate/assertion ID必须解析到`Scripts/evidence-tool`或test target导出的typed registry。`evidence-tool run --input-artifact <role>=<tool-returned-path>`只能填写adapter声明的role、kind和cardinality；tool必须验证ArtifactPathKey domain、schema/manifest以及列出的flow/binding/candidate/plan/policy identity，禁止scan latest、自由role、自由argv、自由oracle path、environment injection、absolute path和caller cwd。Internal Alpha的direct build-profile input必须是M3-013在当前clean HEAD重新执行`package-app`后stdout返回的`artifactDomain=developmentCandidateInput` file，并同时显式接收M3-010 legal record完成review continuity。第一阶段RunnerAdapter typed external input固定为三类：M3-010两个legal member各声明exactly-one `reviewedDevelopmentCandidateInput` file（`artifactDomain=developmentCandidateInput`，`release-candidate-input.v1.schema.json`），run顶层candidate保持absent且package保存同bytes artifact；M3-009 candidate producer声明exactly-one `releaseCandidateInput` file（同名ArtifactPathKey domain，`release-candidate-input.v1.schema.json`）和exactly-one `releaseCandidateAppTree` tree（同名ArtifactPathKey domain，`app-bundle-content-manifest.v1.schema.json`），两者必须同时出现、与`--candidate-record`互斥、共同自证candidate并匹配flow/binding/policy；两个broad OS coverage member各声明exactly-one `broadOSCoverageSet` file（同名ArtifactPathKey domain，`broad-os-coverage-set.v1.schema.json`），该role必须与`--candidate-record`同时出现并要求releaseFlow/storeBinding/candidate/negativeRemovalPlan/evidencePolicy五项identity全部匹配。其他adapter不得声明这些role。

missing采用统一到期规则：M0-001～M0-010位于owner map/tool bootstrap之前，只使用TODO task package的explicit owned paths且不得写derived owner输出。M0-011从自身readiness row启动，在source closure内建立map/tool并对自身运行owners查询；structural profile必须写满147条route并验证task/path纯函数，只要求`runnerOwnerTaskID=M0-011`的bootstrap adapter和对应required fixture已存在，不得替future owner预建空adapter。所有M0-011 close后开始的task必须在start阶段通过owners查询领取清单。任一owner task Done时，其全部runner adapter和`#R` fixture必须存在且cross-check通过，`#O` fixture可缺但adapter不可缺。current/release-complete profile按TODO current status拒绝任何已到期owner输出缺失；Formal required set拒绝任一adapter或required fixture缺失。owner map与runner adapters只决定谁materialize fixture/runner，不改变stage、scope、environment、failure或release outcome；因此明确排除在`EvidencePolicyArtifactSetV1`之外。owner/path/adapter变更只改变implementation governance artifact，requirement语义变化仍必须bump policy。

ID规则固定为：

```text
  requirementID   = T-xxx/<lowercase-kebab-concrete-variant>-lN
  verificationID  = requirementID的T-xxx前缀
  executionSuiteID = suite.txxx.<bounded-kebab-suite>.v1
```

family ID、TODO task ID和stage名不能替代或拼入`requirementID`。同一concrete oracle通过一个StageBindingPreset中的多个stable binding复用；`M0-011`必须一次冻结当前`T-001`～`T-021`的完整concrete set，后续实现任务只能消费。若发现缺失variant，必须先进行正式contract/policy revision，禁止在test、M3 aggregator或release run中临时发明ID。

`executionSuiteID`必须解析到`Verification/execution-suites.v1.json`。suite member集合只由requirement shard的`executionSuiteID`反向派生，suite不得再维护第二份selector/member清单；allowed level集合机械等于member level union，不落第二份字段。suite只决定bounded runner，不能用一个suite总结果替代成员requirement；runner必须为每个requirement、scope和environment输出独立scenario result。suite的primary verification前缀与member requirement不一致、suite无member或expanded scenario数超过policy全局cap 4096时fail closed；cap不得按当前设备数或scope动态改变。

第一阶段21个suite的`runnerID`固定为`evidence-tool.member-dispatch.v1`，generic dispatcher由`M0-011`持有；exact scenario adapter owner只从`RequirementOwnerMapV1.runnerOwnerTaskID`读取。未来更换runner必须正式更新suite artifact/policy identity，不能由task-local参数覆盖。

policy不hash尚未实现的future fixture bytes。`fixtureMode=required|optional`时提前冻结`fixtureCaseKey=requirementID`和`fixtureExecutionProfileID`；后续task只能在该key/profile下新增符合`FixtureCaseV1`的input/expected，不修改requirement语义或policy identity。`required` fixture在其implementation task Done前必须存在且cross-check通过；`none`必须省略case key/profile且只允许真实device/legal/stability等不能由synthetic fixture充分表达的scenario。fixture exact path/hash由FixtureCase manifest和EvidenceRun artifact绑定；实际adapter/fixture执行所在Git commit只从`EvidenceRun.runnerSource.gitCommit`读取，不能从candidate source或caller当前HEAD推断。

required set确定性派生：

```text
EvidencePolicyArtifactSet
  + requested releaseStage
  + typed assembly input or stored candidate record
  + PRD ceiling + exact Catalog/public exposure
  + exact Command/DeveloperImage Catalog identity
  + validated NegativeRemovalPlanV1?          # absent for Alpha
  + applicable BroadOSCoverageArtifactSetV1?
       |
       v
derive proposedReleaseScopes internally
  -> resolve every requirement stageBindingPreset
  -> expand every matching binding
  -> intersect exact SubjectSet
       |
       v
requirementID + verificationID
+ scopeProjectionHash + environmentProfileHash
       |
       v
ReleaseGateProfileV1
```

negative-removal使用统一两阶段机器合同，不允许legal task直接修改release scope，也不允许用尚未完成的plan反向授予自己的写权限：

```text
passing Alpha stage store record
  + optional exact prior-plan store record
  + immutable source refs + typed RemovalTargetV1
  -> preflight-negative-removal                 # no repository writes
  -> canonical NegativeRemovalWriteGrantV1
  -> only grant-listed paths may change
  -> rerun affected contract generators + M0/M2 Gates
  -> one exact grant-only source closure commit
  -> clean finalize-negative-removal from base..result commit diff
  -> canonical NegativeRemovalPlanV1
  -> store plan package + run M3-010A Gate
```

```text
NegativeRemovalWriteGrantV1:
  schemaVersion = 1
  grantID
  releaseFlowID
  evidenceStoreBindingID
  repositoryBaseCommit              # clean HEAD observed by preflight
  alphaStage:
    releaseStage = internalAlpha
    stageManifestID
    manifestStoreRef
    storeRecordSHA256
    manifestSHA256
  supersedesPlan?:                  # preflight-owned exact prior-plan pointer
    planID
    planHash
    releaseFlowID
    evidenceStoreBindingID
    evidenceRunID
    manifestStoreRef
    storeRecordSHA256
    manifestSHA256
    planArtifactID
    planArtifactSHA256
  sourceEvidencePolicy{policyID,hash}
  sourcePublicExposure:
    implementationContractIdentity
    catalogExposureHash
    catalogExposedScopes[]
  sourceRefs[]:
    sourceRefID
    sourceKind = legalMaterial | evidenceScenario
    sourceRole = removalAuthority | retainedExactBuildEvidence
    evidenceRunID
    artifactID?                     # legalMaterial only
    scenarioID?                     # evidenceScenario only
    manifestStoreRef
    storeRecordSHA256
    manifestSHA256
  removals[]:
    removalID
    requirementID
    failurePolicyID
    authoritySourceRefIDs[]
    retainedExactBuildSourceRefIDs[]? # transform only
    target:                          # full canonical RemovalTargetV1
      targetKind = action | feature | preparation | deviceScope
      action?:
        productActionID
      feature?:
        nonCommandFeatureID
      preparation?:
        preparationGroupID
        route? = none | classic | personalized
      deviceSelector?:
        deviceClass
        claimNarrowingKind = subtractSameKind |
                             boundedRangeToVerifiedExactSet
        osClaim?:                         # subtractSameKind only
          claimKind = exactBuildSet | boundedVersionRange
          exactBuilds[]?{osVersion,osBuild}
          boundedVersionRange?{minimumInclusive,maximumExclusive}
        sourceBroadClaimScopeHash?         # transform only
        replacementExactBuilds[]?         # transform only; generator-owned
    derivedAffectedExposureTuples[]: # full canonical AtomicPublicExposureV1; generator-owned
      scopeKind = host | device
      deviceClass?
      osClaim?
      productActionID?
      nonCommandFeatureID?
      preparationGroupID?
      route?
    derivedReplacementExposureTuples[]: # transform only; generator-owned
      scopeKind = device
      deviceClass
      osClaim{claimKind=exactBuildSet,exactBuilds[]}
      productActionID?
      nonCommandFeatureID?
      preparationGroupID?
      route?
  grantedContractArtifacts[]:        # generator-owned exact write allowlist
    relativePath
    beforeState = absent | regularFile
    beforeSHA256?                    # regularFile only
    owningContractSetID

NegativeRemovalPlanV1:
  schemaVersion = 1
  planID
  releaseFlowID
  evidenceStoreBindingID
  repositoryResultCommit             # base when no-change; otherwise grant-only child HEAD
  supersedesPlan?:                  # exact projection of writeGrant field
    planID
    planHash
    releaseFlowID
    evidenceStoreBindingID
    evidenceRunID
    manifestStoreRef
    storeRecordSHA256
    manifestSHA256
    planArtifactID
    planArtifactSHA256
  writeGrant                          # full exact NegativeRemovalWriteGrantV1
  writeGrantHash
  resultEvidencePolicy{policyID,hash}
  resultPublicExposure:
    implementationContractIdentity
    catalogExposureHash
    catalogExposedScopes[]
  changedContractArtifacts[]:
    relativePath
    beforeState = absent | regularFile
    beforeSHA256?                    # regularFile only
    afterState = absent | regularFile
    afterSHA256?                     # regularFile only
    owningContractSetID
    revisionBefore?
    revisionAfter?
  surfaceValidation{catalog,cli,gui,docs,help,tests,policy}
  reopenedGateResults[]:
    gateID = M0-900 | M2-900
    reportArtifactID                 # exact ImplementationGateReportV1 in package
    reportSHA256
    outcome = passed

negativeRemovalWriteGrantHash = SHA-256(
  "pulsephone.negative-removal-write-grant.v1\0"
  + repositoryCanonicalJSON.v1 NegativeRemovalWriteGrantV1 bytes
)

negativeRemovalPlanHash = SHA-256(
  "pulsephone.negative-removal-plan.v1\0"
  + repositoryCanonicalJSON.v1 NegativeRemovalPlanV1 bytes
)
```

preflight的source anchor使用三分支纯函数：无prior plan时取current passing Alpha的full contract/policy/public exposure；prior plan与current Alpha同`releaseFlowID/evidenceStoreBindingID`时取prior plan full result identity，用于same-flow terminal remediation；prior来自old flow/binding时仍取current Alpha full source identity，但要求prior result的`catalogExposureHash/catalogExposedScopes[]`等于current Alpha source exposure，允许policy/ImplementationContract revision不同。当前clean repository必须逐字段等于选定anchor；Alpha record始终提供current flow/binding authority。

`preflight-negative-removal`只能在clean HEAD、零repository写入状态开始，并把当前HEAD写入`repositoryBaseCommit`。当前ImplementationContractIdentity/public exposure必须等于选定source anchor；允许Alpha candidate到base之间只有§36.1允许的governance或既有plan result变化，但不能因commit不同跳过identity比较。grant形成到M0/M2 remediation Gate结束前HEAD不得变化；两份report要求`sourceSnapshot.gitHeadCommit == repositoryBaseCommit`，并由同一Gate lock内的before/after snapshot证明checker无source side effect。

M0/M2 remediation report在grant-authorized tree上生成，二者的`sourceSnapshot.gitHeadCommit`必须等于`repositoryBaseCommit`且entries逐项等于实际grant diff。非空diff通过后只允许一次不含TODO/Pitfalls的grant-only source closure commit；其parent必须正是base，tree diff必须与两份report snapshot和grant exact一致。no-change时不创建空commit，`repositoryResultCommit == repositoryBaseCommit`且两份report均为`clean + []`。`finalize-negative-removal`随后只能从该clean result HEAD运行，从`base..result`机械生成`changedContractArtifacts[]`并形成authoritative EvidenceRun；plan `repositoryResultCommit == EvidenceRun.runnerSource.gitCommit`且runnerSource必须clean。M3-010A implementation Gate在同一result commit上以`clean + []`运行并绑定grant/plan record；因此dirty状态只存在于M0/M2 source snapshot，永不成为release-selectable或plan-authority EvidenceRun。

`preflight-negative-removal`必须接收passing Alpha stage store record，并只从该record派生当前`releaseFlowID/evidenceStoreBindingID`；source policy/public exposure按上方source-anchor函数取得，target binding本身不构成flow或source authority。grant的`alphaStage`是该record的exact pointer projection：`stageManifestID == packageID`，四层ref/hash必须可重算，取回manifest必须是`internalAlpha + immutableStageResult + passed`。即使没有source ref或removal，no-change grant仍必须锚定该Alpha。source ref必须按`sourceKind`恰好填写对应branch，并从immutable EvidenceRun store record解析到exact scenario或legal artifact；Beta/Formal aggregate failure必须反查其selected scenario，不能把stage summary当第二种removal authority。broad OS `failed/unknown` scenario只有在`claimEffect=narrowsReleasedCapability`、`typedDetailsRef`可解析到同package保存的exact `BroadOSCoverageArtifactSetV1`及匹配`coverageID + claimScopeHash`时，才可作为该broad claim的`removalAuthority`；passing broad scenario不得授权移除。grant与plan必须绑定同一Alpha的`releaseFlowID/evidenceStoreBindingID`，全部source ref必须先在该binding可取回；`evidenceScenario` run的releaseFlow必须与plan相同，`legalMaterial`允许manifest flow-neutral但record binding必须相同且已按当前policy重新validation/store。pre-flow package迁入后必须使用新record ref。`sourceRefID`、`removalID`和`grantID`均为对象内unique、1～64 byte bounded opaque ASCII，不是path/URL。free ID、missing package、hash mismatch和跨flow伪造引用均失败。每条removal的`authoritySourceRefIDs[]`必须non-empty、unique、ASCII排序，并且引用同一requirement/use-scope、足以证明该target的source；不能用无关legal decision或另一device/OS scenario授权移除。普通removal的authority refs全部为`removalAuthority`且省略retained数组；transform的`retainedExactBuildSourceRefIDs[]`只引用`retainedExactBuildEvidence`，每个build必须局部形成T-004/T-021 exact pair，禁止混入另一broad claim或atomic exposure。

整个supersession lineage尚无prior plan的首个attempt必须省略`--supersedes-plan-record`，write grant和final plan同时省略`supersedesPlan`。任何reopened或recovery replacement M3-010A attempt，包括new flow/binding中的第一份replacement plan，都必须在preflight显式传入`--supersedes-plan-record <prior-plan-store-record>`；tool按prior binding只读取回package并重算plan/artifact/manifest/store四层hash。current flow/binding始终由passing Alpha锚定；source policy/contract/exposure严格按上方三分支函数取得。same-flow branch要求prior full result等于current grant source；cross-flow branch只要求prior result public exposure等于current Alpha source exposure，允许policy/ImplementationContract revision变化。pointer完整保存prior flow/binding。禁止按flow、plan ID/hash、目录或`latest`猜prior plan，也禁止把同一recovery伪装为new lineage root；只有明确没有remediation predecessor的独立release lineage才允许新的root plan。

`RemovalTargetV1`是唯一selector：`targetKind`对应branch恰好一个，`deviceScope`必须有`deviceSelector`，其他branch的selector可省略以表示全部matching public scope；出现OS narrowing时必须同时有device class。`subtractSameKind`要求`osClaim`存在、replacement字段省略：exact-build target只作用于exact-build source，bounded-range target只作用于bounded-range source；禁止用单个exact build在连续range中制造无法表达的洞，bounded range使用non-overlapping half-open interval，exact build不自动合并成range。`boundedRangeToVerifiedExactSet`是唯一cross-kind operator：`osClaim`必须省略，`sourceBroadClaimScopeHash`必须恰好解析一个现有bounded claim，caller不得提交replacement；preflight只从本removal的`retainedExactBuildSourceRefIDs[]`机械派生non-empty、unique、ASCII排序的exact set，每个build必须位于source range、来自同flow/binding/candidate/contract/policy，并同时有`T-004/exact-os-build-claim-evidence-l4`与`T-021/device-matrix-exact-build-l4`passing scenario。replacement复制source claim的全部非OS维度且必须是严格子集；禁止exact-to-range、range扩大、跨action/feature/preparation改写或无evidence增加build。`preparation.route`只允许收窄该group的route，不能独立移除未知route。

validator先从`writeGrant.sourcePublicExposure`的full Catalog projection、PRD ceiling和source policy规范化`AtomicPublicExposureV1`集合。普通operator执行确定性same-kind subtraction；transform执行`(source - affectedBroadTuples) union derivedReplacementExposureTuples`。两类affected/replacement tuple都由preflight生成，caller不能填写；因此整体只允许monotone exposure narrowing，不提供自由addition或独立scope文件。

`derivedAffectedExposureTuples[]`与`grantedContractArtifacts[]`都由preflight tool机械生成，caller不得填写或修改。grant path从source contract set、Catalog/CLI/GUI/docs/help/tests/policy的tracked owner projection以及受影响atomic exposure推导；生成grant前必须验证working tree基线和每个`beforeState/hash`，且不得写任何repository file。实施期间tracked/untracked diff只能落在grant列出的normalized path；symlink、hardlink、非regular node、path escape、grant外写入或before state/hash变化立即失败。`finalize-negative-removal`必须再次接收同一Alpha stage record，重新取回并验证它与grant内`alphaStage`逐字段相同且仍为passing immutable stage；不同record、flow、binding、policy或hash直接失败。finalize还必须解析M0/M2 `ImplementationGateReportV1`，要求definition owner、source snapshot、result contract/policy identity和`overallOutcome=passed`闭合，把两份exact report bytes作为package file artifact保存，并在`reopenedGateResults[]`写入artifact ID/hash；本地`build/gates`文件只作为输入，不是后续authority。finalize必须嵌入原字节write grant，并要求`changedContractArtifacts[]`恰好等于grant中实际发生state或hash变化的文件；create=`absent -> regularFile`、delete=`regularFile -> absent`、modify=`regularFile -> regularFile with different hash`，两侧state相同时hash也相同的no-op不得列出。未变化的granted path可以省略，grant外路径不能补入。

grant含`supersedesPlan`时，finalize还必须再次接收同一个`--supersedes-plan-record`，重新取回并验证exact bytes/pointer，且final plan逐字段复制grant中的pointer；grant省略时CLI参数和plan字段也必须省略。present/absent不一致、换用另一prior record、只复制plan ID或在repository写入后才选择prior plan均fail closed。

全部narrowing operator应用后的exact set必须等于`resultPublicExposure.catalogExposedScopes[]`，其hash与ImplementationContractIdentity均从changed contract bytes重算；M3-009 final `ReleaseCandidateInputV1`必须逐字段匹配该result projection。plan只能按`writeGrant.sourceEvidencePolicy`中的FailurePolicy处理`removableCapability` requirement，且target实际使用的action/feature/preparationGroup/route/deviceClass/osRange dimension必须全部在allowlist中。remediation完成后，changed contract/policy bytes必须解析到`resultEvidencePolicy`；ReleaseGateProfile绑定result policy。空removal仍生成grant为空、canonical no-change plan，source/result policy与public exposure必须相同；发生remediation时允许二者不同，并要求受影响policy/contract revision/hash确实变化。任何productGate、越权dimension、部分surface撤销、非法cross-kind转换、未bump受影响contract/policy revision、未重跑受影响M0/M2 Gate或用旧policy冒充result policy都使plan invalid。

canonical数组顺序固定为：grant `sourceRefs[]`按`sourceRefID`，`removals[]`按`removalID`，每条`authoritySourceRefIDs[]/retainedExactBuildSourceRefIDs[]`按ASCII，`derivedAffectedExposureTuples[]/derivedReplacementExposureTuples[]`和两侧`catalogExposedScopes[]`按canonical bytes，`grantedContractArtifacts[]`与plan `changedContractArtifacts[]`按`relativePath`，`reopenedGateResults[]`按`gateID`。`supersedesPlan`必须从opaque store ref取回prior EvidenceRun及plan artifact，重算plan/artifact/manifest/store四层hash并验证旧plan immutable；只有opaque `planID`不构成可解析链。新plan、grant和旧plan使用同一ID但不同hash、duplicate path/tuple/ref或任一数组乱序均fail closed。

profile generator不接受caller提交requirement、environment、subject、selection role或`required`标记。以下任一情况均fail closed：policy/schema/requirement member missing或extra；非regular canonical file；duplicate/non-concrete/mismatched ID；unknown T/Product Action/feature/PreparationGroup/route/facet/profile/preset/subject/failure/role policy；preset或subject缺失/unused、binding tuple重复、非法空subject；同dimension facet冲突；productGate被移除；未完成NegativeRemovalPlan却产生空scope；已到owner Done却缺required fixture；fixture case与requirement的caseKey/level/class/fixture execution profile不一致；generated tuple missing/extra/duplicate/caller-added；selected run policy/role identity不一致。required evidence缺失或环境前提不满足时结果为`unknown`，不得静默skip或改为`notApplicable`。

Design Freeze不伪装成candidate release stage；它由`M0-900`、完整`ImplementationContractIdentityV1`和structural policy validation闭合。`ReleaseGateProfileV1`只处理Internal Alpha、External Beta和Formal Release。

`scopeProjection` 使用：

```text
ReleaseGateScopeV1:
  scopeKind = global | host | device
  host{architecture,macOSVersion?,macOSBuild?,minimumMacOS?,macModel?}?
  device{deviceClass,productType?,osVersion?,osBuild?,
         osVersionRange?,route=none|classic|personalized?}?
  productActionIDs[]
  nonCommandFeatureIDs[]
  preparationGroupIDs[]

scopeProjectionHash = SHA-256(
  "pulsephone.release-gate-scope.v1\0"
  + repositoryCanonicalJSON.v1 ReleaseGateScopeV1 bytes
)

EvidenceEnvironmentProfileV1:
  profileID
  facetIDs[]                         # fixed policy IDs; ASCII byte order

environmentProfileHash = SHA-256(
  "pulsephone.evidence-environment-profile.v1\0"
  + repositoryCanonicalJSON.v1 EvidenceEnvironmentProfileV1 bytes
)
```

environment facet表达clean-machine、selected-Xcode/no-Xcode、online/offline、app path class、permission state等required precondition；精确host/device facts仍由environment/device artifact保存。不同environment profile的passing scenario不得拼接满足另一profile。

required set使用：

```text
ReleaseGateProfileV1:
  profileID
  releaseFlowID
  evidenceStoreBindingID
  releaseStage
  releaseInput:
    candidateInput                     # full canonical ReleaseCandidateInputV1
    candidateInputHash
  evidencePolicy{policyID,hash}       # equals plan.resultEvidencePolicy when plan exists
  negativeRemovalPlan?               # full canonical NegativeRemovalPlanV1; absent Alpha
  negativeRemovalPlanHash?
  performanceThresholdProfile?       # full canonical; Beta/Formal required
  performanceThresholdProfileHash?
  performanceThresholdFreeze?:       # full canonical freeze object
    freezeEvidenceRunID
    freezeManifestStoreRef
    freezeManifestSHA256
    decisionArtifactID
    decisionArtifactSHA256
    profileArtifactID
    profileArtifactSHA256
    approvalArtifactID
    approvalArtifactSHA256
    freezeStoreRecordSHA256
    freezeHoldID
    freezeHoldAppliedAtUTC
  previousStageManifest?:
    releaseStage
    stageManifestID
    manifestStoreRef
    storeRecordSHA256
    manifestSHA256
  environmentProfiles[]:             # full canonical EvidenceEnvironmentProfileV1
  scopeProjections[]                  # full canonical ReleaseGateScopeV1; hash unique
  proposedReleaseScopes[]             # full canonical ProposedReleaseScopeV1
  broadOSCoverageSet?                 # full canonical BroadOSCoverageArtifactSetV1
  broadOSCoverageSetHash?
  requirements[]:
    requirementID
    verificationID
    scopeProjectionHash
    environmentProfileID
    environmentProfileHash
    requiredDistinctPassingScenarioCount
    stageRunCohortID?
    requiredStageRunOrdinals[]

profileHash = SHA-256(
  "pulsephone.release-gate-profile.v1\0"
  + repositoryCanonicalJSON.v1 ReleaseGateProfileV1 bytes
)
```

`releaseGateProfile`嵌入完整canonical `ReleaseGateProfileV1`，`releaseGateProfileHash`按上式验证；candidate、contract、environment和scope不能只剩不可解析hash。profile、manifest、selection、plan、coverage set和lineage中的`releaseFlowID/evidenceStoreBindingID`必须逐字段相同；manifest的`sourceCommit`固定复制`releaseInput.candidateInput.sourceCommit`，candidate/ImplementationContractIdentity/proposed scopes/broad coverage/threshold/freeze/previous-stage对象也必须从profile逐字段复制，caller不得覆盖或用selected run的`runnerSource`替换。每个requirement的`scopeProjectionHash`必须解析到profile中恰好一个完整scope，scope hash也必须重算一致。profile中的evidence policy必须与manifest及全部selected run逐字段相同；存在plan时必须等于其`resultEvidencePolicy`。Internal Alpha必须省略plan/threshold/freeze/previous stage并按PRD ceiling + current Catalog/public exposure生成scope；External Beta必须携带M3-010A plan、完整threshold/freeze、适用且`coverageOutcome=passed`的bounded broad coverage和passing Alpha ref；Formal必须从passing Beta逐字段继承plan/threshold/freeze/broad coverage/PublicReleaseScopeIdentity且previous stage指向该Beta。exact plan/freeze/coverage/lineage bytes变化必须改变profile hash。`requirementID`是冻结concrete case/variant ID，不能只使用case family。profile必须由上述EvidencePolicyArtifactSet、release stage、typed release input、PRD ceiling、exact Catalog/public exposure、stage允许的NegativeRemovalPlan和适用coverage内部派生；caller不能提交`proposedReleaseScopes`，manifest中的`required`也不是caller权威输入。

每个profile tuple的`requiredDistinctPassingScenarioCount/stageRunCohortID/requiredStageRunOrdinals`只能从policy default与exact cohort机械投影：普通tuple固定`1/absent/[]`；Formal stability/performance cohort固定`3/formal.stability-performance.v1/[1,2,3]`。聚合单位固定为`requirementID + verificationID + scopeProjectionHash + environmentProfileHash`。任一required/applicable requirement `failed`使当前stage失败；否则passing scenario数不足required count、存在unknown或缺失使requirement与stage为`unknown`；恰好达到required count且全部passing才通过。每个passed result必须反查到selection中同requirement/scope/environment的passing scenario。

build-profile不接受caller提供的scope/required set：Internal Alpha从M3-013 fresh reviewed-continuous assembly、PRD ceiling与其中current Catalog/public exposure派生；External Beta从PRD ceiling、M3-009 final candidate Catalog/public exposure、validated NegativeRemovalPlan和M3-019 canonical passed broad coverage set派生；Formal逐字段继承passing Beta的PublicReleaseScopeIdentity与coverage set，不接受独立candidate、plan、freeze或scope输入。存在broad claim而set为failed/unknown时，profile生成保持No-Go并等待M3-010A收窄或新的证据流程，不能丢弃set后继续。需要缩小Beta scope时必须先形成新的validated plan并按§36.1重启flow。

External Beta还必须通过重复`--reusable-legal-record <store-record>`显式传入全部current-binding legal material；tool不得扫描binding、flow或`latest`。records必须candidate absent、current policy重新validation、role/use scope与required legal requirement exact匹配；M3-010 records还必须通过reviewed/Alpha continuity，M3-020 flow legal records必须属于同一flow。policy要求但未提供形成合法`unknown`，extra/duplicate/foreign binding/policy/use-scope record使profile input invalid。Formal只从passing Beta selection继承这组records，不接受caller重新选择。

`release build-broad-os-coverage`只接受M3-009 canonical final candidate input、validated M3-010A plan和已入库exact-build EvidenceRun records；它复用build-profile的同一PRD ceiling/Catalog/plan projection，一次枚举全部broad claim并生成一个canonical `BroadOSCoverageArtifactSetV1`，caller不能选择claim、重复调用后拼接或为每个scope自由命名输出。每个record按固定三slot算法形成，不先生成Beta profile或Gate结果。只要存在broad claim，builder就必须为全部claim和全部slot产出结构完整的三态set：缺设备、缺证据或前提未闭合写为`unknown`，已知contract breach写为`failed`，不能因slot不完整而不生成set。随后broad coverage runner消费该typed set并形成可入库的同outcome scenario；External Beta build-profile重新派生proposed scope，要求set records与全部broad claim按`claimScopeHash` exact一一对应且set `coverageOutcome=passed`。missing/extra/duplicate/foreign candidate/policy输入使builder失败；合法`failed/unknown` set本身结构有效，但只能阻塞freeze/Beta或成为M3-010A的typed remediation source。这样coverage与Beta profile共享一个scope owner，不建立第二份caller scope文件，也不形成先有profile后有coverage的循环。

`run --profile`唯一输出tool-generated selection artifact；caller不能手写或删改member：

```text
EvidenceSelectionSetV1:
  schemaVersion = 1
  selectionSetID                    # 1..64 byte bounded opaque ASCII
  releaseFlowID
  evidenceStoreBindingID
  releaseStage
  releaseGateProfileID
  releaseGateProfileHash
  entries[]:
    requirementID
    verificationID
    scopeProjectionHash
    environmentProfileID
    environmentProfileHash
    selectedScenarios[]:
      evidenceRunID
      scenarioID
      manifestStoreRef
      storeRecordSHA256
      manifestSHA256
      selectionRole
      stageRunID?
      stageRunOrdinal?
  formalStageRunAttemptLedgers[]:      # full canonical StageRunAttemptLedgerV1
    schemaVersion = 1
    ledgerID
    ledgerState = finalized
    stageRunSeriesID
    stageRunCohortID
    scopeProjectionHash
    environmentProfileHash
    attempts[]:
      attemptIndex
      stageRunID
      stageRunOrdinal
      previousStageRunID?
      evidenceRunRefs[]:
        requirementID
        verificationID
        evidenceRunID
        scenarioID
        manifestStoreRef
        storeRecordSHA256
        manifestSHA256
        scenarioOutcome = passed | failed | unknown
      outcome = passed | failed | unknown
```

```text
selectionSetHash = SHA-256(
  "pulsephone.evidence-selection-set.v1\0"
  + repositoryCanonicalJSON.v1 EvidenceSelectionSetV1 bytes
)

stageRunAttemptLedgerHash = SHA-256(
  "pulsephone.stage-run-attempt-ledger.v1\0"
  + repositoryCanonicalJSON.v1 StageRunAttemptLedgerV1 bytes
)
```

执行期checkpoint的机器形态为：

```text
StageRunAttemptLedgerWALV1:
  schemaVersion = 1
  releaseFlowID
  evidenceStoreBindingID
  ledgerID
  stageRunSeriesID
  stageRunCohortID
  scopeProjectionHash
  environmentProfileHash
  checkpointRevision                 # UInt64, starts at 1, contiguous
  seriesState = open | closed | finalized
  attempts[]:
    attemptIndex
    stageRunID
    stageRunOrdinal
    previousStageRunID?
    phase = started | terminal
    evidenceRunRefs[]?                # terminal only; same exact element schema as ledger
    outcome? = passed | failed | unknown  # terminal only

stageRunAttemptLedgerWALHash = SHA-256(
  "pulsephone.stage-run-attempt-ledger-wal.v1\0"
  + repositoryCanonicalJSON.v1 StageRunAttemptLedgerWALV1 bytes
)
```

`selectionSetID`只标识artifact，不能充当scope/required-set/hash authority；`run --profile`必须在第一条Formal cohort attempt开始前生成1～64 byte bounded opaque ID以及每个cohort key的ledger/series ID，caller不能提供；全部attempt结束后才finalize canonical selection并输出detached lowercase hash。同ID不同hash、跨flow/profile复用或hash mismatch均拒绝；aggregate将ID/hash/fixed artifact path写入manifest。entries必须与profile required tuple exact覆盖且按profile key排序，即使当前没有passing scenario也不能删除entry。每个selected EvidenceRun内，同一profile tuple必须至多一个matching scenarioResult；每个selected scenario的run/scenario/store ref/hash组合必须unique并按`stageRunOrdinal,evidenceRunID,scenarioID`排序。结构validator允许scenario outcome为passed/failed/unknown；业务失败不是schema错误。

普通tuple最多选择1个scenario且必须省略`releaseStageRun`；Formal可以复用passing Beta manifest已经选择、且与当前candidate/contract/policy/profile exact一致的External Beta scenario。`formal.stability-performance.v1` tuple最多选择ordinal `1,2,3`各1个scenario，且必须来自Formal evidence。`stageRunID`、`stageRunSeriesID`和`ledgerID`均由`run --profile`生成，为1～64 byte bounded opaque ID；caller不能传入、跨flow/stage/cohort key复用或改变ordinal。cohort key固定为`cohortID + scopeProjectionHash + environmentProfileHash`：两个exact T-018 member在同一key/attempt必须共享同一stageRunID，ordinal 2/3必须通过`previousStageRunID`精确链接前一轮，三轮时间不得重叠。每个ordinal可以包含多个EvidenceRun package，但其scenario union必须对该cohort key的两个member各覆盖一次。

`StageRunAttemptLedgerV1`是该cohort key从第一条Formal attempt开始的append-only exact journal；`attemptIndex`从1连续递增，每个attempt必须在执行前登记identity、在结束后写入三态outcome与exact EvidenceRun refs。attempt outcome只能机械聚合：任一required member scenario failed -> failed；否则任一unknown、missing或未形成可靠terminal -> unknown；两个exact cohort member均各有一个passing scenario才是passed。任一failed/unknown attempt立即终止当前series；重试必须生成新selection/ledger/series并从ordinal 1开始，禁止在旧series继续或挑走中间failure。passing selection必须恰好投影同一series最后连续的三个attempt、ordinal `[1,2,3]`、全部passed且无遗漏/插入；selection entry与ledger attempt的run/scenario/store refs集合必须互为exact projection。

执行中的账本使用同一durable EvidenceStore binding下的internal `StageRunAttemptLedgerWALV1`，不进入release package，也不具备selection authority。每次attempt遵循固定checkpoint：

```text
atomically checkpoint started(attempt identity, ordinal, previous ID)
  -> fsync file + parent before runner launch
  -> run and finalize every EvidenceRun
  -> validate + store put every EvidenceRun
  -> atomically checkpoint terminal(exact refs, derived outcome)
  -> fsync file + parent

recovery sees started without terminal
  -> append/replace next revision with outcome=unknown
  -> close current series
  -> retry only with new selection/ledger/series from ordinal 1
```

WAL checkpoint使用monotonic `checkpointRevision`、compare-and-swap expected previous revision、temp-write + fsync + atomic rename + parent fsync；恢复只能接受最后一个完整、hash-valid revision，不能猜测runner是否成功或复用原`stageRunID`。`phase=started`必须省略refs/outcome，`phase=terminal`必须完整携带两者；同attempt只能从started前进到terminal，不能反向或改identity。failed/unknown terminal把`seriesState`置closed；全部三个passing terminal后可从open原子seal为finalized。tool随后把WAL的exact projection一次性finalize为`ledgerState=finalized`的canonical ledger并嵌入selection；selection禁止消费working、存在unterminated attempt、revision gap或无法恢复的WAL。canonical顺序固定为：selection ledgers按`stageRunCohortID,scopeProjectionHash,environmentProfileHash,ledgerID`，attempts按`attemptIndex`，每个`evidenceRunRefs[]`按`requirementID,verificationID,evidenceRunID,scenarioID`。任何duplicate、乱序、store ref/hash mismatch或ledger/WAL hash mismatch均fail closed。

threshold/legal role必须省略stageRun并按role policy最多选择一次。missing scenario、failed或unknown scenario会形成合法但non-passing的三态stage result；只有unknown role、extra count/ordinal、duplicate、identity mismatch、同run内tuple多义、未immutable store、attempt ledger缺口或把三轮sample合并为一个run才使selection artifact invalid。aggregate必须验证selection canonical bytes/hash并从中构造manifest，不能接受自由run ID列表。canonical selection bytes必须以固定路径`artifacts/evidence-selection-set.v1.json`进入每个release stage package；store/fetch后的独立复验必须读取该artifact，不得依赖`build/`残留文件或按selected run临时重构另一份selection。

可被release选择的evidence run最小长期合同为：

```text
EvidenceRunManifestV1:
  schemaVersion = 1
  evidenceRunID
  evidenceStage = preImplementation | implementation |
                  internalAlpha | externalBeta | formalRelease
  releaseFlow?:
    releaseFlowID
    evidenceStoreBindingID
  startedAtUTC
  endedAtUTC
  monotonicDurationMs
  releaseStageRun?:
    releaseFlowID
    releaseStage
    selectionSetID
    stageRunCohortID
    stageRunSeriesID
    stageRunAttemptIndex
    stageRunID
    stageRunOrdinal
    previousStageRunID?
    releaseGateProfileID
    releaseGateProfileHash
  runnerSource:
    gitCommit
    worktreeState = clean | dirty
    sourceSnapshotArtifactID?          # dirty diagnostic only
  candidate{buildID,appVersion,appBundleContentHash}?
  implementationContractIdentity
  evidencePolicy{policyID,hash}
  performanceContract?:
    revision
    sha256
  measurementProfiles[]?:
    profileID
    profileHash
  performanceThresholdProfiles[]?:
    profileID
    profileHash
  scenarioResults[]:
    scenarioID
    caseKey?
    requirementID
    verificationID
    contractRefs[]
    scopeProjection
    scopeProjectionHash
    environmentProfileID
    environmentProfileHash
    applicability = applicable | notApplicable
    outcome = passed | failed | unknown
    expectedOracleRef
    observedDisposition
    typedDetailsRef?
    standardError?
    artifactIDs[]
    blockerCodes[]
    claimEffect = none | supportsActuallyVerifiedReview |
                  narrowsReleasedCapability | blocksReleaseStage
  artifacts[]:
    artifactID
    role
    artifactKind = file | tree
    relativePath
    file?:
      mediaType
      byteLength
      sha256
    tree?:
      treeHashAlgorithm = appBundleContent.v1
      entryCount
      totalFileByteLength
      manifestArtifactID
      treeContentHash
    sensitivityClass = public | internal | restricted
    redactionState = notRequired | redacted | manuallyReviewed
  validationStatus:
    integrity = valid | invalid | unknown
    privacy = valid | invalid | unknown
    retention = valid | invalid | unknown
    rawCleanup = valid | invalid | unknown
  retentionClass = implementationRun | candidateRun | releasedRun | legalMaterial
  overallOutcome = passed | failed | unknown
```

performance EvidenceRun必须填写`performanceContract`和实际使用的measurement profile；其ID/hash必须与metrics artifact逐字段相同。普通非performance run省略这些字段，不能填空对象占位。`runnerSource`记录实际执行adapter/test/probe所在的clean或diagnostic Git commit，与`ReleaseCandidateInputV1.sourceCommit`承担不同身份。`evidenceStage=internalAlpha|externalBeta|formalRelease`必须携带`releaseFlow`并与store record、profile/selection/manifest lineage逐字段相同；`preImplementation|implementation`必须省略，不能作为current-candidate release selection。flow-neutral implementation legal run只能按`reusableLegalMaterial`规则在当前flow binding重新validation/store后复用。`currentCandidateEvidence`的`evidenceStage`必须落入requested stage的`eligibleEvidenceStages`；Formal复用External Beta run时，该run还必须是passing Beta manifest selection的exact member。只有Formal multiplicity cohort run可携带`releaseStageRun`，且其中flow ID必须等于顶层`releaseFlow`；其他stage、requirement和selection role携带该对象均失败。

普通artifact必须使用`artifactKind=file`。`artifactKind=tree`第一阶段只允许role=`releaseCandidateAppTree`；M3-009 candidate run必须恰有一个该tree和一个`artifactKind=file, role=releaseCandidateInput`，duplicate/missing或role-kind互换均invalid。tree的`manifestArtifactID`必须引用该唯一candidate-input artifact，tool从文件取回完整`ReleaseCandidateInputV1.appBundleContentManifest`，要求其canonical manifest bytes逐byte等于tree使用的manifest，并逐entry验证tree safe node/path/mode/bytes、重算`entryCount/totalFileByteLength/treeContentHash`；`treeContentHash`必须等于run candidate的`appBundleContentHash`。tree root固定为一个`PulsePhone.app`目录，拒绝extra/missing node、hardlink、absolute/outside symlink、foreign node和manifest mismatch；effective maximum严格等于candidate manifest全部file byte length之和，EvidenceStore quota不足形成unknown且不得截断。store/fetch必须保留可交付bundle所需metadata，并在每次取回后重新执行strict code-signature与staple validation；非身份xattr/resource fork仍不进入`appBundleContentHash`。

candidate manifest只能选择`integrity/privacy/retention/rawCleanup`全部valid的immutable evidence run。owner-defined T-matrix/OS/profile本来不适用的scope可以`notApplicable`；若用`notApplicable`排除原本会进入released scope的required case，则必须完成valid `NegativeRemovalPlanV1`及其全surface revision/Gate重跑；productGate不得走该分支。

`selectionRole=currentCandidateEvidence`的technical/device/performance run必须满足candidate identity、ImplementationContractIdentity和evidence policy逐字段相等，且`runnerSource.worktreeState=clean`；历史passing run不得跨candidate直接复用。Release manifest/profile的`sourceCommit`始终来自typed candidate input，普通run的`runnerSource.gitCommit`只记录测试实现来源，允许晚于并不同于candidate commit。在`currentCandidateEvidence`范围内唯一source-equality例外是M3-009 candidate producer run：它恰含`releaseCandidateInput + releaseCandidateAppTree`，其`runnerSource.gitCommit`必须等于artifact内`sourceCommit`。Formal multiplicity cohort的三个ordinal还必须使用同一`runnerSource.gitCommit`。`thresholdProvenance`只允许引用TRD 08 §37冻结profile列出的baseline/freeze run，只证明阈值来源，不能闭合当前candidate requirement。`reusableLegalMaterial`只有在exact component/version/hash/use scope与当前packaging manifest一致、持有授权attestation且已在当前evidence policy下重新validation时可复用。所有selected run必须通过opaque、非URL/非path的`manifestStoreRef + manifestSHA256`可取回和校验。同一`evidenceRunID`出现在任意selection entry时，store ref、store record hash、manifest hash和selection role必须全局一致。

M3-010 flow-neutral legal run是第二个窄source-equality入口：其顶层candidate仍absent，但唯一`reviewedDevelopmentCandidateInput.sourceCommit`必须等于该run的clean `runnerSource.gitCommit`，证明审查发生在生成该assembly的同一source HEAD。M3-013只在显式record取回、schema/hash验证和去`sourceCommit` continuity全部通过后接受fresh input；不能把这个例外推广到普通legal或current-candidate run。

manifest的`selectedEvidenceRuns[]`必须是selection全部selected scenario所引用run的exact去重投影，再加threshold profile明确列出的baseline/freeze run；不得漏项、额外加入未使用run或改变role。每个`verificationResults.evidenceRunIDs[]`必须恰好等于对应selection entry的unique run集合。applicable result只有达到profile required passing count才可`passed`；合法`notApplicable`必须由policy/plan支持的N/A determination成功证明，不能用未执行、环境缺失或runner判断代替，productGate禁止N/A。M3-016的Formal provisional manifest允许selected run暂缺`releaseHoldID/holdAppliedAtUTC`，但不能称为passing Formal Release或进入dist；provisional validation除此之外不豁免任何条件。M3-017 finalize后的Formal Release引用的每个selected run和threshold freeze必须已建立不可变release hold，并记录hold字段；不得依赖仍会按candidate retention清理的未hold package。

Evidence store与hold使用一个release-tooling接口，不为device/DDI/performance另建存储生命周期：

```text
EvidenceStoreBindingResolverV1:
  openReadOnly(evidenceStoreBindingID)
    -> EvidenceStoreReadOnlyV1

EvidenceStoreReadOnlyV1:
  getBindingID() -> bounded opaque evidenceStoreBindingID
  fetchStoreRecord(manifestStoreRef)
    -> exact canonical EvidenceStoreRecordV1 bytes
  fetchManifest(manifestStoreRef)
    -> exact manifest bytes
  fetchPackageArtifact(manifestStoreRef, fixedRelativePath)
    -> exact package artifact bytes
  verifyPackage(manifestStoreRef, expectedManifestSHA256,
                expectedStoreRecordSHA256)
    -> valid | invalid | unknown

EvidenceStoreV1:
  getBindingID() -> bounded opaque evidenceStoreBindingID
  checkpointWorkingLedger(releaseFlowID, ledgerID,
                          expectedPreviousRevision,
                          canonicalWALBytes, walHash)
    -> committed checkpointRevision
  fetchWorkingLedger(releaseFlowID, ledgerID)
    -> exact canonical StageRunAttemptLedgerWALV1 bytes + hash
  sealWorkingLedger(releaseFlowID, ledgerID,
                    expectedRevision, expectedWalHash)
    -> exact finalized StageRunAttemptLedgerV1 bytes + hash
  putValidatedPackage(packageRoot, expectedManifestSHA256,
                      structuralValidationReport)
    -> {record, storeRecordSHA256}
  importValidatedFlowNeutralPackage(sourceStoreRecord,
                                    passingAlphaStageRecord)
    -> new target-binding {record, storeRecordSHA256}
  fetchStoreRecord(manifestStoreRef)
    -> exact canonical EvidenceStoreRecordV1 bytes
  fetchManifest(manifestStoreRef)
    -> exact manifest bytes
  fetchPackageArtifact(manifestStoreRef, fixedRelativePath)
    -> exact package artifact bytes
  fetchPackageSubtree(manifestStoreRef, treeArtifactID)
    -> verified private tool-derived subtree
  verifyPackage(manifestStoreRef, expectedManifestSHA256,
                expectedStoreRecordSHA256)
    -> valid | invalid | unknown
  createReleaseHold(manifestStoreRef, releaseFlowID,
                    candidate?, evidencePolicy, holdReason)
    -> EvidenceReleaseHoldV1
  verifyReleaseHold(releaseHoldID)
    -> exact immutable hold record

EvidenceReleaseHoldV1:
  releaseHoldID
  evidenceStoreBindingID
  manifestStoreRef
  storeRecordSHA256
  manifestSHA256
  releaseFlowID
  candidate?
  evidencePolicy{policyID,hash}
  holdReason = thresholdFreeze | selectedForRelease | legalMaterial
  appliedAtUTC

ReleaseHoldSetV1:
  schemaVersion = 1
  holdSetID                       # 1..64 byte bounded opaque ASCII
  releaseFlowID
  evidenceStoreBindingID
  formalProvisionalStageManifestID
  formalProvisionalManifestStoreRef
  formalProvisionalStoreRecordSHA256
  formalProvisionalManifestSHA256
  holds[]:
    packageKind = evidenceRun | releaseStageManifest
    packageID
    manifestStoreRef
    storeRecordSHA256
    manifestSHA256
    releaseHoldID
    holdReason = selectedForRelease
    holdAppliedAtUTC

EvidenceStoreRecordV1:
  schemaVersion = 1
  evidenceStoreBindingID
  releaseFlowID?                    # exact manifest projection when present
  packageKind = evidenceRun | releaseStageManifest
  packageState = finalized | formalProvisional
  packageID
  manifestStoreRef
  manifestSHA256
  packageByteLength
  retentionClass
  evidencePolicy{policyID,hash}
  storedAtUTC
  validationStatus:
    integrity = valid
    privacy = valid
    retention = valid
    rawCleanup = valid
  immutabilityState = immutable
```

所有显式store record先从record的`evidenceStoreBindingID`经`EvidenceStoreBindingResolverV1`选择adapter，再验证record/hash/package；resolver不按ref尝试多个backend，也不提供latest/failover。current-flow put/checkpoint/hold及普通fetch仍只允许当前`ReleaseFlowV1.evidenceStoreBindingID`。跨binding只开放三个窄入口：M3-013 `verify-reviewed-development-input`从显式flow-neutral legal record只读exact `reviewedDevelopmentCandidateInput`并与fresh Alpha input比较，不迁移或写入；`import-flow-neutral`从source binding只读取legal material并在current binding重新validation/store；negative-removal supersession从prior binding只读取plan package作审计，不导入、改写或选择其evidence。任一source/prior binding或record暂不可用时结果为unknown/No-Go，不得扫描替代backend、重置lineage或自动切换source。NegativeRemovalPlan EvidenceRun固定`retentionClass=candidateRun`，superseded后至少按180 days保留；若切换binding，旧binding必须在该retention窗口内继续可只读解析。

```text
storeRecordSHA256 = SHA-256(
  "pulsephone.evidence-store-record.v1\0"
  + repositoryCanonicalJSON.v1 EvidenceStoreRecordV1 bytes
)

releaseHoldSetHash = SHA-256(
  "pulsephone.release-hold-set.v1\0"
  + repositoryCanonicalJSON.v1 ReleaseHoldSetV1 bytes
)
```

`packageKind=evidenceRun`时`packageID`必须等于manifest的`evidenceRunID`且`packageState=finalized`；manifest有`releaseFlow`时record的flow/binding必须逐字段投影，没有时`releaseFlowID`必须省略。`releaseStageManifest`时`packageID`必须等于`stageManifestID`，record flow/binding必须等于manifest。`packageState=formalProvisional`只允许`releaseStageManifest + formalRelease + manifestState=formalProvisional`，只可作为`hold-selected/finalize`输入，不能称为passing stage、不能进入dist或作为previous-stage lineage。`manifestStoreRef`、`packageID`、`releaseHoldID`和`evidenceStoreBindingID`是1～128 byte bounded ASCII opaque ID；selection/hold-set/ledger/series ID是1～64 byte bounded ASCII opaque ID。以上均禁止URL、absolute/relative path、credential、account或host name；record/hold也不得保存backend root、host或account。consumer不得解析opaque ID内部结构，落盘只能经`ArtifactPathKeyV1`。

`put`前必须通过结构验证：schema/canonical/hash、package完整性、privacy、retention和raw-cleanup全部valid。scenario或stage的passed/failed/unknown是业务Gate outcome，不改变一个结构合法package的可存储性；因此failed/unknown stage manifest可以入库留审计，其selected EvidenceRun scenario可成为late NegativeRemovalPlan的typed source。store保证同ref、record和bytes immutable。duplicate exact package可以返回同ref，hash不同不得覆盖；同package kind/ID不同hash必须拒绝。hold必须同时绑定store record hash与manifest hash；hold创建幂等于exact`manifestStoreRef + releaseFlowID + holdReason`，conflicting candidate/policy必须拒绝；普通cleanup/prune不能删除held package。hold解除只允许release flow之外的授权retention操作并形成独立审计记录，当前release任务不能调用。

`EvidenceReleaseHoldV1.candidate?`绑定被hold package自身的candidate，不是一律强制写final release candidate：Internal Alpha stage/run保留`developmentAssembly` candidate；External Beta、Formal、threshold baseline/freeze和其他current-candidate run等于M3-009 final signed candidate；legal material省略candidate。跨package关联统一由`releaseFlowID + evidenceStoreBindingID + holdReason + selection role`验证，禁止为了“统一”而改写Alpha或历史package candidate。

第一阶段可以使用受控CI/local content-addressed filesystem adapter，但storage root只由受控运行环境提供，不写入manifest、Git或产品Application Support。`M0-011`实现供implementation `V-E/V-E-S`使用的bootstrap local `store put/fetch/verify` adapter；`M3-012A`在同一接口上补齐release-flow durable binding/resolver、flow-neutral import、package subtree、working checkpoint和hold contract及fake/integration tests。`EXT-009`必须在M3-013创建flow前提供最终durable binding以及容纳final candidate tree与全部hold retention的容量，M3-013的Alpha EvidenceRun、stage package和Formal WAL从第一条记录起即使用它，M3-014创建freeze hold，M3-017创建最终selected holds。进入flow后每次current-flow put/fetch/hold/checkpoint都必须验证configured binding等于`ReleaseFlowV1.evidenceStoreBindingID`；backend暂时不可用形成`unknown`且不自动failover。若必须切换binding则终止旧flow并从M3-013创建新flow，但旧binding在candidateRun 180-day supersession审计窗口内必须保持read-only resolver可达。

pre-flow legal package迁入统一使用`Scripts/evidence-tool store import-flow-neutral --source-record <bootstrap-record> --alpha-stage-record <passing-alpha-record> --objects-root build/evidence/objects`。target binding、flow和current policy只能从passing Alpha store record派生，caller不能另传；tool按source record binding取回exact package，只接受`packageKind=evidenceRun`、manifest省略releaseFlow/candidate、`retentionClass=legalMaterial`的flow-neutral material，重新执行current-policy schema/integrity/privacy/retention/raw-cleanup验证，并要求其唯一`reviewedDevelopmentCandidateInput`与Alpha profile candidate input按前述continuity投影逐字段相同后，才把exact package写入target binding并返回新record path。target record仍省略releaseFlowID但binding必须等于Alpha flow；source/target相同可幂等verify后返回。policy mismatch或review continuity mismatch要求在当前clean source上追加新的M3-010 attempt生成legal wrapper，再创建new Alpha flow并重新import；禁止改写旧manifest。不能迁移opaque ref、沿用旧record hash或用该命令导入current-candidate/threshold/stage package。M3-010A只能消费tool返回的新record。

release tooling把结构验证与stage判定分开：`validate-manifest`只判断package能否入库，`evaluate-stage`再根据required result返回passed/failed/unknown并以非passed退出非零；不得把业务failure伪装成malformed artifact。Formal provisional使用同一结构validator和同一evaluator core，由`evaluate-provisional`验证：除release hold字段尚未创建外，全部required result必须passing；其成功只表示可进入M3-017，不表示Formal Release已通过。两个命令的canonical审计输出共用：

```text
StageGateOutcomeReportV1:
  schemaVersion = 1
  evaluationMode = stageResult | formalProvisional
  releaseFlowID
  evidenceStoreBindingID
  stageManifestID
  manifestStoreRef
  storeRecordSHA256
  manifestSHA256
  releaseStage
  manifestState
  releaseGateProfileID
  releaseGateProfileHash
  selectionSetID
  selectionSetHash
  evaluatedRequirements[]:
    requirementID
    verificationID
    scopeProjectionHash
    environmentProfileHash
    outcome = passed | failed | unknown
    reasonCodes[]
  outcome = passed | failed | unknown

stageGateOutcomeReportHash = SHA-256(
  "pulsephone.stage-gate-outcome-report.v1\0"
  + repositoryCanonicalJSON.v1 StageGateOutcomeReportV1 bytes
)
```

`evaluatedRequirements[]`必须与ReleaseGateProfile tuple exact一一对应并按`requirementID,verificationID,scopeProjectionHash,environmentProfileHash`排序。`reasonCodes[]`只能使用stage-gate-outcome-report schema固定enum：`requiredScenarioFailed|requiredScenarioUnknown|requiredScenarioMissing|passingCountInsufficient|invalidNotApplicable|identityMismatch|lineageInvalid|holdMissing`，并按ASCII排序；不能写自由文本或实现本地扩展。report只是在指定store record上运行统一evaluator的deterministic审计投影，不是后续side effect authority；任何consumer都必须重新fetch record/package并调用同一evaluator core，不能只信任caller提供的report path或hash。

release stage package形态固定为：

```text
release-stage-package/
+-- release-evidence-manifest.v1.json
+-- release-evidence-manifest.v1.sha256
`-- artifacts/
    +-- evidence-selection-set.v1.json
    `-- release-hold-set.v1.json          # final Formal only
```

manifest中的selection/hold-set ID、hash和fixed relative path必须与package exact artifact一致；package validator先校验safe node/path、canonical bytes和hash，再允许store。stage store record保护整个immutable package，consumer通过`fetchPackageArtifact`取回，不得从本地path替代。

`release hold-selected`必须只接受Formal provisional store record，并在创建任何hold前内部重新运行`evaluate-provisional`的同一evaluator core；只有`evaluationMode=formalProvisional + outcome=passed`才继续，failed/unknown/mismatch时零side effect。随后从lineage机械遍历Alpha/Beta/Formal stage manifest及threshold/baseline/current-candidate/legal evidence package，生成带tool-generated `holdSetID`的canonical `ReleaseHoldSetV1`；caller不能提交ID或hold列表。holds必须恰好包含lineage全部selected EvidenceRun去重集合以及Internal Alpha、External Beta、Formal provisional三个stage manifest，按`packageKind,packageID`排序。每个entry必须解析到当前flow、当前store binding且`holdReason=selectedForRelease`的exact hold；已有`thresholdFreeze`或`legalMaterial` hold只能附加保留，不能替代set成员，manifest中的releaseHoldID必须等于对应entry。missing、extra、duplicate或超过固定cap失败。

`release finalize`只接受matching provisional stage record与hold set，必须原字节复制provisional package中的selection artifact和ID/hash，不能重跑selection；逐项取回hold后只填充selected evidence hold字段，把exact hold set写入final package固定artifact，并在manifest `formalFinalization`记录ID/hash/path，再输出新的final Formal `stageManifestID`和detached hash。foreign-flow/binding hold、selection变化或provisional/hash mismatch失败。final package必须先结构验证并`store put`，再由`evaluate-stage`从store record重算为passed；`hold-stage-manifest`和`publish-final`都只接受final stage store record（publish另接受其exact final-stage hold），内部重新运行同一evaluator core且只在passed时产生side effect，不接受stage Gate report作为authority。failed/unknown时禁止创建final stage hold或写dist。

final manifest自身的store record/hold不回写manifest。`publish-final`必须从stored final selection机械定位唯一passing `T-002/signed-notarized-stapled-bundle-l5` run及其held `releaseCandidateAppTree`，从EvidenceStore取回到private tool-derived temp，逐byte重算candidate input/tree manifest/hash并执行strict code-signature与staple validation；随后在exclusive dist publish lock内把该tree、stored final manifest及detached hash原子发布到`dist/`，不接受caller app path或既有dist app作为输入。publish完成后把同一evaluator输出的完整canonical `StageGateOutcomeReportV1`及hash、published candidate store pointer/hash、dist manifest bytes/hash和hold-set ID/hash共同写入canonical `FinalReleaseEvidenceGateReportV1`（`build/gates/final-release-evidence.json`），避免自引用。

M3-900必须从report/final store record重新解析同一selected candidate run，取回并验证held store tree，重算embedded stage outcome；随后对store tree与`dist/PulsePhone.app`分别生成canonical `AppBundleContentManifestV1`，要求二者逐byte等于final profile内的candidate input，并重跑strict code-signature/staple validation，再逐byte比较stored/dist release manifest及detached hash。本地`build/`副本、caller app path或未与held store tree比较的dist文件不构成authority。

```text
FinalReleaseEvidenceGateReportV1:
  schemaVersion = 1
  releaseFlowID
  evidenceStoreBindingID
  finalStageManifestID
  finalManifestStoreRef
  finalStoreRecordSHA256
  finalManifestSHA256
  finalStageGateOutcomeReport          # full canonical StageGateOutcomeReportV1
  finalStageGateOutcomeReportHash
  finalStageReleaseHoldID
  finalStageHoldAppliedAtUTC
  selectionSetID
  selectionSetHash
  releaseHoldSetID
  releaseHoldSetHash
  publicReleaseScopeIdentityHash
  publishedCandidate:
    evidenceRunID
    manifestStoreRef
    storeRecordSHA256
    manifestSHA256
    releaseCandidateInputArtifactID
    releaseCandidateAppTreeArtifactID
    releaseCandidateInputHash
    appBundleContentHash
    releaseHoldID
    codeSignatureValidation = passed
    stapleValidation = passed
  distManifestSHA256
  distDetachedHashSHA256
  outcome = passed
```

Gate report只能在final package structure validation、final store put、内部`evaluate-stage=passed`、final stage hold、held candidate subtree复验和dist原子publication全部成功后生成；任一ref/hash/ID必须解析到同一flow、store binding、final manifest及stored selection。published candidate必须是selection中唯一T-002 run的exact artifact pointer，`releaseHoldID`必须等于hold set中该package的`selectedForRelease` hold，candidate input/hash与final `ReleaseGateProfileV1.releaseInput`逐字段相同。embedded stage outcome必须是`evaluationMode=stageResult`、`manifestState=immutableStageResult`、`releaseStage=formalRelease`、`outcome=passed`，并由publish调用的同一evaluator结果原字节复制；M3-900仍从store record独立重算并exact比较。report本身不回写final manifest，也不能被caller用于替换selection、hold-set或candidate tree bytes。

scope 元素固定为：

本节所有`osVersion`与range boundary使用canonical numeric `major.minor.patch` ASCII（三个UInt16十进制分量、无前导零）；source缺少minor/patch时在进入canonical object前补0。比较按numeric tuple，不按字符串；major boundary固定为`N.0.0`，`nextMajor/previousMajor`只增减major并将minor/patch置0。pre-release/build metadata不进入version boundary，exact Apple build另存`osBuild`。

```text
ActuallyVerifiedScopeV1:
  scopeKind = host | device
  host{macOSVersion,macOSBuild,architecture,macModel}?
  device{deviceClass,productType,osVersion,osBuild}?
  productActionIDs[]
  nonCommandFeatureIDs[]
  evidenceRunIDs[]

ReleasedCapabilityScopeV1:
  scopeKind = host | device
  host{minimumMacOS,architecture}?
  device:
    deviceClass
    osClaim:
      claimKind = exactBuildSet | broadVersionRange
      exactBuilds[]?:
        osVersion
        osBuild
      broadVersionRange?:
        minimumInclusive
        maximumExclusive
  productActionIDs[]
  nonCommandFeatureIDs[]

PublicReleaseScopeIdentityV1:
  schemaVersion = 1
  proposedReleaseScopes[]
  releasedCapabilityScopes[]

publicReleaseScopeIdentityHash = SHA-256(
  "pulsephone.public-release-scope-identity.v1\0"
  + repositoryCanonicalJSON.v1 PublicReleaseScopeIdentityV1 bytes
)

BroadOSCoverageArtifactSetV1:
  schemaVersion = 1
  coverageSetID
  releaseFlowID
  evidenceStoreBindingID
  candidateInputHash
  negativeRemovalPlanHash
  developerImageCatalog{revision,hash}
  evaluatedAtUTC
  coverageOutcome = passed | failed | unknown
  records[]:                          # full BroadOSCoverageV1; sorted by claimScopeHash
    schemaVersion = 1
    coverageID
    claimScopeHash
    range{minimumInclusive,maximumExclusive}
    recordOutcome = passed | failed | unknown
    blockerCodes[]
    representativeSlots[]:           # exactly lowerBoundary, intermediate, upperBoundary
      role
      slotRange{minimumInclusive,maximumExclusive}
      slotOutcome = passed | failed | unknown
      representative?:               # present only when slotOutcome=passed
        osVersion
        osBuild
      evidenceRefs[]:                 # exact-build observation scenarios; may be partial
        requirementID
        scenarioID
        evidenceRunID
        manifestStoreRef
        storeRecordSHA256
        manifestSHA256
      blockerCodes[]

claimScopeHash = SHA-256(
  "pulsephone.proposed-release-scope.v1\0"
  + repositoryCanonicalJSON.v1 ProposedReleaseScopeV1 bytes
)

broadOSCoverageSetHash = SHA-256(
  "pulsephone.broad-os-coverage-set.v1\0"
  + repositoryCanonicalJSON.v1 BroadOSCoverageArtifactSetV1 bytes
)

```

`ProposedReleaseScopeV1`与`ReleasedCapabilityScopeV1`使用同一字段形态，但语义不同：前者由profile generator依据PRD ceiling、candidate Catalog/public exposure、validated plan和适用coverage内部派生并写入profile/manifest，后者是Gate通过后的最终输出。`exactBuildSet`要求non-empty、unique、按`osVersion,osBuild` ASCII排序，并且每个build都能反查同candidate的ActuallyVerified exact evidence。两branch恰好存在一个，禁止把一个未验证range伪装成exact set，或把exact set自动合并成range。Internal Alpha device scope只允许当前Alpha target的`exactBuildSet`且coverage set省略，不形成broad public claim；`broadVersionRange`只允许External Beta/Formal。

公开identity在所有三态manifest中都有唯一派生：普通`immutableStageResult`为passed时`releasedCapabilityScopes == proposedReleaseScopes`；failed/unknown时`releasedCapabilityScopes=[]`，`PublicReleaseScopeIdentityV1`仍完整保存`proposedReleaseScopes + empty releasedCapabilityScopes`。Formal provisional必须继承passing Beta的proposed/released identity，且required result聚合必须passed，但`manifestState=formalProvisional`使它不能称为Formal Release或进入dist。证据不足只能形成failed/unknown stage或在Beta前经valid plan缩小proposed scope，不能在一个passing manifest内静默少发布。

第一阶段`broadVersionRange`禁止开放上界：minimum和maximum必须是normalized major boundary、至少跨越三个major且`minimumInclusive < maximumExclusive`。没有broad proposed scope时整个set字段必须省略；存在任一broad claim时必须一次生成恰好一个non-empty `BroadOSCoverageArtifactSetV1`，禁止多次按claim生成后拼接。`coverageSetID`、每个`coverageID`均为set内unique、1～64 byte bounded opaque ASCII；set的flow/binding必须等于plan与Alpha lineage，candidate/plan/Catalog identity必须与Beta profile逐字段相同。records与全部broad proposed scope按claim hash exact一一对应。每条record的coverage slot唯一算法为：`lowerBoundary=[minimum,nextMajor(minimum))`、`upperBoundary=[previousMajor(maximum),maximum)`、`intermediate=[lower.maximum,upper.minimum)`；三段必须non-empty、互不重叠并exact覆盖range。

每个slot始终存在。`slotOutcome=passed`时必须恰有一个representative exact build，`evidenceRefs[]`至少精确闭合`T-004/exact-os-build-claim-evidence-l4`和`T-021/device-matrix-exact-build-l4`、来自同flow/binding/candidate/contract/policy的passing current-candidate scenario并落入对应slot，且`blockerCodes[]`为空。同slot存在多个完整passing exact build时，builder按`osVersion,osBuild` canonical byte order选择最小build作为representative，caller没有选择权；其余参与判定的valid refs仍保留并排序。不存在passing pair但存在同slot有效failed ref时为`failed`；设备、前提或成对证据不足时为`unknown`。failed/unknown slot必须省略representative，可以保留零个或多个已验证partial/negative evidence ref，并至少有一个bounded blocker code；无证据的unknown使用固定`coverage.missing-exact-evidence`，不得用占位build伪装representative。`recordOutcome`机械聚合三个slot：任一failed则failed，否则任一unknown则unknown，否则passed；record `blockerCodes[]`必须是三个slot blocker的canonical unique union，passed record为空。set `coverageOutcome`对全部record使用同一规则。set绑定`evaluatedAtUTC`，不能按当前连接设备临时移动slot。broad coverage EvidenceRun必须把输入set的exact canonical bytes保存为role=`broadOSCoverageSet`的file artifact，并为每个claim、每个broad member生成一个scenario，完整投影record outcome、refs与record blocker；因此missing slot会形成可审计unknown scenario，而不是缺失artifact。

M3-014 freeze和External Beta只接受`coverageOutcome=passed`的set；failed/unknown set保持release No-Go。更窄bounded range仍使用`subtractSameKind`；改为已有证据的`exactBuildSet`必须以该failed/unknown broad scenario和retained exact-build records重开M3-010A，执行唯一`boundedRangeToVerifiedExactSet` operator、重跑M0/M2 Gate并开始new release flow，不能在M3-019或build-profile内直接改scope。Formal逐字段继承passing Beta的完整passed set，不重新选代表或拆分records。

coverage canonical顺序固定为：set `records[]`按`claimScopeHash`，每条`representativeSlots[]`严格按`lowerBoundary,intermediate,upperBoundary`角色顺序，record/slot `blockerCodes[]`按ASCII，slot内`evidenceRefs[]`按`requirementID,scenarioID,evidenceRunID`。claim hash和完整set hash必须重算；单record不建立第二份独立hash authority。duplicate claim/coverage/slot/ref、role乱序、outcome聚合不一致、passed slot缺representative、non-passed slot携带representative、record range与claim不一致、missing/extra broad claim或同candidate生成第二个set均fail closed。

`PublicReleaseScopeIdentityV1`只表达公开承诺，不含`ActuallyVerifiedScopeV1`。manifest中的`proposedReleaseScopes[]`和`releasedCapabilityScopes[]`必须与identity两个数组exact projection且hash可重算；`actuallyVerifiedScopes[]`只按selection独立校验。Formal的proposed/released scope与identity必须逐字段等于passing Beta。Formal可以因三轮cohort新增ActuallyVerified provenance，但去掉`evidenceRunIDs[]`后的每个actually-verified capability/OS scope key都必须是Beta released scope的子集，不能首次扩大公开范围。

```text
PRD ceiling + Catalog/public exposure + negative-removal
  -> proposedReleaseScopes
  -> broad claim exists?
       no  -> coverage input omitted
       yes -> exact matching BroadOSCoverageArtifactSetV1(passed)
  -> ReleaseGateProfile required set
  -> exact requirement aggregation
  -> actuallyVerifiedScopes
  -> releasedCapabilityScopes
```

`ReconnectReadinessProfileV1` 为 `reconnectReadinessProfiles[]` 的元素：

```text
ReconnectReadinessProfileV1:
  schemaVersion=1
  profileID
  deviceClass=iPhone
  osVersionRange{minimumInclusive,maximumExclusive}
  releasedRuntimeControlCapabilityIDs[]
  geometryRequiredCapabilityIDs[]  # subset

profileHash = SHA-256(
  "pulsephone.reconnect-readiness-profile.v1\0" + repositoryCanonicalJSON.v1 bytes
)
```

verification/profile/evidence/Product Action/feature ID arrays按ASCII byte order排序；scope arrays按移除`evidenceRunIDs`后的canonical scope projection bytes排序。对象数组固定排序为：ReleaseGate environmentProfiles按`profileID`，requirements和verificationResults按`requirementID,verificationID,scopeProjectionHash,environmentProfileHash`，selectedEvidenceRuns按`evidenceRunID`，EvidenceRun scenarioResults按`scenarioID`，artifacts按`artifactID`，BroadOSCoverage set records按`claimScopeHash`、slot按固定lower/intermediate/upper、record/slot blocker按ASCII、slot evidence refs按`requirementID,scenarioID,evidenceRunID`，reconnectReadinessProfiles按`profileID`。NegativeRemoval和Formal ledger的更细顺序分别服从本节对应合同。reconnect profile的bounded OS range必须是同一device class某个released scope的子集，且capability集合精确匹配；metrics必须回显同一profileID/hash。ID/hash/profile/capability不一致时该轮evidence无效。内部`prep.*`和Runtime control capability不得进入actuallyVerified/released public scope；它们只出现在verification scope或`ReconnectReadinessProfileV1`。

validator invariants：

- `requirementID + verificationID + scopeProjectionHash + environmentProfileHash`结果唯一，禁止duplicate/conflicting result；profile required set与manifest required result集合精确相等。
- selection set ID/hash/fixed package artifact必须与manifest一致；每个entry必须对应exact profile tuple。普通tuple最多一个scenario；Formal cohort必须由同一StageRunAttemptLedger/series的ordinal `1,2,3`闭合。Gate passing时普通tuple恰好1个passing scenario，cohort恰好3个passing且连续完整；failed/unknown attempt、ledger gap或跨series cherry-pick均失败。
- 同一`evidenceRunID`的store ref/hash/role在全部entry一致；`selectedEvidenceRuns[]`是selection scenario run加threshold baseline/freeze run的exact dedup projection。`verificationResults.evidenceRunIDs[]`必须exact等于对应entry的unique run set。
- 每个`ActuallyVerifiedScopeV1.evidenceRunIDs[]`必须恰好等于投影到该scope、`applicable + passed + currentCandidateEvidence`且声明`supportsActuallyVerifiedReview`的result run ID union；不能包含threshold/legal、N/A、failed/unknown或其他scope run。
- proposed scope必须由PRD ceiling、Catalog/public exposure和negative-removal派生；每个actuallyVerified Product Action/feature必须存在同candidate、同scope/environment的passed required result；released scope只从proposed scope、profile、actuallyVerified和stage rule派生，caller不能独立填入。passing stage的released/proposed exact相同，且`PublicReleaseScopeIdentityV1`只与manifest proposed/released两个字段互为exact projection；ActuallyVerified独立按selection投影。
- 普通failed/unknown stage的released scope必须为空且public identity必须是`proposed + empty released`；Formal provisional必须继承Beta public identity但只能由`manifestState`进入finalize路径。省略identity、在non-passing普通stage保留部分released scope或把provisional称为published均invalid。
- `currentCandidateEvidence`只能闭合same-candidate result；`thresholdProvenance`只能被threshold profile列出的baseline/freeze引用且不能进入actuallyVerified；`reusableLegalMaterial`只能闭合exact material/use-scope requirement。selected run role还必须被对应ReleaseRequirement的EvidenceRolePolicy允许；role与requirement、artifact内容任一不匹配时manifest invalid。
- Internal Alpha必须同时省略performance threshold ref/profile/hash、performanceThresholdFreeze和previousStageManifest；External Beta必须嵌入freeze-held完整threshold profile与唯一freeze对象，且manifest/profile/freeze hold的`releaseFlowID`逐字段相同。
- `formalFinalization`仅final Formal存在，且ID/hash/path必须解析到同package canonical ReleaseHoldSet；该set恰好覆盖lineage selected EvidenceRun union与三份stage manifest hold。Formal provisional及Alpha/Beta出现该字段或artifact均invalid。
- Formal必须取回并重新验证passing External Beta manifest；Beta与Formal的`releaseFlowID`、candidate及其sourceCommit、ImplementationContractIdentity、evidence policy、NegativeRemovalPlan、threshold profile ID/hash、freeze对象、BroadOSCoverage set和PublicReleaseScopeIdentity逐字段相同。selected EvidenceRun各自保留exact `runnerSource`，不要求等于candidate source或彼此相同；只有Formal multiplicity cohort三个ordinal必须同runner commit。ActuallyVerified provenance按Formal selection重投影，可以新增三轮run ID，但去除run ID后的scope key不得超出Beta released scope。任何candidate、contract、policy、plan或public scope变化都必须按§36.1开始new flow并重新经过External Beta；runner-only证据替换按§36.1窄回退执行。
- freeze对象必须唯一指向一个`thresholdProvenance` run；其store record、profile/approval artifact exact bytes与嵌入对象和hash一致，`freezeHoldID`解析出的hold reason为`thresholdFreeze`，且hold在首个Beta run开始前生效。
- `scopeKind=global`时host/device均absent；`host|device`时恰好一个对应对象存在；ReleaseGateScope exact version/build与range字段不能同时存在；Proposed/Released device OS claim必须满足exactBuildSet/broadVersionRange互斥branch。所有public/reconnect broad range必须有finite maximumExclusive；每个public broad claim必须有exact一份三slot coverage record，passing Beta要求set/record/slot全部passed，Formal与Beta逐字段一致。
- 所有ID arrays必须unique并按ASCII排序；public Product Action/feature arrays只允许在scopeKind global的system requirement中为空，此时由requirementID唯一标识。

### 36.1 Release input invalidation 与回退

release artifact一律immutable；“失效”只改变它能否被后续manifest选择，不删除、覆盖或改写历史bytes。每个stage从既有字段机械形成current input projection：

```text
candidate sourceCommit
+ candidate identity when stage requires it
+ ImplementationContractIdentity
+ EvidencePolicy identity
+ ReleaseGateProfile identity
    + exact NegativeRemovalPlan identity
    + proposed scope / bounded broad coverage
+ PublicReleaseScopeIdentity when a passing predecessor exists
+ PerformanceContract / threshold profile when applicable
       |
       v
current release input projection
```

任一owner输出变化时先按下表分类，再重算受影响的canonical identity；TODO保留旧Timeline/evidence记录，并为重跑追加新attempt。不得原地修manifest、复用已失效passing结论或只重跑最后一个validator。

```text
candidate/app/contract/policy/public-scope/performance-contract changed
  -> supersede transitive candidate/profile/stage artifacts
  -> new flow from earliest changed owner

runner/test/probe implementation only changed
  -> keep immutable candidate and flow identities
  -> supersede only affected EvidenceRuns and dependent stage manifests
  -> rerun earliest affected evidence owner and downstream aggregation

TODO/Pitfalls/result bookkeeping only changed
  -> no product/release identity invalidation
```

```text
upstream input changed
  -> find earliest changed owner task
  -> invalidate every transitive downstream artifact
  -> rerun changed owner and affected M0/M2 Gate
  -> rebuild/sign candidate when bundle/source bytes changed
  -> rerun required device/clean-host evidence
  -> regenerate stage profile and manifest
```

统一回退规则：

- 每个new flow在passing Alpha后、M3-009 final candidate前恰形成一份active M3-010A plan；它可以是no-change，也可以在valid grant、全surface revision和M0/M2 remediation Gate闭合后把source anchor变为plan result，并保持同一flow。若lineage已有prior plan，本flow active plan必须显式输入其record并生成绑定new flow/binding的superseding plan；repository已反映prior result时通常是`source == result` no-change，但不能省略pointer。只有active plan可供本flow candidate/freeze/Beta使用。
- active plan finalized后出现removable late evidence时，允许在同flow再生成一份superseding terminal remediation plan：source anchor取active plan result，authority scenario必须来自同flow，完成grant/M0/M2/source commit/clean finalize后立即把该flow及全部candidate/stage artifact标为superseded；terminal plan不得再进入本flow M3-009/freeze/Beta。随后必须重建M3-010 review、创建new Alpha flow，并显式以terminal plan record生成new-flow active plan。其他未经过该路径的candidate/app/contract/policy/public surface变化直接终止flow。
- `runnerSource`变化本身不重建candidate或flow。若变化只是另一个task/治理commit，已有run继续由其exact clean commit审计；若runner owner确认旧实现使证据失效，则标记对应run及引用它的stage manifest为superseded，在同flow重跑受影响evidence与最早stage aggregator。只有重跑同时改变candidate/contract/policy/public scope时才升级为上一条new-flow路径。
- Alpha后、首个M3-014 baseline开始前，允许一次`developmentAssembly -> signedNotarized` candidate转换保留flow。final input必须逐字段匹配本flow plan result、performance contract和scope；candidate source commit可以因该plan授权的remediation和governance-only commits不同于Alpha，但任何未授权product byte/contract差异仍终止flow。M3-009/M3-011/M3-019/M3-020及Beta所需same-candidate evidence绑定新candidate。从第一条M3-014 baseline开始，baseline/freeze/profile已绑定final candidate，任何candidate变化都终止flow并从M3-013重启，不能只替换candidate ref或沿用freeze。
- 首个Beta run开始后，candidate及其source、contract、policy、NegativeRemovalPlan、threshold profile、broad coverage或Beta PublicReleaseScopeIdentity任一变化都终止flow并从M3-013重启；Formal只重投影ActuallyVerified provenance，不提供late public-scope例外。
- M3-017只创建holds并finalize既有passing Formal输入。若finalize发现任何identity或docs/Catalog/help bytes变化，直接失败并按上述最早owner回退。

late device/source/clean-host/Beta evidence使用同一回退机制，不建立stage-specific补丁分支：

```text
new failed/unknown immutable evidence
  -> productGate?
       yes -> current stage No-Go; keep artifact for audit
       no  -> reopen M3-010A in old flow
              -> source anchor = active plan result
              -> create superseding terminal plan from same-flow scenario
              -> full-surface removal + contract/policy revision
              -> rerun M0/M2 Gates + grant-only source commit
              -> mark old candidate/evidence/flow superseded
              -> rerun M3-010 clean review from remediation result HEAD
              -> new M3-013 flow + Alpha
              -> new M3-010A active plan with explicit terminal-plan pointer
              -> M3-009/011/019/020
              -> freeze -> Beta -> Formal
```

M3-010A每次重开必须追加新attempt、新write grant和新plan ID；旧attempt、grant、plan、stage manifest和failed/unknown evidence保持immutable。新grant用typed `sourceRefs[]`指向触发它的exact legal material artifact或selected evidence scenario，final plan通过完整`supersedesPlan` durable pointer建立可取回链；device、clean-host或stage结果必须先反查到对应selected scenario，stage package/summary本身不构成第三种removal authority。任何plan、contract、policy或scope变化都使旧flow/candidate/downstream evidence整体superseded，禁止只在Formal临时缩scope或只重跑最终validator。

`release-evidence-manifest.sha256`保存exact canonical manifest bytes的lowercase SHA-256，并由release record/tag或CI attestation保留。detached hash只证明完整性，不替代签名或来源认证。

## 37. 性能测量合同

### 37.1 时间与统计

所有 duration 使用 `mach_continuous_time` 转换的 monotonicNs。UTC 只用于报告时间。

达到 capability ready 后 warmup 10 秒；reconnect 后重新 warmup。FPS/CPU/RSS 使用完整 1 秒 bucket。

```text
latency/reconnect: p50/p95/p99/max
FPS:               p05/p50/p95/min
CPU/RSS:           p50/p95/max
percentile:        nearest-rank, no interpolation, no outlier trimming
```

三轮基线分别判定，不合并样本。

只允许排除明确记录的 initial/reconnect warmup 和 source-unbound segment。绑定有效期间的卡顿、零帧和 latency spike 不得删除；stability duration 包含 warmup、disconnect、reconnect 和 recovery。

Debug metrics panel 是只读紧凑模块，1 Hz 更新，不改变 toolbar、Scheduler 或主体流程。正式基线可以隐藏 panel，但 collector 必须继续工作。

### 37.2 指标边界

```text
AVCapture bound frame delegate t0
  -> display layer enqueue complete t1
  hostVideoPipelineLatencyMs = t1 - t0

Client StreamFrame submit t0
  -> Helper validates and writes transport/service t1
  touchDeliveryLatencyMs = t1 - t0

GUI AppKit accepts pointer mouseDown p0
  -> logical StreamOpen complete p1
  -> matching begin acceptedForDelivery p2
  -> physical device begins responding p3
  -> bound Live video presents the result p4
  pointer first-contact diagnostic = p1/p2/p3/p4 - p0

usbmux Attach t0
  -> released Runtime control capability set ready t1
  controlReconnectMs = t1 - t0

same Attach t0
  -> first verified new-epoch video frame enqueued t1
  videoReconnectMs = t1 - t0
```

不得把 host video latency 称为端到端视频延迟，不得把 touch delivery 称为 iPhone UI 已绘制。pointer first-contact diagnostic必须包含Stream admission之前的时间，不能从p1或Client StreamFrame submit重新起算；在对应registry/schema正式演进前，它是有界diagnostic observation，不得伪装成现有`touchDeliveryLatencyMs`样本。

### 37.3 Resource metrics

```text
previewFPS
hostVideoPipelineLatencyMs
touchDeliveryLatencyMs
cpuTotalPercent
rssTotalMiB
rssGrowthMiBPerHour
controlReconnectMs
videoReconnectMs
```

完整定义：

| Metric | Sampling contract |
| --- | --- |
| `previewFPS` | verified bound distinct frame完成display enqueue计1；绑定有效但1秒无帧必须产生0 bucket；同时记录received/enqueued/dropped/max gap |
| `hostVideoPipelineLatencyMs` | 每个enqueued frame一个样本；只表示Mac host pipeline |
| `touchDeliveryLatencyMs` | 只统计forwarded且acceptedForDelivery frame；按begin/move/end/cancel分类；rejected/coalesced/unconfirmed单独计数 |
| `cpuTotalPercent` | 每秒进程user+system CPU delta / monotonic elapsed；100%=1 logical core；进程合计可>100% |
| `rssTotalMiB` | 每秒目标进程resident bytes求和；报告steady percentiles和whole-run max |
| `rssGrowthMiBPerHour` | run>=10min时，`(last 5min RSS median - first 5min RSS median) / run hours` |
| `controlReconnectMs` | 终点由release manifest profile固定；released set含坐标输入时才要求input+geometry；无适用control capability记录notApplicable，不制造latency |
| `videoReconnectMs` | Camera denied或video未发布时notApplicable；错绑帧是P0 failure；未恢复记录notRecovered |

CPU/RSS `p50/p95/max` 只统计 post-warmup steady buckets；`wholeRunMax` 必须包含 warmup、disconnect 和 reconnect。

正式单设备基线只运行一个 live，不运行其他 PulsePhone device task。进程集合：GUIHost + target Runtime + identity-verified current/retiring Helper descendants。

短 CLI、CoreMediaIO、WindowServer 不计入。GUIHost 同时承载其他设备窗口时该轮不能作为正式基线。

### 37.4 Stability

```text
Internal Alpha  30 min + 5 reconnects
External Beta    2 h   + 20 reconnects
Formal Release   8 h   + 50 reconnects, 3 consecutive runs
```

Formal的“三轮”只绑定`formal.stability-performance.v1` cohort：`T-018/stability-stage-run-l5`和`T-018/performance-threshold-evaluation-l5`必须来自同一StageRunAttemptLedger/series的三轮8 h + 50 reconnect run；failed/unknown关闭series，不能跨attempt挑选。其他Formal requirement从passing Beta lineage复用一次，或在Formal补充一次，不重复整个release matrix三遍。

每轮导出 crash、wrong target/frame、duplicate generation、foreign signal、lock leak、duplicate terminal、reconnect outcome、frame gap、runtimeFatal、outcomeUnknown 和 metrics gap。

crash、错目标、重复 Runtime/同角色 Helper、误杀、lock/generation 泄漏、duplicate terminal 立即判定失败。

External Beta 前至少三轮基线并冻结`PerformanceThresholdProfileV1`；首个Beta threshold run后不得在同一release flow临时放宽。Audio 第一阶段只验证功能和 stability，不定义 latency SLA。

### 37.5 Metrics export

导出 schema：

```text
pulsephone.metrics.v1
  schemaVersion / metricsSessionID
  performanceContract{revision,sha256}
  evaluationMode = baseline | threshold
  measurementProfileID / measurementProfileHash
  thresholdProfileID? / thresholdProfileHash?    # threshold mode required
  thresholdSetID?                                # threshold mode required
  startedAtUTC / endedAtUTC / monotonicDurationMs
  appBuild / buildConfiguration / metricsEnabled
  macModel / macOSBuild / architecture / logicalCPUCount
  displayRefreshRateMilliHz
  deviceClass / productType / iOSBuild / targetUDIDHash
  captureWidthPixels / captureHeightPixels / nominalCaptureFPSMilli
  windowWidthPixels / windowHeightPixels / audioMute
  warmupMs / bucketMs
  runtimeEpochs[] / connectionEpochs[] / sourceEpochs[]
  excludedSegments[]
  previewFPS{bucketCount,p05,p50,p95,min,maxInterFrameGapMs,received,enqueued,dropped}
  hostVideoPipelineLatencyMs{count,p50,p95,p99,max}
  touchDeliveryLatencyMs{count,byFrameKind,p50,p95,p99,max,rejected,coalesced,unconfirmed}
  cpuTotalPercent{p50,p95,max,wholeRunMax}
  rssTotalMiB{p50,p95,max,wholeRunMax,growthMiBPerHour}
  reconnectReadinessProfileID / reconnectReadinessProfileHash
  reconnects[{attemptID,control{outcome,ms?,reason?},video{outcome,ms?,reason?}}]
  stability{durationMs,counters...,passed,failureReasons[]}
  gateValues[]:
    ruleID
    metricID
    statisticID
    canonicalUnitID
    applicability = applicable | notApplicable
    dataQuality = complete | gap | notRecovered
    observedScaledValue?                       # Int64; complete+applicable only
    sampleCount
    notApplicableReasonCode?
    unknownReasonCode?
```

`gateValues[]`按`ruleID` ASCII排序且唯一；metric/statistic/unit/applicability必须与performance registry一致。baseline mode必须省略threshold profile/set，threshold mode必须绑定exact profile/set。`dataQuality != complete`时不得携带`observedScaledValue`且evaluation只能是`unknown`。metrics文件不携带阈值`passed/failed`；collector按冻结算法生成integer gate value，evaluator只读取`gateValues[]`和profile rules重新比较。

`targetUDIDHash` 使用 TRD 01 §7.1 / TRD 07 §30.1 定义的 `H = lowercase hex SHA-256("pulsephone.udid.v1\0" + canonicalUDID)`；导出不得包含 canonical UDID、坐标、键值或文本。collector 失败只使 performance evidence 无效，不能改变产品 command result。

`pulsephone.metrics.v1`是internal/restricted evidence，不进入公开`dist/`。若未来需要公开性能数据，必须先通过正式schema变更新增不含`targetUDIDHash`、epoch/run internal ID和restricted artifact reference的独立public projection；第一阶段不把内部metrics文件直接公开。

跨进程 latency timestamp：

```text
StreamFrame.clientSubmittedMonotonicNs
FrameAccepted.acceptedMonotonicNs
usbmux attachObservedMonotonicNs
```

这些字段只用于诊断采样，不参与 admission、ordering、result、retry 或 deadline；缺失只使该样本无效。Runtime 收到 FrameAccepted 的 IPC 时间不计入 touchDeliveryLatencyMs。

### 37.6 Performance contract identity

metric、statistic、comparator、canonical unit和applicability的唯一tracked真源是：

```text
PerformanceContractIdentityV1
|
+-- Registries/performance-metrics.v1.json
`-- Schemas/evidence/
    +-- pulsephone.metrics.v1.schema.json
    +-- performance-measurement-profile.v1.schema.json
    +-- performance-threshold-decision.v1.schema.json
    +-- performance-threshold-profile.v1.schema.json
    +-- performance-threshold-approval.v1.schema.json
    `-- performance-evaluation.v1.schema.json
```

该集合复用`RepositoryContractArtifactSetV1`规则，并使用：

```text
PerformanceContractIdentityV1:
  revision                         # performance-metrics.v1.json root revision
  sha256                           # aggregate set hash below

performanceContractSHA256 = SHA-256(
  "pulsephone.performance-contract-artifact-set.v1\0"
  + repositoryCanonicalJSON.v1 artifact-set bytes
)
```

`performance-metrics.v1.json`根与每个metric row固定：

```text
schemaVersion = 1
revision
metricID
allowedStatisticIDs[]
requiredRuleIDs[]
comparator = lessThanOrEqual | greaterThanOrEqual
canonicalUnitID
applicabilityRuleID
collectorContractVersion
evaluatorContractVersion
```

禁止JSON浮点阈值。所有比较值使用registry声明的scaled integer：

```text
previewFPS                  milliFramesPerSecond
latency/reconnect           microseconds
cpuTotalPercent             milliPercent
rssTotalMiB                 kibibytes
rssGrowthMiBPerHour         kibibytesPerHour, Int64
```

### 37.7 Measurement 与 threshold profile

每个可比较threshold set嵌入完整measurement profile：

```text
PerformanceMeasurementProfileV1:
  profileID
  buildConfiguration = release
  host{architecture,macModel,macOSBuild,logicalCPUCount,
       displayRefreshRateMilliHz}
  device{deviceClass,productType,osBuild}
  capture{widthPixels,heightPixels,nominalFPSMilli,
          windowWidthPixels,windowHeightPixels,audioMute}
  processSetProfileID = single-live.v1
  evidenceEnvironmentProfileID
  evidenceEnvironmentProfileHash
  reconnectReadinessProfileID?
  reconnectReadinessProfileHash?

measurementProfileHash = SHA-256(
  "pulsephone.performance-measurement-profile.v1\0"
  + repositoryCanonicalJSON.v1 PerformanceMeasurementProfileV1 bytes
)
```

三轮baseline必须分别finalize并写入EvidenceStore；release owner的外部输入是restricted canonical decision，而不是自由文本或交互式隐含状态：

```text
PerformanceThresholdDecisionV1:
  schemaVersion = 1
  decisionID
  releaseFlowID
  evidenceStoreBindingID
  alphaStage:
    stageManifestID
    manifestStoreRef
    storeRecordSHA256
    manifestSHA256
  performanceContract{revision,sha256}
  evidencePolicy{policyID,hash}
  releaseScopeInput:
    candidateInputHash
    negativeRemovalPlanHash
    broadOSCoverageSetHash?
  decidedAtUTC
  decidedByRole = releaseOwner
  decision = approved
  authorizationRecordRef             # bounded opaque ID; not path/URL/person
  baselineRecords[]:                 # at least 3; unique; ASCII evidenceRunID
    evidenceRunID
    manifestStoreRef
    storeRecordSHA256
    manifestSHA256
  thresholdSets[]:
    thresholdSetID
    scopeProjection                    # full derived ReleaseGateScopeV1
    scopeProjectionHash
    environmentProfileID
    environmentProfileHash
    measurementProfileID
    measurementProfileHash
    rules[]:
      ruleID
      applicability = applicable | notApplicable
      comparator?
      canonicalUnitID?
      limitScaledValue?              # Int64; applicable only
      notApplicableReasonCode?

performanceThresholdDecisionHash = SHA-256(
  "pulsephone.performance-threshold-decision.v1\0"
  + repositoryCanonicalJSON.v1 PerformanceThresholdDecisionV1 bytes
)
```

decision必须exact覆盖registry与M3-009 final candidate、validated plan及M3-019 coverage set共同派生的全部performance scope/rule；caller不能新增、删除或改写scope。每个`scopeProjectionHash`必须按完整projection重算，且decision的`releaseScopeInput`与freeze command输入逐字段相同。适用rule缺limit、单位/comparator不匹配、baseline少于3个、store record无法取回、profile/environment不一致、baseline不是同一final signed candidate或任一baseline非valid均失败。机器不能自行把观测值写成批准阈值；`EXT-008`只在tool生成完整scope/rule模板后填写limit/applicability、authorization ref和批准字段。

冻结阈值artifact为：

```text
PerformanceThresholdProfileV1:
  schemaVersion = 1
  releaseFlowID
  evidenceStoreBindingID
  profileID
  frozenAtUTC
  frozenByRole = releaseOwner
  applicableReleaseStages[] = [externalBeta, formalRelease]
  baselineCandidate{buildID,appVersion,appBundleContentHash}
  baselineSource{gitCommit,worktreeState=clean}
  releaseScopeInput:
    candidateInputHash
    negativeRemovalPlanHash
    broadOSCoverageSetHash?
  implementationContractIdentity
  performanceContract{revision,sha256}
  evidencePolicy{policyID,hash}
  thresholdDecision{decisionID,decisionHash}
  thresholdSets[]:
    thresholdSetID
    scopeProjection
    scopeProjectionHash
    environmentProfile                 # full EvidenceEnvironmentProfileV1
    environmentProfileHash
    measurementProfile                 # full PerformanceMeasurementProfileV1
    measurementProfileHash
    reconnectReadinessProfileID?
    reconnectReadinessProfileHash?
    baselineRuns[]:                     # at least 3
      evidenceRunID
      manifestStoreRef
      storeRecordSHA256
      manifestSHA256
      metricsArtifactID
      metricsArtifactSHA256
      observedValues[]:
        ruleID
        observedScaledValue
    rules[]:
      ruleID
      requirementID
      metricID
      statisticID
      applicability = applicable | notApplicable
      comparator?
      canonicalUnitID?
      limitScaledValue?
      notApplicableReasonCode?

performanceThresholdProfileHash = SHA-256(
  "pulsephone.performance-threshold-profile.v1\0"
  + repositoryCanonicalJSON.v1 PerformanceThresholdProfileV1 bytes
)
```

阈值批准使用独立restricted artifact，不把人员身份或自由文本塞进profile：

```text
PerformanceThresholdApprovalV1:
  schemaVersion = 1
  approvalID
  releaseFlowID
  evidenceStoreBindingID
  thresholdProfileID
  thresholdProfileHash
  thresholdDecisionID
  thresholdDecisionHash
  approvedAtUTC
  approvedByRole = releaseOwner
  decision = approved
  baselineEvidenceRunIDs[]                 # exact decision set; ASCII sorted
```

实际profile不提交Git。`M3-014`将其写入：

```text
build/evidence/objects/<freezeRunPathKey>/artifacts/
+-- performance-threshold-decision.v1.json
+-- performance-threshold-profile.v1.json
`-- performance-threshold-approval.v1.json
```

freeze run必须恰好包含decision、profile和approval三个restricted canonical artifact；profile/approval中的decision ID/hash必须从同package decision exact bytes重算，三者的flow、final candidate、scope input、baseline集合和threshold set必须互相投影。finalize后立即写入immutable evidence store并建立freeze hold，使decision原字节与profile一起可取回复验。ReleaseEvidence嵌入完整canonical profile及其hash；`thresholdProvenance`引用至少三轮baseline和freeze run。baseline、External Beta和Formal全部绑定M3-009同一final signed candidate、ImplementationContractIdentity、performance contract、evidence policy和派生performance scope；每个stage仍必须用自己的same-candidate run通过全部rule。

### 37.8 Freeze 与 evaluation lifecycle

```text
M3-012  metric registry + schemas + collector/evaluator
   |
   v
M3-013  bind durable EvidenceStore + create releaseFlowID
         + Alpha collector smoke/manifest; no threshold
   |
   v
M3-009 + M3-010A + M3-019
         -> final signed candidate + final plan + bounded scope/coverage
   |
   v
M3-014  consume exact Alpha releaseFlowID and final scope inputs
         -> >=3 independent baseline runs, each finalize + store
         -> consume releaseOwner PerformanceThresholdDecisionV1
         -> canonical decision + profile + approval artifacts
         -> immutable store + freeze hold
   |
   +--> M3-015 External Beta evaluates frozen profile
   |       |
   |       v
   `--> M3-016 Formal references passing Beta manifest
           -> same flow/candidate/contract/policy/profile
           -> same PublicReleaseScopeIdentity / bounded coverage
           -> append-only attempt ledger
           -> one series with ordinals 1,2,3, each judged independently
           |
           v
         M3-017 hold selected + lineage packages, persist hold set, finalize
```

current candidate evaluation使用：

```text
PerformanceEvaluationV1:
  schemaVersion = 1
  evaluationID
  releaseFlowID
  evidenceStoreBindingID
  candidate{buildID,appVersion,appBundleContentHash}
  performanceContract{revision,sha256}
  measurementProfileID
  measurementProfileHash
  thresholdProfileID
  thresholdProfileHash
  thresholdSetID
  metricsArtifactID
  metricsArtifactSHA256
  ruleResults[]:
    ruleID
    metricID
    statisticID
    canonicalUnitID
    observedScaledValue?
    limitScaledValue?
    comparator?
    applicability
    outcome = passed | failed | unknown
    reasonCode?
  overallOutcome = passed | failed | unknown
```

validator必须从metrics artifact的`gateValues[]`重算每条比较，不能信任export或evaluation中的自报结果。metrics、evaluation、EvidenceRun的performance contract、measurement profile和threshold profile必须逐字段相同；rule set只能从performance registry、proposed scope和applicability rule派生。applicable rule缺少comparator/unit/value、artifact缺失、metrics gap、无法重算或环境/profile不一致均为`unknown`。每个threshold set至少三轮唯一、valid、同environment/measurement profile的baseline；baseline三轮与Formal cohort三轮分别逐轮判定，禁止合并sample或average掩盖失败。Formal每个ordinal必须同时闭合stability和threshold evaluation，不能用一轮stability搭配另一轮performance；attempt ledger中任何failed/unknown或缺失terminal都终止series并阻止后续ordinal沿用。

freeze run必须恰好包含一个`performanceThresholdDecision`、一个`performanceThresholdProfile`和一个`performanceThresholdApproval` artifact；decision/profile/approval的flow、final candidate、scope input、profile和baseline集合逐字段相同。profile必须在首个External Beta threshold run开始前写入本flow已冻结的durable EvidenceStore并建立`thresholdFreeze` hold，临时adapter不能承接该身份。首个Beta run后，不得在同一release flow生成更宽松profile；需要修改阈值时必须结束当前flow、形成新的有依据baseline/freeze记录并重新进入Beta。Formal必须引用passing External Beta manifest，且两者flow/candidate/contract/policy/profile完全相同。`M3-017`必须为threshold freeze、全部baseline、Beta和Formal evaluation package另建`selectedForRelease` hold；既有freeze hold不能代替最终hold-set成员。

M3-014必须消费M3-013 passing Alpha stage store record、M3-009 final `ReleaseCandidateInputV1`、M3-010A finalized `NegativeRemovalPlanV1`和M3-019完整且`coverageOutcome=passed`的`BroadOSCoverageArtifactSetV1`（没有broad claim时显式省略set参数）。tool从后三者使用与Beta build-profile相同的scope derivation生成performance scope/rule模板，再运行baseline和接受release owner decision；caller不能提交独立scope。failed/unknown set只能作为remediation evidence，不能冻结threshold。baseline、decision-template和freeze API统一接受`--alpha-stage-record`及上述final scope inputs；hold API接受同一Alpha record与freeze store record，并重新验证freeze内嵌candidate/plan/coverage，不接受本地Alpha manifest path或独立`releaseFlowID`参数。decision中的`alphaStage`必须是该record的exact pointer projection：`stageManifestID == packageID`，且`manifestStoreRef`、`storeRecordSHA256`和`manifestSHA256`逐字段相同；record还必须满足`packageKind=releaseStageManifest`、`packageState=finalized`，取回的manifest必须是`internalAlpha + immutableStageResult + passed`并与decision顶层`releaseFlowID`、`evidencePolicy`一致。configured store binding必须等于Alpha flow binding，final candidate/plan/coverage hash必须等于decision/profile的`releaseScopeInput`。任一字段缺失、hash invalid、stage/outcome/state不符、scope不闭合或flow ID已用于另一流程时直接失败。

三轮baseline除same candidate/performance contract/policy/environment/measurement profile外，还必须来自同一clean `runnerSource.gitCommit`；decision-template机械验证该字段并把它纳入baseline comparability。任一轮更换collector/runner commit都使三轮集合不可比较，必须废弃该集合并从第一轮重采，不能只重跑受影响的一轮。

## 38. 项目目录与产物结构

本节是第一阶段repository root、module、registry/schema root和test target的规范目录，不再使用“建议结构”口径。新增root/module/test target或移动bundle lookup时必须同步SwiftPM、packaging和本文；`Fixtures/`与`Verification/`的 leaf layout、case identity 和 requirement ownership 由其 schema、registry、runner adapter 与自动化测试共同校验，本文只列顶层 root，避免双维护。

### 38.1 Repository root

```text
PulsePhone/
+-- .gitignore
+-- Package.swift
+-- Makefile
+-- README.md
+-- Sources/
|   +-- PulsePhoneExecutable/
|   +-- PulsePhoneCLI/
|   +-- PulsePhoneGUI/
|   +-- PulsePhoneClientCore/
|   +-- PulsePhoneMedia/
|   +-- PulsePhoneSharedDefinitions/
|   +-- PulsePhoneCommandCatalog/
|   +-- PulsePhoneCommandPlanner/
|   +-- PulsePhoneAvailability/
|   +-- PulsePhoneWire/
|   |   +-- Generated/                   # tracked generated Swift bindings
|   +-- PulsePhoneHostPaths/
|   +-- PulsePhoneDeveloperSupportDefinitions/
|   +-- PulsePhoneRuntimeExecutable/
|   +-- PulsePhoneRuntimeKernel/
|   +-- PulsePhoneRuntimeState/
|   +-- PulsePhoneBackendAdapters/
|   +-- PulsePhoneDeveloperImageAssets/
|   +-- PulsePhoneLogging/
|
+-- GoHelpers/
|   +-- cmd/pulsephone-direct-helper/
|   +-- cmd/pulsephone-coredevice-helper/
|   +-- internal/{direct,coredevice,protocol}/
|
+-- Registries/
|   +-- command-catalog.v1.json
|   +-- runtime-wire-messages.v1.json
|   +-- runtime-operations.v1.json
|   +-- guihost-wire.v1.json
|   +-- helper-wire.v1.json
|   +-- facts-probe-wire.v1.json
|   +-- standard-errors.v1.json
|   +-- developer-image-catalog.v1.json
|   +-- preparation-groups.v1.json
|   +-- performance-metrics.v1.json
|
+-- Schemas/
|   +-- command-catalog.v1.schema.json
|   +-- wire/
|   +-- result-schemas/
|   +-- details-schemas/
|   +-- developer-support/
|   |   +-- preparation-group.v1.schema.json
|   |   +-- developer-image-catalog.v1.schema.json
|   |   +-- asset-content-manifest.v1.schema.json
|   |   +-- partial-download-state.v1.schema.json
|   |   +-- cache-index.v1.schema.json
|   |   `-- developer-support-provenance.v1.schema.json
|   +-- evidence/
|       +-- evidence-policy.v1.schema.json
|       +-- execution-suites.v1.schema.json
|       +-- release-requirement.v1.schema.json
|       +-- release-flow.v1.schema.json
|       +-- app-bundle-content-manifest.v1.schema.json
|       +-- release-candidate-input.v1.schema.json
|       +-- evidence-selection-set.v1.schema.json
|       +-- stage-run-attempt-ledger.v1.schema.json
|       +-- stage-run-attempt-ledger-wal.v1.schema.json
|       +-- broad-os-coverage-set.v1.schema.json
|       +-- public-release-scope-identity.v1.schema.json
|       +-- stage-gate-outcome-report.v1.schema.json
|       +-- fixture-case.v1.schema.json
|       +-- evidence-run-manifest.v1.schema.json
|       +-- evidence-store-record.v1.schema.json
|       +-- evidence-release-hold.v1.schema.json
|       +-- release-hold-set.v1.schema.json
|       +-- legal-material-record.v1.schema.json
|       +-- negative-removal-write-grant.v1.schema.json
|       +-- negative-removal-plan.v1.schema.json
|       +-- release-gate-profile.v1.schema.json
|       +-- release-evidence-manifest.v1.schema.json
|       +-- final-release-evidence-gate-report.v1.schema.json
|       +-- pulsephone.metrics.v1.schema.json
|       +-- performance-measurement-profile.v1.schema.json
|       +-- performance-threshold-decision.v1.schema.json
|       +-- performance-threshold-profile.v1.schema.json
|       +-- performance-threshold-approval.v1.schema.json
|       `-- performance-evaluation.v1.schema.json
|   +-- implementation/
|       +-- requirement-owner-map.v1.schema.json
|       +-- runner-adapter.v1.schema.json
|       +-- implementation-gate-definition-set.v1.schema.json
|       +-- implementation-gate-report.v1.schema.json
|       `-- repository-source-snapshot.v1.schema.json
|
+-- Verification/
|   +-- evidence-policy.v1.json
|   +-- execution-suites.v1.json
|   +-- requirement-owners.v1.json       # implementation governance; excluded from EvidencePolicy hash
|   +-- implementation-gates.v1.json     # six Gate definitions; separate contract hash
|   +-- runner-adapters/
|   |   +-- T-001/
|   |   +-- ...
|   |   `-- T-021/
|   `-- release-requirements/
|       +-- T-001/
|       +-- ...
|       `-- T-021/
|
+-- Fixtures/
|   +-- contracts/
|   +-- catalog/
|   +-- planner/
|   +-- helper-wire/
|   +-- facts-probe/
|   +-- identity/
|   +-- developer-support/
|   +-- acquisition-http/
|   +-- preparation-lifecycle/
|   +-- evidence/
|   +-- performance/
|   +-- product-actions/
|   +-- product-matrix/
|   +-- requirements/
|   +-- release/
|
+-- Tests/
|   +-- Unit/
|   |   +-- SharedDefinitionsTests/
|   |   +-- RegistryContractTests/
|   |   +-- PythonRegistryTests/
|   |   +-- EvidenceContractTests/
|   |   +-- CommandCatalogTests/
|   |   +-- PlannerTests/
|   |   +-- SchedulerTests/
|   |   +-- LifecycleTests/
|   |   +-- WireCodecTests/
|   |   +-- HostPathTests/
|   |   +-- LoggingTests/
|   |   +-- DeveloperImageCatalogTests/
|   |   +-- PreparationCoordinatorTests/
|   |   +-- CLIContractTests/
|   +-- Integration/
|   |   +-- RuntimeBootstrapTests/
|   |   +-- HelperSupervisorTests/
|   |   +-- GUIHostTests/
|   |   +-- ArtifactFDTests/
|   |   +-- DeveloperImageAssetStoreTests/
|   |   +-- DeveloperSupportHelperTests/
|   |   +-- ProductMatrixTests/
|   |   +-- ProductActionTests/
|   |   +-- PackagingTests/
|   |   +-- FaultInjectionTests/
|   +-- Device/
|   |   +-- IOS14To16Legacy/
|   |   +-- IOS17PlusModern/
|   +-- Performance/
|
+-- Packaging/
|   +-- Info.plist
|   +-- PulsePhone.entitlements
|   +-- manifests/
|   +-- licenses/
|   +-- scripts/
|
+-- Scripts/
|   +-- generate-registries
|   +-- verify-contracts
|   +-- evidence-tool
|   +-- implementation-gate
|   +-- performance-evidence
|   +-- package-app
|   +-- smoke-clean-machine
|
+-- docs/
|   +-- pulsephone-ecosystem-architecture.md
|   +-- pulsephone-prd.md
|   +-- pulsephone-trd.md
|   +-- pulsephone-trd/
|   |   +-- 00-normative-terminology.md
|   |   +-- 01-platform-process-and-identity.md
|   |   +-- 02-command-runtime-and-lifecycle.md
|   |   +-- 03-developer-support-and-preparation.md
|   |   +-- 04-runtime-supervision-and-recovery.md
|   |   +-- 05-ipc-helper-and-probe.md
|   |   +-- 06-product-execution-and-client.md
|   |   +-- 07-artifacts-observability-and-security.md
|   |   +-- 08-delivery-and-verification.md
|
+-- .build/                 # SwiftPM generated, ignored
+-- build/                  # packaging intermediates, ignored
+-- dist/                   # final local artifacts, ignored
    +-- PulsePhone.app
```

### 38.2 SwiftPM targets

```text
PulsePhoneExecutable (executable -> Contents/MacOS/PulsePhone)
  +-- PulsePhoneCLI
  +-- PulsePhoneGUI
  +-- PulsePhoneClientCore
  +-- PulsePhoneMedia
  +-- shared pure targets

PulsePhoneRuntimeExecutable (executable -> Contents/Helpers/PulsePhoneRuntime)
  +-- PulsePhoneRuntimeKernel
  +-- PulsePhoneRuntimeState
  +-- PulsePhoneBackendAdapters
  +-- PulsePhoneDeveloperImageAssets
  +-- PulsePhoneLogging
  +-- shared pure targets

shared pure targets
  +-- PulsePhoneSharedDefinitions
  +-- PulsePhoneCommandCatalog
  +-- PulsePhoneCommandPlanner
  +-- PulsePhoneAvailability
  +-- PulsePhoneWire
  +-- PulsePhoneHostPaths
  +-- PulsePhoneDeveloperSupportDefinitions
```

M0第一批使用以下显式test target/path；SwiftPM不得依赖默认`Tests/<Target>Tests`路径推断：

```text
PulsePhoneSharedDefinitionsTests
  path: Tests/Unit/SharedDefinitionsTests
  dependencies: PulsePhoneSharedDefinitions

PulsePhoneHostPathsTests
  path: Tests/Unit/HostPathTests
  dependencies: PulsePhoneHostPaths, PulsePhoneSharedDefinitions
```

`PulsePhoneDeveloperImageAssets` 只链接 Runtime side 和 shared Developer Support definitions，不链接 GUI/CLI；Helper 通过注册 Wire 使用 catalog reference，不直接解析 Client path。

禁止 `PulsePhoneRuntimeKernel -> PulsePhoneGUI/PulsePhoneCLI/AppKit` 依赖。`PulsePhoneCommandCatalog/Planner` 不依赖 RuntimeKernel 或 Go Helper implementation。

### 38.3 Source to bundle mapping

```text
Repository source                          Packaged destination
-----------------                          --------------------
PulsePhoneExecutable                       Contents/MacOS/PulsePhone
PulsePhoneRuntimeExecutable                Contents/Helpers/PulsePhoneRuntime
GoHelpers/cmd/pulsephone-coredevice-helper  Contents/Helpers/PulsePhoneCoreDeviceHelper
GoHelpers/cmd/pulsephone-direct-helper      Contents/Helpers/PulsePhoneDirectHelper
Registries/*.json                          Contents/Resources/Registries/
Packaging/licenses/ + dependency notices   Contents/Resources/Licenses/
Packaging/Info.plist                       Contents/Info.plist
```

packaging 必须保留 registry canonical bytes/hash fixture 所对应的文件内容；不得在复制阶段重排或重新序列化 JSON。

### 38.4 Generated output

```text
.build/
  SwiftPM objects, modules and test products

build/
  staging/PulsePhone.app
  generated/                    # temporary generation staging; ignored
  contract verification reports
  evidence/objects/<pathKey>/     # ignored local/CI working package; opaque ID never in path
  signing/notarization intermediate files

dist/
  PulsePhone.app
  release-evidence-manifest.json
  release-evidence-manifest.sha256

skills/pulsephone/
  SKILL.md                       # tracked portable Agent contract
  agents/openai.yaml             # tracked Codex UI metadata
```

registry binding的可编译/可打包source of truth必须被Git追踪：Swift输出位于`Sources/PulsePhoneWire/Generated/`，Go输出位于`GoHelpers/internal/protocol/generated/`，保留的 Python 输出位于`Scripts/lib/pulsephone_contracts/generated/`且不进入 app。generator每次从fresh empty `build/generated/`临时树开始，再由显式任务更新tracked output并删除已不再生成的旧文件。`verify-generated`固定为Makefile target，不是第二个generator script；它调用`Scripts/generate-registries`的verify mode，从规范输入重新生成并对normalized relative-path set和regular-file exact bytes做双向比较。missing、extra、symlink、hardlink、其他node type或bytes mismatch均失败。禁止直接编译ignored staging或在build时静默改写source tree。

只有包含签名内嵌Agent Skill资源的`dist/PulsePhone.app`和明确发布材料可以交付。仓库`skills/pulsephone/`是packaging输入和开发校验入口，不携带第二份app；已安装到Agent目录的薄skill也不产生独立candidate identity，不能替代正式release candidate选择、签名/notarization/staple或evidence gate。`Verification/`、`Fixtures/`、`Tests/`、`.build/`、`build/`、device captures、temporary signing files 和本地 Python cache 不进入 app bundle；EvidencePolicy只作为CI/release tooling真源，通过identity/hash进入evidence，不随产品运行时分发。

## 39. 实施顺序

```text
1.  SharedDefinitions / canonical identity / StandardError / HostPath primitives
2.  machine-readable Wire/error/evidence-policy/schema registries + generated validators + golden fixtures
3.  CommandCatalog / Planner / 44-21-6 static coverage and negative exposure
4.  DeveloperImageCatalog / PreparationGroup / OS-profile canonical fixtures
5.  Runtime bootstrap / locks / socket / RuntimeWire Hello and control plane
6.  RuntimeCoordinationActor / Scheduler / lifecycle / inhibitors / wait registry
7.  LocalDeviceFactsProbe / discovery / target selection
8.  HelperSupervisor / HelperWire / anchored catalog-reference validation
9.  DeveloperImageAssetStore / immutable catalog revisions / asset-store lock / source resolver / acquisition / cache / prune
10. PreparationCoordinator / DemandSpec / DemandPersistence / Observer / Attempt / progress/status
11. iOS 14～16 classic query/mount/service vertical slice
12. iOS 17+ personalized/TSS/tunnel/service vertical slice
13. `device.prepare` + implicit preparation + finite command vertical slices
14. Stream pointer/keyboard + cleanup/fencing
15. GUIHost/live/video/audio/source binding and prewarm projection
16. ActionLog / ReplayTrace / Diagnostics / Screenshot FD
17. detach/reconnect/fatal/orphan/acquisition fault injection
18. packaging/legal decision + controlled remediation/performance-contract/final signing/no-Xcode clean-machine/threshold/release evidence
```

不得通过先实现隐藏 route 再补 Catalog 的方式绕过第 3～4 步；后续步骤只能消费已经冻结并经 fixture 验证的 route、source 和 preparation group。

最终candidate与release flow的收口顺序固定为：

```text
M3-002...006 resilience source + M3-012 performance source
M3-007 generated legal bytes -> M3-008 package-app producer qualification
M3-018 pre-Alpha fault closure
                         |
                         v
       M3-010 commit derived legal RunnerAdapters -> clean source closure
          -> clean re-assembly + read-only legal/source decision
          + reviewedDevelopmentCandidateInput in legal package
                         |
M3-012A release tooling + EXT-009 durable store binding
                         |
                         v
       M3-013 clean re-assembly + reviewed/fresh continuity check
          -> create flow + Alpha from fresh development input
                         |
                         v
       M3-010A legal import + preflight grant + no-change/remediation
             |
             v
       M3-009 final signing/hash
             |
             +--> M3-011/020 clean-host/source matrices
             |
             `--> M3-019 exact device evidence + one tri-state broad set
                         |
                         +-- failed/unknown
                         |     -> stored broad scenario
                         |     -> reopen M3-010A + §36.1 new flow
                         |
                         `-- passed, or no broad claim
                               |
                               v
                   M3-014 final-candidate baseline
                         + decision/profile/approval durable freeze
                         |
                         v
                   M3-015 Beta
                         v
                   M3-016 Formal + durable attempt WAL
                         v
                   M3-017 final holds/publish
```

M3-013可在notarization、M3-010A remediation和最终公开scope之前完成Internal Alpha，但M3-010必须先汇合全部pre-Alpha product/bundle-byte owner并在clean HEAD重建review input；M3-013随后再次clean重建，continuity通过后才创建flow，并从第一条evidence起使用最终durable store binding。M3-014只能在M3-009 final signing、M3-010A finalized plan和M3-019 exact/broad scope都稳定后执行；baseline、Beta和Formal统一绑定同一final signed candidate与performance scope。任何M3-010A surface变更、candidate/app/contract/policy/coverage变化或store binding切换都按§36.1终止旧flow并从对应owner重跑；runner-only或governance-onlycommit服从§36.1窄分类，不误判为candidate变化。

## 40. 验证要求

### 40.1 Static/CI

- command-matrix 52/21/44/14/2 与 non-command feature 6 coverage。
- wire-registry/hash/golden fixture 一致。
- Client/Runtime executionCatalogHash fixture 一致。
- Client/Runtime developerImageCatalogRevision/hash fixture 一致；任一不匹配进入 incompatible Runtime 路径。
- plannerContractVersion 对语义变更敏感。
- StandardError code 唯一、allowed operation/lifecycle/commitState 完整。
- 排除入口 negative tests。
- DeveloperImageCatalog exact mapping、source/hash/file-role、no-nearest fallback 和 immutable revision fixtures。
- `verify-evidence-policy-structural`对EvidencePolicyArtifactSet member/schema/hash、147 concrete ID、21 suite、29 binding preset、17 environment、25 SubjectSet、2 ApplicabilityRule、5 FailurePolicy、3 EvidenceRolePolicy、4 fixture profile code、1 Formal multiplicity cohort/2 exact member、4096 suite cap、FixtureCase和RequirementOwnerMap exact coverage fail closed；`verify-evidence-policy-release-complete`在M3要求T-001～T-021、全部proposed public identity和三个release stage完整覆盖。
- EvidenceRun/ReleaseEvidence manifest canonical/hash、hard caps、pathKey、exact-scope required-set、typed NegativeRemovalPlan source/result policy、artifact allowlist、privacy/retention/raw-cleanup validation、selection exact projection、EvidenceStoreRecord/release/freeze/final-stage hold、releaseFlow/stage lineage、Beta->Formal exact scope identity、per-requirement multiplicity、三态聚合和unknown/notApplicable negative fixtures。
- performance contract registry/schema/hash、scaled integer unit、metrics gateValues、measurement/threshold/approval profile、至少三轮baseline、durable freeze hold、Beta/Formal同flow/candidate/policy/profile和recomputed evaluation negative fixtures。

### 40.2 Scheduler/Lifecycle

- conflicting FIFO、exclusive writer fairness、disjoint bypass。
- OneShot pending cap 64、PreparationWaitRegistry total cap 64。
- Stream conflict/loading fail-fast。
- opening/ordered buffer overflow cleanup。
- owner EOF、Ctrl-C、Client timeout、GUI close。
- terminal exactly once、late callback fencing。
- stop/idle/fatal 共用 inhibitor predicate。
- preparation internal claimant、phase-scoped lease、disjoint bypass、attempt late-callback fence。

### 40.3 IPC

- header golden bytes、big-endian、unknown flags/type/state/direction。
- HelloAck、HelloReject -> same-FD bootstrapOnly、malformed close。
- 18 operation exactly-one Response；recordLocalAction zero Response。
- 0x0108 negative fixture。
- saturation、slow peer、reserve exhaustion、partial write。
- SCM_RIGHTS 0/1/2 FD、MSG_CTRUNC、ordering、purpose binding、Screenshot/Element PNG validation。
- Helper message ordering、duplicate Result、generation token mismatch。
- PrepareObserver progress/terminal、catalog-reference file-role、TSS error/redaction fixtures。
- FactsProbe second line、timeout、self-kill、257 devices。

### 40.4 Host/security

- forged UID/TMPDIR/HOME 不影响 anchor。
- `/tmp -> /private/tmp` anchor verification。
- owner/type/mode/symlink/foreign base fail closed。
- UDS path length for maximum EUID。
- socket replace/delete vnode-watch fail-stop。
- PID reuse / process start identity / executable path recovery。
- `self install`使用effective UID login home且不受伪造`HOME`/cwd/PATH影响；source/staging/target validation、launcher各node type、installer PID exclusion、每次signal前身份复核、TERM/KILL deadline、publish与launcher双rollback均有fault-injection fixture。
- Agent Skill资源packaging覆盖missing/unsafe source、frontmatter/name/default-prompt、content marker和outer signature/content manifest；`skill install`覆盖central app fresh/update/current/repair、Codex/Claude/custom target、重复target去重、fresh/update/unchanged/conflict/force、staging/publish/rollback和无半成品恢复。`skill status`与`skill uninstall`覆盖default built-ins、显式custom root、modified/incomplete、unknown-file preservation和不删除中央app。安装后的skill只使用全局launcher。
- DeveloperImages owner/mode/no-follow、host/per-asset locks、6/8 GiB cap、LRU prune、partial resume/crash takeover。

### 40.5 Product integration

Default Product Delivery required：

- 从packaged `PulsePhone.app`在owner当前提供的USB iPhone上完成live frame、aspect/geometry、tap/drag、至少一个toolbar device action、close/relaunch和endpoint/process cleanup。
- 从 packaged CLI 完成 `element snapshot` 默认 JSON、annotated-only 和 both；验证同一 generation/
  capture digest、pixel/logical/normalized 坐标、可直接 tap 的 center、单/双 analyzer 降级，以及查询
  前后零滚动、零 Accessibility focus movement、零 HID、零 overlay 和全部 worker/FD/temp cleanup。
- 在同一实际设备上完成首次operator-confirmed source选择与第二次app launch自动复用；验证current sourceEpoch/connectionEpoch/geometry重新取得，cache失效与手动replace/clear不显示错误帧。
- 在同一current sourceID/sourceEpoch下完成portrait -> landscape -> portrait多次切换，真实sample持续enqueue；记录formatRevision、sample dimensions和geometryRevision。用户尚未resize时验证默认`375 pt` preferred canvas短边；Retina `2x`下约为`750 backing pixels`，但尺寸断言使用AppKit points。当前标准主显示环境且布局可行时，初始portrait canvas/content/frame短边约为`375 pt`。验证单帧异常不跳窗，初始portrait/landscape及稳定windowed状态没有白色或黑色侧边；从四边四角连续live resize时，每次手势冻结比例和driver，直接拖动边单调跟手且没有回弹、driver切换或尺寸振荡，窗口逐callback按带固定controls/chrome偏移的派生关系保持比例。live resize中触发方向变化时确认旧方向最后一帧保持饱满、capture与formatRevision继续推进、pointer fail closed，松手后一次采用已稳定的新presentation并恢复实时画面与current geometry tap/drag。AppKit实际minimum width通过overflow、自适应controls和双轴裁限解决；fullscreen允许black non-coordinate letterbox且不改系统frame，退出后按current presentation恢复无letterbox windowed窗口。
- 声明Keyboard Capture modifier/chord已验证时，按本章`Physical Keyboard Modifier/Chord Acceptance`在全部自动化完成后执行一次实体Mac键盘checkpoint；Computer Use可准备和观察环境，但不得生成passing chord。owner不可用时该row为`notTested`，不得反复运行synthetic shortcut或阻塞其他无关工作。
- 正式AppKit窗口和packaged Runtime使用真实production wiring；component model、fake backend、机械CLI smoke或只显示画面的窗口不能替代。
- 每台实际设备记录exact model/productType、OS version/build和通过的capability；未提供设备/环境为`notTested`。

以下只在Optional High-Assurance Validation或对应外部分发scope显式激活时 required：

- iPhone 11 Pro / iOS 14.2.1 legacy minimum rows。
- temporary iPhone 12 / iOS 16.3.1 classic DDI transition rows。
- iPhone 14 / iOS 26.5.x modern personalized/TSS main smoke。
- iOS 17.x boundary 设备在 External Beta broad claim 前补齐；缺失时缩小声明。
- multi-device source/target binding。
- Camera/Microphone/Input Monitoring independent denial/revoke/regrant。
- USB reconnect control/video independent recovery。
- app located in `/Applications`、user dir、path with spaces。
- no-Xcode empty cache、cache hit、offline reusable、offline TSS unavailable 和 selected-Xcode hit。

## 41. 冻结事实与历史证据边界

本节记录设计冻结时可依赖的机制事实和历史审计结论，不扩大产品承诺，也不维护当前问题或验证状态。当前已确认问题以`../OBSERVED_ISSUES.md`为准；当前暂缓验证以`../DEFERRED_VALIDATION.md`为准。

| ID | 当前事实 | 工程含义 |
| --- | --- | --- |
| F-001 | iPhone 14 / iOS 26.5.2 / USB 已验证普通 tap、连续 drag、HID keyboard、Home、Indigo true edge | 对应 mechanism 为 V1，不等于完整 Product Action V2 |
| F-002 | 强证据集中在一台 iOS 26.5.2 设备 | iOS 17+ 仍是 targetCompatibility；版本矩阵必须单独形成 |
| F-003 | AVFoundation capture source 与 CoreDevice UDID 是独立链路，尚无可靠映射 | video 必须 fail closed；T-001 是 Target safety product gate |
| F-004 | 历史原型依赖外部 `/tmp/pymd3-venv` | 仅作为历史证据保留；当前发布包使用 Go Helper，发布包无 Python runtime |
| F-005 | Go Helper 可保持 tunnel/CoreDevice service并通过stdio处理实时输入 | 长连接方向已形成候选实现；正式监督、close timeout和crash recovery仍以当前 Gate 证据为准 |
| F-006 | iPhone 14 / iOS 26.5.2 已验证Indigo Consumer Eject可在输入焦点保持时双向toggle软件键盘；visible state不可查询 | 只公开无状态`gui.softwareKeyboard.toggle`；不提供show/hide/query/checked，不与Keyboard Capture联动 |
| F-007 | classic usbmux/Lockdown 可跨版本；developer/DVT/DDI按能力和版本拆分 | iOS 14～16 facts/install/uninstall 与 screenshot/launch 分别声明，不得统一外推 |
| F-008 | macOS 不会因父进程退出自动 kill Helper | 必须使用 lifetime Pipe + inherited lock + verified orphan recovery |
| F-009 | capability preparation 无 1 秒证据 | 历史 10 秒 outer deadline 已废止；当前使用 TRD 03 分阶段 deadline 和两段 Client budget；autopair=false |
| F-010 | usbmux 支持 Attached/Detached，但原型未接入 | Runtime 必须实现 monitor；重连必须重建 Helper/tunnel/service |
| F-011 | 当前键盘是物理 HID + iPhone-side IME，不是 Mac committed text | Keyboard Capture 与 `text.type` 必须保持独立产品/技术路径 |
| F-012 | 2026-07-22 production审计曾确认正式live仅完成video prototype，production assembly仍有缺口；该历史缺口随后由M2-031、packaged physical acceptance和M2-900 closure处理 | 只保留为“component evidence不能替代production wiring”的历史反例；不得据此推断当前状态，当前问题查询`OBSERVED_ISSUES.md` |
| F-013 | 2026-07-24 packaged验证中，Computer Use合成modifier曾触发`tapDisabledByUserInput`；该路径与实体Mac键盘事件不等价 | synthetic chord只可证明Event Tap fail-closed/recovery，不能作为modifier/chord forwarding通过证据；完整声明需要本章定义的单次实体键盘checkpoint |

## 42. 发布验证矩阵

以下验证项是Optional High-Assurance Validation的冻结human-readable family摘要。只有owner显式激活该配置后，才从`EvidencePolicyArtifactSetV1`生成当前ReleaseGateProfile concrete required set；不得从本表文本、TODO或本地脚本临时推导。未激活时本表保留为附加验证backlog，不阻塞Default Product Delivery，但其中错目标、错帧、stale epoch和其他共享product safety failure仍按上文始终阻断。

| ID | Required evidence | Required stage / failure scope |
| --- | --- | --- |
| T-001 | 同名多设备、0/1/N选择、USB重连、source uniqueID、UDID/source/connection/source epoch确定绑定；未绑定只显示身份占位；证明不会显示A控制B且可在无video时盲控B | Internal Alpha smoke；External Beta完整矩阵；始终 product gate |
| T-002 | 两个Go Helper、bundle-relative lookup、codesign/notarization/staple、held release-candidate app tree、clean macOS14 arm64；`/Applications`、用户目录、含空格路径；`self install`的fresh/update/repair/already-current、launcher reconcile、verified process termination与rollback；final publish/store/dist tree逐byte一致；bundle无Python runtime/wheel/source/license-only leftovers | Alpha允许开发依赖；External Beta前 product gate；Formal publish再次闭合stored candidate bytes |
| T-003 | Go toolchain/依赖清单、LICENSE/NOTICE/source availability；approved DDI source/use/version/hash/权利；bundle无DDI、受控cache允许；TSS Apple allowlist | Core Runtime/Helper为product gate；来源或权利未闭合的精确capability必须移除 |
| T-004 | iOS14.2.1、16.3.1、17.x boundary、26.5.x；每个finite broad range按固定lower/intermediate/upper slot记录exact build；报告区分targetCompatibility/actuallyVerified/releasedCapability | Beta默认只声明实测exact build；broad范围必须有maximumExclusive、三slot证据和PublicReleaseScopeIdentity，Formal只重投影provenance不得扩大 |
| T-005 | iOS 14～16逐项 facts/status/screenshot/install/uninstall/launch；classic cache/Xcode/remote/mountedUnknownUnverified、missing/mismatch/invalid、offline和no-nearest-fallback；非PNG转换器闭合 | 每command capability gate；错目标/不安全依赖升级product |
| T-006 | tap坐标/geometry；GUI pointer首触p0～p4分层且warm路径无固定秒级初始化；drag/swipe duration、frame/payload cap和ordered begin/move/end；App Switcher、Lock/Volume/Mute mapping/hold；Rotate每次单个relative quarter-turn、upside-down支持边界和actual geometry；app commands、generation-scoped keyboard lifecycle、`type`独立SET/PULL回读与Unicode paste、focus error、64KiB text、bounded IPA streaming；Software Keyboard无状态Eject toggle及与实际执行中Capture/text interaction的资源冲突 | 对应command capability；shared input/helper failure按product；false visible-state、service接管或输入交错按contract drift阻断 |
| T-007 | admission前后断线、Runtime/Helper crash、attempt/generation/runtime epoch、idle owner、download owner、demand-driven reconnect、socket/watch/PID reuse/orphan、500ms classifier、fatal cleanup、Client timeout races；用P99定标orphan waits | shared singleton/generation/terminal/target invariants始终product |
| T-008 | Camera/Mic/Input Monitoring独立授权/拒绝/撤销/重授；GUI-only TCC attribution；placeholder blind control；EventTap device-first/focus cleanup；audio route/sleep/multi-live/Mac-or-Off output | Camera->video、Mic->audio、Input Monitoring->keyboard capability；crash/错目标/错误归因product |
| T-009 | machine-readable command-matrix.v17 52/21/44/14/2 + feature6 coverage；Product profile shorthand可唯一展开为每row execution/logging ID；P-C1/PreparationGroup展开、parent、release inheritance、GUI fixture、negative removal、Catalog/hash/planner consistency | Contract drift阻断对应阶段；shared/hidden reachable path为product |
| T-010 | ActionLog begin/terminal、cross-epoch root/child、single writer、tail recovery、identity/home anchor、rotate/prune/clear/partial；diagnostics path/cap/auto-finalize/shutdown；redaction | logging path failure不得影响command；unsafe deletion/privacy/shared writer failure按product或移除feature |
| T-011 | preview freshness/binding；Runtime reservation/inode/no-follow/PNG/64MiB/unlink；SCM_RIGHTS readonly FD；Client atomic write/force；legacy format；GUI root/child；text/keyboard separation和脱敏 | shared artifact/path/FD安全product；legacy screenshot可精确撤销 |
| T-012 | discovery/canonical/probe；runtime status preparation projection；device.prepare human/JSON/exit/progress；普通60s与prepare两段budget；五shape SIGINT；aggregate projections | shared CLI/target contract product；单command schema可精确撤销 |
| T-013 | single active trace、traceStarting token、stable path、complete/incomplete/no-footer、5MiB、Bootstrap stop、fixed redaction、no broadcast、no last receipt、temp lifecycle | 敏感泄漏阻断；只有完全移除ReplayTrace后可capability降级 |
| T-014 | live launcher dispositions/saturation、per-app registry/cross-copy owner conflict、observation/reset/slow subscriber、Stream absolute max、all stop blockers、token ownership、stop Ack+generation exit、dual reconnect、fatal episode one-shot recovery/no crash-loop | GUI/lifecycle shared invariant product |
| T-015 | full OperationLifecycle、actor no-await、token handoff、PreparationWaitRegistry cap64/re-plan、internal preparation claimant、queue fairness、Stream/OneShot cleanup和late token | Scheduler/lifecycle shared invariant product |
| T-016 | every bounded IPC/path boundary；registry+StandardError fixtures；19 operations；execution+DeveloperImageCatalog compatibility tuple；target-only prepare request及唯一progress/result/status DTO；protocolViolation/capacity/outcomeUnknown统一映射；revision-keyed catalog-reference Helper；ArtifactFD；spawn identity；HostPath/asset lock caps | shared RuntimeWire/HelperWire/path/FD product；isolated feature only if fully removable |
| T-017 | EvidencePolicyArtifactSet/concrete requirement/execution suite/owner map与typed input；binding/failure preset；monotone typed removal/atomic exposure；stored selection/attempt ledger；EvidenceStore flow-neutral import/tree record/opaque ref/hold set/final Gate report；releaseFlow/stage lineage；PublicReleaseScopeIdentity/bounded broad coverage；30m+5 / 2h+20 / 8h+50x3 | human matrix、TODO、local/latest path、stage summary或legal decision不能替代machine required set/store/removal plan；product gate不可移除；缺失/unknown不闭合 |
| T-018 | performance contract、metrics collector/export integer gateValues；measurement/threshold/approval profile hash；scaled integer、latency boundaries、CPU/RSS/growth、notApplicable/notRecovered、single-live process set、durable freeze hold、Beta/Formal同flow/candidate/policy/profile/public scope、append-only Formal series、privacy | metrics gap使performance evidence无效；阈值不得在首个Beta run后放宽；Formal继承Beta public identity但重投影provenance；failed/unknown关闭series；crash/错目标/leak/unbounded growth product |
| T-019 | DeveloperImageCatalog/source/hash/file-role；AssetContentManifest和canonical role path；catalog 4MiB/64 revision/64MiB caps；archive-bound PartialDownloadState/HTTP interruption/resume/fallback；content-addressed assetKey/path；asset-store/per-asset lock；cross-Runtime/app-copy single-flight；immutable catalog revision；rebuildable cache index；6/8 GiB cap和prune | integrity/ownership/unbounded cache failure为product；单source不可用可bounded fallback |
| T-020 | explicit/implicit/live preparation；Runtime-derived DemandSpec；epochBound/persistentAcrossReconnect；Observer/Attempt identity；bounded lock/claim/attempt deadline；progress/idle/detach/terminal；非DDI disjoint command继续 | shared preparation lifecycle为product；单group可在完全撤销消费者后移除 |
| T-021 | classic/personalized、approved/mountedUnknownUnverified provenance、TSS/query/mount/service；iOS14/16/17+/26 command physical evidence | 每route/command/OS精确声明；错target、未批准asset或错误personalization为product |

### 42.1 Internal Alpha exit criteria

```text
shared Catalog/Planner/registry implemented and fixture-clean
main validation device product smoke
target safety P0 smoke
Runtime/Helper singleton and lifecycle smoke
DeveloperImageCatalog/AssetStore/prepare explicit+implicit smoke
CLI human/JSON/exit/SIGINT smoke
permissions degradation smoke
30 minutes live + 5 reconnects
metrics can be collected and exported
```

### 42.2 External Beta exit criteria

```text
signed + notarized + stapled clean-machine bundle
all public command golden tests
multi-device/reconnect/orphan P0 matrix
D063 saturation and slow-peer tests
permission denial/revoke/regrant matrix
all distributed dependency legal material closed
no-Xcode empty-cache/cache-hit/offline/TSS matrix and T-019～T-021 applicable evidence
2 hours live + 20 reconnects
at least 3 repeatable performance baselines and freeze-held threshold profile
all Beta evaluations reference that profile ID/hash
each public OS scope is either an exact-build set or a bounded range backed by a coverageOutcome=passed three-slot set
```

### 42.3 Formal Release exit criteria

```text
complete Command Matrix and lifecycle/security regression
install/upgrade and representative app paths
8 hours live + 50 reconnects, 3 consecutive passing stability/performance cohort runs
reference passing External Beta manifest
meet the exact same frozen performance threshold profile ID/hash
bounded lower/intermediate/upper exact-build evidence for any broad OS claim
classic/personalized Developer Support matrix and cache/source policy gates
all selected evidence packages held for released-version retention
final PulsePhone.app published only from held selected T-002 candidate tree
store tree, candidate input and dist tree AppBundleContentManifest exact-match
strict code-signature and staple validation repeated after publication
all public docs, Catalog, help and release manifest consistent
```
