# PulsePhone PRD

> 文档状态：Design Freeze 后正式重写版
>
> 基线日期：2026-07-18
>
> Command Matrix：`command-matrix.v17-20260822`
>
> 默认交付规范：`default-product-delivery.v1-20260722`

## 1. 文档定位

本文档定义 PulsePhone 第一阶段的产品范围、用户入口、交互行为、兼容性口径、结果语义和验收要求。

本文档不记录方案讨论过程，也不保留已经废弃的候选方案。技术实现、进程模型、调度、Wire、Helper、文件布局和安全约束由 `pulsephone-trd.md` 定义。

当前规范优先级如下：

```text
本 PRD                     产品需求和发布合同
+ pulsephone-trd.md         工程与验证合同
  -> CommandCatalog / registries / schemas
  -> 实现、CLI help、GUI presentation、tests 和 release manifest
```

PRD 与 TRD 是完整规范，不依赖临时讨论记录补充语义。若实现发现未定义边界，必须先同步 PRD/TRD、适用 revision 和测试，再实施。

当前状态必须明确区分：

```text
targetCompatibility  目标兼容范围，尚不代表已经验证或发布。
actuallyVerified     已在明确设备、系统和环境中取得验证证据。
releasedCapability   已通过当前发布阶段门槛、允许对外声明的精确能力。
```

第一阶段所有能力当前均处于设计冻结后的 `R0` 状态：产品合同已冻结，但实现、完整验证和对外发布声明仍需在后续阶段形成。

### 1.1 交付配置与优先级

PulsePhone 默认采用 `Default Product Delivery` 配置。它的目标是先形成一个可以实际使用的 `PulsePhone.app`，并在项目 owner 当时能够提供的 USB iPhone 上完成端到端验证。验证结论只覆盖实际记录的设备型号、OS version/build 和能力；没有设备或环境的项目记为 `notTested`，不等于失败，也不阻断默认交付。

原 Alpha、Beta、Formal 的长时运行、重复实体拔插、完整设备/OS 矩阵、clean Mac、TCC 重置、签名公证、EvidenceStore、retention、hold 和冻结性能阈值属于显式选择的 `Optional High-Assurance Validation` 配置。只有 release owner 明确激活该配置时，它们才成为当前交付 Gate；完整保留要求见 [`OPTIONAL_HIGH_ASSURANCE_VALIDATION.md`](OPTIONAL_HIGH_ASSURANCE_VALIDATION.md)。

无论选择哪个配置，下列安全边界始终是 product gate：不能显示 A 而控制 B，不能把命令路由到错误 UDID，不能接受 stale connection/source/geometry epoch，不能把组件或模型测试描述成已工作的生产 UI，也不能把未测试设备声明为已验证。

## 2. 产品概述

PulsePhone 是一个独立的 macOS iPhone 预览与控制工具，提供两种主要使用形态：

```text
GUI live
  实时展示目标 iPhone 的画面和音频。
  使用鼠标、键盘和工具栏操作设备。

CLI
  以稳定、可脚本化的命令执行手势、按键、截图、当前画面元素快照、App 管理、状态和诊断操作。
```

产品整体关系：

```text
                         +-------------------+
                         |   PulsePhone.app  |
                         +---------+---------+
                                   |
                    +--------------+--------------+
                    |                             |
                    v                             v
             +-------------+               +-------------+
             |  GUI live   |               |     CLI     |
             +------+------+               +------+------+
                    |                             |
                    +--------------+--------------+
                                   |
                                   v
                         +-------------------+
                         | per-UDID Runtime  |
                         +---------+---------+
                                   |
                                   v
                              USB iPhone

未来：MCP / Phone Use / pulse 集成复用 PulsePhone 高层能力，
但不进入第一阶段交付范围。
```

## 3. 产品目标

第一阶段目标：

- 形成可独立运行和搬移、在可提供设备上完成端到端操作的 macOS app bundle；签名与公证在需要外部分发时完成。
- 在未安装 Xcode 的 clean Mac 上按需获取、缓存并准备受控 Developer Support。
- 提供完整的 GUI live 和 CLI 使用闭环。
- 在 iPhone 上不安装额外 App、WebDriver 或 XCTest Runner，返回当前 viewport 的被动视觉 element snapshot。
- 让 GUI、CLI 和未来入口共享同一套命令定义、兼容规则和设备执行秩序。
- 对同一设备的多个 Client 提供确定的资源冲突、排队、取消和结果语义。
- 对不同设备提供独立 Runtime 和故障隔离。
- 将 CoreDevice、usbmux、Lockdown、DDI 和 Helper 细节封装在产品接口之下。
- 形成 ActionLog、ReplayTrace、DiagnosticLog 和性能证据基础。
- 为后续 Go 版自有协议实现、MCP、Phone Use 和 pulse 集成保留稳定边界。

## 4. 非目标

第一阶段不交付：

- 不改造现有 pulse。
- 不接入 MCP 或 Phone Use。
- 不实现 Codex/Cursor 内嵌画面。
- 不实现录屏、视频录制回放或语义级 UI 自动化。
- 不把视觉候选声明为 XCTest/XCUIElement、真实 Accessibility hierarchy 或稳定平台 element token。
- 不提供会为发现元素而滚动页面、移动 Accessibility focus、发送 HID 或显示检查高亮层的 element 路径。
- 第一阶段不提供 `element find/get/click`，也不推测 identifier、enabled、selected 或 hittable。
- 不支持 Wi-Fi lockdown、无线控制或无线视频。
- 不支持 iPad、iPod touch 或其他 device class。
- 不承诺 Intel Mac、Universal binary 或 macOS 13 以下。
- 不承诺未形成精确真机证据的宽泛 iOS 版本能力。
- 不提供图形化设备选择页或 `live --debug-device-picker`。
- 不提供公开 daemon 命令、`--force` stop 或公开 job 恢复接口。
- 不提供 `.app` bundle 安装，只支持 `.ipa`。
- 不提供 GUI Launch、GUI Uninstall。
- 不提供公开 `keyboard enable/disable`、Hardware Keyboard toggle 或 Clipboard Sync。
- 不提供 Software Keyboard show/hide、可见状态查询或 checked state API；只提供无状态 Toggle 动作。
- 不提供 `orientation get/set`。
- 不在第一阶段一次性重写完整 CoreDevice 协议栈。

## 5. 用户与场景

### 5.1 GUI 用户

GUI 用户通过 CLI launcher 打开 live 窗口：

```sh
PulsePhone.app/Contents/MacOS/PulsePhone live [--udid <UDID>]
```

典型场景：

- 查看目标 iPhone 的实时画面和音频。
- 在 iOS 17+ 目标上使用鼠标执行点击、拖动和系统边缘手势。
- 通过工具栏执行 Home、App Switcher、锁屏、音量、旋转、截图、软件键盘切换和 IPA 安装。
- 显式开启 Keyboard Capture，将 Mac 物理键盘完整转发给 iPhone。
- 在 Camera 权限不可用或视频源未绑定时继续盲控正确目标设备。
- 观察来自 GUI 或其他 CLI Client 的已接受触点轨迹。

### 5.2 CLI 用户

CLI 用户通过独立调用完成设备操作：

```sh
PulsePhone.app/Contents/MacOS/PulsePhone tap --x 0.5 --y 0.8
PulsePhone.app/Contents/MacOS/PulsePhone device prepare --udid <UDID>
PulsePhone.app/Contents/MacOS/PulsePhone screenshot --output out.png
PulsePhone.app/Contents/MacOS/PulsePhone element snapshot
PulsePhone.app/Contents/MacOS/PulsePhone install --path app.ipa
```

典型场景：

- 脚本化执行确定的设备命令。
- 调试单个设备能力和错误边界。
- 在多个终端中操作同一设备，并由 Runtime 统一调度。
- 查询当前 USB 设备、设备状态和 Runtime 状态。
- 获取同一时刻当前 viewport 的视觉控件、文字、坐标和可直接用于现有 tap 的 normalized center。
- 显式准备设备、观察 Developer Support 下载和服务启动进度。
- 获取 ActionLog、ReplayTrace、DiagnosticLog 和性能验证材料。

## 6. 平台与支持边界

### 6.1 macOS

第一阶段目标平台：

```text
macOS 14+
Apple Silicon arm64
App Sandbox = off
默认产品交付可使用本地开发签名或等价可运行构建
外部分发要求 Developer ID 签名 + Hardened Runtime + notarization
```

PulsePhone.app 可以位于 `/Applications`、用户目录或包含空格的目录。公开 CLI 是当前 app bundle 内的主 executable；PATH symlink 只是可选便利能力。

普通文件操作只保证在所有 PulsePhone 进程停止后移动或替换 app。唯一受支持的运行中替换入口是
`PulsePhone self install`：它先完成源与staging验证，再终止经过身份复核的当前用户PulsePhone进程，并以可回滚事务发布用户级安装。

完整`PulsePhone.app`内嵌名称为`pulsephone`的portable Agent skill和Codex平台元数据。
`skill install`先复用`self install`的验证、用户级发布与launcher协调能力，随后把薄skill原子安装到Codex、Claude Code或显式绝对skill root；完整app始终只保留一份用户级安装，不复制到各Agent skill目录。安装后的skill只调用全局`PulsePhone ...`命令，不承担app bootstrap。

### 6.2 连接方式

第一阶段只支持 USB 连接。

非 USB 设备不得进入默认目标集合，也不得因其他链路可发现而被静默选择。

### 6.3 设备类型

第一阶段支持列表固定为：

```text
supportedDeviceClasses = [iPhone]
```

`devices` 可以列出发现的其他 USB iOS/iPadOS 设备，但必须标记 `supported=false`。默认选择只考虑 iPhone。

### 6.4 iOS 17+

iOS 17+ 是完整功能的目标兼容范围，包括：

- GUI 视频和音频预览。
- GUI pointer interaction。
- GUI Keyboard Capture。
- CLI tap、drag、swipe。
- Home、App Switcher、Lock、Volume Up、Volume Down、Device Mute。
- Rotate。
- Unicode `type --text`，以及有界的 Text HID 按键、光标、清空和输入法循环命令。
- Screenshot。
- Install、Uninstall、Launch。

当前证据只覆盖已经记录的精确设备与 OS build，且部分能力仍只是原型或组件级验证。`iOS 17+`是目标能力上限，不是默认交付时可以直接声明的宽泛支持范围。默认交付只声明本次实际通过的 exact device/build/capability 集合；未提供的 lower/intermediate/upper build 统一记为 `notTested`。若 owner 需要发布 bounded range，再显式启用高保障配置并执行其三槽 coverage、release flow 与 narrowing 规则。

### 6.5 iOS 14～16

iOS 14.0～16.7.x 是 legacy direct-subset 的目标兼容范围，不是已经发布的整体支持承诺。

历史目标兼容性参考如下，不构成默认交付必须提供的设备：

```text
iPhone 11 Pro / iOS 14.2.1
iPhone 12 / iOS 16.3.1
```

能力边界：

| 能力 | iOS 14～16 目标口径 |
| --- | --- |
| GUI video/audio preview | 目标能力，仍需完整绑定与权限验证 |
| devices / device info / status | 目标能力 |
| install / uninstall | 逐项验证后形成声明 |
| screenshot | 条件能力，需要匹配且来源合规的 DDI |
| launch | 条件能力，需要匹配且来源合规的 DDI |
| pointer / keyboard / HID button / rotate / type | 不支持 |

第一阶段发布包不包含 DDI。PulsePhone 可以读取受控 Application Support cache、通过 `xcode-select` 选中的正式公开 Xcode，或 immutable catalog 中的 approved remote source；Xcode 是可选 local optimization，不是运行前提。

Developer Support 不可用时必须返回精确 typed error，不得修改 Xcode、按最近版本猜测兼容、跨版本复用或改走未声明路径。非精确版本只有形成对应真机证据并进入冻结兼容映射后才能发布。

### 6.6 支持声明边界

`targetCompatibility` 只表示设计目标。每次实际测试的精确设备与 OS build 必须分别记录；catalog entry、DDI 可下载或 service advertisement 都不能代替真机 command evidence，也不能自动扩大 `releasedCapability`。未提供的目标设备保留为 `notTested`。

## 7. 产品入口与目标选择

### 7.1 命令类别

CLI 命令分为三类：

```text
global
  commands
  devices
  runtime status
  logs prune
  logs clear --all

device
  live、device info、status、device prepare、普通控制命令、截图、element snapshot、trace start、diagnostics start

runtime/log diagnostic
  runtime status --udid、stop、trace stop、diagnostics stop、logs clear
```

### 7.2 canonical UDID

公开 UDID 使用统一 canonical form：

```text
1. trim 首尾 ASCII whitespace
2. ASCII a-z 转为 A-Z
3. 保留原有 hyphen 位置
4. 非空、最多 128 bytes、只允许 ASCII 字母/数字/hyphen
```

`devices` 只显示 canonical UDID。非法输入返回 `invalidUDID`；多个物理设备折叠成同一 canonical UDID 时返回 `duplicateCanonicalUDID` 并 fail closed。

### 7.3 默认目标

省略 `--udid` 时，从以下集合按 canonical UDID ASCII byte order 选择第一台：

```text
当前 USB 连接
+ canonical identity 唯一
+ DeviceClass = iPhone
```

选择顺序不读取当前命令的系统版本、trust、lock 或 capability。先选中第一台，再校验命令兼容性；第一台不兼容时不得静默改投第二台。

```text
eligible iPhone list: [A, B, C]
                         |
                         v
                     choose A
                         |
                 command compatibility
                    /             \
                 pass             fail
                  |                |
              execute A       return A error
                               never switch to B
```

### 7.4 断连后的诊断目标

显式 `runtime status --udid`、`stop --udid`、`trace stop --udid`、`diagnostics stop --udid` 和 `logs clear --udid` 可以定位已经断连设备的 Runtime 或日志。

省略 UDID 时仍使用当前 USB 默认目标，不反查 active trace、active diagnostics、历史默认设备或 orphan Runtime。

## 8. 公开 CLI

### 8.1 Help、静态与设备查询

```sh
PulsePhone --help
PulsePhone help
PulsePhone <command> --help
PulsePhone commands
PulsePhone version
PulsePhone self install
PulsePhone skill install [--agent <codex|claude-code|all>]... [--skill-root <ABSOLUTE_ROOT>]... [--force]
PulsePhone skill status [--agent <codex|claude-code|all>]... [--skill-root <ABSOLUTE_ROOT>]...
PulsePhone skill uninstall [--agent <codex|claude-code|all>]... [--skill-root <ABSOLUTE_ROOT>]... [--force]
PulsePhone devices
PulsePhone device info [--udid <UDID>]
PulsePhone status [--udid <UDID>]
PulsePhone runtime status [--udid <UDID>]
```

语义：

