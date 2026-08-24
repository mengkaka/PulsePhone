# PulsePhone TRD 05 - IPC、Helper 与 Probe

> 文档状态：第一阶段规范章节
>
> 上级文档：[`pulsephone-trd.md`](../pulsephone-trd.md)
>
> 负责范围：第 21～24 节；RuntimeWire、GUIHostWire、BootstrapControl、HelperWire、Helper generation 和 LocalDeviceFactsProbe。

本章持有所有跨进程互操作合同。Runtime 监督与 orphan recovery 由 TRD 04 持有；Developer Support 语义由 TRD 03 持有；Product Action 对 operation 的调用由 TRD 06 持有；ArtifactFD 的文件与路径安全由 TRD 07 持有。

## 21. RuntimeWire 与 GUIHostWire

### 21.1 Registry artifacts

必须从同一规范输入生成：

```text
runtime-wire-messages.v1.json
runtime-operations.v1.json
guihost-wire.v1.json
helper-wire.v1.json
facts-probe-wire.v1.json
standard-errors.v1.json
```

CI 保存`repositoryCanonicalJSON.v1` exact bytes、SHA-256和golden fixture。实现存在未注册operation/type/code时不得声明v1 interoperable。

本组 registry 的规范 revision 是 `wire-registry.v9-20260822`；wire protocol major 仍为 1。revision 改变不允许绕过 Hello compatibility 与 golden fixture。

五份 transport registry 均固定：

```text
registryVersion=2
protocolMajor=1
entries[]:
  id
  numericMessageType?
  direction
  allowedConnectionStates
  requestSchemaID? / responseSchemaID?
  association=requestID|sessionID|subscriptionID|none
  terminalPolicy=exactlyOneResponse|oneWay|none|perFrameAck
  fdPolicy=none|exactlyOneReadOnlyPNG
  payloadLimitClass
  allowedEventKinds[]
  allowedErrorCodes[]
```

registry/schema使用本节`repositoryCanonicalJSON.v1`；无语义顺序集合由owner按ASCII byte order排序，有语义顺序数组保留声明顺序。Swift/Go 的 enum、decoder、validator必须由同一registry生成或验证同一golden fixture；保留的 Python tooling 只能消费同一份 registry，禁止手写可独立变化的allowlist。

`wireRegistry.sha256`的完整member set固定为：

```text
Registries/runtime-wire-messages.v1.json
Registries/runtime-operations.v1.json
Registries/guihost-wire.v1.json
Registries/helper-wire.v1.json
Registries/facts-probe-wire.v1.json
Schemas/wire/**/*.json
```

`Schemas/wire/`包含全部Wire envelope、handshake、operation、event、progress、observation、Helper和FactsProbe DTO schema；目录下全部`.json` regular file必须进入set。按§21.1.1构造`RepositoryContractArtifactSetV1`，`setID=wireRegistry`，`revision=wire-registry.v9-20260822`：

```text
wireRegistrySHA256 = lowercase SHA-256(
  "pulsephone.wire-registry-set.v1\0"
  + repositoryCanonicalJSON.v1 RepositoryContractArtifactSetV1 bytes
)
```

`wireRegistry.sha256`只指上述aggregate hash，不包含`standard-errors.v1.json`或details schema；它们由TRD 07 §32.3的独立identity持有。任一member path/bytes变化必须重新生成aggregate并bump wire registry revision；禁止使用单文件hash或文件bytes直接拼接。

#### 21.1.1 repositoryCanonicalJSON.v1

`repositoryCanonicalJSON.v1`只用于需要稳定字节、golden hash或跨语言生成的repository contract document，包括适用registry、schema、fixture manifest和evidence manifest。RuntimeWire、GUIHostWire、HelperWire和FactsProbeWire普通payload只遵守各自framing/schema规定的RFC 8259编码，不要求发送方使用canonical形态。

canonical document必须是顶层object，并按以下规则生成exact bytes：

- 编码固定为UTF-8；禁止BOM、无意义空白、缩进和尾随换行。
- object member name必须唯一；duplicate key在构造dictionary/map前按decoded scalar拒绝，例如`"a"`与`"\u0061"`是同一key。
- object key按解码后Unicode scalar序列的UTF-8 bytes升序排列；不做case-fold或Unicode normalization。
- array保持owner schema定义的语义顺序。无语义顺序的ID/set projection必须由owner先按ASCII byte order排序；canonical encoder不得猜测或重排array。
- `null`、`true`、`false`使用对应小写字面量。
- string必须是有效Unicode scalar序列；禁止lone surrogate，不做Unicode normalization。
- quote和backslash分别编码为`\"`、`\\`；U+0008/U+0009/U+000A/U+000C/U+000D分别使用`\b`、`\t`、`\n`、`\f`、`\r`；其余U+0000～U+001F使用小写hex的`\u00xx`。
- solidus `/`不转义；其他Unicode scalar直接编码为UTF-8，不使用可选`\uXXXX`或surrogate-pair escape。
- canonical numeric domain默认只允许owning schema明确声明的`Int64`或`UInt64`整数。只有字段schema显式声明`x-pulsephone-canonicalDecimal: true`时，才允许AST中的canonical fixed decimal；任何路径仍禁止binary floating point、exponent、NaN和Infinity。
- integer使用无引号base-10 JSON number：zero只能为`0`；禁止`+`、前导零和`-0`；signed范围为`-9223372036854775808...9223372036854775807`，unsigned范围为`0...18446744073709551615`。
- canonical fixed decimal使用无引号base-10 JSON number：`-?(0|[1-9][0-9]*)\.[0-9]*[1-9]`，fraction为`1...9`位、总数字不超过38位；禁止`+`、前导零、尾随零、整数形态、负零和exponent。parser/AST保留并验证exact token，不经过`Double`；producer只能从已量化的bounded值构造canonical token。
- `monotonicNs`、sequence、byte count和其他`UInt64`字段保持JSON number，不改为string；实现必须从decimal token直接checked-parse `UInt64`，禁止先经过IEEE 754 `Double`。
- 非整数值必须由owning schema逐字段显式启用canonical fixed decimal，或定义scaled integer/canonical decimal string并升级适用schema/revision；未标记字段看到decimal token必须由schema validation fail closed。

