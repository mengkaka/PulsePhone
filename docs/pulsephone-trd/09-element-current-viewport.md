# PulsePhone TRD 09 - Current-Viewport Element Snapshot

> 文档状态：第一阶段规范章节
>
> 上级文档：[`pulsephone-trd.md`](../pulsephone-trd.md)
>
> 负责范围：第 43～48 节；SnapshotFrame、capture provider、视觉 analyzer、融合/矫正、Element result、生命周期与验证。

本章只持有当前选定的被动视觉 element snapshot 工程合同。公开产品行为由 PRD §8.9
持有；Command execution profile 由 TRD 02/06 持有；RuntimeWire 与 PNG `ArtifactFD` 分别由
TRD 05/07 持有；精确 input profile、融合参数和 schema hard cap 由版本化配置、schema、代码
guard 和测试持有。

## 43. 能力与 Ownership

第一阶段只有一个公开 Element Product Action：`element.snapshot`。它是 CLI hybrid action，
Runtime 完成 target-bound capture、三路分析、融合、矫正和 generation 发布；CLI 只负责参数
preflight、可选输出路径的 no-clobber preflight、接收标准结果/可选 PNG FD，以及本地原子写入。

```text
CLI root element.snapshot
  -> Runtime command.submit
  -> immutable SnapshotFrame
  -> parallel analyzer barrier
  -> fusion + local correction
  -> exactly one published generation
  -> StandardResultV1
  -> optional read-only annotation PNG ArtifactFD
  -> Client atomic output publish
```

Runtime 是 per-UDID snapshot generation、device capture 和 analyzer lifecycle 的 owner。Helper
只承载已有设备截图 transport，不识别元素、不持有 analyzer，也不接收用户 output path。
OmniParser 是部署方独立维护的常驻服务；Runtime 只持有 persistent client、health、deadline 和
circuit state，不启动或终止模型服务。

macOS Vision analyzer 位于 Runtime 进程内的专用 actor/串行 queue。Apple private region
analyzer 位于 Runtime 监督的隔离常驻 host worker；worker crash、selector drift 或 framework
不可用只能使该分支降级，不能终止 Runtime。两者都是主机能力，与 Xcode 和 iPhone Helper
无关。

当前公开 CLI 不依赖 GUIHost 存在，也不跨进程读取 GUI frame。GUI-local 或未来同进程高层 API
可以把已绑定 Live sample 作为同一 `SnapshotFrame` contract 的 provider；CLI/Runtime 使用
device capture provider。禁止用共享临时 PNG、窗口截图或陈旧缓存猜测 Live 状态。

## 44. SnapshotFrame 与 Capture Provider

`SnapshotFrame` 是一次查询的不可变图像 authority，至少绑定：

```text
canonicalUDID
runtime/connection/source epoch as applicable
geometry revision and orientation
capture generation and provider sequence
query fence, capture monotonic timestamp and frame age
pixel dimensions and logical dimensions
provider identity
read-only source image lease
```

metadata selection 必须在任何 decode、encode、resize 或颜色转换前完成 target、epoch、freshness
和 geometry 校验。并行 analyzer 生命周期内 source image lease 保持有效；release 不在
AVFoundation callback/MainActor 上阻塞。每种 derived image 由 `(frame generation, profile ID,
dimensions, color space, encoding)` single-flight 缓存，并携带 source-to-input 与 inverse transform。

查询建立最低新帧 fence：采用的 frame sequence 必须大于 query 开始时的 baseline，capture 时间
不得早于 query fence。内部调用可附带 `afterActionID`；该 ID 必须先在同一个 Live provider 和
exact authority 下注册，注册时原子记录最新 accepted sequence 与有效 visual fingerprint。当前
`live-visual-settlement.v1` 以 normalized fingerprint difference `30/1000` 判定首次显著变化，随后
以 `10/1000` 稳定阈值等待连续 `120 ms`，整体 deadline 为 `1.5 s`。稳定结果标记
`stableAfterVisualChange`；deadline 内没有变化时只返回 query 后的最新可信 frame 并标记
`unchangedAtDeadline`，没有 query 后可信 frame 则失败。action 最多保留 `30 s`，每个 provider
最多注册 `64` 个；cancel、retire、stall 或 authority change 必须移除 waiter 或使 action 失效。
该机制只证明 Live visual sample 的变化与稳定，不能声明 app idle 或 XCTest 等价。CLI 第一阶段
不公开该参数。