- 顶层Help显示全部公开CLI Product Action的稳定命令表、简短功能摘要和结构化兼容摘要；单命令Help显示usage、参数约束、兼容范围和示例。
- Help是本地静态presentation，不是Product Action，不使用JSON envelope；需要machine-readable descriptor时使用`commands --json`。
- Help和`commands`从同一份本地Command Catalog/CLI argument definition投影。新增公开命令时不得再维护Help专用命令表；Supporting Action和内部Wire operation不得进入公开Help。
- Help始终展示完整声明能力，不按当前连接设备、iOS版本、trust/lock、Developer Support、Runtime或实时availability过滤。
- Help不得枚举设备、访问usbmuxd/CoreDevice、连接Runtime或GUIHost socket、启动Runtime/GUIHost、读取实时availability或请求任何TCC授权。
- `commands`返回版本化的完整公开CLI Product Action descriptor和Catalog metadata，不启动Runtime；既有仅返回command ID集合的v1结果保持immutable，完整descriptor使用新结果版本。
- `version`只返回当前app bundle声明的版本与build，不探测设备或Runtime。
- `self install`把当前app copy安装或升级到`~/Applications/PulsePhone.app`，并把`~/.local/bin/PulsePhone`协调为指向已安装主executable的absolute symlink；两个`~`都来自effective UID对应的可信login home，不读取`HOME`。
- `self install`不使用`sudo`，不写`/Applications`、`/usr/local/bin`或shell profile，不显示GUI、不自动重启Runtime/GUI；调用本身即表示用户同意在确需复制时终止当前用户的活跃PulsePhone会话。
- `skill install`的调用本身表示用户授权其在必要时执行与`self install`相同的用户级App安装或升级并终止经身份复核的活跃PulsePhone进程；Agent不得把用户要求设备操作或加载skill视为该授权，代用户调用前必须取得明确确认。
- `skill install`至少需要一个`--agent`或`--skill-root`。`--agent codex`安装到可信login home下的`.codex/skills/pulsephone`并包含`agents/openai.yaml`；`--agent claude-code`安装到`.claude/skills/pulsephone`且只包含portable payload；`--agent all`等价于两个内置目标。重复目标去重。
- `--skill-root`可重复且必须是绝对规范目录；每个root下固定创建`pulsephone/`，当前portable payload只有`SKILL.md`，不写平台专属元数据或完整app。未来portable payload可以增加被`SKILL.md`直接引用的`scripts/`、`references/`或`assets/`，但仍不得携带app。
- skill发布是目标集合级原子事务。缺失目标为`installed`，由PulsePhone安装且未修改的旧payload为`updated`，exact current bytes为`unchanged`；非PulsePhone文件、已被修改的managed文件、symlink、foreign owner或unsupported node默认以冲突/unsafe path失败且不改变任何skill目标。只有显式`--force`可以替换目标内由本命令管理的文件路径，不删除其他文件。
- `skill status`无目标参数时查询Codex和Claude Code两个内置目标；显式参数时只查询所选目标。它不安装app、不写文件。`skill uninstall`至少需要一个目标，只删除该目标内PulsePhone管理的payload路径；默认拒绝删除已修改内容，`--force`仍不删除未知文件、非空父目录、用户app或全局launcher。
- skill命令返回每个目标的kind、root、最终skill path、disposition和payload文件；`skill install`还返回本次共享App安装结果。安装后的`SKILL.md`先验证`PulsePhone version --json`，缺失或无效时停止并提示重新从完整app运行`skill install`，不得自行猜测安装路径或调用bundle相对executable。
- 目标App缺失、版本/build不同或目标bundle/签名无效时，结果分别为`installed`、`updated`或`repaired`；目标有效且版本/build相同时为`alreadyCurrent`，不复制App也不终止进程，但仍修复launcher。
- 复制前在原位验证源App；同文件系统staging复制完成并再次验证后，才以有界`SIGTERM`和身份复核后的`SIGKILL`终止除installer自身外的相关进程。发布与launcher更新必须保留rollback，直到从`/`分别通过installed executable和launcher执行`--help`及`version --json`。
- 已正确的launcher保持不变；错误symlink、普通文件或旧launcher脚本可事务替换；launcher路径为目录时拒绝且绝不递归删除。成功结果包含disposition、launcher是否变化、终止进程数、安装/launcher路径和版本/build。
- `devices` 枚举当前 USB 设备；空列表仍为成功。
- `device info` 返回稳定 DeviceFacts，不返回 Runtime 状态。
- `status` 返回 concise identity 和可观察 DeviceCondition，不返回 queue、live、stream 或 Helper 状态。
- `runtime status` 不冷启动 Runtime；无 UDID 时返回可发现 Runtime 列表，显式 UDID 时还能报告 `notRunning`、`generationBusy` 或 preparation projection。

Help兼容文案来自结构化compatibility和preparation/candidate事实：

- 只有minimum时显示`iOS N+`；同时存在maximum exclusive时显示对应半开范围。
- 无设备local命令明确显示`No device required`。
- transport内部标识统一投影为产品术语，例如`usb`/`rsd`组合显示为`USB iPhone`，不得直接泄漏内部服务名。
- `app.launch`等分段支持命令必须显示每个受控support variant，例如`iOS 17+`的CoreDevice路径和`iOS 14～16`的条件Developer Support路径；不得把顶层minimum误写成所有版本无条件可用。
- 改变minimum、maximum、transport或support variant后，Help必须随同一结构化事实自动变化，不需要修改renderer中的commandID特判。

内部`PulsePhoneRuntime --help`只显示内部启动用途和`--canonical-udid <UDID>`等启动参数。它必须在没有readiness FD、canonical UDID、已运行Runtime或已连接设备时仍输出usage并以0退出；打印Help不等同于启动Runtime服务。

### 8.2 设备准备

```sh
PulsePhone device prepare [--udid <UDID>]
```

`device prepare` 面向 CI、排障和提前准备。用户不需要理解 DDI、TSS、RSD 或 tunnel：

- 使用与其他 device command 相同的目标选择，不因默认设备不可准备而改投另一台。
- 目标必须是当前 USB connected 的受支持 iPhone。
- 成功表示Runtime根据当前设备事实和OS profile派生的Developer Support group已准备、必要image已mounted、当前连接代service已ready。
- 已 ready 时幂等成功；多个调用观察同一准备过程，不重复下载或 mount。
- 不提供 DDI version、source、group 或 download-only 参数。
- human 模式在 stderr 实时显示 checking、downloading、validating、preparing device、starting services 和 ready 等稳定阶段；`--json` 保持一个最终 envelope，不混入中间进度。
- Runtime 以 `(connection epoch, preparation group)` 持有唯一 preparation job。多个显式 `device prepare` 只观察同一 job，并复用其最新 progress 与同一 terminal；不得重复下载、TSS、mount 或 probe。
- `device prepare` 是不可由用户取消的状态查询/准备控制。CLI 忽略 SIGINT，不设置 observer deadline，且 client EOF 不取消 Runtime job；只有 Runtime 内部成功、typed failure、绝对 deadline 或设备断连会结束该 job。进程被 `SIGKILL` 或连接丢失时不能保证本地观察继续，但 job 仍按其内部生命周期推进。

### 8.3 Live

```sh
PulsePhone live [--udid <UDID>] [--select-source]
```

`live` 是短生命周期 launcher。CLI 先在 GUIHost 外按统一 target 规则解析 canonical UDID；没有可用 target 时直接返回目标选择错误，不启动 GUIHost Source Chooser 或 target Runtime。对需要 Developer Support 的目标，CLI 随后执行 Runtime preflight：已 ready 才让当前 app copy 的 GUI process 原子 reserve 目标并启动 Source Resolver；未 ready 时 Runtime 启动或加入唯一 preparation job，CLI 返回类型化 remediation，并且**不**创建 GUIHost、Source Chooser 或 Live 窗口。`--select-source` 表示强制打开独立 Source Chooser 纠正映射，不是简单忽略缓存。

```text
CLI launcher              GUIHost                   Runtime
    | live(UDID, policy)      |                         |
    |----------------------->| reserve + resolve source|
    |<-----------------------| disposition / failed    |
    | print result + exit    |                         |
    X                        |                         |
                             | mapping handoff         |
                             | create Live + attach -->|
                             |<------------------------|
```

成功 disposition 固定为：

```text
opened
  新 target reservation 已建立并启动 Resolver；最终可能自动进入 Live，也可能保留 Chooser。

alreadyOpen
  未指定 --select-source，已有同 target Live/Chooser 被聚焦，没有创建第二个 owner。

sourceSelectionOpened
  --select-source 已打开或聚焦该 target 的关联 Chooser。
```

这些结果都不表示 Runtime、Camera、video、audio 或交互能力已经 ready。首次 Resolver/Chooser 在 source handoff 成功前不得为该 target 启动 Runtime；已有 Live 的 `--select-source` 只打开关联 Chooser并保留现有 Runtime 和画面，直到用户确认新 source。

同一 GUIHost 内，同一 UDID 最多一个 reserved resolver/chooser/live owner。不同 app copy 不保证窗口单例，但 per-UDID Runtime 最终只允许一个 live owner；后到窗口必须显示 `liveOwnerConflict`，并禁用 Runtime-backed 控制。

### 8.4 手势

```sh
PulsePhone tap --x <0..1> --y <0..1> [--udid <UDID>]
PulsePhone drag --from <x>,<y> --to <x>,<y> --duration <ms> [--udid <UDID>]
PulsePhone swipe --from <x>,<y> --to <x>,<y> --duration <ms> [--udid <UDID>]
```

坐标合同：

```text
normalized coordinate: [0, 1]
左上角: (0, 0)
右下角: (1, 1)
duration: 1...30000 ms
```

CLI 坐标参数接受不带符号、空格或指数记法的有限 ASCII 十进制文本。`0`、`1`、`0.<digits>` 和 `1.0...` 等位于范围内的形式均合法；小数尾随零不改变合法性，内部统一规范化为不带尾随零的 canonical decimal（例如 `0.40` -> `0.4`、`1.0` -> `1`）。空分量、符号、指数记法、NaN/Infinity 和范围外数值必须拒绝。

该 normalized coordinate 始终表示用户当前看到的 display orientation，不表示固定 portrait framebuffer，也不直接等于 CoreDevice digitizer wire coordinate。GUI canvas、CLI tap/drag/swipe 和 overlay 共用同一 visual coordinate contract。Runtime 必须使用 current connection 的 exact geometry revision 和 orientation 做唯一一次 visual-to-digitizer projection：

```text
portrait             (x, y) -> (x, y)
landscapeRight       (x, y) -> (y, 1-x)
portraitUpsideDown   (x, y) -> (1-x, 1-y)
landscapeLeft        (x, y) -> (1-y, x)
```

projection 后才按 canonical decimal 规则映射到 `0...65535`。geometry/orientation 缺失、stale、与 presentation 未收敛或在 interaction 中变化时，坐标动作必须 fail closed；public CLI 不能依赖此前 GUI interaction 曾经同步 geometry。普通屏内 touch 使用 generation-scoped Universal HID `mainTouchscreen`；只有 GUI 在 visual edge slop 内明确分类的 system edge gesture 使用 Indigo digitizer，CLI drag/swipe 不从坐标猜测 edge。

GUI 每个自然 pointer gesture 继续拥有独立的逻辑 StreamSession，但稳定 live 会话中的首触关键路径必须复用 current connection epoch 下已经 ready 的 post-capture Helper generation、generation-scoped HID service 和 Runtime 权威 geometry snapshot。只要 snapshot 的 connectionEpoch、geometryRevision、orientation、presentation convergence 和 owner lineage 仍为 current，Runtime 不得为每次 mouseDown 强制同步执行新的设备 display-geometry OneShot 或重新初始化底层 input service。只有 snapshot 缺失、stale、冲突或已有权威事件表明 geometry 变化时，才允许在任何 Helper frame 前刷新或 fail closed。

当 StreamOpen 的一次有界刷新证明 requester 与 Runtime 权威 snapshot 属于同一 connection epoch、logical size 和 orientation，但 requester 的 geometry revision 落后时，Runtime 必须返回该次 Stream 实际接受的完整 geometry。GUI 只能在该 Stream 首帧尚未发送、accepted revision 不旧于 requester，且物理 geometry exact 相同时，把当前 controller 和全部尚未投递的自然手势原子重绑定到 accepted revision；已经投递的 interaction、epoch 变化、物理 geometry 冲突或较旧的 accepted revision 继续 fail closed。不得通过忽略 revision 来放宽逐帧 fence。

本地 optimistic overlay 只表示 GUI 已接收 pointer 事件，不表示 Stream 已打开或设备已接受输入。Stream open、frame、close/cancel 或 geometry admission 失败不得被静默吞掉；GUI 必须有界恢复 interaction/closing 状态并投影可定位的 unavailable reason，使后续手势不会因前一条失败的 Stream 长期失效。

CLI drag/swipe 只表示普通屏内 gesture，不从坐标自动推导 system edge。drag 与 swipe 共享同一线性执行机制，但保留不同 commandID 表达用户意图。

### 8.5 按键与旋转

```sh
PulsePhone button home [--udid <UDID>]
PulsePhone button app-switcher [--udid <UDID>]
PulsePhone button lock [--udid <UDID>]
PulsePhone button volume-up [--udid <UDID>]
PulsePhone button volume-down [--udid <UDID>]
PulsePhone button mute [--udid <UDID>]
PulsePhone rotate --direction left|right [--udid <UDID>]
```

说明：

- `button mute` 是发送给 iPhone 的 Device Mute，与 GUI Preview Audio 的 Mac/Off 状态无关。
- App Switcher 使用同一设备连接内的 double-Home 序列，不使用自动 edge fallback。
- Lock 成功只表示完整 press/release 已发送，不保证设备最终保持锁定。
- `rotate --direction right|left` 每次只表示一次相对 quarter-turn：`right` 为顺时针 90 度，`left` 为逆时针 90 度。不得把参数解释为绝对 `landscapeRight/landscapeLeft` 目标，也不得在一次 Product Action 内循环追加旋转以追逐某个绝对方向。
- `portraitUpsideDown` 是否可达由 iOS、设备形态和前台 App 的 supported orientations 共同决定。iOS 可以接受、跳过或拒绝该方向；PulsePhone 必须以真实 primary display geometry 为坐标和可见方向 authority，不伪造四方向循环。Rotate response 只能作为本次请求已被 CoreDevice 处理的事实，不能单独证明可见 display 已采用该方向。
- CoreDevice rotate response 返回后，PulsePhone 在短、有界窗口内查询 actual display geometry：立即查询一次，未匹配时短延迟后最多再查询两次。若 actual display orientation 与 rotate response 匹配且相对 previous display orientation 发生变化，返回可见旋转 confirmed；否则快速返回当前 actual display orientation、相对 previous 是否变化以及 visible confirmation 状态。坐标输入只能基于 actual display geometry 恢复；未确认可见旋转不得把 response-only orientation 写入 Runtime/GUI 坐标 authority。

### 8.6 文本与键盘编辑

```sh
PulsePhone type --text <UTF-8 text> [--udid <UDID>]
PulsePhone text key --key <KEY> [--control] [--shift] [--option] [--command] [--repeat <1...100>] [--udid <UDID>]
PulsePhone text cursor --move <MOVE> [--count <1...100>] [--select] [--udid <UDID>]
PulsePhone text clear [--udid <UDID>]
PulsePhone text input-source next [--udid <UDID>]
```

要求：

- 保留顶层 `type --text` 作为唯一精确 UTF-8 入口，不增加 `text type` alias。
- 支持完整 UTF-8，最大 64 KiB。
- 整段文本作为一个命令发送，不拆为逐字符 Runtime job。
- 将完整文本写入设备 `general` pasteboard，关闭 SET 会话后通过独立会话精确回读，再由
  PulsePhone 自有 generation-scoped keyboard service 发送 `Command+V`。
- 每个 Helper generation 新建 virtual keyboard service 后，必须等待 1 秒 service readiness，再允许本
  generation 的第一次 pasteboard SET、Text HID 宏或 Keyboard Capture pressed-set；已经 ready 的 service
  直接复用，不重复等待。readiness 等待期间取消或失败不得发送 pasteboard/HID 副作用，后续请求继续等待
  同一个已创建 service，不得创建第二个 service。
- 不读取或写入 Mac pasteboard，不启动 host/device Clipboard Sync。
- 不恢复设备原 pasteboard。
- 每个新 Helper generation 首次创建 virtual keyboard service 时允许 iOS 软件键盘被系统收起；
  命令不为恢复显隐增加 remove/recreate 或 toggle 补偿。
- success disposition 为 `pasteDispatched`：只证明 SET 精确回读、paste 和 release barrier 完成，
  不保证目标 App 最终显示、保留或提交文本。
