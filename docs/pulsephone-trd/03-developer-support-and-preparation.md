# PulsePhone TRD 03 - Developer Support 与 Capability Preparation

> 文档状态：第一阶段规范章节
>
> 上级文档：[`pulsephone-trd.md`](../pulsephone-trd.md)
>
> 负责范围：第14～18节；DeveloperImageCatalog、AssetStore、DDI、TSS、两层single-flight、PreparationAttempt、phase-scoped claims、deadline和failure boundary。

本章是Developer Support子系统的唯一事实源。通用Scheduler/Gate/inhibitor由TRD 02持有；Runtime supervision由TRD 04持有；Wire/Helper framing由TRD 05持有；公开command和Client UX由TRD 06持有；路径权限、error registry和hard cap由TRD 07持有；来源/法律/evidence由TRD 08持有。

## 14. 系统模型与所有权

### 14.1 三套生命周期

```text
host DeveloperImageAsset
  download -> validate -> immutable cache
  lifetime: cross-device / cross-connection / cross-Runtime

device image mount
  query -> personalize if required -> upload -> mount
  lifetime: usually survives USB detach; may end on reboot/update/unmount

Helper/tunnel/service generation
  spawn -> tunnel/RSD -> service handles -> retire
  lifetime: exactly one connectionEpoch; never reused after detach
```

USB detach只终止device-side preparation和当前connection generation；已经取得host download ownership的AssetAcquisitionTask可以继续。Runtime退出后host cache仍存在；device mount也可能继续存在。

### 14.2 独立前提

```text
pair / Trust
  -> host pairing record and Lockdown session

Developer Mode where applicable
  -> device permits developer capability

DDI mount
  -> developer service payload available on device

iOS 17+ tunnel
  -> host reaches RSD / RemoteXPC endpoints
```

上述状态不能合并成一个布尔值。USB discovery、basic Lockdown facts、installation_proxy install/uninstall和AVFoundation preview不因DDI unavailable而整体降级。

### 14.3 模块与依赖

```text
DeveloperImageCatalog
  dynamic approved catalog snapshots and compatibility rules

DeveloperImageAssetStore
  source resolution, download, validation, extraction, cache and locks

DeveloperImagePreparationCoordinator
  Demand/Observer/Attempt, progress, deadlines and capability commit

DeveloperImageBackendAdapter
  catalog-reference handoff, image query/mount, TSS and service probe
```

Client只提交target-only的`device.prepare`请求或普通CommandIntent并渲染projection；不提交PreparationGroup、内部触发原因、URL、cache path、hash、mount、TSS或tunnel状态。Runtime是权威owner，Helper只执行批准的设备协议和固定TSS路径。

### 14.4 Readiness 与 demand

`coordinatorReady`与capability ready分离：

```text
Runtime startup
  -> lock/socket/catalog/scheduler/state/usbmux monitor
  -> coordinatorReady
  -> accept RuntimeWire requests

coordinatorReady
  +-> non-DDI command can execute
  +-> explicit device.prepare creates/joins demand
  +-> finite command may create a start-only demand
  `-> live launcher may create a start-only demand before GUI creation
```

Runtime startup、plain USB attach、device info/status、install和uninstall不无条件下载、mount或创建tunnel。

三种入口统一派生为Runtime内部`DemandSpec`：

```text
DemandSpec
  origin = explicitPrepare | finiteCommand | livePreflight
  preparationGroupID          # Runtime derived
  persistence = epochBound
  ownerReference

explicitPrepare
  group <- current facts + OS profile + device.prepare descriptor
  persistence = epochBound

finiteCommand
  group <- authoritative CandidatePlan
  persistence = epochBound

livePreflight
  group <- live launch policy + current facts
  persistence = epochBound