stored canonical document验证顺序固定为：

```text
hard cap / UTF-8 / BOM
  -> strict parse preserving member pairs and raw number tokens
  -> reject duplicate key / invalid integer / overflow / unsupported number
  -> owning registry/schema typed validation and unknown-field rejection
  -> re-encode repositoryCanonicalJSON.v1
  -> require exact byte equality with stored document
  -> compute hash over the validated exact bytes
```

canonical encoder只负责字节表达，不隐式增加domain separator。普通文件完整性hash是exact canonical bytes的lowercase SHA-256；`executionCatalogHash`、`developerImageCatalogHash`、release profile hash等语义身份继续使用各owner章节冻结的domain separator加canonical bytes。

所有owner章节中的`"<domain>.vN\0" + bytes`统一表示：ASCII domain ID不含NUL，随后追加单个`0x00` byte，再追加exact payload bytes；`\0`不是字符backslash与`0`。digest固定输出lowercase 64-hex。

实现约束：

- Swift canonical path不得使用会把未知number泛化为`NSNumber`/`Double`的中间模型；number AST必须区分canonical fixed decimal、negative `Int64`与nonnegative `UInt64`，并分别检查digit/scale与integer overflow。
- Python使用arbitrary-precision `int`；必须拒绝`parse_float`、`parse_constant`并通过member-pair hook拒绝duplicate key。
- Go使用保留number token的decoder或等价lexer，并以`strconv.ParseInt/ParseUint`验证；不得解码到默认`float64`，且必须补充token级duplicate-key检查。
- 通用`JSONEncoder`、`json.dumps`或`encoding/json`只有在输出逐字节通过共享golden fixture时才可作为底层实现；library default不构成兼容保证。

跨语言golden必须覆盖：

```text
nested and Unicode UTF-8 key ordering
quote / backslash / non-escaped solidus
U+0000 / U+0001 and \b / \t / \n / \f / \r exact escapes
literal < / > / & and direct UTF-8 U+2028 / U+2029
NFC / NFD remain distinct
direct UTF-8 non-BMP scalar output
array order preservation
domain separator uses one 0x00 byte
0
1
-1
9007199254740991       # 2^53 - 1
9007199254740992       # 2^53
9007199254740993       # 2^53 + 1
9223372036854775807    # Int64.max
9223372036854775808    # UInt64 valid; Int64 overflow
-9223372036854775808   # Int64.min
18446744073709551615   # UInt64.max
```

至少拒绝：

```text
18446744073709551616
-9223372036854775809
-0 / 01 / 1.0 / 1e0
duplicate object key
escaped duplicate key ("a" vs "\u0061")
BOM / trailing newline / optional whitespace
invalid UTF-8 / lone surrogate
optional `\/`、可直接输出scalar的`\uXXXX`和surrogate-pair escape
negative integer in a UInt64 field
9223372036854775808 in an Int64 field
```

revision/version/hash保持三个不同概念：`schemaVersion`或`protocolMajor`表示解码兼容形态；各registry/catalog owner持有自己的opaque revision；SHA-256表示exact bytes。M0不建立通用`revision-metadata.json`或active revision pointer。跨文档聚合身份只使用TRD 08定义的`ImplementationContractIdentityV1`。

多个repository contract file需要形成一个身份时，统一构造：

```text
RepositoryContractArtifactSetV1:
  schemaVersion = 1
  setID
  revision
  entries[]:                    # normalized relativePath ASCII byte order
    relativePath
    sha256                      # lowercase SHA-256 of exact validated file bytes
```

每个owner必须冻结完整allowed path/file set和aggregate domain ID。`relativePath`使用repository-relative `/`分隔ASCII路径，禁止absolute、`.`、`..`、empty segment和反斜杠。entry只能指向regular file；symlink、hardlink、missing、extra、duplicate path或其他node type均失败。每个JSON file先通过owning schema和`repositoryCanonicalJSON.v1` exact-byte验证，再计算entry `sha256`；entries排序后对整个ArtifactSet canonical bytes计算owner-specific domain hash。

ArtifactSet是从current source tree确定性生成的verification projection，不写入mutable active pointer，也不允许caller增删path。CI必须验证allowed directory中不存在未被set覆盖的contract JSON。revision相同但path set或bytes不同、或hash相同但revision不同，均视为identity mismatch。

每个contract file只属于一个ArtifactSet，禁止为解决引用而在多个set重复收录。file内的schemaID/errorCode/registryID等reference已经由exact file bytes绑定；set-local reference必须在同set解析，cross-set reference只能按TRD 08 `ImplementationContractIdentityV1`冻结的dependency graph解析。单独计算ArtifactSet hash时可以产出unresolved-external列表，但不得把它误判为已闭合identity。

### 21.2 Framing

RuntimeWire 与 GUIHostWire 使用 `AF_UNIX + SOCK_STREAM`。每条连接每个方向只有一个
serialized writer；Runtime为每个peer持有统一outbound broker，request handler、USB
monitor、executor callback和observation publisher不得并发直接写descriptor。Client
同样通过统一writer发送Request/StreamFrame，不得让多个调用者自行分帧写入。

进入normal状态后，每个Client连接只有一个长期reader。reader负责完整frame读取、
decode和按message type/association分发：Response交给requestID waiter，RuntimeEvent
交给可靠控制消费者，Progress交给best-effort消费者，RuntimeObservation和
ObservationStreamReset交给subscriptionID消费者，ArtifactFD交给requestID owner。
任何同步request helper都不得在writer提交后再次直接调用`readFrame`或跳过未知的合法
服务端消息；否则会窃取其他request的Response或丢失unsolicited event。

Client close/reset先停止新写入并terminal全部pending waiter，再shutdown/close descriptor
以中断reader，最后有界join reader和callback投递。EOF、ProtocolError、decode错误或
association冲突对当前连接fail closed；不自动重发未取得terminal Response的请求。

