# PulsePhone TRD 07 - Artifact、可观察性与安全

> 文档状态：第一阶段规范章节
>
> 上级文档：[`pulsephone-trd.md`](../pulsephone-trd.md)
>
> 负责范围：第 29～34 节；PNG ArtifactFD、HostPathLayout、ActionLog/Trace/Diagnostics、StandardResult/Error、hard cap、安全与隐私。

本章持有文件、FD、日志、错误和资源上限的精确合同。RuntimeWire message direction 由 TRD 05 持有，Developer Support 生命周期由 TRD 03 持有，用户可见错误体验和隐私承诺由 PRD 持有。

## 29. PNG ArtifactFD

设备截图与显式 Element annotation 是唯二 PNG 大对象 Wire 例外，不内联 JSON/base64，
不建立 chunk stream。artifact metadata 必须携带 `purpose=deviceScreenshot|elementAnnotation`；
Client 必须验证 purpose 与当前 command/format 一致。

### 29.1 Runtime reservation

```text
Runtime
  -> generate artifactID/basename
  -> openat(O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW,0600)
  -> record dev/inode
  -> pass exact internal path to Helper

Helper
  -> open existing reservation O_WRONLY|O_TRUNC|O_NOFOLLOW
  -> write/fsync/close
  -> return artifactID + metadata only

Runtime
  -> reopen from original dirfd read-only
  -> validate owner/type/dev/inode/PNG/size<=64MiB
  -> unlinkat path
  -> send read-only FD
```

Helper 返回替代路径是 protocolViolation。Element annotation 由 Runtime 在完成 fusion/correction
后写入同类 owner-only reservation，不经过 Helper，也不接收用户 output path。

### 29.2 SCM_RIGHTS ordering

```text
sendmsg(header first byte + exactly one FD)
  -> write remaining header/payload
  -> receiver binds ancillary FD to this header only
```

sender header partial write时后续 bytes 不重复 control message。receiver 使用 recvmsg 读取 exactly 16-byte header，buffer 不跨入 payload；payload 阶段 ancillary、MSG_CTRUNC、0或>1 FD、flag/type mismatch均为protocolViolation。

`ArtifactFD + success Response` 必须在 actor 内原子预留两个 outbound frame 的 final/control capacity；先 enqueue ArtifactFD，再 enqueue success Response。Element success Response 除
`artifactID` 外还携带完整 `elementSnapshotResult.v1`，并与 metadata 的 generation/capture digest
一致；device screenshot 继续使用既有 screenshot result。

Client 在 success Response 前暂存匹配 FD；failure/EOF/mismatch 时立即 close。Client 再校验 read-only、owner、regular file、PNG、metadata和 hard cap。

所有 Runtime failure Response 必须对应 0 个 ArtifactFD。success 前缺失/重复 FD、requestID/artifactID mismatch或失败 Response 携带 FD均为protocolViolation。Helper 不继承 artifact/directory FD，也不得接受用户 output path；reservation node identity mismatch时不得删除 foreign node。

错误唯一映射：

```text
path/owner/type/symlink/inode  -> unsafeHostPath
valid reservation but bad PNG -> artifactValidationFailed
size > 64 MiB                 -> artifactTooLarge
unsupported backend format    -> unsupportedScreenshotFormat
```

`outputExists` 只在 Client 发 Runtime request 前的 no-clobber preflight产生；`localWriteFailed` 只在收到并验证有效 artifact 后的目标目录 temp write/atomic rename阶段产生。两者都不触发 Runtime自动重截图。

## 30. HostPathLayoutV1

### 30.1 Layout