- `text key` 发送物理 Keyboard page usage。`KEY` 只接受 `a...z`、`0...9`、`return`、`escape`、
  `backspace`、`tab`、`space`、`minus`、`equal`、`left-bracket`、`right-bracket`、`backslash`、
  `semicolon`、`quote`、`grave`、`comma`、`period`、`slash`、`caps-lock`、`delete-forward`、`home`、
  `end`、`page-up`、`page-down`、`left`、`right`、`up`、`down`。modifier 使用左侧
  Control/Shift/Option/Command usage；`repeat` 默认 1，最大 100，每次重复都完整 release。
- `text cursor` 的 `MOVE` 只接受 `left/right/up/down/word-left/word-right/line-start/line-end/
  document-start/document-end`。character 使用 Arrow，word 使用 Option+Arrow，line boundary 使用
  Command+Left/Right，document boundary 使用 Command+Up/Down；`--select` 增加 Shift，`count` 默认 1，
  最大 100。
- `text clear` 只派发一次 `Command+A`，完整释放后再派发一次 Backspace 并 release-all；它是不可自动
  重试的破坏性编辑宏。
- `text input-source next` 只派发一次 `Control+Space` 循环请求；不使用 `Command+Space` fallback，
  不提供指定或查询当前输入法的参数。
- 四条 Text HID 命令要求调用方先建立正确设备输入焦点。成功 disposition 分别为
  `keyDispatched`、`cursorMoveDispatched`、`clearDispatched`、`inputSourceCycleDispatched`，只证明完整
  HID 宏和 release barrier 已完成，不证明目标 App 的最终字符、光标、选区、文本或输入法状态。
- Text HID 命令与 `type --text`、Keyboard Capture 共用当前 Helper generation 自有的 virtual keyboard
  service，并通过 exclusive `input.keyboard` 与 active interaction 串行；冲突时 fail-fast 返回
  `resourceBusy`。首次创建 service 允许系统收起软件键盘，不做显隐补偿。
- ActionLog、ReplayTrace 和 DiagnosticLog 不记录文本原文、hash、HID usage、pressed-set 或逐键 frame；
  Text HID 命令只记录 allowlisted key/move、modifier 布尔值和 bounded repeat/count。

### 8.7 App 管理

```sh
PulsePhone install --path <app.ipa> [--udid <UDID>]
PulsePhone uninstall --bundle-id <bundleID> [--udid <UDID>]
PulsePhone launch --bundle-id <bundleID> [--udid <UDID>]
PulsePhone apps [--udid <UDID>]
```

要求：

- install 只接受 `.ipa`，不自动 launch。
- install/uninstall 使用 classic installation service，iOS 14～16 与 iOS 17+ 共用同一产品语义。
- launch 在 iOS 17+ 使用 CoreDevice AppService；iOS 14～16 仅在 approved Developer Support + DVT 可用时开放。
- CLI 发起时把相对路径解析为绝对标准路径；Runtime 不依赖调用方 cwd。
- IPA 内容采用 execution-time path semantics，不 copy、spool 或 fingerprint。
- install 一旦 accepted，不因 CLI 超时、CLI 退出或 live 窗口关闭自动取消。
- `apps` 是 CLI-only 只读查询，使用 classic installation service，兼容 USB iPhone iOS 14+；不增加 GUI 入口，也不提供类型、bundle、placeholder、size 或 system filter。
- `apps` 返回 installation database 中 `CFBundlePackageType=APPL` 且没有精确小写 `hidden` SpringBoard tag 的 User App 与 System App。它不读取当前 SpringBoard icon layout，因此主屏 page、dock、folder、App Library 或 icon preference 不改变成员资格。
- 每项以 InstallationProxy 返回的非空、全量唯一且不超过 255 UTF-8 bytes 的 opaque bundle identifier 为 identity，包含 `bundleID`、可选 `displayName`、可选 short version 和 `user|system|unknown` application type；不要求 reverse-DNS 形态，名称和版本缺失不使查询失败。
- JSON 与 human 结果都按 bundle ID UTF-8 byte order 稳定排序。human 列固定为 `NAME`、`BUNDLE ID`、`VERSION`、`TYPE`，缺失名称或版本显示 `unknown`。
- 空 App 集合成功。bundle ID 缺失、为空、超过 255 UTF-8 bytes 或重复，以及字段类型错误、Browse 未明确完成或结果超限均 fail closed，不返回 partial result；`truncated` 恒为 `false`。

### 8.8 Screenshot

```sh
PulsePhone screenshot --output <path> [--force] [--udid <UDID>]
```

CLI screenshot 必须使用真实设备截图，不依赖 GUI preview frame。

流程：

```text
Client path preflight
      |
      v
Runtime device screenshot
      |
      v
validated read-only PNG FD
      |
      v
Client temp write + atomic rename
      |
      v
final absolute output path
```

默认不得覆盖已存在目标；`--force` 才允许原子替换。图片最大 64 MiB。Runtime 临时路径不得暴露给用户或写入日志。

### 8.9 Element Snapshot

```sh
PulsePhone element snapshot [--udid <UDID>]
  [--format json|annotated|both]
  [--output <PNG_PATH>]
  [--force]
```

该命令只描述一次已验证的新鲜 current viewport，不滚动、不移动 Accessibility focus、
不发送发现用输入，也不在设备或 Mac 画面上显示检查 overlay。设备无需安装 WDA、App、
WebDriver 或 XCTest Runner。结果是视觉候选，不等同于 XCTest element 或 Accessibility tree。

`--format` 默认 `json`：stdout 直接返回一个标准 JSON terminal envelope，且不生成标注图。
JSON 保留融合后的文字、控件和 unknown 候选；`annotated` 只把最终 `controlCandidate` 边框绘制到
`--output` PNG，成功时 stdout 为空；`both` 原子写入
同一 PNG 并返回 JSON。`annotated` 和 `both` 必须提供 `--output`，已存在目标只有
`--force` 才可替换。JSON 与 PNG 必须来自同一次 capture、同一 snapshot generation 和同一
融合结果，不允许为了绘图再次截图或识别。

每个候选返回 source attribution、可见 label（存在时）、视觉类型、置信度、`frame` 和
`center`。`frame`/`center` 同时提供 screenshot pixel、logical point 和 `[0,1]` normalized
坐标；`center.normalized` 可直接传给现有 tap。没有可靠证据的 identifier、enabled、selected
和 hittable 必须为 `null`，不能从外观猜测。

`capture.provider` 表示实际产出本次源图的 provider。`capture.attempts` 按执行顺序返回有界的
provider 状态与分段耗时；发生 fallback 时 `capture.fallbackReason` 返回被替换 provider 的稳定
错误码和失败阶段，未发生 fallback 时为 `null`。一次成功查询仍只发布一张源图和一个 generation。

三个视觉 analyzer 对同一个不可变画面并行工作，然后执行确定性的融合与局部几何矫正。融合会把
同一目标的文字、控件和 region 证据收敛到同一候选，并抑制横跨多个同级控件的重复 OCR 大框；合法的
容器/子控件和其他 nested control 仍分别保留。几何矫正既保留对可信过大 parent 的局部分解，也允许
在已有候选 seed 和局部像素共同支持时细化其矩形，但不得仅凭尺寸、形状或局部像素把文字/unknown
提升为可操作控件；它不得覆盖更可信的 OmniParser 控件框，证据不足时必须保留原候选。
一个或两个 analyzer 不可用时，只要仍有至少一路成功且画面身份、新鲜度和 geometry 可信，
命令以 degraded success 返回并公开各路状态；三路全部失败或没有可信新鲜画面时命令失败。
合法的空候选集合仍可成功。任何失败都不得自动切换到页面滚动或 focus traversal。

Element snapshot 可能把按各 analyzer 配置派生的截图发送到部署方配置的 OmniParser endpoint；
不会静默改投其他服务。OmniParser HTTP 合同固定为 `POST /parse/` JSON；接口未提供的 confidence、
identifier 或控件状态不得由客户端臆造，版本化 detector-only API 只能作为向后兼容的可选增强。
Vision 与其他主机 analyzer 在本机执行。默认日志、trace 和性能导出不
保存截图、OCR 正文、视觉 caption 或目标 App 内容；标注 PNG 只由上述显式格式产生。

### 8.10 Runtime、日志与诊断

```sh
PulsePhone stop [--udid <UDID>]
PulsePhone trace start [--udid <UDID>]
PulsePhone trace stop [--udid <UDID>]
PulsePhone diagnostics start [--udid <UDID>]
PulsePhone diagnostics stop [--udid <UDID>]
PulsePhone logs prune
PulsePhone logs clear [--udid <UDID> | --all]
```

`stop` 只执行安全停止，不提供 force：

- 有 live、job、stream、trace、capability preparation、control mutation、cleanup 或 fencing blocker 时返回结构化 busy。
- Runtime Ack `stopping` 后，CLI 仍需等待 socket 关闭且 generation lock 释放，才输出成功。
- Runtime 已不存在时返回 already stopped，不冷启动 Runtime。
- orphan Helper generation 可以进行身份校验后的恢复和退场，但不得启动新 Runtime。

ReplayTrace 与 DiagnosticLog：

- 每个 UDID 同时最多一个 active ReplayTrace 和一个 active diagnostics session。
- start 返回稳定绝对路径。
- stop 返回同一路径，不 rename。
- ReplayTrace 是 stop blocker；diagnostics session 本身不是 stop blocker。
- 单文件 hard cap 均为 5 MiB。
- 达到 cap、磁盘满或写失败只结束对应记录，不影响设备命令。

ActionLog 维护：

- `logs prune` 不启动 Runtime，只处理 eligible closed ActionLog。
- `logs clear` 在 Runtime 存在时与 active writer 协调；不得 unlink 后继续写不可见 inode。
- `--all` 是非事务聚合操作，已完成目标不回滚。

### 8.11 JSON 与退出码

所有公开 CLI 命令必须支持 `--json`。

`element snapshot` 是唯一默认机器输出的例外：未指定 `--format` 时等同于
`--format json`，`--json` 在 `json|both` 下是幂等的；`--format annotated --json` 是冲突参数，
必须在截图和分析前失败。其余命令继续使用下述 human/JSON mode。

Human mode：

```text
stdout  最终成功结果或 artifact path
stderr  queued/progress/warning 和最终人类可读错误
```

JSON mode：

- stdout 只输出一个最终 JSON envelope。
- 完全抑制 progress。
- unknown command、参数错误和目标选择失败也使用同一 envelope。
- 第一阶段不公开 `--verbose`；human progress 使用统一限频规则。

最小 envelope：

```text
schemaVersion
ok
commandID | null
commandToken?
target: global | device | unresolved
result?       # ok=true only
error?        # ok=false only
metadata?
```

固定退出码：

| Exit | 含义 |
| ---: | --- |
| 0 | 成功 |
| 1 | 非预期内部错误 |
| 2 | 用法或参数错误 |
| 3 | 目标选择或设备兼容失败 |
| 4 | Runtime、协议、transport 或版本失败 |
| 5 | admission、queue 或资源 busy |
| 6 | 已知命令失败或已知 partial failure |
| 7 | 设备副作用结果未知 |
| 130 | Ctrl-C 中断 |

`jobID` 只允许作为诊断 metadata，不是公开可操作 handle。第一阶段不提供 query、cancel-by-jobID 或断线结果恢复。

## 9. GUI Live

### 9.1 窗口生命周期

首次 `live` 先建立 target reservation 并运行 Source Resolver。有效 cache 或获准的单设备自动 proof 经首帧 Probe 成功时可以不显示 Chooser；其他情况显示独立 Chooser。Resolver/Chooser 只使用本地 target facts 和 GUIHost 内共享 AV catalog，不启动 target Runtime。source handoff 成功后才创建正式 Live、显示目标身份占位并异步 attach Runtime。source handoff 的持久 authority 固定为 target-local mapping cache；正式 Live 只接收 canonical UDID并重新读取cache，不接收Chooser descriptor、mapping record或历史帧作为source启动参数。

```text
reserve target
      |
      v
Source Resolver
      |
      +------> valid cache / qualified auto proof + valid frame
      |
      +------> Source Chooser -> Preview -> confirm
      |
      v
mapping cache committed / current proof accepted
      |
      v
formal Live identity placeholder
      |
      +------> attach Runtime/live owner
      |
      +------> reread cache + bind proved AV source
      |
      v
video + control independently become available
```

首次 Chooser 取消时释放 reservation，不写缓存、不创建正式 Live。已有 Live 的 Change Source/`--select-source` 复用关联 Chooser；取消保留原 mapping、capture、Runtime attachment 和窗口，确认后在原 Live 内切换，不创建第二个正式 Live。

关闭窗口时：

- 停止该窗口的视频和音频。
- cancelAndClean 该窗口拥有的 pointer/keyboard Stream。
- detach live owner。
- 关闭窗口和连接。
- 不取消已经 accepted 的 pending/running OneShot。
- 不自动调用 `stopIfIdle`。

### 9.2 视频与控制解耦

AVFoundation 视频和 Runtime 控制是两条独立链路：

```text
                 +-------------------------+
iPhone ----------| AVFoundation video/audio|------> live canvas
                 +-------------------------+

iPhone <---------| Runtime + Helper control|<------ mouse/keyboard/toolbar
                 +-------------------------+
```

真实视频帧的 source identity 必须同时绑定：

```text
target canonicalUDID
+ Runtime connectionEpoch
+ AV sourceID/sourceEpoch
+ mapping proof lineage
```

视频展示和坐标输入在 source identity 之外分别维护独立 authority：

```text
sample presentation
  presentation width/height + orientation + session-local formatRevision

interaction geometry
  connectionEpoch + geometryRevision + logical width/height + orientation
```

Live 对两条链路维护正交的用户可见状态：视频为 `live / frozen / unavailable`，触控为 `available / preparing / unavailable`。`frozen` 只表示画布保留了同一 target 最近一次 identity-valid 的已显示帧，不代表当前 capture、source proof、Runtime connection、geometry 或设备内容仍然有效。触控 readiness 只由 current Runtime attachment、current interaction geometry 与 stream admission authority 决定，不从视频状态或 Helper PID 推导。因此“画面不可用但触控可用”和“画面可用但触控未准备好”都是合法状态，GUI 必须分别表达，不能合并成单一 loading/busy 状态。

只有 source identity 匹配 current bound session 的 sample 才能显示；错误 source、stale sourceEpoch、stale connectionEpoch 或失效 proof 继续 fail closed。`sourceEpoch` 只在同一 sourceID/current binding 内参与代际 fencing，不得跨不同 sourceID按数值大小判断新旧；`frozen`中的旧 presentation 只用于视觉连续性，current binding token、sourceID/sourceEpoch 与 connection identity 全部匹配后的首个 committed presentation可以替换它，即使新 sourceEpoch 数值更小。同一 current sourceID/sourceEpoch 下合法的 sample presentation dimensions 变化不是 identity mismatch，不得因此停止 enqueue、清空 mapping 或伪造 source reconnect。presentation format 决定真实视频的当前比例；interaction geometry 决定 pointer 坐标。两者尚未收敛时视频继续显示，但坐标输入保持 unavailable，绝不以旧方向继续操作。

GUIHost 必须持有一个进程内懒创建、随 GUIHost 生命周期存在的 AV catalog；Resolver、cache Probe、稳定窗口、thumbnail、人工 Preview 和正式 Live 共用该 catalog 的 current inventory/sourceEpoch lineage，不分别创建短命 catalog，也不需要额外 daemon。Inventory 分为 capture-eligible、qualified phone-screen 和明确非手机来源：Mac 内建摄像头、Continuity Camera、Desk View 等可靠可判定来源直接排除；无法证明的 residual 只进入人工 Chooser，不能自动绑定。

