# PulsePhone TRD 06 - 产品执行与 Client

> 文档状态：第一阶段规范章节
>
> 上级文档：[`pulsephone-trd.md`](../pulsephone-trd.md)
>
> 负责范围：第 25～28 节；完整 Command Matrix、输入实现、GUI 实现和 CLI 结果/取消/聚合合同。

本章是 PRD Product Action 到工程执行的主映射。通用 Scheduler/lifecycle 规则只引用 TRD 02；Developer Support 只引用 TRD 03；Wire 和 artifact 细节只引用 TRD 05、TRD 07，避免形成第二事实源。

## 25. Command Matrix

本节与 PRD 第 11 节共同构成第一阶段完整 Command Matrix。PRD 固定入口、成功边界、发布范围和证据；本节固定 executionShape、activation、availability、claims、candidate、deadline、owner/cleanup 和 logging。共享 Catalog、Planner、CLI help、GUI exposure 和测试 fixture 必须从这两节实现，不得从未注册来源补字段。

```text
matrixRevision=command-matrix.v17-20260822
Product Action rows       52
Supporting Action rows    21
non-command features       6
public CLI variants       44
GUI toolbar/window rows   14
owner-bound interactions   2
CLI argument definitions  16
```

### 25.0 Shared execution profiles

```text
P-L0 local-static
  Client local handler；RuntimeActivation=never；默认 absolute deadline=1 s。
  deadline/SIGINT 在副作用前取消为 known timeout/interrupted；已发生删除等副作用时保留 completed items。

P-L1 local-probe
  P-L0 + LocalDeviceFactsProbe；2 s work；异常额外 1 s terminate/reap。
  不取得 bootstrap.lock/runtime.lock，不等待或影响 Runtime/orphan generation。

P-C0 runtime-control
  不生成 RuntimeJobPlan，不进入 Scheduler，无 device ResourceClaim。
  read-only control 无 terminal 时为 known timeout/interrupted。
  mutating control 在 actor 内 committed 后 requester EOF 不回滚；terminal 未观察到时可为 outcomeUnknown。
  file mutation 使用 controlMutation；work deadline 后最多 2 s 进入稳定 opened/closed 状态，失败则 handoff cleanup/fencing并fail-stop。

P-C1 runtime-prepare-control
  public `device.prepare` 映射 `runtime.prepareCapabilities`。
  `device.prepare` 使用 `waitForTerminal`；Live preflight 可使用仅允许的 `startOnly`。外部request只携带target/action context/mode；Runtime派生target-default PreparationGroup。
  不创建 OneShotJob、不进入 CommandQueue/DeviceScheduler；注册 PrepareDemand，并仅在 `waitForTerminal` 时注册 PrepareObserver，随后加入共享 PreparationAttempt。
  attempt 的 device phase 以 internal preparation claimant 进入 Scheduler；host acquisition 不持有 device ResourceLease。
  explicit observer 无 Client budget，CLI 忽略 Ctrl-C；client EOF 只关闭观察通道，不取消其他 demand 或共享 acquisition。

P-O0 oneShot-capability-remediation
  RuntimeActivation=ensureRunning；Runtime authoritative planning。
  capability missing创建/加入 start-only preparation demand，立即以 `capabilityPreparing` remediation 终止；不进入PreparationWaitRegistry、不进入pending queue、没有accepted boundary或自动续跑。
  accepted 后 Client EOF 不取消；owner cancel只移除 pre-admission/waiter/pending，running不强停。
  running abort/deadline后 cleanup Ack grace=2 s；无 Ack则 fence generation并Runtime fail-stop。

P-S0 stream-realtime
  需要已有 live Runtime connection；Runtime authoritative StreamSessionPlan。
  capability loading、资源冲突或更早 conflicting waiter时 failFast；不进入 Gate/pending，不缓存重放。
  owner EOF/focus/window/watchdog/absolute max共用 cancelAndClean；2 s内无 release Ack则先 fence。

P-H0 client-hybrid
  Client 创建 rootActionID，编排现有 local/control/oneShot/stream child。
  compatible Runtime child使用 childActionID+parentActionID；Bootstrap v1 child只在Client本地按requestID关联。
  不存在 HybridJob/HybridPlan；Client形成唯一 aggregate result。
```

Logging profile：

```text
L0  无 per-UDID ActionLog，只进 Client DiagnosticLog/unified logging。
L1  仅向已经存在且兼容的 Runtime best-effort recordLocalAction；不冷启动、不 outbox。
L2  Runtime action.begin/action.terminal；ReplayTrace 记录脱敏语义调用和结果。
L3  只记录 Stream semantic begin/terminal/summary；禁止 frame、HID usage、pressed-set、文本。
L4  hybrid root/child linkage；root 与 child 各自 append-once。
```

所有 path 默认记录 `<redacted-path>`。`text.type` 只记录 `textRedacted=true` 和允许的 byte count；Text HID
命令只记录 allowlisted action、modifier 布尔值和 bounded count；Keyboard/Stream 不记录 payload。

规范表可在同一连续小节声明共享`Profile / Log` shorthand，但machine-readable CommandCatalog必须把解析后的`executionProfileID`和`loggingProfileID`写入每个Product Action row。不得让实现自行继承未在本章声明的默认值。Supporting Action使用本节明确的shape/caller/operation boundary，不自动获得独立Product logging identity。

Common deadline：

```text
clientWaitTimeoutV1                    60 s
local pure action                       1 s
self install absolute                 120 s
skill target transaction               5 s after app install
FactsProbe work                         2 s
FactsProbe abnormal terminate/reap      1 s
GUIHost OpenLive                        5 s
fast Runtime control                    5 s
controlMutation stabilization           2 s
bootstrap lock acquisition              5 s
runtimeStatus per target                2 s
runtimeStatus aggregate                10 s
log maintenance                        30 s
logs clear --all                       45 s
local artifact write after selection    5 s
verified generation exit wait          10 s
HelperHello                             2 s
```

Developer Support 使用 TRD 03 第 18 节的分阶段 deadline；不得恢复统一 10 秒 preparation deadline。

Preparation group：

```text
prep.coredevice.v2
  iOS 17+ 唯一 userspace tunnel/RSD/CoreDevice Helper generation。
  HID/button/keyboard/pasteboard/orientation/screenshot/app-control 是同一 generation facets。

prep.direct.lockdown.v1
  usbmux + classic Lockdown；autopair=false。

prep.legacy.developer.v2
  iOS 14～16 approved classic DDI/signature + legacy developer/DVT service。
  source 由 immutable catalog、受控 AssetStore、selected Xcode optimization 或 approved remote acquisition 决定。
  禁止 caller URL/path、上游隐式 auto_mount、写 Xcode 和 nearest-version guess；mount和目标service ready后才Complete。
```

每个 OneShot candidate 自动取得 `executor.<executorID>.oneshot-capacity-slot`；默认每 Helper outstanding OneShot=1。direct/legacy candidate 还取得同一个 exclusive `executor.direct.process-slot`。Stream 只取得 plan 明确声明的长期 channel/session claims。

Candidate cleanup：

```text
CoreDevice input
  active touch -> touch.cancel；button down -> matching up；keyboard/chord -> release-all。

CoreDevice control
  close request/service handle；screenshot temp必须unlink；迟到 callback按attempt token丢弃。

installation_proxy
  close AFC stream 和 service handle；不 rollback install/uninstall，不删除源 IPA。
  install/uninstall committed/unknown timeout或transport loss -> outcomeUnknown。
  read-only Browse关闭service handle；timeout、transport loss或非法response均为notCommitted known failure。

legacy developer
  close screenshotr/DVT service；DDI retirement由 generation controller 处理，单命令cleanup不擅自unmount。
```

### 25.1 Local Product Action

| commandID | Exposure | Profile / Log | Handler / activation | Deadline |
| --- | --- | --- | --- | ---: |
| `catalog.commands` | CLI `commands` | P-L0 / L0 | local static；never Runtime | 1 s |
| `product.version` | CLI `version` | P-L0 / L0 | bundled Info.plist version/build；never Runtime | 1 s |
| `self.install` | CLI `self install` | P-L0 / L0 | user-level local install transaction；never Runtime | 120 s |
| `skill.install` | CLI `skill install` | P-L0 / L0 | self install + bounded multi-target skill transaction；never Runtime | 120 s + 5 s |
| `skill.status` | CLI `skill status` | P-L0 / L0 | bounded local skill inspection；never Runtime | 5 s |
| `skill.uninstall` | CLI `skill uninstall` | P-L0 / L0 | bounded multi-target skill transaction；never Runtime | 5 s |
| `device.list` | CLI `devices` | P-L1 / L0 | facts enumerate；never Runtime | 2 s + abnormal reap |
| `device.info` | CLI | P-L1 / L1 | facts probe；stable facts | 2 s + abnormal reap |
| `device.status` | CLI `status` | P-L1 / L1 | facts probe；condition | 2 s + abnormal reap |
| `live.launch` | CLI `live [--select-source]` | P-L1 / L1 | facts target + GUIHost open(sourceSelectionPolicy) | 2 s + 5 s |
| `logs.prune` | CLI | P-L0 / L0 | local ActionLog maintenance | 30 s |
| `gui.keyboardCapture.toggle` | GUI | P-L0 / L1 | per-window local state | 1 s |
| `gui.previewAudioMute.toggle` | GUI | P-L0 / L1 | per-window AVFoundation output state；默认 Off，选中=Mac，未选中=Off | 1 s |
| `gui.cameraAuthorization.openSettings` | GUI | P-L0 / L1 | local System Settings action | 5 s |

### 25.2 Control Product Action

| commandID | Exposure | Profile / Log | Activation | Work deadline | Main predicate |
| --- | --- | --- | --- | ---: | --- |
| `trace.start` | CLI | P-C0 / L2 | ensureRunning | 5 s | no active trace |
| `trace.stop` | CLI | P-C0 / L2 | never cold-start | 5 s | active trace or noActiveTrace |
| `diagnostics.start` | CLI | P-C0 / L2 | ensureRunning | 5 s + 2 s stabilization | no active diagnostics |
| `diagnostics.stop` | CLI | P-C0 / L2 | existing compatible Runtime only | 5 s + 2 s stabilization | active or noActiveDiagnostics |
| `device.prepare` | CLI | P-C1 / L2 | ensureRunning | Runtime preparation terminal | Runtime-derived target group ready/alreadyReady或typed terminal |

### 25.3 OneShot input/navigation

以下均使用 P-O0/L2、`prep.coredevice.v2` 且无自动 retry。除 row 明确说明外无 fallback。

| commandID | Compatibility / availability | Claims | Candidate | Running deadline / terminal boundary |
| --- | --- | --- | --- | --- |
| `touch.tap` | iPhone USB iOS 17+；connected/trusted；input ready；geometry known | shared app-state, shared geometry, exclusive input.touch, core input-channel | `coredevice.normalTouch` | 5 s；down/up + cleanup Ack |
| `touch.drag` | same；NormalizedPointV1；CLI不推导edge | same as tap | `coredevice.normalTouch` + `gesture.linear.v1` | duration+5 s，max35 s；<=4096 frames/512KiB |
| `touch.swipe` | same；普通屏内swipe | same as tap | same linear planner/payload as drag | same；保留原commandID |
| `button.home` | iOS 17+；CoreDevice button ready | exclusive app-state, exclusive input.button, core input-channel | `coredevice.button.home` | 5 s；press/release |
| `button.appSwitcher` | iOS 17+；button ready | exclusive app-state, exclusive input.button, core input-channel | `coredevice.button.doubleHome` | 10 s；same-connection frozen sequence |
| `button.lock` | iOS 17+；button ready | exclusive app-state, exclusive input.button, core input-channel | `coredevice.button.lock` | 5 s；press/release |
| `button.volumeUp` | iOS 17+；button ready | shared app-state, exclusive input.button, core input-channel | `coredevice.button.volumeUp` | 5 s；press/release |
| `button.volumeDown` | same | same as volumeUp | `coredevice.button.volumeDown` | 5 s |
| `button.mute` | same；Device Mute | same as volumeUp | `coredevice.button.mute` | 5 s；不共享Preview Audio Mac/Off state |
| `device.rotate` | iOS 17+；orientation ready；current geometry known；CLI relative left/right，GUI clockwise right | shared app-state, exclusive geometry, exclusive orientation service | `coredevice.orientation.rotate`；每次一个 relative quarter-turn request | one request + short display-geometry confirmation window；返回requested/response/previous/current orientation、是否变化和visible confirmation；不得循环追逐绝对 landscape |
| `gui.softwareKeyboard.toggle` | iOS 17+；Indigo Consumer button ready | shared app-state, exclusive input.keyboard, core input-channel | `coredevice.softwareKeyboardToggle` | 5 s；Eject report + barrier；state unknown |
| `text.clear` | iOS 17+；keyboard ready；focused editor由调用方保证 | exclusive app-state, exclusive input.keyboard, core input-channel | `coredevice.keyboardMacro` | 5 s；select-all + Backspace + release barrier；不自动retry |
| `text.cursor` | iOS 17+；allowlisted move；count 1...100 | exclusive app-state, exclusive input.keyboard, core input-channel | `coredevice.keyboardMacro` | 5 s；bounded navigation macro + release barrier |
| `text.inputSource.next` | iOS 17+；keyboard ready | exclusive app-state, exclusive input.keyboard, core input-channel | `coredevice.keyboardMacro` | 5 s；Control+Space + release barrier |
| `text.key` | iOS 17+；allowlisted key/modifiers；repeat 1...100 | exclusive app-state, exclusive input.keyboard, core input-channel | `coredevice.keyboardMacro` | 5 s；bounded physical-key macro + release barrier |
| `text.type` | iOS 17+；pasteboard + keyboard ready；UTF-8<=64KiB | exclusive app-state, exclusive pasteboard, exclusive input.keyboard, core input-channel | `coredevice.pasteboardSetAndPaste` | 45 s；SET committed，paste+release barrier；不恢复旧pasteboard |