Live provider 只读取 owning process 已接受且 target/source epoch 匹配的最新 sample，不启动第二个
capture session。frozen、withheld、reconfiguring、identity unbound 或超过 freshness cap 的 sample
不能建立 current viewport 证明。

device provider 按 target OS 和 capability 从以下已注册路线选择：

```text
iOS 17+  persistent DVT takeScreenshot when registered and ready
         -> generation-owned CoreDevice RSD tunnel + per-capture ScreenCaptureService channel
         -> persistent bounded AXAudit device screenshot fallback

iOS 14-16 existing mobile.screenshotr route
```

iOS 17+ Element device capture 使用同一 personalized DDI、RSD tunnel 和 CoreDevice generation。
generation 持有 persistent RSD tunnel；每次 CoreDevice capture 在该 tunnel 上新建、调用并关闭一个
`ScreenCaptureService` channel，禁止对同一个 channel 发起第二次 capture。DVT provider/screenshot
channel 可在 generation 内持久复用，并固定调用
`com.apple.instruments.server.services.screenshot` 的 `takeScreenshot`。同一 helper generation 另持有
lazy persistent AXAudit USB lockdown/audit session，固定调用 `deviceCaptureScreenshot`，使用已有 pairing
且禁止自动配对。该 session 的 lifecycle/health 与主机侧 Apple region detector worker 完全独立。
公开 screenshot CLI/GUI 只使用各自既有 provider，不能请求 DVT/AXAudit fallback 链。

Element 的现代 capture 顺序固定由 Runtime 发送 `dvt -> coreDevice -> axAudit`。三次尝试共享同一个
per-generation capture lock 和同一个尚未发布的 ArtifactFD reservation：任一 provider 成功立即停止；
只有在任何 artifact byte 发布前发生 service open、capture 或 response validation failure，才允许尝试
下一 provider。fallback 成功只写入一次最终 PNG，并在 Result 发送后退休已发生 fatal provider failure
的 helper generation；下一个请求不能复用正在退出的 helper。AXAudit 对 selector response 做有界遍历，
只接受不超过 64 MiB 的 PNG/JPEG，JPEG 复用统一 PNG normalization。最终 provider 失败、request
cancellation、connection/generation replacement、detach 和 Runtime stop 必须关闭各自 channel/session，
并拒绝迟到结果。

每个现代 provider attempt 使用独立的 monotonic total deadline，覆盖旧 channel 的必要关闭、service
open、capture、response validation 和 one-shot channel 的必要关闭。各 attempt deadline 与失败清理上限
之和必须小于 Element capture 的 absolute deadline；精确数值由版本化内部 policy 和测试唯一持有。
任一阶段超时都按当前 provider 的失败 attempt 记录，归一化到当前 `serviceOpen|captureOrValidate`
阶段，并在尚未发布 artifact 时继续既定 fallback。超时或取消必须先从可复用状态移除该 channel/session，
再执行有界 close/cancel；cleanup 不响应时不得无限等待，也不得让迟到结果恢复或复用已污染的 service。

Helper success 必须携带严格有界的 attempt trace。Runtime 只接受
`dvt`、`dvt -> coreDevice` 或 `dvt -> coreDevice -> axAudit` 的完整前缀，且只允许末项成功；
实际 provider 必须等于最后成功 attempt。每个 attempt 包含
`queueWait/serviceOpen/capture/serviceClose/total` 微秒、稳定错误码和归一化失败阶段
`serviceOpen|captureOrValidate`。字段缺失、额外字段、错序、非末项成功、provider/stage 不匹配或任一
timing 超过 30 秒都在 artifact acceptance 前 fail closed。legacy screenshotr 不携带现代 attempt trace。

每个 Runtime 的 per-UDID device capture coordinator 同时最多运行一个物理 capture producer。只有
target identity、完整 capture-time geometry（含 connection epoch/revision/orientation）、有序 provider
plan 全部相同，且 producer 实际开始 capture 的单调时间不早于每个请求自己的 query fence，多个并发
请求才可加入同一个 in-flight producer。不兼容请求在自己的单调 absolute deadline 内串行等待；deadline
后不得启动新 capture。completed capture 不作为后续请求的 cache。