```

`runtime.prepareCapabilities`有两种固定 mode：public explicit `device.prepare` 使用`waitForTerminal`，CLI `live` preflight 使用`startOnly`。finiteCommand 在Runtime内部创建`startOnly` DemandSpec，不伪装成Wire request。第一阶段每个目标OS profile的`device.prepare`解析为一个target-default PreparationGroup；无法唯一解析时返回typed unavailable，禁止Client选择group规避Planner。

## 15. Catalog、Source 与 AssetStore

### 15.1 Source order

```text
1. already-mounted image on device
2. verified PulsePhone Application Support cache
3. /usr/bin/xcode-select -p selected release Xcode
4. immutable catalog approved remote source
5. typed unavailable
```

Xcode是可跳过local optimization，不是runtime prerequisite。禁止beta Xcode、arbitrary user directory、运行时枚举或发现第三方 catalog、nearest-version guess和caller-provided URL。运行时只能读取本节定义的固定 owner-controlled catalog URL；不得调用 GitHub Tree API、Contents API、搜索 API 或根据目录列表推导候选文件。

### 15.2 DynamicDeveloperImageCatalogV1

PulsePhone 不再随 app 发布或在 Runtime handshake 中固定 Developer Image catalog。需要 host
asset 的 preparation job 从唯一的 owner-controlled HTTPS catalog 取得已校验 snapshot；动态
的是资产与 build 映射，不是运行时任意信任远端文件。schema 固定为：

```text
schemaVersion / catalogRevision
defaultCandidateBaseAssetID
baseAssets[] { baseAssetID, contentManifestSHA256, archiveSHA256, archiveSize, sourceURL }
developerDiskImages[] { ddiVersion, contentManifestSHA256, archiveSHA256, archiveSize, sourceURL }
catalogEntry[] { iosVersion, buildID, baseAssetID }
```

catalog 使用 RFC 8785 JCS UTF-8 canonical bytes；其 identity 是 canonical bytes 的 lowercase
SHA-256。`catalogRevision` 固定为 `YYYY-MM-DD.<positive-decimal-sequence>`，先比较日期、再以
任意精度十进制整数比较 sequence。相同 revision 但不同 canonical hash 是内容分叉，较旧 revision
是回滚；两者均为 `developerImageCatalogMismatch`。新 catalog 不进入 Runtime compatibility
handshake，刷新只能影响后续 preparation job。

每一 `catalogEntry` 的 `buildID` 在 v1 全局唯一，并且是远端和本地选择的唯一主键；不得增加
product type、chip、board 或其它硬件 discriminator。它表示维护者亲自在这个精确 build 的真机上，
使用指定 BaseImage 完成 TSS、mount 和完整 prepare service profile 后审核发布的映射。本机默认
candidate 成功记录不能自动生成或更新远端 `catalogEntry`。

classic 资产只选择完整 iOS 版本，或在该完整版本不存在且输入含 patch 时选择同 major/minor
版本；不作最近版本猜测。personalized 路由依序选择远端精确 `catalogEntry`、本地 exact-build
`CatalogEntry/`、再 `defaultCandidateBaseAssetID`。default candidate 不是已验证兼容声明。

### 15.2.1 Owner-controlled remote catalog

当前 trust root 为：

```text
catalog URL
  https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/developer-image-catalog.v1.json

archive URL prefix
  https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/
```

`release` 是 owner 管理的受控发布分支，不是任意上游 mirror。运行时只 GET exact catalog URL 和
catalog 中已批准的 direct raw archive URL；禁止 GitHub Tree、Contents、Search API、目录枚举、
nearest-build、caller URL/path 和未声明 mirror。HTTPS 远端是当前权威，但已接受 snapshot 不会被
有效但较旧的响应覆盖。

首次需要 host asset 时必须先获得已校验 catalog。没有 current 或 last-known-good catalog 的
bootstrap 获取失败返回 `developerImageCatalogUnavailable`；Xcode 不能在该状态下自行扩展支持范围。
刷新失败时可使用本轮开始时的 last-known-good snapshot，并在机器可读 projection 标记
`staleCatalog=true`。一旦成功接受新 active catalog，旧 catalog、旧本地记录和旧 cache asset
都不得选择已被该 active catalog 退役的资产。当前预发布阶段只维护新增资产；首次外部
PulsePhone 发布后才强制已发布 archive 路径和字节永久不变。

catalog、archive、cache key、日志和请求不得包含 UDID、ECID、pairing record、nonce、TSS ticket
或设备内容。archive 和解压必须做 hash、固定文件集和路径安全验证；本阶段不新增公开的
catalog、archive、cache、重试或解压数值配额。

### 15.3 两层 single-flight 与 snapshot

设备侧：

```text
PreparationSingleFlightKey
  runtimeEpoch + connectionEpoch + preparationGroupID