固定 16-byte header：

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | magic：`PPRW` 或 `PPGW` |
| 4 | 2 | wireProtocolMajor, big-endian UInt16 |
| 6 | 2 | messageType, big-endian UInt16 |
| 8 | 2 | flags；v1 bit0=`hasSCMRights` |
| 10 | 2 | reserved=0 |
| 12 | 4 | UTF-8 JSON payload length, big-endian UInt32 |

payload：RFC 8259 UTF-8 JSON、顶层 object、`schemaVersion=1`、无 BOM、无压缩。

### 21.3 RuntimeWire message type

```text
0x0001 Hello
0x0002 HelloAck
0x0003 HelloReject
0x0004 ProtocolError
0x0010 BootstrapRequestV1
0x0011 BootstrapResponseV1
0x0100 Request
0x0101 Response
0x0102 RuntimeEvent
0x0103 Progress
0x0104 RuntimeObservation
0x0105 ObservationStreamReset
0x0106 StreamFrame
0x0107 ArtifactFD
0x0108 AggregateResponse  # reserved, MUST NOT SEND
```

RuntimeWire message registry：

| Message | Direction | State | Association / terminal rule |
| --- | --- | --- | --- |
| `Hello` | Client -> Runtime | awaitingHello | no requestID；exactly once per connection |
| `HelloAck` | Runtime -> Client | awaitingHello | success enters normal |
| `HelloReject` | Runtime -> Client | awaitingHello | parseable compatibility reject enters bootstrapOnly |
| `ProtocolError` | either | normal/bootstrapOnly | best-effort once then close；pre-Hello malformed may close directly |
| `BootstrapRequestV1` | Client -> Runtime | bootstrapOnly | requestID；one allowed operation |
| `BootstrapResponseV1` | Runtime -> Client | bootstrapOnly | same requestID/operation；exactly one then close |
| `Request` | Client -> Runtime | normal | requestID/operation；runtime-operations registry |
| `Response` | Runtime -> Client | normal | exactly one for response-bearing Request |
| `RuntimeEvent` | Runtime -> Client | normal | requestID or sessionID or connection/revision by eventKind |
| `Progress` | Runtime -> Client | normal | requestID + preparationAttemptID?；best-effort before terminal |
| `RuntimeObservation` | Runtime -> Client | normal | subscriptionID + observationSequence；best-effort |
| `ObservationStreamReset` | Runtime -> Client | normal | subscriptionID + nextSequence；projection reset only |
| `StreamFrame` | Client -> Runtime | normal | sessionID + seq；one-way, no Response |
| `ArtifactFD` | Runtime -> Client | normal | requestID + artifactID + exactly one FD；not terminal |
| `AggregateResponse` | none | none | reserved；send or receive is protocolViolation |

Runtime event association：

```text
operationAccepted        -> requestID + actionID
operationQueued          -> requestID + queuePosition? + revision
operationStarted         -> requestID + attemptID
preparationStarted       -> requestID + preparationAttemptID + preparationGroupID
streamClosed             -> sessionID + interactionID + outcomeSummary
availabilityInvalidated  -> connectionID + affectedRevisionKinds[] + stateRevision
deviceDisconnected       -> connectionID + connectionEpoch + stateRevision
runtimeFatal             -> connectionID + runtimeEpoch + StandardErrorV1
```

USB reconnect固定复用现有事件：

```text
confirmed detach(E)
  -> deviceDisconnected(connectionID, E, stateRevision)
  -> availabilityInvalidated(connectionID, affectedRevisionKinds, stateRevision)
  -> ObservationStreamReset(subscriptionID, nextSequence, reason=projectionInvalidated)

confirmed attach(E+1)
  -> availabilityInvalidated(connectionID, affectedRevisionKinds, stateRevision)
  -> Client runtime.getAvailabilitySnapshot
  -> snapshot.connectionEpoch == E+1
```

`deviceDisconnected`引用刚刚失效的旧epoch；attach不新增`deviceConnected`或
reconnect event kind。RuntimeEvent在仍有效连接内不可静默丢弃。若bounded control
outbound无法继续保证Response/Event frame完整性，Runtime关闭该peer并执行owner-bound
cleanup，Client重连后从完整snapshot恢复；不能让控制事件与observation共用可丢弃策略。
Progress可以限频或丢弃。RuntimeObservation保持best-effort bounded，饱和时reset或
断开subscriber，绝不阻塞executor或占用可靠控制队列。

### 21.4 Handshake

```text
accept -> awaitingHello
            |
            +-- compatible Hello -> HelloAck -> normal
            |
            +-- parseable compatibility mismatch
            |       -> HelloReject -> bootstrapOnly
            |
            +-- malformed/auth/unparseable -> close

bootstrapOnly
  -> one BootstrapRequest/Response
  -> close

normal
  -> Request/Event/Progress/Observation/StreamFrame/ArtifactFD
```

Hello：

```text
wireRange
clientBuildID
runtimeCompatibilityID
executionCatalogHash
developerImageCatalogRevision
developerImageCatalogHash
clientInstanceID
role = cli | gui
```

HelloAck：

```text
selectedWireMajor
runtimeBuildID
runtimeCompatibilityID
executionCatalogHash
developerImageCatalogRevision
developerImageCatalogHash
connectionID
canonicalUDID
runtimeEpoch
connectionEpoch?
quiescing
```

buildID仅诊断。`runtimeCompatibilityID`覆盖非Catalog的Runtime coordination/ABI family；`executionCatalogHash`覆盖command execution contract；`developerImageCatalogRevision/hash`覆盖Developer Support source、manifest和compatibility metadata。三组compatibility identity任一不一致都进入HelloReject/bootstrapOnly，Client不得让现有Runtime使用另一app copy的catalog。

### 21.5 Request/Response

除 `runtime.recordLocalAction` 外，每个 Request exactly one Response。

```text
Client                     Runtime
  | Request(id, operation)   |
  |------------------------->|
  |<-------------------------| RuntimeEvent / Progress
  |<-------------------------| Response exactly once
```

terminal Response 后，同 request 的 Event、Progress 或 ArtifactFD 是 protocolViolation。

`AggregateResponse` v1 禁止发送；global/hybrid aggregate 只在 Client 本地形成。