```text
E    = decimal(geteuid())
home = getpwuid_r(E).pw_dir, owner validated
base = /tmp/pulsephone-<E>/
H    = lowercase hex SHA-256("pulsephone.udid.v1\0" + canonicalUDID)
G    = lowercase hex SHA-256("pulsephone.gui.app-path.v1\0" + canonicalAppPath UTF-8 bytes)
V    = lowercase hex SHA-256("pulsephone.video-mapping-target.v1\0" + canonicalUDID)

<base>/<H>.sock
<base>/<H>.bootstrap.lock
<base>/<H>.runtime.lock
<base>/<H>.helpers.v1.json
<base>/gui-<G>.sock

epochScratch:
  <base>/scratch/<H>/<runtimeEpoch>/screenshots/<artifactID>.png

userTempArtifact:
  <base>/artifacts/<H>/traces/<traceID>.jsonl
  <base>/artifacts/<H>/diagnostics/<sessionID>.jsonl

persistentHistory:
  <home>/Library/Application Support/PulsePhone/ActionLogs/

persistentBinding:
  <home>/Library/Application Support/PulsePhone/VideoSourceMappings/
    <V>.v2.json
    <V>.v1.json  # legacy operator-confirmed record, read compatibility only

developerImageStore:
  <home>/Library/Application Support/PulsePhone/DeveloperImages/
    catalogs/<catalogRevision>.json
    assets/<assetKey>/manifest.v1.json
    assets/<assetKey>/roles/<fileRole>
    downloads/<assetKey>.partial
    downloads/<assetKey>.partial.v1.json
    locks/asset-store.lock
    locks/<assetKey>.lock
    state/cache-index.v1.json
    state/<assetKey>.progress.v1.json
```

### 30.2 Permissions

```text
directories 0700
files/socket/lock 0600
```

只允许验证 macOS root-owned `/tmp -> /private/tmp` 系统 anchor；从 `pulsephone-<E>` 起全部 no-follow。

UDS bind/connect 必须使用冻结的短字面路径 `/tmp/pulsephone-<E>/...`，不得改写为 `/private/tmp/...` 或 `$TMPDIR`。按最大 32-bit EUID、64-hex H/G 计算：

```text
Runtime socket <H>.sock        96 bytes, plus NUL <= Darwin sun_path[104]
GUIHost socket gui-<G>.sock   100 bytes, plus NUL <= Darwin sun_path[104]
```

使用 `/private/tmp` 字面路径将没有足够 NUL 空间，因此禁止。bind 后必须立即从已验证 anchor 复核 node identity。

所有 child path 从已验证 dirfd 使用 `mkdirat/openat/fstatat/unlinkat` 或等价 API。不得信任 `$UID`、`TMPDIR`、`HOME`、cwd、Helper path 或用户字符串。

foreign node owner/type/mode/symlink 校验失败时 fail closed，不 chown/chmod/delete/repair，不 fallback 到第二个 base。

`VideoSourceMappings/`只允许从validated Application Support anchor逐级创建/打开，设置excluded-from-backup并保持当前Mac本地使用，不经iCloud或其他同步机制分发。每个target只按exact `V`打开当前V2或legacy V1 record，不scan latest、不从其他target fallback。`VideoSourceMappingRecordV2`使用canonical JSON；基础字段固定为：

```text
schemaVersion = 2
targetPathKey = V
sourceIdentityDomain = pulsephone.av-source.v1
proofKind = operatorConfirmedPreview.v1 | singleConnectedTargetSource.v1
sourceID = 64-char lowercase hex
```

V2还允许以下两项可缺省布局提示；必须同时存在或同时缺失：

```text
initialCanvasWidth  = UInt64, 1...65535
initialCanvasHeight = UInt64, 1...65535
initialCanvasWidth <= initialCanvasHeight
```

两项由形成proof的有效Preview/Probe帧按`min(frameWidth,frameHeight)`和`max(frameWidth,frameHeight)`写入。它们只提供正式Live首个current sample前的portrait-normalized canvas ratio，不证明source仍出帧，不提供当前方向、geometry或interaction authority。无法取得合法尺寸时允许写入不含两项的V2；读取缺失尺寸的trusted V2按默认比例继续，不迁移或静默改写record。只出现一项、零值、超界或`width > height`均为corrupt record并fail closed。

`VideoSourceMappingRecordV1`固定为只读兼容格式，字段为`schemaVersion=1 + proofKind=operatorConfirmedPreview.v1`及相同其余字段；任何写入或替换只允许使用V2。V2 missing时可以exact读取trusted V1；V2节点存在但unsafe、corrupt或schema/domain不兼容时不得回退V1。V1 cache Probe成功后本次按operator proof使用；后续显式确认或获准写入时只写V2。Clear Mapping删除重新验证为trusted的exact V2和V1节点。