上述 CoreDevice candidate 同时取得 `exclusive executor.coredevice.input-channel` 或对应 executor capacity claim。

### 25.4 App lifecycle

以下均使用 P-O0/L2。install/uninstall 统一 classic Lockdown，不为 iOS 17+ 添加第二条 CoreDevice installation route。

| commandID | Compatibility / availability | Claims | Candidate / prep | Deadline / terminal boundary |
| --- | --- | --- | --- | --- |
| `app.install` | iPhone USB iOS 14+；connected/trusted；installation service；`.ipa` | shared app-state, exclusive app.management, exclusive service.installation | `direct.installationProxy.install` / direct.lockdown | 30 min；backend Complete；bounded AFC <=1MiB；不rollback/launch |
| `app.uninstall` | iOS 14+；installation service | shared app-state, exclusive app.management/installation/app.lifecycle:{bundleID} | `direct.installationProxy.uninstall` / direct.lockdown | 5 min；backend Complete；不rollback |
| `app.launch` | iOS 17+ CoreDevice AppService；iOS 14～16 approved classic DDI+DVT | shared app-state, exclusive app.management/app.lifecycle:{bundleID} | OS-disjoint `coredevice.appLaunch` 或 `legacy.dvtLaunch` | 60 s；request complete；不保证持续前台 |
| `app.list` | iPhone USB iOS 14+；connected/trusted；installation service | shared app-state, exclusive service.installation | `direct.installationProxy.browse` / direct.lockdown | 30 s；明确 Complete；完整稳定排序结果或 known failure |

install/uninstall/launch 两两串行，但 shared app-state 允许与不冲突的 pointer、keyboard、screenshot 并发。DirectHelper process slot 和更早 waiter 仍可限制实际并发。

`app.install` 的 production Runtime在planning前对规范化execution-time `ipaPath`执行no-follow普通文件preflight；失败返回`invalidIPAPath`且不启动Helper。backend payload固定为`operation=install`和通过preflight的路径；Helper payload、日志和terminal不得回显该路径。DirectHelper必须再次以no-follow方式打开同一路径并验证为非空普通文件，以有界ZIP/Info.plist读取确认单一`Payload/*.app`和合法`CFBundleIdentifier`，不得先把整份IPA读入内存。Helper侧文件竞态、无效归档或bundle metadata返回`invalidIPA/notCommitted`。

DirectHelper在同一target-bound Lockdown lease中打开 AFC 和 InstallationProxy。IPA上传到本次request唯一的 `/PublicStaging/PulsePhone` remote file，每次host read和AFC write均不得超过1 MiB；AFC handle关闭后才提交一次 InstallationProxy `Install`，只有backend `Status=Complete`才返回 `bundleID + disposition=installed`。remote staging file、AFC、InstallationProxy和Lockdown lease必须在terminal前best-effort清理；不删除或改写host源IPA，不自动launch，不rollback已提交安装。Install request提交前的service/upload失败返回`installFailed/notCommitted`；提交后明确backend拒绝返回`installFailed/committed`；提交后transport loss或30分钟absolute deadline耗尽返回`outcomeUnknown/unknown`。Client、Runtime和Helper不得用通用60秒socket/helper等待提前截断该30分钟deadline。

HelperWire `Result` 的允许错误集合必须包含 `invalidIPA`、`installFailed` 和 `outcomeUnknown`。前两者携带符合 `backendStage.v1` 的details；未知结果只使用 `outcomeUnknown` 并携带 `unknownOutcome.v1(reason=commitStateUnknown)`，不得把原始异常、IPA路径或backend自由文本跨进程返回。

`app.list` 的 Runtime backend payload 精确为 `{operation:"browse"}`，caller 不能提供 filter、attribute、bundle ID 或 page 参数。Runtime 选择 DirectHelper 并显式执行 30 秒 running absolute deadline；普通 60 秒 Client wait、DirectHelper 默认 input timeout 或 install 的 30 分钟 deadline均不得替代该限制。命令复用 P-O0 的 preparation wait、pending queue、64 pending cap、`continueAfterClientEOF` 和 `automaticRetry=never`；它不取得 `device.app-management`，但 exclusive `service.installation` 使 Browse 与 install/uninstall及其他 Browse 串行。DirectHelper process slot仍可与其他direct/legacy work形成实际串行。

DirectHelper 在 target-bound Lockdown lease中发送 InstallationProxy `Browse`，`ClientOptions.ApplicationType=Any`，`ReturnAttributes` 精确为 `CFBundleIdentifier`、`CFBundleDisplayName`、`CFBundleName`、`CFBundleShortVersionString`、`ApplicationType`、`CFBundlePackageType`、`SBAppTags`。实现必须自有流式 page loop，不能调用会无界聚合且接受空response结束的 convenience Browse：每个 length-prefixed plist先检查长度再分配，单个原始 plist上限1 MiB；每个response必须为dictionary，非terminal response必须含array `CurrentList`，只有显式字符串`Status=Complete`成功。terminal page可含最后一批`CurrentList`；空response、EOF、backend error、malformed page或缺少Complete均fail closed。

记录处理顺序固定为：先验证dictionary及非空、最多255 UTF-8 bytes且全Browse唯一的字符串 bundle identifier；该值是 InstallationProxy opaque事实，不要求reverse-DNS形态。再验证`CFBundlePackageType` shape并只保留精确`APPL`；只对`APPL`验证`SBAppTags`缺失或纯字符串数组，含精确小写`hidden`时排除；最后才验证并投影保留记录的名称、short version和application type。display name优先非空`CFBundleDisplayName`，再回退非空`CFBundleName`；version只取非空`CFBundleShortVersionString`；两者缺失/空时省略。`User/System`映射`user/system`，缺失或其他字符串映射`unknown`。这些字段存在但类型错误时整体失败；不得透传任何其他metadata。

`appListResult.v1`顶层只有`apps`和恒为false的`truncated`；item只有required `bundleID`、required `applicationType`及optional `displayName`/`version`，两层均`additionalProperties=false`。结果按bundle ID UTF-8 bytes稳定升序，normalized encoded result上限256 KiB，不设置App/page/record数量或名称/版本的额外产品上限；超限整体失败，不截断、不返回已收集记录。backend拒绝、协议/字段/Complete/上限错误使用`backendFailed/notCommitted`，30秒deadline使用`executionTimeout/notCommitted`和`stage=browseDeadline`，transport中断使用`transportFailure/notCommitted`；不得返回`outcomeUnknown`。允许backend stage仅为`helperStartup`、`serviceOpen`、`browseSend`、`browseReceive`、`browseValidate`、`resultNormalize`和dispatcher兜底`directDispatcher`。日志只允许计数、类型分布、完整性、耗时、失败stage/error code/limit类型，不记录App名称、bundle ID、版本、partial list、原始metadata或exception。

### 25.5 Stream

以下均使用 P-S0/L3 和 `prep.coredevice.v2`。

| commandID | Availability / frame schema | Claims / route | Buffer, watchdog and terminal |
| --- | --- | --- | --- |
| `gui.pointer.interaction` | live attached；iOS17+ input ready；geometry known；begin(seq0,point,edge,revision), move, end/cancel | shared app-state/geometry, exclusive input.touch, core input-channel；edge none=normal HID；validated edge=Indigo | opening begin+latestMove?+end?；ordered64/256KiB；latest move1；Ack watchdog1s；absolute30s；geometry/owner loss touch.cancel；cleanup/fence2s |
| `gui.keyboard.interaction` | live attached；Input Monitoring/EventTap；iOS17+ keyboard ready；complete pressed-set ordered | shared app-state, exclusive input.keyboard, core input-channel；virtual HID keyboard | Client opening32；Runtime ordered64/256KiB；Ack watchdog1s；all released+300ms close；absolute5min；focus/owner loss release-all；cleanup/fence2s |

两个 Stream 都 fail fast；backend open 2 秒；oldest FrameAccepted watchdog 1 秒；cleanup/fence 2 秒。

### 25.6 Hybrid

| commandID | Exposure | Profile / Log | Ordered orchestration | Aggregate deadline |
| --- | --- | --- | --- | ---: |
| `runtime.status.global` | CLI | P-H0 / L0 | discover sockets + full/lite status, max256/fanout8 | 10 s |
| `runtime.status.device` | CLI explicit UDID | P-H0 / L0 | lock classification + full/lite status + preparation projection | 2 s |
| `runtime.stop` | CLI | P-H0 / L4 | bootstrap lock + stop/retire/recovery + generation exit | normal max 20 s；orphan calibrated |
| `logs.clear.device` | CLI | P-H0 / L4 | Runtime coordinated writer or local closed files | 30 s + stabilization |
| `logs.clear.all` | CLI | P-H0 / L4 | snapshot max256/fanout8, per-target primitive | 45 s |
| `element.snapshot` | CLI | P-H0 / L4 | Runtime current-frame capture + parallel analysis；Client optional atomic PNG write | analyzer whole 10 s；Client wait 60 s；local write 5 s |
| `screenshot.cli` | CLI | P-H0 / L4 | device screenshot child + local atomic write | child 30 s; Client wait 60 s; local 5 s |
| `screenshot.gui` | GUI | P-H0 / L4 | Save Panel + preview local or device child | no whole deadline; local 5 s/child 30 s |
| `live.close` | GUI | P-H0 / L4 | media stop + Stream cleanup + detach + close | GUI wait <=5 s |

`runtime.status.device` lock classification：

```text
socket absent + runtime.lock free
  -> notRunning

socket absent + runtime.lock busy + verified Runtime alive
  -> generationBusy(reason=runtimeExiting, waitAvailable=true, recoveryAvailable=false)

socket absent + runtime.lock busy + Runtime gone + verified helpers
  -> generationBusy(reason=orphanHelpers, waitAvailable=false, recoveryAvailable=true)

socket absent + runtime.lock busy + identity cannot be verified
  -> generationBusy(reason=identityUnknown, waitAvailable=false, recoveryAvailable=false)
```

status 本身不等待、不 signal、不 kill、不 recover。compatible socket 使用 full control；incompatible socket 使用 Bootstrap lite并校验 returned canonicalUDID/H。

### 25.7 Supporting Action

