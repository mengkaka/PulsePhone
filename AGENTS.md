# PulsePhone Agent 执行指南

## 适用范围

本文件定义 `PulsePhone/` 仓库内长期稳定的 Agent 执行规则。不要把会持续变化的任务进度、设备状态、进程 ID 或临时 blocker 写入本文件。

## 事实来源

- 产品和工程合同：`docs/pulsephone-prd.md`、`docs/pulsephone-trd.md` 和 `docs/pulsephone-trd/*`。
- 阶段和生态边界：`docs/pulsephone-ecosystem-architecture.md`。
- 已确认的真实产品问题、优先级、修复要求和当前闭环证据：`docs/OBSERVED_ISSUES.md`。
- 因设备、环境、人工前提或可选配置未激活而暂缓的验证：`docs/DEFERRED_VALIDATION.md`。
- 历史实施生命周期兼容数据：`Verification/implementation-lifecycle.v1.json`；它只供验证工具读取，不是当前任务入口。
- 可执行验证规则：PRD/TRD、registry/schema、`Fixtures/`、`Verification/`、测试与构建脚本。
- 实际实施状态：当前代码、Git 历史与 worktree、测试、打包产物和已记录证据。

历史会话和上下文压缩摘要只是恢复工作的线索，不是长期权威事实。它们与仓库中的更新事实冲突时，应依据上述事实来源和用户最新的明确指令重建当前状态。

## 恢复与执行

- 每次恢复任务时，首先检查`git status --short`、最近提交、当前代码/产物/测试状态、`docs/OBSERVED_ISSUES.md`的非`resolved`条目与相关`docs/DEFERRED_VALIDATION.md`场景。
- 默认从严重度最高、依赖已经满足且状态为`open`或`investigating`的最小OBS ID继续；已经有可信下一动作时不要重新启动全项目审计或重复已闭环工作。
- `deferred` OBS是已经确认但由owner明确延期的问题，恢复条件满足前跳过；它不是`resolved`。Deferred Validation是尚未确认失败的验证场景，不能代替或隐藏OBS。
- 需要多步实施时，在当前OBS内记录计划、依赖、提交、验证和唯一下一动作；历史实施记录从私有归档 Git 历史读取。
- 修复前读取OBS引用的PRD/TRD。若问题暴露合同缺失或需要改变用户可见行为，先提交PRD/TRD变更；若实现只是偏离现有合同，直接按合同修复并补测试。
- 保留无关的现有改动。不得使用破坏性 Git 操作或文件系统清理来简化 worktree。
- 除非用户明确激活，Optional High-Assurance Validation 和外部发布流程始终保持未激活。

## 多 Agent、Worktree 与临时 Todo

新 session 默认处于只读/讨论模式。不要假设用户一开始聊天就是开发任务；在出现明确变更触发条件之前，只能读取、分析、解释、讨论或汇总已有信息，不创建 feature worktree，不创建`TEMP_*_TODO.md`，也不修改仓库文件。

变更触发条件包括：

- 用户明确要求实现、修复、修改、重构、补测试、更新文档、创建临时 todo、提交、合并或跑会改变仓库状态的实验。
- 用户把已讨论的新需求确认进入开发阶段，例如“开始做”“按这个方案实现”“创建todo然后执行”。
- agent 已经需要写入、删除或移动仓库文件才能继续完成用户目标。

一旦命中变更触发条件，当前 session 转为变更任务。变更任务必须先从当前集成分支创建独立 feature branch 与独立 worktree，再创建临时 todo 或修改文件。若用户只是查询现有业务、解释代码、分析历史、审查方案、监听或汇总其他 agent 进度，则保持只读/讨论模式。

变更任务的标准流程：

1. 以当前集成分支作为 base，除非用户明确指定其他 base。
2. 创建独立 feature branch，命名为`codex/<short-task-slug>`；不得让多个 agent 在同一分支或同一 worktree 并行修改。
3. 在仓库同级目录创建独立 worktree，例如`../PulsePhone-<short-task-slug>`，并在该 worktree 内完成后续开发。
4. 进入 feature worktree 后，才允许创建`docs/TEMP_<TASK>_TODO.md`或`TEMP_<TASK>_TODO.md`；临时 todo 只属于当前 feature worktree，不得提交。
5. feature worktree 内应先运行与当前功能相关的最小必要测试；涉及OBS或产品闭环时，按对应合同和验证文档完成更高层级验证。
6. 任务完成前必须删除临时 todo，确认`git status --short`没有意外文件，然后提交需要保留的实现、测试和文档改动。
7. 回到集成分支所在 worktree，确认当前分支正确，优先使用`git merge --ff-only <feature-branch>`合并；不能fast-forward时，先明确差异来源，再rebase或普通merge。
8. 合并成功后删除对应 feature worktree，再在集成分支 worktree 中运行完整构建：`make build`。需要完整验证或OBS关闭时，继续运行`make check`以及任务要求的packaged/实体设备验证。
9. 合并后构建通过，才可声明集成分支构建产物已更新；构建失败时不得声明任务完成，应修复失败或记录明确blocker。