第一阶段不实现 request idempotency table、`queryRequest`、断线重连恢复、自动 resend 或跨 connection terminal replay。requestID 只关联当前 connection；Client/Runtime 均不得把 tombstone 当作可靠结果数据库。

```text
RuntimeRequestV1:
  schemaVersion=1
  requestID
  payload:
    operation
    body

RuntimeResponseV1:
  schemaVersion=1
  requestID
  payload:
    operation                 # exact echo
    actionID?
    parentActionID?
    result: StandardResultV1
```

UUID 必须是 lowercase canonical `8-4-4-4-12`。sequence、byte length 和 monotonic timestamp 使用非负整数；JSON 禁止 NaN/Infinity。

normal operation body 中的 canonicalUDID 是 target-safety assertion，必须与 HelloAck target byte-for-byte 相同；不匹配时 protocolViolation + close，不映射为 deviceNotFound，也不得改投其他 Runtime。

需要 Response 的 requestID 在 active outstanding 和 recent tombstone window（64/connection，5 min）内不得重复。命中即 protocolViolation。tombstone 淘汰后不提供幂等重放保证，Client 仍禁止主动重试。`runtime.recordLocalAction` 不进入 request tombstone；其 append-once 只由 `(actionID,eventKind)` 保证。

### 21.6 19 个 Runtime operation

```text
command.submit
runtime.health
runtime.getAvailabilitySnapshot
runtime.runtimeStatus
runtime.prepareCapabilities
runtime.attachLive
runtime.detachLive
runtime.markLiveCaptureReady
runtime.stopIfIdle
runtime.recordLocalAction          # only one-way Request
runtime.cancelOwnedPendingWork
runtime.startReplayTrace
runtime.stopReplayTrace
runtime.startDiagnostics
runtime.stopDiagnostics
runtime.clearActionLogs
stream.open
stream.close
stream.cancel
```

operation 最小 body/result：

| operation | body | success result / rule |
| --- | --- | --- |
| `command.submit` | `CommandIntentV1` | `RuntimeCommandResultV1`；可先发 accepted/queued/started/progress |
| `runtime.health` | `{canonicalUDID}` | `RuntimeHealthV1` |
| `runtime.getAvailabilitySnapshot` | `{canonicalUDID}` | 完整有界 `AvailabilitySnapshotV1` |
| `runtime.runtimeStatus` | `{canonicalUDID}` | 有界 `RuntimeStateSnapshotV1` |
| `runtime.prepareCapabilities` | `PrepareCapabilitiesRequestV1` | `PreparationResultV1`；只承载explicit device.prepare，Runtime派生group并注册observer |
| `runtime.attachLive` | `{canonicalUDID,actionContext?,observationTopics[]}` | liveOwnerID/subscriptionID/epoch/revision；Response 先于首条 observation |
| `runtime.detachLive` | `{canonicalUDID,actionContext?,liveOwnerID,subscriptionID}` | cleanup 后 `{detached:true}`；already detached 幂等成功 |
| `runtime.markLiveCaptureReady` | `{canonicalUDID,captureActivationID,connectionEpoch,liveOwnerID,subscriptionID}` | `{captureProvenance:postCapture,connectionEpoch,disposition,oldExecutorGeneration?,newExecutorGeneration?,geometryRevision?,logicalWidth?,logicalHeight?,orientation?}`；geometry四字段all-or-none，只在current connection的post-capture display prewarm已成功建立authoritative snapshot时返回；只允许同一 attached live owner 的 exact current lineage，重复同 activation 返回 `alreadyReady`并在current snapshot可用时同样回传，冲突或 stale identity fail closed |
| `runtime.stopIfIdle` | `{canonicalUDID,actionContext?}` | `StopIfIdleResultV1`；busy 使用 typed blockers error |
| `runtime.recordLocalAction` | `LocalActionEventV1` | one-way；绝不回 Response |
| `runtime.cancelOwnedPendingWork` | `{canonicalUDID,targetRequestID,reason}` | `CancellationDispositionV1` |
| `runtime.startReplayTrace` | `{canonicalUDID,actionContext}` | traceID + absolutePath |
| `runtime.stopReplayTrace` | `{canonicalUDID,actionContext}` | traceID + same path + completeness |
| `runtime.startDiagnostics` | `{canonicalUDID,actionContext}` | diagnosticsSessionID + absolutePath |
| `runtime.stopDiagnostics` | `{canonicalUDID,actionContext}` | same session/path + completeness |
| `runtime.clearActionLogs` | `{canonicalUDID,actionContext?,scope:device}` | deleted counts + writerState + scanComplete |
| `stream.open` | `{intent:CommandIntentV1,interactionID}` | backend ready 后 `StreamOpenResultV1` |
| `stream.close` | `{sessionID,interactionID,reason,expectedLastSeq?}` | first-wins/join `StreamClosedResultV1` |
| `stream.cancel` | `{sessionID,interactionID,reason}` | 与 close 共用 terminal barrier |

核心 DTO：