qualified phone-screen 必须同时满足 `.external`、支持 muxed media、manufacturer 为 `Apple Inc.`、active format 与至少一个 available format 的 media type 均为 `kCMMediaType_Muxed` 且 subtype 均为 `kCMMuxedStreamType_EmbeddedDeviceScreenRecording`。任一属性缺失或变化都 fail closed 为 residual。名称、尺寸、方向、source 数量、列表顺序、modelID 和 transport 不能单独建立 proof。

允许的 mapping proof 只有：

```text
operatorConfirmedPreview.v1
  Chooser Preview 收到当前 sourceEpoch 的有效帧
  + 用户明确确认 Use Source

singleConnectedTargetSource.v1
  当前 connected target 恰好一个
  + 完整 1.5 s stability window
  + 每 100 ms snapshot，末尾连续 4 个 qualified sourceID 集合 exact 一致
  + stable qualified source 恰好一个
  + source/target display name Unicode canonical-equivalent exact match
  + 无 connected-target duplicate mapping claim
  + Probe 收到当前 sourceEpoch 的有效首帧
```

Stable gate 只授权自动跳过 Chooser；它不得阻塞 Chooser 出现、候选更新、thumbnail、人工 Preview 或 valid cache exact restore。早期相同 snapshot 不得提前完成 1.5 秒窗口；用户一旦选择、Preview、Refresh 或执行其他明确 Chooser 操作，本次 auto attempt 立即取消。窗口结束时集合为空、变化、样本不足或其他条件不完整时保留 Chooser，不延长等待、不选列表第一项。

Chooser 采用稳定的 macOS 双栏工作区：顶部紧凑展示控制目标的设备名称、iOS 版本和 canonical UDID，左栏为可滚动 source 列表，右栏为按比例居中的大尺寸实时 Preview，底部固定放置 Refresh、状态、取消和“使用此源”。footer 状态或重新分配提示必须在 Refresh 与右侧操作按钮之间压缩并单行尾部截断；文案变长不得自动扩大用户当前窗口宽度、移动右侧操作区或与按钮重叠。候选展示 AV display name、active format、短 opaque sourceID 和串行采集的单帧缩略图。thumbnail 最长边为 240 px，每 source 采用 2 秒 absolute deadline；超时或失败后清理 capture 并继续下一项。已有 Live 打开 Chooser 时默认选择 current active source；否则在候选非空时默认选择确定性排序的第0项并立即 Preview。默认选择不构成确认，也不写 mapping；inventory 更新时保留 exact `sourceID + sourceEpoch` selection，原项消失后才回退新的第0项。

只对当前选中 source 运行持续 Preview；确认动作发生时，必须存在同一owner/sourceEpoch且monotonic age不超过1秒的最近有效帧，仅有`hasFrame`状态或过期帧不能授权确认。target facts、connected-target mapping claims 和 AV source inventory 是相互独立的状态：facts/claims 暂不可用时，候选、thumbnail 和 Preview 继续工作，但确认保持 fail closed；connected-target 集合必须连续两次成功观测到相同 canonical UDID 集合后才能授权 claims，单次热插拔过渡快照不能把其他设备的 source 投影为未绑定。GUIHost 最多执行四轮串行 facts/claims 恢复，恢复后只要 Preview 仍然新鲜就自动开放确认，耗尽后保留准确错误和 Refresh。每个 source 分别显示未绑定、已映射到当前/其他设备以及当前/其他 Live 正在使用的状态；source 已被其他当前连接 target 映射时，必须显示对应设备名称/UDID及重新分配影响，最终确认前不得停止旧 session 或修改任何 record。

PulsePhone 可以把人工或自动 proof 保存为当前 Mac 上可失效的 target-local 映射提示。缓存保存 target 隔离的 opaque sourceID、必要 schema/domain/proof kind，以及从有效Preview/Probe帧得到的可缺省`initialCanvasWidth/initialCanvasHeight`。两项尺寸必须all-or-none、正数并按portrait归一化为`width <= height`，只用于正式Live首个current frame前的窗口比例；缺失或非法时回退默认9:16，真实presentation或current Runtime geometry到达后立即失去authority。缓存不保存 raw `AVCaptureDevice.uniqueID`、sourceEpoch、inventoryRevision、connectionEpoch、geometry revision、当前方向、设备/source名称、列表位置或时间，也不跨 Mac 同步。opaque sourceID 在同一 Mac、同一物理视频源上通常可跨应用重启或设备重连保持稳定，但不是 Apple 永久身份保证。

后续 `live` 启动必须重新读取 current inventory。trusted cached sourceID 在 capture-eligible inventory 中 exact 单命中且没有 connected-target duplicate claim时，立即使用 current sourceEpoch Probe，不等待 Stable gate；收到有效首帧即可完成 source handoff，interaction geometry 和 Runtime connectionEpoch 不是 source 选择前提。Chooser首次确认、自动proof和direct cache启动都只以canonical UDID创建正式Live；正式Live重新读取mapping并走相同binding入口，不存在仅Chooser路径可用的内存source handoff。GUIHost内部允许按cache解析出的sourceID转交同一source的capture lease，但该lease不是mapping authority，缺失时direct启动必须能由相同接口创建新capture。正式 Live 创建后再 attach Runtime，并分别推进视频 binding 和坐标 authority。

source handoff 已经形成有效 proof 后，正式 Live 为 current Runtime attachment 建立新 video binding 时仍必须等待该 binding 自己的 current identity-valid 首帧。Live Probe采用5秒deadline。GUIHost对同一sourceID/sourceEpoch只维护一个底层capture owner；Probe首帧成功后必须把同一lease提升为bound consumer。若没有可转交lease，direct cache启动由相同source-scoped入口创建capture。任何路径都不得通过固定sleep后创建同source第二个session完成Probe到bound转换。

bound capture收到首帧后必须持续维护last-sample liveness。`AVCaptureSession.isRunning == true`但连续2秒没有current identity-valid sample时进入明确`frozen`或`unavailable`，不能继续显示为live；Runtime/control authority保持独立。每个stall generation只允许在stop、清delegate、drain并fence旧lease后执行一次无固定sleep的clean reacquire；仍无帧时保持明确不可用并等待用户Refresh、current inventory revision或系统interruption-ended，不无限重试。该状态机用于安全处理外部transport丢帧，不宣称能够阻止Apple私有screen-capture transport本身断开。

缓存缺失、损坏、version/domain不兼容、source不存在或不唯一、capture无有效帧、duplicate claim、inventory/source epoch变化或任何歧义都必须停止并 fence 当前 attempt，进入 Chooser；不得自动使用 inventory 第一项。只有窗口 target 未改变、旧帧来自该target最近一次identity-valid bound session且失效属于USB detach或同source自动重绑过渡时，正式 Live 才可保留已经显示的最后一帧。foreign/stale identity、用户确认 Change Source、切换target或关闭窗口必须彻底清帧。不同target缓存隔离；显式重新分配由 GUIHost 串行协调，partial failure 或仍有重复 claim 时所有受影响 target 后续都回到 Chooser。

正式 Live 底栏只读显示 current source 摘要与视频状态，并提供语义明确、tooltip 为“更换视频源”的 Change Source 图标入口；不得提供 source picker、Preview 或 Use Source。点击该入口只打开或聚焦关联 Chooser，在最终确认前不得刷新或停止当前视频、Runtime、mapping 和控制。已有 Live 的 Chooser 选中 current active source 时显示“当前 Live 正在使用此视频源”；再次点击“使用此源”只关闭 Chooser、释放其 Preview consumer并聚焦原 Live，不写 mapping、不重新 Probe、不重启 capture/Runtime、不改变 presentation/control 或 `captureActivationID`。无 source 时由 Chooser 显示固定 9:16 identity placeholder、空候选和 Refresh，不以 Mac 摄像头回退。Camera 非 authorized 时 Chooser 不启动 thumbnail/Preview：`notDetermined` 提供授权入口，`denied/restricted` 提供系统 Camera 设置入口；首次 Chooser另提供“继续，不显示画面”，直接进入无 source mapping 的正式 Live 以保留盲控能力。该路径不得伪造 mapping proof，已有 Live 的 Chooser 通过取消保留原会话。

`captureActivationID`属于current attached Live + current Runtime connection epoch，不属于Chooser、mapping或某个`ProductionBoundVideoSession`。同一epoch内首次identity-valid bound sample创建activation；同一Live换源、replacement bound session和presentation/geometry refresh复用该ID并保持Runtime幂等。confirmed reconnect产生new connection epoch或关闭后创建new Live时旧ID失效并生成新ID。capture-ready typed failure不得被折叠为通用`Controls unavailable`；视频状态也不得覆盖实际仍可用的pointer/control projection。

绑定未确认、发生歧义、设备重连、Camera denied 或 source unavailable 时：

- 立即停止并fence旧capture/audio，拒绝旧session callback继续写入。
- 同一target的USB detach/自动重绑过渡按上述规则保留最后一帧；否则清帧并显示包含device name + canonical UDID的身份占位。
- 冻结帧上显示不拦截输入的“画面已断开”浮层；触控未准备好时独立显示“触控正在准备”或明确不可用状态，两项状态可以同时出现。
- 不得显示设备 A 的画面并控制设备 B。
- 非视频控制继续按目标 UDID 独立工作。
- current Runtime geometry/control authority成立时，即使视频仍为frozen/unavailable，坐标输入也可独立恢复；geometry unknown或stream admission尚未成立时只禁用坐标输入，其他命令仍按各自capability工作。

### 9.3 权限降级

权限影响范围必须独立：

```text
Camera             -> video preview
Microphone/audio   -> audio preview
Input Monitoring   -> Keyboard Capture
```

Camera denied/restricted 不得阻止 Runtime、live ownership、keyboard、toolbar、device screenshot 或其他设备控制。GUI 应提供打开系统 Camera 设置的入口，并在 App 回到前台或用户刷新 Source Chooser 时重新读取真实授权状态；首次 Chooser 必须允许不建立 source mapping 直接进入 identity-placeholder Live。

### 9.4 画布与坐标

稳定的 windowed 画布必须由当前 presentation ratio 直接决定，video canvas、display layer 与 interaction view 边界一致，不允许在设备画面两侧或上下留下白色或黑色 letterbox。aspect-fit 只用于系统管理的 fullscreen bounds，或 stable presentation 尚未提交的有界过渡阶段；这些 letterbox 始终不属于设备坐标。

window content必须把video canvas与底部source controls划分为两个不重叠区域；native toolbar和source controls都不属于设备坐标。只有video canvas保持当前设备比例，display layer、interaction view、placeholder与overlay共享同一canvas bounds，不得把包含固定controls的整个content直接约束为设备比例。

比例 authority 固定为：bound video 使用当前已提交的 sample presentation format；同一target进入`frozen`时保留最后一次已提交的presentation ratio，仅作为window/canvas连续性而不保留source或坐标authority；从未有identity-valid sample、必须清帧、Camera denied、source unavailable 或未绑定时，identity placeholder 优先使用 current interaction geometry，其次使用trusted mapping中的portrait-normalized initial canvas ratio，二者都不存在时使用默认 9:16。cache尺寸和capture discovery `activeFormat`都只可作为首帧前的临时 reservation hint，不能覆盖已提交sample presentation，也不能建立target proof、当前方向或坐标authority。

画布状态浮层必须位于video canvas内，与display layer和interaction view共享bounds，但hit-test透明且不进入`visibleImageRect`坐标换算。身份占位与主要视频状态只有一个中央视觉 owner：在黑色占位或任意亮度的冻结帧上使用紧凑深色半透明局部状态面承载浅色图标、progress和文字，Reduce Transparency/Increase Contrast 下使用更不透明的系统中性色；不得依赖固定前景色或逐帧亮度猜测。视频状态与触控状态在该状态面内保持语义独立且不重复显示身份/视频文案；两者都available时隐藏，任一不可用时只显示对应状态。底部触控徽标保持独立且不得与中央状态重叠。浮层不得清除最后一帧、改变windowed比例、阻止current-authority pointer事件或把旧帧提升为screenshot preview。视频恢复必须等current source identity和presentation authority成立后才移除视频状态；触控恢复必须等current Runtime admission authority成立后才移除触控状态。

同一 bound source session 内，合法分辨率变化和横竖屏宽高交换必须持续播放。PulsePhone 以多帧有界确认提交新的 session-local `formatRevision`；单帧异常、旋转中间帧或临时 crop 不得立即改变窗口和坐标。stable presentation orientation 变化时先取消旧 pointer/keyboard coordinate interaction并清除 overlay，再建立递增的 current interaction geometry；新 geometry 与展示方向一致前只禁用坐标输入，非坐标控制和视频保持独立可用。

当前 macOS/iPhone 屏幕采集链路可能在实体 display 已稳定旋转后继续输出旧方向的外层 sample dimensions，并把新方向 framebuffer 作为带黑边的内层画面居中，而不是在同一运行中的 `AVCaptureSession` 内交换宽高。这种持续外层格式失配不是合法的新 presentation ratio，也不能让 stable windowed 画布保留黑边。若 Runtime actual display geometry 已由同一 connection 的权威事件推进，而 identity-valid sample 在 format debounce deadline 后仍保持相反的 portrait/landscape class，PulsePhone 必须对当前已证明的 source 执行一次有界 capture pipeline 重新协商；重新协商不得清除 operator mapping、伪造 source reconnect、分配新的 Runtime/Helper generation或改变本次 Rotate 结果。若当前 session 可在不重建 source proof 的情况下重新配置，应保留 current sourceID/sourceEpoch 与单调 `formatRevision`；整个失配、停止、重配和首个新 stable sample 窗口内 coordinate input 必须 fail closed，非坐标控制继续可用。重配失败时保留明确 unavailable 状态，禁止裁剪设备像素、把带黑边外层尺寸提升为设备比例或要求用户关闭并重开 Live 才恢复。

```text
mouseDown:
  必须位于 visibleImageRect，或位于最多 28 pt edge hit slop。

edge snap:
  距画面边缘 <= 18 pt 时 snap 到精确 0/1，仅在 begin 分类 edge。

drag/up:
  active interaction 离开画面或窗口后 clamp 到最近边缘，不自动 cancel。

normalized:
  视觉左上=(0,0)，右下=(1,1)，使用当前显示方向。
```

visual normalized point 只在 canvas/CLI/overlay 层存在。Runtime 使用 current `connectionEpoch + geometryRevision + logical size + orientation`执行§8.4定义的唯一方向投影；Helper 只接收已经投影到 canonical portrait digitizer space 的 point/edge，不得再次旋转。GUI pointer StreamOpen 必须携带 exact orientation；CLI coordinate action 必须在 admission 前取得同一 current geometry，不能从 capture width/height、设备名称、上一次 GUI 会话或默认 landscape direction 推断。普通 pointer/tap/drag 走 Universal HID `mainTouchscreen`，明确 system edge gesture 才走 Indigo。

geometry revision 改变时必须 cancel 旧 interaction、清除旧 overlay，并使用新 geometry 更新窗口比例和坐标映射。首次geometry使用默认window reservation；用户完成手动缩放后，后续geometry或方向变化保留用户当前canvas长边尺度，只重算另一轴并裁限到current screen visible frame，不无条件跳回默认大小。

GUI coordinate admission必须同时证明current Runtime geometry、current committed sample presentation与current video binding已经收敛。Rotate terminal、capture-ready receipt或StreamOpen accepted geometry只能推进geometry authority，不能单独恢复pointer；任一presentation class不一致、capture重新协商中、video binding revision未采纳或Live model更新失败都必须在`mouseDown`进入逻辑Stream前拒绝并清理旧controller/overlay。不得出现界面显示`Controls awaiting geometry`或明显带黑边失配画面时仍发送实体pointer frame。

