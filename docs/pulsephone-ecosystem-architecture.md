# PulsePhone 生态架构

> 文档状态：长期生态蓝图
>
> 基线日期：2026-07-16
>
> 当前阶段：优先完成独立 PulsePhone；MCP、Phone Use 产品化和 pulse 集成不进入第一阶段实现。

## 1. 文档定位

本文定义 PulsePhone、MCP、Phone Use 和 pulse 四个模块的长期职责、边界、依赖方向和阶段关系。

```text
ecosystem architecture
  -> 定义四个模块为什么存在、分别负责什么、如何协作

pulsephone-prd.md
  -> 定义 PulsePhone 第一阶段作为独立产品提供什么

pulsephone-trd.md + pulsephone-trd/*
  -> 定义如何实现和验证当前 PRD
```

本文不定义 PulsePhone 内部 Wire、Helper、调度、文件路径或错误 DTO。发生冲突时，PulsePhone 当前产品和工程行为分别以 PRD、TRD 为准；生态蓝图需要随之同步，不能反向引入未进入当前阶段的能力。

## 2. 四个模块

### 2.1 PulsePhone

PulsePhone 是独立的 macOS iPhone 预览与控制产品，也是生态中唯一直接拥有 PulsePhone 设备访问链路的模块。

职责：

- 提供 GUI live 和 CLI 产品入口。
- 发现、选择并校验目标设备身份。
- 提供视频/音频预览、触摸、键盘、按键、截图、current-viewport element snapshot 和 App 管理能力。
- 独占设备画面 capture、snapshot generation、视觉 analyzer/fusion 和坐标 authority；无法证明 target/epoch/freshness 时 fail closed。
- 管理每台设备的执行协调、并发、生命周期和错误语义。
- 生成 ActionLog、ReplayTrace、DiagnosticLog 和发布证据。
- 未来提供稳定的高层 Agent API，供 MCP 或 pulse 调用。

边界：

- 不承担 MCP 协议适配。
- 不定义 Agent 如何理解页面或选择下一步动作。
- 第一阶段不依赖 pulse，也不改造 pulse。
- 未来高层 API 不允许调用方绕过 PulsePhone 的目标校验、调度或生命周期。

### 2.2 MCP

MCP 模块是 Phone Use 能力到 MCP client 的协议适配层。其具体进程名称可以后续确定，本文使用 `iphone-use-mcp` 表示该角色。

职责：

- 暴露 MCP tools、resources 和稳定 schema。
- 将 MCP request 转换为 PulsePhone 高层 Agent API request。
- 将 PulsePhone 的结果、截图、element snapshot 和结构化错误映射为 MCP response。
- 管理 MCP connection、client cancellation 和协议级限流。

边界：

- 不直接访问 CoreDevice、Lockdown、AVFoundation 或设备服务。
- 不持有 PulsePhone Runtime、Helper、tunnel 或设备级 queue。
- 不 import PulsePhone 私有实现模块。
- 不复制 PulsePhone 的 target selection、重试、调度或错误真相。

### 2.3 Phone Use

Phone Use 是面向 Agent 的产品能力模型，不是设备进程、transport 或 Runtime。

职责：

- 定义 Agent 可以理解的手机操作语义。
- 定义 screenshot、element snapshot、tap、drag、type、button、install 等工具体验。
- 定义观察、动作、结果和下一步决策所需的信息模型。
- 未来承接录制、回放、任务级历史和 Agent UX。

边界：

- 不直接执行设备协议。
- 不拥有某个 UDID 的设备状态、截图/element generation、视觉 analyzer 或执行队列。
- 不规定 PulsePhone 内部使用 Swift、Python、Go 或具体 backend。
- 产品语义必须映射到 PulsePhone 已公开且已发布的能力，不能凭空扩大设备能力。

### 2.4 pulse

pulse 是现有成熟自动化项目，继续负责已有全版本设备自动化和测试工作流。

职责：

- 维护现有 skill、WebDriver、sib 和自动化能力。
- 继续服务已有测试、脚本和全版本设备控制场景。
- 未来按需要调用 PulsePhone 高层 API，或为旧系统提供 external driver。

边界：

- 第一阶段不因 PulsePhone 改造现有架构。
- 不与 PulsePhone 共享私有 Runtime/Helper 内部状态。
- 集成时不能形成第二套 PulsePhone 设备 ownership 或绕过目标安全。
- pulse 的已有能力不自动成为 PulsePhone 的产品承诺。

## 3. 总体关系

