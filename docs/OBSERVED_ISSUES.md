# PulsePhone Observed Issues

本文档是当前已确认产品问题的唯一工作队列，记录在真实产品入口、实体设备验证或开发执行过程中已经复现或具有可信失败证据的问题。它不替代PRD、TRD、registry/schema或自动化测试；问题涉及产品合同或验收范围时，修复者仍需同步更新对应事实源。历史实施过程从私有归档 Git 历史读取，后续一律按本文档和`AGENTS.md`的当前循环执行。

尚未执行、不能判断通过或失败的场景不进入本文档，统一记录在`DEFERRED_VALIDATION.md`。Deferred Validation条件满足后先执行验证：通过则在该文档标记`verified`；失败后才创建或关联OBS。已经确认但主动暂缓修复的问题继续留在本文档并使用`deferred`状态。

## 状态定义

本轮新增：OBS-037（investigating，2026-09-20）：Runtime lifetime 退场缺少有界退出、
串行 cleanup 和 DirectHelper OneShot 覆盖；socket bind/chmod 中间崩溃可能阻断新 generation。
依据 TRD 05 §23.1 和 TRD 06 §25.6 修复，要求正常协议/退出码不变、父进程死亡后 2 秒退场、
真实继承 fd/lease 及 socket staging 恢复回归。验收产物统一留到后续设备窗口；当前下一步为源码修复和双 reviewer 复审。

| 状态 | 含义 |
| --- | --- |
| `open` | 问题已复现或已有可信证据，但尚未开始修复。 |
| `investigating` | 正在定位或验证根因，尚无通过验收的修复。 |
| `resolved` | 修复、回归、实体入口验证和必要文档更新均已完成。 |
| `deferred` | 已明确延期，并记录原因、风险和恢复条件。 |
| `notReproduced` | 后续无法复现；必须保留原始证据和复现环境，不能等同于 `resolved`。 |

每次修改状态时必须补充日期、提交、验证结果和剩余风险。主Agent按严重度、依赖和ID顺序领取`open`/`investigating`问题；`deferred`在恢复条件满足前跳过，但不得计为完成。只剩未提供设备、环境或人工条件的附加验证时，把该精确场景移入`DEFERRED_VALIDATION.md`，不要让已经修复的问题仅因`notTested`长期保持`open`。任何条目都不得静默删除。本文只保留resolved必要摘要，以便后续agent优先读取当前可执行队列。需要追溯已关闭问题的长历史时，从git历史读取旧版本。

## 问题索引

| ID | 标题 | 严重度 | 状态 | 当前归属 |
| --- | --- | --- | --- | --- |
| `OBS-001` | 关闭已绑定视频的 live 窗口时 GUIHost 崩溃 | High | `resolved` | M2 production GUI close lifecycle；2026-07-23 已闭环 |
| `OBS-002` | live 视频画布比例与底部 source controls 预留不一致 | High | `resolved` | `M2-017` / `M2-020` production window layout；2026-07-24 已闭环 |
| `OBS-003` | Keyboard Capture 启用后 Mac 键盘未被接管或未转发 | High | `resolved` | iOS 16 capability投影与iOS 17+实体物理键盘转发已闭环；2026-08-01解决 |
| `OBS-004` | Home / App Switcher toolbar 操作效率待复查 | Medium | `resolved` | 2026-07-30 current candidate轻量复查通过；无需生产代码修改 |
| `OBS-005` | PulsePhone 与 PulsePhoneRuntime 缺少静态、可扩展且无副作用的 Help 合同 | Medium | `resolved` | CLI contract / Catalog consistency；2026-07-24 已闭环 |
| `OBS-006` | live 窗口未统一处理实际最小宽度、最小缩放、sample format 旋转与全屏几何 | High | `resolved` | native resize selector、稳定transaction与主轴优先量化已完成实体及clean Gate闭环 |
| `OBS-007` | pointer / keyboard Stream 打开时重复退休 CoreDevice Helper generation | High | `resolved` | 默认范围已闭环；实体detach/reconnect转`DV-010` |
| `OBS-008` | GUI pointer 首触秒级停顿并可能静默失效 | High | `resolved` | `c82a8be`完成次数/时延/Player A-B，final source `6f9ad15`完成方向/fullscreen pointer与cleanup闭环；2026-07-27已解决 |
| `OBS-009` | Rotate 将相对旋转错误实现为绝对 landscape 目标 | Medium | `resolved` | final source `6f9ad15`完成relative single-request、unknown恢复、GUI/CLI方向与presentation收敛实体闭环；2026-07-27已解决 |
| `OBS-010` | Software Keyboard 返回成功但实体键盘不切换 | Medium | `resolved` | `fe2939a`/`f125b0a`完成公开capability撤回、negative Gate与实体剩余能力闭环；2026-07-27已解决 |
| `OBS-011` | GUI 上下系统边缘手势分类反转 | Medium | `resolved` | `31929e8`修正flipped edge；2026-07-28人工实体系统手势验收后关闭 |
| `OBS-012` | 公开 trace / diagnostics 命令在 production Runtime 中固定失败 | Medium | `resolved` | production持久化、生命周期与packaged CLI实体闭环；2026-07-27 已解决 |
| `OBS-013` | packaged stop 在 GUIHost 终止后可失败并遗留 Runtime | High | `resolved` | `b3e905b`实现production stop lifecycle，`f630659`连续3次fresh packaged实体闭环；2026-07-27已解决 |
| `OBS-014` | Pointer p3 / p4 外部轮询无法形成可归因的自动化端到端延迟数据 | Low | `deferred` | 2026-07-30 owner决定当前体验可接受，停止剩余cohort并清理任务专用测量设施；保留production continuous-clock修复 |
| `OBS-015` | CLI tap/drag/swipe 不会在已打开的 Live GUI 显示触点 Overlay | Medium | `resolved` | `a7e1827`完成production observation闭环，实体CLI触点、A/B、cleanup及clean Gate通过；2026-07-28已解决 |
| `OBS-016` | 实体USB重连后Runtime不推进连接代，GUI与CLI控制永久不可用 | High | `resolved` | `6a9cce9`稳定reattach；exact `fc73de7` candidate完成三轮实体重连、GUI/CLI输入及cleanup闭环；2026-07-28已解决 |
| `OBS-017` | Install App选择IPA后未启动真实安装 | Medium | `resolved` | production picker/status、Runtime/direct install route及CLI/GUI实体可归因失败矩阵已闭环；签名IPA成功oracle保留于`DV-013` |
| `OBS-018` | Screenshot部分场景可用但无session入口与fallback未闭环 | Medium | `resolved` | `1feba3b`修复；clean、fresh packaged cancel/preview/device fallback、trace与cleanup均闭环 |
| `OBS-019` | iOS 16 CLI swipe延迟返回泛化capabilityUnavailable | Medium | `resolved` | `218cfe6`修复；production iOS 16等价矩阵、clean、fresh packaged compatible坐标链路与cleanup均闭环 |
| `OBS-020` | successful one-shot后死亡generation遗留socket/manifest并永久阻断后续命令 | High | `resolved` | `901bc0d`修复；clean、fresh packaged正常链路、实体SIGKILL/public stop恢复、restart与cleanup均闭环 |
| `OBS-021` | `type --text` 冷启动首次调用可能触发粘贴权限弹框 | High | `resolved` | `1a46e0b`完成fresh-only service readiness；cold/reused、Capture与cleanup实体闭环 |
| `OBS-022` | Live缺少可用的无状态软件键盘切换入口 | Medium | `resolved` | `7f6d25f`实现Indigo Consumer Eject无状态toggle；Capture开关两态实体闭环 |
| `OBS-023` | iOS 14～16 prepare、screenshot与launch未装配legacy production路径 | Medium | `resolved` | iOS 16.3.1 exact classic闭环；其余exact-build矩阵由`DV-004`管理 |
| `OBS-024` | `uninstall` 未装配跨版本 production 路径 | Medium | `resolved` | iOS 14.4.2与iOS 26.5.2完成卸载、缺失错误和恢复安装闭环 |
| `OBS-025` | PATH软链启动无法定位App内CLI资源 | Medium | `resolved` | canonical app root统一资源定位；fresh package软链CLI与直接入口等价 |
| `OBS-026` | Live 共存时 Element capture 可被单个截图 provider 永久阻塞 | High | `resolved` | 有界attempt/fallback、fresh packaged Live/no-Live、后续控制与cleanup闭环 |
| `OBS-027` | Element annotation 底图被垂直镜像 | High | `resolved` | bitmap context方向修复；fresh package实体方向/框/hash与clean Gate闭环 |
| `OBS-028` | Element 客户端以未部署的未来协议拒绝当前 OmniParser 服务 | High | `resolved` | 直接 POST `/parse/`、三路 fresh packaged 实体与 clean Gate 闭环 |
| `OBS-029` | Element correction 不能细化已有候选或构造可操作控件框 | Medium | `resolved` | seed-based 局部精修、可信 Omni 保护、低遮挡 annotation 与 clean Gate 闭环 |
| `OBS-030` | Element Runtime 冷启动首次请求可能命中过早的 outer deadline | High | `resolved` | 27/32 秒 outer deadline、同 PID cold/warm 三路实体与 clean Gate 闭环 |
| `OBS-031` | Element production server 未使用已冻结的 outer deadline | High | `resolved` | `00a7ebb`完成deadline装配、诊断selector及有界correction；clean Gate与fresh packaged全组合闭环 |
| `OBS-032` | Element 标注图混入文字框且跨控件证据未收敛 | Medium | `resolved` | `94af605`完成分层投影与同级证据收敛；clean Gate、fresh packaged同页三路实体与cleanup闭环 |
| `OBS-033` | Element Live 帧复用拒绝首次绑定的临时几何 | High | `resolved` | revision 0 provisional 生命周期兼容、clean Gate 与 fresh packaged 实体 Live 闭环 |
| `OBS-034` | Developer Support preparation 未接入生产单飞与 remediation 合同 | High | `resolved` | build 22 iOS 26.5.2 fresh-generation rehydration、Live preflight 与 cleanup 已闭环 |
| `OBS-035` | `type --text` 第二次调用复用已关闭的 Pasteboard 会话 | High | `resolved` | `f2071f0` 修复；iOS 26.5.2 连续实体输入通过，无粘贴权限弹窗 |
| `OBS-036` | 高位 ECID 被 Lockdown 整数解析拒绝，导致 iOS 17+ prepare 误报 Developer Support 不可用 | High | `investigating` | 高位 `UniqueChipID` unsigned parsing；等待 packaged candidate 验证 |

## OBS-001：关闭已绑定视频的 live 窗口时 GUIHost 崩溃

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-23
- 影响范围：packaged `PulsePhone.app` 的正式 live GUI 窗口
- 用户可见结果：窗口关闭后 macOS 显示 PulsePhone crash 对话框；GUIHost 进程退出，需要重新启动
- 与其他问题的关系：独立于 pointer/HID 控制失败和 AVFoundation source mapping cache

### 关闭摘要

- 本条已关闭；主文档只保留状态、问题边界和必要关闭摘要，避免当前工作队列无限扩展。需要追溯完整复现、根因、提交、candidate/hash、验证记录和历史checkpoint时，从git历史读取旧版本。
- 后续agent领取当前工作时，应优先读取索引以及`open`/`investigating`正文；不得把归档中的旧“当前唯一下一动作”当作仍然有效。若当前产品重新复现同类失败，再重新打开本OBS或创建更精确OBS。

## OBS-002：live 视频画布比例与底部 source controls 预留不一致

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-23
- 影响范围：packaged `PulsePhone.app` 正式 live 窗口的视频画布、底部 source picker、pointer 坐标区域和 geometry resize
- 用户可见结果：窗口可显示真实 iPhone 画面，但底部 52 pt source controls 覆盖视频；用户实际可见、可操作的画布与设备比例不严丝合缝
- 与其他问题的关系：独立于 `OBS-001` close crash、AVFoundation source mapping cache 和 HID 投递延迟

### 关闭摘要

- 本条已关闭；主文档只保留状态、问题边界和必要关闭摘要，避免当前工作队列无限扩展。需要追溯完整复现、根因、提交、candidate/hash、验证记录和历史checkpoint时，从git历史读取旧版本。
- 后续agent领取当前工作时，应优先读取索引以及`open`/`investigating`正文；不得把归档中的旧“当前唯一下一动作”当作仍然有效。若当前产品重新复现同类失败，再重新打开本OBS或创建更精确OBS。

## OBS-003：Keyboard Capture 启用后 Mac 键盘未被接管或未转发

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-23
- 重新打开日期：2026-07-28
- 解决日期：2026-08-01
- 影响范围：packaged `PulsePhone.app` 的 iOS 16/17+ toolbar capability projection、Mac 物理键盘转发、Input Monitoring/Event Tap、短期 keyboard Stream 和 release-all。
- 用户可见结果：历史版本曾出现 iOS 16 多余 Keyboard Capture 入口，以及 iOS 17+ 开启后物理键盘未产生设备输入；当前 candidate 已恢复正确兼容性投影和实体输入。
- 与其他问题的关系：`OBS-021`独立承接 `type --text`；`OBS-022`独立承接无状态软件键盘切换。三者只共享 generation-scoped input service 和调度资源，不合并产品职责。

### 关闭摘要

- iOS 16 多余入口的根因是本地 toggle 没有表达对 iOS 17+ keyboard stream capability 的依赖；既有提交 `12360eb`、`5574937`已同步 Catalog、Planner、toolbar 和 production identity。当前自动化证明 iOS 16 同时省略 `gui.keyboardCapture.toggle` 与 `gui.keyboard.interaction`，iOS 17+ 保留入口；本轮未取得 iOS 16 实体设备，exact-build 扩展仍由 `DV-004`承接。
- iOS 17+ 继续使用真实 Input Monitoring、session-level Event Tap、device-first pressed-set、300 ms 短期 Stream 和 fail-closed release-all。提交 `018a3f8`补充 toolbar 回归，防止新增 Software Keyboard 时挤掉 Keyboard Capture。
- exact source `c80a2d9` 的 packaged candidate 在 iPhone 14 / iOS 26.5.2 上投影 `Keyboard Capture active`。输入框保持激活时，真实 Mac 键盘按键 `1`写入当前光标；Software Keyboard 可独立隐藏，隐藏后 Capture 输入仍有效，文本焦点不丢失。
- Capture enabled/active 是 GUI 状态，不等于持续占有 Runtime 资源。全部按键释放后短期 Stream 关闭；因此 Capture 开启但空闲时，`type --text`可复用同一个 Helper-owned keyboard service 并成功执行，不创建第二个 service。
- 共享验证通过 35 项 CoreDevice Python、149 项 focused Swift（2 项实体 opt-in 跳过）以及最终完整 800 项 Swift（2 项实体 opt-in 跳过、0 失败）；generated Swift/Python、registry、current identity/evidence 阶段均通过。candidate input 为 `build/evidence/objects/042f60b280d2edf3df2f8fa5c6bb35708601f3375a82aa0c42b8371575025aa4/release-candidate-input.v1.json`，文件 SHA-256=`ab6983889df7a78e532a116973e9da51edafe4af4124dc74ec24f576a7d9ae81`，app content hash=`b074dd6e21f9a89e03e8f821fbf4bd7464b76529019cf094ba591732033419ef`。
- `package-app`和 `codesign --verify --deep --strict`通过；该本地 development candidate 为 ad-hoc 签名，`TeamIdentifier=not set`，不得扩大为正式发布签名证据。Live、Runtime 和 Helper 已清理，两台已知目标的 `runtime status`均为 `notRunning`。

## OBS-004：Home / App Switcher toolbar 操作效率待复查

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-23
- 最新owner反馈日期：2026-07-29
- 解决日期：2026-07-30
- 影响范围：packaged `PulsePhone.app` 正式 live 窗口的 Home 和 App Switcher toolbar action
- 用户可见结果：历史上曾担心点击到可见效果存在秒级延迟；2026-07-29 owner反馈当前效率可以接受，2026-07-30 fresh candidate轻量复查再次确认Home和App Switcher均快速terminal并产生正确实体终态，无需生产代码修改。
- 与其他问题的关系：独立于 `OBS-002` 画布布局和 `OBS-003` 键盘输入；若复查发现实体响应或Live画面仍明显慢，再区分设备控制链路延迟与Live画面显示延迟。

### 已确认的实现事实

- `HomeButtonAction.holdMilliseconds` 为 50 ms。
- App Switcher 固定序列为 35 ms 按下、120 ms 间隔、35 ms 再次按下，合计约 190 ms，加上 transport/service overhead。
- 2,000 ms cleanup acknowledgement 是异常 cleanup 的最大等待上限，不是每次操作的固定 sleep。
- production Helper 通过generation-scoped `_ensure_pointer`复用同一 Indigo service；button OneShot仍保持独立request、Scheduler claim与terminal/cleanup边界，但正常成功序列不再每次重建service。
- GUI 将toolbar submit放到单一`runtimeQueue`；成功的Home/App Switcher在terminal后立即清除busy并展示结果，不再请求availability。只有失败结果和Lock等确需刷新状态的动作才继续执行`session.availability()`。
- Runtime live session 的 OneShot submit 走独立 normal request 连接；与 player demo 直接长持有 HID service 的调用路径存在固定开销差异。

因此，当前不再把本条描述为已确认的持续性能缺陷；已有实现和矩阵结果显示正常路径不存在固定秒级sleep。后续只需复查当前candidate是否仍满足可接受效率，若通过则无需代码修改，可按验证结果关闭。

### 合理性分析与建议

- 50 ms Home hold 与 App Switcher 的 double-Home 间隔用于表达真实按键语义，属于合理且必要的时序，不应为追求数字而删除。
- OneShot 每次独立建立 Runtime request 和 Indigo service，有利于保持 ownership、资源申领、错误隔离和 cleanup 边界，并非当然错误；但如果实测证明 service negotiation 占据主要时间，应评估在 live owner 生命周期内受控复用，而不是盲目要求所有路径长连接。
- 单一 `runtimeQueue` 可以简化操作顺序和窗口状态一致性，但不代表 terminal 后的 availability refresh 必须延长用户可见的 busy 时间或阻塞后续输入；建议分别测量 submit、terminal 和 refresh，再判断是否需要解耦。
- Live 视频为了帧顺序和稳定渲染允许有有界缓冲，但若缓冲已让控制反馈达到秒级，则应检查 capture queue、sample timestamp 和 display layer 背压，而不应把它解释为 toolbar 的必要代价。
- 当前不预设一个脱离设备、macOS 和统计数据的毫秒级硬指标。建议先建立实体设备响应与 Live 显示的 p50/p95 基线，再结合用户是否会重复点击或误判失败来决定优化优先级。

### 复查范围

当前优先执行轻量复查；只有复查失败时才继续深入定位。复查时在同一次点击中分别记录：

1. GUI 点击时间。
2. 实体 iPhone 开始响应的时间。
3. PulsePhone Live 画面显示该状态变化的时间。
4. Runtime accepted/running/terminal、Helper service open/close 和 availability refresh 的时间。

如果当前candidate的实体响应和Live画面反馈仍与历史10+10矩阵同量级，且owner确认体验可接受，则不需要修改生产代码。只有实体 iPhone 或Live画面出现稳定、用户可感知的异常变慢时，才继续定位 Runtime request、Scheduler/queue、CoreDevice preparation、Indigo service setup 或 AVFoundation/capture/display buffering。两段延迟可能同时存在，不得在未测量时相互替代。

### 合同判断

- TRD 06 §25.3 中 Home 5 s、App Switcher 10 s 是 running failure deadline/terminal boundary，不是期望交互延迟或允许的固定等待。
- PRD 要求正式 toolbar action 实际调用对应 handler 并在实体设备上闭环；仅组件测试或最终生效不能证明可见延迟合理。
- 当前 PRD/TRD 未冻结 Home/App Switcher 的具体 UX latency SLO；修复时不应擅自把新阈值声明为既定产品合同。

### 关闭验收标准

只有同时满足以下条件才能将状态改为 `resolved`：

1. 在当前 packaged `PulsePhone.app` 和实体 iPhone 上对 Home、App Switcher 执行轻量效率复查，记录点击到实体设备响应及点击到 Live 画面反映变化的分层数据；可复用最近10+10矩阵方法，不要求先改代码。
2. 确认不存在为正常 button action 引入的固定秒级 sleep、不必要的 preparation、terminal后的无意义availability refresh或可避免的串行阻塞。
3. 若复查数据与历史10+10矩阵同量级，且owner确认体验可接受，则本条可直接关闭为`resolved`，关闭记录中明确“无需生产代码修改”。
4. 若复查失败，再按原路径定位：实体响应慢则查 Runtime request、Scheduler/queue、CoreDevice preparation 和 Indigo service setup；Live显示慢则查 capture timestamp、display buffering 和用户可见帧延迟。
5. 关闭时记录candidate/commit、设备/OS、复查数据、owner体验结论、是否修改代码以及剩余风险；如发生代码改动，再运行相关 GUI/Runtime/Helper 回归、packaged 实体 Gate、`make check` 和适用 M2-900。

### 解决记录

本条已解决。历史10+10实体分层矩阵已经完成，2026-07-29 owner反馈当前效率可以接受；2026-07-30 current candidate轻量复查通过后按合同直接关闭，无需生产代码修改。

- 2026-07-26 implementation checkpoint：docs baseline `a66ad7d`后，source commit `189017f`让正式bound session只在接受exact current binding lineage的真实incoming sample后异步发送internal `runtime.markLiveCaptureReady`。Runtime以`preCapture|postCapture`显式provenance完成一次性replacement，active Stream/OneShot时defer且不抢占、不重放；GUI在转换期间保持video并暂时禁用受影响control。visual probe改为首个post-click accepted incoming frame建立baseline，不再读取已经enqueue/display的buffer。
- compatibility推进为`runtime.compat.v2`，旧Runtime在Hello阶段fail closed。21项ProductionRuntimeAssembly（2 physical-only skipped）、33项GUIHost assembly/display/telemetry、17项CoreDevice generation及registry/current-contract targeted通过；clean `swift test`与`make check`均为631项Swift（2 physical-only skipped、0失败），7项registry Python、14项bootstrap contract和29项current/evidence checks通过。
- 2026-07-26 default-delivery observation：同一post-capture generation 2中Home OneShot实体响应的Helper分层为`serviceOpen=33.234 ms / sequence=51.402 ms / total=84.710 ms`；Rotate toolbar action在631.949 ms内succeeded，App Switcher至少一次真实改变设备状态。以上排除了当前正常路径存在固定3秒sleep，但没有完成Home与App Switcher各10次的点击到设备/点击到live画面分层矩阵，因此本问题仍保持`open`。
- 2026-07-27 final measurement checkpoint：exact candidate input SHA-256=`cd037a872a5d51db6b0c5192f780dc051ca146d02b8ae506d725fa1d94fc24be`、app tree hash=`46df36ad1db3589cc0a36ff8d5f044121bd6ef9254865c0160cbc146f63a5140`在iPhone 14 / iOS 26.5.2 build `23F84`完成独立稳定矩阵。GUIHost PID `43414`、Runtime PID `43418`及post-capture Helper PID `51462` / generation 3在最终20个动作前后不变；Home与App Switcher各10次均恰有一组clicked、Accepted、Started、Result、terminal succeeded、presented和accepted incoming-frame content change，0次availability refresh，0次typed failure或busy遗留。原始截图只作为ephemeralSensitive scratch；人工复核的1.2 s终态为Home网格10/10、真实App Switcher卡片10/10。
- 同一最终矩阵使用nearest-rank统计且不建立SLO。Home的p50/p95分别为：GUI queue `0.121/0.430 ms`、Runtime Accepted `0.723/5.977 ms`、Started `0.813/6.025 ms`、Result `52.382/59.716 ms`、GUI submit `53.094/71.408 ms`、click-to-presented `53.407/71.990 ms`、首个Live内容变化 `454.597/459.777 ms`；Helper service open `0/0.003 ms`、button sequence `51.507/52.948 ms`、total `51.509/52.953 ms`。App Switcher对应为queue `0.148/0.226 ms`、Accepted `0.794/1.162 ms`、Started `0.933/1.263 ms`、Result `194.905/196.516 ms`、submit `195.750/197.484 ms`、click-to-presented `196.019/197.908 ms`、首个Live内容变化 `337.712/357.423 ms`；Helper service open `0/0.001 ms`、sequence `193.898/194.985 ms`、total `193.899/194.988 ms`。
- 结果把原“秒级固定延迟”分解为合同内约`51 ms` Home / `194 ms` double-Home序列和约`0.34...0.46 s`首个Live内容变化；正常路径不存在固定秒级sleep、重复preparation、逐action service negotiation或terminal后的availability串行阻塞。一次在主矩阵前插入的packaged screenshot oracle首先返回`developerServicesUnavailable`、有界重试成功并按既有恢复合同形成generation 2 -> 3；该扰动没有进入最终矩阵，也未在generation 3的后续40个按钮动作中重复。当前不创建新问题；若受控fresh序列重复则另建精确OBS。
- final Default Delivery的packaged实体、clean `make check`与M2-900已通过；10+10扩展矩阵现已完成，可作为当前复查的历史基线。2026-07-29后本问题不再要求为了历史共享cleanup单独保留；只需在当前candidate轻量确认效率仍可接受，若通过则记录“无需代码修改”并关闭。
- 2026-07-30 current candidate closure：使用OBS-006同一exact `d4440c5` / input hash `a5156e92...d99d` fresh package和iPhone / iOS 26.5.2 (`23F84`)执行轻量复查。Home `queue=0.375 ms / submit=95.644 ms / presented=96.284 ms`，App Switcher `queue=0.253 ms / submit=198.419 ms / presented=198.858 ms`，两项均terminal `succeeded`；Live分别观察到Home网格和真实App Switcher卡片。Home首次1.1秒截图仍处于landscape到portrait过渡，下一次有界轮询已显示正确Home，不把工具轮询间隔当产品时延；App Switcher在首个约1.1秒观察即正确。日志只有clicked/terminal/presented，无失败、busy遗留或成功后availability refresh；结果与历史10+10基线一致且owner已确认体验可接受，因此不修改production source并关闭本条。toolbar日志位于Git ignored的`build/observations/OBS-006/candidate-a5156e92/toolbar-latency.log`，SHA-256=`5b1d10731d83be1c58d64d374ee3efb5571bb5d5f56947fcad77246fd0d17732`。

## OBS-005：PulsePhone 与 PulsePhoneRuntime 缺少静态、可扩展且无副作用的 Help 合同

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-24
- 影响范围：packaged `PulsePhone` CLI、内部 `PulsePhoneRuntime` 可执行文件、公开 `commands` 输出、Command Catalog、兼容性说明和执行期目标错误
- 用户可见结果：`PulsePhone --help` 当前返回 `invalidArgument: unknownCommand("--help")`，无参数调用返回 `invalidArgument: missingCommand`；用户无法从可执行文件获得完整命令、参数和系统兼容范围
- 与其他问题的关系：不阻塞已经实现的设备控制执行路径，但属于发布前必须闭合的公开 CLI contract / Catalog consistency 问题；独立于 `OBS-002`～`OBS-004` 的 GUI 功能问题

### 关闭摘要

- 本条已关闭；主文档只保留状态、问题边界和必要关闭摘要，避免当前工作队列无限扩展。需要追溯完整复现、根因、提交、candidate/hash、验证记录和历史checkpoint时，从git历史读取旧版本。
- 后续agent领取当前工作时，应优先读取索引以及`open`/`investigating`正文；不得把归档中的旧“当前唯一下一动作”当作仍然有效。若当前产品重新复现同类失败，再重新打开本OBS或创建更精确OBS。

## OBS-006：live 窗口未统一处理实际最小宽度、最小缩放、sample format 旋转与全屏几何

### 当前状态

