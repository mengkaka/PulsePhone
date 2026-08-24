# PulsePhone Deferred Validation

本文档是 PulsePhone 当前暂缓验证事项的唯一状态台账。它记录尚未观察到产品失败，但由于设备、主机、权限、人工配合、外部凭据或可选交付配置未激活而不能完成的验证。

本文档不替代 PRD、TRD、测试定义或历史证据。PRD/TRD继续定义必须验证什么；本文只说明当前为什么没有执行、何时恢复以及未执行会限制哪些声明。

## 1. 与 Observed Issues 的边界

```text
尚未执行，不能判断通过或失败
  -> DEFERRED_VALIDATION.md

已经复现失败或存在可信失败证据
  -> OBSERVED_ISSUES.md
```

暂缓项条件满足后，不得直接移动成Observed Issue。正确流程为：

```text
deferred -> ready -> verifying
  +-> verified                   # 验证通过，不创建OBS
  `-> convertedToIssue           # 验证失败，创建或关联OBS
```

命中本文件中的精确场景时，Agent可以跳过该次验证并继续其他可执行工作，但必须保持`notTested`事实，不得标记通过、删除合同、扩大`actuallyVerified`或声称相应设备/环境受支持。

## 2. 状态定义

| 状态 | 含义 |
| --- | --- |
| `deferred` | 前提尚不具备，当前不执行。 |
| `ready` | 激活条件已经满足，可以领取验证。 |
| `verifying` | 正在按PRD/TRD执行验证。 |
| `verified` | 验证通过，已记录精确环境、结果和证据。 |
| `convertedToIssue` | 验证失败，已经创建或关联`OBSERVED_ISSUES.md`条目。 |
| `retired` | PRD/TRD经正式变更删除了该要求或支持声明。 |

只有`verified`和`retired`是关闭状态。`deferred`不是通过，`convertedToIssue`必须由对应OBS继续闭环。

## 3. 当前索引

| ID | 暂缓验证 | 范围 | 状态 | 激活条件 |
| --- | --- | --- | --- | --- |
| `DV-001` | Apple notarization与外部分发凭据 | Optional High-Assurance / external distribution | `deferred` | owner明确激活外部分发并授权可用notary credential |
| `DV-002` | clean macOS、可搬移安装与无开发环境运行 | Optional High-Assurance | `deferred` | 提供可重置clean macOS 14 arm64主机或VM |
| `DV-003` | 两台并发USB iPhone与错目标安全矩阵 | Optional High-Assurance / target safety extension | `deferred` | 至少两台设备可稳定同时连接并允许执行受控多设备场景 |
| `DV-004` | legacy、iOS 17.x与broad OS exact-build矩阵 | Optional High-Assurance / compatibility extension | `deferred` | 对应设备在执行窗口可用；broad claim具备固定lower/intermediate/upper slots |
| `DV-005` | 依赖许可证、Developer Support source/use与TSS授权审查 | External distribution | `deferred` | authorized owner完成exact material/use-scope审查和attestation |
| `DV-006` | Camera、Microphone、Input Monitoring完整TCC重置矩阵 | Optional High-Assurance | `deferred` | 提供允许重置TCC的账号、主机或VM snapshot |
| `DV-007` | approved source、TSS、online/offline/cache-hit受控网络矩阵 | Optional High-Assurance | `deferred` | 提供受控网络、egress和真实Apple/source访问窗口 |
| `DV-008` | 性能三轮baseline、阈值批准与freeze | Optional High-Assurance | `deferred` | final candidate/scope稳定并由owner批准machine-generated threshold template |
| `DV-009` | durable EvidenceStore、release flow、retention与hold | Optional High-Assurance | `deferred` | owner激活高保障流程并重新确认或提供受控store、容量和保留策略 |
| `DV-010` | 实体USB detach/reconnect、重启与Stream generation连续性 | Extended device validation | `convertedToIssue` | 实体detach/reattach已失败并创建`OBS-016`；由该OBS继续闭环 |
| `DV-011` | rare orientation reachability | Extended GUI validation | `deferred` | 目标App/设备可稳定到达对应方向 |
| `DV-012` | Alpha/Beta/Formal长时运行、重复拔插和最终发布证据 | Optional High-Assurance | `deferred` | owner显式激活完整profile且`DV-001～009`所需前提满足 |
| `DV-013` | 完整实体command、text与IPA oracle矩阵 | Extended device validation | `deferred` | 对应设备、可控前台状态、测试文本和测试IPA在集中窗口可用 |
| `DV-014` | 不同显示器缩放与window chrome/min-width组合 | Extended host display validation | `deferred` | 提供明确的显示器、scale和窗口chrome组合 |
| `DV-015` | OmniParser增强协议、资源与大样本端到端矩阵 | Element external service validation | `deferred` | baseline `/parse/` 由OBS-028实现；owner激活未来版本化协议、资源和大样本验证 |
| `DV-016` | Element批准数据集、Apple private分发与跨主机资源矩阵 | Element release/accuracy validation | `deferred` | owner批准真实数据集和隐私流程，并提供目标macOS主机矩阵、分发决定及受控资源场景 |
| `DV-017` | Go helper 迁移的能力与外部分发闭环 | Python-to-Go P0/P1 package closure | `deferred` | 提供受控签名IPA/profile、legacy/modern设备、personalized资产/TSS窗口、实体reconnect与外部分发环境 |

## 4. 暂缓项

### DV-001 Apple notarization与外部分发凭据

- 合同引用：PRD交付范围；TRD 08 §35～§36、§42；`OPTIONAL_HIGH_ASSURANCE_VALIDATION.md` §4。
- 历史来源：已封存TODO `EXT-001`、`M3-009`。
- 当前原因：默认产品交付不要求Apple notarization；当前没有记录已授权给Agent使用的notarytool credential。
- 允许跳过：notary submission、staple、Gatekeeper外部分发闭环。
- 不得声明：不得称当前产物已经完成Developer ID外部分发、公证或最终Formal Release。
- 通过条件：对exact candidate完成签名、公证、staple、Gatekeeper和byte identity验证并保存允许的证据。

### DV-002 clean macOS、可搬移安装与无开发环境运行

- 合同引用：PRD §19；TRD 08 §35、§40～§42；Optional profile §4～§5。
- 历史来源：已封存TODO `EXT-002`、`M3-011`、`M3-015`、`M3-020`。
- 当前原因：开发主机不能替代可重置clean macOS 14 arm64环境。
- 允许跳过：clean install、upgrade、`/Applications`、用户目录、含空格路径、no-Xcode/empty-cache和TCC-reset组合。
- 不得声明：不得把开发机或source-tree测试扩大成clean-machine兼容性。
- 通过条件：exact packaged candidate在clean host上不依赖Homebrew、system Python、开发venv、caller cwd或未声明本机状态完成规定矩阵。

### DV-003 两台并发USB iPhone与错目标安全矩阵

- 合同引用：PRD target safety；TRD 06 target/source binding；TRD 08 `T-001`。
- 历史来源：私有归档仓库中的 `EXT-003` 历史记录与设备盘点。
- 当前原因：历史执行中曾短暂同时观察到两台wired iPhone，但没有形成稳定可重复的两台并发实体oracle；设备曾被枚举不等于多设备场景已经验证。
- 允许跳过：同名、并发、source/control交叉、detach一台后另一台持续工作的实体矩阵。
- 不得声明：不得声称多设备实体安全已验证；模型/进程测试不能替代实体结果。
- 通过条件：至少两台USB iPhone上证明canonical UDID、视频source、Runtime和input始终同目标，错误或歧义时fail closed。

### DV-004 legacy、iOS 17.x与broad OS exact-build矩阵

- 合同引用：PRD兼容范围；TRD 03 Developer Support；TRD 08 `T-004`、`T-005`、`T-021`。
- 历史来源：私有归档仓库中的 `EXT-004`、`M3-019` 历史记录与 2026-07-17 设备快照。
- 当前原因：2026-08-02 已在 iOS 16.3.1 (`20D67`) 上使用 exact approved catalog entry 和
  selected Xcode `DeviceSupport/16.1` 完成 classic prepare ready/alreadyReady、真实 screenshot PNG 与
  DVT launch 正向闭环；`OBS-023` 已关闭。iOS 14.4.2 (`18D70`) 仍没有 exact approved 14.4 DDI，
  因而Developer Support范围只完成 classic route 与 typed unavailable 负向验证；同一exact build已
  完成不依赖DDI的Installation Proxy卸载、缺失错误和恢复安装闭环。iOS 17.x boundary/intermediate
  和完整lower/intermediate/upper range slots仍未提供。iOS 26.5.2 (`23F84`) 已完成modern prepare、
  screenshot、launch及相同卸载/恢复安装对照，但不能替代上述缺失槽位。
- 允许跳过：未提供device/build的physical command、DDI和broad range验证。
- 不得声明：只允许声明实际记录的 exact device/OS build/capability；iOS 16.3.1 的正向结果不得
  外推全部 legacy 范围，iOS 14.4.2 的 typed unavailable 也不能改写成正向通过；iOS 26.5.2 结果
  不得外推整个`iOS 17+`范围。
- 通过条件：按目标claim建立固定lower/intermediate/upper exact-build证据；验证失败时创建对应OBS，设备缺失继续保持`deferred`。

### DV-005 许可证、Developer Support source/use与TSS授权审查

- 合同引用：PRD分发范围；TRD 08 §35.2～§35.3、`T-003`、`T-019`～`T-021`。
- 历史来源：已封存TODO `EXT-005`、`M3-010`、`M3-020`。
- 当前原因：GPL/source availability、approved Developer Support source/use和TSS egress需要authorized owner作精确材料审查，Agent不能自行给出法律授权结论。
- 允许跳过：外部分发legal attestation和依赖材料最终批准。
- 不得声明：不得声称许可证、再分发权、Developer Support来源或TSS使用已经获得法律批准。
- 通过条件：authorized owner对exact component/version/hash/use scope形成可审计决定；真实产品失败另建OBS。

### DV-006 Camera、Microphone、Input Monitoring完整TCC重置矩阵

- 合同引用：PRD live权限降级；TRD 06 GUI/TCC；TRD 08 `T-008`。
- 历史来源：私有归档仓库中的 `EXT-006`、`M3-015` 历史记录与签名/TCC 证据。
- 当前原因：当前开发账号的既有授权可以验证正常路径，但不能替代可重复的deny/revoke/regrant和clean attribution矩阵。
- 允许跳过：当前不可重置TCC状态下的deny、revoke、regrant和迁移组合。
- 不得声明：不得把一次authorized状态扩大成所有TCC生命周期已验证。
- 通过条件：在签名身份稳定的packaged app上分别验证Camera、Microphone、Input Monitoring的notDetermined/denied/authorized/revoked及重启投影。

### DV-007 approved source、TSS与受控网络矩阵

- 合同引用：TRD 03 §14～§17；TRD 08 §35.3、`T-019`～`T-021`。
- 历史来源：已封存TODO `EXT-007`、`M3-020`。
- 当前原因：缺少可重复控制的online、offline、cache-hit、selected-Xcode、TSS和source-egress环境。
- 允许跳过：当前无法机械建立的网络分支与外部服务状态。
- 不得声明：不得把一次成功下载或现有cache扩大成完整online/offline/TSS支持。
- 通过条件：按exact catalog/source/hash和egress allowlist执行成功、失败、offline、cache与完整性矩阵。

### DV-008 性能baseline、阈值批准与freeze

- 合同引用：PRD性能边界；TRD 08 §37、`T-018`。
- 历史来源：已封存TODO `EXT-008`、`M3-012`、`M3-014`～`M3-016`。
- 当前原因：默认交付只要求有界诊断，不预填发布SLA；正式threshold必须基于final candidate/scope和三轮可比baseline，由owner批准。
- 允许跳过：高保障性能阈值、freeze和Formal cohort判定。
- 不得声明：不得把deadline、单次样本或Agent选择的数字称为发布性能SLA。
- 通过条件：tool生成完整scope/rule模板，三轮valid baseline同candidate可比，owner批准阈值并完成freeze验证。

### DV-009 durable EvidenceStore、release flow、retention与hold

- 合同引用：TRD 08 §36～§42；Optional profile §4～§7。
- 历史来源：已封存TODO `EXT-009`、`M3-013`～`M3-017`；历史`PulsePhoneEvidenceStore`尝试。
- 当前原因：历史外部root/binding曾被配置并用于旧M3 attempt，但当前没有激活的新release flow，也没有重新确认其容量、备份、retention owner、长期只读解析和最终hold/publication条件。默认交付不要求继续维护该store。
- 允许跳过：Alpha/Beta/Formal store、selection、WAL、hold、final dist lineage。
- 不得声明：不得把仓库`build/`、临时目录或历史store记录当作当前Formal Release证据。
- 通过条件：新flow从第一条记录起使用同一可解析durable binding，并完成retention、hold、fetch、validation和最终dist byte identity。

### DV-010 实体USB detach/reconnect、重启与Stream generation连续性

- 合同引用：PRD lifecycle/recovery；TRD 04、TRD 06；TRD 08 `T-001`、`T-007`、`T-020`、`T-021`。
- 历史来源：`OBS-007`已完成默认范围的generation/service/cleanup修复；其USB detach/reconnect关闭场景此前保持`notTested`。
- 转换记录：2026-07-27 owner提供实体拔插窗口后，packaged Live在detach/reattach中恢复了新AVFoundation source epoch，但Runtime没有建立新connection epoch或Helper generation；GUI pointer以`geometryUnavailable`失败，CLI swipe以`capabilityUnavailable`失败，旧Helper成为defunct且manifest停留在旧记录。
- 当前归属：已创建High `OBS-016`承接Runtime USB monitor、epoch、Helper lifecycle、GUI/CLI control恢复、自动化和至少三次实体reconnect闭环。本条保持`convertedToIssue`，不再作为允许跳过的未执行验证。
- 剩余边界：设备reboot/remount尚未单独执行；只有`OBS-016`关闭后仍未提供该额外场景时，才可创建更窄的新Deferred Validation，不得用它隐藏已经确认的detach/reattach失败。

### DV-011 rare orientation reachability

- 合同引用：PRD live geometry；TRD 06 §26～§27；TRD 08 `T-006`、`T-014`。
- 历史来源：`OBS-006`已完成默认portrait/landscape/fullscreen/windowed实体闭环；Reachability、不可达upside-down和额外显示器缩放此前保持`notTested`。
- 当前原因：方向是否可达取决于iOS和前台App，当前没有稳定覆盖Reachability或等价App中的全部实际可达/不可达方向。
- 允许跳过：当前目标App不能稳定进入的orientation。
- 不得声明：不得把portrait和两个landscape结果扩大成所有App和所有方向。
- 通过条件：在可控App/设备中验证reachable与unsupported分支、窗口恢复和current geometry输入；失败时重新打开`OBS-006`或创建更精确OBS。

### DV-012 Alpha/Beta/Formal长时与最终发布证据

- 合同引用：TRD 08 §36～§42；`OPTIONAL_HIGH_ASSURANCE_VALIDATION.md`。
- 历史来源：已封存TODO M3 owner-activated branch和历史M3-013 attempts。
- 当前原因：该profile从未被owner重新显式激活；完整流程同时依赖设备、主机、凭据、网络、threshold和durable store。
- 允许跳过：30分钟+5次、2小时+20次、8小时+50次x3以及最终release hold/publication。
- 不得声明：不得把Default Product Delivery称为External Beta、Formal Release或完整高保障验证通过。
- 通过条件：owner明确激活新profile和scope，建立新的执行计划/Goal，并从clean candidate按当前TRD重新运行；不得恢复已封存TODO或拼接历史失败attempt。

### DV-013 完整实体command、text与IPA oracle矩阵

- 合同引用：PRD Product Action矩阵；TRD 06 §25～§27；TRD 08 `T-006` device-command和text/IPA实体cases。
- 历史来源：默认交付已经对当前iPhone闭合核心live、pointer、keyboard和部分toolbar/CLI动作，但没有把全部22-row实体command oracle作为同一current candidate完整运行。
- 当前原因：完整矩阵需要受控设备前台状态、可观察结果、测试文本、测试bundle/IPA和集中人工观察；当前未作为默认交付硬门槛执行。
- 当前精确范围：`OBS-017`已在source `dfe7c8d`的fresh packaged candidate上用受控unsigned IPA完成CLI与GUI的AFC/InstallationProxy committed rejection矩阵；`OBS-024`进一步在source `7bacda5`上使用受控签名IPA，于iOS 14.4.2 (`18D70`)和iOS 26.5.2 (`23F84`)完成`app.install`成功、`app.uninstall`成功、`appNotInstalled`及恢复安装oracle。其余公开command row和其他exact-build组合仍未作为同一current candidate完整执行。
- 允许跳过：本条尚未具备前提的未执行command row；已经确认失败的`OBS-004`、`OBS-008`、`OBS-009`、`OBS-010`绝不能借本条跳过。
- 不得声明：不得把部分toolbar/CLI实体成功扩大成所有公开Product Action均已完成实体oracle。
- 通过条件：对exact candidate逐row记录app前置状态、提交结果、实体设备业务结果、cleanup和exact device/OS build；`app.install`成功行必须使用受控签名IPA并记录真实bundle ID及安装结果；真实失败创建或关联OBS。

### DV-014 不同显示器缩放与window chrome/min-width组合

- 合同引用：PRD live窗口与geometry；TRD 06 §27；TRD 08 `T-014`。
- 历史来源：`OBS-002`、`OBS-006`已在当前主显示环境闭合默认画布、toolbar和fullscreen行为，其他显示器缩放组合保留为剩余风险。
- 当前原因：未提供一组冻结的外接显示器、Retina/non-Retina scale、菜单栏/Dock和window chrome组合。
- 允许跳过：未列入当前可用主机环境的精确显示器/scale组合。
- 不得声明：不得把当前主显示器结果扩大成所有显示器和缩放配置。
- 通过条件：先冻结具体组合，再验证initial reservation、minimum width、resize、fullscreen exit和方向变化；失败时重新打开相关OBS或创建更精确OBS。

### DV-015 OmniParser增强协议、资源与大样本端到端矩阵

- 合同引用：PRD §8.9、§15.4；TRD 09 §45、§48。
- 当前原因：当前部署的 `/parse/` baseline 已真实可用，其客户端接入、timeout/disconnect/malformed/cap
  和 packaged 单页成功路径属于 `OBS-028` 的普通实现与关闭条件，不再由 Deferred Validation 跳过。
  服务尚未提供可协商的 versioned detector-only 增强协议和稳定 model/version/preprocess/confidence
  metadata；owner 也尚未激活 100 页批准数据集、MPS memory pressure、CPU fallback、模型 preload、
  资源争用和完整 screenshot egress release Gate。
- 允许跳过：未来增强协议的成功/回退矩阵、MPS/CPU/model preload 资源矩阵，以及至少 100 页
  ground-truth precision/recall/IoU/tap-error/latency Gate。不得跳过 baseline `/parse/` 的实现、自动化、
  当前 endpoint 请求、packaged 单页验证或已观察到的协议/几何失败。
- 不得声明：不得把 baseline 单页成功、mock enhanced protocol、Vision/Apple 成功或历史 benchmark
  扩大成未来增强协议、固定模型版本、跨页面精度、资源稳定性或 release readiness 已验证。
- 通过条件：owner 激活后，服务实现并冻结 exact enhanced probe/request/response 与 model/version/imgsz，
  exact PulsePhone candidate 完成协商成功/回退、MPS/CPU/recovery、至少 100 页精度与延迟，以及隐私、
  NOTICE/SBOM/许可和 cleanup Gate；失败时创建对应 OBS。

### DV-016 Element批准数据集、Apple private分发与跨主机资源矩阵

- 合同引用：PRD §8.9、§15.4；TRD 08 §35～§42；TRD 09 §44～§48。
- 当前原因：当前只有不含真实页面内容的 synthetic fixtures、单一开发主机和单一 iOS 26.5.2
  设备；owner 尚未批准至少 100 页真实页面数据集、对应的截图/OCR 隐私处理与保留流程，也未冻结
  Apple private framework 的目标 macOS 版本、签名/分发决定或可重复的 memory/CPU/GPU/energy
  压力环境。现有 Vision/Apple 真机成功和单页历史样本不能替代泛化准确率或发布评审。
- 允许跳过：未获批准数据上的多语言、主题、Dynamic Type、横竖屏和 App 类型准确率；Apple private
  framework 跨 macOS compatibility、assets-empty、memory pressure、签名与分发 Gate；Vision privacy
  attestation；Live/no-Live、多设备、analyzer 组合的 CPU/GPU/ANE/memory/energy 竞争矩阵；锁屏、权限
  弹框、DRM/secure surface 与隐私遮挡等需要受控页面或人工配合的实体场景。
- 不得声明：不得把 synthetic evaluator、单机 warm timing、当前 App Switcher/输入焦点验证或动态加载
  private framework 的开发包扩大成跨 App 精度、发布 SLA、Apple private 可分发或受限页面支持。
- 通过条件：owner 先批准数据来源、ground truth、隐私/保留流程、目标 host/device scope 和 Apple
  private 分发决定；随后对 exact candidate 完成至少 100 页 precision/recall/IoU/tap-error/correction
  Gate、跨主机 compatibility、受控资源竞争/恢复、特殊页面 side-effect/privacy、NOTICE/SBOM 和 cleanup
  验证。涉及 OmniParser 服务成功路径的子矩阵还必须先满足 `DV-015`；失败时创建对应 OBS。

### DV-017 Go helper 迁移的能力与外部分发闭环

- 状态：`retired`（2026-08-24）。
- 结论：Go Runtime/Helper 已替代产品包中的 Python runtime/helper；iOS 14.4.2、iOS 16.3.1 与 iOS 26.5.2 的
  owner-approved 实体范围和 Dynamic Developer Image Catalog source precedence 已完成验收。迁移差分 corpus 仅作为
  历史证明，不再是当前产品验证入口。
- 边界：签名/notary与 clean host 仍由 `DV-001`/`DV-002` 管理；扩展 OS 矩阵由 `DV-004` 管理；source/license/TSS
  授权由 `DV-005`/`DV-007` 管理；完整签名 IPA oracle 由 `DV-013` 管理。本条不会将这些独立事项扩大为已通过。
- 历史：详细迁移证据、Python baseline 与差分记录保留在私有归档仓库的 Git 历史和 Python baseline/release tags 中。

## 5. Agent 查询与更新规则

1. 开始任何实体、环境或发布验证前，先按ID、合同引用、设备/OS、主机和场景匹配本文件。
2. 只有精确命中`deferred`且激活条件未满足时才能跳过；相邻场景、普通实现工作和已经观察到的失败不能借此跳过。
3. 条件满足时先改为`ready`，随后执行验证。通过后记录日期、commit/candidate、精确环境、结果和证据，改为`verified`。
4. 验证失败时先保存可信证据，再创建或关联OBS并改为`convertedToIssue`。不得把真实失败恢复成`deferred`或`notTested`。
5. PRD/TRD改变要求时同步更新合同引用；只有合同正式删除该义务时才能改为`retired`。
6. 新增暂缓项必须是尚未确认失败的验证场景。复杂但已确认的问题属于`OBSERVED_ISSUES.md`的`deferred`状态。

## 6. 当前结论

Default Product Delivery的上一阶段实施台账已经封存。本文所有当前条目均不自动阻塞普通OBS修复循环，但会限制相应设备、环境、高保障或外部分发声明。主Agent在没有可执行OBS时，应报告仍存的`deferred`范围，不得把它们静默计为产品无风险或验证通过。