| Supporting Action | Shape / caller | Activation and boundary |
| --- | --- | --- |
| `LocalDeviceFactsProbe.enumerate` | local / device.list,target selection | 2 s work + abnormal 1 s reap；strict allowlist |
| `LocalDeviceFactsProbe.probe` | local / device.info,status,preflight | same；re-enumerate selected identity |
| `guiHost.openLive` | local / live.launch | per-app-path target reserve + Source Resolver/Chooser；5 s；rollback reservation on failure；首次 handoff 前不启动 target Runtime |
| `runtime.health` | control / bootstrap | existing compatible Runtime；2 s；no ActionLog |
| `runtime.getAvailabilitySnapshot` | control / GUI | existing Runtime；2 s；full bounded snapshot on revision gap |
| `runtime.runtimeStatus` | control / status | existing Runtime；2 s；never enters device queue |
| `runtime.prepareCapabilities` | preparation control / explicit device.prepare 或 live preflight | ensureRunning；`waitForTerminal` 注册observer并观察shared terminal，`startOnly` 仅启动/加入attempt后返回；不进入CommandQueue |
| `runtime.attachLive` | control / live window | ensureRunning；5 s attach after generation barrier；acquire live token/subscription |
| `runtime.markLiveCaptureReady` | internal control / bound live video | existing attached live connection；校验owner/subscription/connection/capture activation；完成或defer一次性post-capture generation replacement；5 s |
| `runtime.detachLive` | control / close/EOF | existing only；idempotent；Stream cleanup before token release；5 s |
| `runtime.stopIfIdle` | control / stop | existing Runtime；5 s Ack；atomic quiesce or typed blockers |
| `runtime.recordLocalAction` | one-way control / L1,L4 | existing compatible connection only；drop on saturation/disconnect；no cold start/outbox |
| `runtime.cancelOwnedPendingWork` | control / timeout,SIGINT | one targetRequestID；同一clientInstanceID owner-only；Element active capture/analysis/annotation 可请求取消，其他不支持的running OneShot不强制取消 |
| `runtime.startReplayTrace` | control / trace.start | reserve traceStarting + trace inhibitor before file I/O；5 s |
| `runtime.stopReplayTrace` | control / trace.stop | footer/flush/close before token release；5 s |
| `runtime.startDiagnostics` | control / diagnostics.start | controlMutation around create/header；5 s + stabilization |
| `runtime.stopDiagnostics` | control / diagnostics.stop | flush/close；5 s + stabilization；shutdown finalize bounded |
| `runtime.clearActionLogs` | control / logs.clear | rotate/close/delete/reopen under controlMutation；30 s + stabilization |
| `device.screenshot` | OneShot child / CLI,GUI fallback | shared app-state + exclusive screenshot service；CoreDevice iOS17+ or conditional legacy screenshotr；30 s；PNG FD |
| `BootstrapControlV1.probeRuntimeLite` | bootstrap control / runtime status | incompatible Runtime；2 s；mandatory canonicalUDID/compatibility tuple check |
| `BootstrapControlV1.stopReplayTraceAndFinalize` | bootstrap control / trace.stop | incompatible Runtime；5 s；same path/traceID |
| `BootstrapControlV1.retireIfIdle` | bootstrap control / stop | incompatible Runtime；5 s Ack；same shutdown predicate, no force |

Supporting Action 不进入公开 `commands` 列表。

`runtime.attachLive`只在已经通过 CLI preflight 的窗口创建后取得 live token/subscription；它不创建 preparation demand。`runtime.detachLive`只在owned Stream terminal/fence barrier后释放live token。

任何finite command的权威CandidatePlan声明required capability且当前未ready时，Runtime创建`epochBound` start-only demand并加入/启动共享attempt，然后立即返回`capabilityPreparing`。details 必须以 `capability.v1` 表达 group、state=`preparingDevice`、reason=`runDevicePrepare` 与 remediation=`runDevicePrepare`；human output 必须包含 `Developer support preparation is in progress. Run PulsePhone device prepare to follow progress.`。该路径没有 Scheduler admission、re-plan、原命令执行或自动 retry。Stream在capability未ready时固定fail fast。

attachLive 只取得 live shutdown inhibitor 和 observation subscription，不持有覆盖 live 生命周期的 `device.app-state` 或其他 DeviceScheduler ResourceLease。真正的 pointer/keyboard interaction 在各自 Stream open 时取得 lease，因此 live 窗口存在不构成全局命令排他。

物理USB reconnect不等同于`runtime.detachLive`。Runtime保留live inhibitor、
`liveOwnerID`和`subscriptionID`；GUI RuntimeClient保持同一socket的单一reader，并按
TRD 05 §21消费`deviceDisconnected`/`availabilityInvalidated`。Detach时Client立即使
旧LiveAttachment的control authority和capture activation失效、清除geometry/overlay；
attach侧完整availability snapshot返回strictly newer connectionEpoch后，Client以同一
owner/subscription原子替换`connectionEpoch + stateRevision`。不得再次调用
`runtime.attachLive`抢占自己、不得在旧attachment上接受新capture activation，也不得
自动重放断连前已经terminal或unknown的命令。

正式live的capture/generation启动状态机固定为：

```text
OpenLive -> target reservation + Source Resolver
  -> cache/auto/Chooser produces proved source handoff
  -> create formal Live placeholder + runtime.attachLive
  -> Runtime may hold or create preCapture generation
  -> bind proved source and run video capture independently
  -> first accepted bound AVFoundation sample for current target/epochs
  -> GUIHost asynchronously runtime.markLiveCaptureReady
  -> no active generation: record postCapture readiness
  -> idle preCapture generation: bounded retire + spawn postCapture generation
  -> busy preCapture generation: mark deferred; transition at next safe barrier
  -> refresh availability and enable affected controls only from terminal result
```

GUIHost不得在AVFoundation frame callback、AppKit main thread或display enqueue路径同步等待replacement。transition期间video继续显示；affected toolbar/pointer/keyboard状态投影为loading或typed unavailable，不允许用户动作先失败一次再靠第二次成功。首次 Resolver/Chooser 没有 proved source handoff 时不得启动 target Runtime；已有正式 Live 的 Change Source 则保留现有 Runtime/control 路径。不得选择未确认source只为授权HID。Runtime不自动重放在capture-ready之前已经terminal的命令。

pointer/keyboard每段短期interaction仍分别open/close StreamSession；这些close不退休post-capture generation。相同connection epoch中button、pointer和keyboard共享完成转换后的generation。只有detach、fatal、incompatible retire、Runtime quiesce或§18.3定义的一次性preCapture转换可以替换generation。

### 25.8 Release gate scope

Product-scope action：

```text
catalog.commands / device.list / device.info / device.status / live.launch / logs.prune
device.prepare
touch.tap / touch.drag / touch.swipe / gui.pointer.interaction
runtime.status.global / runtime.status.device / runtime.stop
logs.clear.device / logs.clear.all / live.close
```

其余公开 input/button/app/screenshot/trace/diagnostics/audio/keyboard action 默认是 capability scope，但只有能够从 Catalog、exposure、文档和测试中精确完全移除时才允许局部降级。Supporting Action 同时支撑 product row 时，其 shared failure 继承 product scope。

Supporting release inheritance：

```text
S-P product:
  LocalDeviceFactsProbe.enumerate / probe
  guiHost.openLive
  runtime.health / getAvailabilitySnapshot / runtimeStatus
  runtime.prepareCapabilities
  runtime.attachLive / detachLive / stopIfIdle
  runtime.markLiveCaptureReady
  runtime.recordLocalAction / cancelOwnedPendingWork / clearActionLogs
  BootstrapControlV1.probeRuntimeLite / retireIfIdle

S-C capability:
  runtime.startReplayTrace / stopReplayTrace
  BootstrapControlV1.stopReplayTraceAndFinalize
  runtime.startDiagnostics / stopDiagnostics
  device.screenshot
```

S-C 只有在全部可达 parent exposure 和 releasedCapability 同时撤销、共享 Runtime/IPC 不受影响时才允许降级。

`element.snapshot` 复用 `command.submit` 作为 hybrid root 的 Runtime work request；默认 JSON
Response 不携带 FD，`annotated|both` 才携带一个由 TRD 07 管理的 annotation PNG FD。完整
SnapshotFrame、analyzer、fusion 和 result 语义由 TRD 09 持有。

非 command feature：

```text
product:
  live.targetBindingSafety
  live.identityPlaceholderBlindControl

capability:
  live.videoPreview
  live.audioPreview
  live.inputObservationOverlay
  developerSupport.transparentPreparation
```

### 25.9 排除入口

不得实现或暴露：

```text
keyboard enable / keyboard disable
Hardware Keyboard toggle
Software Keyboard show/hide/state/checked API
Clipboard Sync
video record start/stop
live --debug-device-picker
orientation get/set
stop --force
.app install
GUI launch / GUI uninstall
Touch status toolbar item
```

## 26. 输入实现

### 26.1 CLI gesture planning

参数：

```text
NormalizedPointV1 = <x>,<y>
x/y finite ASCII decimal in [0,1]; trailing zeros are accepted and removed during normalization
(`0.40` -> `0.4`, `1.0` -> `1`); signs, whitespace, exponent notation, NaN and Infinity are rejected
durationMs integer 1...30000
```

generated plan：

```text
frames <= 4096 including begin/end
encoded Helper payload <= 512 KiB
```

超限在 admission 前返回 `argumentTooLarge` 或 `planTooLarge`。

CLI和GUI的point都属于visual normalized space：当前显示方向的左上为`0,0`、右下为`1,1`。planner保持canonical decimal，不提前猜测framebuffer或HID方向。Production Runtime在最后一个device-I/O trust boundary读取current geometry，并对每个point执行唯一一次exact-rational projection：

| current orientation | visual `(x,y)` -> canonical portrait digitizer `(u,v)` |
| --- | --- |
| `portrait` | `(x,y)` |
| `landscapeRight` | `(y,1-x)` |
| `portraitUpsideDown` | `(1-x,1-y)` |
| `landscapeLeft` | `(1-y,x)` |

先在normalized rational domain完成交换/补数，再用既有half-up规则映射各轴到`0...65535`；不得先round再做`65535-value`，否则中点会产生不一致off-by-one。HelperWire只携带projected integer coordinate和projected edge，不携带第二套orientation authority，Helper不得再次旋转。

Production Runtime current geometry必须包含`connectionEpoch + geometryRevision + logicalWidth + logicalHeight + orientation`。GUI `StreamOpen`提交五者并由Runtime与current device snapshot核对；public CLI coordinate command在自身admission内刷新/取得current geometry，不能依赖先前GUI interaction。这里的current device snapshot是Runtime在current connection epoch内维护、并由attach/reconnect、display observation、presentation convergence和rotate terminal推进的权威快照；当该快照身份完整且没有stale/conflict信号时，GUI每个短期pointer StreamOpen不得强制再执行同步设备display-geometry OneShot。只有快照缺失、stale、冲突或权威事件表明geometry已变化时才刷新。missing/stale/conflicting orientation、wrong epoch/revision、presentation/geometry未收敛或active interaction期间geometry变化均在任何Helper frame前fail closed；后者先发送cancel/release并清除overlay。

Reconnect后CLI坐标命令与GUI恢复相互独立：每个新CLI process从Runtime current
availability和current epoch的权威geometry完成admission，只能路由到new epoch的新
Helper generation。GUI视频source恢复不能作为Runtime control恢复证明，CLI成功也不能
授权GUI复用旧LiveAttachment；两条路径只在current connection/source/geometry/
capture activation全部匹配时收敛。

若mismatch refresh确认requester与权威snapshot的connection epoch、logical size和orientation exact一致，Runtime保留或推进自己的monotonic geometry revision，并在pointer StreamOpen结果中返回实际注册到projection owner的完整accepted geometry。GUI只可在该Stream任何Frame尚未发送时接受不旧于requester的revision，并原子重绑定controller和队列中全部尚未投递的自然gesture；任一queued frame assertion不一致、foreign epoch、物理geometry冲突、较旧revision或已投递interaction都必须cancel/fail closed。每个Frame仍要求exact accepted epoch/revision，不得改成只比较尺寸或方向。

### 26.2 GUI pointer

```text
mouseDown inside visibleImageRect or 28 pt edge slop
  -> clamp
  -> 18 pt edge snap/classification
  -> open Stream
  -> seq=0 begin

mouseDragged
  -> latest-wins move

mouseUp
  -> ordered end

owner/window/geometry/watchdog loss
  -> touch.cancel + cleanup
```

每个自然gesture仍是独立逻辑StreamSession，opening buffer、claims、identity、ordered frame、latest-wins move、watchdog和terminal合同不变。稳定live会话中的Stream admission必须复用current post-capture Helper generation、generation-scoped Universal/Indigo service和上述权威geometry snapshot；不得把Helper/tunnel重建、input-service初始化或无条件display query放在每次mouseDown后的首触关键路径。

GUI在AppKit接受mouseDown时记录首触起点，分别记录StreamOpen完成、begin FrameAccepted、实体设备响应和Live画面反映结果。既有`touchDeliveryLatencyMs`只覆盖Client StreamFrame submit之后的投递，不得替代该分层首触诊断。正常warm路径不得存在固定秒级等待；是否冻结正式阈值必须以实体设备与Player Demo同机基线为依据，不能把2秒backend-open deadline或1秒FrameAccepted watchdog误当作期望延迟。