共享范围只包含 producer 返回的不可变 source bytes、geometry、实际 provider 和 attempt trace。每个
请求仍独立分配 snapshot generation/frame sequence，独立执行 analyzer/fusion/correction，并持有自己的
owner、deadline、result 和 optional annotation artifact。单个 waiter cancel/deadline 只移除该 waiter，
不能取消其他 waiter；最后一个 waiter 离开时必须取消并 join producer cleanup。producer failure 一致传递
给已经加入的 waiter，迟到结果不能恢复已取消请求或进入后续 capture。provider 只有在尚未发布 source
frame 时可 fallback；fatal service error 退休 owning generation，但已经返回 coordinator 的不可变 bytes
仍可由已加入 waiter 消费。一次查询最终只允许一张 source frame。

查询期间 target/epoch/geometry/orientation 改变时丢弃全部 analyzer 结果，并最多以新 authority
重试一次。仍不稳定则失败，不发布混合坐标。

## 45. Analyzer 生命周期与并行 Barrier

三个 analyzer 必须从同一个 `SnapshotFrame` 同时 fan-out，并各自使用版本化 input profile：

- OmniParser 使用有界最长边的派生图、persistent HTTP keep-alive client 和 inverse transform。
- Vision 直接消费原始 `CVPixelBuffer`/`CGImage` 或 device PNG 的单次 decode 结果，不做 PNG
  round-trip 或全局缩放。
- Apple region worker 使用独立有界派生图，并只返回 region hint，不返回或伪造 AX element。

精确尺度、模型版本、Vision recognition 配置和 Apple selector capability 只在单一 versioned
configuration 中定义；analyzer 实现不得复制常量或运行时静默换 profile。每个 result 必须返回
实际 source/input dimensions、profile/version、backend、queue/inference elapsed 和 inverse
transform identity。

每路 analyzer result 还必须包含 `stageTimings`，以微秒记录
`resizeAndColorSpace/inputEncode/requestEncode/transportRoundTrip/transportOverhead/responseDecode`。
当前实现无法独立测量的阶段返回 `null`；明确不适用于 Vision 原图进程内调用的派生图、request
encode 和 transport 阶段返回 `0`。`transportRoundTrip` 包含远端服务或 worker 执行时间，
`transportOverhead` 只能由该 round-trip 减去可信的 server/worker total 得出，且不得大于
round-trip；两者不得同时累加为端到端时长。device PNG 在建立共享 `SnapshotFrame` 时只强制 decode
一次，其 `sourceDecodeMicroseconds` 只记录在 pipeline `timings`，不得重复归入各 engine。

Vision 与 Apple worker 都按 Runtime epoch lazy single-flight initialize/prewarm。并发首批请求共享
同一个 initialization future；后续请求复用 warm state。Runtime restart、worker crash、版本或
asset 变化和 circuit recovery 可以重新初始化，但必须递增可观测 restart/reinitialization count。
禁止 per-command process spawn。

Vision production policy 固定为 macOS `Vision.framework` 的 `VNRecognizeTextRequest` revision 3、
`.accurate`、`zh-Hans` 后接 `en-US`、language correction 开启、automatic language detection 关闭、
minimum text height `0`、空 custom words。prewarm 必须先验证主机支持所需语言并执行一次真实空白
image request；同一 Runtime 内并发首次调用共享该 future，失败可重试且 attempt/success/failure
分别计数。warm query 为每张原图创建新的 request/handler，避免复用含 result/cancellation 状态的
`VNRequest`，同时复用进程内 framework/model warm state 和 actor 串行执行边界。Runtime shutdown
取消并 join 未完成 prewarm，之后该 analyzer 只返回 unavailable。

Vision 识别正文只可作为显式 Element result 的 `label`，并标记 `labelSource=vision`；最多
1024 UTF-8 bytes。正文不得参与 snapshot ID、tracking ID、日志、trace、diagnostics、metrics 或默认
artifact retention。默认 JSON 可以返回该 label；annotation 只绘制几何边框，不新增 OCR 持久化。

Apple region host worker 固定使用 `apple-region-worker.v1` binary-plist frame protocol 和
`macos-private-image-region` backend identity。worker 启动时只创建一次 bridge：加载所需 private
framework、验证 class/availability/shared-manager/detection selector，保留同一个 manager，并用有界
真实 image request 校验 assets 与 return shape；任一失败返回 unavailable，不进入 detect。Runtime
只接受 exact backend/version hello，版本漂移或额外/缺失 message 字段在发送业务 image 前 fail closed。