用户尚未手动缩放时，首次placeholder、portrait或landscape binding使用compact initial reservation：默认preferred canvas短边为`375 pt`，在Retina `2x`显示环境中约等于`750 backing pixels`；产品与布局authority始终使用AppKit points，不以backing pixels作为跨显示器硬编码尺寸。实现按current presentation ratio从短边计算另一轴，再加入固定source controls与AppKit实际window chrome。该值是preferred target而不是越过minimum width或screen visible frame的硬编码尺寸；当前屏幕放不下时允许保持比例地缩小，实际不可压缩controls要求更大宽度时必须记录minimum-width owner。实现不得仅为保留所有toolbar item或source controls自然宽度而把初始窗口扩大到接近可用屏幕高度；次要toolbar item必须优先进入overflow，source controls必须采用紧凑自适应布局。当前标准主显示环境且布局可行时，portrait canvas/content/frame短边应采用约`375 pt`，不得沿用已被owner取代的`640 pt` preferred长边或`340...360 pt`宽度目标。若当前屏幕和不可压缩controls不存在满足比例的尺寸，必须报告明确window geometry不可用状态，不能以letterbox、裁剪或静默扩大替代。

window reservation 必须纳入 AppKit 实际采用的 titlebar、native toolbar、source controls 和 minimum content width。稳定 windowed 状态下，minimum width、screen visible frame 和用户 resize 边界必须同时约束 canvas 两轴：提高宽度时同步按 current presentation ratio 提高 canvas 高度，降低高度时同步降低宽度，禁止只扩宽 canvas host 后以 letterbox 填充差值。产品最小可用尺度固定为`minimumWindowedCanvasShortEdge=320 pt`，独立于`375 pt` preferred initial target和AppKit技术minimum；portrait以canvas width、landscape以canvas height执行该下限。只有current screen visible frame连`320 pt`短边都无法容纳时才允许按比例降低，并必须记录screen-bound诊断，不能把降低后的尺寸持久化为用户尺度。若 chrome 或 source controls 阻止精确比例，应先使用 toolbar overflow 和自适应 source controls，再把用户 resize 裁限到最近的可行精确比例尺寸；不得以黑边或白边作为 windowed fallback。programmatic resize 后应有界核对实际 content/frame size，并在比例不一致时继续一次有界 reconciliation 或报告明确诊断。

用户在 windowed 状态从任意边或角拖动窗口时，一次 live-resize transaction 必须冻结开始时的 committed presentation ratio、source controls高度和实际window chrome高度，并在首次有效尺寸变化时冻结本次拖动的驱动方式。单边拖动保留用户直接控制的轴并由其派生另一轴；角拖动把候选尺寸投影到同一固定比例约束，整个手势内不得在width-driven与height-driven之间反复切换。窗口 delegate 必须在每次 resize callback 中保持 `canvasWidth / canvasHeight == frozenPresentationRatio`，且用户直接控制的边应单调跟随拖动，不得因程序化修正反弹或形成`setFrame -> resize callback -> setFrame`可见循环。AppKit没有发送`windowWillResize`或只采纳一轴时，`windowDidResize`只可执行保持直接拖动边和transaction driver的幂等修正；next-run-loop与settlement timer仅核对晚到WindowServer漂移。拖动结束只记录最终 visible canvas 长边；不得先允许自由宽高变化，再依赖 display layer aspect-fit 掩盖比例偏差。普通resize期间视频持续播放，不因窗口尺寸变化暂停capture或丢弃同方向有效帧。

live resize期间若设备发生presentation方向变化，capture、source identity校验和format稳定性检测必须继续进行，但与本次冻结比例方向不兼容的sample不得进入display layer；画布保留最后一个兼容帧且不得出现黑边、白边或中途切换窗口比例。稳定的新presentation在transaction内只作为pending结果保存，坐标输入在显示方向、presentation和interaction geometry重新收敛前fail closed。live resize结束后必须一次性采用最新稳定presentation和最终用户尺度；若稳定结果已经形成，不得重新等待完整debounce周期。窗口几何采用后恢复匹配新方向的实时帧；close、换源、detach/rebind和fullscreen transition必须清除或终止旧transaction，不能让旧pending callback改写current窗口。

这里的“窗口按固定比例缩放”定义为拖动任一轴时，另一轴按`windowFrameHeight = canvasWidth / currentPresentationRatio + sourceControlsHeight + actualWindowChromeHeight`同步派生，且video canvas始终完整填充windowed可用画布。由于source controls与window chrome为固定高度，禁止把要求误实现为恒定的原始`NSWindow.frame.width / frame.height`或直接设置包含controls的`contentAspectRatio`；这种实现会与零letterbox和固定controls边界冲突。

fullscreen 使用独立的 `windowed -> enteringFullscreen -> fullscreen -> exitingFullscreen -> windowed` 状态。进入前保存 windowed 用户 canvas 长边和 reservation；fullscreen 期间允许使用对称黑色 letterbox，并允许更新 presentation、layout 和 interaction geometry，但不得用 `setFrame` 改写系统管理的 fullscreen frame，也不得把 fullscreen bounds 记录为用户 windowed 尺度。退出后按当时 current presentation ratio 和进入前的用户尺度恢复无 letterbox 的有界 windowed reservation。placeholder、screen change、用户 resize 和 fullscreen 必须复用同一 reservation 管线。

### 9.5 Pointer interaction

iOS 17+ 支持：

```text
mouseDown    -> begin
mouseDragged -> move
mouseUp      -> end
window/owner/geometry/watchdog loss -> cancel
```

普通触摸与系统边缘手势使用不同底层能力，但 GUI 对用户保持同一自然 pointer 模型。

实时 Stream 不等待资源：open 当刻资源可用且没有更早冲突 waiter 才执行；否则立即返回 `resourceBusy`，不排队、不在资源释放后自动重放。

### 9.6 触点 Overlay

只要 live observation subscription 健康，所有 Client 已 `acceptedForDelivery` 的 pointer gesture 都应显示触点或轨迹，包括：

- 当前 GUI 自身产生的 gesture。
- 其他 CLI Client 产生的 tap/drag/swipe。

Overlay 是 presentation projection，不反压设备执行。连接重置、geometry 改变或 observation gap 时必须清除旧轨迹。

### 9.7 Keyboard Capture

Keyboard Capture 是每个 live 窗口的本地 toggle：

- 新窗口固定默认为关闭。
- 不跨窗口、不跨 app launch 持久化。
- enabled 不等于 active。

```text
active = enabled
      && window is key
      && input view is first responder
      && Event Tap available
      && Runtime keyboard capability ready
```

active 时采用完整 device-first 语义：

- 所有捕获到的 `keyDown/keyUp/flagsChanged` 都不得触发 PulsePhone/macOS 本地命令。
- 可映射事件作为物理 HID 发送给 iPhone。
- 无法映射的普通事件被消费并忽略，不回落给 Mac。
- Command+Space、Control+Space、Command+Tab、Command+Q/W/K 等组合也发送给 iPhone。
- 第一阶段不注册 Keyboard Capture、Quit 或 Close Window 快捷键。

窗口失焦、App deactivate、Event Tap disabled、toggle 关闭或窗口关闭时，必须执行 release-all 并结束当前 keyboard interaction。enabled preference 在窗口失焦后保留，在窗口关闭后丢弃。

中文输入使用 iPhone-side IME；不读取 Mac IME committed text。显式 `type --text`、Text HID 命令与
Keyboard Capture 是三种独立产品能力。

Keyboard Capture、`type --text` 与 Text HID 命令只复用当前 Helper generation 自己创建的同一个 virtual
keyboard service，不枚举或接管其他进程的 service。首次实际输入可创建该 service 并接受软件键盘被
系统收起；新建成功后完成一次 1 秒 service readiness 才能派发本 generation 的首个键盘或文本事件，
ready 后全部入口零额外等待。Capture 关闭只做 release-all 和 interaction 清理，不删除 service，也不
触发 Software Keyboard Toggle。

### 9.8 工具栏

工具栏 shape 在窗口生命周期内只创建一次。Client 使用本地 Catalog 和有界 LocalDeviceFactsProbe 计算兼容性：

- `incompatible` 的 command 从初始 toolbar 移除。
- facts 为 `unknown` 的 command 保留固定位置，但以 disabled/loading 展示。
- Runtime 后续只更新 enabled/disabled/loading 和 reason，不重排、不增删控件。
- queue/lease 瞬时竞争不固化为 toolbar disabled 状态。

第一阶段固定顺序：

| Order | Action | Control |
| ---: | --- | --- |
| 10 | Home | momentary icon button |
| 20 | App Switcher | momentary icon button |
| 30 | Lock | momentary icon button |
| 40 | Volume Up | momentary icon button |
| 50 | Volume Down | momentary icon button |
| 60 | Device Mute | momentary icon button |
| 70 | Rotate Right 90° | momentary icon button；每次单次顺时针 quarter-turn |
| 80 | Screenshot | momentary icon button |
| 90 | Keyboard Capture | checked toggle |
| 100 | Toggle Software Keyboard | momentary icon button |
| 110 | Preview Audio | checked toggle；选中=Mac，未选中=Off |
| 120 | Install IPA | momentary icon button + IPA drop |

第一阶段不显示 Touch 状态 item，也不显示 Hardware Keyboard toggle。

Toggle Software Keyboard 是 iOS 17+ 的独立无状态瞬时动作。每次点击只发送一次 CoreDevice Indigo
Consumer `Eject`（usage page `0x0C`、usage `0xB8`）及 barrier：当前显示则隐藏，当前隐藏则显示。
PulsePhone 不查询、不缓存、不推测可见状态，因此该按钮没有 checked state，成功也不声明键盘已经显示
或隐藏。它不启用、关闭或读取 Keyboard Capture；只有与正在执行的 `type --text`、Text HID 命令或
Keyboard Capture 短期 interaction 争用 `input.keyboard` 时返回 `resourceBusy`，不得交错发送。
Capture 仅 enabled/active 但当前没有未结束 interaction 时，不阻止本动作。

### 9.9 Screenshot

GUI Screenshot 是 hybrid action：

```text
click
  -> create rootActionID
  -> best-effort root.begin to existing Runtime; never cold-start for logging
  -> Save Panel
       +-> cancel: root cancelled，不创建 Runtime child
       +-> selected path
             +-> bound preview frame age <= 1 s
             |     -> local PNG write
             |     -> root terminal; no child
             +-> otherwise
                   -> create childActionID(parentActionID=rootActionID)
                   -> Runtime device screenshot fallback
                   -> child terminal + root terminal
```

preview frame 必须匹配目标 UDID、source/connection epoch 和 geometry revision。preview local write failure 不自动改走设备截图，避免产生第二次意外副作用。

root 与 fallback child 是两个 append-once action。Client 只写 root terminal，Runtime 只写 child terminal；两者不得共用 actionID，也不得由 Client 和 Runtime 对同一 actionID 分别写 terminal。

### 9.10 IPA 安装

文件选择器只采集参数，不创建 Product Action、不启动 Runtime、不写 ActionLog。用户选择合法 `.ipa` 或完成合法 drop 后才创建 `app.install`。

Install App 点击必须打开只允许单个 `.ipa` 普通文件的选择器；该本地参数采集不依赖当前 Live Runtime session。取消选择显示非失败的 `Install cancelled` 状态且不创建 action；选择结果无法通过绝对规范路径、`.ipa` 后缀和普通文件检查时显示 `invalidIPAPath`，不得提交 Runtime。合法选择后若 Live Runtime session 已不可用，则显示 `runtimeNotRunning` 或等价的明确 controls-unavailable 状态，不得静默丢弃提交。

合法选择提交后显示进行中状态。terminal success 显示已安装的 bundle ID；terminal failure 显示标准 error code。GUI 日志只允许记录 actionID、commandID、routeID、阶段、终态和按 `redaction.path.v1` 处理后的参数事实，不得记录 IPA 绝对路径。

GUI 不提供 accepted install 的 Cancel 入口。关闭窗口不取消已 accepted install。

### 9.11 音频

音频预览默认关闭。每个 live 窗口独立维护 Audio Preview 输出状态：工具栏 `Preview Audio` 选中时通过 AVFoundation 播放到当前 macOS output device，未选中时为 Off。

- 新建 live 窗口默认不接受音频预览输出。
- 该状态只影响 Mac 端预览，不发送 Device Mute，也不改变 iPhone 的系统音量或静音状态。
- 音频失败只显示非模态状态，不阻塞视频或控制。
- 多窗口依赖 macOS 正常 system mixing，不实现自定义 mixer。

## 10. 设备准备与 Developer Support

Developer Support 是 PulsePhone 在设备上开放部分 developer service 的产品前提。PulsePhone 封装 DDI、personalization、mount、tunnel 和 service probe；普通用户只看到“设备准备”状态。

### 10.1 触发方式

```text
explicit
  device prepare
  -> observe the Runtime-owned shared preparation job until its Runtime terminal

DDI-dependent command or live launch
  capability not ready
  -> start or join the same Runtime-owned preparation job
  -> immediately return typed remediation: Developer support preparation is in progress. Run PulsePhone device prepare to follow progress.
  -> do not wait and do not automatically resume the original command/window launch
```

Runtime 启动、USB attach、`devices`、`device info`、`status`、install 和 uninstall 不无条件触发 Developer Support 下载或 tunnel。

### 10.2 用户可见状态

```text
checking device
resolving developer support
waiting for shared download
downloading
validating
preparing device
starting device services
ready
```

Progress 不显示 URL、绝对路径、UDID、ECID、nonce、ticket、hash 全文或设备内容。`runtime status --udid` 和已有 live window 可以查看 bounded preparation projection；local `status` 不读取 Runtime。

### 10.3 下载、cache 与 Xcode

- PulsePhone.app 不 bundled DDI。
- PulsePhone 在需要 host asset 的 prepare job 开始时，从 TRD 03 定义的固定 HTTPS owner-controlled remote catalog
  取得并钉住一个已校验 snapshot；该 snapshot 可以随远端维护者发布新 asset/build mapping 扩展支持范围，无需为新增 DDI
  另行发布 PulsePhone。未 mounted/service-ready 且没有任何已校验 catalog snapshot 时，不能从 Xcode 或目录观察自行推断支持范围。
- 远端 catalog 是当前权威，但 Runtime job 在 asset selection、下载、TSS、mount 和 service warm 全程只使用其开始时钉住的
  revision 与 canonical hash。刷新只影响后续 job；有效但较旧的远端响应不得覆盖已接受的新 catalog。运行时不枚举远端目录，
  不使用 GitHub Tree/Contents/Search API，也不把远端 catalog 作为 Runtime handshake identity。
- `/usr/bin/xcode-select -p` 选中的正式公开 Xcode 是可选 local source；没有 Xcode 时产品仍可运行。
- 不读取 beta Xcode、任意用户目录或未注册 mirror，不修改 Xcode，不按最近版本猜测。
- cache、archive staging 和下载实现必须保留完整性、路径安全、磁盘可用空间、锁和正在使用资产保护；当前动态 catalog
  阶段不新增公开数值配额。active/locked entry 不删除。
- 多台设备对同一 content-manifest asset 共享一次 host acquisition，但分别完成设备 mount、个性化和 connection service
  preparation。

### 10.4 Online、offline 与 personalization

```text
already mounted
  -> no download; probe current services

approved cache/Xcode hit selected by the pinned catalog snapshot
  -> no asset download

iOS 14...16 not mounted
  -> exact iOS version classic DDI; only patch-to-minor fallback
  -> classic image upload + mount

iOS 17+ not mounted
  -> exact remote build mapping, then local exact-build candidate observation, then default candidate
  -> reusable device manifest when available
  -> otherwise Apple TSS personalization
  -> upload + mount + tunnel/RSD services
```