record不得包含canonical/raw UDID、raw `AVCaptureDevice.uniqueID`、mappingProof UUID、sourceEpoch、inventoryRevision、connectionEpoch、geometryRevision、除上述initial canvas pair以外的format/size、当前orientation、device/source name、列表位置或时间线数据。单record canonical bytes硬限4096，target records硬限256；达到cap不prune、不猜测旧record，本次current proof仍可用于session，但不得宣称cache已保存。proof kind只说明形成target/source mapping的方式，不提供sourceEpoch或永久identity保证。

读取时要求owner=EUID、regular file、mode 0600、nlink=1、size cap、canonical schema/domain/path-key/sourceID/proofKind全部exact。missing、corrupt、version/domain mismatch或foreign state不得静默repair、迁移或选其他source，只返回cache unavailable并由GUI回退Chooser。用户最终确认或获准的auto proof可以原子替换owner/type/mode/link均trusted但内容stale/corrupt的exact V2 record；显式Clear Mapping也可以删除这种trusted exact节点。foreign/symlink/hardlink节点始终fail closed，产品不得替换或删除，必须由用户在产品外处理。

V2写入使用同目录0600 exclusive temp、完整write、fsync、rename和parent fsync；成功前旧V2保持有效，失败不留下可被读取的partial。Clear Mapping只unlink已重新验证owner/type/mode/link和derived exact filename的target V2/V1 record并fsync parent；内容损坏时不要求先成功decode schema/path-key，不枚举或删除其他target。

GUIHost对connected-target duplicate claim和人工reassignment使用进程级单一mapping mutation coordinator，不新增全局mapping index：

1. Resolver对当前bounded connected-target snapshot逐个执行exact record lookup；同一sourceID被多个trusted record声明时，相关cache/auto path全部conflicted并回退Chooser。
2. Chooser item分别显示所有当前connected claim的设备名/canonical UDID与本GUIHost active Live状态；持久claim不得被误标为active使用。选中冲突source时显示停止原设备画面和后续需重选的影响。最终确认前不停止active session、不修改record，点击“使用此源”是唯一确认，不再增加二次alert。
3. 最终确认在coordinator内重新读取同一connected-target集合和exact records；冲突集合与UI确认时不一致则中止、刷新Chooser并要求重新确认。
4. 已明确授权reassignment时，先停止并fence本GUIHost内其他target对该source的active capture，再clear其他connected target的trusted exact V2/V1 records，最后原子replace当前target V2。
5. 多record mutation无法跨文件原子提交。任一步失败或进程中断后，不回滚已经安全完成的clear；后续duplicate/missing/partial state必须fail closed进入Chooser，不能让两个target自动使用同一source。
6. 不扫描未连接target、不按mtime或“最新record”猜owner。未连接target的陈旧claim在它下次连接并执行exact load时检测；不同app copy之间的竞态也以duplicate claim/Probe失败回退Chooser。

若关联Chooser确认的source已经是当前target/current Live的exact active source，必须在进入mapping mutation coordinator前执行strict no-op：关闭Chooser并释放其Preview consumer，不读取或改写任何mapping record，也不停止、fence、Probe或替换active capture。该路径不得更新proof、initial canvas、Runtime attachment或`captureActivationID`。只有选择不同source时才进入上述reassignment序列；原target Live可以继续保留控制链，但其被fence的视频必须明确进入unavailable并要求后续重新选择，不自动交换或继承新target原有source。

`DeveloperImages/`设置excluded-from-backup。asset的下载、原子publish与prune使用per-asset exclusive`flock`；Runtime/Helper从完整校验到mount文件全部打开期间持shared`flock`。host-wide`asset-store.lock`把approved remote acquisition并发限制为1，并统一串行化catalog publish、capacity calculation、prune、asset publish和cache-index update/rebuild；lock order固定为`asset-store -> asset`。`cache-index.v1.json`、progress、partial metadata、PID和socket只用于可重建观察，不能替代catalog、integrity、capacity或lock ownership。

Runtime和本地Developer Image诊断入口在初始化store之前，从可信login home的anchored directory验证`Library`，缺失时创建`Application Support`，并逐级验证其owner/type；创建或验证`PulsePhone/DeveloperImages`为当前用户拥有的`0700`目录。首次使用不能要求用户预建目录；产品私有目录既有错误权限、symlink或foreign node必须fail closed，不自动chmod、不跟随、不递归清理。

### 30.3 Storage lifecycle