同一 Runtime epoch 的并发首批 Apple 调用共享一个可取消 waiter 集合和唯一 worker startup；取消尚未
占用 detect I/O 的 waiter 不退休共享 worker，取消 active detect 才终止并重建隔离进程。每个 request
使用递增 ID，response 必须 exact echo、成功或带 bounded error code，并限制 16 MiB image、16384
dimension、2048 regions、1 MiB response 和 60 秒内部 timing。合法零 regions 是成功空结果；非有限、
非正面积或超出 input bounds 的 region 是 malformed failure，不能裁剪成合法候选。

worker crash、timeout、malformed result 或 private exception 只退休 Apple worker，不影响 Runtime、
OmniParser 或 Vision。默认连续三次 worker/protocol failure 打开 Apple-only circuit 30 秒；half-open
重新执行完整 startup/self-test，成功后清零 failure 并递增 initialization/restart count。Runtime
shutdown 取消并 join startup/detect，关闭 pipe、终止并 reap process；shutdown 后 analyzer 只返回
unavailable。

OmniParser 默认未配置并保持 disabled；此时 element snapshot 不创建 HTTP client，也不发送截图到网络
服务。endpoint 由唯一 `OmniParserEndpointConfiguration` 解析：一次性环境变量
`PULSEPHONE_OMNIPARSER_ENDPOINT` 优先于 PulsePhone 受控 Application Support 配置文件。公开 CLI 使用
`PulsePhone config --help` 枚举允许 key，并使用 `PulsePhone config get|set|clear omniparser.endpoint` 查询或
修改该持久化值。所有 endpoint 在 Runtime 创建时完成
scheme、host、length 和 credential 校验；已运行 Runtime 保持启动时的配置，后续 set/clear 只作用于新建
Runtime。diagnostics 只记录脱敏 host、config source、network scope 和 TLS 状态，不记录 credential、query
或完整 URL。

OmniParser production HTTP 合同固定为 `POST /parse/`。该接口不定义 GET application readiness；
client 不发送预检请求，也不从 HTTP 405、推测的 device/backend 或阈值回显构造 capability。单次
可用性只由 POST transport 和下述严格响应校验确定。

client 向 `/parse/` POST strict JSON：`base64_image` 是 longest-edge 1280、sRGB PNG 的
base64；`response_mode="json"`，`box_threshold="0.05"`，`iou_threshold="0.7"`。request body 不携带
UDID、bundle ID、OCR 内容或目标 endpoint 以外的身份。response 只接受 `latency` 与
`parsed_content_list`；latency 是有限、bounded 秒数，每项只包含 `bbox/content/interactivity/source/type`。
`bbox` 必须是四个有限数，满足 `x1 < x2 && y1 < y2`。client 把该归一化 rect 与
`[0,1] x [0,1]` viewport 求交：正面积交集裁剪后继续解析，完全不相交的 row 忽略。字段结构/类型
错误、非有限坐标或无序 bbox 仍使整个 response invalid；不得把这些错误修造成候选。
content/source/type 有长度和 UTF-8 上限，interactivity 必须为 Boolean，items 不超过 2048。只把 `type="icon"` 或
`interactivity=true` 的项投影为 control candidate；非交互 text 行不进入 Omni control 集合，Vision
仍是可见 label 首选。该协议没有 confidence，结果必须保留 `confidence=null`，不得用 threshold、
interactivity 或 source 字符串伪造。归一化 bbox 先转换到派生图 top-left pixel rect，再只经该 profile
的 inverse transform 还原 source pixels。

未来服务可以另外实现 versioned detector-only capability/request/response，以提供 model/version、
backend、request echo、preprocess、分段 timing 和 confidence；client 只有在显式选择增强模式、完整
协商并严格验证该协议时才能使用这些增强字段。增强 capability probe 不是 production POST 的前提，
也不能令 `/parse/` JSON 协议变为 unavailable。