已 mounted 或可复用 manifest 时可以离线继续。需要 Apple TSS 但网络不可用时返回
`personalizationServiceUnavailable`；不自动切换未批准服务。iOS 14-16 未找到完整版本或同 major/minor
DDI 时返回 `matchingDDIUnavailable`，不得猜测其他版本；iOS 17+ default candidate 的失败不写负缓存，下一次
显式 `device prepare` 会重新按当时 catalog snapshot 尝试。

### 10.5 并发、取消与断连

- 同一设备、连接代和Runtime派生的preparation group只有一个共享准备过程。
- 同一 asset 跨 Runtime 只有一个下载 owner。
- 未 ready 的 DDI-dependent finite command 或 `live` 启动/加入同一准备，但立即以 `capabilityPreparing` 返回结构化 remediation；非 DDI 且资源不冲突的命令继续执行。
- realtime Stream 在 capability loading 时 fail fast，不排队或重放。
- 显式 `device prepare` 的 SIGINT 被 CLI 忽略；它没有本地 observer timeout。任何 client EOF、进程终止或 observer 断开都不复制、取消或回滚共享下载/准备。
- USB detach终止旧连接代的显式prepare observer、start-only demand和设备侧准备；host download可以继续。
- reconnect永不复用旧Helper/tunnel/service，也不重放旧命令；准备必须由reconnect后的新显式或start-only请求触发。
- Runtime process restart 不等同于物理 USB reconnect：新 Runtime 不得继承旧进程的 ready bit、Helper/tunnel 或 connection epoch。
  iOS 17+ 路径只可读取此前完整 preparation 成功写入的、UDID 哈希化且精确绑定 product/build/group 的非权威 eligibility receipt，
  以决定是否尝试一次有界 `queryMounted + required-service warm`；两者都成功后才恢复当前 Runtime generation 的 ready projection。
  receipt 不是 device readiness 证据，且 rehydration 不下载、TSS、mount、排队或重放原 command；receipt 不匹配、query 未确认
  mounted、warm 失败或超时均不得放行，必须继续现有 start-only preparation/remediation 合同。
- PulsePhone 第一阶段永不自动 unmount，避免破坏其他工具共享的 developer environment。

### 10.6 成功与发布边界

成功要求Runtime-derived target capability group ready，不只是文件存在、下载完成或 MountImage committed。当前
`prep.coredevice.v2` 的成功要求 `warmGeneration` 打开完整 RequiredFacets；已mounted但来源无法映射到approved catalog时可以在
required service probe成功后用于当前连接，但标记`mountedUnknownUnverified`，不能用于remount、cache source或release evidence。

Runtime restart 后的 rehydration 同样只以该次 `queryMounted + required-service warm` 的成功建立 current Runtime
projection；eligibility receipt 只限制何时允许发起该检查，不能单独建立 ready，且不把 host cache、旧 Runtime terminal、旧
Helper generation 或旧 connection epoch 当作 device readiness 证据。

Developer Support source、cache 或 service available 都不等于 command 已验证。发布声明继续使用 exact `actuallyVerified` device/OS/command evidence。

## 11. 功能矩阵

以下表格描述目标能力上限，不等于当前已发布声明。

| 功能 | macOS / iOS 17+ iPhone USB | macOS / iOS 14～16 iPhone USB | Exposure |
| --- | --- | --- | --- |
| devices / commands | 目标 | 目标 | CLI |
| device info / status | 目标 | 目标 | CLI |
| runtime status / stop | 目标 | 目标 | CLI |
| device prepare | 目标 | 目标 | CLI |
| GUI video preview | 目标 | 目标 | GUI |
| GUI audio preview | 目标 | 目标 | GUI |
| GUI pointer | 目标 | 不支持 | GUI |
| CLI tap/drag/swipe | 目标 | 不支持 | CLI |
| Home/App Switcher/Lock/Volume/Mute | 目标 | 不支持 | CLI + GUI |
| Rotate | 目标 | 不支持 | CLI + GUI |
| Keyboard Capture | 目标 | 不支持 | GUI |
| type --text | 目标 | 不支持 | CLI |
| Text key/cursor/clear/input-source | 目标 | 不支持 | CLI |
| Install IPA | 目标 | 目标，逐项验证 | CLI + GUI |
| Uninstall | 目标 | 目标，逐项验证 | CLI |
| Launch | 目标 | 条件目标，approved Developer Support | CLI |
| CLI device screenshot | 目标 | 条件目标，approved Developer Support | CLI |
| Current-viewport element snapshot | 目标 | 条件目标，approved Developer Support | CLI |
| GUI preview screenshot | 目标 | 目标 | GUI |
| GUI device screenshot fallback | 目标 | 条件目标，approved Developer Support | GUI |
| ActionLog | 目标 | 目标 | internal + CLI maintenance |
| ReplayTrace / DiagnosticLog | 目标 | 目标 | CLI diagnostic |

### 11.1 Product Action 状态说明

以下 52 行构成第一阶段完整 Product Action 合同。发布字段含义：

```text
P   product gate；失败阻断当前发布阶段。
C   capability gate；只有精确撤销全部入口和声明后才可局部降级。
R0  合同已冻结，尚未形成对外 releasedCapability。
V0  只有设计、上游路径或 capability advertisement，无完整成功产品证据。
V1  相关 backend mechanism 已在 iPhone 14 / iOS 26.5.2 原型验证，
    但该 Product Action 尚未达到完整发布证据。
V2  完整发布行已通过；当前没有 V2。
```

`ceiling` 是完成发布证据后允许形成声明的最大范围，不是当前已发布承诺。

### 11.2 Local Product Action

| commandID | 入口与目标 | 成功/失败边界 | Scope / ceiling / evidence |
| --- | --- | --- | --- |
| `catalog.commands` | CLI `commands`；global | 返回全部 public CLI descriptor 和 Catalog metadata；不启动 Runtime | P / macOS 14+ arm64 CLI / R0 V0 |
| `developerImage.list` | CLI `developer-image list [--refresh]`；global | 只读列出当前 catalog、缓存、matching signed Xcode 与 approved remote 的支持状态；不下载、不 TSS、不 mount、不写候选记录 | P / macOS 14+ arm64 CLI / R0 V0 |
| `developerImage.check` | CLI `developer-image check [--udid UDID] [--refresh]`；device | 只读匹配设备 buildID，并且仅在既有 Runtime 已报告必要 developer service 可用时返回 `ready`；不启动 Runtime、不准备设备 | P / macOS 14+ arm64 CLI / R0 V0 |
| `product.version` | CLI `version`；global | 返回当前 app copy 的短版本号与 build号；不探测设备、不启动 Runtime | P / macOS 14+ arm64 CLI / R0 V0 |
| `self.install` | CLI `self install`；global | 原子安装或升级用户级app并协调launcher；验证失败回滚；不启动Runtime | P / macOS 14+ arm64 CLI / R0 V0 |
| `skill.install` | CLI `skill install`；global | 先完成中央app安装，再以目标集合事务发布薄skill；冲突默认不覆盖 | P / macOS 14+ arm64 CLI / R0 V0 |
| `skill.status` | CLI `skill status`；global | 只读返回内置或显式skill root的安装、修改和完整性状态 | P / macOS 14+ arm64 CLI / R0 V0 |
| `skill.uninstall` | CLI `skill uninstall`；global | 只删除显式目标内受管理payload；不删除中央app、launcher或未知文件 | P / macOS 14+ arm64 CLI / R0 V0 |
| `device.list` | CLI `devices`；global | `<=256` 时返回全部 USB iOS/iPadOS device；空列表成功；第257台 fail closed | P / macOS 14+ arm64 CLI / R0 V0 |
| `device.info` | CLI `device info [--udid]`；当前 USB iPhone | 返回稳定 facts + probe provenance；未知字段允许成功 | P / iPhone USB iOS 14+ CLI / R0 V0 |
| `device.status` | CLI `status [--udid]`；当前 USB iPhone | 返回 concise identity + condition；condition 可 unknown；不读取 Runtime | P / iPhone USB iOS 14+ CLI / R0 V0 |
| `live.launch` | CLI `live [--udid]`；短 launcher | opened=0；already open=5；host/IPC=4；window create=6；交付不明=7 | P / iPhone USB iOS 14+ CLI launcher / R0 V0 |
| `logs.prune` | CLI `logs prune`；global | 完整无失败=0；skipped/failed/未完成扫描=known partial 6；提交结果不明=7 | P / macOS 14+ arm64 CLI / R0 V0 |
| `gui.keyboardCapture.toggle` | GUI checked toggle；per-window | 返回 enabled/active/unavailableReason；不等待既有 Stream cleanup；不记录按键 | C / iPhone USB iOS 17+ GUI / R0 V1 mechanism |
| `gui.previewAudioMute.toggle` | GUI checked toggle；per-window | 名称保持 `Preview Audio`；选中=Mac 输出，未选中=Off；只改变 Mac preview，不发送 Device Mute | C / iPhone USB iOS 14+ GUI audio / R0 V0 |
| `gui.cameraAuthorization.openSettings` | Camera denied/restricted contextual action | 只证明系统设置入口已打开，不伪造授权结果 | C / iPhone USB iOS 14+ GUI video permission / R0 V0 |

### 11.3 Control Product Action

| commandID | 入口 | 成功/失败边界 | Scope / ceiling / evidence |
| --- | --- | --- | --- |
| `device.prepare` | CLI `device prepare [--udid]` | Runtime-derived target group ready；idempotent；progress有界；观察取消不回滚共享准备 | C / iPhone USB iOS 14+ CLI / R0 V0 |
| `trace.start` | CLI `trace start [--udid]` | 返回 traceID + stable path；active trace 时 `traceAlreadyActive`；Client EOF 后 trace 继续 | C / iPhone USB iOS 14+ CLI diagnostic / R0 V0 |
| `trace.stop` | CLI `trace stop [--udid]` | complete footer 后返回同 traceID/path；Runtime/trace absent=`noActiveTrace` | C / iPhone USB iOS 14+ CLI diagnostic / R0 V0 |
| `diagnostics.start` | CLI `diagnostics start [--udid]` | 返回 stable path；重复 start=`diagnosticsAlreadyActive`；Client EOF 后继续 | C / iPhone USB iOS 14+ CLI diagnostic / R0 V0 |
| `diagnostics.stop` | CLI `diagnostics stop [--udid]` | flush/close 后返回同 path；Runtime absent=`runtimeNotRunning`；none=`noActiveDiagnostics` | C / iPhone USB iOS 14+ CLI diagnostic / R0 V0 |

### 11.4 OneShot Product Action

| commandID | 入口与兼容范围 | Success boundary / 主要失败 | Scope / ceiling / evidence |
| --- | --- | --- | --- |
| `touch.tap` | CLI `tap`；iPhone USB iOS 17+ | 完整 down/up + cleanup Ack；不保证目标 App 业务结果 | P / iOS 17+ CLI / R0 V1 |
| `touch.drag` | CLI `drag`；iPhone USB iOS 17+ | 完整 begin/move/end；plan cap 超限在 admission 前失败 | P / iOS 17+ CLI / R0 V1 |
| `touch.swipe` | CLI `swipe`；iPhone USB iOS 17+ | 与 drag 共用执行机制；保留 swipe commandID | P / iOS 17+ CLI / R0 V1 |
| `button.home` | CLI + GUI；iPhone USB iOS 17+ | 完整 press/release | C / iOS 17+ CLI+GUI / R0 V1 |
| `button.appSwitcher` | CLI + GUI；iPhone USB iOS 17+ | 同一 Indigo connection 完成 double-Home；不保证 UI 持续停留 | C / iOS 17+ CLI+GUI / R0 V1 |
| `button.lock` | CLI + GUI；iPhone USB iOS 17+ | 完整 press/release；不声称 ensure-locked | C / iOS 17+ CLI+GUI / R0 V0 |
| `button.volumeUp` | CLI + GUI；iPhone USB iOS 17+ | 完整 press/release | C / iOS 17+ CLI+GUI / R0 V0 |
| `button.volumeDown` | CLI + GUI；iPhone USB iOS 17+ | 完整 press/release | C / iOS 17+ CLI+GUI / R0 V0 |
| `button.mute` | CLI + GUI；iPhone USB iOS 17+ | 完整 Device Mute button event；不代表 Preview Audio 的 Mac/Off 状态 | C / iOS 17+ CLI+GUI / R0 V0 |
| `device.rotate` | CLI relative left/right + GUI clockwise right；iPhone USB iOS 17+ | 每次只发送一个相对 quarter-turn；短窗口确认 actual display orientation；返回请求方向、response方向、previous/current display方向、是否变化和visible confirmation；不得循环追逐绝对 landscape；坐标只使用actual display geometry | C / iOS 17+ CLI+GUI / R0 V0 |
| `gui.softwareKeyboard.toggle` | GUI momentary button；iPhone USB iOS 17+ | Consumer Eject report + barrier；不查询或声明最终可见状态 | C / iOS 17+ GUI / R0 V1 mechanism |
| `text.clear` | CLI；iPhone USB iOS 17+ | Command+A、release、Backspace、release barrier；不声明文本为空且不自动重试 | C / iOS 17+ CLI / R0 V0 |
| `text.cursor` | CLI bounded move/count/select；iPhone USB iOS 17+ | Arrow/modifier 宏 + release barrier；不声明最终光标或选区 | C / iOS 17+ CLI / R0 V0 |
| `text.inputSource.next` | CLI；iPhone USB iOS 17+ | Control+Space + release barrier；只声明循环请求已派发 | C / iOS 17+ CLI / R0 V0 |
| `text.key` | CLI allowlisted key/modifier/repeat；iPhone USB iOS 17+ | 物理 HID 宏 + release barrier；不声明最终字符 | C / iOS 17+ CLI / R0 V0 |
| `text.type` | CLI UTF-8；iPhone USB iOS 17+ | pasteboard SET 后完成 paste/release barrier；不保证 App 显示；不恢复旧 pasteboard | C / iOS 17+ CLI / R0 V0 |
| `app.install` | CLI + GUI `.ipa`；iPhone USB iOS 14+ | installation backend Complete；不自动 launch；无 rollback/retry | C / iOS 14+ CLI+GUI / R0 V0 |
| `app.uninstall` | CLI bundleID；iPhone USB iOS 14+ | installation backend Complete；`appNotInstalled`/`uninstallFailed` | C / iOS 14+ CLI / R0 V0 |
| `app.launch` | CLI bundleID；iOS 17+ 或条件 iOS 14～16 | launch request 完成；不保证持续前台；Developer Support unavailable时精确失败 | C / iOS 17+及条件 iOS 14～16 CLI / R0 V0 |
| `app.list` | CLI `apps [--udid]`；iPhone USB iOS 14+ | installation Browse 明确 Complete；返回全部符合 package/tag 规则的稳定排序结果；异常或超限 fail closed，无 partial | C / iOS 14+ CLI / R0 V0 |

### 11.5 Stream Product Action

| commandID | 入口与兼容范围 | Success/cleanup boundary | Scope / ceiling / evidence |
| --- | --- | --- | --- |
| `gui.pointer.interaction` | GUI canvas；iPhone USB iOS 17+ | backend open；begin/end ordered、move latest-wins；acceptedForDelivery 才广播 overlay；cleanup Ack 或 fence 后 terminal | P / iOS 17+ GUI / R0 V1 |
| `gui.keyboard.interaction` | Keyboard Capture active；iPhone USB iOS 17+ | ordered pressed-set；release-all Ack 或 fence 后 terminal；不记录 usage/frame/text | C / iOS 17+ GUI / R0 V1 |

### 11.6 Hybrid Product Action

