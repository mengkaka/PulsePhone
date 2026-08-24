# PulsePhone TRD 01 - 平台、进程与身份

> 文档状态：第一阶段规范章节
>
> 上级文档：[`pulsephone-trd.md`](../pulsephone-trd.md)
>
> 负责范围：第 3～7 节；平台与产物、模块依赖、进程拓扑、canonical identity、target selection 和 availability。

本章只定义基础设施和身份事实，不定义 command-specific 执行规则、Developer Support 状态机、Wire framing 或发布证据。相关细节分别由 TRD 02、TRD 03、TRD 05 和 TRD 08 持有。

## 3. 平台、产物与构建

### 3.1 平台

```text
macOS 14+
Apple Silicon arm64
USB transport only
supportedDeviceClasses = [iPhone]
iOS targetCompatibility = 14.0+
App Sandbox = off
```

暂不支持 Intel、Universal binary、macOS 13 以下、Wi-Fi transport 和 iPad。iOS 14～16 使用 legacy route，iOS 17+ 使用 modern route；具体命令范围由 Command Matrix 和已验证证据共同约束。

### 3.2 App bundle

权威公开 executable：

```text
<any path>/PulsePhone.app/Contents/MacOS/PulsePhone
```

私有 Runtime executable：

```text
<same bundle>/Contents/Helpers/PulsePhoneRuntime
```

第一阶段 bundle 目录固定为：

```text
PulsePhone.app/
  Contents/
    Info.plist
    MacOS/
      PulsePhone
    Helpers/
      PulsePhoneRuntime
      PulsePhoneDirectHelper
      PulsePhoneCoreDeviceHelper
    Resources/
      Registries/
        command-catalog.v1.json
        runtime-wire-messages.v1.json
        runtime-operations.v1.json
        guihost-wire.v1.json
        helper-wire.v1.json
        facts-probe-wire.v1.json
        standard-errors.v1.json
        developer-image-catalog.v1.json
        preparation-groups.v1.json
      Licenses/
```

`PulsePhoneRuntime` 是唯一私有 native Runtime executable；DirectHelper 与 CoreDeviceHelper 是独立签名的 Go executable，分别承担 direct/facts 与 CoreDevice device I/O。Runtime/Client 必须从已校验 bundle root 精确解析对应 executable、registry 和 resource，不通过 shell、PATH、caller cwd 或环境变量查找。

App bundle 不携带 DDI、personalization ticket 或运行时下载产物。Developer Support asset 只允许进入 TRD 07 定义的 Application Support 受控缓存。

### 3.3 构建系统

第一阶段使用 Swift Package + packaging script/Makefile：

```text
SwiftPM:
  Swift模块、可执行文件、单元测试、编译已追踪且verify-generated通过的registry binding

explicit generation:
  normative registry/schema
  -> isolated build/generated staging
  -> explicit update of tracked Swift/Go bindings and tooling-owned Python registry output
  -> verify-generated exact-byte comparison

packaging:
  release build
  app bundle assembly
  Go helper binaries and required standard-library/license inventory
  registry/golden fixture
  codesign / notarization / staple
  clean-machine smoke test
```

不继续使用原型的单文件 `swiftc` 形态。

### 3.4 可移动边界

`canonicalAppPath.v1` 从当前主 executable 解析：

```text
realpath executable
  -> F_GETPATH filesystem canonical path
  -> verify suffix /PulsePhone.app/Contents/MacOS/PulsePhone
  -> derive bundle root
  -> hash canonical bundle path for GUIHost endpoint
```

hash 输入使用 bundle root 的 UTF-8 filesystem representation bytes，不额外 case-fold 或 Unicode normalize。任一步失败返回 `guiHostUnavailable`，不得回退 caller 原始路径。

不同 canonical app path 使用不同 GUIHost endpoint。不同 app copy 可并行存在，但所有 copy 对同一 UDID 最终共享同一个 per-UDID Runtime singleton 和 live owner invariant。