同一 Runtime-owned Omni client generation 复用一个 ephemeral keep-alive `URLSession`，每个 host
最多一个连接且最多一个 detector request in flight；并发调用有界排队，queue wait 包含在分支
deadline 内。session 禁用 cookie、credential store、cache 和 proxy dictionary，拒绝 HTTP redirect，
并拒绝 TLS server-trust 默认处理以外的 authentication challenge。production 协议没有 application
readiness cache；response failure 或 circuit recovery 不切换协议，也不增加 GET 预检。
派生 PNG 最大 16 MiB、本地 JSON request 最大 24 MiB、response 最大 4 MiB、item 最大 2048。
默认 request timeout 为 8 秒；连续三次 transport/protocol failure 后同一 generation circuit 打开
30 秒，恢复后的下一次请求仍直接 POST。64 KiB probe cap 只适用于未来显式增强协议。
Runtime shutdown、配置变化和 generation retirement 必须取消请求、唤醒排队者并关闭 connection
pool；外部服务进程不由 Runtime 启停。

每个启用分支必须以以下 terminal state 之一到达 barrier：

```text
succeeded | timedOut | unavailable | failed | circuitOpen
```

成功但零 candidate 是合法结果。单路失败不取消其他分支；whole-request cancellation 取消或丢弃
全部迟到 callback。fusion 只有在所有启用分支 terminal 或 whole budget 到期后开始；已发布
snapshot 不接受迟到结果原地修改。

默认 whole analyzer budget 为 10 秒；OmniParser、Vision、Apple 分支 deadline 分别不超过 8、3、
2 秒，fusion/correction budget 不超过 1 秒。deadline 均为 monotonic absolute deadline，包含 queue
wait 和预处理，但不包含 Runtime epoch 的一次性 prewarm。稳定 warm 请求仍必须记录实际分层耗时，
不能以 deadline 作为性能目标。

`element snapshot` 另有覆盖 capture、Runtime epoch 首次并行 prewarm、analysis、correction 和可选
annotation 的 monotonic outer safety deadline：JSON 为 27 秒，含 annotation 为 32 秒。其中 15 秒只
为首次 prewarm 预留；它不得放宽 capture provider 的 `3/4/3 s`、analyzer 的 `8/3/2 s`、whole
analyzer 的 10 秒或 correction 的 1 秒内部 deadline。outer deadline 仍早于 CLI 60 秒 receive
deadline，命中时必须取消并 join 当前 request，不能发布迟到 snapshot。Runtime epoch 内后续请求复用
Vision context 和 Apple worker，不重复消费该初始化成本。

至少一路 analyzer `succeeded` 且 frame 仍可信时发布 snapshot。存在任一路非成功时
`degraded=true` 并列出 engine health；三路均非成功时 whole action 失败。circuit 按
engine/profile/version 隔离，一路故障不得打开其他 circuit。

## 46. 坐标、融合与局部矫正

所有 analyzer box 先通过自己的 inverse transform 还原到 `SnapshotFrame` top-left source pixels，
再 clip viewport、验证有限数值和正面积。fusion 以版本化 policy 执行 overlap/containment、
跨来源 evidence 合并、OCR group suppression 和可信 nested-box retention。文字 evidence 可以提供
可见 label，但不能把 control candidate 变成 button，也不能成为 identifier。

默认 fusion policy 使用 Omni confidence `0.10`、control minimum `18 px`、跨来源 merge `0.72` 和
nested area ratio `0.65`。Vision OCR 分别覆盖至少两个 Omni control 的自身面积达到 OCR frame 的
`0.15`，且这些相交区域的 union 达到 OCR frame 的 `0.60` 时，只有在命中项剔除包含其他命中项的
container 后仍有至少两个彼此重叠不超过较小项 `0.20` 的同级 control，才抑制该 OCR group；空白分词
数量与 control 数量相等时按主轴视觉顺序把 label 分配给尚无 label 的 control。该规则不得折叠
container/child control，也不得删除其层级证据。

Apple region 与 control 的 overlap score 达到 `0.45` 时作为该 control 的来源证据，不另建重复 region。
一个 Apple region 恰好桥接两个垂直对齐、水平相邻且互相重叠不超过较小项 `0.20` 的 control，并且
其中一个无 label、另一个只有十进制数字 label 时，可合并为一个 icon+counter control；nested、两个
都有 label、两个都无 label 或间距越界的候选不得使用该规则。所有 consolidation 在 source pixel 中
按固定 analyzer 顺序执行，最终仍按 canonical geometry 顺序输出。

局部 geometry correction 是 fusion 后的确定性图像处理，不是第四 analyzer，不运行无 candidate seed
的全屏 contour search。它包含两个独立阶段：

1. `oversized-parent-decomposition` 只对 versioned safety predicate 命中的过大 parent 读取局部 source
   pixels；必须有 child evidence、局部 component 数量/面积/尺寸 cap，质量规则允许时才替换 parent。