```text
epochScratch
  screenshot intermediate；FD 交付后立即 unlink。
  整个 runtimeEpoch generation retired/fenced 后才递归清理。

userTempArtifact
  trace/diagnostics stable path；不 rename。
  Runtime restart/epoch cleanup 不删除。

persistentHistory
  ActionLog rotation/prune/clear。
  temp/orphan/screenshot cleanup 永不进入。

persistentBinding
  trusted video source mapping；只由operator确认、获准的single-target auto proof、协调后的reassignment或用户显式Clear Mapping修改。
  Runtime epoch cleanup、window close、USB detach、app upgrade和ActionLog维护不得删除。
  version/domain/source失效时保留或显式替换exact trusted record，但运行时一律fail closed回退Chooser。

developerImageStore
  catalogs/assets/partial/metadata合计soft target=6 GiB，hard cap=8 GiB。
  catalog canonical bytes<=4 MiB/revision，最多64个revision且catalogs total<=64 MiB。
  publish 前按 archive/extracted upper bound 证明不越过 hard cap；否则先 LRU prune 或返回容量错误。
  prune 只删除可取得 nonblocking exclusive asset lock 的非 active、非 required entry。
  failed partial/extract 不得覆盖或删除既有 verified entry。
```

## 31. ActionLog、ReplayTrace 与 DiagnosticLog

### 31.1 ActionLog

append-only：

```text
action.begin
action.terminal
```

共同 identity：

```text
schemaVersion / recordSequence / runtimeEpoch
actionID / parentActionID?
canonicalUDID
sourceRole / sourceClientInstanceID
commandID / timestamp
```

event-specific fields：

```text
action.begin:
  redacted arguments
  executionShape
  initial route/planning metadata

action.terminal:
  outcome=succeeded|failed|cancelled|partial|outcomeUnknown
  commitState?
  duration
  attempt/result summary
  resultDelivery=delivered|clientGone
```

`recordSequence` 只在单个物理文件内单调，不提供跨文件/epoch 全序。读取时先跨文件、跨 epoch 按 actionID 聚合 begin/terminal，再按 parentActionID 形成 root/children。

append-once key：`(actionID,eventKind)`。消费者容忍 begin-only/terminal-only。

记录边界：

```text
Runtime product action
  -> best-effort action.begin before admission/device side effect
  -> best-effort action.terminal after immutable terminal

Client-local single-device action
  -> recordLocalAction only when a compatible Runtime connection already exists
  -> never cold-start Runtime, never create local outbox

health/probe/watchdog/internal maintenance
  -> DiagnosticLog/unified logging only
```

Client 已离线但 accepted OneShot 最终完成时，ActionLog 写真实 outcome，并可标记 `resultDelivery=clientGone`。Client timeout 不能伪造 Runtime terminal。

路径：

```text
ActionLogs/
  actionlog-maintenance.lock
  <H>/
    identity.v1.json
    writer.lock
    actions-<UTC>-<fileUUID>.jsonl
```

`identity.v1.json` 必须校验 canonicalUDID/hash。损坏或不匹配时 skip/fail closed，不猜测归属。

`identity.v1.json` 至少包含：

```text
schemaVersion
canonicalUDID
canonicalUDIDHash
createdAtUTC
```

首次创建使用 temp + fsync + atomic rename。maintenance lock、writer lock 和 identity 文件均为 stable coordination/identity node；prune/clear不得删除或替换。

persistentHistory home anchor 失败时，普通产品 action 只丢弃本次 best-effort ActionLog 并继续；只有 `logs prune/clear` 等以日志目录为主副作用的显式命令返回 `unsafeHostPath`。该失败不得成为第二个 Runtime startup blocker。

### 31.2 Retention

```text
rotate file             10 MiB
closed files / UDID      5
closed age               7 days
bytes / UDID             50 MiB
global bytes             250 MiB
```

只有 10 MiB rotate 自动发生。其余由 `logs prune` 显式执行。prune 只删除可取得 writer lock 的 closed `actions-*.jsonl`，不删除 identity/lock/dir。

`logs prune` 使用 30 秒 absolute deadline和稳定目录顺序。结果上限：

```text
skippedSample <=64
failedSample  <=64
each sample   <=1 KiB
whole result  <=256 KiB
```