open/send/close/cancel失败必须保留typed stage并回到可再次开始gesture的有界状态。optimistic overlay不构成backend或设备成功证据；不得使用`try?`或等价路径把失败转换为永久closing、静默丢帧或无reason的无响应。

edge classification只在visual canvas begin时发生。edge=`none`的tap/drag/pointer使用generation-scoped Universal HID `mainTouchscreen`；明确edge使用Indigo digitizer。edge point按上表投影，visual edge label也投影到canonical portrait edge：

| orientation | visual top/right/bottom/left -> canonical edge |
| --- | --- |
| `portrait` | top/right/bottom/left |
| `landscapeRight` | left/top/right/bottom |
| `portraitUpsideDown` | bottom/left/top/right |
| `landscapeLeft` | right/bottom/left/top |

Runtime是point和edge projection唯一owner；Helper只编码projected Universal/Indigo event。GUI与CLI不得各自维护transform table，capture dimensions、列表顺序、source名称或默认`.landscapeRight`均不是input orientation proof。

### 26.3 Keyboard Capture

每窗口 local state：

```text
keyboardCaptureEnabled default=false
keyboardCaptureActive = enabled && keyWindow && firstResponder
                        && EventTapAvailable && runtimeCapabilityReady
```

active 时安装 session-level CGEventTap，完整消费 keyDown/keyUp/flagsChanged。Event Tap callback 只更新本地 pressed set 并有界入队，不能同步等待 Runtime。

opening 期间最多 32 个完整 pressed-set snapshot。全部 frame ordered，从 seq=0 flush。overflow/open failure/focus loss/Event Tap disable 必须 fail closed、清空 pressed set并 release-all。

全部 key released 后 300 ms 关闭短期 interaction，不关闭 enabled preference。

Keyboard Capture、`text.type` 与 Text HID 命令通过 `_ensure_keyboard_service` 只创建和复用本 Helper
generation 自有的同一个 Universal HID keyboard service，不枚举或接管外部 service。首次实际输入可创建
service 并接受 iOS 软件键盘被系统收起。新建 Ack 后必须完成一次 1 秒 readiness 才能返回 service；取消
或失败保留该 service 的 settling 状态，下一请求继续等待，ready 后复用路径不再等待。Capture 关闭只做
release-all 和 interaction 清理，不删除 service。
`gui.softwareKeyboard.toggle` 不读取或改变 Capture enabled/active，也不负责创建 Universal HID keyboard
service；这些能力只通过 exclusive `input.keyboard` claim 防止事件交错。

### 26.4 type --text

`text.type` 作为单一 OneShot，UTF-8 最大 64 KiB。candidate 固定为：

```text
ensure generation-scoped PulsePhone-owned keyboard service
  -> if newly created: wait 1 s service readiness
  -> device general pasteboard SET        # committed boundary
  -> close SET session
  -> independent PULL session exact read-back
  -> Command-only pressed set
  -> 20 ms modifier settle
  -> Command+V pressed set
  -> 80 ms V hold
  -> release-all barrier
```

PulsePhone 不访问 Mac pasteboard、不启动 Clipboard Sync、不恢复设备原 pasteboard；read-back不一致时返回
`backendFailed(stage=pasteboardReadBack)`且不得发送chord。不做 ASCII fallback，不观察或自动处理系统粘贴弹框，不自动重试。SET 后明确
paste失败是committed known failure，terminal不明是`outcomeUnknown`。成功disposition为
`pasteDispatched`，只证明SET精确回读、Command+V与release barrier完成，不声明App已经显示文本。
上述20 ms/80 ms只属于`text.type`的staged paste chord，用于保证设备形成完整且可鉴权的
`Command+V`；不得把它改成通用Text HID宏的全局等待。除新建keyboard service后的固定1秒readiness外，
不得在chord之外增加依赖文本内容、目标App、截图、OCR、AX扫描或权限弹框的等待。

### 26.5 Text HID 与编辑命令

`text.key`、`text.cursor`、`text.clear` 和 `text.inputSource.next` 均投影到单一
`coredevice.keyboardMacro` OneShot。Runtime 只向 Helper 发送经过 argument schema 规范化的语义动作；Helper
不得接受 raw HID usage、任意长度 frame 数组或跨 CLI 进程的 key-down/key-up 状态。

命名 key allowlist 固定为 `a...z`、`0...9`、`return/escape/backspace/tab/space/minus/equal/
left-bracket/right-bracket/backslash/semicolon/quote/grave/comma/period/slash/caps-lock/delete-forward/
home/end/page-up/page-down/left/right/up/down`。modifier 固定为左侧 Control、Shift、Option、Command。
`repeat/count` 默认 1、最大 100；每次重复都是完整 pressed-set 后 release，不跨重复持键。

`text.cursor` 映射固定为 Arrow、Option+Left/Right、Command+Left/Right、Command+Up/Down；selection 在对应
宏增加 Shift。`text.clear` 固定为 `Command+A -> release -> Backspace -> release-all`，禁止自动重试。
`text.inputSource.next` 固定为 `Control+Space -> release-all`，不使用 Command+Space fallback，也不提供输入源
query 或绝对选择。

Helper 在一个请求内完成全部宏、release-all 和 cleanup barrier。第一个非空 pressed-set 是副作用提交点；
提交后 transport/timeout/cleanup terminal 不明确返回 `outcomeUnknown`，不自动重放。成功 disposition 分别为
`keyDispatched`、`cursorMoveDispatched`、`clearDispatched` 和 `inputSourceCycleDispatched`，只表示宏已派发，
不表示 App 的最终字符、光标、选区、文本或输入法状态。

### 26.6 Toggle Software Keyboard

`gui.softwareKeyboard.toggle` 是无checked state的GUI OneShot。Helper通过generation-scoped Indigo service
发送一次Consumer page `0x0C`、Eject usage `0xB8` report及barrier。动作不查询、不缓存、不推测软件键盘
当前可见状态；无输入焦点时允许report成功但没有可见变化。成功只表示report和barrier完成。

该动作不启用、关闭或读取Keyboard Capture，不创建或删除Universal HID keyboard service。只有与
正在执行的`text.type`、Text HID命令或Keyboard Capture短期interaction争用exclusive `input.keyboard`时
返回`resourceBusy`，不排队、不交错；Capture仅enabled/active但没有未结束interaction时不持有该资源。

### 26.7 button 与 rotate mapping

```text
home        page=0x0C code=0x40 hold=50 ms
lock        page=0x0C code=0x30 hold=500 ms
volume-up   page=0x0C code=0xE9 hold=50 ms
volume-down page=0x0C code=0xEA hold=50 ms
mute        page=0x0C code=0xE2 hold=50 ms
```

App Switcher：同一 Indigo connection 内：

```text
Home down -> 35 ms -> up -> 120 ms gap -> Home down -> 35 ms -> up
```

duration/mapping 修改必须更新 Catalog fixture 和 plannerContractVersion，不能只改 Helper magic number。

Rotate 使用相对方向，不使用绝对orientation setter：

```text
CLI --direction right   -> one clockwise quarter-turn request
CLI --direction left    -> one counterclockwise quarter-turn request
GUI Rotate Right 90°    -> one clockwise quarter-turn request
```

每个`device.rotate` Product Action最多向orientation service提交一次relative rotate request。Helper不得循环调用`right`直到`landscapeRight`，也不得循环调用`left`直到`landscapeLeft`。iOS、设备形态和前台App可以接受、跳过或拒绝`portraitUpsideDown`；Runtime以actual primary display geometry作为可见方向和坐标authority。CoreDevice rotate response只能说明本次relative request已被处理，不能单独证明可见display已采用该方向。

Rotate response返回后，Helper执行短窗口display-geometry confirmation：立即调用一次`get_display_info()`；若actual display orientation未匹配response orientation，则等待`100 ms`后第二次查询；仍未匹配则等待`150 ms`后第三次查询并结束。实现可用命名常量表达次数和延迟，但不得恢复秒级等待或后台追逐。结果必须包含`requestedDirection`、`rotateResponseOrientation`、`previousDisplayOrientation`、`currentDisplayOrientation`、`displayOrientationChanged`和`visibleOrientationConfirmed`。只有`currentDisplayOrientation == rotateResponseOrientation`且相对previous发生变化时，`visibleOrientationConfirmed`才为true；否则terminal仍返回最新actual display geometry事实，GUI/CLI应表达当前方向与是否变化。response-only orientation不得写入Runtime/GUI geometry authority。

短窗口耗尽后，如果actual display未采用response方向，Runtime必须用最新actual display geometry恢复或保持coordinate authority；若actual display后来在coordinate admission、capture-ready receipt或Live presentation convergence中变化，仍按§26.1和§27.1的actual geometry fence推进。unsupported upside-down不得导致Runtime geometry永久为nil，也不得开放使用response-only geometry的pointer/touch。

## 27. GUI 实现

### 27.1 Video binding safety

#### 27.1.1 Identity、presentation 与 interaction authority

真实 sample 的 source identity 必须匹配：

```text
canonicalUDID
connectionEpoch
sourceID
sourceEpoch
mappingProof lineage
```

同一 live session 另有三个独立状态：

```text
SamplePresentationFormat
  presentationWidth / presentationHeight
  orientation
  normalizedShape = shortEdge / longEdge
  formatRevision                 # session-local, starts at 1

InteractionGeometry
  connectionEpoch / geometryRevision
  logicalWidth / logicalHeight / orientation

LiveWindowState
  windowed | enteringFullscreen | fullscreen | exitingFullscreen
  preferredWindowedCanvasLongEdge
  lastWindowedReservation

VideoAvailability
  live(current binding + presentation authority)
  frozen(last displayed frame; no current video authority)
  unavailable(no retained frame)

PointerAvailability
  available(current Runtime attachment + geometry + admission authority)
  preparing(current attachment exists; admission authority pending)
  unavailable(no current coordinate authority)
```

错误source、stale sourceEpoch、stale connectionEpoch、foreign mapping proof或已停止session的sample在enqueue前丢弃。`sourceEpoch`的代际比较只在同一sourceID/current binding内成立，不同sourceID的数值不可排序。`frozen`保留的旧presentation不具有current source authority；新bound session的callback通过exact binding token、sourceID/sourceEpoch和connection identity fence后，其首个committed presentation直接替换旧presentation，不受跨sourceID epoch数值大小影响。identity-valid sample的dimensions变化不属于identity failure；同一sourceID/sourceEpoch下不得仅因format变化停止capture、清除mapping或分配新sourceEpoch。`formatRevision`只描述当前capture session的presentation演进，不持久化、不进入mapping proof，也不能替代geometryRevision。

identity-valid sample在presentation候选确认期间继续enqueue到`AVSampleBufferDisplayLayer`。presentation与interaction geometry暂未收敛时，display继续更新，pointer frame和依赖坐标的screenshot preview保持fail closed；非坐标Runtime control继续独立可用。`VideoAvailability`与`PointerAvailability`分别由各自authority推进，不允许从另一个状态或Helper PID派生。未绑定且无可保留帧时丢弃真实帧，显示 device name + UDID identity placeholder。Camera authorization只影响video，不影响Runtime/control。

`frozen`中的frame和last committed presentation ratio只是同一target窗口的视觉连续性数据：它们不能建立或延长mapping proof、capture activation、source epoch、connection epoch、interaction geometry、screenshot preview或设备当前内容证明。pointer可以在`frozen/unavailable`视频上独立成为`available`，但只使用current Runtime geometry与current stream admission回执；浮层必须持续说明画面不是实时内容。

#### 27.1.2 Mapping 与启动状态机

占位画布优先使用current `InteractionGeometry`；初次geometry未到达时使用trusted mapping中all-or-none、portrait-normalized的`initialCanvasWidth/initialCanvasHeight`比例，尺寸缺失或invalid时使用9:16。cache尺寸和capture discovery `activeFormat`都只能在首个identity-valid sample之前作为临时reservation hint，不能覆盖已提交presentation、建立target proof、证明当前方向或成为interaction authority。窗口不得超出current screen visible frame。

AVFoundation sourceID由`pulsephone.av-source.v1`域分离SHA-256从进程内raw `AVCaptureDevice.uniqueID`生成。raw uniqueID不得离开catalog或进入持久化文件。sourceID在同一Mac/同一source上通常稳定，但只作为可失效trust anchor，不是Apple永久设备身份。