first demand -> one PreparationAttempt
later prepare/Gate/live demand -> join same attempt
```

catalog refresh 也 single-flight/coalesced：一个 owner 获取与校验，其他调用共享同一 accepted
或 last-known-good outcome。每个需要资产的 PreparationAttempt 在第一次成功解析 catalog 后创建
immutable `CatalogSnapshot { catalogRevision, catalogCanonicalSHA256 }`；其 asset selection、cache/Xcode
matching、archive hash、TSS、mount 和 warm 全程只能使用该 snapshot。并发刷新不能令已开始 attempt
混用两个 revision 的 metadata 或 asset。

host asset 以 content manifest hash 寻址。所有 Runtime 进程对同一内容目录使用 host-wide store
lock 与 per-content exclusive lock；同一 content 只有一个 acquisition owner，验证后的内容只原子
发布一份。每台设备仍分别 mount/personalize 并创建自己的 connection generation。

### 15.4 Acquisition algorithm

```text
query mounted state
  -> mounted + current group service-ready: no catalog or host asset required
  -> mounted + unready: warm/re-probe; do not redownload or remount merely because warm is pending
  -> confirmed not mounted:
       acquire/pin CatalogSnapshot
       -> select classic DDI or BaseImage from that snapshot
       -> verified PulsePhone cache -> matching selected Xcode -> approved remote archive
       -> validate fixed archive members and content manifest
       -> atomically publish content-addressed asset
       -> revalidate epoch/attempt, then TSS when required, upload/mount, and full service warm
```

下载只写 private partial/staging，完成 archive hash、固定文件集、content manifest 和 fsync 后才可
atomic rename。实现必须拒绝 absolute path、`.`、`..`、symbolic/hard link、device node、duplicate path、
缺失成员和额外成员；archive、partial、PID、mtime 或 progress 不是 ownership 事实。partial resume
只能在同一 archive hash、source identity 和 catalog snapshot 下继续，否则删除 partial/sidecar 后从零
开始。所有 host lock 等待不得阻塞 RuntimeCoordinationActor。

### 15.5 Logical layout、local observation 与回收

```text
$PULSE_HOME/
  Catalog/
    developer-image-catalog.v1.json
    metadata.json
    last-known-good/
  DDI/<classic-content-manifest-sha256>/
  BaseImage/<base-content-manifest-sha256>/
  CatalogEntry/<buildID>/<base-content-manifest-sha256>.json
  private partial/staging/locks/cache-index state
```

`metadata.json` 至少保存 accepted `catalogRevision`、canonical SHA-256、catalog URL、ETag、
fetchedAt 与 expiresAt；catalog/metadata pair 在 lock 下原子发布，并保留内部 last-known-good
pair 用于中断恢复。`CatalogEntry/` 只记录 default candidate 实际完成 mount 和完整 service profile
的本机观察，选择仅按 `buildID`。它不保存 device identity、ticket、nonce 或硬件范围；它引用的
BaseAsset 必须在本作业 snapshot 中仍处于 active，否则不得选择。

只在刷新失败时才可从本轮开始时的 LKG snapshot 选择对应资产。active/locked/current-attempt asset
绝不回收；空间不足时可回收完整且已验证的非活动内容，仍无法安全发布则返回
`developerImageCacheCapacityExceeded`。本阶段不规定新的数值 cache cap 或最小保留空间。

## 16. Preparation 生命周期与调度

### 16.1 Demand 与 bounded wait registry

```text
explicit device.prepare
  -> target-only Wire request
  -> Runtime-derived epochBound PrepareDemand + PrepareObserver
  -> completion on group ready/unavailable/disconnected

finite command
  -> Runtime-derived epochBound start-only PrepareDemand
  -> immediate `capabilityPreparing` remediation
  -> no re-plan, Scheduler admission, execution, or automatic retry

live preflight
  -> Runtime-derived epochBound start-only PrepareDemand
  -> immediate remediation before GUIHost/Resolver/window creation
```

PrepareObserver 每 UDID 最多 64 个，由`PreparationWaitRegistry`登记；start-only demand不占 observer capacity。超限在observer创建前返回`admissionCapacityExceeded`，details固定`capacityClass=preparationWaitRegistry, limit=64, truncated=false`。

`epochBound` demand在USB detach时与对应observer一起删除，绝不恢复或重放。第一阶段没有跨连接 persistent preparation demand。host AssetAcquisitionTask使用独立生命周期，不因DemandPersistence变化回滚已经拥有的download。

### 16.2 Prepare control lifecycle

```text
received
  -> validated
       +-> terminal known failure
       `-> registered/observing     # control commit boundary
            +-> ready
            +-> unavailable
            +-> deviceDisconnected
            +-> clientGone (transport only; job continues)
            `-> Runtime fatal/EOF projection
