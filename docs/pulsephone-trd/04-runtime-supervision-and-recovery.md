# PulsePhone TRD 04 - Runtime 监督与恢复

> 文档状态：第一阶段规范章节
>
> 上级文档：[`pulsephone-trd.md`](../pulsephone-trd.md)
>
> 负责范围：第 19～20 节；Runtime bootstrap、singleton、generation fence、orphan recovery、USB detach/attach 和 fatal fail-stop。

本章持有 Runtime 进程监督和恢复合同。通用 lifecycle 由 TRD 02 持有；Developer Support attempt 由 TRD 03 持有；Wire/Helper 互操作由 TRD 05 持有；Product Action 调用关系由 TRD 06 持有。

## 19. Runtime 启动、单例与 generation fence

### 19.1 Host locks

每 UDID 两级锁：

```text
bootstrap.lock
  串行化 Runtime spawn、replacement、orphan recovery、stop/retire completion。

runtime.lock
  per-UDID singleton 和 coordinated Helper generation fence。
  Runtime 从任何设备 I/O 前持有到退出。
  Helper 继承同一 locked open-file-description。
```

两个 lock 文件均使用稳定 inode，创建后永不 unlink、rename 或 replace。stale cleanup 只删除 socket。

`runtime.lock` 使用 `flock(LOCK_EX|LOCK_NB)`。在 bootstrap 原子区内仍得到 `EWOULDBLOCK` 时，新 Runtime 返回结构化 startup failure，不自行执行第二套 recovery。Runtime 必须先取得 lock，才读取 device facts、spawn Helper 或执行任何设备 I/O。

### 19.2 冷启动

RuntimeBootstrapCoordinator 必须从当前 bundle 精确解析 `Contents/Helpers/PulsePhoneRuntime`，使用原生 spawn API，不经 shell/PATH；child cwd 固定为 `/`，stdin/stdout/stderr 不继承短生命周期 CLI terminal。

```text
Client                    BootstrapCoordinator             Runtime
  | acquire bootstrap.lock        |                          |
  |------------------------------>| recheck socket/lock      |
  |                               | spawn bundle Runtime ---->|
  |                               |                          | flock runtime.lock
  |                               |                          | bind/listen socket
  |                               |<---- readiness pipe -----|
  |<------------------------------| ready / failure          |
```

Runtime startup deadline 5 秒，只覆盖 coordinator readiness，不包含 Helper/tunnel preparation。

Runtime readiness pipe 使用 FD 3，Runtime exactly once 写 `ready(runtimeEpoch,pid)` 或 `failed(StandardError)` 后关闭。

startup timeout 只终止本次刚创建、尚未 ready 的 Runtime并释放 bootstrap.lock；不得重新运行 orphan recovery，也不得 signal 其他 generation。

### 19.3 socket identity

Runtime 在 ready 前记录 socket `st_dev/st_ino/owner/type`，并 event-driven watch base directory。ready 状态下 socket 缺失、被替换、identity 不匹配或 watcher 失效时进入受控 fail-stop。

目录变更事件只触发对本 Runtime expected socket 的 `lstat`/identity recheck；其他 UDID 文件变化不得误触发退出。不使用 polling 或 heartbeat替代 vnode watch。watcher setup失败属于startup failure。

正常 quiescing 必须先原子设置 `expectedSocketRemoval=true`，停止 admission，再取消 watcher和 unlink 自身 socket。

### 19.4 Helper generation fence

Runtime-managed Helper：

```text
FD 0  Runtime -> Helper HelperWire
FD 1  Helper -> Runtime HelperWire
FD 2  stderr diagnostic
FD 3  lifetime Pipe read end
FD 4  inherited runtime.lock FD
other FD closed/CLOEXEC
```

每个 Helper 使用独立 process group。Runtime 必须先取得 Helper process start identity，并把该 Helper 原子写入 `helpers.v1.json`，之后才能发送 `HelloAccepted`；Helper 在收到该 Ack 前不得执行设备 I/O。