2. `existing-frame-refinement` 以已有非 Omni candidate 为 seed，在 bounded expanded crop 内寻找与 seed
   相交或包含 seed center 的稳定 foreground component。只有 local border/background、contrast、
   containment、area-growth、aspect、distance 和 viewport clip 全部通过时，才可用 component rect 细化
   原 frame。refinement 必须保留 seed 的 `text|controlCandidate|unknown` 类型，不得根据 component
   尺寸或形状推断 interactivity；它不得改写含 OmniParser source 的可信 control frame，不得删除
   label/source attribution。

两个阶段逐项 fail-open-to-original：条件不满足、没有唯一可信 component、纹理/低对比背景、处理失败
或最终数量超过 cap 时保留原 candidate。新增或替换的 geometry 追加 `localGeometry` source；仅追加
source 却不改变 geometry 不计为 refinement。所有参数由版本化 policy 固定，并以 source-pixel rectangle
执行确定性排序。

每个 snapshot 只准备一次 grayscale source，所有 parent/seed crop 复用该 source；单个 crop 最长边
不超过 512 pixels，每帧最多处理 8 个 parent 和 64 个 refinement seed。两个阶段共享
`4,194,304` rasterized-pixel work cap 和从 correction 开始计算的 1 秒 monotonic deadline；按确定性
顺序耗尽任一预算后，尚未处理或处理中未形成完整可信 component 的 candidate 保留原 geometry。
结果必须记录真实 correction elapsed，不得 clamp 到 1 秒；result builder 使用独立的异常数据安全上限，
不得把性能目标越界转换成 schema/internal failure。

最终 geometry 只由融合后的 source-pixel rectangle 派生：

```text
frame.pixel          source screenshot top-left coordinates
frame.logicalPoints  capture-time logical display coordinates
frame.normalized     [0,1] current visual presentation coordinates
center.*             exact center of the same final frame
```

logical/normalized projection 使用 `SnapshotFrame` 捕获时的唯一 geometry authority。Element 层不
再次旋转、交换轴或读取稍后的全局 orientation；`center.normalized` 可原样作为现有 visual tap 输入。

每次成功发布递增 `snapshotGeneration`。`snapshotID` 只在本 generation 内稳定，由量化 geometry、
source attribution 和确定性 collision suffix 生成，不包含 OCR 正文。optional `trackingID` 只是
跨帧 best effort；target/epoch/geometry/layout 无法可靠关联时必须换 ID。第一阶段只返回 viewport
metadata 和 flat element array，不推测 UIKit/SwiftUI hierarchy。

## 47. Result、CLI 与 Annotation Artifact

公开 grammar 固定为：

```text
PulsePhone element snapshot [--udid <UDID>]
  [--format json|annotated|both]
  [--output <PNG_PATH>]
  [--force]
```

`json` 是默认格式并直接使用 JSON terminal envelope；`--json` 在 `json|both` 下幂等。
`annotated` 成功时 stdout 为空；`both` 写 PNG 并返回 JSON；`--format annotated --json` 在任何
capture 前以 `invalidArgument` 失败。`annotated|both` 要求 output，`json` 禁止 output/force。
目标存在时 fail closed，只有 `--force` 允许替换。

CLI 在 Runtime 请求前执行 output path/no-clobber preflight。Runtime 只在 `annotated|both` 下对最终
fusion/correction result 中的 `controlCandidate` 绘图，并发送 exactly one owner-only、read-only、
validated PNG FD；JSON 始终保留完整 final element array，JSON 路径发送零 FD。Client 用同目录
`0600` 临时 regular file 执行 write/fsync/close/atomic rename，失败
清理自己拥有的临时节点。PNG 不写 stdout，不使用 base64。

`both` 的 JSON annotation metadata 和 PNG FD 必须绑定同一 requestID、artifactID、
snapshotGeneration、capture SHA-256 和 dimensions。Runtime 先原子预留 `ArtifactFD + Response`
两个 final/control frame，按 FD 后 Response 顺序发送；failure Response 固定零 FD。Client 在收到
匹配 success Response 前暂存 FD，mismatch/failure/EOF 时关闭。

Runtime annotation metadata 不包含用户 output path。Client 只有在 owner-only 临时文件成功
fsync/close 并原子发布到最终路径后，才可在对外 JSON 的 `annotation.outputPath` 补入规范化路径；
Runtime response、ArtifactFD metadata、ActionLog 和 diagnostics 均不得接收或记录该路径。