- 状态：`resolved`
- 原解决日期：2026-07-27
- 发现日期：2026-07-24
- 最近重新打开日期：2026-07-28
- 最近补充日期：2026-07-29
- 最终解决日期：2026-07-30
- 当前重新打开日期：2026-07-30
- 影响范围：packaged `PulsePhone.app` 正式 live 窗口的初始 reservation、AVFoundation bound sample 展示、手动横竖屏切换、用户 live resize、合理最小可缩放尺寸、全屏进入/退出、pointer geometry 和无视频源占位
- 用户可见结果：初始尺寸、320 pt产品minimum、零letterbox和fullscreen恢复保持闭环；四边四角连续resize固定比例并平滑跟手，窗口位置不漂移，画面无黑边或白边。resize期间方向变化继续保留最后兼容帧，并在结束后一次采用稳定新方向。
- 严重度判断：High。当前缺陷直接影响默认live首屏和最基础的用户resize，不属于额外显示器、Reachability或可选验证；把白边改成黑边不能满足稳定windowed画布与设备画面严丝合缝的产品要求。
- 与其他问题的关系：`OBS-002` 已解决 video canvas 与底部 source controls 重叠、用户 resize 基础比例约束和初始 geometry reservation；本条保留其历史闭环记录，只跟踪实体复测后新确认的 AppKit 最小宽度、同 source session 动态 sample format 和 fullscreen transition 缺口。它独立于 `OBS-004` 的设备控制延迟

### 已确认的复现与实现事实

1. 以 portrait 方向打开正式 live 窗口并自动恢复已确认 source 后，视频画面约为 `1170:2532`，但窗口实际宽度大于按默认 canvas 长边计算出的宽度，视频两侧出现可见空白。
2. 设备保持同一 AVFoundation source 和 capture session，从 portrait 手动旋转到 landscape 后，横屏 sample dimensions 发生宽高交换，但正式窗口不再显示新画面；旋回 portrait 后，尺寸重新匹配首个 sample，画面继续更新。
3. `Sources/PulsePhoneGUI/ProductionVideoSession.swift` 的 `ProductionVideoObservationCollector.receive` 在首个 sample 后要求所有后续 sample 的 width/height 与记录值完全相等；同一 `sourceEpoch` 下尺寸不同的 sample 被计为 dropped frame，未进入 `AVSampleBufferDisplayLayer`。
4. `Sources/PulsePhoneMedia/VideoSourceInventoryAVFoundation.swift` 已从每个 `CMSampleBuffer` 的 format description 读取实际 dimensions，因此冻结不是 AVFoundation 未提供横屏尺寸，而是 bound session 在 enqueue 前主动拒绝。
5. `Sources/PulsePhoneGUI/ProductionGUIHost.swift` 按数学 reservation 调用 `window.setFrame`，但没有在 AppKit 完成 titlebar/native toolbar 布局后重新核对实际采用的 content width。当前 toolbar 已使用 `iconOnly`、`small` 和 `unifiedCompact`，仍可能受窗口按钮、标题、toolbar item 和 overflow chrome 的实际最小宽度约束。
6. 底部 source controls 的固定控件宽度合计小于当前观察到的 portrait 窗口实际宽度，因此当前白边更可能主要来自 native titlebar/toolbar 的实际宽度下限，而不是视频比例公式错误。
7. `ProductionGUIHostCanvasHost` 正确执行 aspect-fit；当 AppKit 把容器撑宽但画布高度保持原 reservation 时，它会把比例正确的视频居中放入更宽容器，从而暴露两侧空白。当前只有 video view 明确设置黑色背景，canvas host 的剩余区域可能显示为白色。
8. 当前 window delegate 已处理 `windowWillResize`、`windowDidEndLiveResize` 和 screen 变化，但没有定义 entering fullscreen、fullscreen、exiting fullscreen 和 `windowDidExitFullScreen` 的几何策略。
9. 现有 assembly 测试主要验证独立 sizing 数学和 `presentsWindows=false` 的窗口结构，无法证明真实 WindowServer、native toolbar 和 fullscreen transition 下 AppKit 最终采用的尺寸。
10. 2026-07-29 owner补充确认，当前live窗口允许用户继续缩到过小尺寸，虽然可能仍保持比例或事后校正，但窗口内容、toolbar/source controls和可视画面整体观感不可接受；这说明现有minimum authority只覆盖数学可行性或AppKit实际最小宽度，没有冻结产品层面的合理最小可用尺寸。

### 根因与合同缺口

当前实现把三个应独立演进的概念混在一起：

```text
source identity
  canonicalUDID + connectionEpoch + sourceID + sourceEpoch

sample presentation format
  presentation width/height + normalized device shape
  + orientation + session-local formatRevision

interaction geometry
  geometryRevision + logical width/height + orientation
```

- `sourceEpoch` 应证明 capture source identity 和 session binding，不应仅因为同一 bound source 的合法分辨率变化或宽高交换而失效。
- sample presentation format 决定当前真实视频如何显示和窗口应采用什么比例，但不能单独建立 source/target proof。
- interaction geometry 决定 pointer 的坐标和 revision safety；presentation format 变化时必须取消旧 interaction，并在新的 geometry 与展示方向一致后恢复输入。
- window state 还必须独立记录 windowed/fullscreen transition 和用户 windowed canvas 长边，不能把每一次比例变化都无条件转换为 `setFrame`。

现有 PRD/TRD 已要求 aspect-fit、canvas/source controls 分区、geometry revision invalidation、保留用户长边和 screen visible frame 边界，但没有明确：

- 同一 `sourceEpoch` 下合法 sample format 变化必须继续显示；
- source identity、presentation format revision 和 interaction geometry revision 的边界；
- 防抖只能延迟窗口/geometry 提交，不能阻塞 sample enqueue；
- physical/manual rotation 如何从稳定 bound sample 推导 presentation orientation；
- AppKit 实际最小内容宽度如何进入 reservation；
- 用户可缩放到的产品最小可用尺寸如何定义，并与AppKit/source controls/toolbar minimum共同生效；
- fullscreen transition 中何时禁止 `setFrame`，退出全屏后如何恢复 windowed reservation。

因此不得直接通过删除尺寸校验或增加零散 `setFrame` 调用完成本问题；必须先更新产品和技术合同。

### 已冻结的全面修复方向

#### 1. 保持 source binding fail closed

- 真实帧仍必须匹配 current canonicalUDID、connectionEpoch、sourceID、sourceEpoch 和当前 binding lineage。
- source 消失、sourceEpoch 改变、Runtime reconnect 或 target proof 失效时，继续停止旧 session、清除旧帧并重新绑定。
- 禁止使用名称、列表顺序、设备比例、方向或尺寸建立 source mapping proof。

#### 2. 独立维护 sample presentation format

- 每个 identity-valid sample 优先从 clean aperture/presentation dimensions 取得展示尺寸；不可用时才 fallback 到 raw encoded dimensions。
- identity 校验通过的 sample 必须持续 enqueue 到 display layer。format candidate 的确认、防抖和窗口调整不得位于 enqueue 的前置拒绝路径。
- capture session 内维护单独的 `formatRevision`。同一 sourceEpoch 下 presentation dimensions 合法变化时递增 format revision，不伪造 source reconnect。
- `AVSampleBufferDisplayLayer` 失败时可按既有机制 flush/recover，但合法尺寸变化本身不构成 renderer failure。

#### 3. 使用 normalized device shape 识别变化

```text
normalizedShape = shortEdge / longEdge
```

- dimensions 改变但 normalized shape 仍在容差内、方向不变时，视为同一方向的分辨率变化；继续显示，不调整 windowed 长边。
- width/height 交换且 normalized shape 与已建立设备形状相符时，形成 orientation candidate。
- 单帧异常、旋转中间帧或明显不同的临时 crop 不得立即重定义设备形状或窗口比例。
- 稳定候选必须由多帧一致性和有界时间确认；单帧不得触发 resize，真实稳定旋转也不得被无限延迟。具体阈值由 TRD 和测试冻结，目标是在约 400 ms 内完成稳定方向提交。
- 防抖期间继续播放收到的新帧，不允许重新出现“横屏冻结、旋回竖屏恢复”。

#### 4. Reachability 与异常比例

- iPhone Reachability/便捷访问通常只移动屏幕内容，不改变完整 framebuffer dimensions，不应触发窗口 resize。
- 临时异常比例可以继续在当前 canvas 中 aspect-fit 显示，但不得立即改变 authoritative device shape 或 pointer geometry。
- 若比例长期稳定但不符合当前 device shape，必须等待 Runtime/geometry 佐证或进入明确的重新验证状态；不得静默把未知 crop 当成新设备比例。

#### 5. 同步 presentation 与 interaction geometry

- stable presentation orientation 变化时，先取消当前 pointer/keyboard coordinate interaction并清除旧 overlay。
- 生成或取得递增的新 geometry revision，使 logical orientation、visible image rect 和当前 presentation orientation 一致。
- 在新 geometry 可用于 current connection 前，不得继续使用旧方向坐标；视频显示不因输入暂不可用而停止。
- Runtime/rotate Ack 提供的权威 geometry 优先于未经确认的单帧候选；stale geometry 和 stale sample format 都不得覆盖 current revision。

#### 6. 统一 window reservation 与 AppKit 实际最小宽度

- 首先尽可能降低 native toolbar 的宽度要求：隐藏纯视觉标题但保留 accessibility title；为次要 item 设置稳定 visibility priority 并允许进入 overflow；不通过过度缩小图标牺牲可点击性。
- source controls、titlebar/native toolbar 和 AppKit 最终布局共同形成实际 minimum content width；不得只依赖理论按钮宽度或硬编码某次观察值。
- 除AppKit和source controls的技术最小宽度外，还必须定义产品层面的合理最小可缩放尺寸。该下限应保证视频画面、source controls、toolbar overflow和状态反馈仍可辨认且不显得破碎；用户从任意边/角继续缩小时，窗口应在该下限处稳定停止或按同一比例双轴裁限，不允许缩到过小后仅靠letterbox、裁剪、控件挤压或事后校正维持几何数学。
- portrait reservation 至少遵守：

```text
effectiveCanvasWidth = max(calculatedCanvasWidth, actualMinimumContentWidth)
canvasHeight = effectiveCanvasWidth / currentPresentationAspectRatio
contentHeight = canvasHeight + sourceControlsHeight
windowFrame = AppKit frame for contentHeight + actual chrome
```

- 重新计算后仍必须裁限到 current screen visible frame。稳定windowed状态若遇到toolbar/source controls最小宽度冲突，必须优先使用toolbar overflow、自适应source controls和双轴同比例裁限；不得只扩宽canvas host并使用黑色或白色letterbox填充差值。fullscreen和stable presentation尚未提交的有界过渡可以使用设备坐标之外的对称黑色letterbox。
- 每次 programmatic `setFrame` 后必须校验 AppKit 实际采用的 content/frame size，使用有界 reconciliation，防止无限 layout/setFrame 循环。
- 用户从任意边或角live resize时，每次`windowWillResize` callback都必须同步计算另一轴；minimum/maximum clamp、产品最小可用尺寸和screen bounding不得单独改变宽或高。`windowDidEndLiveResize`只记录最终visible canvas长边，不能依赖aspect-fit掩盖拖动期间的窗口比例偏差，也不能把低于产品下限的过小窗口记录为新的用户尺度。

#### 7. 明确 fullscreen 状态机

```text
windowed -> enteringFullscreen -> fullscreen
fullscreen -> exitingFullscreen -> windowed
```

- fullscreen 中可以更新 canvas aspect、video layout、presentation revision 和 interaction geometry，但不得调用 `setFrame` 改变系统管理的 fullscreen window。
- 进入 fullscreen 前保存 windowed 用户 canvas 长边和有效 reservation，不把 fullscreen bounds 记录为用户 windowed 尺度。
- `windowDidExitFullScreen` 后，按退出当刻的 current presentation ratio 和进入前的用户 windowed 长边重新计算有界 reservation。
- 用户从未调整 windowed 大小时才使用默认 canvas 长边；不得每次退出 fullscreen 都无条件跳回默认 720 pt。
- fullscreen transition 中收到的多个 format candidate 只提交最终稳定状态，不能让中间帧覆盖退出后的窗口比例。

#### 8. 无视频源使用同一几何管线

- 未绑定 source、Camera denied、source unavailable 或尚无有效 sample 时，继续使用合同定义的 identity placeholder 比例。
- placeholder、用户 resize、screen change、fullscreen 和退出 fullscreen 应复用同一个 reservation/state 入口，不建立无视频源专用旁路。
- 比例 authority 顺序和 presentation/interaction 差异必须由更新后的 PRD/TRD 明确，避免现有“Runtime geometry优先”文字与真实 bound sample 展示发生歧义。

### 强制文档前置顺序

本问题的实施者必须按以下顺序执行，不能先改 production code 再补文档：

1. 先更新 `docs/pulsephone-prd.md` 的 live 画布、坐标和 GUI 验收章节，冻结 source identity、presentation geometry、interaction geometry、manual rotation、fullscreen、用户尺度和无视频源行为。
2. 再更新 `docs/pulsephone-trd.md` 及 `docs/pulsephone-trd/06-product-execution-and-client.md`，冻结 sample dimension 提取、session-local format revision、持续 enqueue、防抖、geometry 同步、AppKit minimum width reconciliation、fullscreen 状态机和测试边界。
3. PRD/TRD 必须形成早于 production 实现的独立可审计提交。文档没有解决 authority 冲突前，不允许修改 `ProductionVideoSession`、`LiveWindowModel` 或 window delegate 来宣称修复。
4. 文档提交完成后，在本OBS记录合同checkpoint，再按当前`AGENTS.md`问题循环实施源码、自动化、packaged入口和实体复测。
5. 若实现发现 Runtime 无法接收或确认 stable sample 推导出的 geometry revision，必须先返回 PRD/TRD 明确同步合同；不得用禁用 pointer、绕过 revision 校验或永久依赖 local-only geometry 掩盖缺口。

### 实施范围与复杂度

- 应复用现有 `LiveWindowModel`、`LiveWindowReservation`、`ProductionLiveWindowSizing` 和 window state，不另建与现有模型平行的第二套窗口系统。
- 历史format、fullscreen和geometry修复继续保留；本次重新打开后的production增量预计约`80～220`行，测试约`150～320`行，主要涉及`LiveWindowReservation`、`ProductionLiveWindowSizing`、真实`NSWindow` assembly测试和必要的source controls自适应布局。
- 当前增量预计`1～2`个工程日；加上fresh packaged app的portrait/landscape初始窗口、所有边角live resize、fullscreen退出和placeholder实体复测，现实总量约`1.5～3`个工程日。
- 只删除 exact dimensions guard 可以短期让横屏帧进入 renderer，但不能闭合窗口比例、输入坐标、异常帧、防抖和 fullscreen，因此不构成本问题的可接受修复。

### 关闭验收标准

只有同时满足以下条件才能将状态改为 `resolved`：

1. PRD/TRD 在 production code 之前完成更新并有独立提交；最终合同明确三类 authority、format revision、持续 enqueue、minimum width 和 fullscreen 行为。
2. packaged `PulsePhone.app` 使用当前可用实体 iPhone，portrait -> landscape -> portrait 多次切换期间画面持续更新，不依赖关闭窗口、重新选择 source 或旋回原方向恢复。
3. 同一 current sourceID/sourceEpoch 下，合法宽高交换和等比例分辨率变化不会被错误计为 identity mismatch；错误 source、stale epoch 和 stale connection 仍 fail closed。
4. 单帧异常和旋转中间帧不会造成窗口跳动；稳定方向变化在合同 deadline 内更新 canvas、windowed reservation 和 interaction geometry。
5. 初次 portrait 和 landscape binding 后，稳定windowed状态的`canvasHost.bounds`、`visibleImageRect`和video/interaction bounds一致，与current presentation ratio严丝合缝，不存在白色或黑色侧边。
6. 用户从所有边角连续live resize时，每次resize callback都保持当前canvas ratio；minimum/maximum clamp、产品最小可用尺寸与screen bounding同步裁限两轴。方向变化保留用户windowed canvas长边并继续保持无letterbox。
7. fullscreen 中横竖屏切换不改变系统 fullscreen window frame；退出 fullscreen 后按当前稳定 presentation ratio 和进入前的 windowed 用户尺度恢复。
8. 默认范围内无source、Camera denied和source unavailable继续使用统一placeholder reservation。Reachability与额外显示器/scale是独立未测试场景，转由`DV-011`和`DV-014`管理；将来验证失败时重新打开本问题或创建更精确OBS。
9. orientation/geometry 提交时旧 pointer interaction被取消、overlay清除；新方向下 canvas tap/drag 的 normalized coordinates 命中实体设备预期位置，不出现显示横屏但按竖屏映射。
10. 自动化覆盖same-epoch format transition、resolution-only change、outlier debounce、fullscreen state、actual minimum width reconciliation、初始portrait/landscape零letterbox、所有边角逐callback resize、screen bounding和stale identity；至少一组assembly测试使用真实presented `NSWindow`完成初始binding与live resize断言，而不只验证独立数学模型或adopted width有界。
11. 相关 GUIHost、VideoBinding、pointer、Runtime geometry、packaging 回归、clean `make check` 和适用 M2-900 Gate 全部通过，并记录修复提交、设备/OS、帧尺寸序列、geometry revisions、窗口尺寸和剩余风险。
12. 用户尚未建立windowed尺度时，placeholder及首次portrait/landscape binding使用`375 pt` preferred canvas短边；Retina `2x`下约为`750 backing pixels`，但实现和验收必须以AppKit points为authority。另一轴按current presentation ratio派生，屏幕不足时等比例缩小；当前标准主显示环境且布局可行时，portrait canvas/content/frame短边约为`375 pt`。该口径取代先前`640 pt` preferred长边及`340...360 pt`宽度目标，且不得引入letterbox、裁剪设备像素、缩小标准hit target或让toolbar/source controls覆盖canvas。
13. packaged实体从所有边和角连续拖动时，每个可见resize阶段都按`frameHeight = canvasWidth / currentPresentationRatio + sourceControlsHeight + actualWindowChromeHeight`联动两轴；不能出现拖动期间或结束后的白边/黑边，也不能只依赖约416 ms settling把自由变形事后拉回。原始`NSWindow.frame.width / frame.height`无需为常量，禁止用包含固定controls的`contentAspectRatio`冒充该关系。
14. 当实体display已稳定改变方向但运行中的AV capture继续输出旧方向outer dimensions并在其中letterbox新framebuffer时，产品在有界deadline后自动重协商同一已证明source的capture pipeline；不要求关闭/重开Live，不改变sourceID/sourceEpoch、Runtime/Helper generation或Rotate单请求语义。失配和重协商期间GUI pointer在`mouseDown`前fail closed，恢复后新presentation与actual geometry一致且稳定windowed零letterbox。
15. live窗口必须有产品认可的最小可缩放下限。该下限不能只等于AppKit技术最小宽度或source controls理论宽度；实体拖动到最小时，视频画布仍可辨认、source controls/toolbar不破碎、窗口观感合理，且不会把低于该下限的尺寸保存为用户windowed尺度。具体point数值可由修复者结合当前主显示、toolbar/source controls布局和PRD/TRD合同冻结，但必须有自动化和packaged实体证据。

### 解决记录

2026-07-26 已按强制顺序先更新PRD，再更新TRD root/04/06/08和TODO/Pitfalls，冻结四类authority、持续enqueue、formatRevision/debounce、geometry acceptance、actual minimum-width reconciliation和fullscreen状态机。该独立docs-only基线早于production实现提交。

同日 source commit `3a9f6bd`完成presentation dimensions、same-source/same-epoch持续enqueue、3-frame/400 ms debounce、stale timer fence、presentation/geometry convergence、black letterbox、native toolbar overflow、actual minimum-width两次reconciliation及fullscreen/windowed尺度实现。46项focused测试、clean 647项Swift测试和clean `make check`全部通过；2项需要显式实体环境变量的测试保持skipped。尚未从fresh packaged app执行portrait -> landscape -> portrait、fullscreen中旋转、用户resize、Reachability和current geometry tap/drag实体关闭标准，因此状态保持`open`。

同日 fresh candidate source `6d2538a` / app hash `5bef1476...b6349`在QuickTime/player absent时从既有0600 operator-confirmed opaque mapping自动恢复；正式GUIHost日志证明`sourceEpoch=3 / formatRevision=1 / 1170x2532 portrait`真实sample持续递增，public screenshot返回真实device PNG，且Runtime只发生一次预期`generation 1 -> 2` post-capture replacement。Mac桌面仍锁定，尚不能验证可见canvas、旋转、resize、fullscreen和current-geometry pointer，因此这些preflight事实不满足第2、5～9项关闭标准，状态保持`open`。

同日 source `523a4b7`的fresh packaged physical checkpoint在同一`sourceEpoch=5`完成两轮portrait/landscape/portrait，format revisions依次为`1:1170x2532 -> 2:2532x1170 -> 3:1170x2532`，fullscreen中再到`4:2532x1170 -> 5:1170x2532`，sample sequence全程持续增长。实际最小窗口`296x738`无白边；扩大到`651x851`时只有black letterbox；fullscreen系统frame始终`1512x909`，退出后按current presentation ratio和进入前实际canvas长边恢复为`412x889`。portrait current-geometry tap命中Calculator `2`，截图SHA-256=`221817be7d91dc708c6a9273cf3bdd04fea381d24dd850cc34867c9ce7e3301c`；fullscreen landscape tap命中`3`并形成`23`，截图SHA-256=`159b78a123caf2e109a38b6a97628156acbc852aab8d3efbc73af3128192d279`。第2、5、7、9项默认产品实体部分通过；Reachability未测试，第8项完整关闭标准仍不满足，状态保持`open`。

clean `4b6a0a0`的完整`make check`与M2 Gate、exact `27bf04a` candidate的最终close/relaunch/cleanup均通过。2026-07-26治理拆分后，已确认的最小宽度、动态format、fullscreen/windowed和current geometry缺陷均已有实现、自动化与packaged实体证据，OBS-006标记`resolved`。未执行的Reachability和额外显示环境不代表已知失败，分别转入`DV-011`和`DV-014`；将来验证失败时重新打开或创建更精确OBS。

### 重新打开记录（2026-07-26）

- owner在当前默认显示环境重新运行packaged live后确认两项稳定可复现的产品失败：首次portrait/landscape windowed画面两侧存在黑边；从窗口边角拖动时实际宽高不按current presentation ratio持续联动。两项均发生在默认产品入口，不命中`DV-011`或`DV-014`。
- 代码审计确认`LiveWindowReservation`以`canvasHostWidth = max(canvasWidth, fittedMinimumContentWidth)`允许host独立变宽，`ProductionGUIHostCanvasHost`随后通过aspect-fit把真实画面居中到黑色host；现有unit/assembly测试还显式接受minimum-width black letterbox，presented-window测试只断言adopted width有界，没有证明初始portrait/landscape或真实live resize后零letterbox。
- 原解决记录中的`651x851` black letterbox只能证明设备坐标没有包含黑边，不能证明窗口几何满足owner已确认的“稳定windowed不能有白边或黑边”。因此先前按较宽black-letterbox fallback合同关闭的结论被本次实体失败取代，状态改回`open`；历史format持续enqueue、fullscreen状态机和current geometry证据继续有效，不要求推倒重做。
- PRD、root TRD、TRD 06与TRD 08已通过先行合同提交`42e0a16`收紧：稳定windowed初始binding、方向变化和逐callback live resize必须零letterbox；minimum width通过toolbar overflow、自适应source controls和双轴同比例裁限解决；黑色letterbox只允许fullscreen或stable presentation尚未提交的有界过渡。
- source提交`46c77f3`移除`canvasHostWidth > canvasWidth`的稳定windowed fallback；minimum width只允许同时扩展两轴，屏幕内不存在可行精确比例时显式返回`minimumContentWidthUnavailable`并保持model事务回滚。source controls采用small control、自适应picker与更低水平compression resistance，programmatic reservation和每次`windowWillResize`共同量化为AppKit可实际采纳的整点canvas尺寸，避免fractional frame被向外取整后重新产生黑边。
- 自动化checkpoint：12项`LiveWindowTests`和30项`ProductionGUIHostAssemblyTests`通过；真实presented `NSWindow`分别覆盖portrait/landscape初始adoption及每个方向8组宽、高、边角resize callback，断言canvas host、video和interaction边界在0.5 pt像素采纳容差内一致。另14项display assembly、12项presentation/performance collector和16项VideoBinding测试通过；共84项focused、0失败。
- `d4492fd` source的fresh packaged candidate（candidate SHA-256=`e3cca2884538aa12b2e0f65d57fff40de2707d37f84ff1eb0dc16e5543d6f18c`，app hash=`f4f2a4a706c815ce61fa61e22678b97c3d6235456140f81826af5dd3def6c313`）实体复测推翻了“delegate返回约束尺寸即代表AppKit最终双轴采纳”的测试假设。portrait初始窗口`396x949`已无左右黑边，截图SHA-256=`1e283a4cd827480bb255d1febbe926216ceb01133b4abf496819eb554079189a`；随后从窗口边缘缩窄时实际frame变为`352x949`，截图SHA-256=`4e76878687e72ba7e4ca1089aa11fd09be8f1d86e055d4c9b53dc45646f88972`，AppKit只采纳宽轴并在上下产生黑边。该失败发生在fresh packaged默认入口，不命中Deferred Validation，状态保持`investigating`。
- source提交`99c1eb3`让每次`windowWillResize`保存reference frame与期望双轴frame；`windowDidResize`若发现AppKit只采纳拖动轴，立即按实际移动边保留对边、在派生轴保持中心、裁限visible frame并执行一次带重入保护的programmatic reconciliation。fullscreen transition、programmatic reservation和close会清除pending live-resize状态。真实presented `NSWindow`回归不再直接应用约束frame，而是先模拟只采纳宽轴或高轴，再通过production `windowDidResize`链断言最终frame、canvas host、video与interaction零letterbox。
- 自动化checkpoint：31项`ProductionGUIHostAssemblyTests`通过；合并12项LiveWindow、14项display assembly、12项presentation/performance、4项source handoff和16项VideoBinding后共89项focused、0失败。
- clean `0dcb796`已通过672项Swift（2 physical opt-in skipped、0失败）和完整`make check`，fresh candidate文件SHA-256=`1869df581ea91aad62a8ce736fbb6875fef0203ba02cc8b650247c14623bc9de`、app hash=`17db13f193a005dcdcd1d9374fba34c680e7580a4e490fd2bf0ea3177d94ccfb`，deep/strict codesign与zero `.pyc/__pycache__`通过。关闭旧GUIHost/Runtime并从该exact package重启后，portrait初始仍为`396x949`零侧边；同一单轴缩窄操作最终仍变为`352x949`并出现上下黑边，截图SHA-256=`0b4cc2f2545b607d6327ea1801c80808f6d231477744d48174fbad60433f156a`。结构化日志没有`partialAxisAdoption`记录，证明同步`windowDidResize`曾在AppKit最终单轴采纳前把暂时exact的pending清除。
- source提交`2d2e11d`不再把同步`windowDidResize`视为最终采纳点：pending sequence贯穿整个live-resize，每次didResize只安排下一main-run-loop turn核对，`windowDidEndLiveResize`后再延迟一次final reconciliation并随后记录用户canvas尺度。回归先让delegate看到一次exact frame，再无第二次didResize地把真实`NSWindow`改成单轴frame，只有延迟核对能恢复期望双轴尺寸。31项GUIHost assembly与最终89项相关组合测试通过；一次既有pointer reconnect组合超时在exact case连续3次复跑均通过，随后完整89项重跑通过。
- clean `7428dc1`已再次通过672项Swift（2 physical opt-in skipped、0失败）和完整`make check`。正式packaging产出的candidate文件SHA-256=`bca3cf6d2d42d574206fb0e8650ac155c17bf33a147aaa4ae2719b9b45c403ce`、release input hash=`c799dd02668549711c72e22763ff7ea44d9a506dafd7e52b84ace8c122fb4c98`、app hash=`cc8e08f6fa75e86f55f38899e9175d52620234551a4573b2e3321796c98482b1`，deep/strict codesign与zero `.pyc/__pycache__`通过。关闭旧candidate并从该exact package启动后，portrait初始为`396x949`零侧边，截图SHA-256=`7de4f98dd27edf2c0f7e5a131dd0e155970bf60d2c2d26d58911dc381a6c2c36`；同一右下边缘单轴缩窄仍最终变为`352x949`并出现上下黑边，截图SHA-256=`bf1fb7d0b4c8056a2c79c0e30d77ebc648102759f799535c9f5e48201e99d52c`。正式GUIHost日志仍没有`partialAxisAdoption`，说明一次next-run-loop和end-live-resize后的延迟核对仍早于或未覆盖WindowServer最终单轴frame；状态保持`investigating`。
- source提交`1c84db9`把live resize收尾改为有界settling状态机：`windowWillStartLiveResize`冻结起始frame，`windowDidEndLiveResize`保留或在pending缺失时从起始/最终frame合成expected双轴尺寸；随后最多7个有界checkpoint跨约416 ms观察`inLiveResize`和actual/expected frame，只有至少到第4次且连续2次无需reconciliation仍exact才记录用户canvas尺度。任何晚到单轴frame都会重新执行有边缘保持和visible-frame裁限的双轴setFrame，并重置稳定计数；新resize sequence、programmatic reservation、fullscreen与close会取消旧settlement。presented `NSWindow`回归新增“end后80 ms才单轴回退”和“缺失windowWillResize pending”两条production路径；31项GUIHost assembly及最终89项OBS-006/008相关组合测试均0失败。
- clean source `c82a8be2eaa8ff94c7469e6a4da4f167c31825df`通过31项GUIHost assembly、最终89项OBS-006/008 focused组合、672项Swift（2项physical opt-in按合同skipped）和完整`make check`。正式candidate为`build/evidence/objects/8d52f233774c2884ad68c9c960edc31b96375b9bda9201610a9412b77031a133/release-candidate-input.v1.json`，文件SHA-256=`e583977d99493b7d801f3b8f8ae31dc28f29113de00bc7a7138e320d3474328e`，release input hash=`64000a0b604bb324a12f36d80ba72162282483b0b17d8ab4ff621489502caf80`，app hash=`c61abe13adfb69e3eb077b2add79f73fca210d2e3d986ae8fd486f18eaee7e28`；deep/strict codesign与zero `.pyc/__pycache__`通过。
- 同一exact candidate在当前iPhone 14 / iOS 26.5.2和主显示环境完成最终实体闭环：portrait初始`396x949`零侧边；同一缩窄曾由WindowServer晚到采纳为`352x949`，但`windowWillResize`缺失路径由`windowDidEndLiveResize`合成pending，日志连续记录`synthesized=true`、partial-axis reconciliation和settlement attempt `0...3`，最终恢复`396x949`。portrait初始与settled截图SHA-256分别为`1e283a4cd827480bb255d1febbe926216ceb01133b4abf496819eb554079189a`和`84eb09c7a6325d62e2d0c1d4d45fb9198e76ac7c08f3104778de4a40c231afab`。
- landscape Calculator继续覆盖右侧/边角缩小`753x440`、左侧`699x415`、高度主导`634x385`、边角放大`738x433`；fullscreen系统frame为`1277x768`，退出后精确恢复`738x433`。current-geometry tap命中Calculator `3`，drag真实完成；后续Home portrait与Calculator landscape的format revisions `3:1170x2532 -> 4:2532x1170`仍持续显示。窗口正常关闭后Helper退出，public `stop --json`返回`stopped`，exact Runtime socket、Helper manifest和epoch scratch均absent，GUIHost仍存活且没有新增PulsePhone `.ips`。
- 结论：重新打开后确认的初始letterbox和live-resize单轴采纳已满足全部默认关闭标准，状态恢复为`resolved`。Reachability和额外display/scale组合继续分别由`DV-011`、`DV-014`保持`deferred`，不计为通过，也不反向保持本OBS开放。