GUIHost 懒创建一个随进程生命周期持有的 `ProductionAVFoundationVideoSourceCatalog`。它不是daemon；没有 Live/Chooser request时不要求预启动。首次 request 发起 screen-source enable 和异步 inventory monitoring，此后 Resolver、Stable accumulator、cache Probe、thumbnail、人工 Preview 与正式 Live 全部消费同一 catalog 的 current snapshot和 sourceEpoch lineage。禁止每个阶段创建短命 catalog，禁止用原 `31 * 100 ms` blocking poll 阻塞 AppKit main thread、Chooser出现或cache restore。

GUIHost同时懒创建一个source-scoped capture coordinator。Key为exact `sourceID + sourceEpoch`；同一key最多一个底层`AVCaptureSession` owner，thumbnail、Chooser Preview、Resolver Probe、Live Probe和bound presentation以fenced consumer role注册。需要同源并行展示时由同一capture fan-out到多个sink，不得为每个role各建session。Lease本身不提供mapping authority：正式Live必须先只按canonical UDID重新读取target-local mapping，再用解析出的current sourceID/sourceEpoch acquire；direct cache启动没有可转交lease时由同一接口创建。owner token、sourceEpoch、window close、inventory removal和target reassignment必须原子撤销相关consumer，最后一个consumer释放后stop、清delegate并drain callback queue。

Catalog 对上层只发布 ephemeral metadata：opaque sourceID、sourceEpoch、AV display name、active dimensions和 classification；raw AV uniqueID、device object、manufacturer/media format细节只留在进程内 catalog。每个 snapshot 最多64项并按sourceID稳定排序，sourceID集合或classifier输入变化推进inventory revision；旧revision的Probe、thumbnail、Preview和auto callback必须同时通过sourceEpoch与resolver owner token校验。

Inventory 分层固定为：

```text
captureEligible
  current catalog中可以建立AV capture attempt的source

qualifiedPhoneScreen
  captureEligible中满足完整公开phone-screen predicate的source

residual
  captureEligible中无法证明phone screen、也无法证明known non-phone的source

knownNonPhone
  builtIn camera / Continuity Camera / Desk View等可靠可判定来源
```

`knownNonPhone`不进入Chooser或自动路径；trusted cache仍在完整`captureEligible`中exact resolve，不能因classifier升级让既有人工proof失效。qualified predicate要求以下条件全部成立：

```text
deviceType == .external
&& hasMediaType(.muxed)
&& manufacturer == "Apple Inc."
&& active format mediaType == kCMMediaType_Muxed
&& active format subtype == kCMMuxedStreamType_EmbeddedDeviceScreenRecording
&& device.formats 至少一个format具有相同mediaType + subtype
```

active dimensions允许在首帧前为`0x0`，不参与classifier。`localizedName`、`modelID`、transport、CMIO location、format count、尺寸和枚举顺序都不是classifier proof；任一必需属性缺失即归入residual。名称只在后续auto guard中按Unicode canonical-equivalent exact比较，不做模糊、前缀或后缀匹配。

允许的mapping proof只有：

```text
current operator proof
  proofKind=operatorConfirmedPreview.v1
  + Chooser Preview收到current sourceEpoch有效帧
  + 用户执行最终确认

current single-target auto proof
  proofKind=singleConnectedTargetSource.v1
  + connected target count == 1
  + Stable gate完成且qualified source count == 1
  + source/target display name canonical-equivalent exact match
  + no connected-target duplicate claim
  + Probe收到current sourceEpoch有效帧

cached trusted proof
  trusted target-local record
  + exact source identity domain/version
  + current inventory中sourceID恰好单命中
  + no connected-target duplicate claim
  + current capture收到有效帧
```

名称、尺寸、方向、source数量、列表顺序、单独的deviceType、Desk View或列表第一项均不能独立建立proof。auto proof必须使用独立proof kind，不能写成`operatorConfirmedPreview.v1`。

Stable accumulator只控制“是否允许自动跳过Chooser”：

```text
observationWindow       = 1.5 s, monotonic, always runs to deadline
snapshotInterval        = 100 ms
finalQuietSnapshotCount = 4
finalQuietSpan          = 300 ms
comparison              = exact qualified sourceID set
```

Window从GUIHost首次发起screen-source enable/monitoring前开始。完整1.5秒结束前不得因早期相同snapshot提前auto bind；结束时最后4个snapshot不足、集合为空/变化、enable尚未返回、sourceEpoch/owner token变化或任一auto条件不完整，均终止本次auto attempt并保留Chooser。Chooser、候选更新、thumbnail、人工Preview以及trusted cache exact restore不等待该gate。用户执行选择、Preview、Refresh或其他明确交互后设置`autoAttemptCancelled=true`，后续gate callback只能更新诊断，不能关闭Chooser或handoff。

GUIHost通过本地facts provider按CLI传入canonicalUDID取得target name、iOS version和连接状态，并同时取得bounded connected-target snapshot用于`count == 1`和duplicate claim检查；这些查询不启动Runtime，也不得改选target。Chooser顶部固定显示当前target三项facts。source item只显示AV name、active dimensions和short opaque sourceID，不给source虚构iOS/UDID。

target facts、connected-target mapping claims和AV inventory分别维护独立revision/token。facts/claims recovery固定执行首次立即attempt；每轮provider和mapping读取完整结束后，后续三轮分别按`200 ms`、`500 ms`、`1 s`退避，总计最多4次。同一GUIHost内target snapshot provider通过专用串行队列执行，不允许不同owner、同一owner后续attempt或Refresh新token与尚未返回的旧provider调用并发；旧token callback只能丢弃。每个valid target snapshot都必须读取对应mapping records，但只有连续两次成功attempt得到完全相同的canonical UDID集合且records均可读时才能提交facts/claims；第一次集合、集合变化、provider失败或record不可读都不授权`未绑定`或确认，并在下一次成功attempt重新建立候选集合。每次Chooser Refresh生成新token并同时重启facts/claims recovery和catalog refresh。facts/claims unknown或恢复耗尽时，inventory、thumbnail和Preview继续投影，但mapping确认保持disabled；恢复成功后重新计算claims并在current Preview freshness仍成立时自动启用确认。错误只能显示在target/status区域，不能替换已有source列表或Preview。

启动状态机固定为：

```text
OpenLive(automatic) -> reserve target, no target Runtime
  -> start/shared current catalog snapshot
  -> exact-target trusted cache
       +-> current captureEligible exact match + no duplicate claim
             -> immediate bounded Probe, no Stable wait
             -> valid frame -> source handoff
             -> failure/stale -> Chooser + optional auto gate
       +-> missing/invalid/unsafe/conflicted -> Chooser + optional auto gate
  -> Stable gate finishes before user interaction
       +-> full auto predicates -> bounded Probe
             -> valid frame -> save auto proof -> source handoff
             -> failure/stale -> remain Chooser
       +-> predicates incomplete -> remain Chooser

OpenLive(forceChooser) -> reserve target, no target Runtime -> Chooser immediately

source handoff
  -> persist/confirm target-local mapping
  -> create formal Live identity placeholder with canonical UDID only
  -> formal Live rereads mapping; optional initial canvas ratio applies
  -> ensureRunning + runtime.attachLive
  -> construct fresh ProductionVideoSourceMapping from current sourceEpoch
  -> formal binding Probe on current attachment
       +-> acquire exact source-scoped lease
       +-> current valid frame -> promote same lease to bound video/audio
       +-> no frame by 5 s or identity changed -> video unavailable
  -> geometry/control converge independently

Chooser selection -> selected Preview(valid current frame)
  -> final confirm
  -> coordinated cache mutation/manual proof
  -> source handoff
```

Probe必须在current catalog上按sourceID/sourceEpoch acquire capture lease，只接受第一个format-valid sample，并使用有界deadline；成功只形成source handoff或formal binding readiness，不要求InteractionGeometry。Probe、Preview或正式capture的callback不得跨owner token复用。Cache record永不提供sourceEpoch、inventoryRevision、connectionEpoch、geometry、当前orientation或formatRevision；可缺省initial canvas pair只提供首帧前布局。

source handoff 前的 Resolver Probe只执行一次，失败即进入 Chooser。source handoff 后的正式 Live binding Probe deadline固定为5秒，并作为capture lease上的验证role运行。current valid frame到达后，coordinator原子移除Probe sink、安装bound sink并保留同一底层capture generation；没有可转交lease时由coordinator创建一次。deadline耗尽、配置失败或identity变化时撤销consumer并fail closed，显示video unavailable并保留Change Source；不得使用固定sleep或无liveness证据的盲重试，Runtime-backed非坐标控制继续按独立authority工作。

Chooser first paint和交互不等待thumbnail。Chooser window content使用稳定最小尺寸的纵向三区：紧凑target identity header、双栏workspace、固定footer；titlebar subtitle显示当前app copy的`PulsePhone <version> (<build>)`，不得占用header或改变content size。workspace左栏是可滚动的紧凑source list，右栏是aspect-fit大尺寸实时Preview；footer固定放置Refresh、状态、取消和“使用此源”，窗口缩放时列表、Preview和动作不得重叠，Preview不得缩小到不可辨认。footer tools与actions保持intrinsic宽度；status area从tools后方靠左排列、按内容占宽并允许压缩，其右边界不得侵入actions，未占用空间保留在status与actions之间。status与reassignment warning使用单行tail truncation和低horizontal compression resistance。任一文案更新不得改变当前NSWindow宽度或推动右侧actions。候选按qualified、residual分区；每个source的thumbnail capture串行执行，deadline为从configure开始计算的2秒absolute monotonic window，首帧缩放为最长边240 px。超时、capture失败、source消失、Chooser关闭、Refresh、owner token/sourceEpoch变化或用户选择开始持续Preview时，必须stop capture、清delegate并drain callback queue，旧sample不得写入后续item。Camera非authorized时立即终止整个thumbnail batch，不逐项消耗deadline：`notDetermined` 由长期 GUIHost 请求授权，`denied/restricted` 打开系统 Camera 设置，授权结果只能在真实 callback、App activation或Refresh后重读。总后台预算上限为`2 s * candidateCount`，candidateCount受64项inventory cap限制。

candidate非空且没有有效selection时，已有Live优先选择其exact current active `sourceID + sourceEpoch`，否则选择当前确定性排序的第0项并立即启动持续Preview；inventory revision优先保留exact selection，原项消失后才选择新的第0项。默认选择只改变Chooser-local selection，不形成proof、不写mapping。Preview sink保存最近有效sample的monotonic timestamp、sourceEpoch和owner token；确认时三者必须仍匹配且sample age `<= 1 s`，否则确认disabled并保持/恢复`video preparing`。`hasFrame`布尔值本身不构成确认或cache写入authority。人工确认把frame dimensions按`min/max`写入可缺省initial canvas pair；auto proof使用其Probe首帧尺寸。首次Chooser取消释放reservation且不写cache、不创建Runtime/Live；Camera非authorized时可显式选择“继续，不显示画面”，在不写cache、不形成source proof的前提下handoff target facts并创建identity-placeholder正式Live，随后才启动/attach Runtime。已有Live的Change Source或`forceChooser`复用同target关联Chooser，保留原capture/mapping/Runtime；取消不变，确认后在原Live内stop/fence旧capture并切换，不创建第二个Live owner，也不展示无视频继续按钮。Refresh只刷新shared catalog snapshot、facts/claims recovery、thumbnail和selected Preview attempt，不修改正式mapping。

每个source row分别投影persistent mapping claims与本GUIHost active Live使用状态：未绑定、已映射到当前target、已映射到其他target，以及独立的current Live/other Live标记；mapping存在但没有active Live时不得显示为正在使用，多个claim全部列出并fail closed。选择other-target claimed source时，footer固定显示重新分配影响，点击“使用此源”是唯一确认且不再弹二次alert。选择associated Live的exact current active source时，footer显示“当前 Live 正在使用此视频源”；确认走专用strict no-op：停止并释放Chooser Preview consumer、关闭Chooser并聚焦原Live，不调用mapping mutation/handoff，不更新proof/initial canvas，不停止、重启或Probe bound capture，不改变Runtime attachment、presentation/control或`captureActivationID`。

Chooser、auto和cache Resolver完成proof后只调用`OpenLive(canonicalUDID)`或同target existing-Live refresh；不得把descriptor、mapping record、sourceEpoch或Preview sample作为正式Live source参数。可转交capture由coordinator按key持有，Live重读cache后自行acquire，因此有lease的Chooser路径和无lease的direct cache路径共用同一source状态机。