sample 满后继续扫描和计数，只停止追加详情。存在 skipped/failed 或 scanComplete=false 返回 known partial/exit 6。

`logs clear --udid` 在 compatible Runtime 存在时由 Runtime 原子 rotate/close active writer、删除 eligible old files并 reopen；Runtime absent时Client只删可锁 closed files。`--all` 对固定 snapshot 聚合，不嵌套创建 per-device Product root。任何 active writer 不可稳定 close/reopen时，Runtime进入fail-stop，不能unlink后继续写不可见inode。

### 31.3 ReplayTrace

- Runtime 单 writer。
- active trace 从 traceStarting 起持有 shutdown inhibitor。
- 5 MiB hard cap，预留 footer 空间。
- complete / incomplete / no-footer 三种结束语义。
- 永久 schema-redacted，不记录 input frame、usage、text、path、artifact bytes。
- start/stop 返回同一稳定路径。
- trace active state第一阶段不通过RuntimeObservation广播；自动异常结束不发送异步result，也不保存last receipt。
- size cap/disk/write failure尽力写incomplete footer后关闭；footer也写不出时保留no-footer；无论如何release trace inhibitor。
- Runtime hard crash留下no-footer prefix；该文件可用于诊断但不得按完整replay input处理。

### 31.4 DiagnosticLog

- 默认只用 unified logging。
- 显式 session 写 5 MiB temp JSONL。
- active session metadata 只在 Runtime 内存。
- cap/disk/write failure 自动 finalize，之后 stop 返回 `noActiveDiagnostics`。
- session 本身不是 idle blocker；start/stop/finalize I/O 持短期 controlMutation。
- start立即返回stable absolute path；文件不rename；Runtime restart、epoch cleanup和screenshot cleanup不得删除。
- 自动结束后不保留last receipt/index；stop统一`noActiveDiagnostics`。
- quiescing shutdown finalize不新取external token，复用5秒deadline；超时关闭writer FD并把文件视为incomplete。

## 32. StandardResult 与 StandardError

### 32.1 StandardResultV1

```text
outcome = succeeded | failed | cancelled | partial | outcomeUnknown
commitState? = notCommitted | committed | unknown
durationMs? = UInt64 monotonic elapsed milliseconds
value?
error?: { code, details? }
```

`durationMs`从monotonic duration按整毫秒向下取整；禁止negative、floating-point、overflow和wall-clock subtraction。字段不适用或无法可靠测量时absent，不以0代替unknown。

规则：

- succeeded 无 error。
- failed/partial/outcomeUnknown 必须有 error。
- partial 只用 `partialFailure` + aggregatePartial details，且 value 必须 absent。
- failed/outcomeUnknown 不得同时携带 value；outcomeUnknown 只用同名 code。
- cancelled 可以没有 error，但 value 必须存在。具体Runtime operation或Command result schema必须定义有限reason enum和payload cap，禁止自由文本；`StandardResultV1`基础shape只验证value presence，不解释或自行发明reason。
- commitState 只在 oneShot、stream 或 mutation 语义适用时出现。
- Runtime/Helper terminal 不携带 `runtimeMayContinue`；仅 Client 未观察到 terminal 时本地投影。

### 32.2 Error family

```text
internal              -> 1
argument              -> 2
targetCompatibility   -> 3
runtimeProtocol       -> 4
admissionBusy         -> 5
knownCommandFailure   -> 6
unknownOutcome        -> 7
interrupted           -> 130
```

### 32.3 code registry

本节 registry revision 为 `standard-errors.v3-20260822`；schema major 仍为 `StandardErrorV1`，但错误集合和 allowed-operation mapping 与旧 revision 不兼容。

`standardErrorRegistry.sha256`的完整member set固定为：

```text
Registries/standard-errors.v1.json
Schemas/details-schemas/**/*.json
```

`Schemas/details-schemas/`包含registry引用的全部details schema，目录下全部`.json` regular file必须进入set；missing、extra contract JSON或unresolved `detailsSchemaID`均失败。按TRD 05 §21.1.1构造`RepositoryContractArtifactSetV1`，`setID=standardErrorRegistry`，`revision=standard-errors.v3-20260822`：

```text
standardErrorRegistrySHA256 = lowercase SHA-256(
  "pulsephone.standard-error-registry-set.v1\0"
  + repositoryCanonicalJSON.v1 RepositoryContractArtifactSetV1 bytes
)
```