```text
CommandIntentV1:
  commandID
  actionID?
  parentActionID?
  canonicalUDID
  normalizedArguments
  expectedConnectionEpoch?
  expectedGeometryRevision?

ActionContextV1:
  actionID
  parentActionID?

RuntimeCommandResultV1:
  commandID
  jobID?               # diagnostic only
  resolvedRouteID?
  resultSchemaID
  payload?             # must match resultSchemaID

RuntimeHealthV1:
  canonicalUDID / pid / runtimeEpoch
  runtimeState=ready|quiescing
  stateRevision

AvailabilitySnapshotV1:
  target/epoch + facts/condition/capability/geometry/inhibitor/state revisions
  quiescing
  commands[{commandID,state=enabled|disabled|loading,reasonCode?,sourceRevisions}]
  truncated / omittedCommandCount

RuntimeStateSnapshotV1:
  target/pid/runtimeEpoch/runtimeState/terminationCause?
  connectionEpoch?/connected/stateRevision
  queue/operation/stream/executor/capability summaries
  preparationSummaries[]             # max 8, PreparationStatusV1
  omittedPreparationCount
  assetAcquisitionSummaries[]        # max 4
    {catalogEntryDiagnosticID?,phase,stateRevision,sourceKind?,progress?}
  omittedAssetAcquisitionCount
  trace/diagnostics summaries
  inhibitorRevision/stopBlockers/lastErrorCode?
  truncated/otherOmittedCounts

StopIfIdleResultV1:
  disposition=stopping|alreadyStopping
  runtimeEpoch / stateRevision
  forceStopSupported=false

StopBlockerV1:
  kind=live|runningJob|pendingJob|stream|activeTrace|
       assetAcquisition|preparingCapability|controlMutation|cleanup|fencing
  count?
  ownerClientInstanceID?
  jobID? / sessionID? / commandID?
  state?
  retryWhen=liveDetached|jobTerminal|streamClosed|traceStopped|
            acquisitionFinished|capabilityResolved|controlFinished|cleanupFinished|stateChanged

PrepareCapabilitiesRequestV1:
  canonicalUDID
  actionContext?

PreparationProgressV1:
  preparationAttemptID / preparationGroupID
  phase / phaseSequence / stateRevision
  completedBytes? / totalBytes? / fraction?
  sourceKind? / sharedAcquisition? / retryAfterMs?

PreparationResultV1:
  preparationAttemptID? / preparationGroupID
  disposition=ready|alreadyReady
  capabilityIDs[] / connectionEpoch? / executorGeneration?
  assetDisposition=notRequired|cacheHit|xcodeHit|downloaded|mountedOnly
  mountDisposition=alreadyMounted|mounted|notRequired
  serviceDisposition=ready|notRequired
  provenance=approved|mountedUnknownUnverified

PreparationStatusV1:
  preparationGroupID
  state=unknown|acquiring|preparingDevice|ready|unavailable
  preparationAttemptID? / phase? / progress?
  connectionEpoch? / capabilityIDs[] / lastError?
  truncated=false

CancellationDispositionV1:
  targetRequestID
  disposition=cancelledBeforeSubmission|cancelledBeforeRunning|
              cancellationRequested|alreadyRunningCannotCancel|
              alreadyTerminal|notOwned|notFound
  targetPhase?
  terminalSummary?

StreamOpenResultV1:
  sessionID / interactionID / actionID
  executorGeneration / openedAtMonotonicNs
  pointer accepted geometry?:
    connectionEpoch / geometryRevision
    logicalWidth / logicalHeight / orientation

MarkLiveCaptureReadyResultV1:
  captureProvenance=postCapture / connectionEpoch / disposition
  oldExecutorGeneration? / newExecutorGeneration?
  current geometry? (all-or-none):
    geometryRevision / logicalWidth / logicalHeight / orientation

StreamClosedResultV1:
  sessionID / interactionID / actionID?
  disposition=closed|cancelled|alreadyClosing|alreadyClosed|notFound
  closingCause?
  terminalSummary?
  lastAcceptedSeq?
  cleanupDisposition=acknowledged|fenced|notRequired

OutcomeSummaryV1:
  outcome=succeeded|failed|cancelled|partial|outcomeUnknown
  errorCode?
  commitState?
  durationMs?
```

`cancellationRequested` 只表示 Runtime 已在同一 `clientInstanceID` 所拥有的可取消 active request
上原子设置 cancellation token；原请求保持自己的 exactly-one terminal Response，取消请求不能接收或
替代该 terminal。Element capture/analysis/annotation 支持该 disposition；不支持运行中取消的其他
OneShot 继续返回 `alreadyRunningCannotCancel`。owner 不匹配返回 `notOwned`，未知 request 返回
`notFound`，recent terminal tombstone 返回 `alreadyTerminal`。

`gui.pointer.interaction`成功的`StreamOpenResultV1`必须包含完整pointer accepted geometry；其他Stream固定省略这些字段。该geometry是Runtime注册projection owner时实际使用的权威snapshot，不是请求字段的回显。Client必须验证其connection epoch仍等于current live attachment；字段缺失、invalid或foreign epoch均视为invalid response并在任何Frame前关闭Stream。

`runtime.markLiveCaptureReady`在generation transition后会best-effort查询并同步primary display current geometry。查询成功时，Result必须回传与`connectionEpoch`匹配的完整geometry四字段；查询失败、transition=`deferred`或current snapshot不完整时固定全部省略，不得回传partial组。GUI只能把该receipt用于current attachment上尚未投递coordinate frame的binding：epoch必须exact，logical size/orientation必须与Runtime receipt一致，revision不得回退；采纳时原子rebind Live model、video binding和interaction view。receipt缺失时不得根据landscape sample宽高猜测left/right，必须保持coordinate fail closed直到后续actual authority收敛。

`captureActivationID`由GUI Live state按current attached owner + current connectionEpoch分配，不由Chooser、mapping或某个bound capture对象独立分配。同一epoch内replacement bound consumer、Change Source、capture reconfiguration以及stable presentation与current geometry不匹配时都必须使用原ID重复调用`runtime.markLiveCaptureReady`。该调用必须返回`alreadyReady`，不重新分配或退休Helper generation、service或capture provenance；Runtime只执行一次best-effort current display query/synchronization并按上述规则回传receipt。confirmed detach/new connectionEpoch和new Live owner使旧ID失效。连续presentation callback在前一refresh进行中必须合并为单一in-flight control，不得形成query storm或改写source identity。

`runtime.prepareCapabilities`的request body禁止`preparationGroupID`、source、URL、path或内部reason。Runtime依据当前DeviceFacts、OS profile、CommandCatalog和DeveloperImageCatalog派生target-default group；finite command和live prewarm通过TRD 03的内部`DemandSpec`进入同一Coordinator，不生成伪造的RuntimeWire request。

本节是`PreparationProgressV1`、`PreparationResultV1`和`PreparationStatusV1`字段的唯一owner。TRD 03只持有状态机、速率、容量、deadline和provenance语义。

`PreparationResultV1`只作为`StandardResultV1.outcome=succeeded`的value；failed/cancelled/outcomeUnknown通过StandardResult和StandardError表达，不在DTO内维护第二套error/disposition。

`preparationAttemptID`在`disposition=ready`时必填；直接命中当前capability的`alreadyReady`不创建no-op attempt并固定省略该字段。