```

每个显式 observer 具有独立requestID/actionID/observerID和exactly-once terminal。requestID唯一性和duplicate处理完全由TRD 05持有，不存在preparation专用duplicate error。Progress可合并，terminal必须进入reliable queue。新 observer 必须先重放当前最新 progress，再接收后续 progress 与同一 terminal。Client EOF 只移除自己的observer transport；CLI SIGINT 不移除 observer，也不存在 observer deadline。任何 observer 离开都不回滚已经运行的shared attempt或owned acquisition；最后一个reference离开后，当前bounded attempt可以完成，不能自动retry或在terminal后由普通命令重建demand。

### 16.3 Attempt identity 与状态

```text
PreparationAttemptIdentity
  runtimeEpoch
  connectionEpoch
  preparationGroupID
  preparationAttemptID
  executorGeneration?       # Helper exists后加入
```

```text
created
  -> queryingMountedImage
       +-> waitingForAsset
       +-> waitingForGenerationClaims
       `-> terminalUnavailable

waitingForAsset
  -> waitingForDeviceClaims

waitingForDeviceClaims
  -> personalizing/uploading/mounting
  -> startingGeneration
  -> probingServices
  -> terminalReady | terminalUnavailable | terminalDisconnected

waitingForGenerationClaims
  -> startingGeneration -> probingServices
  -> terminalReady | terminalUnavailable | terminalDisconnected
```

终态不可回到created；显式retry创建新preparationAttemptID。所有device/TSS/Helper callback必须匹配完整identity。Asset cache commit按独立`assetKey + acquisitionAttemptID`生效，可以在device attempt断开后完成，但不得更新新epoch capability；catalog revision/entry只是source和assetKey mapping，不进入immutable content identity。

### 16.4 Phase-scoped claims

PreparationAttempt从created到terminal持有`preparingCapability` inhibitor，但不在网络acquisition期间持有device lease。

```text
query phase
  exclusive service.mobile-image-mounter
  exclusive executor.direct.process-slot
  -> query -> release

asset acquisition
  no device ResourceLease

asset ready
  -> revalidate epoch/attempt
  -> re-query mounted state

mount-generation phase
  exclusive device.developer-environment
  exclusive service.mobile-image-mounter
  exclusive executor.direct.process-slot
  exclusive executor.coredevice.generation-control  # modern only
  -> personalize/mount/generation/probe -> release

already-mounted generation phase
  shared device.developer-environment
  exclusive direct.process-slot                     # legacy only
  exclusive coredevice.generation-control            # modern only
```

所有DDI-dependent command执行时取得shared`device.developer-environment`。mount mutation等待已有developer-service operation完成并阻止新冲突claim插队。install/uninstall不使用该key，只可能遇到有界direct process-slot冲突。

Preparation claimant复用DeviceScheduler all-or-nothing、FIFO和disjoint bypass，不进入OneShot CommandQueue，不改变Product accepted boundary。每次claim wait最多5分钟；超时以`preparationTimeout`和`phase=deviceClaimWait`终止attempt，并原子释放inhibitor及任何已提交的内部状态。

### 16.5 Capability invalidation

以下事件统一使相关capability revision失效并重新评估demand：

```text
connectionEpoch change
trust / Developer Mode readiness change
device OS build or catalog mapping change
mounted signature/manifest mismatch
Helper/tunnel/service generation retire
required service probe failure
```

## 17. Classic、Personalized 与 Helper

### 17.1 iOS 14～16 classic

```text
ProductVersion/build -> pinned catalog snapshot exact classic DDI
  -> only patch-to-minor fallback when exact version is absent
  -> DeveloperDiskImage.dmg + signature
  -> com.apple.mobile.mobile_image_mounter
  -> ReceiveBytes / USB stream
  -> MountImage(ImageType=Developer)
  -> /Developer
  -> DVT/screenshotr probe
  -> prep.legacy.developer.v2 ready
```

PulsePhone不生成DMG、不从设备提取DMG、不按最近版本复用。facts/install/uninstall不依赖legacy developer group。

### 17.2 iOS 17+ personalized

```text
remote exact build mapping, local exact-build observation, or default candidate
  Image + BuildManifest + trustcache
  -> query current device manifest/personalization inputs
       +-> reusable device manifest
       `-> fixed Apple TSS endpoint -> ApImg4Ticket
  -> MountImage(ImageType=Personalized)
  -> /System/Developer
  -> tunnel/RSD/RemoteXPC
  -> CoreDevice service probes
  -> prep.coredevice.v2 ready