`standardErrorRegistry.sha256`只指上述aggregate hash；禁止使用`standard-errors.v1.json`单文件hash或文件bytes直接拼接。任一member path/bytes变化必须重新生成aggregate并bump registry revision。

```text
internal:
  internalFailure preparationFailed cleanupTimeout

argument:
  invalidArgument argumentTooLarge planTooLarge invalidCoordinate
  invalidDuration invalidBundleID invalidIPAPath invalidOutputPath invalidUDID

targetCompatibility:
  noDeviceConnected deviceNotFound duplicateCanonicalUDID
  unsupportedDeviceClass unsupportedOSVersion unsupportedTransport

runtimeProtocol:
  runtimeNotRunning runtimeFailed runtimeStartupTimeout incompatibleRuntime
  unsupportedBootstrapOperation protocolViolation transportFailure
  guiHostUnavailable guiIPCFailure unsafeHostPath

admissionBusy:
  queueFull resourceBusy admissionCapacityExceeded aggregateTargetLimitExceeded
  capabilityPreparing runtimeStopping controlBusy incompatibleRuntimeBusy
  orphanHelperGenerationBusy liveAlreadyOpen liveOwnerConflict guiHostBusy
  traceAlreadyActive diagnosticsAlreadyActive keyboardInteractionBackpressure

knownCommandFailure:
  capabilityUnavailable deviceNotTrusted deviceLocked
  deviceDisconnected deviceEnumerationLimitExceeded executionTimeout backendFailed
  artifactValidationFailed artifactTooLarge unsupportedScreenshotFormat partialFailure
  probeUnavailable windowCreateFailed localOpenSettingsFailed traceWriteFailed
  noActiveTrace diagnosticWriteFailed noActiveDiagnostics invalidIPA installFailed
  uninstallFailed appNotInstalled appLaunchFailed
  developerSupportUnavailable developerImageCatalogMismatch unsupportedPreparationGroup
  developerImageDownloadFailed developerImageIntegrityFailed developerImageCacheCapacityExceeded
  developerModeRequired personalizationServiceUnavailable developerImageMountFailed
  developerServicesUnavailable preparationTimeout
  outputExists localWriteFailed timedOut

unknownOutcome:
  outcomeUnknown guiLaunchOutcomeUnknown

interrupted:
  interrupted cancellationUnknown
```

Wire 只传 code + typed details。family、exit、retryable、allowed lifecycle/commitState 和 message 从同一 registry 本地派生。unknown code 或非法 details 是 protocolViolation。

每个 error registry entry 必须包含：

```text
code
family
defaultCLIExit
retryable
detailsSchemaID
allowedOutcomes
allowedLifecyclePhases / allowedCommitStates
clientContinuationProjectionPolicy
visibility=public|internal
```

family default：argument/interrupted/unknownOutcome retryable=false，admissionBusy=true；其他 family 每 code 显式声明。至少以下为 retryable：

```text
noDeviceConnected
runtimeStartupTimeout
transportFailure
runtimeNotRunning
runtimeFailed
developerImageDownloadFailed
personalizationServiceUnavailable
preparationTimeout
deviceDisconnected
probeUnavailable
```

至少以下为 non-retryable：

```text
unsupportedDeviceClass
unsupportedOSVersion
incompatibleRuntime
unsupportedBootstrapOperation
protocolViolation
unsafeHostPath
artifactValidationFailed
developerImageCatalogMismatch
developerImageIntegrityFailed
unsupportedScreenshotFormat
invalidIPA
outputExists
```

details schema：