### 第二次重新打开记录（2026-07-26）

- owner基于当前packaged live截图和直接操作补充默认产品要求：稳定windowed始终不得出现白边或黑边；拖动任意窗口边或角时宽高必须持续联动，不能先自由改变window frame再由aspect-fit或拖动结束后的settling掩盖；当前初始portrait窗口视觉占用仍偏大，应在不牺牲画布、hit target和controls边界的前提下明显缩小。
- 当前截图中的顶部native toolbar与底部source controls属于window chrome/非设备坐标，不是letterbox；本次“比例固定”不要求原始outer frame的`width / height`为常量。合同关系冻结为`canvasWidth / canvasHeight = currentPresentationRatio`以及`frameHeight = canvasHeight + sourceControlsHeight + actualWindowChromeHeight`，拖动一轴时必须同步派生另一轴。
- 代码审计确认当前默认`LiveWindowReservation.preferredCanvasLongEdge=720 pt`，portrait先从canvas高度计算宽度，但`actualMinimumContentWidth`可以反向抬高两轴，因此当前窗口看起来接近按高度撑满。只降低默认长边不足以保证缩小；实现还必须通过toolbar overflow、紧凑自适应source controls和可诊断minimum-width owner降低实际初始宽度。
- PRD、root TRD、TRD 06与TRD 08已在独立合同提交`1cf090a`冻结：默认preferred canvas长边改为`640 pt`；当前标准主显示环境在布局可行时优先采用约`340...360 pt`的portrait content/frame width；稳定windowed继续零letterbox，live resize使用带固定controls/chrome偏移的双轴派生关系，禁止直接设置包含controls的`NSWindow.contentAspectRatio`。
- 建议实现继续复用现有`LiveWindowModel`、`LiveWindowReservation`、`ProductionLiveWindowSizing`和bounded adoption reconciliation：将默认preferred长边改为`640 pt`；为secondary toolbar item设置更积极但稳定的overflow优先级；压缩source controls非权威文本和水平阻力；在每次`windowWillResize`及WindowServer实际采纳阶段验证派生双轴尺寸。不得另建第二套窗口系统、允许稳定windowed letterbox或缩小标准hit target。
- 当前唯一下一动作：从clean `1cf090a`合同读取新范围，先建立默认`640 pt`、portrait compact width、真实presented `NSWindow`逐callback无letterbox和minimum-width owner回归，再修改production sizing；随后运行相关GUI/Video/pointer测试、clean `make check`、fresh package，并在当前可用实体环境完成初始portrait/landscape、所有边角resize、fullscreen退出和current-geometry pointer复测。实体iPhone暂时offline时先完成源码与自动化，不得把已观察的默认窗口要求转入Deferred Validation。
- 2026-07-26 owner sizing correction：合同提交`e0d73eb`取代上述`1cf090a`中的`640 pt` preferred canvas长边和约`340...360 pt` portrait宽度。owner基于`766 px`短边截图与实际视觉确认，将compact initial修正为canvas短边`375 pt`，在Retina `2x`下约为`750 backing pixels`；points是唯一布局和测试authority，不能把`750`直接写成跨显示器像素硬编码。按iPhone 14 portrait `1170x2532`比例，preferred canvas约为`375x811.5 pt`，再加入固定source controls与实际window chrome。
- 本次修正只改变用户尚未建立windowed尺度时的initial reservation，不放宽稳定windowed零letterbox、逐callback双轴联动、minimum/maximum clamp、fullscreen状态机、方向变化后用户尺度保留或current-geometry pointer要求。若visible frame不足，允许按比例缩小；若不可压缩controls要求更大短边，必须记录minimum-width owner并证明约束真实不可压缩。
- 建议实现继续复用现有reservation管线，但语义应从`preferredCanvasLongEdge`改为`preferredCanvasShortEdge`，不能只把旧常量数值改成`375`或`750`。portrait以width、landscape以height作为preferred短边，按current presentation ratio派生长边，再统一应用source controls、实际chrome、visible frame和可诊断minimum-width约束。
- 当前唯一下一动作：基于本次owner correction修正production sizing与现有compact/minimum-width回归，验证默认`375 pt`短边、portrait/landscape初始零letterbox、真实presented `NSWindow`和所有边角逐callback固定比例；随后运行相关GUI/Video/pointer测试、clean `make check`并生成fresh package完成实体尺寸、resize、fullscreen退出和current-geometry pointer闭环。
- source提交`4e7c179`将默认initial reservation从`640 pt`长边模型改为`375 pt`短边模型，并把用户完成live resize后的长边尺度保留为独立可选authority；portrait以width、landscape以height建立初始短边，visible frame不足时仍沿现有比例约束缩小。source controls不再用包含picker/status自然展示文本的`fittingSize`冒充minimum，而按insets、stack spacing、picker最小宽度、四个标准button和progress indicator声明`234 pt`不可压缩minimum；只有Home、App Switcher和Rotate保持high toolbar visibility，其余item稳定进入overflow。
- 同一提交还修复了真实presented `NSWindow`回归暴露的minimum authority竞态：若已知controls minimum只在首次frame之后异步写入model，晚到programmatic reservation会在用户resize settlement开始后清除pending sequence。production现在在窗口组装和首个frame前同步建立`234 pt` minimum，避免initial reconciliation覆盖live-resize authority。
- 自动化checkpoint：13项`LiveWindowTests`与34项`ProductionGUIHostAssemblyTests`共47项focused通过；完整`PulsePhoneGUIHostTests`通过134项、0失败。真实presented window覆盖长source/status展示文本、当前主屏不足时约`366 pt`等比例短边、portrait/landscape零letterbox、所有边角逐callback约束、end后80 ms单轴回退、missing callback settlement及pointer并发路径。
- 当前状态仍为`investigating`。唯一下一动作：从clean `4e7c179`运行完整`make check`，重新生成exact signed packaged candidate并核对hash/codesign/tree；随后在当前iPhone完成初始portrait/landscape短边、所有边角连续resize、fullscreen退出、方向切换视频连续性与current-geometry pointer实体闭环。
- 2026-07-27 source checkpoint：commit `2544e70`补齐fresh initial binding所需的capture-ready actual geometry采纳。首个AV mapping只有在已持有同epoch、同尺寸的actual geometry时才沿用其revision；否则使用`geometryRevision=0`的不可交互provisional lineage绑定视频，既不建立pointer authority，也不再把横屏尺寸猜成left/right handedness。Runtime receipt到达后原子更新Live model、pointer controller、interaction view与current video binding；receipt早于`videoSession`安装时会在session安装后重试，同activation并发refresh合并，duplicate capture-ready同步current display geometry但不替换既有Helper generation。5项RuntimeClient、38项GUIHost assembly、41项Runtime assembly（2项physical opt-in skipped）、完整138项GUIHost、73项Product Action和clean 689项Swift/完整`make check`均通过，registry/generated/current-contract checks全部通过。当前仍需fresh packaged实体证明compact initial portrait/landscape、所有边角连续resize、fullscreen退出、format连续性和current-geometry pointer；状态保持`investigating`，唯一下一动作是从clean docs HEAD生成exact signed candidate并执行该共享实体Gate。
- 2026-07-27 packaged partial checkpoint：exact candidate source=`ebb9b47`、candidate file SHA-256=`67daedf1e14ef8ad702516acf29ecdf17473fe7e8500bf3a3b56beb812f34381`、release input hash=`c594ef6561736a1112be908785c693b4090ab2de3471f8befe0738c3bcd579ba`、app content hash=`62083f4f5565a4c0ab5db8a8dd0780a8d62a0c9d303a73f1639bfa092155ddd9`。当前iPhone 14 / iOS 26.5.2在设备已为actual `landscapeLeft`时fresh启动，Live以`sourceEpoch=5 / formatRevision=1 / 2532x1170`持续递增sample，capture-ready receipt建立`geometryRevision=1 / landscapeLeft`；首个current-geometry tap真实改变Calculator，随后portrait与`landscapeLeft`切换期间format/sample继续前进且无freeze。该结果关闭fresh initial-landscape handedness、该方向format continuity和current-geometry pointer子集；同一exact candidate尚未复跑compact portrait initial、所有边角连续resize和fullscreen exit，状态保持`investigating`，唯一下一动作仍是以包含最终rotate trace的fresh candidate完成共享GUI实体Gate。
- 2026-07-27 final candidate failure checkpoint：exact source `f630659` / release input hash=`e8359a9293d94530ef24df89139a44132877244c1b82d385b018774d88d2441d`从fresh `landscapeLeft` Live执行GUI `right`，Helper日志只出现一条`requestSent`，148 ms返回success且public device screenshot为`1170x2532` portrait；但AV Live长期保持约`818x378` landscape outer canvas，把portrait framebuffer居中并产生大面积黑边。GUI一度显示`Controls awaiting geometry`，随后仍接受pointer p0/p1/p2，Runtime cached geometry revision 2发送的实体tap把Calculator `484`误操作为`484%`，证明presentation失配没有在GUI admission前fail closed。CLI `left`单请求返回`landscapeLeft / 2532x1170 / revision 3`后Live恢复；再次进入portrait仍复现旧outer format。关闭并重开Live后，同一opaque source立即重新协商为`sourceEpoch=5 / formatRevision=1 / 1170x2532`，窗口恢复约`366x792`零letterbox，说明缺口是运行中capture negotiation而非source mapping、Runtime geometry或设备display。失败trace为0600 complete canonical JSONL，SHA-256=`5c8a4523b159c571fbd4b2b4bfd8d999f862ef131509703af7f09e1548a18dcb`；public stop后Runtime/Helper/socket/manifest/lock holder均absent。现有合同未覆盖persistent outer-format mismatch，已先补充有界同source capture reconfiguration和全程pointer convergence fence；状态保持`investigating`。
- 2026-07-27 source checkpoint：commit `00017f6`在actual geometry推进但committed outer presentation仍为相反class时，为每个geometry revision至多安排一次600 ms后复核；复核仍失配才串行停止当前AV session、排空旧video/audio callback、按同一device unique ID重建input/output negotiation并恢复运行。mapping proof、sourceID/sourceEpoch、frame sequence、format tracker、Runtime attachment和Helper generation均不重建；自然format收敛会取消重协商，stop竞态会在session重启前再次核对owner。Rotate先在model/controller副本验证，再采纳exact video binding；已绑定video的pointer admission还必须同时匹配committed presentation sourceEpoch、orientation class和binding geometry revision，首帧前、失配和重配期间均在p0前fail closed。14项performance collection与39项GUIHost assembly focused回归通过；clean `make check`通过695项Swift（2项physical opt-in skipped）、7项registry Python、14项bootstrap contract及29项current/evidence，0失败。状态保持`investigating`；唯一下一动作是从clean docs HEAD生成fresh signed candidate，在当前iPhone证明同一source自动恢复portrait/landscape零letterbox、只出现一次scheduled/succeeded、Runtime/Helper lineage不变且恢复前无pointer p0，再完成resize/fullscreen共享Gate。
- 2026-07-27 fresh `c9f4c82` candidate failure checkpoint：candidate file SHA-256=`ed1fc1faa37350a6ddb0da699866eec0d8920dc79c96cfc99b878511e0d2c714`、release input hash=`c5e690cc6e53e712f48aa14df578cde07840a91f83821c04d4325ff7e7ea77aa`、app content hash=`0a84a2ba9a3c6b513794089ff07663b912236a0497ffd59be953b0f53c791056`。fresh portrait Live固定为同一source、`sourceEpoch=5`、GUIHost/Runtime/Helper generation不变；首个GUI `right`以一条`requestSent`在144 ms成功，AV于41 ms内自然交换到`2532x1170`，因此只记录一次reconfiguration `scheduled`和一次`cancelled`，窗口自动到`818x378`零letterbox。连续第四个GUI `right`以一条request在267 ms成功并把实体内容推进到portrait，但Live长期保留landscape outer canvas、portrait framebuffer居中及大面积黑边，且没有任何`captureReconfiguration scheduled`，证明`00017f6`的persistent mismatch分支在Rotate到video-session rebind/schedule之间仍有漏失。GUI持续显示`Controls awaiting geometry`，失配点击只产生`admission/geometryUnavailable`且没有p0，说明OBS-008的convergence fence已生效；当前唯一下一动作是确认并修复该rebind/schedule拒绝分支，补精确sequence回归后重新package，再执行resize/fullscreen闭环。
- 2026-07-27 root-cause/source checkpoint：LLDB在失败的第四次Rotate直接观察到incoming geometry为`connectionEpoch=1 / geometryRevision=15 / 1170x2532 portrait`，当前GUI model为`revision=14 / landscapeLeft`；revision和geometry均合法，但`LiveWindowModel.updateRuntimeGeometry`先抛出`minimumContentWidthUnavailable`，没有进入`ProductionBoundVideoSession.rebindGeometry`。直接根因是`reconcileActualMinimumWidth`曾把landscape下AppKit当次采用的约`816 pt` content width提升为长期`actualMinimumContentWidth`，切回portrait后该伪minimum要求约`1,870 pt`窗口高度，因而在capture reconfiguration producer之前事务失败。source `9bf785f`改为只有声明式`sourceControlsMinimumContentWidth`拥有跨方向minimum authority；AppKit adopted width只记录`stage=adoptedContentWidth`诊断，不再污染下一方向。真实presented `NSWindow`回归覆盖`portrait -> landscape -> portrait`并证明返回portrait后canvas精确、content width `<396 pt`且不出现`Window geometry unavailable`；39项GUI assembly、14项performance collection和13项LiveWindow focused均通过。一次clean全量运行的唯一失败是已记录的pointer reconnect时序用例，exact case随后连续3次通过；最终clean `make check`和fresh packaged实体共享Gate仍待完成，状态保持`investigating`，唯一下一动作是提交本checkpoint后从clean HEAD复验并重建candidate。
- 2026-07-27 clean Gate checkpoint：两次长时全量运行让既有`testPointerCloseAndCancelFailureReconnectsRuntimeSession`稳定暴露测试竞态：replacement session只等待attach、未等待availability就立即提交第二个gesture；production没有对应失败。test-only commit `56a256e`补齐与首个session相同的availability ready边界，exact case连续3次和完整39项GUI assembly均通过。clean HEAD随后完成695项Swift（2项physical opt-in按合同skipped、0失败）、7项registry Python、generated Swift/Python、14项bootstrap contract及29项current/evidence，完整`make check`通过。状态仍为`investigating`；唯一下一动作是从新的clean docs HEAD构建fresh signed candidate并执行连续Rotate、auto reconfiguration、pointer、resize/fullscreen共享实体Gate。
- 2026-07-27 final packaged closure：exact clean source=`6f9ad15292f095e5fe8b96bc71e0b0b58b9063fb`；candidate=`build/evidence/objects/66ca0b287f59ca43690d4d682820d1e21804f863fddb6a1441d735b405c573b1/release-candidate-input.v1.json`，file SHA-256=`3e54b81714d517d0df8fffd3d3f2f9922d1d628750861d4ae8419b8119c3020a`，release input hash=`8127f861fa9ff8b874444dbb8763f171921736c512be1337d5d61e8df9dfc2dc`，app content hash=`bd55056156b5d69eb107b12ca8796fe490015bcf05903db822be90922cfd4e9a`。此前同source的clean `make check`通过695项Swift、2项physical opt-in skipped、0失败，并通过Python、generated、bootstrap及current/evidence Gate。
- 当前iPhone 14 / iOS 26.5.2在同一`sourceEpoch=5`、GUIHost/Runtime/Helper lineage和Helper generation 2不变的条件下完成12次连续GUI Rotate；portrait、两个landscape handedness、unsupported `outcomeUnknown`后的actual geometry恢复和回到portrait均持续推进sample/presentation且稳定windowed零letterbox。两次`captureReconfiguration scheduled`均因AV在600 ms deadline前自然收敛而正确`cancelled`；本次实体链路没有触发持久失配，所以不能把`scheduled -> succeeded`写成实体结果。production assembly已强制覆盖持久失配的单次restart、lineage保留、stop fence和恢复前pointer拒绝。
- 同一窗口从八个边/角依次完成live resize：`816x469 -> 935x524`、`935x524 -> 976x543`、`976x543 -> 937x525`、`937x525 -> 859x489`、`859x489 -> 805x464`、`805x464 -> 751x439`、`751x439 -> 699x415`、`699x415 -> 647x391`。每个sequence均记录start/end、partial-axis reconciliation并在attempt 3前达到exact expected frame；实体画面无白边/黑边。
- landscape fullscreen约`1278x768`；fullscreen内Rotate到portrait时系统管理frame保持不变，Escape退出后按用户建立的`647 pt` canvas长边恢复为portrait outer约`299x739`、canvas `299x647`，随后current portrait pointer产生p0/p1/p2并真实改变Calculator。默认范围关闭标准全部满足，状态标记`resolved`；rare orientation reachability和其他display/scale组合继续由`DV-011`、`DV-014`保持`deferred`，不计为通过。
- 2026-07-27 clean Gate重新打开checkpoint：exact source `0dfac30`连续两次完整Swift运行均在`ProductionGUIHostAssemblyTests.testPresentedWindowUsesNativeToolbarOverflowAndAdoptedContentWidth`得到presented portrait content width=`377.0 pt`，稳定超过测试冻结的`preferredCanvasShortEdge + 0.5 = 375.5 pt`；两轮均为694项、2项physical opt-in skipped、仅此1项失败。独立AppKit probe证明普通`375 pt`content round-trip可精确采用，因此不能把失败笼统归因于frame/content换算；当前唯一下一动作是确认native toolbar/current presentation条件下`377 pt`属于应被消除的无owner扩张，还是合同允许且应显式验证的AppKit adopted-width诊断，再完成最小源码/测试修复和clean Gate。
- 2026-07-27 test root-cause checkpoint：单独运行同一真实window用例得到screen visible frame=`1512x949 pt`、最终frame=`366x884 pt`、content=`366x844 pt`、canvas=`366x792 pt`并通过原`375.5 pt`边界，证明production最终compact reservation正确。全量顺序中`waitForExactCanvas`只等待ratio与三层bounds一致，可能在异步`reconcileActualMinimumWidth`完成前返回并读取临时`377 pt`；test commit `a95475a`在原断言前有界等待最终content width进入既有compact boundary，不放宽产品尺寸、不修改production sizing，也不把adopted width写回长期minimum。完整39项`ProductionGUIHostAssemblyTests`通过。随后一次dirty-worktree `make check`的4个failure全部来自两个packaging测试按合同拒绝未提交文档，并非本修复回归；当前唯一下一动作是在clean docs checkpoint上运行完整`make check`，通过后恢复`resolved`。
- 2026-07-27 root-cause correction/source checkpoint：clean `8b3eb73`完整Swift再次让新增等待超时并停在`377 pt`，推翻“纯测试读取过早”的结论。bounded diagnostic `5d7fef7`确认没有固定前置测试类可复现该状态；源码审计进一步确认programmatic reservation期望当前主屏portrait content=`366 pt`时，native toolbar首次layout可临时采用`377 pt`，`reconcileActualMinimumWidth`虽记录`adoptedContentWidth`，却只有声明式minimum数值变化才消耗第二次`setFrame`，因此偶发screen/layout callback会掩盖production缺口，缺少callback时窗口永久停在临时宽度。source `88e1742`把“actual adopted width仍比desired宽超过0.5 pt”并入既有每revision最多两次的bounded retry，同时继续只让`234 pt` source-controls声明拥有长期minimum authority；不持久化`377 pt`，也不放宽`375.5 pt`断言。40项`ProductionGUIHostAssemblyTests`和修复前用于捕获非确定性的clean 694项Swift（2项physical opt-in skipped）均0失败；当前唯一下一动作是在clean docs checkpoint运行完整`make check`，通过后恢复`resolved`。
- 2026-07-27 clean closure：exact source=`88e1742`，clean docs/Gate HEAD=`3349043`。完整`make check`通过695项Swift，2项physical opt-in按环境合同skipped、0失败；真实presented-window用例在完整packaged performance/product-matrix前置负载后通过原`375.5 pt`边界，40项GUIHost assembly、registry/generated Swift与Python、doctor、structure、bootstrap及29项current/evidence checks全部通过。该修复只消耗既有第二次programmatic reservation，不改变长期minimum、presentation、resize/fullscreen或实体input合同；此前exact `6f9ad15` packaged实体resize/fullscreen/方向证据继续有效。OBS-006恢复`resolved`；当前被packaging测试替换的staging bytes不冒充旧实体candidate，最终共享fresh package仍由剩余OBS收尾Gate复核。
- 2026-07-28 owner regression checkpoint：owner确认当前产品中live窗口拖动时仍会先出现白边，松手后才自动校正宽高比；进入fullscreen后会自动缩放回非fullscreen。只读源码审计确认当前production仍主要依赖`ProductionGUIHostWindowController.windowWillResize`返回期望frame、`windowDidResize`/next-run-loop reconciliation和`windowDidEndLiveResize`后的bounded settlement修正AppKit实际采纳结果；`reconcilePendingLiveResize`会在检测到`partialAxisAdoption`后再调用`setFrame`。这与关闭标准第13条“不能只依赖约416 ms settling把自由变形事后拉回”冲突。窗口创建时未设置专门的fullscreen `collectionBehavior`，fullscreen状态机由`LiveWindowModel.windowWillEnterFullscreen/windowDidEnterFullscreen/windowWillExitFullscreen/windowDidExitFullscreen`与GUIHost回调维护；若当前产品fullscreen后自动缩回，说明此前fullscreen实体闭环证据已不再覆盖当前candidate。状态重新打开为`investigating`。
- 2026-07-29 owner补充确认：当前live窗口可以缩放到很小，观感很差；本条新增产品最小可用尺寸要求。该要求与白边/松手校正同属windowed live resize体验，不能转入Deferred Validation。
- 当前唯一下一动作：从fresh packaged app采集当前candidate、macOS/显示器和实体设备信息，分别记录拖动四边/四角时`windowWillResize`、`windowDidResize`、`windowDidEndLiveResize`、`liveResizeSettlement`、`partialAxisAdoption`日志与可见白边截图，并记录当前可缩到的最小窗口/content/canvas尺寸及主观不可接受表现；同时验证fullscreen进入/退出事件序列、`windowState`、是否有非fullscreen阶段`setFrame`或screen/geometry callback触发缩回。修复方向必须保持合同定义的派生关系`frameHeight = canvasWidth / currentPresentationRatio + sourceControlsHeight + actualWindowChromeHeight`，不得用包含固定controls/chrome的`NSWindow.contentAspectRatio`冒充比例约束；新增最小尺寸下限也必须按该关系双轴生效。
- 2026-07-29 fresh reproduction：使用上述exact `35a5dfe` / app hash `58f2881e...9934` candidate，fullscreen进入/退出本轮正常，退出后reservation恢复portrait canvas `366x792 pt`。随后从右下角向内拖动，WindowServer先采用frame `276x676 pt`；`windowDidEndLiveResize`才以`synthesized=true`生成expected `268x672 pt`，随后`partialAxisAdoption`和settlement attempts `0...3`完成事后校正，最终canvas仅`268x580 pt`。这同时复现“松手后才校正”和产品minimum过小；已有`windowWillStartLiveResize`的missing-pending fallback只在end边界生效，不能满足逐callback合同。
- contract `fc946a1`在production修改前冻结`minimumWindowedCanvasShortEdge=320 pt`，与`375 pt`initial preferred和AppKit技术minimum分离；portrait以canvas width、landscape以canvas height执行。TRD同时要求missing `windowWillResize`或partial-axis adoption由同轮`windowDidResize`基于start/adopted frame同步约束，settlement只验证晚到漂移，不再作为首个可见修正边界。command-matrix与current-contract gates通过。
- 当前唯一下一动作：实现orientation-aware `320 pt` effective minimum、`windowDidResize` missing-pending同步fallback和重入fence，补portrait/landscape/screen-bound/minimum持久化及真实presented-window回归；focused与clean Gate通过后生成fresh package复测连续resize和fullscreen。
- source `a0fe6bf`实现orientation-aware产品minimum并与source controls/AppKit技术minimum分离；`NSWindow.contentMinSize`随presentation ratio更新，visible frame不足时只在当次screen-bound路径降低。`windowDidResize`在已有live-resize start但没有`windowWillResize` pending时同步生成expected并以重入fence纠正；fallback后续callback以先前expected作增量主导轴比较、以原drag reference维护移动边，避免锁死首个合成尺寸。model拒绝持久化短边低于`320 pt`的用户尺度。
- focused `LiveWindowTests`、live-resize sizing和真实presented-window共24项通过；完整`PulsePhoneGUIHostTests`通过204项、0失败。真实窗口回归覆盖portrait/landscape `contentMinSize`、screen-bound、missing callback首轮同步纠正、继续拖动刷新expected、partial-axis同轮纠正和canvas/video/interaction exact bounds。该自动化checkpoint尚不能替代fresh packaged连续拖动和fullscreen实体验收，状态保持`investigating`。
- 当前唯一下一动作：在clean worktree运行完整`make check`，从包含`a0fe6bf`及本checkpoint的exact clean HEAD生成fresh signed candidate；在当前iPhone完成portrait/landscape最小短边、四边/四角连续resize逐帧无白边、fullscreen进入/退出不自动缩回及windowed尺度恢复，再完成public stop与产物复核。
- 首次clean全量运行执行771项Swift（2项physical opt-in skipped），唯一失败是未被本次窗口源码触及的Runtime reconnect测试：attachment已nil且`deviceDisconnected`已到达，但异步`projectionInvalidated` reset handler在固定`3.3 s`断言时仍为1而非2；exact原用例随后连续3次通过。test-only `c73dfbf`把该阶段改为等待同一组三个终态，与用例第一次detach已有边界一致；patched exact 3/3及完整51项Runtime assembly通过（2项skipped、0失败），没有改变production时序或放宽终态。
- 当前唯一下一动作：从包含`c73dfbf`与本checkpoint的clean HEAD重新运行完整`make check`；通过后生成fresh signed candidate并执行上述packaged resize/minimum/fullscreen Gate。
- 2026-07-29 clean Gate checkpoint：exact clean HEAD `4705e543bd618d72901b7e7ac6cffa8a7315fda3`的完整`make check`通过；771项Swift中2项physical opt-in按合同skipped、0失败，doctor/structure、registry及generated Swift/Python、7项registry Python、14项bootstrap contract和29项current/evidence checks全部通过。完整输出保存在Git ignored的`build/observations/clean-gate-20260729-2/make-check.log`；状态继续保持`investigating`，自动化结果不替代packaged实体resize/fullscreen验证。
- 当前唯一下一动作：从包含本checkpoint的exact clean docs HEAD生成fresh signed candidate，完成静态产物复核，并在当前iPhone执行portrait/landscape产品minimum、四边/四角连续resize逐阶段零letterbox、fullscreen进入/退出和windowed尺度恢复，随后public stop与进程cleanup。
- 2026-07-30 final packaged closure：exact clean source=`d4440c5179889eeacaa6a335ef50fbafb29530e6`；candidate=`build/evidence/objects/bd720ef6af9afbe91f650ea7e2bbf06789b8e9517c27b8b1a727f50902afb3de/release-candidate-input.v1.json`，file SHA-256=`18177f07aef0f1a1d6e5959ce122e4c13ace5a27d04025726608757e2320595e`，release input hash=`a5156e929153679c3a5e4b2e931f269fc146b1e95671c587c220e5055ea7d99d`，app content hash=`83725e1a2bd20f6bf01d3b7cda004d119d7fce3662e75b973ad1ec5c29f87f66`。Team ID=`GZC4TSS5TG`；deep/strict codesign、manifest/tree exact、embedded Python、zero bytecode和两个release binary的current execution catalog identity通过。
- 实体环境为macOS 26.5.1 (`25F80`)内建Retina主屏`1512x982 pt / 3024x1964 px`与iPhone / iOS 26.5.2 (`23F84`)。23次portrait及1次landscape live-resize start覆盖四边、四角、扩张、缩小、产品minimum和screen maximum；21次有实际adoption的序列均记录`windowDidResizeFallback`，22次记录同轮`partialAxisAdoption`，活跃resize在`windowDidEndLiveResize`前已经exact。三个screen-bound no-op序列虽`synthesized=true`但actual已等于expected；landscape subminimum尝试没有采用过小frame，end只把`697x414`量化到`699x415`，未出现自由变形或letterbox。portrait稳定canvas约`322...323 x 697...699 pt`，landscape稳定canvas约`699x323 pt`，满足orientation-aware `320 pt`短边；最小和恢复画面均观察为canvas/video/source controls exact、无白边或黑边。
- fullscreen进入后frame为`1277...1278x768 pt`，2.5秒有界观察及fullscreen内多次Rotate始终保持系统frame，没有自动缩回；最终portrait presentation下退出后稳定恢复windowed约`322x789 pt`、canvas `322x697 pt`，没有把fullscreen bounds持久化。window geometry日志SHA-256=`de799005e18b9ec03c7a8d731a0232e0ef6d47c0875e5c46a1e701b72224a4c7`，位于Git ignored的`build/observations/OBS-006/candidate-a5156e92/window-geometry.log`。
- normal close后public `stop`返回`stoppedTargetCount=1 / disposition=stopped`，随后`runtime status=notRunning`；Runtime、Helper和exact GUIHost均退出。post-run deep/strict codesign与zero bytecode再次通过。默认范围关闭标准满足，状态标记`resolved`；额外display/scale与rare orientation仍由`DV-014`、`DV-011`保持`deferred`，不计为通过。