| commandID | 入口 | Success/partial boundary | Scope / ceiling / evidence |
| --- | --- | --- | --- |
| `runtime.status.global` | CLI `runtime status` | 只读可发现 socket；full/lite bounded summary；超限/timeout 为 known partial | P / macOS 14+ arm64 CLI / R0 V0 |
| `runtime.status.device` | CLI `runtime status --udid` | 返回 full/lite/notRunning/generationBusy + bounded preparation projection；不等待、不 signal、不恢复 | P / canonical Runtime target CLI / R0 V0 |
| `runtime.stop` | CLI `stop [--udid]` | 确认 socket EOF + runtime.lock 释放才成功；可退场 verified orphan；不 spawn | P / canonical Runtime target CLI / R0 V0 |
| `logs.clear.device` | CLI `logs clear [--udid]` | Runtime 协调 active writer或本地删除 closed file；known/partial/unknown 分离 | P / canonical log/runtime target CLI / R0 V0 |
| `logs.clear.all` | CLI `logs clear --all` | snapshot/fan-out 非事务执行；已完成不回滚；unknown 优先 exit 7 | P / macOS 14+ arm64 CLI / R0 V0 |
| `element.snapshot` | CLI `element snapshot` | 同一可信 current viewport 的并行视觉分析与融合；单/双路失败为显式 degraded success，三路全失败或无可信 frame 失败；可选标注 PNG 由 Client 原子写入 | C / iOS 17+及条件 iOS 14～16 CLI / R0 V0 |
| `screenshot.cli` | CLI output path | device PNG FD + Client atomic write；outputExists/validation/size/write 分阶段失败 | C / iOS 17+及条件 iOS 14～16 CLI / R0 V0 |
| `screenshot.gui` | GUI Save Panel | cancel 不调用 Runtime；fresh bound preview local save，否则 device fallback | C / iOS 14+ GUI preview，fallback按 OS / R0 V1 preview only |
| `live.close` | GUI window close | 停止 media、清理 owned Stream、detach/EOF cleanup；accepted OneShot 继续 | P / iPhone USB iOS 14+ GUI / R0 V0 |

### 11.7 非 command 产品能力

| featureID | 最终合同 | Scope / ceiling / evidence |
| --- | --- | --- |
| `live.targetBindingSafety` | 真实帧必须绑定 canonicalUDID + source/connection epoch；永不显示 A 控制 B | P / iPhone USB iOS 14+ GUI / R0 V0 |
| `live.identityPlaceholderBlindControl` | 未绑定/无 Camera 时显示 name+UDID+真实 geometry，占位下继续非视频控制 | P / iPhone USB iOS 14+ GUI / R0 V0 |
| `live.videoPreview` | AVFoundation preview；Camera 独立降级；source/epoch fail closed | C / iPhone USB iOS 14+ GUI / R0 V1 mechanism |
| `live.audioPreview` | AVFoundation audio；默认 Off；per-window 选中=Mac、未选中=Off；Mic/audio failure 不影响 video/control | C / iPhone USB iOS 14+ GUI / R0 V0 |
| `live.inputObservationOverlay` | acceptedForDelivery projection；ordered boundary/latest move/reset；不反压执行 | C / iPhone USB iOS 17+ GUI / R0 V0 integration |
| `developerSupport.transparentPreparation` | explicit/implicit/live demand共用准备；approved acquisition/cache/mount/service状态对用户透明 | C / iPhone USB iOS 14+ / R0 V0 |

## 12. 调度与并发体验

PulsePhone 不采用“同一设备所有命令全局串行”的产品模型。Runtime 根据资源声明决定并发、等待或立即 busy。

```text
new action
    |
    v
all resources free and no earlier conflicting waiter?
    | yes                         | no
    v                             v
run immediately             realtime Stream?
                                  | yes          | no
                                  v              v
                             resourceBusy     finite OneShot
                                              enters pending queue
```

产品规则：

- 同一冲突域按 FIFO，exclusive waiter 防止新的 shared claimant 插队。
- 资源完全不相交的后到 action 可以越过。
- OneShot pending queue 每 UDID 最多 64。
- 显式 PrepareObserver 每 UDID 最多 64 个；ordinary-command/Live start-only demand不占 observer capacity。
- pointer/keyboard Stream fail fast，不排队、不重放。
- Developer Support asset 下载不持有 device resource；只有短期 query/mount/service preparation参与同一 Scheduler仲裁。
- preparation loading期间，依赖同一 capability的有限命令立即返回 `capabilityPreparing` remediation；非DDI且资源不冲突的命令继续。
- live 窗口本身不独占整个设备；CLI 仍可执行不冲突命令。
- install/uninstall/launch 两两串行，但允许与不冲突的 pointer、keyboard 或 screenshot 并发。
- Home/App Switcher/Lock、`type --text` 和 Text HID 命令因 exclusive app-state 与相关操作互斥。

## 13. Client 等待、取消与结果未知

普通有限CLI最多本地等待60秒。DDI-dependent command 不把 Runtime preparation 纳入该等待：未 ready 时立即返回 `capabilityPreparing` remediation，不自动重新规划或执行。显式 `device prepare` 一直观察 Runtime-owned job，直至 Runtime 的内部成功、typed failure、绝对 deadline 或断连 terminal；不使用 Client observer budget。

```text
CLI                       Runtime                       Device
 | device prepare            |                            |
 |-------------------------->| register observer / run    |
 |<--------------------------| progress                   |
 | SIGINT ignored            |                            |
 |<--------------------------| Runtime terminal           |
 X                           |                            |
```

结果：

- DDI-dependent ordinary command 不注册 completion waiter；它启动/加入 shared job 后立即返回 remediation，原动作未 accepted、未执行且不自动恢复。
- `device prepare` 的 CLI 忽略 Ctrl-C 且没有 observer timeout；client EOF 只移除观察通道，绝不取消 shared job。
- running OneShot 不因 Client timeout 或普通 EOF 强制停止。
- CLI 返回 `outcomeUnknown`、`runtimeMayContinue=true`、exit 7。
- Runtime 最终结果进入 ActionLog，但第一阶段不提供结果恢复 API。

Ctrl-C 使用独立合同，`device prepare` 例外：

- 整次调用只有 1 秒总预算。
- OneShot 可原子取消尚未 running 的 owned work。
- 普通 one-shot 的 Gate waiter 可以移除，但不取消 shared acquisition/attempt；`device prepare` 的 PrepareObserver 不因 SIGINT 移除。
- running/cleaning 不强制停止。
- 所有受控 Ctrl-C 结果固定 exit 130。
- 第二次 Ctrl-C 立即退出，不再等待。

聚合命令优先级：

```text
Ctrl-C                         -> exit 130
任一已提交子项 outcome unknown -> exit 7
任一已知失败/超时/跳过         -> exit 6
全部成功                       -> exit 0
```

## 14. Runtime 生命周期体验

### 14.1 自动启动

用户无需手动管理 daemon。需要 Runtime 的命令自动连接或启动对应 UDID 的 Runtime。

`devices`、`device info`、`status` 和静态 `commands` 不为查询而启动 Runtime。

### 14.2 自动空闲退出

自动退出条件：

```text
没有 live
+ 距最后一次有效 CLI activity >= 10 分钟
+ 没有 OneShot / Stream / trace / asset acquisition / preparation / control mutation / cleanup blocker
= Runtime 可以 quiesce 并退出
```

有效 CLI CommandIntent 和成功注册的 CLI `device prepare` 刷新 activity 时间。health、runtime status、progress、命令完成和 live 内部 activity 不刷新。

### 14.3 USB 断连与重连

Detach 后：

- Runtime 和 live ownership 保留。
- pending job、显式 PrepareObserver 和 start-only demand 结束为 `deviceDisconnected`。
- device-side preparation结束；独立host asset acquisition可以继续并提交cache。
- running job 不强制取消，等待 backend terminal 或原 deadline。
- active pointer/keyboard 进入 cleanup。
- GUI 丢弃旧 video/audio，显示目标身份占位。

Attach 同一 UDID 后：

- 复用原 RuntimeProcess、socket、Scheduler 和 live ownership。
- 创建新的 connection epoch。
- 旧 Helper/tunnel/service 永不复用。
- 等旧 generation 完整退场后只按新显式或start-only demand准备新 generation。
- Runtime 控制恢复和 AVFoundation video rebinding 分别进行。
- 不自动重放断连前的命令。

### 14.4 Runtime fatal

Helper crash、协议损坏、确认非 USB detach 的 fatal transport failure 或无法完成 cleanup 会使当前 per-UDID Runtime fail-stop。

其他 UDID 不受影响。GUI 保留正确绑定的视频窗口，清理旧 Stream 和 overlay，进入 video-only/runtime-restarting 状态，并在当前 recovery episode 中尝试一次统一 Runtime 恢复。失败后不 crash-loop，只在 USB Attach、App foreground 或显式用户操作时再次尝试。

## 15. 日志、隐私与可观察性

### 15.1 ActionLog

ActionLog 是 best-effort 操作历史，不是强一致审计或可靠回放源。

每个 action 使用 append-only 双事件：

```text
action.begin
  -> action.terminal
```

hard crash 可以留下 begin-only；日志写失败可以留下 terminal-only。消费者必须容忍不成对记录。

hybrid action 使用 root/child：

```text
root R
  +-- child C1, parentActionID=R
  +-- child C2, parentActionID=R
```

root 与每个 child 各自最多一个 begin 和一个 terminal。child terminal 不能替代 root terminal；Client 与 Runtime 不得对同一 actionID 重复写 terminal。

默认 retention 目标：

```text
单文件 rotate       10 MiB
每 UDID closed files 5
closed age           7 天
每 UDID               50 MiB
全局                 250 MiB
```

除 10 MiB rotate 外，不运行后台 retention timer；其他目标只在显式 `logs prune` 时处理。

### 15.2 ReplayTrace

ReplayTrace 用于显式记录可诊断、可人工分析的语义执行序列。

- 固定脱敏。
- 不记录 pointer/keyboard frame、HID usage、pressed set、文本或路径原文。
- 5 MiB hard cap。
- complete footer 表示正常结束。
- incomplete footer 表示 Runtime 存活时异常停止。
- 无 footer 表示可能发生 hard crash。
- active trace 阻止 Runtime idle/manual stop。

### 15.3 DiagnosticLog

默认技术日志进入 macOS unified logging。只有显式 diagnostics session 才创建临时 JSONL 文件。

- 5 MiB hard cap。
- 达到 cap 后自动结束。
- 不保留 last receipt 或恢复索引。
- Runtime 重启和 screenshot cleanup 不删除该文件。
- diagnostics session 本身不阻止 Runtime stop。

### 15.4 隐私

任何日志和性能导出不得包含：

- 文本输入原文或 hash。
- Keyboard HID usage、pressed set 或逐键 frame。
- pointer 坐标明细，除非明确允许的脱敏语义摘要。
- IPA、Screenshot、Trace、Diagnostics 的完整用户路径。
- canonical UDID 明文出现在性能导出中。
- backend 原始异常或可能包含敏感数据的任意 JSON。
- Element screenshot、OCR 正文、视觉 caption、OmniParser credential 或 endpoint query。
- Developer Support URL query、cache绝对路径、ECID、nonce、personalization manifest或TSS ticket。

## 16. 错误体验

错误必须说明：

- 发生了什么。
- 是否可以重试。
- 是否可能仍在 Runtime 中继续。
- 用户应采取的下一步。

参数错误必须返回具体的公开参数名、失败原因和适用约束；能确定的修正方式应在 message 中给出建议。参数错误不得被解释为设备连接失败，也不得因参数未改变而自动重试。

主要错误类别：

| 类别 | 代表错误 |
| --- | --- |
| 参数 | `invalidArgument`, `invalidCoordinate`, `invalidUDID`, `argumentTooLarge` |
| 目标/兼容 | `noDeviceConnected`, `deviceNotFound`, `unsupportedOSVersion`, `unsupportedDeviceClass` |
| Runtime/协议 | `runtimeNotRunning`, `runtimeFailed`, `incompatibleRuntime`, `transportFailure` |
| Admission | `queueFull`, `resourceBusy`, `capabilityPreparing`, `admissionCapacityExceeded`, `runtimeStopping`, `liveAlreadyOpen` |
| Developer Support | `developerSupportUnavailable`, `developerImageDownloadFailed`, `developerImageIntegrityFailed`, `developerImageCacheCapacityExceeded`, `personalizationServiceUnavailable`, `developerImageMountFailed`, `developerServicesUnavailable`, `preparationTimeout` |
| 已知失败 | `deviceDisconnected`, `executionTimeout`, `installFailed` |
| 未知结果 | `outcomeUnknown`, `guiLaunchOutcomeUnknown` |
| 中断 | `interrupted`, `cancellationUnknown` |

同一底层 timeout 或断连必须按 commitState 映射：

```text
明确未提交         -> known failure / exit 6
已经提交或无法判断 -> outcomeUnknown / exit 7
```

PulsePhone 第一阶段不自动重试 mutating command。

静态Help只声明兼容边界，不替代执行期权威判断。`unsupportedOSVersion`继续属于`targetCompatibility`、exit 3，但human/JSON错误必须在有界typed details内说明command要求和当前目标OS，例如：

```text
unsupportedOSVersion: tap requires iOS 17 or later; target device is running iOS 16.
```

版本符合但Developer Support、Developer Mode或具体service/capability不可用时，必须保留`developerSupportUnavailable`、`developerModeRequired`、`developerServicesUnavailable`、`capabilityUnavailable`等独立typed error，不得统一改写成系统版本错误。

## 17. 交付阶段与降级

### 17.1 阶段

```text
Design Freeze
  -> 公开合同冻结，可重写 PRD/TRD。

Default Product Delivery
  -> 形成可用 PulsePhone.app。
  -> 在 owner 实际提供的设备上闭合 live、输入、工具栏和生命周期。
  -> 只声明 exact tested device/build/capability；其余为 notTested。

External Distribution
  -> 在默认产品交付通过后，按实际分发渠道完成签名、公证和许可证义务。

Optional High-Assurance Validation
  -> owner 显式激活后，执行保留的 Alpha/Beta/Formal 长时、矩阵和审计流程。
```

### 17.2 失败范围

当前激活配置中的每项交付要求属于：

```text
product
  失败阻断当前发布阶段。

capability
  只有在精确 command/feature、device class、OS range 和 exposure
  可以从 Catalog、CLI、GUI、PRD、help 和测试中完全移除时，才允许局部撤销声明。
```

统一判断：

```text
test failure
     |
     v
shared safety or product invariant broken?
     | yes                         | no
     v                             v
block release              can exact capability be
                           completely disabled/removed?
                              | yes          | no
                              v              v
                         revoke claim    block release
                         and rerun matrix
```

错设备、错视频帧、重复 Runtime/Helper/download owner、误杀进程、generation/lock 泄漏、cache越界或非原子提交、敏感数据泄漏和重复 terminal 始终属于 product failure。没有提供某型号设备、旧 OS、clean host、TCC reset、签名凭据或重复拔插环境不属于默认产品失败；这些项目在默认配置下记录为 `notTested`。

capability撤销必须由同requirement/use-scope的immutable legal material或evidence scenario触发，并使用typed removal target对当前公开exposure做单调收窄。默认原语是same-kind确定性set subtraction；唯一cross-kind例外是把一个bounded OS claim整体替换为由同flow passing exact-build evidence机械派生的非空严格子集。受影响Catalog、CLI、GUI、PRD、help、测试和policy由工具机械派生，不能由执行者自由填写。

## 18. 默认产品交付验收标准

本节默认针对 `Default Product Delivery`。它要求验证用户能够看到和操作的生产应用，不允许用孤立模型、fake backend、golden fixture 或只读源码审计代替 `PulsePhone.app` 的真实入口。高保障配置的额外要求由附加文档和 TRD 08 显式激活。