| schemaID | Cap | Key fields |
| --- | ---: | --- |
| `none.v1` | 0 | details 必须 absent |
| `argument.v1` | 4 KiB | argumentName, reason, limit?；message 可提供确定的修正建议 |
| `target.v1` | 4 KiB | reason, canonicalUDID?, deviceClass?, osVersion? |
| `limit.v1` | 256 KiB | limit, truncated, capacityClass?, observedAtLeast?, omittedCount?, prefix? |
| `stopBlockers.v1` | 64 KiB | stable-sorted StopBlockerV1[] |
| `capability.v1` | 8 KiB | capabilityID, state, reason, preparationGroup? |
| `developerSupport.v1` | 8 KiB | preparationGroupID, phase, sourceKind?, catalogEntryDiagnosticID?, retryStage?；禁止 URL/path/hash/ECID/nonce/ticket |
| `unknownOutcome.v1` | 4 KiB | reason=`clientWaitDeadlineExceeded\|preparationObserverDeadlineExceeded\|terminalDeliveryUncertain\|commitStateUnknown` |
| `runtimeCompatibility.v1` | 16 KiB | compatibility IDs/hashes and bounded blockers summary |
| `artifact.v1` | 8 KiB | stage, artifactID?, content type/size；禁止 path |
| `aggregatePartial.v1` | Runtime 256 KiB / Client 1 MiB | summary, items[], truncated, omittedCount |
| `probe.v1` | 8 KiB | timeout/terminationTimeout/malformedResponse/unavailable |
| `backendStage.v1` | 8 KiB | stage, normalizedBackendCode?, commitState?；禁止 raw exception |
| `guiHost.v1` | 8 KiB | connect/write/reserve/createWindow/ack stage |
| `hostPath.v1` | 4 KiB | pathClass + owner/type/mode/symlink/inode/outsideBase/anchor reason；禁止绝对路径 |

`hostPath.v1` enum：

```text
pathClass=tempAnchor|tempBase|socket|lock|helperManifest|
          screenshotReservation|trace|diagnostics|actionLog|developerImageStore

reason=ownerMismatch|typeMismatch|modeMismatch|symlink|inodeMismatch|
       outsideBase|anchorInvalid
```

`admissionCapacityExceeded`使用`limit.v1`，其中`capacityClass`必须来自registry固定enum；PreparationWaitRegistry满时固定为`preparationWaitRegistry`。`outcomeUnknown`使用`unknownOutcome.v1`；Client observer deadline使用`preparationObserverDeadlineExceeded`，不得创建平行的known-failure error code。

`retryable` 只用于提示，不允许触发自动重试。`outcomeUnknown` 永远不得通过 retryable 暗示安全重试。

每个 runtime operation registry entry 必须显式列 `allowedErrorCodes`。command.submit/stream.open 使用 CommandDescriptor command-specific set + shared argument/target/admission/runtime delivery codes；health/status/availability/cancel 不允许 backend command code；trace/diagnostics/clear 只允许各自 code + controlBusy/runtimeStopping/unsafeHostPath/outcomeUnknown；recordLocalAction 因 one-way 不发送 error。

## 33. Backpressure 与 hard cap

以下是工程 hard cap，不是产品性能 SLA。所有 deadline 使用 monotonic absolute time。

### 33.1 RuntimeWire

```text
payload max                         1 MiB
connections / Runtime             16
awaitingHello+bootstrapOnly         4
outstanding / connection           16
outstanding / Runtime             128
recent tombstone                   64 / conn, 5 min
recordLocalAction payload           16 KiB
recordLocalAction rate/burst        50/s / 64, overflow drop
regular reliable queue            128 frames / 2 MiB
final/control frame max            256 KiB
final/control reserve               4 frames / 1 MiB
progress message                    16 KiB
progress rate                       10/s/request, 50/s/connection
preparation progress                 8 KiB
preparation owner byte rate          4/s/asset
preparation observer byte rate       1/s/asset
observation message                  8 KiB
observation queue                   64 frames / 256 KiB
bootstrapOnly outstanding            1
bootstrapOnly lifetime              15 s
Hello / frame assembly / write       2 s
```

### 33.2 Stream

```text
StreamFrame max                     8 KiB
ordered in-flight                  64 / 256 KiB
pointer latest move                 1
pointer opening                     begin + latestMove? + end?
keyboard opening                   32 snapshots
FrameAccepted watchdog              1 s
backend open                        2 s
cleanup/fence                       2 s
pointer absolute max               30 s
keyboard absolute max               5 min
```

ordered overflow/watchdog 必须 cancel 整个 session，不能丢中间 keyboard/boundary frame 后继续。

### 33.3 HelperWire

```text
JSONL line/framing max              1 MiB
outbound message max              512 KiB
Runtime normalized result max     256 KiB
default outstanding OneShot         1
regular outbound                   64 / 512 KiB
result/control reserve             64 / 512 KiB
HelperHello                         2 s
frame assembly/write                2 s
progress message                   16 KiB
progress rate                       10/s/request, 50/s/helper
```