普通文件操作在活跃进程期间移动/替换app不做保证；所有进程停止后支持移动。`self.install`是唯一例外：
它只能发布到effective UID可信login home下的`Applications/PulsePhone.app`，先在同一父目录完成staging和验证，再对source/target
bundle内已知role的当前UID进程执行start identity、executable provenance与installer PID复核后终止。不得按名称、PID文件或历史快照直接发信号。
旧App与launcher必须保留到新App direct/launcher entrypoint验证完成，失败时恢复；不自动恢复被终止的Live、Trace、Diagnostics或Runtime状态。

### 3.5 签名与 TCC identity

正式分发使用 Developer ID 签名、Hardened Runtime 和 notarization。TCC 授权不能只按 bundle ID 推断；designated requirement 通常同时包含 signing identifier、Team ID 和 Apple signing constraints。相同 bundle ID 但不同 Team/signing identity 不得假定继承授权。

只有长期 GUIHostProcess 调用或申请：

```text
Camera
Microphone
Accessibility / Input Monitoring
CGEventTap
```

CLI mode、DeviceRuntimeProcess 和 HelperProcess 不调用这些 GUI TCC API。移动签名 app 后系统可能保留授权，也可能重新请求；实现必须读取真实 TCC state，不能根据路径或历史结果伪造授权。

### 3.6 项目结构总览

完整规范见第 38 节。第一阶段 repository、build 和 bundle 的关系：

```text
PulsePhone repository
+-- Sources/       Swift executable/library targets
+-- GoHelpers/     Go Direct/CoreDevice helpers and shared protocol packages
+-- Helpers/       legacy Python oracle/source retained outside the release bundle; P2 repository cleanup is deferred
+-- Registries/    normative wire/error registries
+-- Schemas/       command/result/details schemas
+-- Fixtures/      canonical hash and protocol golden data
+-- Tests/         unit/integration/device/performance
+-- Packaging/     plist, entitlements, manifests, licenses
+-- Scripts/       generation, verification and packaging
+-- skills/pulsephone/
|   +-- SKILL.md   portable Agent execution contract
|   +-- agents/    platform-specific metadata source
+-- docs/          current product/technical contracts and non-normative archives
|
+-- .build/        SwiftPM generated
+-- build/         staging/generated reports
+-- dist/
    +-- PulsePhone.app
```

```text
normative registry/schema
  -> explicit generation/update of tracked bindings
  -> verify-generated
  -> SwiftPM build consumes tracked bindings
  -> build/staging/PulsePhone.app
  -> embed skills/pulsephone payload under Contents/Resources/AgentSkills
  -> codesign/notarize/staple
  -> dist/PulsePhone.app + release evidence manifest
  -> skill install publishes one central app plus thin Agent skills
```

## 4. 设计原则

```text
1. 逻辑模块和进程部署是两个维度。
   Shared pure module 可同时链接到 Client 和 Runtime。

2. 静态定义可以共享，mutable device execution state 只能有一个 owner。
   每个 UDID 的唯一 owner 是对应 DeviceRuntimeProcess。

3. Client preflight 只服务 UX，不能成为执行授权。
   Runtime 始终重新权威 planning。

4. 除 LocalDeviceFactsProbe 外，所有设备命令都进入 Runtime。

5. Runtime 识别 CommandID/ExecutionPolicy，但 RuntimeKernel 不写 command-specific 分支。

6. Helper 只负责协议执行，不拥有 Scheduler、ResourceLease 或产品 lifecycle。

7. OneShotJob 与 StreamSession 是不同原语。
   高频 StreamFrame 不进入 CommandQueue。

8. 新需求先归入现有 executionShape 和生命周期。
   未通过 exception gate，不新增平行状态机、队列、结果模型、cleanup path 或常驻进程。

9. 所有外部 I/O 在 RuntimeCoordinationActor 临界段之外执行。
   actor 内先提交 stable boundary，callback 用 identity token 回到 actor。
```

Exception gate 固定要求：

```text
proposed new mechanism
  -> prove local/control/oneShot/stream/hybrid cannot express semantics
  -> identify the unique mutable-state owner
  -> define capacity/backpressure/deadline
  -> define cancellation, cleanup/fencing and exactly-once terminal
  -> define StandardResult/Error and ActionLog projection
  -> define failure isolation and release removal boundary
  -> update Command Matrix, registry, compatibility hash and tests
```

