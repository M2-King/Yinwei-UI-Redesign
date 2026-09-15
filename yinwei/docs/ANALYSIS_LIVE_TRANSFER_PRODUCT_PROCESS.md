# 分析：Live Transfer 持续失败 — 产品与过程视角

> **性质**：产品排序 / 验收门禁 / 范围冻结建议。不改代码、不含实现计划。  
> **背景文档**：[`IMPLEMENTATION_FLOATING_ISLAND.md`](./IMPLEMENTATION_FLOATING_ISLAND.md)、[`IMPLEMENTATION_PHASES.md`](./IMPLEMENTATION_PHASES.md)  
> **用户判断（本稿采纳为正确方向）**：方向做反了——应先完善窗口端（Full）功能，不应把未验证/不成熟能力直接放到新兴灵动岛上。

---

## 1. 结论：排序做错了

Live Transfer「一直调不通」的主因，不是单点技术债，而是**把未验证的系统音频管线（SMTC + WASAPI loopback → HRTF）绑在了尚未站稳的 Island 壳上**。

正确顺序应是：

1. **Full 窗口**把「听得见的 Spatial / HRTF」做到可重复验收  
2. **Full 窗口**再把「系统环回 → HRTF」做到可 A/B 对比验收  
3. **最后**才把已验证能力缩进 Island 的 chrome / 紧凑 UI

实际发生的是反向：Island（P2.6）刚合入、验收清单仍大量未勾，就叠上 SMTC 元数据、视觉 LIVE、WASAPI 真实 Transfer、再到 Full 监视条——**壳与管线同时未成熟，故障面互相放大**。

---

## 2. 已交付 vs 已证明

| 层 | 文档/产品上「像做完了」 | 真正该证明的 | 常见误判为 Done |
|----|------------------------|--------------|-----------------|
| Island chrome | Full ↔ Island 模式机、无边框、置顶、click-through、DPI | 播放中切换 ≥20 次不中断；点透与回 Full 稳定 | HWND / 布局能切 = Island Done |
| SMTC | 常驻 daemon、标题/艺人、READY 不卡 5–15s | 元数据稳定且与「是否在播」语义一致 | 标题对上 = 媒体会话就绪 |
| 视觉 LIVE | az 环、字幕 `HRTF LIVE · pid · az` | 与真实湿声方位一致、可重复 | UI 在动 = Transfer 在工作 |
| WASAPI live HRTF | `真实Transfer`、源会话静音、loopback→HrtfStreamer→cpal | **耳机里听得见**湿声；关 Transfer 可回干声；无双声/爆音/静默 | 点了按钮 + 字幕出现 = Transfer Done |
| Full 监视条 | 状态可见、与 Island 信息对齐 | Full 上同一管线可独立复现与对比 | 条上有 LIVE = 管线成熟 |

**「Done」被误定义成了：检测通了 / UI 亮了 / 文案对了。**  
产品级 Done 必须是：**可听、可关、可 A/B、可在 Full 单独复现**。视觉 LIVE 与 SMTC 是辅助信号，不能替代听感门禁。

文档侧也强化了这一错位：`IMPLEMENTATION_PHASES` 将 P2.6 标为「代码合入」，同时写「Island 已支持 SMTC + WASAPI 真实 Transfer」，而 Island 验收清单（含「听得见 HRTF wet」）仍为未勾状态——**合入 ≠ 证明**。

---

## 3. Island 先行耦合的成本

Island 本职是 **HWND chrome + 紧凑 UI**；音频应仍挂在 `EngineController` / `spatial_core`。一旦把**未验证的 live 管线**默认入口放在 Island 上，调试成本被系统性放大：

1. **故障归因分叉**  
   听不见 / 双声 / 卡顿时，无法快速判断是：窗口策略（frameless、toolwindow、click-through）、SMTC 进程、loopback/静音、HRTF、还是输出设备。Island 把「壳问题」与「声问题」绑在同一操作路径上。

2. **验收面过窄、操作路径过长**  
   复现依赖：进 Island → 展开 → 点真实 Transfer → 看字幕。Full 缺少同等成熟的「系统环回 A/B」门禁时，无法在宽窗口、完整控件下隔离变量。

3. **新壳放大旧债**  
   文件 Spatial 侧已有 pose slew / orbit buzz 类问题与修复史；live 管线再叠加时，Island 的固定尺寸、置顶、点透探测等又引入新变量。两个不成熟面相乘，而不是相加。

4. **范围蠕变掩盖门禁缺失**  
   Floating Island → SMTC → 视觉 LIVE → WASAPI live HRTF → Full monitor bar：每一层都能「演示一点进度」，但没有一层强制回答：「在 Full、不经 Island，系统环回 HRTF 是否已稳定可听？」

5. **产品叙事提前**  
   对外/对内都像「灵动岛上已有真实 Transfer」，实际门禁未过——后续每次失败都会打击信任，并诱使继续在 Island 上打补丁，而不是退回 Full 做成熟度。

---

## 4. 建议成熟度阶梯（门禁）

以下门禁**必须按序通过**；未过关不得把下一层标为产品可用，更不得把下一层的默认入口放在 Island。

### Gate A — Full 窗口 · 文件 Spatial（听感地基）