source-scoped coordinator可以把同一个identity-valid frame事件扇出给多个consumer，但交给display sink的每个`CMSampleBuffer`必须是独立wrapper，具有独立attachments容器并引用同一只读format/data buffer；display sink只允许在自己的wrapper上设置`kCMSampleAttachmentKey_DisplayImmediately`。原始capture sample与其他consumer wrapper保持不可变，任何consumer不得共享或并发修改同一个attachments dictionary。wrapper创建失败只丢弃对应display交付并保留其他consumer；Chooser Preview、bound Live、Refresh/取消/确认和close竞态继续受consumer token/sourceEpoch fence约束。

source消失、sourceEpoch变化、Runtime reconnect或mapping proof失效时，停止旧session并fence旧callback；cache最多作为重新绑定提示，必须重新执行current inventory/capture/frame及正式Live的connection binding。若target未改变、旧帧来自最近一次identity-valid bound session且失效属于USB detach或同source自动重绑过渡，display layer保留已显示最后一帧并进入`frozen`，否则flush并进入`unavailable`身份占位。geometry revision或同sourceEpoch presentation format变化只推进各自authority，不重新选择source。用户最终确认Change Source、切换target、foreign/stale identity及window close必须停止session并flush冻结帧；不同canonicalUDID的record不得互相作为fallback读取。

bound consumer收到首帧后记录session generation与last valid sample monotonic time。每次sample把同generation liveness deadline推进到`sample + 2 s`；deadline到达时若session仍标记running、identity/current consumer仍exact且没有更新sample，则该generation判定为stalled并立即退出`live`。有可保留帧时进入`frozen`，否则`unavailable`；pointer/control只按Runtime authority投影。每个stall generation最多一次clean reacquire：先撤销consumer、stop最后一个lease owner、清delegate、drain callback queue并fence旧generation，再无固定sleep地通过coordinator acquire新generation并执行5秒Probe。失败后保持明确状态，只有用户Refresh、strictly newer inventory/sourceEpoch或AVFoundation interruption-ended才能开始后续attempt；不得无限循环或把`isRunning`当作frame liveness。

USB detach/reattach固定为两条并行恢复链：

```text
detach
  video: stop capture/audio + fence callbacks -> frozen if retained frame else unavailable
  pointer: cancel old interaction/streams + clear old authority -> unavailable

reattach
  video: inventory + cached proof + current frame/binding -> live
  pointer: current attachment -> preparing
           + current geometry + stream admission authority -> available
```

任一链先恢复都不得等待另一链。新video binding收到首个current identity-valid sample并提交presentation时替换冻结帧并进入`live`；Runtime control attachment到达但geometry/admission未完成时进入`preparing`，只有current authority完整成立才进入`available`。stale callback、旧attachment或旧StreamOpen回执不得移除对应状态。

`captureActivationID`由Live window state按current attached owner + current connectionEpoch持有，不由Chooser、mapping、capture lease或`ProductionBoundVideoSession`生成。current epoch首个identity-valid bound sample创建一次ID并调用`runtime.markLiveCaptureReady`；同一epoch内Change Source、replacement bound consumer、capture reconfiguration和presentation/geometry refresh复用该ID，Runtime返回duplicate/alreadyReady时只刷新current geometry，不替换post-capture generation。confirmed detach使旧ID立即失效；reattach建立strictly newer connectionEpoch后只有新identity-valid sample可创建新ID。Live close/new owner同样生成新ID。

GUI不得用`try?`把capture-ready transport/protocol failure折叠成`nil`。stale epoch、owner conflict、invalid response和transport failure分别保留typed diagnosis并按current availability重投影；capture-ready失败只影响本次geometry收敛，不能在现存post-capture pointer generation仍可用时显示通用`Controls unavailable`。Chooser启动与direct cache启动都进入上述同一Live state，不存在“是否携带activation ID”的两套路径。

#### 27.1.3 Sample presentation format

每个identity-valid `CMSampleBuffer`的presentation dimensions按以下唯一顺序取得：

1. `CMVideoFormatDescriptionGetPresentationDimensions`，`usePixelAspectRatio=true`且`useCleanAperture=true`；结果必须finite且两轴均大于0，使用nearest-integer half-up转换为positive `UInt64`。
2. 上述结果无效时fallback到`CMVideoFormatDescriptionGetDimensions`的raw encoded dimensions；任一轴非正时该sample为invalid format并丢弃。

首个有效sample建立`formatRevision=1`和session normalized shape。之后每个identity-valid、format-valid sample必须先进入display enqueue路径，再独立驱动下列candidate state machine；candidate/debounce/window work不得成为enqueue前置条件：

```text
same exact dimensions
  -> no presentation mutation

same orientation + abs(candidateShape - establishedShape) <= 0.015
  -> resolution-only candidate

width/height orientation changes
  + abs(candidateShape - establishedShape) <= 0.015
  -> orientation candidate

otherwise
  -> anomalous-ratio candidate; display aspect-fit only
     no authoritative shape/window/geometry mutation without corroboration
```

candidate按orientation、dimensions和shape容差归并；conflicting sample重置candidate。三帧连续一致时立即提交；若从第一帧起400 ms内只有两帧一致且没有conflict，则在400 ms边界提交；单帧永不提交。400 ms到期仍不足两帧则丢弃candidate而保留current authority。resolution-only和orientation commit都递增`formatRevision`；resolution-only保持用户windowed canvas长边且不因pixel count变化调整该长边，orientation commit进入§27.1.4。timer、candidate和callback均绑定exact session/sourceEpoch，stop/rebind后的旧callback不得提交。

Reachability通常不改变framebuffer dimensions，因此只作为像素内容变化显示，不触发candidate。临时crop或异常ratio可以在current black canvas中aspect-fit显示；即使持续稳定，也只能在current Runtime geometry佐证相同shape/orientation后提交，否则进入明确的geometry-revalidation状态并保持坐标输入不可用，禁止静默重定义设备shape。

renderer status failure沿既有flush/recovery路径处理；合法format commit本身不是renderer failure，不得自动flush、restart capture或分配新sourceEpoch。

实体屏幕采集还存在一种独立的persistent outer-format mismatch：primary display actual geometry已经由Rotate terminal或等价权威事件稳定推进到另一orientation class，但identity-valid AV sample在上述400 ms format确认窗口结束后仍维持旧class的outer presentation dimensions，并把新方向framebuffer letterbox到旧外层。该状态不得作为合法format commit，也不得通过aspect-fit长期保留。GUI为每个strictly newer actual geometry revision最多安排一次有界capture reconfiguration；执行前再次核对exact connection、sourceID/sourceEpoch、geometry revision及presentation仍未收敛，若sample已自然提交matching format则取消。reconfiguration只重建当前`AVCaptureSession`的input/output negotiation，保留mapping proof、sourceID/sourceEpoch、frame sequence owner、单调formatRevision、Runtime attachment和post-capture Helper generation；不重新枚举或猜测source，不发送第二个Rotate，不把reconfiguration解释为source reconnect。失败时video可继续显示最后可用帧或明确不可用，但坐标保持fail closed并记录stage/code。

capture reconfiguration期间旧session callback、deadline与frame继续受当前session/token fence约束；停止/重配必须串行，旧callback不得写入新session。新session至少收到两帧一致sample并提交matching presentation后，才允许按§27.1.4复用同一captureActivationID取得/确认actual geometry并原子恢复video binding与coordinate input。自动化必须覆盖自然宽高交换不触发reconfiguration、persistent mismatch只触发一次、reconfiguration成功后formatRevision继续单调、失败/stop竞态有界、source proof和Runtime/Helper generation不变。

#### 27.1.4 Presentation 与 interaction geometry同步

stable orientation commit固定执行：

```text
commit new formatRevision
  -> cancel current pointer interaction / release coordinate-owned input
  -> clear optimistic and observed overlay
  -> keep interaction geometry unavailable
  -> reuse current captureActivationID for one idempotent geometry refresh
  -> Runtime queries primary display and returns actual geometry receipt
  -> GUI validates exact connection + logical size/orientation class + monotonic revision
  -> atomically update LiveWindowModel, video binding and interaction view
  -> coordinate input available
```

AV sample的portrait/landscape类和尺寸不得生成GUI-derived handed geometry，也不得覆盖较新的Runtime/rotate geometry。toolbar Rotate Ack若提供current connection、严格更高revision和matching orientation，则其geometry优先；stale Ack、same-revision conflict和与stable presentation方向类不符的geometry保持fail closed。physical/manual rotation没有Rotate Ack时，GUI必须通过TRD 05定义的同activation幂等capture-ready refresh取得actual display geometry；查询失败时视频继续而coordinate input保持不可用，不得回退到`.portrait`或`.landscapeRight`默认值。

当Runtime已被另一个Client或Rotate terminal推进到同一物理geometry的更高revision时，首次新coordinate StreamOpen以§26.1的accepted geometry回执完成authority收敛；GUI不得把较低的local presentation revision写回Runtime。该首帧前收敛不构成新的orientation或window mutation，且不能复活已发送或已取消的旧interaction。

geometry变化只更新interaction/window authority，不改写sourceID/sourceEpoch或sample format。geometry commit前先cancel旧interaction；旧format candidate、旧timer、旧source session和旧connection callback都不得覆盖current revision。video display不等待Runtime geometry。coordinate path要求current Runtime geometry和current stream admission authority，但不要求`VideoAvailability.live`；当视频为`frozen/unavailable`时，visual point仍只按current geometry投影到current canvas，冻结帧不得参与geometry推导或修正。current geometry尚未确认时保持`PointerAvailability.preparing/unavailable`。

Rotate terminal的actual geometry采纳必须是all-or-none GUI transaction：先在model副本中验证revision/connection，再让current video binding接受同一geometry，随后提交model、controller和interaction view。若presentation尚未对齐，仍可保存新的Runtime geometry用于窗口恢复和后续capture reconfiguration，但必须cancel/reset pointer controller、清空interaction view geometry和overlay，并保持`coordinateInputEnabled=false`；不得因为旧model geometry仍与旧sample对齐、accepted-geometry回执可用或video binding部分更新而开放StreamOpen。`mouseDown`还必须拒绝`videoBindingInFlight`或capture reconfiguration active状态。

#### 27.1.5 Window reservation、实际最小宽度与fullscreen

AppKit content layout固定为`videoCanvas + sourceControls`两个纵向、不重叠区域；第一阶段`sourceControlsHeight=52 pt`。正式 Live 的 sourceControls 只能只读显示current source摘要和video状态，并提供Change Source图标按钮；不得包含source picker、Preview或Use Source。首次选择、强制纠正、Refresh、thumbnail和人工Preview都属于关联Chooser。`AVSampleBufferDisplayLayer`、interaction view、identity placeholder与overlay只能占用videoCanvas；native toolbar和source controls都不得进入`visibleImageRect`。稳定windowed状态下canvas host bounds必须等于`visibleImageRect`，不得存在未被video占用的横向或纵向区域；fullscreen和stable presentation尚未提交的有界过渡可使用黑色非坐标letterbox。

bound session使用current committed presentation ratio；placeholder使用§27.1.2的fallback authority。window sizing使用`contentHeight = canvasHeight + sourceControlsHeight`并另计AppKit实际titlebar/toolbar chrome，禁止把包含source controls的整个`NSWindow.contentAspectRatio`设为设备比例。

用户尚未完成有效windowed resize时，programmatic initial reservation使用`preferredWindowedCanvasShortEdge=375 pt`；portrait与landscape都先固定canvas短边，再以current presentation ratio计算长边，最后加入`sourceControlsHeight`与AppKit实际chrome。Retina `2x`下该短边约为`750 backing pixels`，但reservation、约束和验收只使用AppKit points。该值是screen/minimum约束前的preferred target，不是原始frame硬编码；visible frame不足时按比例缩小，实际不可压缩minimum更大时保留明确owner诊断。当前标准主显示环境且presentation/controls均可用时，portrait canvas/content/frame短边应优先采用约`375 pt`；不得因次要toolbar item保持可见、picker自然宽度或旧`640 pt`长边目标而偏离该值。

source controls fitting width、`NSWindow.contentMinSize`、native titlebar/toolbar布局和AppKit实际采用的content width共同形成`actualMinimumContentWidth`。产品另行冻结`minimumWindowedCanvasShortEdge=320 pt`：portrait的minimum canvas width为`320 pt`，landscape的minimum canvas width为`320 * currentPresentationRatio`，最终effective minimum width取它与`actualMinimumContentWidth`的较大值。`320 pt`是可用性下限，不得替代`375 pt` initial preferred target，也不得被某次adopted width写回；只有visible frame无法容纳时才能在当次screen-bound reservation中同比例降低且不得持久化。toolbar使用compact/icon-only presentation，纯视觉title隐藏但保留accessibility title，次要item允许稳定overflow；不能靠缩小hit target绕过minimum。programmatic reservation流程固定为：