只因 command 名称、backend、iOS 版本或 convenience 不同，不足以建立新机制。差异优先收敛到 CompatibilityRule、CandidatePlan、Executor adapter、schema specialization 或 Client orchestration。

## 5. 模块划分

### 5.1 Client 模块

```text
PulsePhoneCLI
  参数解析、human/JSON adapter、target selection、aggregate orchestration

PulsePhoneGUI
  AppKit、窗口、toolbar、pointer、keyboard、Save Panel、IPA drop

PulsePhoneClientCore
  RuntimeBootstrapCoordinator、RuntimeClient、GUIHostCoordinator、LocalDeviceFactsProbe

PulsePhoneMedia
  AVFoundation video/audio、source binding、frame freshness、metrics
```

### 5.2 Shared pure 模块

```text
PulsePhoneSharedDefinitions
  canonicalUDID、identity、standard result/error、common DTO

PulsePhoneCommandCatalog
  CommandDescriptor、ExecutionPolicy、CompatibilityRule、schemas

PulsePhoneCommandPlanner
  pure authoritative planning logic、CandidatePlan、ResourceClaim materialization

PulsePhoneAvailability
  CatalogCommandList、CompatibleCommandList、EffectiveCommandAvailability

PulsePhoneWire
  RuntimeWire、GUIHostWire、registry-generated codec/validator

PulsePhoneHostPaths
  canonical app path、HostPathLayoutV1、dirfd/no-follow helpers

PulsePhoneDeveloperSupportDefinitions
  DeveloperImageCatalogV1、asset manifest、PreparationGroup、Progress/Result/Status DTO
```

Shared 模块不得拥有设备 I/O、进程管理或 mutable Runtime state。

### 5.3 Runtime 模块

```text
PulsePhoneRuntimeKernel
  Runtime API
  RuntimeCoordinationActor
  DeviceScheduler
  OperationLifecycle
  RuntimeLifecycleController
  ShutdownInhibitorRegistry
  PreparationWaitRegistry
  PreparationCoordinator
  ExecutorRegistry / ExecutorGenerationController
  RuntimeConnectionRegistry

PulsePhoneBackendAdapters
  CoreDeviceExecutor
  DirectExecutor
  DeveloperSupportBackendAdapter
  HelperSupervisor
  error/result normalization

PulsePhoneDeveloperImageAssets
  DeveloperImageCatalog
  DeveloperImageAssetStore
  source resolver / acquisition / validation / extraction / prune

PulsePhoneRuntimeState
  DeviceFacts / Condition / Capability / Geometry
  usbmux connection monitor
  AvailabilityInvalidated

PulsePhoneLogging
  ActionLog / ReplayTrace / DiagnosticLog
```

### 5.4 依赖关系

```text
PulsePhoneCLI -----+
                   +--> PulsePhoneClientCore --> Shared modules
PulsePhoneGUI -----+

PulsePhoneRuntime executable
  +--> RuntimeKernel
  +--> BackendAdapters
  +--> Shared modules

RuntimeKernel -X-> CLI / GUI / AppKit
CommandCatalog -X-> RuntimeKernel / Helper
Helper -X-> Client / RuntimeKernel / CommandCatalog
```

具体 executable 负责依赖注入。RuntimeKernel 定义 Executor 与 DeveloperSupportBackendAdapter protocol，但不构造 concrete implementation。DeveloperImageAssetStore 是 host asset 的唯一 owner；Runtime/Helper 只能通过 catalog identity 和固定 file-role 引用使用 asset。

## 6. 进程模型

### 6.1 角色

```text
CLI ClientProcess
  单次调用，解析参数、选择目标、等待结果后退出。

GUIHostProcess
  长期 AppKit process，可管理多个不同 UDID live 窗口。

DeviceRuntimeProcess
  每 UDID 一个，唯一协调设备执行和 Runtime state。
  `PulsePhoneRuntime --help`是readiness FD和全部Runtime assembly之前的静态早期退出，不构成DeviceRuntimeProcess启动。

CoreDeviceHelperProcess
  每 UDID 最多一个长期 coordinated process，按需存在；执行 modern service、personalized mount/TSS device phase。

DirectHelperProcess
  每 UDID 最多一个 coordinated direct process slot；一进程一个 OneShot；执行 legacy Lockdown/mobile-image-mounter phase。

LocalFactsProbeProcess
  Client 直接启动的短期只读例外；不属于 Runtime generation。
```