Runtime hard crash 后：

- Helper 通过 lifetime Pipe EOF 执行 cleanup/exit。
- 只要任一旧 Helper 仍存活，runtime.lock 仍 busy。
- 新 Runtime 不得开始设备 I/O。

### 19.5 helpers.v1.json

```text
schemaVersion
runtimeEpoch
canonicalUDIDHash
ownerUID
runtimePID / runtimeProcessStartIdentity
helpers[]:
  helperID
  role / executorID
  executorGeneration
  pid / processGroupID
  processStartIdentity
  executablePath
```

文件位于已验证 Runtime base，mode 0600，使用 temp + fsync + atomic replace；每次读取校验 owner、regular-file、no-symlink、runtimeEpoch 和 canonicalUDIDHash。

metadata 是恢复线索，不替代 runtime.lock。缺失、尾部损坏、PID reuse、owner/path/token 不匹配时不得按进程名猜测或 kill。DeveloperImage progress、partial、PID 或 observer 文件同样只用于观察，不表示 acquisition ownership；host-wide/per-asset `flock` 才是权威 owner。

### 19.6 orphan recovery

```text
socket absent + runtime.lock busy
                |
                v
validate old Runtime identity
       | alive                         | gone
       v                               v
wait controlled exit <=10 s      validate helpers[]
no signal                       graceful cleanup
       |                         SIGTERM verified set
       |                         SIGKILL verified survivors
       +------------+------------+
                    v
             confirm lock free
                    |
          +---------+---------+
          |                   |
   activation path        stop path
   spawn new Runtime      no spawn
```

identity 无法验证、signal 失败或 lock 未释放时返回 `orphanHelperGenerationBusy`。第一阶段不增加常驻 guardian。

Runtime 死亡只表示该 Runtime 的 acquisition owner claim 消失。新 Runtime 取得权威 asset lock 后可验证并接管完整 asset，或从受控 partial 恢复；不得根据旧 progress 状态等待并不存在的 owner。旧 `preparationAttemptID` callback 永远不能恢复新 Runtime 的状态。

## 20. USB 断连、重连与 fatal

### 20.1 Detach

Runtime 持有轻量 usbmux monitor，并按exact canonical UDID把inventory变化串行化到
per-device connection coordinator。Helper不监听USB inventory，也不发布权威
detach/attach；Helper执行中的`DeviceDisconnected`、`transportLost`或IPC/process
终止只能作为提前停止旧generation派发并主动确认inventory的辅助信号。USB monitor
确认的current inventory是连接状态authority，重复、乱序或与current state相同的
通知必须幂等忽略。

Detach 同一 UDID：

- connected=false，记录并fence刚刚失效的current connection epoch；detach期间不
  预分配新epoch，也不把无物理连接状态伪造成一个可执行connection generation。
- invalidate condition/capability/geometry 和连接代 facts。
- 依赖旧 connection epoch 的 PreparationWaitRegistry command waiter、PrepareObserver和全部`epochBound` demand得到一次有界terminal并删除；pending OneShot终止为`deviceDisconnected`。
- 当前 device preparation phase 取消并释放 phase-scoped ResourceLease；对应 attempt 以旧 `preparationAttemptID` fenced。
- 已开始的 host asset acquisition 在仍有 acquisition owner 时继续；它不持有 device ResourceLease，也不因 detach 自动取消。
- running OneShot 不强制 cancel，等待 Helper terminal 或 execution deadline。
- active Stream cancelAndClean。
- Executor generation 进入 draining。
- live ownership、`liveOwnerID`和`subscriptionID`保留；旧capture activation与
  observation projection失效。
- 向仍连接的Client先后投递引用旧epoch的`deviceDisconnected`、相应
  `availabilityInvalidated`和`ObservationStreamReset`。前两者负责控制状态与
  snapshot重同步，reset只清除presentation projection；不得新增平行的USB事件
  schema。
- GUI 停止旧 video/audio、清除帧和 overlay、显示身份占位。