```text
calculate ratio-preserving desired content
  -> setFrame once when windowState == windowed
  -> layoutSubtreeIfNeeded
  -> read actual adopted content/frame size
  -> if adopted width differs by > 0.5 pt, fold it into actualMinimumContentWidth
  -> recompute both canvas axes from current presentation ratio
  -> setFrame at most once more and verify canvasHost == visibleImageRect
```

同一`formatRevision + screen + windowState`最多两次programmatic `setFrame`，禁止layout/setFrame无限循环。稳定windowed状态不得使用letterbox作为minimum-width fallback。若actual minimum width与visible-frame高度发生冲突，先让次要toolbar item进入overflow并让source controls采用更紧凑的自适应布局，再将preferred/user size裁限到最近的可行精确比例尺寸；禁止返回`max(canvasWidth, minimumWidth)`而保留原canvas height，也禁止让canvas host宽高与`visibleImageRect`分离。两次reconciliation后仍无法满足时必须输出可诊断失败，不能静默以黑边或白边交付。

compact initial reservation的minimum-width处理顺序固定为：保留标准hit target；将次要toolbar item移入overflow；降低source controls水平compression resistance并裁剪非权威展示文本；量化到AppKit可采纳的整点canvas尺寸；最后才允许提高canvas两轴。若经过这些步骤后portrait short edge仍超过`375 pt`，实现必须记录actual minimum width及其owner，并证明这是不可压缩chrome/control约束；不得恢复已被owner取代的preferred-long-edge模型，也不得以screen-height filling作为默认策略。

用户live resize只在`windowed`状态执行ratio约束。`windowWillStartLiveResize`建立transaction并冻结reference frame、committed presentation ratio、source controls高度与actual window chrome高度；首次有效尺寸变化根据候选frame相对reference frame的变化冻结`widthEdge`、`heightEdge`或`corner` driver。单边driver始终保留用户控制轴并派生另一轴；corner driver把候选`(width, canvasHeight)`投影到`width = ratio * canvasHeight`，以相对reference frame的归一化位移选择同一投影方向，手势内禁止重新比较每个callback的width/height delta后切换driver。每次callback都必须满足`contentWidth = canvasWidth`、`contentHeight = canvasHeight + sourceControlsHeight`和`canvasWidth / canvasHeight = frozenPresentationRatio`；从任意边或角拖动、`320 pt`产品minimum、maximum clamp和screen bounding都不得单独改变一轴。尺寸量化按current backing scale在投影后执行一次，不能让相邻callback在两个candidate之间往返。

若AppKit省略`windowWillResize`、返回值未被完整采纳或`windowDidResize`观察到missing pending/partial-axis adoption，`windowDidResize`以transaction reference、冻结driver和当次adopted frame生成expected frame；修正必须保留用户直接拖动的edge位置，并以sequence/reentrancy fence保证相同adopted frame只产生相同结果。活跃resize期间普通presentation/window reservation callback只更新pending状态，不得清除transaction、重置driver、重新居中窗口或发起独立programmatic reservation。异步next-run-loop reconciliation和`windowDidEndLiveResize` settlement只验证晚到WindowServer漂移，不能作为正常可见resize的反复校正机制。对应frame关系为`frameHeight = canvasWidth / frozenPresentationRatio + sourceControlsHeight + actualWindowChromeHeight`。固定controls/chrome意味着原始`frame.width / frame.height`不是常量，禁止用`NSWindow.aspectRatio`或包含controls的`contentAspectRatio`替代该派生关系。`windowDidEndLiveResize`记录实际visibleImageRect的长边，不记录content长边，也不得持久化低于`320 pt`的canvas短边。首次binding且用户尚未resize时使用默认`375 pt` canvas短边；presentation/geometry变化保留用户windowed长边并裁限current screen visible frame。

bound video session在live resize开始时接收冻结presentation。identity-valid sample仍进入presentation tracker和capture liveness；与冻结presentation具有相同portrait/landscape class的sample继续enqueue，与其方向class不兼容的sample在display enqueue前被withhold，使`AVSampleBufferDisplayLayer`保留最后一个兼容帧。collector仍按3个一致sample立即commit，或在至少2个一致sample后于400毫秒deadline commit；commit callback在活跃transaction内保存为latest pending presentation，不调用window reservation。withhold开始后pointer admission保持fail closed，直到resize结束、latest stable presentation及对应Runtime geometry一次性采用且新方向匹配帧恢复展示。若结束时pending presentation已稳定，立即采用而不重新启动debounce；若尚未稳定，display gate保持到既有tracker提交。close、source change、detach/rebind、capture stop与fullscreen transition必须按generation清除gate和pending callback。

fullscreen状态机固定为：

```text
windowed -> enteringFullscreen -> fullscreen
fullscreen -> exitingFullscreen -> windowed
```

`windowWillEnterFullScreen`保存windowed用户长边和last reservation并进入`enteringFullscreen`。`enteringFullscreen/fullscreen/exitingFullscreen`期间可以提交formatRevision、更新canvas aspect和geometry，并在系统fullscreen bounds与设备比例不同时使用对称黑色letterbox，但不得调用`setFrame`，也不得把fullscreen bounds写入preferred windowed canvas尺度。transition期间多个candidate仍按§27.1.3归并，只有最终stable commit生效。`windowDidExitFullScreen`进入`windowed`后，以退出当刻current presentation ratio、进入前用户长边和current screen visible frame执行一次无letterbox的有界reconciliation；用户从未resize时才使用默认`375 pt` canvas短边。

screen change、placeholder、Camera denied、source unavailable、`frozen`最后一帧和source重新绑定全部复用同一reservation/window-state入口，不存在无视频源专用resize旁路。`frozen`保留last committed presentation ratio；windowed resize、screen clamp和fullscreen transition继续使用同一精确比例管线，不得因状态浮层或capture停止产生黑边、白边或窗口比例跳变。

画布状态浮层位于display layer之上、interaction view的非阻塞视觉层中，bounds始终等于video canvas。其hit testing必须透明，不能拦截`mouseDown/drag/up`或改变`visibleImageRect`。identity placeholder与primary video availability共享一个中央视觉owner，不得同时绘制重复identity/video label。中央owner使用紧凑深色半透明局部surface、稳定padding和浅色系统图标/文字/progress；其对比度由surface保证，不读取或猜测视频帧亮度。Reduce Transparency或Increase Contrast生效时改用更不透明的系统中性色。surface内按状态显示独立video/pointer行，对应状态恢复后只移除自己的行，两者均恢复后隐藏；底部touch badge继续独立显示且布局不得与中央surface重叠。identity placeholder与冻结帧互斥；没有历史帧时由中央owner承载身份和视频不可用状态。

#### 27.1.6 Verification boundary

Source Resolver/Chooser自动化至少覆盖：公开metadata classifier的qualified/residual/known-non-phone边界；1.5秒完整窗口、100毫秒snapshot和末尾4次exact集合；早期瞬时唯一、晚出现source、用户交互取消auto；cache exact restore不等待gate；cache missing/corrupt/ambiguous/no-frame/duplicate claim回退；thumbnail串行、2秒timeout、取消和stale callback fence；Preview帧age恰好1秒、超时、wrong owner/sourceEpoch；facts/claims首次失败后200/500/1000毫秒串行恢复、同一GUIHost provider最大并发为1、恢复耗尽、连续两次相同connected-target集合才提交claims、Refresh新token和stale callback fence；默认第0项、已有Live current source优先和inventory selection保留；mapping/active Live独立状态、current source strict no-op和other-target一次确认；footer status/warning长文案在minimum、initial和用户放大宽度下不得扩大window或侵入actions；initial canvas pair的min/max归一化、缺失兜底与无authority语义；首次取消不启动Runtime；handoff后才ensureRunning；Chooser/direct均只按UDID让Live重读cache；source-scoped lease单owner、多sink fencing、每个display consumer独立sample wrapper、Probe到bound原地promotion、无lease direct创建、5秒Probe耗尽；bound 2秒stall、每generation一次clean reacquire、恢复耗尽和显式Refresh；已有Live强制选择/取消/确认；同epoch activation复用、new epoch/new Live轮换、capture-ready typed failure；单target auto proof与operator proof kind分离；sourceControls只读；`--select-source` IPC/disposition；connected-target reassignment和partial failure fail closed；中央status surface高对比、无重复label、accessibility appearance和hit-test透明。测试clock、catalog、capture、liveness deadline和callback queue必须可注入，不能以真实1秒、1.5秒、2秒或5秒sleep作为唯一覆盖。

自动化至少覆盖：same-source/same-epoch orientation transition、resolution-only change、single/outlier/conflicting candidate、400 ms commit边界、stale session callback、wrong source/epoch/connection、presentation/geometry convergence、active interaction cancel、视频/触控四种正交组合、detach保留最后一帧但释放旧capture/audio/input authority、无历史帧fallback、source change/Clear Mapping/close清除冻结帧、reattach两条链任意先后恢复、旧callback/attachment不得复活状态、浮层hit-test透明、actual minimum width两次reconciliation cap、默认`375 pt` canvas短边compact initial reservation、`320 pt` minimum canvas短边的portrait/landscape与screen-bound分支、Retina `2x`约值但以points验收、当前标准主显示环境portrait约`375 pt`可行短边、初始portrait/landscape windowed零letterbox、冻结帧和状态浮层下windowed零letterbox、四边四角各50至100个连续callback的扩张/收缩单调性、transaction driver不切换、直接拖动edge不反弹、相同adopted frame幂等、missing `windowWillResize`同步fallback、partial-axis adoption同步修正、programmatic callback fence、活跃resize中的presentation/geometry callback不清除transaction、同方向帧继续enqueue、异方向帧withhold但tracker照常commit、pending stable presentation在结束后只采用一次、pointer在旧方向保留帧期间fail closed并于收敛后恢复、screen bounding、windowed user-scale preservation、fullscreen black letterbox及完整fullscreen状态机。至少一项GUIHost assembly测试必须在主线程使用真实`NSWindow`、native toolbar和完成layout的content view，分别在初始binding与真实live resize后断言`canvasHost.bounds == visibleImageRect`且比例匹配；只测纯数学model、只断言adopted width有界或只验证拖动结束后的settled frame不构成passing。

packaged Gate记录sourceID摘要、sourceEpoch、formatRevision、sample dimension序列、geometryRevision、window/content/visibleImageRect、fullscreen state和pointer结果；不得记录raw AV uniqueID或用dimensions证明target identity。

### 27.2 Audio

每 live 独立 AVFoundation audio preview 和 local Mac/Off output state，默认 Off。选中 `Preview Audio` 才允许音频进入 Mac renderer；未选中时不入队并清空 renderer 缓冲。Camera、Microphone、video、audio 和 control 分别降级。Detach/source epoch change 立即停止旧 audio。

### 27.3 Toolbar shape

Client 先运行 local Catalog + bounded facts probe：

```text
compatible   -> include enabled/loading by current state
incompatible -> omit
unknown      -> include fixed slot as disabled/loading(factsUnknown)
```

窗口生命周期内不增删/重排 toolbar；Runtime snapshot 只更新 state/reason。固定右侧More按钮的popover在控制项之后以separator和secondary footer显示当前app copy的`PulsePhone <version> (<build>)`；footer不属于toolbar item，不进入overflow宽度、source controls fitting、window minimum或canvas比例计算。Chooser subtitle与More footer复用同一个从当前Bundle读取且可注入测试值的版本模型。

### 27.4 Observation overlay

Runtime 在 Executor `acceptedForDelivery` 后发布 pointer projection。GUI 使用 `(clientInstanceID, interactionID)` 去重本地乐观 overlay 和 Runtime echo。

observation queue 饱和时 reset/disconnect，不反压 device execution。

RuntimeObservation不得等待Product Action terminal、设备画面变化或GUI绘制。CLI/GUI
触摸一旦到达真实`acceptedForDelivery`边界，publisher异步投递标准projection；本地
device execution线程不等待任何subscriber。`ObservationStreamReset`只清除projection，
不代表设备重新连接。connection epoch变化时先reset旧projection，GUI只有在新
LiveAttachment、new source epoch、current geometry和new capture activation收敛后才把
新observation映射到visible image rect。

### 27.5 Screenshot

GUI hybrid：