```

若已mounted，不请求TSS。若reusable manifest可完成mount，offline继续；否则TSS unavailable返回isolated`personalizationServiceUnavailable`。

`MountImage` 的 `Complete` 只证明 mount 已提交，不证明挂载前读取的 RSD service directory 已包含新的
Developer Support surface。首次 mount 成功后，Helper 必须关闭用于 mobile-image-mounter 的旧 tunnel/RSD
generation，并重新打开 tunnel、重新读取 RSD peer information；只可在新的 generation 上重新查询 mounted state
并执行 required-service probe。该刷新不重发 `MountImage`、不重发 TSS，也不是对 Product Action 的自动 retry；
fresh discovery 或 probe 失败时本 PreparationAttempt 以既有 typed terminal 失败。

Runtime拥有TSS policy、attempt identity、deadline和result normalization。Helper只访问内置Apple TSS allowlist endpoint，禁止caller URL和越界redirect。ECID、nonce、manifest和ticket只在Helper内存存在，不进入RuntimeWire、log、trace、metrics、catalog或长期inventory。

### 17.3 Helper asset reference

第一阶段不使用双handoff路径。Runtime 向 Helper 发送已由钉住 catalog snapshot 选定的
content-addressed asset reference：

```text
catalogRevision
catalogCanonicalSHA256
assetContentManifestSHA256
fileRoles[]
```

允许role：

```text
classic.image
classic.signature
personalized.buildManifest
personalized.image
personalized.trustCache
```

Helper 以 `catalogRevision + catalogCanonicalSHA256 + assetContentManifestSHA256 + role` 为唯一请求
解析键；Runtime 先校验该 asset 仍属于 job snapshot，Helper 再在 trusted DeveloperImages root 下打开
对应内容目录的固定 role，使用 openat+O_NOFOLLOW、fstat owner/type/size 并重复 SHA-256。禁止
Client/user path、archiveRelativePath、absolute path、arbitrary relative path、URL 和 catalog override。
任一层失败返回 `developerImageIntegrityFailed`。

### 17.4 mounted state

mobile_image_mounter只能查询mounted state、image type、signature或manifest，不能从标准非越狱设备取回完整DMG/BuildManifest/trustcache。

`DeveloperSupportProvenance`只有：

```text
approved
  mounted image映射到approved catalog entry，或由exact approved host asset完成mount

mountedUnknownUnverified
  只复用设备上已经存在、来源无法映射的mount
  required service probe成功后仅供当前connectionEpoch使用
```

`mountedUnknownUnverified`不得作为cache source、remount source、actuallyVerified或releasedCapability evidence，也不触发仅为未来remount而进行的后台下载。未来确实需要remount时必须重新走approved source。PulsePhone第一阶段永不自动unmount。

### 17.5 OS profiles

```text
legacyClassic: 14.0 <= iOS < 17.0
  transport = usbmux/Lockdown
  image = classic
  target = facts/status/install/uninstall
  conditional = screenshot/launch
  unsupported = pointer/keyboard/HID/rotate/type control

modernRSD: iOS >= 17.0
  transport = tunnel/RSD/RemoteXPC
  image = personalized
  backend = CoreDevice facets