## 问题循环

1. 从`OBSERVED_ISSUES.md`领取一个可执行问题，并确认其状态、严重度、合同引用、原因判断和关闭标准仍与当前代码一致。
2. 查询`DEFERRED_VALIDATION.md`。只有精确场景命中且激活条件未满足时，才把该验证记录为`notTested`并继续其他工作；已观察到的失败、当前可做的代码修复和自动化回归不得跳过。
3. 完成必要的合同更新、实现、自动化、packaged入口和当前可用实体设备验证。组件/model结果不能替代问题要求的production结果。
4. 每个阶段及时更新同一OBS的状态、日期、提交、证据、剩余风险和唯一下一动作。已确认但主动延期时使用`deferred`并记录风险与恢复条件。
5. 在开始调查、确认根因、形成合同/源码提交、完成关键验证、关闭/延期/阻塞等重要checkpoint后，更新对应OBS并关联精确提交、测试或设备证据。
6. 发现非显然、可重复、可能导致返工的机制时，将稳定结论写入 owning PRD/TRD、代码 guard、测试或当前OBS；普通测试失败和一次性操作不建立独立历史日志。
7. 全部关闭标准满足后才标记`resolved`。只剩未提供环境的附加验证时，将该精确场景移入Deferred Validation，不让已修复问题长期保持`open`。
8. 重复以上循环，直到没有`open`或`investigating`问题。此时仍须分别报告`deferred` OBS和Deferred Validation，不得把它们计为通过。

## 记录边界

- `OBSERVED_ISSUES.md`持有问题当前状态、当前可执行队列和未关闭问题的完整闭环记录；resolved条目只保留必要关闭摘要，避免主队列无限扩展。
- 稳定行为、错误边界和验证规则必须进入 owning PRD/TRD、registry/schema、代码或测试；不要维护并行的实现时间线、陷阱日志或任务台账。
- 需要追溯被替代的方案、执行过程或历史证据时，查询私有归档仓库的 Git 历史。

## 验证与证据

- 优先使用测试、CLI 输出、日志、结构化状态和可持久证据，避免重复视觉检查。
- 当任务要求打包产品或实体设备验收时，代码审计或组件测试不能单独构成完成证明。
- 在 `docs/OBSERVED_ISSUES.md` 中的所有闭环条件完成并留下记录之前，不得将问题标记为 `resolved`。
- Deferred Validation验证通过时记录exact candidate/commit、环境和证据并标记`verified`；验证失败时创建或关联OBS并标记`convertedToIssue`，不得把真实失败改回`deferred`或`notTested`。
- 只能按照仓库验证和隐私约定保存或引用截图；在现有任务或证据文档中记录相关路径/哈希、观察结果、结论和下一动作。

## Computer Use 与图片

- 只有在结构化工具或现有证据无法可靠确认所需事实时，才使用 Computer Use。
- 保持截图差分功能开启。除了某一次必须获取完整画面的独立诊断外，不得设置 `disableDiff: true`。
- 不得通过 `nodeRepl.emitImage(...)` 重复输出相同或未变化的完整截图。对同一画面只检查一次，尽可能使用相关区域裁剪，并将结论持久化为文本。
- 不得为了轮询未变化的状态而循环捕获完整画面。如果存在结构化状态，应使用有界轮询。
- 完成图片密集的验收步骤后，应先在现有任务、问题或证据记录中写入结果和唯一下一动作，再继续执行。

## 上下文管理

- 用户可见和内部执行指令应保持简洁。引用仓库文档，不要重复其正文。
- 将需要长期保留的决策、问题状态和证据写入对应OBS；将稳定行为和防回归规则写入其 owning PRD/TRD、代码或测试，不依赖会话记忆。
- 不要仅为重复这些规则而中断当前 Goal。除非确实需要用户输入，应静默应用它们并继续执行。

## 完成声明

- “当前可执行问题已处理”要求没有`open`或`investigating` OBS，但可以明确列出尚未恢复的`deferred` OBS和Deferred Validation。
- “产品没有已知问题”要求所有OBS均为`resolved`，不能遗留`deferred`、`notReproduced`或未归档的可信失败。
- “完整验证完成”还要求当前承诺范围内的Deferred Validation均为`verified`或经PRD/TRD正式变更为`retired`；可选高保障条目只有owner明确激活后才属于该声明范围。