所有 snapshot 内集合稳定排序并在 256 KiB Response cap 内完整编码；超限使用 typed bounded summary/truncated 字段，禁止截断 JSON。

Client 提供 actionID 时 Runtime 必须原样使用；缺失时 Runtime 在 received boundary 分配全局 UUID。command.submit、stream.open 和仍可关联 active/recent session 的 close/cancel 必须在 Response/Event/ActionLog 中携带最终 actionID。parentActionID 只能与非空 actionID 同时出现。

Stream request terminal 与 session terminal 是两个层次：每个 close/cancel wire Request exactly one Response，但同一个 StreamSession 只提交一次 OperationLifecycle terminal和一次 cleanup。watchdog/geometry/Runtime autonomous close 在 owner connection 仍存在时发送一次 unsolicited `streamClosed`；owner 已断连时只写 `clientGone`，不伪造 Response。

### 21.7 RuntimeEvent

```text
operationAccepted
operationQueued
operationStarted
preparationStarted
streamClosed
availabilityInvalidated
deviceDisconnected
runtimeFatal
```

Progress 独立限频、可丢弃，不是 RuntimeEvent。Preparation progress 必须携带 `preparationAttemptID`，旧 attempt 的迟到 progress 只能丢弃并写脱敏诊断。RuntimeObservation 是 presentation projection，不是 terminal。

`operationAccepted/Queued/Started` 必须先于同 request 的 terminal Response。`stream.open` Response 是唯一 open-ready 事实，不再发送 streamOpened event。显式 close/cancel Response 已承载 session terminal时不再发送 streamClosed；只有 watchdog/geometry/autonomous cleanup 使用 unsolicited streamClosed。

```text
StreamFrameV1:
  sessionID / interactionID / seq
  frameKind
  payload
  clientSubmittedMonotonicNs?

RuntimeObservationV1:
  subscriptionID / clientInstanceID / interactionID
  observationSequence
  presentationPayload { edge / frameKind / x / y }

ObservationStreamResetV1:
  subscriptionID
  nextSequence
  reason
```

frame delivery class 来自 StreamSessionPlan frameSchema，Client 不能自报 ordered/coalescible。Observation queue 饱和时发送 reset 或断开 subscriber，不反压 device execution。

Live subscription跨同一Runtime内的USB reconnect保留原`subscriptionID`。Detach、epoch
替换、sequence gap或queue saturation发送`ObservationStreamReset`并推进该subscription
的`nextSequence`，旧epoch排队中的observation不得在reset之后投递。只有显式
`runtime.detachLive`、peer close、Runtime stop/fatal或不可恢复的subscriber断开才销毁
subscription。

### 21.8 Stream close/cancel

并发 close/cancel 使用 first-wins + join：

```text
first request
  -> freeze closingCause
  -> one Helper close/cancel
  -> one cleanup
  -> one session terminal

later request
  -> join same terminal barrier
  -> no second cleanup
```

barrier 完成后，第一个 request 返回 `closed|cancelled`，joiner 返回 `alreadyClosing`；两者引用同一个 immutable terminalSummary、lastAcceptedSeq 和 cleanupDisposition。recent tombstone 内返回 `alreadyClosed` + 同一 snapshot；淘汰后返回 `notFound`。每个 wire request 各有一个 Response，但 session terminal 和 cleanup 只发生一次。

### 21.9 GUIHostWire

```text
0x0001 Hello
0x0002 HelloAck
0x0003 HelloReject
0x0004 ProtocolError
0x0100 OpenLive
0x0101 OpenLiveResult
```

GUIHost 没有 bootstrapOnly、event、stream 或 FD message。每连接最多一个 outstanding OpenLive。

GUIHost Hello 与 Runtime Hello schema 隔离：

```text
GUIHostHelloV1:
  wireRange
  launcherBuildID
  guiHostCompatibilityID
  launcherInstanceID
  canonicalAppPathHash

GUIHostHelloAckV1:
  selectedWireMajor
  guiBuildID
  guiHostCompatibilityID
  guiHostInstanceID
  canonicalAppPathHash

OpenLiveV2:
  schemaVersion=2
  requestID
  payload:
    canonicalUDID
    sourceSelectionPolicy=automatic|forceChooser

OpenLiveResultV2:
  schemaVersion=2
  requestID
  payload:
    disposition=opened|alreadyOpen|sourceSelectionOpened|failed
    result?    # success: owner windowID + reserved canonicalUDID
    error?     # failed: code + details
```

任何 GUIHost HelloReject 发送后立即关闭，不允许 bootstrapOnly。目标 UDID 只出现在 OpenLive，不进入 GUIHost Hello。

OpenLiveResult：

```text
opened                 new target reservation + Resolver accepted
alreadyOpen             automatic policy focused existing Live/Chooser
sourceSelectionOpened   forceChooser opened/focused associated Chooser
failed                  guiHostBusy | windowCreateFailed
```

`guiHostUnavailable`、`guiIPCFailure`、`guiLaunchOutcomeUnknown` 由 launcher 根据本地阶段合成。

GUIHost 只能直接产生 `guiHostBusy`、`windowCreateFailed`。三个 success disposition 都必须携带 reserved canonicalUDID 和 owner windowID；`opened` 只证明 reservation + Resolver 已接受，不证明 Chooser/Live 最终状态或 Runtime/video/audio ready。`sourceSelectionPolicy` 只控制是否强制进入关联 Chooser，不允许 GUIHost 改选 target。

## 22. BootstrapControlV1

只存在于 parseable compatibility HelloReject 后的同一 RuntimeWire connection。

允许 operation：

```text
probeRuntimeLite
stopReplayTraceAndFinalize
retireIfIdle
```

每个 bootstrapOnly connection 恰好一个 request/response，15 秒 absolute lifetime，payload cap 16 KiB。

```text
BootstrapRequestV1:
  schemaVersion=1
  requestID
  operation
  payload={}

BootstrapResponseV1:
  schemaVersion=1
  requestID
  operation             # exact echo
  ok
  result?               # ok=true only
  error?                # ok=false only, code+details
```

Result：