### 当前重新打开记录（2026-07-30）

- owner在当前packaged Live窗口向外拖动放大时观察到窗口宽高可见抖动。该现象发生在普通live resize连续阶段，不是初始reservation、minimum过小、letterbox或fullscreen恢复失败。
- 静态根因已定位：`windowWillResize`每个callback都用相对变化重新选择width/height主导轴；`windowDidResize`对AppKit partial-axis adoption同步调用`setFrame`，该程序化frame又可形成新的resize callback；`applyWindowReservation`还会无条件清除active resize状态并独立`setFrame`。实体关闭证据中21个实际adoption序列均出现fallback、22次出现`partialAxisAdoption`，证明程序化校正是正常拖动路径，但既有Gate只证明比例与零letterbox，没有证明边移动单调或无振荡。
- 实施边界：保留macOS标准四边四角入口；一次live resize冻结start frame、presentation ratio、controls/chrome高度和driver。边拖动固定直接控制轴，角拖动投影到同一比例约束；相同adopted frame的修正必须幂等，active resize中的presentation/geometry reservation不得清除transaction或重新居中。settlement只处理松手后的晚到WindowServer漂移。
- resize中发生方向变化时，capture/liveness/presentation tracker继续工作；不兼容冻结方向的sample暂不enqueue，display layer保留最后一个兼容帧。稳定presentation保存为pending，pointer保持fail closed；松手后按最终用户尺度一次采用latest stable presentation并恢复匹配帧。close、换源、detach/rebind和fullscreen必须清除旧gate/pending generation。
- 自动化关闭边界：四边四角各50至100个连续扩张/收缩callback均无driver切换、边反弹、双帧振荡或非幂等setFrame；missing callback与partial-axis路径保持比例；同方向帧持续enqueue，异方向帧withhold期间tracker仍commit；pending presentation只应用一次且pointer在收敛后恢复。随后运行clean Gate并从exact clean HEAD生成fresh package，实体复验普通放大/缩小平滑、resize中旋转最后一帧、松手恢复、零letterbox及pointer。
- source `09c308d`实现稳定live-resize transaction：start时冻结ratio、controls/chrome和首个有效driver，corner使用固定约束投影，active transaction不再被普通reservation清除且不调度next-run-loop二次校正。bound collector在冻结方向内继续enqueue；异方向sample只跳过display enqueue，仍推进identity validation、liveness和presentation tracker，GUI保存latest stable presentation并在resize end一次采用，门控期间pointer fail closed。
- 新增回归对width edge、height edge和corner分别执行扩张/收缩各100个连续callback，断言比例与主轴单调；collector回归证明3个异方向帧全部withhold但formatRevision仍`1 -> 2`、dropped保持0、结束后首个新方向帧恢复enqueue。完整`PulsePhoneGUIHostTests`通过220项、0失败，包含真实NSWindow、minimum、fullscreen、presentation和pointer既有覆盖。
- clean Gate checkpoint：exact clean HEAD `3b8084d`的完整`make check`通过；794项Swift测试中2项physical opt-in按合同skipped、0失败，doctor/structure、registry及generated Swift/Python、7项registry Python、14项bootstrap contract和29项current/evidence checks全部通过。此前4个失败均由旧Live占用`build/staging/PulsePhone.app`触发打包保护；受控关闭旧GUIHost/Runtime/Helper后，两个packaged用例分别约140秒和126秒通过，没有resize或业务回归。
- fresh packaged root-cause checkpoint：`219d028`确认此前声明为`windowWillResize(_:toFrameSize:)`的方法并非AppKit delegate selector；运行时`responds(to: windowWillResize:toSize:)`为false，因此实体拖动从未进入同步约束，2.5秒拖动产生148次`windowDidResizeFallback`/程序化`setFrame`反馈。改为真实`windowWillResize(_:to:)`并增加selector级回归后，fresh package中fallback与partial-axis reconciliation均为0；owner确认左上角不再跳动或漂移，窗口无黑边/白边。
- 连续平滑性根因与实体结果：同步约束生效后仍有轻微阶梯感。静态扫描确认`ProductionLiveWindowSizing.adoptableContentSize`原先以`ratioMismatch * 1000 + displacement`优先选择比例更整齐的整数候选，使输入主轴每次增加`0.25 pt`时偶尔产生`5～6 pt`输出跳步，例如`324 -> 329`。source `b583ef9`改为先最小化用户直接控制主轴的位移，再以比例误差和总位移决胜；portrait/landscape全范围回归覆盖`320...500 pt`、每`0.25 pt`输入，要求主轴误差不超过`0.5 pt`、单步不超过`1 pt`且单调，并继续把物理比例差限制在`0.5 pt`内。
- exact dev candidate使用app content hash `53351a18992dc6ed0f63dc47d26bec5899ce2bf6c26649085c0a3af91c10fbb3`、release input hash `6f25103b5fa1738aee98af48bf13785c8c185951aad1a35bcb0d881ad9a5a4d3`和当前iPhone / iOS 26.5.2。owner复验右下角、边缘及连续放大/缩小后确认手感“很完美”，同时左上角稳定且全程无黑边/白边；toolbar不是连续抖动根因，固定controls高度继续按既有合同参与派生关系。
- final clean Gate closure：exact clean HEAD `7c0a61a336a63926e74ec5e3840e33434048674e`完成完整`make check`；795项Swift测试中2项physical opt-in按合同skipped、0失败，59项GUIHost assembly、两个完整packaging用例、doctor/structure、registry/generated、Python、bootstrap及29项current/evidence checks全部通过。首轮Gate因owner刚验收的Live GUIHost仍占用staging而被打包保护拒绝，不属于产品或源码失败；核对精确父子进程后受控关闭GUIHost并由public stop清理Runtime，clean rerun通过。结合exact app hash `53351a18...bb3`的owner实体平滑性、零letterbox和位置稳定验收，本次重新打开的关闭标准满足，状态标记`resolved`。resize中旋转继续由`09c308d`自动化覆盖；额外显示器/scale仍由`DV-014`管理，不扩大本机结果。

## OBS-007：pointer / keyboard Stream 打开时重复退休 CoreDevice Helper generation

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-25
- 影响范围：packaged `PulsePhone.app` 正式 live 窗口的 canvas tap/drag、Keyboard Capture、Runtime Stream open、CoreDevice Helper/tunnel generation retention 和输入失败可观察性
- 用户可见结果：点击 live canvas 后输入长时间无响应，容易被理解为窗口或视频卡死；触摸手势可能不生效。Keyboard Capture 在空闲后重新输入时也可能出现首键秒级延迟、短时间输入积压、丢键或 stream unavailable
- 与其他问题的关系：与 `OBS-003` 的 CGEventTap/TCC/键盘捕获前端闭环不同，本条发生在键盘事件已经形成 pressed-set 之后的 Runtime/Helper Stream 打开路径；与 `OBS-004` 的 toolbar OneShot/Indigo service 延迟共享部分底层开销，但本条特指 pointer/keyboard Stream 导致 Helper generation 重建。它不属于 `OBS-006` 的 AVFoundation 帧与窗口几何问题

### 关闭摘要

- 本条已关闭；主文档只保留状态、问题边界和必要关闭摘要，避免当前工作队列无限扩展。需要追溯完整复现、根因、提交、candidate/hash、验证记录和历史checkpoint时，从git历史读取旧版本。
- 后续agent领取当前工作时，应优先读取索引以及`open`/`investigating`正文；不得把归档中的旧“当前唯一下一动作”当作仍然有效。若当前产品重新复现同类失败，再重新打开本OBS或创建更精确OBS。

## OBS-008：GUI pointer 首触秒级停顿并可能静默失效

### 当前状态

- 状态：`resolved`
- 解决日期：2026-07-27
- 发现日期：2026-07-26
- 影响范围：packaged `PulsePhone.app` 正式 live canvas 的 tap、drag、swipe-like pointer interaction，以及输入失败的用户可见状态和性能诊断
- 用户可见结果：拖动开始后约1秒设备画面没有变化，随后目标组件才开始跟随鼠标；继续运行后可能退化为canvas只显示本地点击反馈、实体iPhone完全无响应
- 与其他问题的关系：`OBS-007`记录并修复过短期Stream错误退休Helper generation、input service continuity和坐标route；本条是在同generation/service复用已经实现后，对当前首触admission和静默失败的新观察。它不重新否定`OBS-007`已记录的历史实体通过，也不属于`OBS-006`的视频画布几何问题

### 关闭摘要

- 本条已关闭；主文档只保留状态、问题边界和必要关闭摘要，避免当前工作队列无限扩展。需要追溯完整复现、根因、提交、candidate/hash、验证记录和历史checkpoint时，从git历史读取旧版本。
- 后续agent领取当前工作时，应优先读取索引以及`open`/`investigating`正文；不得把归档中的旧“当前唯一下一动作”当作仍然有效。若当前产品重新复现同类失败，再重新打开本OBS或创建更精确OBS。

## OBS-009：Rotate 将相对旋转错误实现为绝对 landscape 目标

### 当前状态

- 状态：`resolved`
- 解决日期：2026-07-27
- 发现日期：2026-07-26
- 影响范围：GUI toolbar `Rotate Right`、公开CLI `PulsePhone rotate --direction left|right`、Command Catalog/help、argument normalization、Runtime orientation action和Helper DeviceControl调用
- 用户可见结果：从某个横屏再次点击Rotate时，不是单次顺时针90度，而可能在两个横屏方向之间切换或快速经过多个方向；按钮图标与实际行为不一致

### 关闭摘要

- 本条已关闭；主文档只保留状态、问题边界和必要关闭摘要，避免当前工作队列无限扩展。需要追溯完整复现、根因、提交、candidate/hash、验证记录和历史checkpoint时，从git历史读取旧版本。
- 后续agent领取当前工作时，应优先读取索引以及`open`/`investigating`正文；不得把归档中的旧“当前唯一下一动作”当作仍然有效。若当前产品重新复现同类失败，再重新打开本OBS或创建更精确OBS。

## OBS-010：Software Keyboard 返回成功但实体键盘不切换

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-26
- 影响范围：GUI toolbar `Toggle Software Keyboard`、`gui.softwareKeyboard.toggle` OneShot、generation-scoped virtual HID keyboard service及实体iOS软件键盘可见性
- 用户可见结果：在iPhone真实文本输入框已经聚焦时点击Software Keyboard，toolbar action很快返回成功，但设备软件键盘既不显示也不隐藏
- 与其他问题的关系：`OBS-003`记录的Keyboard Capture/EventTap/TCC/pressed-set生命周期已经有历史实体通过，本条不回退其resolved状态。OBS-010单变量A/B已经证明OBS-003时期的软件键盘画面变化混入service/Runtime lifecycle副作用，不能继续作为toggle证据

### 关闭摘要

- 本条已关闭；主文档只保留状态、问题边界和必要关闭摘要，避免当前工作队列无限扩展。需要追溯完整复现、根因、提交、candidate/hash、验证记录和历史checkpoint时，从git历史读取旧版本。
- 后续agent领取当前工作时，应优先读取索引以及`open`/`investigating`正文；不得把归档中的旧“当前唯一下一动作”当作仍然有效。若当前产品重新复现同类失败，再重新打开本OBS或创建更精确OBS。

## OBS-011：GUI 上下系统边缘手势分类反转

### 当前状态

- 状态：`resolved`
- 解决日期：2026-07-28
- 发现日期：2026-07-27
- 影响范围：Live video canvas 的 GUI pointer begin edge classification、Indigo system edge gesture、portrait及经Runtime方向投影后的landscape系统手势
- 用户可见结果：从设备画面底部边缘向上滑不能触发App Switcher；从顶部或右上区域向下滑时反而可能被当作bottom edge gesture并触发App Switcher
- 与其他问题的关系：本条不是toolbar `App Switcher`的double-Home动作，也不是`OBS-008`的首触延迟或失败恢复；它是GUI begin坐标到visual edge label的确定性分类错误，应独立修复和验收

### 关闭摘要

- 本条已关闭；主文档只保留状态、问题边界和必要关闭摘要，避免当前工作队列无限扩展。需要追溯完整复现、根因、提交、candidate/hash、验证记录和历史checkpoint时，从git历史读取旧版本。
- 后续agent领取当前工作时，应优先读取索引以及`open`/`investigating`正文；不得把归档中的旧“当前唯一下一动作”当作仍然有效。若当前产品重新复现同类失败，再重新打开本OBS或创建更精确OBS。

## OBS-012：公开 trace / diagnostics 命令在 production Runtime 中固定失败

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-27
- 影响范围：packaged `PulsePhone trace start|stop`、`diagnostics start|stop`、Runtime stable artifact paths、记录生命周期、stop blocker与status投影
- 用户可见结果：在真实packaged Runtime已运行且设备可选中时，`trace start --json`固定返回`traceWriteFailed`，`diagnostics start --json`固定返回`diagnosticWriteFailed`；用户无法启用两个已公开并由Help/Catalog声明的诊断入口
- 与其他问题的关系：本条不属于Optional High-Assurance release evidence或`DV-009` durable EvidenceStore；PRD已把两项列为Default Product CLI control，当前可用主机和设备具备执行条件

### 关闭摘要

- 本条已关闭；主文档只保留状态、问题边界和必要关闭摘要，避免当前工作队列无限扩展。需要追溯完整复现、根因、提交、candidate/hash、验证记录和历史checkpoint时，从git历史读取旧版本。
- 后续agent领取当前工作时，应优先读取索引以及`open`/`investigating`正文；不得把归档中的旧“当前唯一下一动作”当作仍然有效。若当前产品重新复现同类失败，再重新打开本OBS或创建更精确OBS。

## OBS-013：packaged stop 在 GUIHost 终止后可失败并遗留 Runtime

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-27
- 影响范围：packaged `PulsePhone.app` 的公开 `stop [--udid]`、GUIHost异常终止后的Runtime清理、bootstrap generation fencing与CLI错误投影
- 用户可见结果：正式Live已建立后终止GUIHost，立即执行省略UDID的packaged `stop --json`可返回unresolved `internalFailure`，目标Runtime继续存活；用户收到失败却无法确认或完成清理
- 与其他问题的关系：独立于`OBS-001`正常窗口close、`OBS-007`Stream generation复用和`OBS-012`recording blocker；本次故障发生在GUIHost被终止后的public cleanup lifecycle

### 关闭摘要

- 本条已关闭；主文档只保留状态、问题边界和必要关闭摘要，避免当前工作队列无限扩展。需要追溯完整复现、根因、提交、candidate/hash、验证记录和历史checkpoint时，从git历史读取旧版本。
- 后续agent领取当前工作时，应优先读取索引以及`open`/`investigating`正文；不得把归档中的旧“当前唯一下一动作”当作仍然有效。若当前产品重新复现同类失败，再重新打开本OBS或创建更精确OBS。

## OBS-014：Pointer p3 / p4 外部轮询无法形成可归因的自动化端到端延迟数据

### 当前状态

- 状态：`deferred`
- 发现日期：2026-07-27
- Owner延期日期：2026-07-30
- 调度优先级：Low，当前停止执行。主Agent在恢复条件满足前必须跳过本条，不得继续剩余实体cohort或为本条扩展测量设施
- 影响范围：packaged Live pointer首触诊断、实体设备与Player Demo同机A/B、AVFoundation首个变化sample和display enqueue分层、后续是否需要性能优化的决策依据
- 当前结果：`OBS-008`已经证明warm `p0 -> p2`约4 ms并关闭固定秒级admission和静默失效；但其`p3`由Computer Use动作完成边界、`p4`由随后Live crop首次确认形成，只是包含工具调用和截图轮询的有界观察，不能把约430～450 ms或810～840 ms直接归因给iOS响应、CMIO采集或PulsePhone显示
- 严重度判断：Low。当前没有新的已确认用户可见性能回归，本条只修复测量可归因性；不得以此重新打开`OBS-008`，也不得在数据形成前宣称仍有数百毫秒PulsePhone专属瓶颈
- 与其他问题的关系：`OBS-004`负责Home/App Switcher既有用户可见延迟并拥有自己的10次实体矩阵；本条只测pointer。`OBS-011`负责system edge gesture正确性，必须先关闭。若本条数据确认新的性能缺口，应新建独立优化OBS，而不是在本条内扩大产品行为

### Owner决策与延期收尾

- Owner根据当前真实使用体感确认“鼠标操作 -> 设备变化 -> Live画面变化”的整体响应已经可接受；当前没有已确认的性能回归，也没有继续投入完整延迟归因的产品必要性。因此终止剩余校准、544-case实体cohort、报告生成和基于该报告的优化判断。
- 本条不得标记为`resolved`：现有小样本和失败run没有形成原验收标准要求的完整报告，不能宣称“测量已经证明无需优化”。`deferred`只表示owner主动停止当前投入。
- source提交`3d3de69`已经完成工程表面收缩：删除OBS-014专用collector、runner、Swift/Python测试及其在GUIHost、VideoSession、SampleBufferDisplay、`Package.swift`和`Makefile`中的接线；正常Live采集、显示、pointer业务路径与既有p0/p1/p2诊断日志保持不变。
- source提交`2877093`的production Helper continuous-clock修复及两项小型回归继续保留：exact `mach_timebase_info`换算，以及只在真实`send_frame` await返回后记录`FrameAccepted.acceptedMonotonicNs`。该telemetry语义独立于OBS-014实验设施。
- exact cleanup source `3d3de69`在独立clean worktree完成完整`make check`：786项Swift中2项physical opt-in skipped、0失败；7项registry Python、14项bootstrap contract、29项current/evidence Gate、doctor、structure和generated/current identity全部通过。CoreDevice Python专项32项独立通过。生产源码/测试/构建入口搜索确认不再含`PULSEPHONE_OBS014_CONFIG`、task-local ROI/fingerprint collector或OBS-014 runner。
- 恢复条件：用户重新观察到稳定、可复现且影响使用的pointer延迟回归，或产品明确需要正式延迟指标/SLA。恢复时先依据当时问题建立最小测量方案，不默认恢复本次约3,000行任务专用实现，也不得复用未完成run得出性能结论。

### 原合同判断与执行边界（已停止）

无需先修改PRD/TRD。PRD §18.8和TRD 08 §37.2已经定义`p0 -> p1 -> p2 -> p3 -> p4`并明确当前分层在正式metric/schema演进前只作为bounded diagnostic observation。本条在现有合同内把Mac侧可自动确认的后半段细分为：

```text
p4a = 第一张达到受控ROI变化oracle的identity-valid AV sample进入delegate
p4b = 同一sample完成production display enqueue
```

`p4a/p4b`是本OBS的task-local字段，不新增公开metric、registry、schema、SLA或Release Evidence requirement。Computer Use允许用于前置场景准备和产生真实AppKit输入，但从AppKit记录`p0`开始直到`p4a/p4b`终止观察之间，不得以Computer Use截图、人工观察或外部crop轮询作为计时oracle。精确物理屏幕`p3`不属于第一阶段关闭前提；只有自动化结果仍无法区分设备处理与capture时，才允许另建任务评估设备侧测试App或高帧率外部相机。

本OBS只建立测量、运行样本并形成决策，不得顺手改变HID service、event形状、begin/move/end节奏、capture preset、pixel format、分辨率、AVSampleBufferDisplayLayer或渲染实现。任何优化必须由测量结果支持并进入新的独立OBS。

### 原自动化测量方案（已停止）

1. 复用现有pointer `interactionID`关联AppKit接受`p0`、StreamOpen完成`p1`和matching begin `acceptedForDelivery`的`p2`；新增task-local collector记录同一interaction的`p4a/p4b`、sample PTS、presentation age、frame sequence、source epoch、geometry revision、orientation和typed outcome。
2. 在受控测试case开始前保存固定ROI的baseline fingerprint；只接受identity-valid、同source epoch、同geometry lineage且达到case阈值的第一张变化sample。timeout、无变化、foreign frame、geometry变化和ambiguous fingerprint必须形成独立结果，不能挑选后续成功样本覆盖。
3. tap使用Calculator等可机械建立确定结果的显示区域；drag使用具有固定高对比内容和可检测位移的滚动区域。报告只保存case ID和derived difference/offset，不保存raw pointer坐标、用户文本、截图、视频或逐帧像素。
4. 样本至少分为warm稳定portrait、warm稳定`landscapeLeft`、warm稳定`landscapeRight`、fresh Live首个gesture和Rotate/geometry收敛后的首个gesture；不同cohort独立统计，不合并warmup、rebind或方向过渡样本。
5. 每个稳定方向至少执行30次tap、20次drag、10次快速`tap -> tap`和10次`drag -> tap`；记录p50/p95/max、missing/timeout/rejected数量、Helper PID/generation、HID context和geometry query计数。实体结果必须由受控ROI oracle证明，overlay与协议Ack不能替代。
6. Player Demo在同一设备、App状态、方向、ROI、gesture形状和capture观察器下执行A/B；记录其send start/accepted边界到`p4a/p4b`，不得使用另一设备、另一capture source或另一图像检测算法形成基线。
7. 不预填脱离样本的性能阈值。报告必须并列给出PulsePhone与Player Demo的p50/p95/max、逐cohort差值和run内spread，再判断差异是否稳定、是否超过观测噪声；不能只比较一个最佳样本或总平均值。

### 原数据保存与隐私规则（已停止）

机器可读结果保存在Git ignored的task-local目录：