```

版本差异优先数据化到service name、mapping、command IDs、format quirks和evidence scope；只有framing/行为实际变化才增加backend分支。

## 18. Deadline、Projection 与 Failure

### 18.1 Deadline

catalog、asset acquisition、validation、mounted-state query、TSS、device claim、mount、Helper
generation、service warm 和完整 PreparationAttempt 都有各自的 monotonic phase/attempt deadline，
不因 progress、observer、detach 或重入重置。本动态 catalog 阶段不在产品合同中新增具体数值；
实现必须保留现有 Runtime/transport 的资源与超时保护。任何内部 phase/attempt deadline 到期统一
返回 `preparationTimeout` 并携带 typed phase details。DDI-dependent ordinary CLI 不等待 preparation，
立即返回 remediation；显式 prepare 观察该 Runtime terminal，不设置独立 client deadline。

explicit observer 不延长或缩短共享attempt的`preparationAttemptAbsolute`。`device prepare` 的 CLI 忽略 SIGINT；client EOF 不取消 attempt，只使该 observer transport 不再接收 progress/terminal。它不是 Runtime attempt failure，也不存在 preparation 专用 observer-timeout error code。

### 18.2 Progress、Result 与 Status

Progress phase：

```text
checkingDevice / queryingMountedImage / resolvingDeveloperSupport
waitingForAcquisitionSlot / waitingForSharedAcquisition
downloading / validating / extracting
personalizing / uploading / mounting
startingDeviceServices / probingServices / ready
```

`PreparationProgressV1`、`PreparationResultV1`、`PreparationStatusV1`和Runtime status中的acquisition summary精确字段只由TRD 05持有。本章只规定：progress <=8 KiB；owner byte progress <=4 Hz；cross-Runtime observer <=1 Hz；phase transition立即发送；result必须表达asset/mount/service disposition和`DeveloperSupportProvenance`；Runtime status最多投影8个group和4个asset acquisition，且只从Coordinator/AssetStore/Inhibitor当前state生成，不维护第二份owner state。

所有projection禁止URL、absolute path、UDID/ECID/nonce/ticket、完整hash和service payload。

### 18.3 Idle 与 generation retention

Runtime idle字段为`lastCLIActivityAt`。validated CLI CommandIntent和成功注册的CLI`runtime.prepareCapabilities`刷新；health/status/progress/completion/GUI activity不刷新。

`assetAcquisition`和`preparingCapability`进入统一ShutdownInhibitorRegistry。ready generation保留到detach、fatal、incompatible retire或Runtime quiesce，不因最后一个observer/command terminal消失立即teardown。

iOS 26的live capture存在一个额外但有界的generation provenance转换。`runtime.attachLive`之后、GUIHost尚未以当前`canonicalUDID + connectionEpoch + sourceID/sourceEpoch + geometryRevision`收到并接受首个bound AVFoundation frame之前创建的CoreDevice generation标记为`preCapture`；首个有效bound frame之后创建的generation标记为`postCapture`。GUIHost只能从同一live owner的正式bound session报告capture ready，preview、source名称、inventory顺序、分辨率或未确认帧都不能产生该事实。

当前connection epoch第一次从无有效bound capture进入capture ready时，Runtime若仍持有`preCapture` generation，必须安排一次`postCapture` replacement。转换遵守以下边界：

- 同一`connectionEpoch + liveOwnerID`最多完成一次；source refresh、短期pointer/keyboard Stream close或OneShot terminal不重置该状态。
- 已存在Stream或OneShot时不抢占、不自动重放；先完成其既有terminal/cleanup/fence，再在下一安全barrier退休旧generation。
- 没有active generation时只记录capture-ready provenance，下一次按需spawn直接成为`postCapture`，不先创建再替换。
- replacement失败产生typed preparation/control unavailable，video与placeholder生命周期继续独立；不得把失败的已提交命令自动重试到新generation。
- detach、fatal、incompatible retire或Runtime quiesce仍按原合同退休generation；新connection epoch重新计算provenance，但不复用旧capture、stream或executor epoch。

这项转换只修正当前OS/device上经实体证据确认的capture activation边界，不把任一AVFoundation source ID或Apple service行为声明为永久保证。

### 18.4 Detach、reconnect、reboot

```text
detach
  -> old PrepareObservers deviceDisconnected
  -> delete all epochBound demands
  -> device attempt stop/cleanup/fence
  -> old Helper/tunnel/service retire
  -> owned asset acquisition may continue

attach
  -> new connectionEpoch
  -> never replay old command/observer
  -> accept new explicit/start-only demand
  -> resulting demand queries mount and creates new generation

reboot / OS update / explicit external unmount
  -> re-query; remount from approved cache/source when demanded
```

### 18.5 Failure boundary

isolated capability failure：

```text
developerSupportUnavailable
developerImageCatalogMismatch
developerImageCatalogUnavailable
developerImageDownloadFailed
developerImageIntegrityFailed
developerImageCacheCapacityExceeded
matchingDDIUnavailable
developerImageCandidateIncompatible
personalizationServiceUnavailable
developerImageMountFailed
developerServicesUnavailable
preparationTimeout
```

`developerImageCatalogUnavailable` 表示首次 bootstrap 没有可用 catalog snapshot；
`matchingDDIUnavailable` 表示 classic exact/patch-to-minor 选择均缺失；
`developerImageCandidateIncompatible` 仅限底层明确、deterministic、pre-commit 的 default
candidate/BaseImage-build 不兼容。网络、暂时 TSS 故障或 committed mount 后的服务未 ready 必须保留
其原始错误，不能泛化为 candidate 不兼容。default candidate 失败不写负缓存，下一次显式 prepare
会重新尝试。上述错误终止 attempt/observer 并保持 Runtime coordinatorReady。USB detach 使用
`deviceDisconnected`。

target mismatch、Helper framing corruption、duplicate generation和无法cleanup/fence属于Runtime fatal fail-stop。