| | 标准 |
|--|------|
| **范围** | 仅 Full；打开本地文件；Original / Spatial；音位 / orbit（若已启用） |
| **Pass** | 耳机可稳定区分干/湿；改方位可感知；播放 ≥N 分钟无持续 buzz/爆音；参数热更新可预期 |
| **Fail** | 仅 UI/波形/数值变化但听感无差；或已知 buzz 类缺陷未关闭仍堆新功能 |
| **产出** | 「Full 文件 Spatial 可演示清单」勾选完成；作为一切 live 功能的前置 |

### Gate B — Full 窗口 · 系统环回 HRTF（A/B）

| | 标准 |
|--|------|
| **范围** | 仍在 Full（或 Full 等价调试面）；外部播放器有声；启动 loopback→HRTF；源会话静音策略明确 |
| **Pass** | **Transfer ON**：清晰湿声；**OFF**：回干声且无残留双声；重复开关 ≥10 次无静默/崩溃；pid/会话选择可解释；与文件 Spatial 听感同类（方位可辨） |
| **Fail** | 只有 SMTC 标题/「LIVE」字幕；或仅偶发有声；或只能在 Island 路径触发才能「碰巧」有声 |
| **产出** | 书面 A/B 步骤（外部 App → Full 开/关 Transfer → 听感记录）；**禁止**以 Island 为唯一复现路径 |

### Gate C — Island chrome（壳成熟，不管线创新）

| | 标准 |
|--|------|
| **范围** | Full ↔ Island 形态；click-through；DPI；任务栏/Alt+Tab 策略 |
| **Pass** | 播放中切换 ≥20 次不中断音频；点透与回 Full 稳定；Mock 可进 Island |
| **Fail** | 壳不稳仍继续往 pill 塞新管线入口 |
| **约束** | 本门禁**不**验收新音频能力；只验收「已在 Gate A/B 证明的能力」在缩 UI 下仍可用 |

### Gate D — Island 承载已证明能力（缩进，非发明）

| | 标准 |
|--|------|
| **范围** | 把 Gate A/B 已通过的文件 LIVE / 系统 Transfer **投影**到 Island |
| **Pass** | Island 与 Full 听感一致；字幕与真实湿声一致；文件会话优先于 SMTC 的规则可测 |
| **Fail** | Island 上出现 Full 从未稳定复现过的「新行为」却被当作功能完成 |

**一句话**：Full 证明管线 → Island 只做呈现与快捷入口。

---

## 5. 在 Full 过关前，Island 应冻结 / 降范围

在 **Gate B 未 Pass** 之前，建议对 Island 明确冻结：

| 冻结 / 降范围 | 理由 |
|---------------|------|
| 不以 Island 为「真实 Transfer」主入口或唯一入口 | 避免壳与管线耦合调试 |
| 不新增 Island 专用 live 管线变体、会话策略、静音策略 | 变体只许先在 Full 验证 |
| SMTC 仅作只读元数据（标题/艺人），不暗示 HRTF 已就绪 | 防止「有字 = 有声」的 Done 幻觉 |
| 视觉 LIVE / az 环：无稳定湿声时不升级为产品卖点 | 动画不得替代听感验收 |
| Full monitor bar：可保留为 **Full 侧**诊断与 A/B，不倒逼 Island 对等炫技 | 监视服务于 Gate B，而非 Island 叙事 |
| 文档与阶段状态：区分「代码合入」与「听感验收通过」 | 消除 PHASES / 浮窗清单之间的虚假完成感 |

Island **允许继续做的**（壳本身）：模式切换稳定性、点透、DPI、回 Full——即 Gate C，且不依赖新音频。

---

## 6. 过程教训

1. **新壳不是新功能的试验田**  
   新兴 UI（灵动岛）应承载已证明能力；未证明管线应留在信息与控件最全的 Full 面。

2. **听感是硬门禁，检测与 UI 是软信号**  
   SMTC READY、pid、`HRTF LIVE` 字幕、监视条状态，最多证明「链路有意图」；Pass/Fail 必须以可重复听感与 A/B 为准。

3. **合入 ≠ 可用；清单未勾 ≠ 可写「已支持」**  
   阶段文档应把「代码合入」和「验收通过」拆开；未勾听感项时，产品叙述保持「实验 / 仅 Full」。

4. **一次只加一个未验证面**  
   Island 未稳时叠加 SMTC + live HRTF + 监视条，导致无法二分排查。过程上应：一表面成熟后再叠下一表面。

5. **默认复现路径必须是 Full**  
   任何 live/Transfer 缺陷，若不能在 Full 稳定复现，不应优先在 Island 上修——先补 Full 门禁，再映射到 pill。

6. **范围冻结是进度，不是退步**  
   从 Island 拿掉未验证入口，是在恢复可验证的产品顺序；否则「一直失败」会变成常态。

---

## 7. 闭环建议（仅过程，不涉及改码）

- 评审时固定提问：「这件事能否在 **不进入 Island** 的情况下验收听感？」不能 → 不得标 Island 功能完成。  
- 每层 Gate 保留简短书面 Pass/Fail 记录（日期、外部播放器、ON/OFF 听感），再允许下一层排期。  
- 更新阶段叙事时：P2.6 壳与「系统 Transfer」拆成不同完成度；Transfer 归属 Gate B，Island 仅 Gate C/D。

---

*本稿只回答「为什么方向反了、如何用门禁把顺序拧回来」。具体工程修复不在范围。*