```text
probeRuntimeLite
  RuntimeLiteV1{canonicalUDID,pid,runtimeBuildID,runtimeEpoch,
                runtimeCompatibilityID,executionCatalogHash,
                developerImageCatalogRevision,developerImageCatalogHash,
                quiescing,blockersSummary[]}

stopReplayTraceAndFinalize
  {traceID,absolutePath,completeness=complete}

retireIfIdle
  {disposition=stopping|alreadyStopping}
```

Bootstrap stable error subset 只允许：

```text
unsupportedBootstrapOperation
incompatibleRuntimeBusy
noActiveTrace
traceWriteFailed
runtimeFailed
```

`probeRuntimeLite` 必须返回 canonicalUDID；Client 重算 H 并校验当前 socket basename，防止连接错误 Runtime。

Bootstrap 不访问设备、不解释 CommandCatalog、不更新 `lastCLIActivityAt`。

## 23. HelperWire 与 Helper 模型

### 23.1 Helper 类型

```text
CoreDeviceHelper
  prep.coredevice.v2
  userspace tunnel / RSD / RemoteXPC
  personalized image query/mount/TSS device phase
  HID / keyboard / orientation / screenshot / app control

DirectHelper
  prep.direct.lockdown.v1
  prep.legacy.developer.v2
  classic usbmux/Lockdown/installation/DDI/DVT
```

CoreDevice 所有 facet 共用一个 generation，不按 command 重复 spawn tunnel/Helper。

CoreDevice generation还携带Runtime内存态`captureProvenance=preCapture|postCapture`和当前connection epoch的一次性replacement状态。StreamSession、具体HID service handle与Helper generation是三个不同生命周期：`StreamClose`、`Cancel`、全部按键释放后的300 ms keyboard close、pointer gesture terminal或`active.streams.isEmpty`都不得改变capture provenance，也不得触发generation retirement。

在同一current post-capture generation内，CoreDevice Helper必须按需持有至多一个Indigo input service和一个Universal HID input service；keyboard virtual service ID同样只属于该generation。每个pointer/keyboard StreamSession仍独立open、ordered frame、release-all或touch end、close/cancel和Runtime claim，不得为了复用service把多个产品interaction合并成一个Stream。Stream terminal只释放本interaction的device input state，不关闭健康service；Helper fatal、service/frame/cleanup fatal、detach、新connection epoch、incompatible retire或Runtime quiesce必须有界release并关闭全部generation-scoped input service。button OneShot、Software Keyboard Toggle和明确分类的system edge gesture串行复用Indigo；普通tap/drag/swipe和pointer edge=`none`复用Universal HID `mainTouchscreen`，keyboard/text继续复用Universal HID及generation-scoped keyboard service。Software Keyboard Toggle虽走Indigo，仍取得exclusive `input.keyboard`，不得与keyboard/text interaction交错。任何route都不自动重放、不越过Scheduler claim，也不把service存活或wire Ack解释为设备成功。

generation-scoped keyboard service具有`absent -> settling -> ready`内部状态。`create_keyboard_service` Ack后
进入`settling`并等待1秒，期间不得发送pasteboard SET或任何keyboard pressed-set；等待取消或失败时保留
同一个service ID及`settling`状态，后续请求继续完成等待，不得重复创建。只有进入`ready`后才允许首个
Keyboard Capture、`text.type`或Text HID事件；同generation复用不得再次等待。该readiness不改变公开
result schema、Scheduler claim、interaction terminal或首次可能收起软件键盘的原生行为。

该策略来自iPhone 14 / iOS 26.5.2 packaged实体单变量：同一post-capture Helper PID/generation下，第一段fresh Indigo pointer Stream真实打开App Store，随后新建并立即关闭的短Stream仍得到open/frame/cleanup协议Ack但设备不再响应；Helper PID/generation不变且button OneShot仍成功。后续在同一设备、同一landscapeRight Calculator状态和同一raw point上的有界A/B又证明Universal `mainTouchscreen`与Indigo都能真实命中相同数字，推翻“Universal在该设备恒不可用”的扩大结论。普通touch因此回到已研究验证的Universal路线，Indigo只保留button和真实edge semantics；实现仍必须以连续分离pointer/keyboard实体结果证明service continuity，协议Ack或本地overlay不能替代设备oracle。

GUIHost在正式bound video session接受当前target/current epoch的首个有效sample后，通过同一已attach live connection发送内部`runtime.markLiveCaptureReady` control。请求必须携带并由Runtime校验当前canonical target、live owner/subscription、connection epoch和单次capture activation ID；不得携带raw AVFoundation unique ID、设备名称、列表下标或图像内容。该control只记录/完成§18.3的一次性provenance转换，不是公开Product Action，不创建第二套preparation group，也不替代`runtime.prepareCapabilities`。

若旧generation为空闲，Runtime可在该control内完成`shutdown -> bounded cleanup/reap -> spawn/Hello/Ready`并返回`replaced`；若仍有owned Stream/OneShot，则返回`deferred`并在安全barrier转换。相同activation重复请求返回`alreadyReady`，foreign/stale owner、connection epoch或activation冲突返回protocol/target failure并且零generation mutation。diagnostics只记录old/new executor generation、connection epoch、触发原因、elapsed和typed outcome，不记录target/source原始身份。

Direct lockdown 与 legacy developer 共用一个 Runtime-coordinated process slot；一进程只执行一个 OneShot，cleanup 后退出。

### 23.2 HelperWire framing

UTF-8 JSONL，每行：

```text
schemaVersion
type
runtimeEpoch
executorGeneration
messageID
requestID? / sessionID? / attemptID? / preparationAttemptID? / deliveryAttemptID?
payload
```

stdout 只允许 HelperWire JSONL；stderr 只允许有界脱敏诊断。

### 23.3 Handshake 与设备 I/O

```text
Helper spawn
  -> Helper Hello
  -> Runtime validate build/manifest/process identity
  -> atomically write helpers.v1.json
  -> HelloAccepted
  -> Helper may start device I/O
  -> Ready
```

Helper 在 HelloAccepted 前不得设备 I/O。

### 23.4 Message types

```text
Hello / HelloAccepted / Ready
Request / Accepted / Started / Committed / Progress / Result
StreamOpen / Frame / FrameAccepted / Close / Cancel
Shutdown / DeviceDisconnected / ProtocolError
```