```text
toolbar click
  -> create rootActionID
  -> best-effort record root.begin on existing compatible Runtime
  -> open Save Panel

Save Panel cancelled
  -> record root cancelled terminal
  -> no Runtime child

selected path + bound frame <=1 s
  -> local PNG encode/write
  -> record root terminal
  -> no child

otherwise
  -> create childActionID(parentActionID=rootActionID)
  -> child device.screenshot with both IDs
  -> Runtime records child begin/terminal only
  -> ArtifactFD
  -> local write
  -> Client records root terminal only
```

best-effort root logging 不冷启动 Runtime，也不改变本地结果。root 与 child 必须使用不同 actionID；Runtime child 与 Client root 不得对同一 actionID 各写 terminal。preview local write failure不 fallback，避免重复动作。

Save Panel 没有产品 deadline；用户选定目标后，preview local encode/write 使用 5 秒 stage deadline，device child 使用 30 秒 running deadline。不存在把 Save Panel、Runtime queue、device execution 和 local write 合并在一起的 screenshot-specific whole-action deadline。

## 28. CLI 实现

### 28.0 Static Help fast path

`PulsePhone`必须先从bundled CommandCatalog构造静态CLI surface，再决定是Help还是Product Action。以下入口均在任何设备或Runtime factory之前完成：

```text
PulsePhone --help
PulsePhone help
PulsePhone <command path> --help
```

Help fast path只能读取已打包的regular-file Catalog/schema资源并向stdout写入稳定UTF-8文本；不得调用`LocalDeviceFactsProbe`、usbmuxd/CoreDevice、Runtime bootstrap/socket、GUIHost、host mutable state、实时availability或TCC API。未知command path仍返回usage error/exit 2。顶层Help按Help group/order再按ASCII显式command path排序；单命令Help合并同一path下的合法variant，并从Catalog argument/compatibility definition渲染usage、options、constraints、compatibility和examples。renderer不得根据commandID或不完整`cliVariant`猜测`button`等命名空间。

`commands`仍是`catalog.commands` local Product Action。它与Help共享同一静态projection，但按新版本化result schema输出machine descriptor；测试必须注入会在调用时失败的device/runtime/GUI factories，证明Help和`commands`均不触发副作用。

`version`是`product.version` local Product Action。生产值只读取当前 packaged app 的`CFBundleShortVersionString`和`CFBundleVersion`；human输出固定为`PulsePhone <version> (<build>)`，JSON result精确为`version`与`build`。任一键缺失、为空或类型错误时以`internalFailure`失败，不从Git、Runtime、设备或其他app copy猜测。该命令与Help/`commands`一样不得创建device、Runtime、GUIHost或host mutable-state backend。

`self install`是`self.install` local Product Action，不进入Runtime bootstrap、Planner或Scheduler。`skill install`、`skill status`和`skill uninstall`同样是local Product Action，不创建device、Runtime或GUI backend。路径只从effective UID经系统用户数据库取得的login home派生：App固定为`Applications/PulsePhone.app`，launcher固定为`.local/bin/PulsePhone`；不得信任`HOME`、cwd、PATH或shell expansion。源App使用`canonicalAppPath.v1`从当前executable确定，并在任何写入前验证bundle结构、主executable、版本/build、required bundled resources和签名。source与destination解析为同一filesystem object时直接按`alreadyCurrent`处理，不自复制。

destination判定不跟随最终node symlink：missing为`installed`；regular app directory且版本/build不同为`updated`；存在但bundle、主executable、required resources或签名无效为`repaired`；全部有效且版本/build相同为`alreadyCurrent`。`alreadyCurrent`不复制App、不枚举或终止进程，但仍执行launcher reconciliation。需要复制时先复制一次到`~/Applications`下的唯一sibling staging目录；复制必须保留bundle tree和签名相关metadata，随后对staging重复完整验证并确认版本/build与source exact一致。该阶段失败不得改变现有App或launcher。

staging ready后，installer只枚举effective UID且executable位于validated source或current destination bundle内的已知PulsePhone role；保存并立即复核PID/start identity/executable path，不匹配即跳过且不得按名称发信号。installer自身PID永不signal。先发`SIGTERM`并有界等待5秒，再只对仍存活且再次复核通过的进程发`SIGKILL`并等待2秒；超时或无法确认退出时停止发布。Live、Trace、Diagnostics、Runtime/Helper会话可以被终止且不自动恢复；不删除日志、截图、已完成recording、Developer Support asset或其他用户数据，只清理已验证为stale且由旧generation拥有的runtime transient state。

publish在`~/Applications`同一文件系统内使用rename/swap语义，并保留旧App rollback node；launcher reconciliation同样先保留旧node。正确的canonical absolute symlink保持不变；错误symlink、普通文件或旧launcher script可替换；directory或其他unsupported node直接失败，禁止递归删除。发布后从cwd `/`分别直接执行installed executable与经launcher解析的`--help`和`version --json`，验证command ID、版本/build和exit status；四项全部通过后才删除rollback node并返回成功。任一post-publish检查失败必须恢复App与launcher；恢复失败返回typed internal failure且不得声称安装成功。成功result精确包含`disposition`、`launcherChanged`、`terminatedProcessCount`、canonical `applicationPath`、`launcherPath`、`version`和`build`。

正式packaging把tracked `skills/pulsephone/SKILL.md`复制到`Contents/Resources/AgentSkills/portable/pulsephone/SKILL.md`，把Codex专属`agents/openai.yaml`复制到`Contents/Resources/AgentSkills/codex/pulsephone/agents/openai.yaml`，并在outer seal前验证两者为owned regular file、portable frontmatter名称为`pulsephone`且Codex default prompt使用`$pulsephone`。Skill资源进入完整app content manifest、签名和release candidate identity；不得从app外部路径在运行时读取或替换。

`skill install`先从当前validated source app读取并验证完整portable/platform payload，再调用与`self install`相同的`ProductionSelfInstaller`事务。App安装成功并从全局launcher验证版本/build后，才处理skill目标；skill阶段失败不回滚已经独立成功的中央App安装，但不得留下任何部分更新的skill目标。内置Codex与Claude Code root从同一trusted login home派生；自定义`--skill-root`必须为不含`.`/`..`、NUL或非规范separator的absolute standardized path，最终目录始终追加`pulsephone`。不得接受目标自身或任一既有ancestor symlink，不得跟随最终node，且所有既有可变node必须属于effective UID。

portable `SKILL.md`和平台metadata带可验证的managed-content marker，marker承诺其余exact bytes的SHA-256。发布前读取所有目标：marker与bytes匹配表示未修改managed payload，可安全升级；exact current bytes为`unchanged`；marker缺失/不匹配、unexpected node或unknown file占用managed path为conflict，除非显式`--force`。force只授权替换或删除声明的managed relative paths，不授权递归删除skill目录中的其他内容。所有待写文件先在各root的private sibling staging构造、复读和hash验证；全部staging ready后才逐目标rename/swap，并保留rollback node直到所有目标复读成功。任一skill发布失败按逆序恢复已发布目标。

`skill status`纯读取目标并报告`notInstalled`、`installed`、`modified`或`incomplete`；无selector时固定检查两个内置目标，不扫描filesystem发现其他Agent。`skill uninstall`要求显式目标，使用与install相同的preflight与multi-target rollback，只删除声明的managed file；缺省拒绝modified/incomplete payload，`--force`仍保留unknown file和非空目录。三条命令均返回bounded target数组，输入target在canonical path去重，human和JSON来自同一typed result。

安装后的skill不包含app路径或`self install`步骤。其setup gate只运行全局`PulsePhone version --json`；失败时停止设备动作并要求用户从完整app重新执行`skill install`。Agent加载skill或收到普通设备请求不构成全局安装授权；只有用户直接调用或明确批准Agent调用`skill install`才构成授权。

内部`PulsePhoneRuntime`执行顺序固定为：

```text
pre-scan argv for exactly --help / help
  -> print minimal internal usage, exit 0
  -> otherwise initialize readiness FD
  -> parse --canonical-udid
  -> acquire/bootstrap Runtime and run server
```

Runtime Help不得创建readiness对象、读取标准readiness FD、取得process lock、创建socket、探测设备、组装server或进入runloop。正常Runtime启动参数仍拒绝未知/重复option；Help不是Runtime control operation。

### 28.1 Output adapter

所有 public command 支持 `--json`。参数解析前预扫描该 flag，确保 early parse error 也输出 envelope。
`element.snapshot` 由 TRD 09 定义为默认 JSON 的机器输出命令；其 `--json` 在
`--format json|both` 下幂等，和 `--format annotated` 组合时在任何 Runtime 请求前失败。

```text
human:
  stdout final success
  stderr progress/warning/error

json:
  stdout exactly one final envelope
  no progress
```

第一阶段不公开 `--verbose`。human queued/started/progress 采用统一限频规则写 stderr；JSON mode 不输出中间事件。

最小 JSON envelope：

```text
schemaVersion
ok
commandID: string | null
commandToken?                 # only before commandID resolution
target:
  {scope:"global"}
  or {scope:"device",udid:"..."}
  or {scope:"unresolved",requestedUDID?}
result?                       # ok=true only
error?                        # ok=false only
metadata?
```

`unresolved` 只允许 pre-target failure。成功结果和已经选中设备后的失败必须使用 global/device。global action 不写 per-UDID ActionLog；single-device local action只向已经存在的兼容 Runtime best-effort 上报。

`app.list` human输出固定header `NAME\tBUNDLE ID\tVERSION\tTYPE`，缺失名称/版本显示`unknown`；字符串先转义反斜线，再转义tab、LF、CR和其他Unicode control character，不能破坏行列结构。JSON result保留原Unicode字符串并省略缺失的optional字段，由JSON encoder完成规范转义；human与JSON使用同一稳定排序后的normalized result。

exit：

```text
0 success
1 internal
2 argument
3 targetCompatibility
4 runtimeProtocol
5 admissionBusy
6 knownCommandFailure/partial
7 unknownOutcome
130 interrupted
```

### 28.2 Client timeout

CLI timeout 仅覆盖实际 command observation；preparation 不延长普通命令：

```text
non-DDI command
  -> clientWaitTimeoutV1 = 60 s

DDI-dependent finite command
  -> capability unavailable 时 start/join Runtime preparation
  -> immediately return capabilityPreparing remediation
  -> no ordinary command wait, re-plan, or automatic replay

device.prepare
  -> 不使用普通 60 s budget
  -> wait for the Runtime preparation terminal
```

普通60秒Client wait到期：

```text
best-effort cancelOwnedPendingWork(targetRequestID)
do not wait ack
close connection
return outcomeUnknown
  details.reason=clientWaitDeadlineExceeded
  metadata.runtimeMayContinue=true
exit 7
```

Client timeout 不进入 RuntimeJobPlan、PreparationWaitRegistry 或 Scheduler，也不重置 Runtime 内部 phase deadline。`device prepare` 不设置 client observer timeout，且 CLI 忽略 SIGINT；只有 client EOF 才关闭其观察通道，shared attempt 仍由 Runtime deadline 决定。

### 28.3 Ctrl-C

除 `device prepare` 外，整次 invocation 共用 1 秒：

```text
local    stop new local step, kill active FactsProbe group
control  cancel before write or wait existing terminal
oneShot  request CancellationDisposition
hybrid   stop launching new child, project each active child
```

所有结果 exit 130。第二次 SIGINT 立即退出。

`device prepare` 首次和后续 SIGINT 均忽略，不向 Runtime 发送取消，也不主动关闭 observer；其可观察终态只能来自 Runtime 内部成功、typed failure、absolute deadline 或断连。

### 28.4 Aggregate

Client snapshot target，最多 256、fan-out 8、item 2 KiB、final 1 MiB。

```text
completed          preserve result
not submitted      notStarted
read-only in-flight timedOut
mutating submitted outcomeUnknown
```

exit priority：130 > 7 > 6 > 0。

`runtime status` global 只扫描当前可发现 socket，不展示无 socket orphan，也不把已连接但无 Runtime 的设备伪造成 running entry。超过 256 个 target 或结果 cap 时返回有界前缀和 known partial。

`logs clear --all` 在任何删除前固定 target snapshot；若 snapshot 已超过 256，立即返回 `aggregateTargetLimitExceeded`，不得产生部分删除。执行期间新 target 不纳入，已完成删除不回滚。

### 28.5 stop

stop Client 全程持有 bootstrap.lock：

```text
recheck
  -> absent + lock free: alreadyStopped
  -> socket exists: stopIfIdle / retireIfIdle
  -> absent + lock busy: classify + wait/recover, no spawn

Ack stopping/alreadyStopping
  -> wait socket EOF
  -> acquire/release runtime.lock probe
  -> only then print Stopped
```

第一阶段无 force stop。