### 20.2 Attach

Attach 同一 UDID：

- 保留 RuntimeProcess、socket、Scheduler、live owner、`liveOwnerID`和
  `subscriptionID`。
- 只有从confirmed detached变为exact canonical UDID confirmed attached时，才从
  上一个已失效epoch递增一次并建立新的connectionEpoch。同一detach/reattach
  episode中的重复attach通知不得再次递增。
- 重新获取 facts/condition。
- 旧 Helper/tunnel/service 永不复用。
- 等旧 generation terminal + shutdown/wait/fence 完成。
- 只在仍有live owner的`persistentAcrossReconnect` live prewarm demand，或attach后新收到的explicit/implicit demand存在时启动新preparation；旧explicit prepare和finite command均为`epochBound`，不得恢复。plain attach不下载DDI、不mount、不无条件创建tunnel/Helper generation。
- current facts/condition和state revision提交后发送既有`availabilityInvalidated`；
  Client通过`runtime.getAvailabilitySnapshot`取得新epoch。没有`deviceConnected`或
  reconnect专用event kind。Client保留原owner/subscription并原子替换本地
  LiveAttachment的connectionEpoch/stateRevision；旧capture activation不能在新
  epoch重放，必须由新identity-valid sample建立新的activation。
- video source 独立重新绑定。允许读取当前Mac上该target的operator-confirmed mapping cache作为sourceID提示，但必须重新枚举current inventory、采用新的sourceEpoch、等待新有效帧与current geometry，并绑定新的connectionEpoch；不得持久化或复用旧connection/source/geometry epoch。
- 新capture session从首个identity-valid sample重新建立session-local formatRevision和normalized shape；旧session的presentation、candidate、debounce timer、fullscreen callback或geometry proposal全部失效，不得跨reconnect提交或作为新source proof。
- cache缺失、损坏、version/domain不兼容、sourceID不存在/不唯一、capture失败或inventory变化时只恢复identity placeholder与source picker，不阻止同target control恢复，也不自动选择其他source。

```text
Attach
  +--> active demand -> preparation -> Helper generation -> capabilities
  |
  +--> GUI video recovery ------> AV source -> target/epoch binding

two paths converge only in presentation, not in lifecycle ownership
```

### 20.3 transport loss classifier

```text
Helper crash / framing corruption
  -> immediate fatal fail-stop

transportLost
  -> suspectDisconnect
  -> wait matching Detach <= 500 ms / actively confirm device
       +-> device gone: disconnect lifecycle
       +-> device present at deadline: fatalTransport -> fail-stop

expected shutdown
  -> normal draining/terminating/retired
```

Helper辅助信号和USB monitor命中同一次物理detach时只进入一次disconnect
lifecycle；先到的Helper信号不得自行递增epoch，后到的monitor通知也不得重复清理、
重复terminal或重复退休generation。

### 20.4 fatal fail-stop

fatal path：

```text
set terminationCause + enter quiescing atomically
  -> reject new external work
  -> terminal pending/PreparationWaitRegistry waiters/PrepareObservers
  -> clean/fence running OneShot and Stream
  -> release this Runtime's acquisition/preparation owner claims
  -> terminate all executor generations
  -> finalize ReplayTrace incomplete
  -> complete/handoff controlMutation cleanup
  -> release all inhibitors
  -> unlink socket
  -> exit nonzero and release runtime.lock
```

第一阶段不建立 dirty-generation marker、write-ahead journal、persistent command queue 或跨 Runtime result recovery。Runtime crash 后，旧 pending/running work 不恢复、不自动 replay；mutating device-side outcome 无法证明时固定为 outcomeUnknown，由用户决定是否再次执行。

Runtime 不通过立即 SIGKILL 自身跳过 Helper cleanup。

GUI 收到 fatal/EOF 时保留正确绑定的视频，清理 Stream/overlay，禁用 Runtime-backed command，并在一个 recovery episode 中调用一次 `ensureRunning`。失败后不定时 crash-loop。