### 18.1 Contract

- PRD、TRD、`command-matrix` revision、共享 Catalog、CLI help 和 GUI exposure 一致。
- 所有 52 个 Product Action、21 个 Supporting Action、6 个 non-command feature 和排除入口都有静态覆盖测试。
- 不存在未注册 command、Wire operation、error code 或隐藏入口。

### 18.2 Target safety

- 多设备、同名设备、canonical collision、USB 拔插和 epoch 变化的模型/进程测试证明不会控制错误设备；实际设备 smoke 只覆盖 owner 当前提供的设备，未提供拓扑为 `notTested`。
- 未确认 AVFoundation source 绑定时不显示真实帧。
- 首次 mapping 只允许由 Chooser Preview + 用户确认形成 `operatorConfirmedPreview.v1`，或由严格 phone-screen classifier、完整 Stable gate、单 connected target、名称 exact guard、无重复 claim 和首帧 Probe 共同形成 `singleConnectedTargetSource.v1`。后续 trusted cache 只允许 exact sourceID 在 current capture-eligible inventory 单命中、无 duplicate claim并收到 current sourceEpoch 有效帧后恢复；cache stale/corrupt/ambiguous/no-frame时必须回退 Chooser。
- Chooser确认只接受同owner/sourceEpoch且age不超过1秒的current Preview帧；mapping中的可缺省initial canvas尺寸只影响首帧前比例，不建立source、方向或坐标authority。
- 不出现“显示 A、控制 B”。
- Runtime/orphan recovery 不 signal foreign 或 PID-reused process。

### 18.3 GUI

- `live` 在 5 秒产品 deadline 内返回 opened、alreadyOpen、sourceSelectionOpened、known failure 或 outcomeUnknown；`--select-source` 强制打开或聚焦关联 Chooser。
- 首次 Resolver/Chooser 不启动 target Runtime；source handoff 后才创建正式 Live 并 attach。已有 Live 的 Change Source 取消后保持原 Runtime、mapping 和画面。
- Chooser 不等待 Stable gate 即可显示 target facts、候选和 thumbnail；单设备自动路径只能在完整 1.5 秒窗口结束且末尾集合稳定后执行。正式 Live 底栏只读显示 source 状态并保留 Change Source，不提供直接 picker/Preview/Use Source。
- Chooser 使用双栏 source list + 大尺寸 Preview，已有 Live 默认选择 current active source，否则默认选择确定性第0项并立即 Preview；每项分别显示 mapping 与 active Live 状态。target facts/claims 瞬态失败时 Preview 不被清除，最多四轮串行自动恢复成功后自动开放确认，Refresh 可重启恢复。
- current active source 的再次确认是 strict no-op；跨 target source 重新分配只在一次最终确认后执行，并使原 target 的画面停止、mapping 清除且后续重新选择。
- Chooser和direct cache路径都只以canonical UDID创建正式Live；Live重新读取mapping。正式Probe可以提升同一source-scoped capture lease，bound运行中2秒无帧必须退出live状态，每个stall generation最多一次clean reacquire且没有固定sleep。
- 同一 source-scoped capture 向多个 display consumer 扇出时，每个 consumer 使用独立、可安全修改 attachments 的 sample wrapper；Chooser Preview 与已有 Live 并行、Refresh/取消/确认/关闭竞态不得造成共享sample mutation或崩溃。
- 同一attached Live/current connection epoch换源不产生冲突的新`captureActivationID`；new epoch/new Live轮换，capture-ready failure保持typed且control文案与实际authority一致。
- 占位窗口在 Camera/video 不可用时仍显示正确目标身份和比例。
- iOS 17+ pointer、Keyboard Capture、Toggle Software Keyboard、toolbar 和 overlay 符合本 PRD。
- iOS 14～16 不显示或启用不兼容输入能力。
- toolbar shape 稳定，不因 Runtime revision 重排。
- Live 的 More 面板底部显示当前 app copy 版本；Source Chooser 标题栏 subtitle 显示同一版本。版本展示不参与 toolbar overflow、source controls fitting、窗口最小宽度或设备画面比例计算。
- Preview Audio 的 Mac/Off 状态与 Device Mute 明确分离；新 live 窗口默认 Off。
- GUI screenshot 正确执行 preview-first 和 device fallback。
- accepted install 不因窗口关闭取消。
- 稳定windowed生产窗口在首次portrait/landscape binding、方向变化及从任意边角live resize后，video canvas与current sample presentation ratio严丝合缝，不存在白色或黑色侧边；minimum width、toolbar和source controls通过overflow、自适应布局及双轴同比例裁限解决。fullscreen或presentation未稳定的有界过渡可以使用设备坐标之外的对称黑色letterbox。
- 用户未调整过windowed尺度时，placeholder和首次portrait/landscape binding使用默认`375 pt` preferred canvas短边；Retina `2x`下约等于`750 backing pixels`，但验收以AppKit points为准。另一轴按current presentation ratio派生，当前屏幕不足时等比例缩小；当前标准主显示环境且布局可行时，portrait canvas/content/frame短边约为`375 pt`。该目标取代先前`640 pt` preferred长边和`340...360 pt`宽度口径；初始reservation不得引入letterbox、裁剪设备像素、缩小标准hit target或让toolbar/source controls覆盖video canvas。
- 用户windowed resize的产品最小canvas短边为`320 pt`；在当前screen可容纳时，portrait和landscape均不得缩到该值以下，也不得把低于该值的瞬态/settled尺寸保存为用户尺度。标准macOS四边与四角resize入口均保留；一次拖动冻结presentation ratio和驱动方式，直接拖动边单调移动且全过程没有反弹、driver切换、尺寸双帧振荡或可见程序化校正。缺失`windowWillResize`或AppKit partial-axis adoption不得导致先自由变形、松手后再校正。普通resize继续播放同方向帧；resize中发生方向变化时保留最后一个兼容帧并继续format检测，结束后一次采用已稳定的新presentation和用户尺度，presentation/geometry收敛前坐标输入fail closed。
- 同一current sourceID/sourceEpoch下的合法分辨率变化和portrait/landscape宽高交换持续enqueue；稳定变化在TRD deadline内推进formatRevision、window reservation和interaction geometry，单帧异常不造成窗口跳动。
- 用户resize后保留windowed canvas长边；fullscreen中方向变化不改写系统frame，退出后按current presentation ratio恢复进入前尺度。placeholder、Camera denied和source unavailable走同一几何管线。
- presentation与interaction geometry未收敛时视频继续显示、坐标输入fail closed；收敛后tap/drag使用当前visibleImageRect，不出现显示横屏但按竖屏映射。
- 视频与触控可用性独立表达。USB detach立即停止旧capture/audio/input authority，但同一target保留最近一次identity-valid最后一帧和已提交比例，并覆盖“画面已断开”；触控未准备好时独立显示状态。没有历史帧或identity发生变化时清帧并回到身份占位。中央状态在黑色占位和任意冻结帧上均保持高对比、无重复文案，并与底部触控徽标互不遮挡。重连后视频和触控按各自current authority独立恢复，浮层不拦截已获准的点击、拖动或边缘手势。
- 稳定、已预热的 live 会话中，pointer 首触不得因每手势重复设备 geometry 查询、Helper/tunnel 重建或 input-service 初始化出现固定秒级停顿；每个自然手势仍使用独立逻辑 Stream，底层 generation/service 和 current authoritative geometry snapshot 按各自生命周期复用。Stream admission/closing 失败必须可见且不得让后续手势静默失效。
- 生产 AppKit 入口实际接入 pointer、Keyboard Capture、Toggle Software Keyboard、overlay、audio、toolbar、screenshot 和 preparation 状态；只存在可测试的数据模型不算通过。
- 在packaged app中形成一次可信 source mapping 后，关闭并重新启动应用；第二次`live`必须在无需Computer Use或再次选择source的情况下按缓存状态机自动恢复同一iPhone画面。用户强制重选、重新分配、cache失效回退和多设备冲突提示必须可用。

### 18.4 CLI

- 除 `element snapshot` 的明确机器输出合同外，所有公开命令同时通过 human 和 `--json` golden tests；Element 覆盖默认 JSON、annotated-only、both 和冲突参数 golden tests。
- `element snapshot` 的 JSON/PNG 必须证明同一 generation/capture，坐标可直接驱动现有 tap，单/双路降级可见，并验证查询前后 viewport 零滚动、零 focus move、零输入和零 overlay。
- `version` 的 human 输出为 `PulsePhone <version> (<build>)`；JSON result 精确返回 `version` 与 `build`，且不探测设备、不启动 Runtime 或 GUIHost。
- stdout/stderr、exit code、target union、partial 和 outcomeUnknown 契约一致。
- 普通60秒 Client timeout、`device prepare` 的 Runtime-owned terminal wait 与其他命令的1秒Ctrl-C契约独立。
- `device prepare` human progress、`--json` single terminal envelope、ordinary-command remediation 和 Live preflight 同时通过 golden tests。
- 不公开 job handle、force stop、hidden quick route 或废弃入口。
- 默认目标选择稳定且不自动跳过第一台不兼容设备。

### 18.5 Lifecycle

- 每 UDID 最多一个 Runtime owner。
- 不同 UDID 的 Runtime crash 互不影响。
- USB reconnect 不复用旧 Helper generation。
- asset acquisition、device preparation和Helper generation各自 exactly-once terminal/release；detach不取消已拥有的host download。
- stop 只在所有 blocker 清零后完成。
- Runtime crash 后 accepted work 不被自动重放。
- OneShot/Stream terminal 和 cleanup exactly once。

### 18.6 Packaging 与法律

- 默认产品交付必须从 repository 的正式 packaging 入口构建并启动 `PulsePhone.app`，不能依赖测试专用 Runtime、stub GUIHost 或未打包的替代 executable。
- app 内部依赖使用 bundle-relative lookup；当前开发机上的绝对路径、caller cwd 和临时构建目录不能成为运行合同。
- 第一阶段发布包不包含 DDI；受控 Application Support cache按产品合同存在。
- Developer ID 签名、公证、staple、clean-machine 安装矩阵、许可证交付包、EvidenceStore 和 store-to-dist hold 只在外部分发或高保障配置显式启用时成为 Gate。
- 未签名或仅开发签名的默认交付构建不得被描述为已满足外部分发要求。

### 18.7 Stability

- 默认交付执行有界 live smoke，覆盖启动、真实帧、至少一次 GUI 输入、至少一个工具栏设备动作、窗口关闭、再次启动和进程/endpoint 清理。
- 只在 owner 已提供且无需持续人工值守的条件下验证断连/重连；缺少额外硬件或没有自动化拔插能力时记录 `notTested`，不要求人工完成固定次数拔插。
- 任一实际执行中出现 crash、错目标、重复 Runtime/同角色 Helper、误杀、lock/generation 泄漏或 duplicate terminal 仍然失败，不能用未执行的矩阵项目掩盖。
- `30 min + 5`、`2 h + 20`、`8 h + 50 x 3` 的旧矩阵完整保存在可选高保障配置中，默认不执行。

### 18.8 Performance

Design Freeze 只冻结测量方法，不预填没有实测依据的阈值。

第一阶段测量：

- `previewFPS`
- `hostVideoPipelineLatencyMs`
- `touchDeliveryLatencyMs`
- `cpuTotalPercent`
- `rssTotalMiB`
- `rssGrowthMiBPerHour`
- `controlReconnectMs`
- `videoReconnectMs`

`hostVideoPipelineLatencyMs` 只表示 Mac host pipeline，不得称为端到端视频延迟；`touchDeliveryLatencyMs` 只到 Helper acceptedForDelivery，不声称 iPhone UI 已绘制。

GUI pointer 还必须分层记录 AppKit 接受 mouseDown、逻辑 Stream open 完成、对应 begin frame 被 Helper acceptedForDelivery、实体设备开始响应以及 Live 画面反映结果的时间。`touchDeliveryLatencyMs` 的起点晚于 Stream open，不能用它掩盖 mouseDown 到首个 begin 提交之间的 admission 停顿；在新增正式 machine-readable metric 前，这组时间作为有界 diagnostic observation 保存并用于关闭 pointer 首触问题。

默认交付只要求采集足以发现空白画面、无帧、明显卡死、无控制投递和进程失控的有界指标，不预填发布 SLA，也不要求 owner 冻结阈值。三轮 baseline、`PerformanceThresholdProfileV1`、same-flow freeze 和 Formal 多轮判定只在高保障配置显式激活时执行。Audio 第一阶段只验证功能和稳定性，不定义 latency SLA。

## 19. 交付与验证义务边界

默认产品交付必须持续满足：

- 正式 `live` 窗口从当前 UDID 建立正确 Runtime、视频和 geometry ownership。
- 生产窗口接入可点击/拖动的 pointer stream、坐标转换、窗口 aspect-fit 和 geometry invalidation。
- 生产 AppKit 工具栏接入 Home、App Switcher、锁屏、音量、旋转、键盘、音频、截图和 IPA 安装等合同动作。
- 生产 Runtime backend 将 `command.submit`、`stream.open`、prepare、availability 和 live lifecycle 路由到真实设备执行链，而不是固定返回 `deviceDisconnected` 或空 availability。
- 窗口关闭、再次打开、Runtime/Helper/GUIHost endpoint 清理在实际 app 入口闭合。
- 在 owner 实际提供的设备上记录 exact device/OS/build/capability 结果。

本节只定义合同范围，不维护当前实现或验证状态。已经确认的产品问题统一记录在`OBSERVED_ISSUES.md`；因设备、环境、人工前提或配置未激活而尚未执行的验证统一记录在`DEFERRED_VALIDATION.md`。不得根据本节列表推断某项当前为通过、失败或`notTested`。

以下属于可选高保障或后续扩展义务，不阻断默认产品交付；其当前激活与验证状态由`DEFERRED_VALIDATION.md`持有：

- UDID 与 AVFoundation source 的确定绑定。
- 两个签名 Go Helper、签名和 notarization，以及发布包不包含 Python runtime、wheel 或 Python helper source。
- Go 标准库/依赖、approved Developer Support source/use 和其他实际分发材料的许可证与发布义务。
- iOS 17+目标范围对应的bounded lower/intermediate/upper exact-build兼容矩阵；设备不足时收窄发布scope。
- iPhone 11 Pro / iOS 14.2.1 与 iPhone 12 / iOS 16.3.1 的 legacy direct subset。
- DeveloperImageCatalog、download/resume/hash/cache/prune、cross-Runtime/app-copy single-flight和no-Xcode clean-machine。
- personalized DDI、reusable manifest、Apple TSS online/offline和mountedUnknownUnverified证据。
- Lock、Volume、Mute、Rotate、Screenshot、Install、Launch 等未完整验证 command。
- Runtime singleton、orphan recovery、fault injection 和 USB reconnect。
- Camera、Microphone、Input Monitoring 的独立降级。
- ActionLog、ReplayTrace、DiagnosticLog 和 Screenshot artifact 的完整生命周期。
- Command Matrix、Catalog、Planner、Wire registry 和 StandardError fixture 一致性。
- Scheduler、CapabilityGate、Stream backpressure 和 terminal barrier。
- 稳定性与性能指标采集、导出、基线和发布阈值。
- durable EvidenceStore、flow-neutral legal import、selected/lineage holds，以及held candidate tree到最终dist app的逐byte发布闭环。

## 20. 后续方向

第一阶段稳定后再评估：

- 使用 Go 重写 PulsePhone 实际需要的 CoreDevice/Lockdown 协议子集。
- MCP / Phone Use。
- pulse 集成和 iOS 16 external driver mode。
- iPad 支持。
- 录屏、录制与回放。
- Codex/Cursor 内嵌体验。
- 更完整的 App、设备和测试型能力。