`elementSnapshotResult.v1` 至少包含：

```text
snapshotGeneration / capture / settleReason
capture.provider / capture.attempts / capture.fallbackReason
capture.frameAgeMilliseconds / capture.fenceWaitMilliseconds
degraded / engines / timings
elements[]:
  snapshotID / trackingID?
  frame(pixel, logicalPoints, normalized)
  center(pixel, logicalPoints, normalized)
  sources / confidence? / label? / labelSource / elementType
  identifier=null / enabled=null / selected=null / hittable=null
annotation?                      # both/internal annotated result only
```

result encoded size不超过 Runtime final/control 256 KiB；每路 raw candidate 不超过 2048，最终
elements 不超过 256，单个 label 不超过 1024 UTF-8 bytes，source 列表不超过 4。超限 fail closed，
禁止截断后伪装完整 snapshot。annotation PNG 复用 64 MiB hard cap。

## 48. 生命周期、隐私与验证

Runtime stop/quiesce、USB detach、connection/source epoch change、device generation retire 和 app
termination 必须取消 request、释放 frame lease、退休 capture/analyzer client generation、关闭
Apple worker并拒绝迟到 callback。Apple worker 不得超过 owning Runtime lifetime。Omni client
connection pool 可由 Runtime 关闭，但外部模型服务进程不属于 Runtime cleanup。

每个请求从 capture admission 到 terminal cleanup 结束都绑定 `requestID + clientInstanceID`、独立
generation 和 cancellation token。owner connection EOF、client deadline/SIGINT 的
`runtime.cancelOwnedPendingWork`、Runtime shutdown 或 authority retire 都设置该请求 token；取消只接受
exact owner，返回 `cancellationRequested` 后仍由原请求发送自己的 terminal。共享 capture producer 使用
独立 cancellation，只在没有有效 waiter 或 Runtime/authority cleanup 要求时取消；Runtime shutdown 必须
取消全部 active request 并 join 唯一 producer。pipeline 在该请求全部 analyzer/renderer 分支退出前不得
发布或回收其 generation，迟到结果不得发布。

默认 ActionLog、ReplayTrace、DiagnosticLog、unified log 和 metrics 禁止包含：

```text
source/derived screenshot bytes
OCR text or visual caption
target App content
raw UDID or private selector/token
OmniParser credentials, query or full endpoint URL
user output path
```

这里的 raw UDID 指 discovery/helper 的底层 transport identity；TRD 07 为 ActionLog 和 Runtime
envelope 规定的 canonical target identity 仍按其既有合同使用，不得把两者混写或向性能导出泄漏明文。

允许记录脱敏 provider/fallback、frame age/fence wait、dimensions/orientation、每路 status/elapsed/count/
profile/backend、fusion/correction elapsed、final count、degradation、circuit 和 generation。显式
annotation 是用户选择的输出 artifact，不进入日志或 Runtime retention。

自动化必须覆盖 target/epoch/freshness fence、横竖屏 inverse transform、三路全部完成顺序组合、
单/双路降级、三路失败、合法空结果、timeout/cancel/late callback、worker crash/circuit recovery、
output/no-clobber/atomic failure、schema cap 和 Runtime cleanup。production verification 还必须覆盖：

- 当前页面在查询前后零滚动、零 Accessibility focus movement、零 HID 和零 overlay。
- UIKit、SwiftUI、WKWebView、系统页、第三方 App、键盘、弹窗、深浅色、Dynamic Type、多语言和横屏。
- text/control precision、recall、box IoU、logical/normalized mapping error 和纯图标误报/漏报。
- capture 与每路 analyzer 的 cold/first/warm/reconnect p50/p95，以及并行资源争用。
- 默认 JSON 不生成 annotation；`both` 的 JSON/PNG generation/hash/dimensions exact 一致。
- packaged CLI 在 owner 提供的 iOS 17+ 与条件 legacy 设备上执行，并完成 Runtime/Helper/worker/
  socket/FD/temp artifact cleanup。

OmniParser 代码、权重、NOTICE/SBOM 与 screenshot egress，以及 Apple private framework 的签名、
分发和 macOS compatibility 必须通过对应 release Gate。Apple private 分支不能成为 OmniParser +
Vision 主路径的硬依赖。