### 6.2 per-UDID 拓扑

```text
CLI A -----------+
                 |
GUI live --------+---- /tmp/pulsephone-<E>/<H>.sock
                 |                 |
CLI B -----------+                 v
                           +------------------+
                           | Runtime for UDID |
                           +---------+--------+
                                     |
                         +-----------+-----------+
                         |                       |
                         v                       v
                CoreDeviceHelper          DirectHelper
                         |                       |
                         +-----------+-----------+
                                     |
                                     v
                                  iPhone

GUI video/audio:
GUIHostProcess ---------- AVFoundation/CoreMediaIO ---------- iPhone
```

不同 UDID：

```text
UDID-A -> Runtime-A -> Helper set A
UDID-B -> Runtime-B -> Helper set B

Runtime-A crash must not terminate Runtime-B.
```

### 6.3 live launcher

`pulsephone live` 是短生命周期 local action：

```text
CLI launcher          GUIHost/LiveWindowRegistry            Runtime
    | OpenLive(UDID)            |                              |
    |-------------------------->| atomic reserve               |
    |                           | create placeholder            |
    |<--------------------------| OpenLiveResult                |
    | exit                      | attachLive ------------------>|
    X                           |<------------------------------|
                                long-lived GUI owns live
```

同一 GUIHost 内 reserve/check/create 必须在同一串行域原子完成。跨 app copy 不共享 LiveWindowRegistry；Runtime `attachLive` 是最终单 live owner 安全边界。

## 7. Identity 与设备状态

### 7.1 canonicalUDID.v1

```text
trim ASCII whitespace
ASCII lowercase -> uppercase
preserve existing hyphen positions
require 1...128 ASCII bytes
allow [A-Z0-9-] after normalization
```

```text
canonicalUDID:
  public JSON、排序、socket/lock/log key、Runtime identity

  rawTransportUDID:
  当前 discovery snapshot 内 Go direct/CoreDevice helper 的 usbmux/Lockdown lookup
```

路径 hash：

```text
H = lowercase hex SHA-256(
      "pulsephone.udid.v1\0" + canonicalUDID
    )
```

canonical collision 必须 fail closed，不能选择任意 raw identity。

### 7.2 TargetSelection

默认 eligible：

```text
USB + unique canonical identity + DeviceClass=iPhone
```

按 canonical ASCII byte order 选第一台，再做 command compatibility。target selection 与 command capability 分离。

### 7.3 Snapshot 模型

```text
DeviceFactsSnapshot
  canonicalUDID、name、product type、device class、iOS version/build、USB transport

DeviceConditionSnapshot
  connected、trust、lock、developer readiness、unknown

DisplayGeometrySnapshot
  orientation、logical size、geometryRevision

CapabilitySnapshot
  按 capabilityID 投影 unknown/preparing/available/unavailable(reason)

PreparationStatusSnapshot
  按 preparationGroup 投影 phase/progress/source/error/attempt identity

connectionEpoch
  Runtime connection/attachment generation；不属于 DeviceFacts 本体
```

Device/condition/capability/preparation snapshot 第一阶段只在进程内存中保存，不写作权威状态文件。DeveloperImageCatalog 与已完成 asset 属于独立的 host 持久化合同，不是设备 snapshot。

Runtime 拥有执行时权威 snapshot。LocalDeviceFactsProbe 只生成本次 UX/preflight view，不能替代 Runtime planning。

### 7.4 Availability

```text
CatalogCommandList
  只看静态 Catalog。

CompatibleCommandList
  Catalog + local DeviceFacts 三值 compatibility。

EffectiveCommandAvailability
  Runtime facts/condition/capability/preparation/geometry/quiescing revisions。
```

Runtime 只在以下 revision 改变时广播 `AvailabilityInvalidated`：

```text
connection / condition / capability / preparation / geometry / quiescing
```

queue、active lease 和瞬时 resource contention 不广播 availability，也不固化为 toolbar disabled。