### 33.4 GUIHost / aggregate

```text
GUIHost payload                    16 KiB
launcher connections                8
outstanding openLive / connection   1
pending openLive total              8
ack reserve                          1 frame / 16 KiB
Hello                                2 s
per-frame write                      1 s
OpenLive end-to-end                 5 s

global targets                    256
fan-out                              8
item                                 2 KiB
final aggregate                      1 MiB
```

### 33.5 Other bounded contracts

```text
OneShot cleanup Ack grace            2 s after running deadline/internal abort
ControlMutation stabilization        2 s after work deadline/cancel

PNG artifact                        exactly 1 read-only FD / PNG <=64 MiB
Element snapshot result             <=256 KiB / <=256 final elements
Element analyzer raw candidates     <=2048 / engine
Element label                       <=1024 UTF-8 bytes

FactsProbe request                   16 KiB / exactly one JSONL line
FactsProbe response                  256 KiB / <=256 devices
logs prune final                     256 KiB
logs prune skipped/failed samples    each <=64 items, <=1 KiB/item

Generated gesture duration           1...30000 ms
Generated gesture frames             <=4096 including boundaries
Generated HelperRequest              <=512 KiB before admission

type --text                          valid UTF-8 <=64 KiB, one OneShot payload
text key repeat                     1...100 complete press/release macros
text cursor count                   1...100 complete navigation macros

PreparationWaitRegistry             64 total waiter/demand/observer
Preparation status groups            8
Preparation status acquisitions       4
DeveloperImage cache soft/hard        6 GiB / 8 GiB
DeveloperImage catalog file           4 MiB
DeveloperImage catalog revisions      64 files / 64 MiB total
DeveloperImage partial sidecar         16 KiB
approved remote acquisitions          1 host-wide
```

reserve 满时不能无限等待或扩容。可靠 terminal 无法入队时断开 Client并记录 `clientGone`，不阻塞 Scheduler。

所有 queue 同时检查 frame count 与 encoded bytes。trickle read/write、局部 progress 或零散 callback 不得刷新 absolute deadline。RuntimeWire final/control 单 frame 始终 <=256 KiB；reserve 的 1 MiB 是队列总量，不允许单个 Response 借此变大。

## 34. 安全与隐私

### 34.1 信任边界

第一阶段信任同一登录 UID，不防御同 UID 恶意进程。Runtime 使用 `getpeereid` 校验 Client peer UID。

接受跨用户可预测 temp base 被预占导致 availability denial，但绝不能连接 foreign socket、删除 foreign node、读取其文件或控制错误设备。

### 34.2 FD

- 只在注册允许的 message type 接受 SCM_RIGHTS。
- 校验 FD 数量、owner、type、open flags、size、content。
- Runtime/Helper spawn 使用严格 FD allowlist。
- Helper 不继承用户 artifact FD。

### 34.3 Target safety

- CommandIntent canonicalUDID 必须与 HelloAck target byte-for-byte 相等，否则 protocolViolation + close。
- rawTransportUDID 只来自当前 discovery map。
- video source 必须绑定 target/epoch。
- cached video proof只允许从exact target-local trusted V2或兼容V1 record恢复sourceID提示；必须在current capture-eligible inventory单命中、没有connected-target duplicate claim并取得current sourceEpoch有效首帧。source handoff不依赖Runtime geometry，正式Live仍必须重新取得connectionEpoch与geometry；任一歧义fail closed回退Chooser。
- Bootstrap lite canonicalUDID 必须重算 socket hash。
- Helper recovery 必须验证 process start identity 和 executable path。

### 34.4 Redaction

禁止写入日志/trace/metrics：

```text
type --text 原文/hash
Text HID raw usage / unbounded macro payload
keyboard HID usage / pressed set / frame
Runtime screenshot/Element image bytes/path
IPA/user temp absolute path
backend raw exception
OCR text / visual caption / target App content in logs
OmniParser credential/query/full endpoint URL
canonical UDID in metrics export
Developer Support source URL / absolute cache path
ECID / nonce / ApImg4Ticket / raw TSS request or response
full content hash / service payload / device name in cache metadata
raw AVCaptureDevice.uniqueID / canonical UDID in video mapping metadata
```