OneShot order：

```text
Request -> Accepted? -> Started? -> Committed? -> Result exactly once
```

Result 后同 request event 是 protocolViolation。若已经收到 Committed，Result.commitState 必须为 committed。

Stream Frame 一帧对应一个 FrameAccepted；Frame 不产生 Result。Close/Cancel 只有 cleanup/release barrier 完成后才能成功 Result。

```text
HelperRequestV1.payload:
  actionID
  parentActionID?
  executorOperationID
  backendPayload

DeveloperSupportRequestV1.payload:
  preparationAttemptID
  preparationGroupID
  catalogRevision
  catalogEntryID
  fileRoles[]             # fixed role IDs only
  operation=queryMounted|requestTSS|mount|probeServices|warmGeneration
  deviceContext

HelperResultV1.payload:
  fallbackDisposition=safe|terminal|unknown
  result=StandardResultV1

StreamOpenV1.payload:
  actionID / parentActionID?
  interactionID / streamKind / streamPayload

FrameV1.payload:
  interactionID / seq / framePayload

FrameAcceptedV1.payload:
  interactionID / seq / acceptedMonotonicNs?
```

`deliveryAttemptID` 只存在 HelperWire envelope 一次，payload 不重复。Frame/FrameAccepted 必须按 sessionID/seq/deliveryAttemptID 一一关联。

`executorOperationID` 和 backendPayload schema 只能来自 CandidatePlan、Helper manifest 和 executionCatalogHash 覆盖的 registry；禁止为 commandID 新增 Helper message type。

Developer Support asset handoff 只接受以下固定 role：

```text
classic.image
classic.signature
personalized.buildManifest
personalized.image
personalized.trustCache
```

Runtime先以`catalogRevision + catalogEntryID + role`在受控AssetStore中解析并校验；Helper再从预先打开的Application Support root使用anchored relative lookup、regular-file/no-symlink、owner/mode/size/hash校验。Client path、URL、绝对路径、`..`和catalog override一律不进入HelperWire。任一层失败返回`developerImageIntegrityFailed`，不得尝试nearest version。

`requestTSS` 只允许 Helper 在 Runtime policy 下访问固定 Apple host allowlist；payload、ECID、nonce、ticket、完整 URL 和响应体不得进入 ActionLog/普通诊断。TSS timeout、offline、reject 和 malformed response 映射为 TRD 03/07 注册的 Developer Support error，不得静默换源或跳过 personalization。

Ready 前的 direction/order/token/payload failure使 preparation 失败并退休 generation；Ready 后同类问题属于 fatal Helper protocol failure。Helper stdout 混入普通日志属于 protocolViolation。

`developerServicesUnavailable`若发生在已确认的`preCapture` generation，只能作为一次性replacement的诊断输入，不能通过重放原OneShot伪造成功；post-capture replacement完成后，相同connection epoch中的后续button、pointer和keyboard必须复用新generation，直到§18.3允许的retire条件成立。

### 23.5 preparation group

```text
prep.coredevice.v2
  iOS 17+ CoreDevice userspace tunnel/RSD/Helper generation

prep.direct.lockdown.v1
  usbmux + classic Lockdown direct services

prep.legacy.developer.v2
  approved classic DDI query/mount + legacy developer/DVT services
```

Runtime 权威解析当前 generation 的 surface/serviceID。Client/Catalog/Wire 不携带或硬编码动态 surface ID、keyboard service ID。

## 24. LocalDeviceFactsProbe

LocalDeviceFactsProbe 是唯一 Client -> Helper 设备 I/O 例外。

### 24.1 约束

```text
DirectHelper --mode facts
autopair=false
independent process group
no bootstrap.lock
no runtime.lock
2 s work deadline from spawn
abnormal termination/reap budget 1 s
Ctrl-C uses remaining shared 1 s only
```

允许：

```text
usbmux ListDevices
usbmux Connect selected DeviceID to port 62078
Lockdown QueryType
Lockdown GetValue allowlist
optional Goodbye
```

GetValue keys：

```text
DeviceName
ProductType
ProductVersion
BuildVersion
DeviceClass
UniqueDeviceID
```

禁止 Pair、StartSession、StartService、SetValue、tunnel、RSD、DDI、developer service、pairing record mutation。

### 24.2 FactsProbeWire

stdin/stdout 各恰好一条 UTF-8 JSONL：

```text
FactsProbeRequestV1
  operation = enumerate | probe

FactsProbeResponseV1
  matching requestID/operation
  result or registered error
```

完整 DTO：

```text
FactsProbeRequestV1:
  schemaVersion=1
  requestID
  operation=enumerate|probe
  payload

FactsProbeResponseV1:
  schemaVersion=1
  requestID
  operation             # exact echo
  ok
  result?               # ok=true only
  error?                # ok=false only

enumerate payload={}
  -> RawDiscoverySnapshotV1{observedAtMonotonicNs,devices[]}

probe payload={deviceID,rawTransportUDID}
  -> FactsProbeResultV1{facts,condition,provenance}
```

FactsProbe DTO 禁止 runtimeEpoch、executorGeneration、actionID 或 Runtime state。每个 Lockdown response <=64 KiB；probe total <=256 KiB。

request cap 16 KiB；response cap 256 KiB；最多 256 devices。第 257 台 fail closed 为 `deviceEnumerationLimitExceeded`，bounded prefix 只能放在 error details，不能用于默认目标选择。

probe child 必须重新 enumerate 并验证 DeviceID/rawTransportUDID，不能直接信任 Client 输入。

timeout、malformed、第二行、requestID mismatch、stdout 混入日志或非零退出都进入同一 `killpg(SIGKILL)` + reap 路径。

正常 response 后 Client 必须 waitpid。child 从 spawn 起运行同一 2 秒 monotonic watchdog；deadline 到达时主动关闭连接并终止自身 process group，防止 Client hard crash 后继续设备 I/O。普通异常调用最多占用 2 秒 work + 1 秒 termination/reap；SIGINT 不另加 1 秒，只使用整次调用剩余预算。