```text
Human user
  +-- GUI ------------------------------------------------+
  +-- CLI script -----------------------------------------+
                                                         |
                                                         v
                                                   +-----------+
                                                   | PulsePhone|
                                                   | product   |
                                                   +-----+-----+
                                                         |
                                                         v
                                                    USB iPhone

Agent / Codex / MCP client
  -> MCP adapter
  -> future PulsePhone Agent API
  -> same PulsePhone target/scheduler/lifecycle
  -> USB iPhone

Future pulse integration
  -> PulsePhone public high-level API, or
  -> pulse-owned legacy driver path explicitly selected by product mode
```

核心依赖方向：

```text
Phone Use semantics
        |
        v
MCP protocol adapter
        |
        v
PulsePhone public Agent API
        |
        v
PulsePhone product/runtime/device access

pulse ---------------------> optional future integration boundary
```

禁止反向依赖：

```text
PulsePhone core  -X-> MCP server implementation
PulsePhone core  -X-> Agent vendor/client
MCP              -X-> PulsePhone private Helper/Wire
Phone Use        -X-> device transport
pulse            -X-> PulsePhone private Runtime state
```

## 4. 能力所有权

| 能力 | PulsePhone | MCP | Phone Use | pulse |
| --- | --- | --- | --- | --- |
| USB 设备访问 | owner | no | no | existing independent stack |
| GUI live preview | owner | no | product consumer concept | future optional integration |
| PulsePhone CLI | owner | no | no | optional caller |
| 设备 target safety | owner | must preserve | requires correct target | owns its existing path |
| PulsePhone command scheduling | owner | no | no | no |
| Developer Support / DDI acquisition and preparation | owner | no | consumes released capability only | owns its existing independent path |
| MCP tool protocol | future provider API only | owner | defines semantic needs | optional client |
| Agent action semantics | exposes supported subset | adapts | owner | optional consumer |
| WebDriver/sib automation | no first-stage ownership | no | no | owner |
| ActionLog/Trace/Diagnostics | owner | exposes allowed projection | consumes semantic history | owns its existing logs |
| 发布能力证据 | owner for PulsePhone | cannot enlarge | cannot enlarge | owner for pulse claims |

## 5. 第一阶段目标

第一阶段只闭合 PulsePhone 独立产品：

```text
macOS 14+ / Apple Silicon
  -> signed app bundle with GUI + canonical CLI
  -> USB iPhone discovery and target safety
  -> iOS 17+ modern control capability
  -> iOS 14...16 legacy direct subset
  -> transparent Developer Support acquisition, cache and device preparation
  -> per-device Runtime coordination
  -> video/audio preview and input
  -> logs, diagnostics, release evidence
  -> clean-machine packaging and stability verification
```

第一阶段交付关系：

```text
PulsePhone                  implement and verify
MCP                         no implementation dependency
Phone Use                   retain as future product model
pulse                       unchanged
```

第一阶段明确不做：

- 不实现或发布 MCP server。
- 不公开 PulsePhone Agent API。
- 不改造 pulse 或迁移 pulse 现有用户。
- 不让 Phone Use 成为 PulsePhone 内部执行抽象。
- 不为未来集成提前开放绕过 CLI/GUI 产品合同的隐藏入口。
- 不承诺元素识别、语义 UI 自动化或完整录制回放。

## 6. 后续阶段

```text
Stage 1  PulsePhone standalone
  -> PRD/TRD implementation
  -> device, packaging, stability and release evidence

Stage 2  PulsePhone public Agent API
  -> freeze high-level action/result schema
  -> reuse the same target, scheduler and lifecycle
  -> no private Runtime/Helper exposure

Stage 3  MCP adapter
  -> map Phone Use semantics to released PulsePhone capabilities
  -> expose tools/resources to MCP clients
  -> add protocol-level cancellation and quotas

Stage 4  pulse integration
  -> evaluate iOS 17+ PulsePhone provider mode
  -> evaluate legacy external-driver cooperation
  -> keep ownership and result semantics explicit

Stage 5  advanced Phone Use
  -> task history, recording/replay and richer Agent observation
  -> only after underlying capability evidence exists
```

每个阶段都必须重新确认：

- 哪个模块拥有目标设备和执行状态。
- 哪个接口是公开稳定合同。
- 错误、取消、重试和结果未知由谁解释。
- 新能力是否具有真实设备和发布证据。
- 是否引入重复 queue、重复 Runtime 或平行事实源。

## 7. 生态级不变量

```text
1. PulsePhone 是其设备访问链路的唯一 owner。
2. MCP 和 Phone Use 永远通过 PulsePhone 公开高层接口调用。
3. future API、GUI 和 CLI 复用同一 target safety 和执行语义。
4. pulse 第一阶段保持独立；未来集成不共享私有状态。
5. 上层语义不得扩大底层 released capability。
6. 任一模块失败都不能导致控制错误设备或显示错误设备画面。
7. 每项公开能力必须能追踪到产品合同、工程合同和发布证据。
```