```text
build/observations/OBS-014/<run-id>/
+-- pointer-samples.v1.jsonl
+-- run-summary.v1.json
+-- player-demo-baseline.v1.json
`-- checksums.sha256
```

逐行sample只保存bounded技术字段、case ID、时间差、typed outcome和脱敏环境摘要；禁止raw UDID、精确坐标、用户内容、原始路径、截图、视频和pixel bytes。原始统一日志、ROI fingerprint和中间结果只能位于mode `0700`的`/tmp/pulsephone-pointer-latency-<run-id>/`，汇总与checksum完成后删除。最终在本OBS记录exact source/candidate、设备型号与OS/build、报告相对路径与SHA-256、关键分位数、A/B结论和唯一下一动作；Timeline只追加checkpoint摘要，不复制逐样本数据。当前默认交付不创建Formal Release flow、hold或长期Release Evidence package。

### 原数据驱动决策规则（已停止）

1. 若`p0 -> p2`相对已验证约4 ms基线出现稳定回退，创建新的pointer admission优化OBS。
2. 若PulsePhone的`p2 -> p4a`在多个cohort中持续高于同机Player Demo且差异超过run内噪声，创建新的HID event/device-delivery或capture归因OBS；先定位差异，不直接选择优化实现。
3. 若`p4a -> p4b`形成稳定大头，创建Mac frame processing/display优化OBS。
4. 若PulsePhone与Player Demo基本一致且`p4a -> p4b`只占小量，则以“没有PulsePhone专属优化依据”关闭本条，不为追求数字修改生产实现。
5. 若现有Mac侧数据仍无法解释`p2 -> p4a`，单独评估精确`p3`方案；设备侧测试App和外部相机不自动进入本OBS范围。

### 原关闭验收标准（未完成）

1. 自动化覆盖interaction关联、时间单调性、ROI baseline/changed/timeout、foreign source/geometry拒绝、快速interaction并发、报告cap、canonical JSONL/JSON和隐私负例；失败样本不能被后续成功样本替换。
2. fresh signed packaged candidate完成全部cohort和最小次数，PulsePhone与Player Demo使用相同设备、状态、ROI和观察器；没有人工截图或crop轮询进入`p0`后的计时路径。
3. `pointer-samples.v1.jsonl`与三个汇总/checksum文件完整生成，sample count、分位数和SHA-256可独立重算；`/tmp`原始数据完成清理，Git worktree不包含真实设备样本或敏感artifact。
4. 报告明确拆分`p0->p1`、`p0->p2`、`p2->p4a`、`p4a->p4b`及presentation age，并记录timeout/rejected/ambiguous数量，不能继续只给430～450 ms和810～840 ms外部观察值。
5. 依据上节规则形成明确结论：关闭为无优化依据，或新建范围更窄的优化/精确`p3` OBS；本条本身不实施未经数据支持的性能调优。
6. 相关collector/GUI/video测试、clean `make check`、packaging静态检查、实体cleanup及报告隐私扫描通过，记录exact commit、candidate、设备/OS、报告hash和剩余风险。

### 历史实施记录

2026-07-30开始实施。`OBS-004`、`OBS-011`及全部更高优先级问题已经关闭；`DV-008`只允许跳过正式三轮baseline、owner threshold approval与freeze，不命中本条默认范围的bounded diagnostic。源码确认p0/p1位于GUIHost、p2位于Runtime Helper接受边界、p4a/p4b位于bound AV sample delegate与production display enqueue，现有单进程telemetry无法完整关联。Player Demo对照入口已确认是长期持有Universal HID service的直接sender；A/B将保留同一PulsePhone Live capture observer、设备、ROI与App状态，只切换PulsePhone Runtime Stream和Player Demo等价sender，避免把两个渲染器或外部截图轮询混入差值。

source提交`bd0efac`实现默认关闭、只由`PULSEPHONE_OBS014_CONFIG`与owner-only canonical临时节点激活的task-local collector。GUI在accepted `pointerBegan`记录p0、成功StreamOpen记录p1和executor generation；Runtime现有统一日志继续提供matching begin p2。identity-valid AV sample先完成既有production display enqueue并冻结p4b，随后才计算16x16 normalized ROI fingerprint；p4a沿用该sample的delegate monotonic timestamp，现有host video metric仍返回原来的production callback时间点，不被task instrumentation替换。pending interaction冻结起始source/epoch/geometry/orientation，baseline unavailable、foreign source、geometry change、missing fingerprint、ambiguous、timeout和session stop均first-terminal-wins。

同一提交新增`Scripts/obs014-pointer-latency`的secure prepare、Runtime p2 capture、Player Demo persistent Universal HID sender、canonical report/verify和bounded cleanup入口。raw control可保存临时坐标但最终四文件只保留case ID、derived timing/difference、typed outcome与脱敏环境；nearest-rank、A/B cohort差值、SHA-256和隐私负例可独立重算。`PIT-225`记录并修复Foundation把已存在`/private/tmp`规范化为`/tmp`而导致probe静默禁用的问题。9项collector/ROI/control Swift测试、5项report Python测试、最终23项collector/display focused、共享216项GUIHost与structure Gate均通过，0失败。

exact clean docs HEAD `28dc8f2`进一步完成完整`make check`：790项Swift中2项physical opt-in skipped、0失败；7项registry Python、5项OBS-014 report Python、14项bootstrap contract和29项current/evidence Gate全部通过，doctor、structure及generated/current identity检查均通过。当前尚未生成fresh package或运行实体样本，状态保持`investigating`。

clean source `a3a0609190102396eec2aad13080e193dda1f866`生成的calibration candidate input=`build/evidence/objects/ec52c15d641de0b960085a6a943f8892c74efa0ba9222d7a22111274d849a45c/release-candidate-input.v1.json`，file SHA-256=`191453616ed30a0cbcff95fd75907f3895fa50b53573c36918103c67f5c064b8`，input hash=`e32057b72bc1f5b2dbb81b1e4849abecde623b7d5a372f742c4e3a8b6b705d1e`，app hash=`508d27dff7014fec90e10add6ca777309fc5e291820c0dbca2edec0553ddaf54`，tree manifest SHA-256=`9d32e2bdc144050232b5921c1a4fa20ada724e48727069dded9bb10075c58667`。13,745项tree、embedded Python 3.13.11、Team ID `GZC4TSS5TG`、deep/strict codesign和zero bytecode均通过。

该candidate的同observer实体calibration证明持久Calculator显示ROI可用：PulsePhone `landscapeRight` tap以`differenceMilli=20 / outcome=changed`完成p0/p1/p4a/p4b。但Player p0/p1为约`341735.86 s`，同一Live的Swift p4a为约`376146.33 s`，相差约9.56小时；同时sender在写arm request后先发送全部HID frame，最后才等待arm response，因此collector可能在设备已变化后冻结baseline并得到`differenceMilli=0 / timeout`。前者源于Python `time.monotonic_ns()`使用`mach_absolute_time`，而production `SystemMonotonicClock`明确使用`mach_continuous_time`；后者是控制顺序错误。该candidate因此只保留静态seal与失败校准事实，不得用于A/B结论。

source提交`98be895`改用`mach_continuous_time`加exact timebase换算记录Player p0/p1，并把arm-response等待移动到第一帧HID发送之前；普通有界deadline继续使用`time.monotonic()`。新增fake Darwin clock和fake persistent HID service回归，明确验证`arm request -> armed -> first send -> p1`，OBS-014 Python专项7项与structure Gate通过，0失败；`PIT-226`承接跨语言clock/arming防回归规则。两个calibration root、raw事件、临时plan和设备截图已删除，Runtime、Helper和GUIHost均清理。

exact clean docs HEAD `814dd98`完成修复后的完整`make check`：790项Swift中2项physical opt-in skipped、0失败；7项registry Python、7项OBS-014 Python、14项bootstrap contract和29项current/evidence Gate全部通过，doctor、structure及generated/current identity检查均通过。

exact clean source=`25cd0cad8df69d66ed197ef74fc21c86db8059cc`生成fresh candidate input=`build/evidence/objects/c6e08e30d5bb826e7cbed2aa94836e7145fa4ed2bb630677e01aadfbd904a0e2/release-candidate-input.v1.json`，file SHA-256=`242151e7676d19253852d8c9d083b036b40309c167a6bebd39b2210bb4a3243b`、input hash=`a9783ce24f0c5841a98c1c310033c989e7e802adada77e1941277d73de2938ad`、app hash=`bf865d23fb7cf1bdfe14b1c5585c39821a1843ebed6e08027a01f284847a5066`、tree manifest SHA-256=`dd4065e720b12422d2a1c72bbead4802612c0f532d159ca7c1f986629c145051`。实际tree与记录的13,745项逐节点manifest独立hash一致；embedded Python 3.13.11 full verification、Team ID `GZC4TSS5TG`、deep/strict codesign、zero bytecode及两个release binary的Matrix v7 execution hash均通过。

该candidate的首轮实体复验确认clock修复生效：Pulse臂`differenceMilli=27 / changed`；Player p0/p1与Swift p4a均位于约`377,994 s`连续时钟域，不再有9.56小时偏移，且sender只在collector返回armed后送第一帧。该Player动作从Pulse留下的显示值`1`再次点击`1`，因此正确得到`differenceMilli=0 / timeout`。第二轮尝试在configured GUIHost中先点Calculator `C`复位，但collector按设计把第一个canvas pointer begin领取为下一个Pulse case，复位动作被记录为`differenceMilli=9 / ambiguous`，真正被测动作随后未采集。两轮均已通过公开stop和exact GUIHost退场完成Runtime/Helper/GUIHost cleanup，raw root、control、计划与截图全部删除；`PIT-227`记录“场景准备必须早于collector启动或使用不进入GUI pointer队列的入口”。

最终双臂calibration在同一`landscapeRight` Live observer和Calculator `0 -> 1`状态转换下通过。Player先按既有`PIT-203`规则把visual点投影为landscapeRight digitizer点`(visualY, 1-visualX)`，得到`differenceMilli=9 / changed`、`p0->p1=13.052 ms`、`p0->p4a=190.204 ms`、`p4a->p4b=0.042 ms`；随后packaged CLI通过不进入GUI pointer队列的同设备`C`动作复位并等待同一Live明确呈现`0`，Pulse GUI同点得到`differenceMilli=9 / changed`、`p0->p1=51.511 ms`、`p0->p4a=241.132 ms`、`p4a->p4b=0.039 ms`。两臂均使用`ambiguity=2 / change=5`，该阈值只区分实测ROI噪声与机械数字变化，不是性能SLA；两组p0/p1/p4均单调且Player与Swift同一clock domain。本轮raw root、control、计划和截图已清理，Runtime、Helper、GUIHost均absent。

历史当时下一动作（已失效）：按稳定portrait、landscapeLeft、landscapeRight以及fresh Live首个gesture、Rotate/geometry收敛后首个gesture生成完整PulsePhone/Player同observer计划；每个稳定方向分别满足30 tap、20 drag、10 tap->tap和10 drag->tap，执行后捕获matching Runtime p2，使用`--require-complete`生成并独立verify四文件、清理`/tmp`，再按数据决定关闭或新建更窄OBS。

首次完整cohort尝试使用candidate `a9783ce2...38ad`生成544-case计划；fresh Live与portrait两臂共182个sample全部`changed`，Player的landscapeLeft post-Rotate、30 tap、20 tap->tap及前三个drag也完成。第4个landscapeLeft Player drag起，Live geometry从revision 4切到5并显示Notification Center；其后17个case按first-terminal合同形成`baselineUnavailable`。截至停止时raw共有254个sample，237 `changed`、17 `baselineUnavailable`，不得通过`--require-complete`，该run不生成最终四文件。后续截图校准纠正了初始system-edge判断：landscape左上角的AssistiveTouch浮钮遮住Calculator History时钟，setup tap误开浮层，后续drag穿过菜单并选中Notification Center。把浮钮移到底部中央、显式确认History已打开后，visual y=0.70～0.48的6个landscapeLeft Player drag全部`changed`、geometry稳定为revision 1、difference为5/9。`PIT-228`承接这条场景确认规则。历史当时下一动作（已失效）：使用已校准plan从新的fresh run完整复跑。

第二次fresh run完成全部544个case和1,632条p0/p1/p4事件：Player Demo与PulsePhone各272个case，portrait 182、landscapeLeft 182、landscapeRight 180，14个cohort均满足fresh/post-Rotate及每个稳定方向30 tap、20 drag、10组tap->tap和10组drag->tap；544个p4结果全部为`changed`，无重复case。`capture-runtime-log`为272个Pulse interaction全部找到matching p2，但`report --require-complete`按合同拒绝生成四文件：全部p2 `acceptedMonotonicNs`比同case p0早`34,410,413,739,375～34,410,462,737,959 ns`，首例为p0=`388407247395333`、p2=`353996833655958`；同一日志中的`clientSubmittedMonotonicNs=388407297396416`仍与p0同域。根因是production `Helpers/coredevice_helper.py`在Frame delivery返回后用Python `time.monotonic_ns()`形成p2，而GUIHost/Runtime `SystemMonotonicClock`使用`mach_continuous_time`。不能用client submitted边界伪装Helper accepted边界，也不能重标、拼接或复用本run作为最终报告；`PIT-226`重新承接该production跨语言clock缺口。

历史当时下一动作（已失效）：保存上述拒绝事实后公开停止并bounded-cleanup本run；把production Helper accepted timestamp改为exact `mach_continuous_time`换算并补注入clock回归，完成focused与clean完整Gate、fresh signed candidate静态封存后，从新run重新执行全部544-case cohort并生成/verify四文件。

source提交`2877093`在production Helper新增可注入的continuous clock，默认直接调用Darwin `mach_continuous_time`、读取exact `mach_timebase_info`并用拆分整数运算转换为UInt64 nanoseconds；Helper仍只在真实`send_frame` await返回后取accepted时间并发送既有`FrameAccepted.acceptedMonotonicNs`，没有改变Wire、HID event、节奏或delivery语义。专项回归注入fake Darwin primitive验证`125/3 * 7 ticks = 291 ns`，并以fake product backend固定断言`device send -> accepted clock -> close`及精确FrameAccepted值。32项CoreDevice Python、7项OBS-014 Python和structure Gate全部通过，0失败；旧raw root已经由probe cleanup删除，GUIHost/Runtime/Helper均退出，public stop返回`alreadyStopped`。

历史当时下一动作（已失效）：从clean `2877093`后续docs HEAD运行完整`make check`；通过后提交Gate记录并从新的exact clean source生成fresh signed candidate，再执行静态seal、p2小校准和不可复用旧数据的全部544-case实体cohort。

exact clean docs HEAD `11d1d6a39a91217b31c3395ea3b737655356bc77`完成完整`make check`：790项Swift中2项physical opt-in按合同skipped、0失败；7项registry Python、7项OBS-014 Python、14项bootstrap contract和29项current/evidence checks全部通过，doctor、structure、generated和current identity均通过。完整输出保存在Git ignored的`build/observations/OBS-014/clean-gate-20260730-continuous-clock/make-check.log`。

历史当时下一动作（已失效）：从包含本Gate记录的exact clean docs HEAD运行`package-app`生成fresh signed candidate；核对source/input/app/tree hash、Team ID、deep/strict codesign、embedded Python与zero bytecode后先执行小规模p2同域校准，再从新run重做全部544-case cohort。

exact clean source=`b2df7243ebf591b5c4f5e1cf6dd904bb4738124f`生成fresh candidate input=`build/evidence/objects/6c565379a7164122a886c928783449f0c1e244da2dac065989a5f8aa1fc9d890/release-candidate-input.v1.json`，file SHA-256=`57c55e88d439cb024f9aec9b05e33b92086b8a6136567a3907c5f31cf1fc94f1`、input hash=`bbcbe039c9d33a14619ffae14cd7f4fc0c6c02464d3587f474c1a0a4e98eae64`、app hash=`c731732d547d19714360db18d6c36f6d5cb3d95dc3facb8755e7b50893c2d6ba`、13,745-entry tree canonical SHA-256=`f39a037b850c734f7dd9275005dfc7711e28ed04c25183fb6172f9d0f211cbff`。source与bundled `coredevice_helper_impl.py`逐byte hash均为`c3dc1c68...b5d5d`且包含continuous accepted clock；embedded Python 3.13.11 full、Team ID `GZC4TSS5TG`、deep/strict codesign、zero bytecode和两个release binary的Matrix v7 identity全部通过。

历史当时下一动作（已失效）：把临时cohort plan更新为本candidate的新run identity，先执行同observer小校准证明production p2与p0/p1/p4同域单调；通过后从独立新run执行全部544-case实体cohort，生成并verify四文件。

fresh candidate的2-case `landscapeRight`同observer校准通过。Pulse使用packaged GUI真实AppKit点击并形成`differenceMilli=20 / changed`：p0=`393248536373041`、p1=`393248545747833`、production Helper p2=`393248551085208`、p4a=`393248654091041`、p4b=`393248654124541`，因此p0->p2=`14.712 ms`、p2->p4a=`103.005 ms`、p4a->p4b=`0.033 ms`，accepted clock已与GUI/Runtime continuous clock同域且严格单调。Player同ROI为`differenceMilli=20 / changed`且p0/p1/p4同域；`report --require-complete`生成2/2 complete calibration结果，随后独立`verify`通过。GUIHost/Runtime/Helper为PID `17617/17641/17654`、Helper generation 2、geometry revision 1。Player case terminal写入后第三方`UserspaceRsdTunnel.wait_closed()`未在额外40秒内退出，按既有`PIT-007`分离operation和teardown并中断该sender；raw无重复且报告完整，不把teardown 130伪报为device action失败。

历史当时下一动作（已失效）：提交本校准checkpoint，正常关闭Live、public stop并删除calibration raw/report；从已有full3计划创建独立fresh run，按14个cohort完整执行544 case，捕获p2并生成/verify最终四文件。

2026-07-30完成owner延期收尾。`3d3de69`删除3,052行OBS-014专用测量实现、测试和入口；Git ignored的`build/observations/OBS-014`、五个临时input root、临时plan/sender脚本及相关bytecode已清理。当前运行的普通staging Live未携带OBS-014配置，因此保留而未中断；不存在OBS-014 runner或配置化collector进程。由于owner终止剩余cohort与报告，本条保持`deferred`而非`resolved`，也不生成新的性能结论或交付报告；恢复前没有可执行下一动作。

## OBS-015：CLI tap/drag/swipe 不会在已打开的 Live GUI 显示触点 Overlay

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-27
- 影响范围：packaged Live GUI、其他CLI Client执行的`touch.tap`、`touch.drag`、`touch.swipe`、Runtime跨连接observation投递、GUI overlay生命周期和Runtime/Client IPC并发
- 用户可见结果：Live窗口已打开时，从另一个packaged CLI进程执行pointer命令，实体设备手势可以执行，但Live画布不会出现合同要求的触点或轨迹；GUI本地鼠标手势的小圆点不能证明外部CLI observation链路存在
- 与其他问题的关系：不重新打开`OBS-008`，后者已经关闭GUI本地pointer admission、静默失效和warm `p0 -> p2`延迟；本条只负责已接受pointer从Runtime投影到其他Live Client。`OBS-014`只测端到端延迟归因，不能替代本条用户可见功能修复，也不得先于本条执行

### 关闭摘要

- 本条已关闭；主文档只保留状态、问题边界和必要关闭摘要，避免当前工作队列无限扩展。需要追溯完整复现、根因、提交、candidate/hash、验证记录和历史checkpoint时，从git历史读取旧版本。
- 后续agent领取当前工作时，应优先读取索引以及`open`/`investigating`正文；不得把归档中的旧“当前唯一下一动作”当作仍然有效。若当前产品重新复现同类失败，再重新打开本OBS或创建更精确OBS。

## OBS-016：实体USB重连后Runtime不推进连接代，GUI与CLI控制永久不可用

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-27
- 影响范围：Production Runtime USB inventory、connection epoch、Helper generation、Live ownership、availability/geometry/capability、GUI pointer、CLI坐标输入和重连后的capture activation
- 用户可见结果：拔线后视频能够通过AVFoundation新source epoch自动恢复，但Live窗口显示`Pointer unavailable`，GUI点击/拖动不生效且没有触点；同一时刻packaged CLI `touch.swipe`返回`capabilityUnavailable`
- 与其他问题的关系：`OBS-007`已经闭合持续连接条件下的Helper generation复用和normal cleanup，本条是其转入`DV-010`后首次执行实体USB验证得到的独立失败；不回退OBS-007的历史结论。`OBS-015`只负责跨Client overlay，但两项必须共用单reader/serialized writer/event broker，不能各建旁路

### 关闭摘要

- 本条已关闭；主文档只保留状态、问题边界和必要关闭摘要，避免当前工作队列无限扩展。需要追溯完整复现、根因、提交、candidate/hash、验证记录和历史checkpoint时，从git历史读取旧版本。
- 后续agent领取当前工作时，应优先读取索引以及`open`/`investigating`正文；不得把归档中的旧“当前唯一下一动作”当作仍然有效。若当前产品重新复现同类失败，再重新打开本OBS或创建更精确OBS。

## OBS-017：Install App选择IPA后未启动真实安装

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-28
- 解决日期：2026-07-30
- 影响范围：packaged `PulsePhone.app` Live toolbar的Install App按钮、IPA文件选择、GUI参数校验、Runtime `app.install`提交、direct installation proxy production route和用户可见状态反馈。

### 关闭摘要

- 合同与实现：PRD §9.10和TRD 06 §25.4冻结picker/status、no-follow IPA、bounded archive/AFC、InstallationProxy terminal、commit state与30分钟deadline；`ad6e833`接通production Runtime/DirectHelper route并共享单一Helper manifest owner，`0ce0f6d`接通production picker/drop/status，`1db5003`修复DirectHelper spawn后start identity握手并保留Supervisor独立验证。
- 自动化：exact clean `4136b1c`的`make check`通过775项Swift测试，2项physical opt-in skipped、0失败；registry/generated、7项Python registry、14项bootstrap和29项current/evidence Gate全部通过。DirectHelper Python 14项与Runtime assembly 54项独立通过，其中2项physical opt-in skipped。
- fresh candidate：source `dfe7c8d`，input=`build/evidence/objects/d9a3ad3c07bd825d8a71c8ce152c482412ebff40bdcc1a6d821540ab84aa5a5d/release-candidate-input.v1.json`，file SHA-256=`41cba4e1ac23ae05048d2ed827c8b23526976a262bc7b3d368911e7db8377732`，input hash=`9a66944c10fe8081696d3bc9d2fdd3cc4e70eb7db10639b035bf046ebec4ad12`，app hash=`b0ef3588bd4617cc8d8148f9173ecc3124d733cfb7ea112008fba883b1bade27`。Team ID `GZC4TSS5TG`、deep/strict codesign、完整tree、embedded Python、zero bytecode及两个release binary的Matrix v7 hash均通过。
- 实体CLI：iPhone / iOS 26.5.2 (`23F84`)使用结构合法、含真实unsigned arm64 iPhoneOS Mach-O的受控IPA（SHA-256=`9c1e88f405871d8e4899df6502e32d03d5dbeafcbf82bc0fcebd275fb8ffcda0`，bundle ID=`com.pulsephone.obs017.unsigned`）。packaged CLI在3.47秒返回`installFailed/committed(stage=installationProxyResponse)`，exit 6；manifest观测到`direct-1 / production-direct`，统一日志actionID=`9065c8e0-a10b-437a-bab8-e01b6ec2ad4a`关联`direct.installationProxy.install`且`pathRedacted=true`，证明真实AFC/InstallationProxy已提交并明确拒绝unsigned code。
- 实体GUI：同一candidate Live经Install App picker选择同一受控IPA，界面明确显示`installFailed`；GUI与Runtime actionID=`69ca1018-d15b-452e-8a59-99a61e4d455f`一致，route=`direct.installationProxy.install`、`pathRedacted=true`，Runtime terminal为`errorCode=installFailed`，GUI在约1.69秒完成terminal与presentation。正常关闭窗口、公开`stop`后`runtime status=notRunning`，Runtime、CoreDevice/Direct Helper、target socket/manifest和GUIHost均absent，近30分钟无新PulsePhone `.ips`。
- 剩余边界：当前没有受控、可安全安装的签名测试IPA，因此成功返回真实bundle ID的实体oracle仍是`DV-013`精确暂缓项，不计为通过，也不阻塞已用同一production route完成的CLI/GUI等价可验证失败矩阵。

## OBS-018：Screenshot部分场景可用但无session入口与fallback未闭环

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-29
- 解决日期：2026-07-30
- 影响范围：packaged `PulsePhone.app` Live toolbar的Screenshot按钮、GUI Save Panel、preview-first本地PNG保存、Runtime device screenshot fallback、root/child action logging和用户可见状态反馈。

### 关闭摘要

- 合同与实现：PRD §9.9及TRD 06 §25.6/§27.5原有root、preview-first、device child与`ensureRunning`合同完整。`1feba3b`移除Save Panel前的Runtime session硬前置，给panel/backend/writer建立production注入边界，保留existing-session best-effort root logging，并把cancel、invalid path、Runtime、格式和本地写错误投影为Catalog标准错误码；路径日志始终脱敏，preview local write失败不重复调用device fallback。
- 自动化：6项`GUIScreenshotTests`、包含真实`NSWindow`的assembly回归和完整207项GUIHost测试通过；exact clean `make check`通过777项Swift测试，其中2项physical opt-in skipped、0失败，doctor/structure、registry/generated、7项Python registry、14项bootstrap与29项current/evidence Gate全部通过。既有`PIT-153`补充承接本次production闭环。
- fresh candidate：复用exact clean source `b32616b752cb18790380a82a752533a0a3cf0dd7`，candidate input=`build/evidence/objects/989d71e847b92433624cb07d24e5aa12d86c0c07c03aa5b97c5f43f527ba67f8/release-candidate-input.v1.json`，file SHA-256=`40fca076b22fedc9abccc639191f6cb1993b1ad53f30e2300ba35a5780d4eff4`，input hash=`95d97b341d8d01ad5926142f967a049530d9257441ae1db6994f9dde2d5dc128`，app hash=`5f7826026a99d75ebec78c0198ede259ec6976617837b0fb0852b6fc175b95bb`。13,745-entry manifest、embedded Python、Team ID `GZC4TSS5TG`、deep/strict codesign、zero bytecode和Matrix v7 identity均通过。
- packaged GUI：Save Panel取消root=`a6192093-cd56-4aa8-9b65-685e1a6983df`，状态为`Screenshot cancelled`且没有terminal child；fresh matching preview root=`9b0463e6-c490-40ef-b721-1e5c2bbb49c8`以`source=preview / childCreated=false / pathRedacted=true`保存2532x1170 PNG，865,609 bytes、mode `0600`、SHA-256=`19dcaafabe00e89e7ca184f1111bde0314f6a55574bb9e121f512ef18c94bc35`。
- packaged fallback：当前Camera已授权且产品没有人为暂停Live的入口，因此在exact GUIHost的`beginScreenshot`入口做可逆no-bound-frame故障注入：全线程冻结时暂存并清空当前`ProductionBoundVideoSession.latestFrame`、置位`stopped`，保存完成后逐字节恢复原帧和标志并detach；没有修改candidate、TCC或USB状态。root=`e2b4c890-5cda-4d07-b58e-92e98eb76e7e`以`source=device / childCreated=true / pathRedacted=true`成功保存2532x1170、16-bit RGBA PNG，1,497,212 bytes、mode `0600`、SHA-256=`1f5ef75a237dc43a2ba8ba40ea91cc2fb07015f38d090e0b90a981eabecaf764`。complete replay trace ID=`db27fd74-e04d-40d4-992b-590d0ce77d5b`、SHA-256=`0a7466c5503bb7faa216561a219fdfc9a439b9b1507416333318cbde496828c6`记录独立device child=`95b39400-b6ad-4d4c-98ef-d63d64bec0dc`的redacted invocation/result和`succeeded`终态，证明root/child身份与终态边界。
- cleanup与剩余边界：正常关闭Live后公开`stop`返回`stoppedTargetCount=1 / stopped`，`runtime status=notRunning`；Runtime、Helper、target socket/manifest均absent。无窗口GUIHost对精确TERM未在有界等待内退出，revalidate exact PID/路径后单独SIGKILL清理；没有新PulsePhone crash report。post-run app hash、13,745 entries、deep/strict codesign、Team ID与zero bytecode不变，四个临时PNG均已删除。Camera/Microphone/Input Monitoring完整TCC reset矩阵仍只属于`DV-006`，本条不扩大该声明。

## OBS-019：iOS 16 CLI swipe延迟返回泛化capabilityUnavailable

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-29
- 解决日期：2026-07-30
- 影响范围：packaged CLI `swipe`、同类`touch.tap`/`touch.drag`坐标命令、Runtime `command.submit` admission顺序、display geometry同步、helper超时和标准错误投影。

### 关闭摘要

- 合同与实现：PRD §11.4/§16、TRD 02 §9及TRD 06 §25.1/§25.3/§26.1已经要求target compatibility先于device-dependent enrichment。`218cfe6`让production Runtime先用authoritative snapshot规划；已知不兼容或invalid argument在任何geometry/Helper查询前terminal，只有compatible coordinate命令的`.planned`或精确`displayGeometryUnavailable`分支刷新geometry并重新规划。刷新失败仍保持自身typed fail-closed语义，没有把兼容设备错误改写为版本错误；`PIT-223`承接该防回归规则。
- 负向与自动化：`ProductionRuntimeAssemblyTests.testCoordinateCompatibilityFailurePrecedesGeometryHelperQuery`以production server覆盖iOS 16的`touch.tap`、`touch.drag`、`touch.swipe`，三者均快速返回`unsupportedOSVersion`、保留当前OS与iOS 17+ typed details，geometry query count为0且不进入normalTouch/input service；CLI contract继续验证human/JSON和exit 3。iOS 17+对照精确证明compatible分支刷新一次geometry，刷新失败仍投影`capabilityUnavailable`。56项Runtime assembly与16项CLI focused回归共72项通过，其中2项physical opt-in skipped、0失败。
- clean与candidate：exact `71e49ec`的`make check`通过779项Swift测试、2项physical opt-in skipped、0失败及全部附加Gate；包含后续generation修复的final clean source `b32616b752cb18790380a82a752533a0a3cf0dd7`进一步通过781项Swift测试和完整Gate。candidate input=`build/evidence/objects/989d71e847b92433624cb07d24e5aa12d86c0c07c03aa5b97c5f43f527ba67f8/release-candidate-input.v1.json`，input hash=`95d97b341d8d01ad5926142f967a049530d9257441ae1db6994f9dde2d5dc128`，app hash=`5f7826026a99d75ebec78c0198ede259ec6976617837b0fb0852b6fc175b95bb`；签名、13,745-entry manifest、embedded Python、zero bytecode和Matrix v7 identity通过。
- compatible实体：iPhone 14 / iOS 26.5.2 (`23F84`)上，同一fresh candidate先在OBS-020链路中连续完成tap、drag、swipe并均返回`acknowledged`。关闭前再次从持续存活TTY执行exact packaged三连：cold tap `3.17 s`、warm 200 ms drag `1.31 s`、warm 200 ms swipe `1.29 s`，均为`acknowledged`；这三条production成功路径进入compatible geometry/normalTouch执行，不是静态Help或Client本地伪成功。
- cleanup与声明边界：公开`stop`在`2.58 s`返回`stoppedTargetCount=1 / stopped`，随后`runtime status=notRunning`，Runtime、Helper、target socket/manifest和新PulsePhone crash report均absent，deep/strict codesign仍通过。当前没有再次提供iOS 16.3.1实体，因此没有把等价production Runtime负向矩阵扩大为iOS 16实体通过；该未提供exact-build的physical范围继续由`DV-004`承接，不阻塞本条已明确允许的等价production关闭。

## OBS-020：successful one-shot后死亡generation遗留socket/manifest并永久阻断后续命令

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-30
- 关闭前调度优先级：High。一次已成功的packaged one-shot可留下无法自动恢复、也无法由公开`stop`清理的generation，随后所有需要Runtime的公开命令均被阻断；它直接阻塞`OBS-018` device fallback和`OBS-019` compatible coordinate packaged Gate，优先于其余Medium/Low队列。
- 影响范围：packaged Runtime启动/退出、Runtime socket与Helper manifest ownership、Helper lifetime、bootstrap generation classifier、公开`runtime status`/`stop`、下一条命令的on-demand Runtime启动和实体cleanup。
- 用户可见结果：packaged device Screenshot成功后，紧接的packaged `tap`在约0.55秒内失败为`internalFailure: generationBusy(...identityUnknown)`且`runtimeMayContinue=true`；`runtime status --udid`报告`notRunning`，公开`stop --udid --json`又以`runtimeFailed: generationBusy(...identityUnknown)`、exit 4失败，用户没有产品入口恢复后续命令。
- 与其他问题的关系：不同于`OBS-019`的planner/geometry admission顺序；当前失败发生在compatible iOS 26.5.2正常路径启动前。也不同于已关闭`OBS-013`的“GUIHost终止后活Runtime无法stop”：本条中的Runtime与Helper均已死亡，但可信socket和manifest仍存在，public stop无法确认并退休全员死亡的stale generation。

### 当前证据与合同判断

1. exact candidate source=`84e2db99d13ac7e4baa34dad159178cd50fe97c6`，candidate input=`build/evidence/objects/03e57153dcea7f5b79c8359458e3a1eb9fe5e920a0ced2d9a8c85d680c7f5ab9/release-candidate-input.v1.json`，app content hash=`8e90871b4f05705166ca51b82edd0a54609a5caa2570f08e4671af9feb2b771a`。
2. iPhone 14 / iOS 26.5.2 (`23F84`)的packaged CLI Screenshot以`source=device`在约5.07秒成功，得到`1170x2532`、4,823,638 bytes、mode `0600`、nlink `1`的PNG；因此前一条command已经完成可见业务终态。
3. Screenshot后Runtime PID `75060`和CoreDevice Helper PID `75066`均已不存在；近邻时间没有新PulsePhone `.ips`。精确target的socket与Helper manifest仍为owner-only节点，manifest仍绑定上述已死亡PID和runtime epoch，Runtime lock已经释放。
4. 下一条packaged `tap`失败为`generationBusy(RuntimeGenerationClassification.identityUnknown)`；随后结构化`runtime status --udid 00008110-001A7D523E90401E --json`返回`notRunning`。这证明status、bootstrap和节点状态对同一generation形成互相矛盾且不可恢复的公开投影。
5. 公开`stop --udid 00008110-001A7D523E90401E --json`精确返回exit 4、`runtimeFailed`和`generationBusy(PulsePhoneCLI.RuntimeStopGenerationState.identityUnknown)`；执行前后均未手工unlink节点，也未向未经验证的PID发信号。
6. PRD公开合同要求`runtime.stop`确认socket EOF与runtime lock释放后成功，并允许退场verified orphan且不spawn；TRD 06区分`orphanHelpers`可恢复与`identityUnknown`不可恢复。当前实现把任何`trusted socket + free runtime lock`直接分类为`identityUnknown`，stop backend又只在socket absent时读取manifest验证process identity，因此即使owned manifest中的Runtime/Helper均可验证为gone，也没有安全退休stale socket/manifest的路径。
7. Runtime正常`run` defer会依次shutdown operation backend、删除owned manifest、调用`RuntimeListener.shutdownExpected()`和按socket device/inode再次删除bound socket。当前两个节点均残留，说明进程没有经过正常Swift unwind；仍需确认是哪个signal、fatal pipe write或其他非正常终止触发，不能只修public stop来掩盖Runtime退出根因。

### 关闭验收标准

1. successful packaged one-shot返回terminal后，Runtime generation要么继续健康服务，要么按合同完整退出；不允许Runtime/Helper死亡而owned socket/manifest残留。
2. 同一candidate连续执行Screenshot后立即执行tap/drag/swipe中的正常坐标命令，下一条命令可复用健康generation或安全启动新generation，不返回`generationBusy(identityUnknown)`。
3. 对`trusted owned socket + free runtime lock + owned manifest + exact recorded Runtime/Helper全员gone`建立production回归和安全恢复；必须验证node owner/type/mode、canonical target、manifest结构及process start identity，任何identity mismatch或活进程未知都继续fail closed且不signal。
4. public `stop`可将已验证全员死亡的stale generation收敛为`Already stopped`或等价标准成功结果，并删除且只删除owned socket/manifest；不能手工unlink作为验收步骤。
5. Runtime异常终止根因具有源码修复或明确合同化的fatal cleanup边界，并覆盖最小可重复回归；Helper、socket、manifest、runtime lock和epoch scratch的清理保持generation-safe。
6. focused tests、clean `make check`、fresh packaged Screenshot -> coordinate command -> public stop实体链路、静态签名/tree检查、进程/节点/crash cleanup全部通过后才可关闭。

### 解决记录

2026-07-30开始调查。真实packaged candidate在device Screenshot成功后暴露死亡generation残留；下一条tap和公开stop分别以bootstrap `identityUnknown`与stop `identityUnknown`失败。已确认Runtime/Helper PID均gone、Runtime lock free、socket/manifest仍为owner-only节点，且未发现新`.ips`。该真实失败不命中Deferred Validation，不能作为`OBS-019`兼容性修复的实体通过证据，也不能靠手工unlink掩盖。当前唯一下一动作：定位Runtime为何未经过正常defer退出，并在不向identity mismatch/未知活进程发信号的前提下，为owned stale socket + manifest + all-gone generation补production stop/bootstrap安全退休回归和实现。

source提交`901bc0d`完成all-gone owned generation恢复：新增的RuntimeKernel原语只在持有exact `bootstrap.lock`并成功持有稳定`runtime.lock`、严格manifest未变化、manifest记录的Runtime和全部Helper均为gone、socket owner/type/mode/device/inode匹配时退休socket和manifest；任何活进程、identity mismatch、不安全节点或变化中的manifest均零signal、零unlink并保留`identityUnknown`。Runtime on-demand bootstrap在精确恢复成功后才spawn replacement，public stop把同一结果投影为`Already stopped`且不spawn；同时修正bundled stop的Runtime identity路径为实际`Contents/Helpers/PulsePhoneRuntime`。真实子Runtime `SIGKILL`回归证明stale socket/manifest确实残留，identity-mismatch pass保留两节点，POSIX all-gone pass安全清除；10项bootstrap、57项Runtime assembly（2项physical opt-in skipped）和12项stop/status合同均0失败，doctor与structure通过。当前唯一下一动作：从clean source checkpoint运行完整`make check`，提交Gate后生成fresh signed candidate；先用public stop恢复旧candidate遗留节点，再执行packaged Screenshot -> tap/drag/swipe -> stop及全节点cleanup实体链路。

clean Gate通过：exact `93c84cc`完整`make check`执行781项Swift测试，2项physical opt-in按合同skipped、0失败；doctor/structure、registry/generated、7项Python registry、14项bootstrap以及29项current/evidence Gate全部通过。当前唯一下一动作：提交本checkpoint，从新的clean docs HEAD生成fresh signed candidate并完成静态seal；随后先用fresh packaged public stop恢复当前旧candidate遗留的exact target节点，再在持续存活的TTY会话中执行packaged Screenshot -> tap/drag/swipe -> public stop并核对Runtime/Helper/socket/manifest/crash cleanup。

2026-07-30 final packaged closure：exact clean source=`b32616b752cb18790380a82a752533a0a3cf0dd7`，candidate input=`build/evidence/objects/989d71e847b92433624cb07d24e5aa12d86c0c07c03aa5b97c5f43f527ba67f8/release-candidate-input.v1.json`，file SHA-256=`40fca076b22fedc9abccc639191f6cb1993b1ad53f30e2300ba35a5780d4eff4`，input hash=`95d97b341d8d01ad5926142f967a049530d9257441ae1db6994f9dde2d5dc128`，app hash=`5f7826026a99d75ebec78c0198ede259ec6976617837b0fb0852b6fc175b95bb`。13,745-entry manifest与fresh/post-run tree的canonical hash均为`88364141a81b02d0c458eaf815c03c4a88ef2da0b6a625b28037f20928f249db`；embedded Python full、Team ID `GZC4TSS5TG`、deep/strict codesign、zero bytecode及Client/Runtime Matrix v7 identity均通过。旧candidate的exact socket/manifest在clean Gate内packaged performance collector通过on-demand bootstrap后已经absent，因此没有把它伪报为fresh public stop证据。

同一fresh candidate在持续存活TTY中于iPhone 14 / iOS 26.5.2 (`23F84`)执行正常链路：device Screenshot成功为4,824,096 bytes / SHA-256 `b0bfd1676b947de6585a31daa0df323d45f2981ddd58264288ec92996bbf9109` / mode `0600` / nlink `1`，紧接tap、drag、swipe均返回`acknowledged`，Runtime仍为`full`；public stop返回`stoppedTargetCount=1 / stopped`，随后status=`notRunning`且exact Runtime/Helper/socket/manifest absent。为补足公开恢复实体oracle，再次成功Screenshot后精确验证fresh Runtime PID `73492`与Helper PID `73497`及manifest start identity，只向二者发送`SIGKILL`；两个PID gone而0600 socket/manifest保留。未手工unlink节点，fresh packaged public stop返回`alreadyStopped / stoppedTargetCount=0`并删除两节点；随后新的tap再次`acknowledged`并由正常public stop清理。近邻没有新PulsePhone crash report，post-run seal不变，临时PNG均已删除。自动化identity-mismatch零signal/零unlink与本实体all-gone/public-stop结果共同满足关闭标准，状态标记`resolved`。

## OBS-021：`type --text` 首次调用可能未输入文本或触发粘贴权限弹框

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-31
- 解决日期：2026-08-02
- 严重度：High
- 影响范围：packaged CLI `type --text`、CoreDevice device-general pasteboard、generation-scoped virtual keyboard service、Command+V readiness 和结果语义。
- 用户可见结果：当前candidate的cold first-call和同generation复用均可直接派发文本，不再因keyboard service尚未ready而显示粘贴权限弹框。
- 与其他问题的关系：`OBS-003`只承接 Live Keyboard Capture；`OBS-022`只承接软件键盘无状态 toggle。

### 关闭摘要

- 根因包含三个独立异步边界：device pasteboard必须使用独立SET/PULL会话精确回读；`Command+V`必须使用
  20 ms modifier settle与80 ms V hold；fresh keyboard service创建Ack后还需1秒ready窗口。文本内容、
  UTF-8、换行和shell quoting均不是权限分支条件。
- 合同提交`ce372aa`、实现提交`1a46e0b`将service状态固定为`absent -> settling -> ready`：仅新建后等待
  1秒，等待中断保留同一service并在下次继续，ready复用零等待；adapter和stream不得绕过统一ensure入口。
  既有独立SET/PULL、type专用20 ms/80 ms chord、通用Text HID 12 ms/12 ms和Software Keyboard路径不变。
- exact clean source`1a46e0b`的45项CoreDevice Python和完整`make check`通过；Swift 806项通过、2项physical
  opt-in按合同skipped、0失败，registry/generated/current-contract及embedded Python full verification通过。
- fresh candidate input为`build/evidence/objects/9adda96830a2615869b0e8a194074384dd6d10f6157c1d68d4735f1ce12a091d/release-candidate-input.v1.json`，
  input hash=`1fb4bfade3758bcfc208b487b56adca6f1fe605112ce21ae1bb9d9a58c19fd02`；deep/strict codesign通过。
  iPhone 14 / iOS 26.5.2 strict-cold production首次调用和Live generation fresh/reused均完整插入且日志为
  `AuthMessageAuthentic`、无权限弹框；fresh/reused耗时约`1.75 / 0.56 s`且只创建一次service。Keyboard
  Capture追加`q`、Software Keyboard双向toggle和焦点保持均通过。首次service原生收起软件键盘继续接受。
- 关闭Live后public stop返回`stoppedTargetCount=1 / stopped`，随后Runtime状态`notRunning`；退出App后
  exact GUIHost/Runtime/Helper均gone，target socket/manifest absent，持久lock无人持有。成功仍只报告
  `pasteDispatched`，不声称目标App已显示文本；不访问Mac pasteboard、不自动重试或处理权限弹框。

## OBS-022：Live缺少可用的无状态软件键盘切换入口

### 当前状态

- 状态：`resolved`
- 发现日期：2026-07-31
- 解决日期：2026-08-01
- 严重度：Medium
- 影响范围：iOS 17+ Live toolbar、Command Catalog、Runtime OneShot、CoreDevice Indigo Consumer report、Helper route/schema 与 Help。
- 用户可见结果：当前 Live 已提供独立的 Software Keyboard 瞬时按钮，可在输入焦点不变时反复切换 iOS 软件键盘显示/隐藏。
- 与其他问题的关系：旧 `OBS-010`保持 resolved；本条使用新的 Indigo Consumer Eject 机制，不恢复旧 Option+Command+K 路径，也不改变 Keyboard Capture enabled/active。

### 关闭摘要

- 合同提交 `7de6aee`、实现提交 `7f6d25f`新增 `gui.softwareKeyboard.toggle`：iOS 17+、toolbar order 100、无 checked state 的 momentary action。Helper route `coredevice.softwareKeyboardToggle`通过 generation-scoped Indigo service发送 Consumer page `0x0C`、usage `0xB8` 的 down/up 与 barrier，并返回 `stateUnknown: true`。
- 动作不查询、缓存或推测软件键盘当前状态，不创建/删除 Universal keyboard service，不启用、关闭或读取 Keyboard Capture。只有与正在执行的 `type --text`或 Keyboard Capture 短期 keyboard interaction 真正重叠时才返回 `resourceBusy`；Capture 仅 enabled/active 但空闲时不阻止 toggle 或 `type`。
- exact packaged candidate 在 iPhone 14 / iOS 26.5.2 上验证：Capture 关闭时显示到隐藏、隐藏到显示均成功，输入焦点与文本不变；Capture 开启时按钮仍可独立隐藏软件键盘，随后真实 Mac 键盘输入继续生效。iOS 16 toolbar absence 已由 Catalog/Planner/GUI 自动化覆盖，实体 exact-build 扩展保留于 `DV-004`。
- 35 项 CoreDevice Python和149项 focused Swift覆盖 Eject 编码、barrier、错误/资源竞争、Catalog/Planner、iOS 16 负向、toolbar 顺序和 GUI/Runtime 投影；最终完整 800 项 Swift及附加 contract/evidence 阶段 0 失败。candidate、ad-hoc signing 和 cleanup 证据与 `OBS-003`共享。

## OBS-023：iOS 14～16 prepare、screenshot与launch未装配legacy production路径

### 当前状态

- 状态：`resolved`
- 发现日期：2026-08-01
- 解决日期：2026-08-02
- 影响范围：packaged CLI 在 iOS 14～16 上的 `device prepare`、device `screenshot` 和 `launch`
- 用户可见结果：packaged CLI 已按目标系统进入 legacy preparation、screenshotr 和 DVT launch 路径；具备 exact approved Developer Support 时完成真实操作，不具备时返回精确 typed error且不伪造成功或artifact。
- 与其他问题的关系：不包含跨版本`uninstall` production assembly缺口，也不扩展 iOS 14～16 的 HID、pointer、keyboard、button、rotate 或 text兼容范围。

### 关闭摘要

- `afce8d8` / `0e03f09`完成target-derived classic preparation；iOS 14/15/16只经DirectHelper执行exact catalog与verified cache的query/mount/probe，iOS 17边界保持CoreDevice warm generation。
- `e59eaac` / `9ff9c8e`完成legacy screenshotr及artifact reservation、原子提交、PNG validation和typed error；`156b16b` / `fcb7196`完成Installation Proxy exact lookup后的DVT ProcessControl launch，不调用CoreDevice AppService。
- `d99279b`完成selected release Xcode source；`039df14` / `dce9181`批准iOS 16.3.1 (`20D67`) exact classic entry。clean `make check`通过802项Swift、2项physical opt-in skipped、0失败及全部附加Gate。
- 同一candidate在iOS 16.3.1完成prepare ready/alreadyReady、1170x2532真实screenshot、existing-output原子替换和DVT launch；iOS 26.5.2 modern prepare/screenshot/launch对照通过。
- iOS 14.4.2 exact DDI、iOS 17.x boundary及broad lower/intermediate/upper矩阵继续由`DV-004`管理，不把单点实体结果外推到整个版本范围。

## OBS-024：`uninstall` 未装配跨版本 production 路径

### 当前状态

- 状态：`resolved`
- 发现日期：2026-08-02
- 解决日期：2026-08-02
- 严重度：Medium
- 影响范围：packaged CLI 在 iOS 14+ 上的 `uninstall --bundle-id`
- 用户可见结果：已安装App可被卸载；目标App不存在时返回`appNotInstalled`，不会再因
  production assembly缺口固定返回`capabilityUnavailable`。
- 与其他问题的关系：独立于`OBS-017`的安装入口，也不依赖legacy Developer Support、DVT、
  CoreDevice或iOS版本分支。

### 关闭摘要

- `fe77158`补齐既有合同投影：`app.uninstall`允许`appNotInstalled`，Helper Wire允许
  `uninstallFailed`；`7bacda5`刷新受identity变化影响的README与需求fixture。PRD/TRD原有
  Installation Proxy、5分钟deadline、`Complete`成功边界、无自动重试和无rollback声明不变。
- `a1d6473`完成production vertical slice：Runtime为iOS 14～16与iOS 17+统一选择
  `direct.installationProxy.uninstall`并生成`operation=uninstall` payload；DirectHelper先按
  exact bundle ID查询，再提交Uninstall，所有分支best-effort关闭Installation Proxy与Lockdown。
- 未安装在提交前返回`appNotInstalled/notCommitted`；明确拒绝返回
  `uninstallFailed/committed`；提交后timeout或request/response不确定返回
  `outcomeUnknown/unknown`。`install`、`uninstall`与`launch`继续复用
  `device.app-management` exclusive claim串行。
- 55项DirectHelper Python、69项Runtime assembly、6项App Installation与3项Claim Resolver
  focused测试通过。exact clean source`7bacda5`的完整`make check`通过816项Swift测试，2项
  physical opt-in按合同skipped、0失败，并通过registry、generated、current-contract与evidence Gate。
- fresh packaged candidate input为
  `build/evidence/objects/ec9be7a6a71d388e116a50a68153642b1ad19d175b4c025bf046b9dfa4a5a707/release-candidate-input.v1.json`，
  file SHA-256=`2f431da4641c51a4e7f54997d72161b5a6da0da9e16abe8f4d5583f95fd02c55`，
  input hash=`5ba385b0eb8788fedb2e94daa0929167166fec32cc9510ece70813dc8c9163aa`，
  app hash=`f6179e1352ff92e2d1bf8dc7d25e8a536ec867a3494c4b2357fe7ea967e94e28`；
  ad-hoc candidate通过deep/strict codesign。
- 同一candidate与签名IPA SHA-256=`5c6ceb1458a06ff451892624de35b2062fde589e8254e90905f1715037bbd445`
  在iOS 14.4.2 (`18D70`)和iOS 26.5.2 (`23F84`)完成相同闭环：初始列表包含
  `com.lavion.soyoungyanglezu` 10.1.6，首次卸载返回`uninstalled`，列表确认消失；第二次卸载
  以exit 6返回`appNotInstalled/notCommitted(stage=installationProxyLookup)`；随后恢复安装返回
  `installed`，最终列表再次包含同一bundle与版本。验收后两台目标均无本candidate Runtime/Helper残留。
- iOS 15/16、iOS 17.x及更广exact-build扩展继续由`DV-004`管理，不把上述两个单点结果外推到
  整个版本范围。

## OBS-025：PATH软链启动无法定位App内CLI资源

### 当前状态

- 状态：`resolved`
- 发现日期：2026-08-03
- 严重度：Medium
- 影响范围：公开CLI的PATH软链入口、静态Help/Command Catalog、产品版本、Local Facts Helper和Runtime compatibility catalog加载。
- 用户可见结果：有效软链指向packaged `PulsePhone.app/Contents/MacOS/PulsePhone`时，连`--help`和`version`也会失败为`internalFailure: missing("Registries/command-catalog.v1.json")`。
- 合同判断：PRD已声明PATH symlink是可选便利能力，TRD已要求从realpath和`F_GETPATH`确认的bundle root解析resource；这是实现偏差，不改变PRD/TRD既定产品结果。

### 根因与关闭标准

- `CanonicalAppPath`已经能把软链入口收敛为真实App路径，但CLI静态目录、Local Facts Helper、Runtime Client compatibility和产品版本仍分别读取`Bundle.main`。Foundation从bundle外软链启动时不会稳定把`Bundle.main`绑定到目标App，因此首个静态目录读取落到错误resource root。
- 实现必须让CLI production入口从同一个validated canonical app root派生`Contents/Resources`和App bundle metadata；测试注入入口、GUIHost和Runtime executable的正常bundle启动行为保持不变。
- packaged真实路径执行`--help`、`version`和代表性设备/Runtime命令必须保持通过；真实软链执行相同入口必须得到等价结果，不能依赖cwd、PATH或caller环境。
- 断链、循环、错误目标和非`PulsePhone.app`目标继续fail closed；修复不扩大活跃进程期间移动或替换App的支持范围。
- focused测试、完整`make check`、fresh packaged真实路径与软链smoke通过后才能标记`resolved`。

### 解决记录

2026-08-03开始修复。源码审计确认CLI侧四类production factory仍绕过既有`CanonicalAppPath`读取`Bundle.main`；当前唯一下一动作是新增canonical bundle resource/metadata派生入口，迁移CLI调用点并补真实软链回归。

实现checkpoint已让`CanonicalAppPath`统一派生bundle URL和`Contents/Resources`，CLI静态目录、Local Facts Helper、Runtime Client compatibility及产品版本均不再读取`Bundle.main`；GUIHost与Runtime executable的正常bundle入口不变。32项HostPath/CLI/Packaging focused测试通过。以当前debug Mach-O和packaged Resources组装的真实App fixture中，直接路径与外部软链的`--help`、`version --json`输出逐byte一致，软链`devices --json`成功列出当前iOS 26.5.2设备。打包器已在seal后、manifest前加入直接路径/外部软链Help与Version等价smoke。当前唯一下一动作：提交implementation checkpoint，在clean commit运行完整`make check`并生成fresh package触发正式打包smoke。

clean commit `a9e9ab3`的完整`make check`通过820项Swift测试、2项physical smoke按约定跳过、0失败，后续29项Gate选集通过；门禁中的两次App组装均已执行直接路径与外部软链的Help、Version等价smoke。当前唯一下一动作：从该clean checkpoint生成fresh package，执行真实路径与外部软链的代表性CLI及实体设备Runtime smoke。

clean checkpoint `1eb83c3`生成fresh development package，candidate input hash为`0dce48079416e205e9d7c9084eeea545b77486814aa7cab7ca3de1ab9d27a3a6`。从`/`作为cwd执行外部软链，`--help`、`version --json`、`devices --json`、`runtime status --json`均返回0且与bundle内真实executable输出逐byte一致；Devices与Runtime Status均正确投影当前iOS 16.3.1和26.5.2两台实体设备。未启动Runtime的状态保持`notRunning`，验证过程没有隐式启动Runtime。关闭`OBS-025`。

## OBS-026：Live 共存时 Element capture 可被单个截图 provider 永久阻塞

### 当前状态

- 状态：`resolved`
- 发现日期：2026-08-06
- 严重度：High
- 影响范围：iOS 17+ packaged `element snapshot` 与 Live 共存时的 DVT、CoreDevice、AXAudit
  现代截图 fallback、Helper generation 退休和后续设备命令。
- 用户可见结果：同一 candidate 在没有 Live 时 Element snapshot 成功；Live 已打开时连续查询可能在
  12 秒执行期限后返回 `executionTimeout`，而不是及时切换到下一截图 provider。
- 与其他问题的关系：`DV-015`只承接尚未部署的 OmniParser detector-only 外部服务，不覆盖已经确认的
  本地 capture 阻塞；`OBS-018`公开 Screenshot GUI/CLI 路径保持 resolved，本条只修改 Element 专用的
  现代 provider chain。

### 根因与关闭标准

- source `e82532a` 的 fresh candidate 在当前 iOS 17+实体环境中，无 Live 查询可由 DVT 成功；打开
  Live 后连续两次 Element 查询均返回 `executionTimeout`。关闭 GUIHost 后查询恢复成功。Live 下分别
  强制 DVT、CoreDevice、AXAudit 的 fresh session 均可成功，说明不是三个 provider 全部不可用。
- Runtime 采样显示请求停在 production CoreDevice Helper executor 等待 helper stdout；Helper 的
  provider loop 对 `service open -> capture -> retire` 没有单路 total deadline。persistent DVT 在状态变化
  后若不返回，既不会形成失败 attempt，也永远到不了 CoreDevice/AXAudit fallback，最终由外层 12 秒
  execution deadline 杀死请求。
- 每个 provider 必须使用覆盖 open/capture/validate/required close 的独立有界 attempt；timeout 形成
  typed failed attempt 并在尚未发布 artifact 时继续固定 fallback。取消和 retire 本身也必须有界，不能
  因等待 cleanup 再次突破 whole deadline；失败 service 从 generation 状态移除且不得接受迟到结果。
- 自动化至少覆盖 DVT 永久挂起后 CoreDevice 成功、DVT/CoreDevice 挂起后 AXAudit 成功、open/close
  挂起、三路全部挂起、外层 cancellation、成功后的 `retiringAfterResult` 和后续 generation 恢复。
- 只有 focused Python/Swift、完整 clean Gate、fresh package 的 Live/no-Live Element、fallback attempt
  trace、后续 pointer/keyboard/button 与 Runtime/Helper/artifact cleanup 全部通过后，才能标记
  `resolved`。

### 调查记录

2026-08-06 已完成 production 线程采样、单 provider 对照和无 Live 恢复对照；根因收敛到 Helper 缺少
provider级有界 attempt，而非 analyzer、fusion 或 capture coordinator 死锁。当前唯一下一动作是实现
DVT/CoreDevice/AXAudit 的有界 total attempt 与 cleanup，补永久挂起和 fallback 自动化。

source `1aeaad9` 已实现 DVT/CoreDevice/AXAudit `3/4/3 s` provider total budget 与 `250 ms` bounded
retire；超时先清除可复用 service/context，再有界关闭并记录当前 provider/stage。CoreDevice required
one-shot close 超时会丢弃该 image 并继续 AXAudit，任一 fallback 成功仍返回 `retiringAfterResult`。
CoreDevice Python 88 项、Runtime assembly 80 项（2 项 physical opt-in skipped）和 Element 65 项通过，
0 失败。当前唯一下一动作：从 exact clean source 生成 fresh package，重跑 Live/no-Live Element、attempt
trace、后续控制命令和完整 cleanup。

clean source `7d872b0b8f4fdb59aed6ccda9cae5c21c45001ff` 的 fresh development candidate input hash 为
`c918c97fae6bb0928abab914cc3b66574fb87e0d78b5744b40e115e756064d0a`，app content hash 为
`3090a5c16d1117c3cdef83aa6eea87ae79ab97cbd6b8f3e912465401c5f6ed9e`；完整 Python runtime、deep/strict
codesign 与 bundle closure 均通过。当前 iOS 17+ 实体设备上，无 Live 的 generation 1 由 DVT 成功，
capture `1396 ms`；打开 Live 后的 generation 2 精确记录 DVT `3004 ms` timeout、CoreDevice `3005 ms`
service-open failure，随后 AXAudit `1647 ms` 成功，完整 CLI 在 `10.63 s` 返回而未触发
`executionTimeout`。同一 Live 会话的 generation 3 又由新 DVT generation 在 `1004 ms` 成功，完整 CLI
为 `3.36 s`，证明污染 generation 已退休且后续 generation 恢复。

Live 保持打开时，公开 `button home`、`tap` 和 `text key --key escape` 分别在约
`0.51 / 0.57 / 1.42 s` 成功，Element timeout/fallback 未破坏后续 button、pointer 或 keyboard 链路。
关闭 Live 后公开 `stop` 在 `2.28 s` 返回 `stopped` 并回收一个 target；随后 target 状态为
`notRunning`，GUI、Runtime 和 Apple worker 进程均为零，target socket/helper manifest 不存在，lock
无打开者，scratch 与本次 mode-0600 原始 JSON/图片临时目录均已清理。最终 clean `make check` 执行
965 项主测试，2 项 physical opt-in 按约定跳过、0 失败，registry/current-contract/evidence Gate 全部
通过。关闭 `OBS-026`；其余 analyzer 降级、rotation/reconnect 与 legacy/外部环境矩阵继续由 Element
临时 TODO 和 Deferred Validation 管理，不作为本问题关闭条件。

## OBS-027：Element annotation 底图被垂直镜像

### 当前状态

- 状态：`resolved`
- 发现日期：2026-08-06
- 严重度：High
- 影响范围：公开 `element snapshot --format annotated|both` 生成的 annotation PNG；JSON 元素结果和
  原始 device screenshot 不受影响。
- 用户可见结果：实体设备 Home 页面原始截图方向正确，但 annotation PNG 的整张底图上下镜像，Dock
  出现在顶部、状态栏出现在底部，文字随像素翻转。

### 根因与关闭标准

- `ElementAnnotationRenderer` 使用原生 top-left bitmap buffer 创建 `CGContext` 后，又套用了 UIKit
  drawing context 才需要的 `translate + scaleY(-1)`，导致 source image 被二次翻转；元素 frame 已单独
  从 top-left 转成 CoreGraphics y 坐标，不能依赖翻转底图来校正。
- 既有非对称方向测试的像素读取 helper 使用了相同错误变换，生产实现和 oracle 相互抵消，因此未能
  阻止回归。修复必须同时移除生产 CTM 和测试 helper CTM，并继续覆盖 top/bottom 不对称底图、top-left
  frame、fractional canvas-edge frame 与 metadata binding。
- focused tests、完整 clean Gate、fresh package 实体 `both` 的原图/annotation 方向和框坐标均通过，且
  JSON 中 capture provider、三路 analyzer health 与 artifact hash/dimensions 一致后才能关闭。

### 调查记录

2026-08-06 已移除 renderer 与测试像素读取 helper 的多余翻转；`ElementSnapshotResultBuilderTests`
17 项通过，覆盖 source top-left orientation、框坐标、分数画布边界和 annotation metadata。当前唯一
下一动作是从该修复提交建立 clean worktree 打包，在当前实体设备执行真实 `both` 并核验 PNG 与脱敏
JSON；在此之前保持 `investigating`。

修复提交 `1d2769b80c2e951e96949666213e82e59e3eba5d` 的 clean detached worktree 生成 fresh ad-hoc
development candidate；candidate input domain hash 为
`6a52829738889912135f2d1fc23ea8ab38ab5d8a83340c5a4b43abd78d498110`，App content hash 为
`ab1465f4414f6809667c348936b08a6a1158a885c009d1253129de24e66f850a`，13,758-entry manifest、嵌入式
Python full verification 与 deep/strict codesign 通过。

同一 candidate 在当前 iOS 17+ 实体设备执行公开 `element snapshot --format both` 成功：DVT 获取
portrait `1170 x 2532` current viewport，Vision 和 Apple private region succeeded，OmniParser 因旧协议
明确 unavailable，最终 31 个元素；capture/analyzer/annotation 分别为 `1442 / 252 / 167 ms`。
annotation 文件为 mode `0600`、`3,817,389` bytes，其实际 hash、dimensions 与 JSON metadata 完全一致。
人工复核确认状态栏位于顶部、Dock 位于底部、文字方向正常，框继续贴合 top-left 元素坐标；未提交图片、
OCR 正文、raw UDID 或 capture digest。公开 stop 显示会话已经停止，无遗留 Runtime。

exact source 的完整 clean `make check` 通过 966 项主测试，2 项 physical opt-in 按环境约定跳过、0 失败；
registry 双语言 generation、7 项 parity、`Scripts/verify-contracts current` 14 项和
CurrentIdentity/EvidenceContract 29 项全部通过。关闭 `OBS-027`。

## OBS-028：Element 客户端以未部署的未来协议拒绝当前 OmniParser 服务

### 当前状态

- 状态：`resolved`
- 发现日期：2026-08-06
- 严重度：High
- 影响范围：默认 `element snapshot` 的 OmniParser 分支、三路融合、纯图标和控件 geometry。
- 用户可见结果：PulsePhone 直接 POST `/parse/`，OmniParser 与 Vision、Apple private detection 从
  同一帧并行返回；服务成功时不再因客户端虚构的 readiness/probe 协议退化。

### 根因与关闭标准

- 当前服务的 `GET /parse/` 返回 HTTP 405 且 `Allow: POST`，没有 application readiness API；
  `POST /parse/` 接受 `base64_image/response_mode/box_threshold/iou_threshold`，返回 `latency` 和
  `parsed_content_list`。每项包含归一化 `[x1,y1,x2,y2]` bbox、`type`、`interactivity`、`source` 和
  `content`，不返回 confidence。
- PulsePhone 最初错把尚未部署的 versioned detector-only probe/request/response 设计当作当前必需
  协议，并且首先请求同级 `/probe/`；第一次修正又把同一 `/parse/` 的 GET 错当 readiness。两种实现
  都在 POST 前失败，不会向已工作的 `/parse/` 上传派生图。这是客户端合同与实现错误，不是服务故障。
- 当前部署协议必须成为 production baseline：严格限制 body/count/type/bbox/timeout，使用最长边
  1280 的派生 PNG，把归一化 bbox 经派生图 geometry 还原到 source pixels；只把 `icon` 或
  `interactivity=true` 项作为无伪造 confidence 的 control candidate，文字 label 仍优先来自 Vision。
- versioned detector-only 协议只能作为未来可选增强，不能阻挡 baseline。Runtime 继续复用一个有界、
  无 cookie/cache/credential/proxy 的 keep-alive client generation，失败和 circuit 语义保持隔离。
- focused protocol/fusion tests、真实 endpoint 请求、fresh packaged 当前设备 `both`、三路状态/框/坐标、
  后续 control 与 cleanup 通过后才能关闭；大样本精度、资源和未来增强协议保留 Deferred Validation。

### 调查记录

2026-08-06 对默认 endpoint 再次只读/内存验证：`GET /parse/` 返回 HTTP 405 和 `Allow: POST`；使用
未提交的 `b.png` 按 Pulse 请求体直接 POST 成功，HTTP 200 返回 exact 顶层键
`latency/parsed_content_list` 和 33 项（23 icon、10 text、23 interactive），每项 exact 键为
`bbox/content/interactivity/source/type`，33 个 bbox 均为四个有限归一化数，未保存响应正文。

同日 `f4e6f14` fresh package 在当前设备执行 `both`：Vision/Apple 成功，但 Omni 在 84 ms 内
`unavailable`；随后对默认 endpoint 的 GET 得到 405，确认第一次 baseline 修正仍错误依赖 GET。
当前修正改为 production 直接 POST，未来 versioned capability probe 只保留显式内部模式；必须重新
完成 focused/clean tests、fresh package 与三路真机成功后才能关闭。

关闭证据：`8f820dc` 将 production client 改为直接 POST `/parse/`，`c76becd` 增加 viewport clip；
focused Element tests 70 项及 exact clean `d746dae` 的完整 `make check` 均通过，后者执行 971 项主测试、
2 项 physical opt-in 按合同跳过、0 失败，current/evidence 29 项继续通过。由该 clean commit 生成并
deep/strict codesign 验证的 fresh candidate 在当前实体设备 cold generation 1 和同 Runtime warm
generation 2 均为三路 `succeeded`、`degraded=false`：Omni 分别返回 24 项，耗时 `2263/2064 ms`。
当前部署协议已闭环；未来 versioned detector-only 协议、外部服务资源和大样本精度继续由 `DV-015`
承接，不重新打开本问题。

## OBS-029：Element correction 不能细化已有候选或构造可操作控件框

### 当前状态

- 状态：`resolved`
- 发现日期：2026-08-06
- 严重度：Medium
- 影响范围：fusion 后 geometry correction、纯图标/控件框、annotation 可读性。
- 用户可见结果：非 Omni 候选可在已有 seed 周围执行有界局部精修或构造 control frame；可信 Omni
  geometry 保持优先，annotation 使用低遮挡描边展示最终 frame。

### 根因与关闭标准

- 当前 correction 只是过大横向 parent decomposition POC：只有 parent aspect/area/child containment
  同时命中才运行局部 component detection；普通已有候选完全不会进入处理。
- 即使命中，`mergeLocal` 在 overlap >= 0.72 时仍保留 `existing.frame`，只追加 `localGeometry` source，
  所以它没有“细化现有框”的能力。实体 Home 查询中该层被调用但未应用，correction 为 0 ms 且没有
  `localGeometry` source；单纯降低现有门槛会扩大误报，不能解决能力缺失。
- 保留过大 parent decomposition，并增加独立、保守的 existing-frame refinement/control-construction
  层：只能在局部 source pixels、候选 seed 和版本化质量门禁共同支持时替换 geometry 或构造 control；
  失败、不确定、数量/面积/尺寸越界时逐项保留原候选，禁止全屏无 seed 搜索。
- Omni 当前协议的 control geometry 必须先接通；correction 不得覆盖可信 Omni 框，只能用作缺失/局部
  改善证据。自动化需覆盖真实替换、控件构造、纹理/低对比回退、边界 clip、数量 cap 和确定性排序。
- annotation 描边必须减少对原始内容的遮挡，同时保持来源可辨、frame 精确和 canvas edge 安全。
- focused/clean tests 及 fresh packaged Home/第三方 App 对照通过后才能关闭；大样本 precision/recall/
  IoU 判定继续由 `DV-016` 管理。

### 调查记录

2026-08-06 已完成代码和最新 `a.png` 审计，确认根因是能力边界而非单一阈值。当前唯一下一动作是更新
最终态 geometry 合同，然后实现有 seed 的候选细化/控件构造和低遮挡 annotation，并在接通真实 Omni
后重新评估三路结果。

关闭证据：`f4e6f14` 增加 bounded existing-frame refinement/control-construction，只处理已有非 Omni
seed，质量门禁失败逐项保留原框；可信 Omni frame 不被 correction 覆盖。自动化覆盖真实 frame 替换、
control 构造、Omni 保护、低对比/纹理回退、viewport clip、数量 cap、排序和 `localGeometry` attribution；
focused Element tests 70 项及 exact clean `d746dae` 的完整 Gate 通过。fresh packaged Home 页面中三路
成功，correction 在 cold/warm 分别实际执行 `114/79 ms`；24 个可信 Omni candidate 覆盖主要图标，
因此最终 `localGeometry` 为 0 是保护策略的预期结果，不是 correction 未运行。人工复核 annotation
方向、图标框和描边均可读。跨 App 的统计精度、recall 和 IoU 仍由 `DV-016` 承接。

## OBS-030：Element Runtime 冷启动首次请求可能命中过早的 outer deadline

### 当前状态

- 状态：`resolved`
- 发现日期：2026-08-06
- 严重度：High
- 影响范围：新 Runtime epoch 的首次 `element snapshot`、Vision/Apple 一次性 prewarm、CLI 冷启动
  可靠性。
- 用户可见结果：新 Runtime epoch 的首次请求拥有独立 prewarm allowance；cold 和同进程 warm 请求
  均在 outer safety deadline 内返回，不再因一次性初始化命中过早的 `executionTimeout`。

### 根因与关闭标准

- analyzer 合同把 Runtime epoch 一次性 Vision/Apple 并行 prewarm 排除在 `8/3/2 s` branch 和
  `10 s` whole analyzer budget 外；production pipeline 却从 capture 前启动 JSON `12 s` / annotation
  `17 s` outer deadline，把 capture、prewarm、analysis、correction 和 annotation 全部压入同一预算。
- outer safety deadline 改为 JSON `27 s` / annotation `32 s`，新增 15 秒只作为首次 prewarm allowance；
  provider、branch、whole analyzer 与 correction 内部 deadline 不得放宽，CLI 60 秒 receive deadline
  保持最终上界。
- focused tests 必须冻结 production deadline 并证明 cancellation/join 语义不变；clean Gate 后从 fresh
  package 执行 public stop、cold generation 1、同 PID warm generation 2，要求三路 succeeded、
  `degraded=false`，随后 public stop 清理 Runtime/Helper/worker。

### 调查记录

2026-08-06 当前 `c76becd` staging candidate 的一次 fresh Runtime 请求返回 `executionTimeout`；持久在线
shell 内 Runtime PID 保持不变，下一请求 generation 2 三路成功。使用正确公开 `stop` 独立复测后，
generation 1/2 均三路成功、`degraded=false`，wall 分别为 `8.47/5.41 s`，且两次之间 Runtime PID
均为 `74441`。执行工具在 shell 结束后会回收其后台 descendant，因此跨独立 tool shell 的 PID 消失
不是产品 Runtime idle 缺陷。

`233e860` 冻结 TRD/TODO/临时架构的 `27/32 s` outer safety deadline；`bcba705` 将 production
pipeline 改为 exact 常量并增加 focused contract test。`ProductionElementSnapshotPipelineTests` 23 项
全部通过，包含 deadline capture cancellation、branch cleanup join、shutdown、共享 waiter、authority
retry 与 generation。当前唯一下一动作是运行 clean Gate，从 exact clean commit 生成 fresh package 并
执行 cold/warm packaged 实体验收。

关闭证据：exact clean `d746dae` 完整 `make check` 通过 971 项主测试、2 项 physical opt-in 按合同
跳过、0 失败，current/evidence 29 项通过；由同一 commit 生成的 fresh signed candidate 通过完整
Python closure 和 deep/strict codesign。public stop 后的 cold `both` wall 为 `7.40 s`、generation 1，
同一 Runtime 的 warm JSON wall 为 `4.62 s`、generation 2；两次均三路 `succeeded`、
`degraded=false`。Runtime PID `75868` 与 Apple worker PID `75878` 在两次请求之间保持不变，证明
Runtime、Vision warm state 和 Apple worker 均跨 CLI 复用。最终 public stop 与零残留检查纳入本次
候选收尾。

## OBS-031：Element production server 未使用已冻结的 outer deadline

### 当前状态

- 状态：`resolved`
- 发现日期：2026-08-06
- 严重度：High
- 影响范围：packaged `element snapshot` production server 装配、cold/annotated 可靠性，以及基于
  production 入口的 analyzer 性能 A/B。
- 用户可见结果：`--format both|annotated` 在同一设备和页面可能间歇性返回泛化的
  `internalFailure`；当前 analyzer 基准也可能被旧 outer deadline 提前终止，不能作为最终验收数据。

### 根因与关闭标准

- `ProductionElementSnapshotPipeline` 已声明 JSON `27 s`、annotation `32 s`，但 production server
  的 `executeElementSnapshot` 绕过 pipeline convenience 入口并继续显式传入旧的 `12/17 s`。
- 既有回归只断言 pipeline 常量，没有覆盖 production server 的实际 deadline 选择，因此
  `OBS-030` 的关闭证据没有冻结真正的 production assembly。
- production server 必须从唯一 deadline policy 取值，并增加 server-level 测试覆盖 JSON 与
  annotation；未分类的 pipeline/result/annotation 错误至少要留下可定位诊断，不能只剩
  `internalFailure`。
- 同一 fresh packaged candidate 必须通过 cold/warm JSON、both、内部单/双/三 analyzer A/B、后续
  控制和 public stop cleanup，才能关闭本问题。

### 调查记录

2026-08-06 在当前 staging candidate 上，同一页面的 JSON 三路查询持续成功，但 `both` 曾两次返回
`internalFailure`，后续又成功；源码审计确认 production server 仍使用 `12/17 s`。同日默认三路 warm
JSON 多次 wall 约 `4.9-5.5 s`，尚未使用新的内部 analyzer selector，且当前 Pulse `screen parse`
因设备端 Peertalk 服务未就绪停在 `Screen scale not found`，不能把其失败耗时当作 Omni 基线。
当前唯一下一动作是修复 production deadline 装配、增加 request-scoped 隐藏 analyzer selector 与
server/CLI/coordinator 回归，再生成 fresh package 采集同屏分阶段数据。

实现 checkpoint：production server 已统一读取 pipeline 的 `27/32 s` 常量；隐藏
`--internal-analyzers` 在公开 Catalog 解析前严格校验并只把 canonical selection 送入本次 Runtime
request，coordinator 对未选择路线既不 prewarm 也不执行，同时保持固定三路 engine schema。Element
55 项、pipeline 23 项、CLI 23 项及 production assembly selector/deadline 回归均通过。首次完整 Gate
执行 975 项、2 项 physical opt-in skipped；本机 Input Monitoring 一度被系统投影为 required，既有
GUI keyboard permission 测试出现 4 assertions 失败，另有 4 个失败是 packaging/product tests 按
合同拒绝 dirty worktree。随后完整 `swift test` 的键盘用例恢复并使全部 60 项 GUI assembly 通过，
只剩 4 个预期的 dirty-worktree packaging failures；提交后必须从 clean worktree 重跑 `make check`。
当前唯一下一动作是提交实现 checkpoint、完成 clean Gate、生成 fresh staging 并执行实体单/双/三路
A/B 与 annotation 验收。

clean/实体 A/B checkpoint：`4819aa8` 的完整 `make check` 通过 975 项主测试、2 项 physical opt-in
按合同跳过、0 失败，并生成 fresh signed staging。持久终端内复用同一 Runtime 后，warm capture 约
`1.11-1.21 s`，Omni 约 `2.0-2.5 s`、Vision 约 `0.11-0.28 s`、Apple 约 `0.06-0.08 s`；默认三路
wall 约 `5.32-5.48 s`，证明 fan-out 并行且总 analyzer 时间由 Omni 控制。直接按冻结的 `/parse/`
协议请求同一服务，`591x1280` 输入 resize/encode `69 ms`、HTTP round trip `2093 ms`、总计
`2161 ms`、返回 30 项，未观察到稳定的 8 秒服务耗时。当前 Pulse 的设备截图停在
`Screen scale not found`，不能用失败 wall 作为对照；其历史 USB screenshot 本身约 `3.94-4.11 s`。

隐藏组合实体测试进一步定位到新的可靠性边界：Vision-only 两次及 Vision+Apple 一次返回
`internalFailure`，日志类型为 `ElementSnapshotResultBuildError`。成功的 Vision+Apple 样本已记录
`correctionMilliseconds=991`；源码确认局部精修对最多 64 个非 Omni seed 重复构造 crop 渲染输入并且
result builder 把 TRD 的 1 秒性能预算错误用作序列化合法性上限，合法修正轻微超过 1000 ms 即抛
`invalidTiming`。修复必须复用单次 prepared source、用版本化工作量上限约束修正，同时把结果安全校验
与性能目标解耦且保留真实耗时；不能通过夹紧或伪造 timing 关闭问题。当前唯一下一动作是完成上述
实现和回归，再从 fresh staging 在同一持久终端复测全部 analyzer 组合及 repeated `both`。

关闭证据：`00a7ebb` 让全部 local crop 复用单次 prepared grayscale source，并用每帧
`4,194,304` rasterized pixels 与 1 秒 monotonic deadline 约束 correction；预算耗尽逐项保留原
geometry。result builder 接受真实 `1001 ms` correction timing，并以独立安全 cap 拒绝异常数据，
不再夹紧或把性能目标越界变成 `internalFailure`；Runtime 日志同时记录具体 result-build enum case。
Element 73、pipeline 23、production assembly 81（2 physical opt-in skipped）及 CLI 23 项 focused
验证通过。exact clean `make check` 通过 976 项主测试、2 项 physical opt-in skipped、0 失败，随后
29 项 current/evidence Gate 全部通过。

同一 exact source 生成的 fresh candidate input hash 为
`fbf3b28937f363c29ae4301c358d1222357d3fc5dd42b6e1d0f2dde0e3e4c8ff`，App content hash 为
`683975dd2d265624be4c09913d54c367827475285b6841952649a21159066b67`；Python full、完整 manifest 与
deep/strict codesign 通过。持久 shell 内 generation `1...11` 覆盖全部 7 种非空 analyzer 组合及
3 次 `both`，全部成功；correction 为 `50...130 ms`，三路 warm wall `4.86 s`，3 次 `both` wall
`4.82...5.13 s`。另对原失败边界 Vision-only 和 Vision+Apple 各连续 5 次，10/10 成功、
correction `114...126 ms`，每次有 3 个 localGeometry 命中。三张 annotation 均为
`1170 x 2532`，人工确认方向、文字和框正确。后续 Home acknowledged，公开 `stop` 回收 1 个 target，
最终 `notRunning` 且 Runtime/helper/Apple worker 零残留。关闭标准全部满足，本问题标记 `resolved`。

## OBS-032：Element 标注图混入文字框且跨控件证据未收敛

### 当前状态

- 状态：`resolved`
- 发现日期：2026-08-06
- 严重度：Medium
- 影响范围：fusion 后的重复候选、local geometry 类型语义和 `annotated|both` 可读性。
- 用户可见结果：annotation 同时绘制 OCR text 与 control frame，出现大框套小框；跨两个底部控件的
  OCR 文字可能保留为独立大框；图标与数字计数也可能作为多个重叠项输出。局部几何还会根据候选尺寸
  把 image text 提升为 `controlCandidate`，使仅用于识别的文字被误画成可点击目标。

### 根因与关闭标准

- JSON element array 和 annotation projection 复用同一未筛选数组，没有区分“机器可检索证据”和
  “面向点击的标注目标”。
- fusion 只有单候选 overlap merge 和旧 OCR containment suppression，不能表达一个文字/region 同时
  为多个相邻 control 提供证据；local refinement 又越权推断 interactivity。
- 修复必须让 JSON 保留完整 final array、annotation 只画 `controlCandidate`，同时以确定性同级约束
  收敛 multi-control OCR 与 Apple evidence。container/child、nested detector box 和普通文字不得因
  去重被删除；local refinement 必须保持 seed 类型。
- focused 回归、完整 clean Gate 和 fresh packaged 当前实体页面必须全部通过。实体结果需确认跨控件
  OCR 大框消失、图标+计数按证据收敛、image text 仍为 text、annotation 只画 control，且三路状态、
  correction timing、方向、hash/尺寸及 public stop cleanup 无回归，才能标记 `resolved`。

### 实现与关闭证据

fusion 已增加 multi-control OCR individual/union coverage、container 剔除、同级 pair overlap 上限及
ordered label assignment；Apple region 可作为 control evidence，仅对相邻的无 label icon + 纯数字
counter 执行桥接。local refinement 删除尺寸/长宽比类型提升，annotation builder 只投影
`controlCandidate`。focused Element 118 项通过，包含 container/child 与 nested numeric child 的负向
回归。

exact source `94af605` 的 clean `make check` 通过 981 项主测试、2 项 physical opt-in skipped、
0 失败，后续 29 项 current/evidence Gate 全通过。fresh staging executable SHA-256 为
`57d22ba5921da5cfc822600e4698f0d935b775178920512327558cf1a3577b97`，与 clean Gate 产物逐字节
一致且 deep/strict codesign 通过。默认 `both` 在当前实体同页得到 30 个 `controlCandidate` 与 32 个
`text`；OmniParser、Vision、Apple region 分别以 `2550/318/65 ms` 成功，三路 wall `2552 ms`，
correction `103 ms`，无 degradation。annotation 只绘制 30 个 control，跨相邻控件的 OCR 大框和
image text 框不再出现；JSON 仍保留 32 个 text，nested/card-child 负向语义由同 candidate 的 focused
回归固定。输出为方向正确的 `1170 x 2532` PNG，annotation SHA-256
`a22a6c5940fed9fcaa0839195a9be05db6b6141949b1047c4750aadef2cb7b62`，其 capture hash 与结果绑定。
公开 status 最终为 `notRunning`，Runtime 与 Apple worker 无残留，关闭标准全部满足。

## OBS-033：Element Live 帧复用拒绝首次绑定的临时几何

### 当前状态

- 状态：`resolved`
- 发现日期：2026-08-08
- 严重度：High
- 影响范围：packaged `PulsePhone live` 的 chooser/automatic probe 到 bound session handoff，及
  bound Live 帧向 Element snapshot provider 的复用。
- 用户可见结果：source chooser 可以持续显示实体 iPhone 画面，但确认后主 Live 固定进入
  `Video unavailable` / `Touch preparing`，反复选择同一有效 source 也无法恢复。

### 根因与关闭标准

- Live 首次绑定在 Runtime authoritative geometry 尚未到达时，按既有合同使用
  `geometryRevision = 0` 的 provisional geometry 启动视频；首个 accepted sample 随后触发
  capture-ready transition，并用 revision 大于零的 current geometry 重绑视频与坐标 authority。
- `7857d82` 增加 `LiveSnapshotFrameProvider` 后，其初始化拒绝 revision 0，并使
  `ProductionBoundVideoSession.start` 抛错。GUIHost 以 `try?` 静默吞掉该错误，再把同一有效
  AVFoundation source 投影为 unavailable；因此 chooser preview 正常而 bound Live 确定性失败。
- 修复必须保留 provisional 视频启动与展示，但 provisional provider 不得发布 Element
  `SnapshotFrame`、登记 visual-settlement action 或建立坐标 authority。收到 current authoritative
  geometry 后，现有 session 必须原地重绑并激活 provider，不能重启 capture backend。
- bound start failure 必须留下不包含 raw source/target 身份的稳定诊断码；不得继续静默吞错。
- 自动化至少覆盖 provider provisional -> authoritative 状态转换、preview/probe lease 原地 promotion、
  provisional sample 继续推进 Live capture-ready、Element query/action fail closed、authoritative rebind
  后同一 backend 发布可信帧，以及 reconnect/new epoch 不复活旧 provider。
- focused tests、完整 clean Gate、fresh packaged 当前实体 `live` 首次绑定、重复打开、Element snapshot
  共存与后续控制全部通过，且 Runtime/GUIHost cleanup 无残留后才能标记 `resolved`。

### 实现与验证

`LiveSnapshotFrameProvider` 已增加显式 `provisional` 状态：构造和 expected-authority 比对允许 exact
revision 0，但 query、action registration 和 publish 均 fail closed；`rebind` 仍只接受 revision 大于零
的 authoritative geometry。Bound session 启动改为记录稳定、无身份数据的错误码，不再以 `try?`
静默丢失失败原因。provider、capture coordinator 和 GUIHost focused tests 共 90 项通过，覆盖同一
backend 上的 provisional sample、capture-ready、authoritative rebind、可信帧发布、retire/reconnect
fence 及错误码。

source commit `7b5e38c` 的 clean `make check` 通过 993 项主测试、2 项按合同跳过的 physical opt-in
测试和后续 29 项 current-contract/evidence 测试，0 失败。fresh signed candidate SHA-256 为
`e93a85c52ca69fec5fcb7b3173428667628496eb8bc53e8f061f0cfe72fd7566`；deep/strict codesign 通过。
当前 iPhone / iOS 26.5.2 的首次打开和缓存映射重开均直接进入 bound Live，真实画面持续更新且无
`Video unavailable`。两次会话都采纳 `connectionEpoch=4 / geometryRevision=1 / portrait`；重开后
GUI 点击主屏搜索产生 pointer `p0/p1` 并真实打开搜索页，工具栏 Home 恢复主屏，video sample 随后
继续递增到 sequence 2200 以上。Live 打开期间 `element snapshot` 成功返回当前页结果，后续 Home
控制成功，Live 未冻结；该 CLI action 按 TRD 09 使用独立 device capture provider，不作为 Live provider
跨进程复用证据。日志不存在 `stage=boundStart outcome=failed` 或新的 unavailable 投影。验证创建的
GUIHost 已关闭；任务开始前已存在的全局 Runtime 保持不变。关闭标准全部满足。

## OBS-034：Developer Support preparation 未接入生产单飞与 remediation 合同

### 当前状态

- 状态：`resolved`（build 22 的 iOS 26.5.2 packaged/device 验收与 exact Runtime assembly 回归已完成）
- 发现日期：2026-08-21
- 严重度：High
- 影响范围：`device prepare`、所有需要 Developer Support 的普通 CLI 命令及 `live` launcher。
- 用户可见结果：`device prepare` 不能作为唯一、不可取消的进度观察入口；多个并发调用可能重复实际准备。未 ready 的普通命令会同步等待准备并自动续跑原动作，Live 在 GUI 创建后才尝试准备，均与当前产品要求冲突。

### 已确认根因与目标合同

- production `ProductionRuntimeServer.executePreparation` 每次请求都新建 attempt，且
  `executeImplicitPreparationIfNeeded` 在请求线程同步执行 prepare 后递归续跑原命令；已有
  `PreparationCoordinator`、`PreparationWaitRegistry`、`PrepareObserver` 与
  `PrepareCapabilitiesControl` 只存在模型/测试，没有接入生产 Runtime。
- Runtime 必须以 `(connectionEpoch, preparationGroupID)` 作为唯一 job key。所有显式 prepare
  observer 复用同一 progress/terminal；ordinary DDI command 和 Live preflight 仅 start/join job，立即以
  `capabilityPreparing` 返回 `remediation=runDevicePrepare`，human output 包含 `Developer support preparation is in progress. Run PulsePhone device prepare to follow progress.`。
- 普通命令不得在该路径获得 accepted boundary、执行原动作、重新规划或自动 retry；Live 未 ready 时不得创建 GUIHost、Resolver、Chooser 或窗口。显式 `device prepare` 的 CLI 忽略 SIGINT，client EOF 不取消 Runtime job。

### 关闭标准与唯一下一动作

- focused tests 必须证明 concurrent explicit observers 只有一次 executor invocation、late observer
  重放 progress 并收到相同 terminal、ordinary command 的原动作未执行、ready fast path 正常、Live 未 ready
  不调用 GUI open，以及 SIGINT 不取消 Runtime job。新增跨 Runtime generation 回归必须证明：先前 explicit prepare 后，fresh
  Coordinator 只在实际 mounted query 与 required-service warm 都成功时恢复 current ready，随后手动 retry 正常执行；未mounted
  或 warm failure 时仍只返回 remediation，零 original action。随后完成 clean Gate、fresh packaged build 和当前 iOS 26.5.2
  的显式 prepare、ordinary remediation/ready command、Live preflight 及 cleanup 验收。
- 本 OBS 已关闭。后续产品修改若再次出现未准备 remediation、explicit prepare 或跨 generation retry 的偏差，应重新打开本条，
  不得以旧 receipt 或旧 Runtime status 代替新的实体序列。

### 2026-08-21 实现与主机验证

- `048cc89` 新增 Runtime-owned `ProductionPreparationJobManager`，以 `(connectionEpoch, preparationGroupID)`
  作为 job key。显式 observer 共用一次 attempt、收到相同 terminal，后加入 observer 重放最新 progress；failed
  start-only attempt 只能由后续显式 `device prepare` 重试。
- `ProductionRuntimeOperationBackend` 只根据 Runtime capability planner 决定是否需要 preparation；没有 CLI
  command whitelist。ordinary finite/touch/keyboard/pointer/element command 只 start/join job 并返回带
  `remediation=runDevicePrepare` 的 `capabilityPreparing`，不执行、排队或重放原动作。显式 prepare 使用
  `waitForTerminal`，CLI 不设置独立 socket deadline；`SIGINT` 不产生终态。
- Live 在 GUIHost、Resolver、Chooser 和窗口创建前发送 `startOnly` preflight；未 ready 时返回 remediation 且不
  创建窗口。原 GUIHost attach 后自行 prepare 的路径已经删除。
- 已通过 `make build-go`、Runtime assembly 96 项（5 项明确 physical opt-in skip）、CLI/Catalog/GUI focused 96 项，
  以及 single-flight、ordinary no-replay、Live no-window、SIGINT 与 legacy/element explicit-retry 回归。完整 clean
  Gate 也已在 clean `4eaa710` worktree 通过：1,022 项 Swift、5 项明确 physical opt-in skip、0 failure；Go、registry、
  current-contract 与 evidence 子门槛均通过。原始日志为
  `build/observations/prepare-singleflight/make-check-clean-20260821T1534.log`，SHA-256=`d849191ef925ead0c5ad97f0ddf588755875490f353ff8c8c4e5810c59075d8c`
  （不提交）。fresh package 和实体 iOS 26.5.2 验收尚未执行，不能据此关闭本 OBS。
- `7e473b0` 修复 headless GUI reconnect assembly test 的调度假阴性：session 报告 availability 后，测试会有界
  重试尚未被接受/下发的 `pointerBegan`；production code 未改变。该 test class 60 项通过。随后精确 clean
  `make check` 通过 1,022 项 Swift、5 项明确 physical opt-in skip、0 failure（491 s）；Go、registry、
  current-contract 与 evidence 子门槛均通过。原始日志为
  `build/observations/prepare-singleflight/make-check-clean-7e473b0-20260821T1600.log`，SHA-256=
  `0d3e444ca954e10cedde45d7d98c90abc44a69d922920d75ab1f864ea029cf20`（不提交）。fresh package 和实体
  iOS 26.5.2 验收仍未执行，故本 OBS 保持 `investigating`。
- 从 clean source `bc1aa74a14e869edb1608fc02b79a7cab29a016c` 生成 fresh staging candidate：
  `build/staging/PulsePhone.app`，版本 `0.1.0 (16)`；candidate input 为
  `build/evidence/objects/68ff080ad3cfd3f1cdeff0f48475abb8ab063e6af9810e796aa5a3f6580126e6/release-candidate-input.v1.json`，
  release candidate input hash=`15a8b95ba3b6c6cdc7d759f744e0f83f386b369c58400eb1a579c027a92f1b75`。
  `codesign --verify --deep --strict` 通过；bundle 为 34 MiB、116 files，仅包含
  `PulsePhoneRuntime`、`PulsePhoneDirectHelper` 和 `PulsePhoneCoreDeviceHelper` 三个 Helpers，且 `.py`、`.pyc` 与
  `__pycache__` 数均为零。封装日志 SHA-256=`d2b3e4010a65e5fcadb77785db027515c406db4d2588c2ee4aa9be9c8cf7c937`
  （不提交）。实体 iOS 26.5.2 验收尚未执行。

### 2026-08-21 capture preflight correction

- fresh packaged acceptance 随后证实 Live 的未准备分支已返回 remediation 且不创建 GUI，但发现 `screenshot.cli` 和
  `element.snapshot` 仍有独立缺口：二者先调用 `planScreenshot()`；现代 route 在 capability 为 awaiting 时直接抛出
  `screenshotUnavailable(capabilityPreparing)`，使后续 `executeImplicitPreparationIfNeeded` 不可达。因此它既不会启动或加入
  Runtime-owned job，也会丢失 `remediation=runDevicePrepare`。这是普通 capture command 的真实合同偏差，不接受为 Python/Go
  行为差异。
- `f58c0f5` 新增 capture 共用 admission/preflight，在 Hybrid route 选择前以 `commandAdmissionSnapshot` 和 planner 识别
  awaiting preparation，启动或加入既有 `(connectionEpoch, preparationGroupID)` job 后返回带 remediation 的
  `capabilityPreparing`；unavailable/unknown 仍保持原有 typed failure。capture、OCR 和原始 action 均不执行或重放。回归
  `testModernCaptureCommandsStartPreparationBeforeCaptureAndRequireRetry` 在一个 blocked warm attempt 中同时覆盖 screenshot 与
  element：两者均得到 remediation、element analyzer 调用数为零，warm 完成后只有手动 screenshot retry 执行。新的
  `make verify-preparation-capture` 以该测试作为不打包、不签名的快速前置检查。
- clean `f58c0f5` 的完整 `make check` 通过 1,023 项 Swift、5 项 physical opt-in skip、0 failure（483.621 s）；日志
  `build/observations/prepare-singleflight/f58c0f5-capture-preflight-20260821T1630/make-check.log` 的 SHA-256 为
  `028d3937f6355b9f827859c5b067e5da8a26007a473ff853e84691ecc10be92c`，不提交。`4c60df2` 仅增加上述快速 Make target。
- clean `4c60df2` 已组装、strict-codesign 校验并 self-install 为 `0.1.0 (19)`；candidate input hash 为
  `f756cb463dcee46e253200e4b784ff710ab7294f4e235f7000bb65dd63e08458`。全局 CLI 确认为 build 19，target 精确为
  `00008110-001A7D523E90401E` / iOS `26.5.2` / `23F84`。fresh Runtime 的 `device prepare` 为
  `alreadyReady`，随后 screenshot 成功（PNG SHA-256
  `a061f17cbfbf1d159af092c928e4b351a8bdd1d21d12e525d3f14abb640a6f98`）、element snapshot 的 DVT/OmniParser/Vision/Apple
  analyzer 均成功、Runtime 为 `full`。原始结果位于
  `build/observations/prepare-singleflight/4c60df2-capture-preflight-package-20260821T1640/`，不提交。
- 此次设备当时已经 `alreadyMounted`，所以它证明 ready fast path 无回归，不能替代新 capture remediation 的真机分支验收。
- owner 已完成 Developer Mode cycle、重启和解锁；build 19 的首次 `screenshot.cli` 返回了
  `capabilityPreparing` 且零 artifact，但 JSON envelope 丢失 `remediation=runDevicePrepare`。原始结果为
  `build/observations/prepare-singleflight/2dffc9b-capture-preflight-device-20260821T1650/first-screenshot.*`
  （response SHA-256=`736ed64d...f8ce7b`）。因此“未 ready 时不 capture/replay”获得真机证据，但 remediation 产品合同未关闭。
  根因已定位为 CLI screenshot adapter 从 `RuntimeClientScreenshotResponse.result` 仅投影 code、丢弃 details；Runtime socket
  本身保留 details。修复将 details 透传至既有 standard error renderer；`make verify-preparation-capture` 现连续覆盖 CLI
  JSON/human/no-artifact、screenshot-specific real socket failure 和 Hybrid start/join/no-replay 三项，全部通过（约 8 秒）。
- 首次 `ad75115` `make check` 被操作者在 long-running `Scripts/package-app` cold Swift build 期间终止，partial log SHA-256=
  `6a795db2...25d40`，不得作为通过或失败证据。终止后的 stdout 刷新证明
  `PartialWriteTests/testIPCMalformedBackpressureCapacityFixture` 实际为 0.001 秒通过，随后才开始
  `PerformanceContractTests/testPackagedCandidateCollectionPublishesAuditableUnknown` 的 package 子进程；此前日志停留在
  PartialWrite 是缓冲现象，不能归因于 harness 或本修复。尚未关闭：先执行不触发 packaging 的 release 编译及相关完整测试集，
  然后再进行一次最终 package/Gate，并由 owner 在新的 Developer Mode cycle 后复验。该前置验证现已完成：release Swift build
  成功（log SHA-256=`be0607d0...d89bd`），`ArgumentPreflightDispatcherTests` 27/27 通过（`383c0110...68672`），
  `ProductionRuntimeAssemblyTests` 97 executed、5 expected skip、0 failure（`3b544b1f...6d734`）；原始 logs 位于
  `build/observations/prepare-singleflight/ad75115-capture-remediation-focused-20260821T1701/`，不提交。
- clean `f82699d` 已只打包一次新 staging candidate：`0.1.0 (21)`（此前被终止的 package 已保留 build 20，故单调 allocator
  正确分配 21），candidate input hash=`b55b7a27e3c04366c579e2b7555cefd2813d5febf7186929a25fa15ab57172f3`。
  `codesign --verify --deep --strict` 通过，bundle scan 无 `.py`、`.pyc`、`.pyo`、`__pycache__`；四个 executable SHA-256 分别为
  CLI=`337e863d...27716`、Runtime=`8a0696a0...01572`、Direct=`5d5ea182...a2afa`、CoreDevice=`06da638a...d1643`。
  package JSON/stderr hashes 为 `b5729cc5...ab7ac` / `06d8c64b...1d8a8`，原始结果位于
  `build/observations/prepare-singleflight/f82699d-capture-remediation-package-20260821T1705/`，不提交。下一步是安装这个精确 candidate，
  再由 owner 进行新的 Developer Mode cycle 后的首次 capture 验收。
- build 21 已由 staging 内 CLI self-install 到 `/Users/a/Applications/PulsePhone.app`（`disposition=updated`）；全局
  `PulsePhone version --json` 确认 `0.1.0 (21)`。installed 四个 executable 与 staging 逐字一致、strict codesign 通过且无
  Python artifacts；原始 install results 位于
  `build/observations/prepare-singleflight/a9d7b1f-capture-remediation-install-20260821T1709/`，不提交。
- build 21 的下一次 Developer Mode cycle/reboot/unlock 已完成首次实体验收序列。首次 `screenshot.cli` 正确返回
  `capabilityPreparing`、exit `5`、完整 `remediation=runDevicePrepare` details 且没有 output artifact（response SHA-256=
  `3081adce0bc975fba159d2317adaf8cf2e54e0add77ee70d8b5389275683c691`）。随后显式 `device prepare` 在约 4 秒内
  `succeeded`，结果为 `cacheHit`、`mounted`、`serviceDisposition=ready`。但紧接着由新的 CLI 进程发起的一次手动 screenshot
  retry 又返回完全相同的 `capabilityPreparing` remediation、exit `5` 且没有 artifact；同一时刻的 `runtime status` 仅报告
  target `full`。原始 first/prepare/retry/status 输出位于
  `build/observations/prepare-singleflight/a7fc60c-capture-remediation-device-20260821T1713/`，不提交。
- 这证伪了“显式 `device prepare` 成功后，后续独立 CLI command 可立即使用已准备 Developer Support”的产品合同，验收保持
  `investigating`。根因已由新 generation regression 固定为 `ProductionRuntimeDeviceCoordinator` 只在 Runtime 内存保存 ready group；
  前一 CLI 的 Runtime generation 退出后，下一代从空 projection 开始，且不会由真实 mounted image 与 CoreDevice warm service
  重建当前 generation readiness。修复后仍须以实体设备验证普通 command 不会在真正未准备时执行或重放。
- `65a8d95` 实现了 fail-closed rehydration：成功的 modern `device prepare` 仅写入 host-private eligibility receipt，精确绑定
  UDID hash、product type/version、build 与 preparation group。fresh Runtime 只有 receipt exact match 后才尝试一次
  `queryMounted -> warmGeneration`；两者成功并重新读取当前 snapshot 后，才标记该 generation ready。该 receipt 不保存 ready
  bit；receipt 缺席/失配/损坏、unmounted、warm/transport/protocol failure 都仍进入既有 start-only remediation，既不下载、TSS、
  mount、排队也不重放原命令。Live `startOnly` 和 ordinary command 均接入该规则。
- 精确主机验证已通过，但不替代实体结论：`DeveloperImageAssetStoreTests` 14/14（含 exact/mismatch/corrupt receipt），新增
  Runtime 2/2（fresh Live start-only 与 fresh command rehydration；unmounted 保持 remediation/零 Home），
  `make verify-preparation-capture` 3/3，release `PulsePhoneRuntimeExecutable` build 成功。原始结果在
  `build/observations/prepare-singleflight/rehydration-focused-20260821T1740/`，SHA-256 分别为 asset=
  `04ce8d469d1d7f9472226cf8a7c073e93e1a327143be145d3c35882b9014a95f`、runtime=
  `12764e71ce7c1d428c1b7ebe59670f70d00aeeb358595b4ea6259f82a5ee1266`、capture=
  `e56badb74b3ed687adcf951a6ffd066e4faca9d6ccf860e3eae6181bbbba2835`、release=
  `93351561896123dc1fd00e1a7f0d7abbd1cea6c10dd25853dfe00ec3b26c8e16`（均不提交）。下一步仍是从该 exact source 打包、安装并以
  实体设备验证，未改变 OBS 状态。
- **2026-08-21 build 22 packaged/device closure：**从 clean `f9a2d1e` 构建 staging candidate 并通过 strict codesign；
  `/Users/a/Applications/PulsePhone.app` 已更新，裸 CLI 确认 `0.1.0 (22)`，四个 executable 与 staging byte-identical，bundle
  没有 Python runtime/source/cache。首次重启解锁后的 `screenshot.cli` 按合同返回 `capabilityPreparing`、完整
  `remediation=runDevicePrepare`、exit 5，且 `first.png` 不存在。随后 `device prepare` 返回
  `mountedOnly/alreadyMounted/ready`。为排除进程内 ready，显式 `runtime.stop` 后确认 `runtime.status=notRunning`；下一条由全新
  Runtime 执行的 `screenshot.cli` 成功生成 `fresh-runtime.png`，SHA-256=
  `d5245cfdb84d26389c1f0422d2bbcbbc46477fbdc274e67aebde5326a4ec694c`。ready 状态的 `live` 返回 `opened`。`stop` 的合同仅处理
  idle Runtime，不关闭打开的 Live window；因此验收随后终止了本次启动的 test-owned GUIHost，最后 `runtime.stop` 成功，进程检查确认
  GUIHost PID 89256 与 Runtime PID 93160 均已退出。
  `make build-go` 后，`ProductionRuntimeAssemblyTests` 为 99 executed、5 explicit opt-in skips、0 failures。首次直接运行该
  suite 的 4 unexpected failures 已证实是缺少该既有 Go-helper test prerequisite，补齐后同一 suite 全绿，不作为产品回归。
  原始 device/host evidence 位于
  `build/observations/prepare-singleflight/f9a2d1e-rehydration-device-20260821T1748/`（不提交）：first=
  `994fbabc3f740a7faef0de5c8e0edc90cc58bd12ee6484eb7435e4cb27af0c6f`、prepare=
  `ed61dec919c95f6fd35b24f5ee951ac37c2afedd6d6bc355a6504f71b37481ea`、fresh screenshot=
  `a301caf869be2dfdf81275b71f58d1b0a98f7429be691fb6b0621fdb0614fde2`、Live=
  `f5019547eafe6f30f01fc77cd942a92d4e6bd5ec4845457c058a442219011bd2`、assembly=
  `0da87cc2827e1a469b2ab7c4c43a511989bfe008b9da7fe731dbea56eee38654`、final stop=
  `ba221e05406ce03dc196b5c5a4a37cd7c3f46374809d5d22f556f533d24dade0`、process cleanup=
  `f5a9f9a95be6c364185e105290b3422e9df8356ef9b896114c73f8d241628201`。

  **2026-08-21 repo-wide Gate closure：**clean `5c1743e` 的完整 `make check` 以 exit `0` 完成；主 XCTest 为
  1,028 executed、5 explicit opt-in skips、0 failures，后续 release-contract selection 为 29 executed、0 failures。
  原始输出归档于
  `build/observations/python-to-go/5c1743ec719694d0e6fadae3f2effc6b617c994d/full-make-check-20260821T1817/make-check.log`
  （SHA-256 `9f08ad1a37bc7e7906fceb3b1d86c326f100aa28e4966d702c71c1e015fb3bbb`，不提交）。此前 full
  `make check` 的 repo-wide delivery-Gate 覆盖缺口已关闭；五项 opt-in physical smoke 的 skip 保持其原有的明确语义，
  不作为成功外推。

## OBS-035：`type --text` 第二次调用复用已关闭的 Pasteboard 会话

### 当前状态

- 状态：`resolved`（source 修复、focused regression 和 iOS 26.5.2 连续实体输入验收均已完成）
- 发现日期：2026-08-21
- 严重度：High
- 影响范围：iOS 17+ CoreDevice 的 `text.type` / CLI `PulsePhone type --text`。不涉及 `text.key`、`text.cursor`、`text.clear`、`text.inputSource.next`，也不涉及 CLI tap/swipe/drag 或 Live pointer/keyboard stream。
- 用户可见结果：首次 `PulsePhone type --text ... --json` 可返回 `pasteDispatched`，同一 generation 的第二次调用可能返回 `internalFailure`，不会可靠地输入第二段文本。

### 已确认根因与修复边界

- Python baseline 的 `_TextInputServiceAdapter.set_pasteboard()` 和 `read_pasteboard()` 各自通过独立 `async with pasteboard_service_factory(...)` 开启并关闭服务。TRD 26.4 也明确规定 `SET -> close SET session -> independent PULL session`。
- Go 误将 `com.apple.coredevice.deviceinfo` Pasteboard service 作为 generation-scoped facet 缓存。设备可以在单次请求响应后关闭该 one-shot connection，第二次 `text.type` 因而尝试复用已关闭会话。
- Go 现将 Pasteboard warm channel 与截图一样在 `ensureReady` 后关闭且不缓存；每次 `text.type` 依次创建、使用并关闭独立 SET 和 PULL service。SET 失败仍保留既有 Python-compatible `internalFailure/notCommitted` 公开投影；SET 成功后的 PULL/read-back 失败仍是 committed `backendFailed(stage=pasteboardReadBack)`，没有接受任何未说明的行为差异。

### 当前验证与关闭标准

- 新增 `TestPasteboardSessionsAreIndependentAcrossConsecutiveTextCommands`，模拟设备对每个 one-shot session 在一次响应后关闭，并固定两次文本命令共使用四个独立、已关闭的 SET/PULL sessions；同时更新 broad legacy/modern transcript 与 read-back mismatch coverage。
- 已通过 focused Go tests、`CGO_ENABLED=0 go test ./...`、`CGO_ENABLED=0 go test -race ./internal/coredevice`、`CGO_ENABLED=0 go vet ./...` 和 HelperWire public-error projection tests；原始 build/test output 不提交。
- 关闭前必须以包含此修复的 installed candidate 在一个已明确聚焦的无害文本框中连续运行两次 `PulsePhone type --text ... --json`：两次均为 `pasteDispatched`、可见文本完整、无新的 paste permission prompt。可选复核一次 `text key`，但它不是本问题的修复范围。

### 2026-08-21 实体关闭记录

- `f2071f0` 的最小本地测试安装只替换并重新签名了 `PulsePhoneCoreDeviceHelper`，未修改受控 staging candidate，且不作为发布产物。全局 launcher 确认指向 `/Users/a/Applications/PulsePhone.app/Contents/MacOS/PulsePhone`；bundle `codesign --verify --deep --strict` 通过，安装 helper 与测试 helper SHA-256 均为 `4629a256f10edf6d2430be3842132528b435de98acc1e345db5ef3b643df61d9`。
- owner 在 iOS 26.5.2 / `23F84`、UDID `00008110-001A7D523E90401E` 的已聚焦无害文本框中完成 `device prepare` 后连续执行两次 `PulsePhone type --text ... --json`，并确认两次均通过、可见文本完整且没有粘贴权限弹窗。该结论关闭本条的实体范围；原始命令结果未提交。
- 随后从 clean `e42011806b13309a9ae422a5f9c8fcb3233cc4e6` 组装正式 staging candidate `0.1.0 (26)`，candidate input 为 `build/evidence/objects/2b3e653065dfbb96d03356ca3db39fc21dd2c7d3547b55d20714dd41738ecd3a/release-candidate-input.v1.json`，`appBundleContentHash=a256f178c4fd6d171f5b7ad470c869b25ba71a1296cdf7fe776f152f85b42a36`。staging 经 self-install 更新到 `/Users/a/Applications/PulsePhone.app`；两边 `version` 均为 build 26、CLI/CoreDevice helper 逐字一致、deep/strict codesign 均通过、Python artifact 扫描为零。staging helper SHA-256=`e1bbcca77e36331b3df46c0fc811625473f63bc59a0af7662eb4716af55bd745`；它与已验收测试 helper 的 Go build ID 相同，去除签名且归一化唯一 16-byte `LC_UUID` 后逐字一致，故不会把 package-app 的确定性 UUID/signature 重写误判为未验收的逻辑差异。

## OBS-036：高位 ECID 被 Lockdown 整数解析拒绝

### 当前状态

- 状态：`investigating`
- 发现日期：2026-08-25
- 严重度：High
- 影响范围：iOS 17+ personalized Developer Support 的已挂载镜像查询和 `PulsePhone device prepare`。

### 已确认根因与修复边界

- 在 iPhone virtual device `0000FE01-8CBDBFB959DA98F8` 上，Lockdown 的 `UniqueChipID` 解码为
  `int64(-8305271335003973384)`。其无符号 64 位位模式为
  `10141472738705578232`，与 Xcode `devicectl` 的 ECID 一致。
- 该值是高位 ECID 的有符号 plist 载体，不是负 ECID。`manifestUint` 正确地拒绝负数，
  但不适合解析语义固定为无符号标识符的 `UniqueChipID`。
- 修复只在 `OpenCoreDevicePersonalizedMounter` 读取 `UniqueChipID` 时采用专用无符号解析，
  不放宽 catalog、size、epoch、chip 或 board 等通用字段的整数验证。

### 当前验证与关闭标准

- 高位、正常和无效 ECID 的 Go 回归测试已经通过。
- 2026-08-25 使用此修复从源码编译 CoreDevice helper，在上述设备执行完整 helper wire 链路：
  `queryMounted` 返回 `mounted=true`，`warmGeneration` 随后成功打开全部七项 CoreDevice 服务。
- 新 packaged candidate 的 `PulsePhone device prepare --udid 0000FE01-8CBDBFB959DA98F8 --json`
  不得再因 `personalization ECID` 失败；若有后续失败，必须报告其新的 typed root cause。
