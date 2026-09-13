# Live Transfer 持续失败 — 整合分析（合成报告）

> **性质**：只读整合分析，**不改代码**。  
> **日期**：2026-09-13  
> **问题**：为什么 Yinwei「lively / live Transfer」（系统音频 → 空间化）一直失败？  
> **用户已确认的方向纠正**：应先完善 **Full 窗口端** 功能与听感验收；不应把未验证管线直接堆到新兴 **灵动岛** 上。

本报告综合四份分镜头文档，并加上编排层结论。分报告路径：

| 镜头 | 文档 |
|------|------|
| Audio DSP / 信号路径 | [`ANALYSIS_LIVE_TRANSFER_AUDIO_DSP.md`](./ANALYSIS_LIVE_TRANSFER_AUDIO_DSP.md) |
| Windows 平台约束 | [`ANALYSIS_LIVE_TRANSFER_WINDOWS_PLATFORM.md`](./ANALYSIS_LIVE_TRANSFER_WINDOWS_PLATFORM.md) |
| Flutter ↔ FFI ↔ UI 接线 | [`ANALYSIS_LIVE_TRANSFER_FLUTTER_FFI.md`](./ANALYSIS_LIVE_TRANSFER_FLUTTER_FFI.md) |
| 产品排序 / 过程 | [`ANALYSIS_LIVE_TRANSFER_PRODUCT_PROCESS.md`](./ANALYSIS_LIVE_TRANSFER_PRODUCT_PROCESS.md) |

---

## 1. 一句话总判

**Live Transfer 失败不是「某一个按钮没写对」，而是四类问题叠在一起：平台语义缺口、信号链时钟/静音包雷区、集成假阳性、以及把未证明管线绑在 Island 上导致无法隔离验收。**  
其中 **产品排序错误**放大了其余所有技术债的调试成本；在 Full 听感门禁通过之前，继续在 Island 上打补丁会系统性「一直失败」。

---

## 2. 用户症状 ↔ 根因对照表

| 用户观察到的现象 | 最吻合的根因层 | 证据强度 | 分报告 |
|------------------|----------------|----------|--------|
| 能检测到汽水标题，但听不到「真转换」 | SMTC ≠ PCM；干湿叠听；或 wet 被干声淹没 | 高（平台 + 产品语义） | Windows / Product |
| 一开 Transfer 歌过几秒自己停 | 曾对源会话 SetMute/音量 0 → 汽水/Spotify 自动暂停 | **已证实（历史）** | Windows / FFI 时间线 T6 |
| 引擎轰鸣，关歌后还在 | `AUDCLNT_BUFFERFLAGS_SILENT` 缓冲未定义被当 float PCM | **已证实（历史）**；现已部分修补 | Audio DSP / Windows |
| UI 显示 HRTF LIVE / frames，仍像干声 | LIVE 文案双载；frames 含静音零帧；叠听 | 高 | FFI / Windows |
| 进岛卡 5–15s（早期） | 冷启 PowerShell/WinRT | 已缓解（常驻 daemon） | FFI 时间线 T2 |
| DLL 改了不生效 | Debug `spatial_core.dll` 被进程锁，拷贝失败 | **已反复证实** | FFI |
| 「方向做反了」 | Island 未稳就叠 SMTC + live HRTF | 采纳为正确产品判断 | Product |

---

## 3. 四镜头共识（交叉验证）

四份报告独立写成，但在下列点上 **高度一致**：

### 3.1 SMTC 绿灯 ≠ Transfer 绿灯

- Windows 白送的是 **元数据与传输控制**，不是 PCM。  
- AUMID → PID **没有 OS 级保证**，只有启发式；错 PID → 空捕获或无关噪声，而 UI 仍可能显示「有 pid」。  
- 因此「检测成功」最多证明 Gate「可见」，不能证明 Gate「可听」。

### 3.2 「真替换干声」在当前平台策略下几乎不可得

- Mute/归零源会话 → 主流播放器自动暂停（已实锤）。  
- 不 mute → 干声 + 湿声叠听 → 用户报告「没有 Transfer」。  
- 模块注释仍写「应 mute」，Dart 已 no-op —— **文档与实现分裂**，验收标准漂移。

### 3.3 静音包语义是轰鸣的硬证据

- WASAPI `SILENT` 标志：缓冲区内容 **未定义**。  
- 当垃圾当 PCM + HRTF/增益 → 停乐后持续轰鸣。  
- 这是信号路径级的平台陷阱，不是「用户听错了」。

### 3.4 Live 路径未继承文件播放的时钟契约

- 文件 `RealtimePlayer`：content rate → resample → device rate。  
- Live：capture 锁 48 kHz、DSP 启动瞬间读 `sample_rate`、随后 cpal 才写入设备率 → **可能错位**。  
- 即使用户偶尔「有声」，听感也不等于正确 Spatial。

### 3.5 UI / 集成制造大量假阳性

- `Yinwei LIVE`（本地文件 Spatial）与 `HRTF LIVE`（系统环回）共用视觉语言。  
- `running=true` + frames 上涨 ≠ 有音乐能量（静音包填零仍计数）。  
- 旧 DLL 锁导致「代码改了、耳朵没变」。

### 3.6 排序错误是放大器

- Island 壳 + 未验证管线同时未成熟 → 故障归因分叉（壳？SMTC？PID？DSP？BT？）。  
- 正确阶梯：**Full 文件 Spatial → Full 系统环回 A/B → Island 只投影已证明能力**。

---

## 4. 因果链（从意图到耳朵）

```text
产品意图：「灵动岛上对汽水做 lively Transfer」
        │
        ▼
SMTC 检测标题 ──────────────────────────────► 用户以为「已经半成功」
        │
        ▼
启发式 Resolve-Pid(AUMID) ──错/对──► WASAPI process loopback
        │                              │
        │                              ├─ SILENT 垃圾 → 轰鸣（历史）
        │                              ├─ 错 PID / DRM → 静默或失败
        │                              └─ 48k vs device rate → 怪声/缝
        ▼
不 mute（防自动暂停）──► 干声仍在 + 湿声叠加 ──► 「听不出转换」
        │
        ▼
Island 小 UI + LIVE 文案 ──► 无法 A/B、无法隔离 ──► 「一直失败」叙事固化
```

**关键洞察：** 前半段（检测）可以「看起来成功」；后半段（可听、可替换、可关）才是 Transfer。团队长时间在前半段迭代，用 UI 进度掩盖后半段未证明。

---

## 5. 已证实 vs 高置信 vs 待实验室验证

| 等级 | 项 |
|------|-----|
| **已证实** | SMTC 不含 PCM；源会话 mute 导致汽水类 App 暂停；SILENT 缓冲当 PCM → 轰鸣；DLL 锁定导致部署假阴性；Island/Full 曾把视觉 LIVE 当 Transfer |
| **高置信** | 干湿叠听是「无效果」主因之一；AUMID→PID 启发式在汽水等多进程场景不稳定；Live 采样率契约弱于文件路径 |
| **待实验室验证** | 具体机型上 device rate 是否常非 48k；汽水是否对 process loopback 空输出/策略限制；蓝牙第二路 cpal 是否单独造成「像坏了」；HRTF/reverb 对近静音底噪的放大阈值是否仍可闻 |

---

## 6. 为什么「修了很多轮」仍像没修好

按时间线压缩（详见 FFI 报告 T0–T9）：

1. 先修 **可见性**（SMTC、岛、监视条）→ 进度感强。  
2. 再修 **副作用**（卡顿、mute 暂停、轰鸣）→ 每次修一个症状，引入下一约束（不 mute → 叠听）。  
3. 始终缺少 **Full 窗听感 A/B 门禁**：没有「Transfer ON/OFF 各听 30 秒并记录」的强制产出。  
4. Island 作为默认叙事入口 → 每次失败都混入壳与管线两个面。

这不是「工程师不努力」，而是 **验收定义错了**（见 Product 报告 §2）。

---

## 7. 整合建议：冻结与门禁（仍不改代码，只定方向）

采纳 Product 报告阶梯，作为后续唯一合法顺序：

| 门禁 | 场所 | Pass 标准（听感硬条件） | Island |
|------|------|-------------------------|--------|
| **A** | Full · 本地文件 Spatial | 干/湿可区分；方位可感；无持续 buzz | 不承载新音频实验 |
| **B** | Full · 系统环回 HRTF | ON 有湿声、OFF 回干声；可重复 ≥10 次；pid/策略可解释 | **禁止**作为唯一复现路径 |
| **C** | Island chrome | 切换/点透稳定；**不**验收新管线 | 只验壳 |
| **D** | Island 投影 | 与 Full 听感一致 | 仅映射 A/B 已过能力 |

在 Gate B 通过前，建议产品叙述改为：

- Island：**元数据只读 + 壳**；不宣称「真实 Transfer 已可用」。  
- Full：唯一允许继续验证系统环回的表面。  
- 文档：`IMPLEMENTATION_*` 区分「代码合入」与「听感验收通过」。

---

## 8. 分报告职责边界（避免再混谈）

| 若争议点是… | 先读 |
|-------------|------|
| 轰鸣 / 采样率 / 队列 / HRTF | Audio DSP |
| PID / mute / SILENT / BT / DRM | Windows Platform |
| DLL / FFI 顺序 / LIVE 文案假阳性 | Flutter FFI |
| 先做岛还是先做窗 / 门禁 | Product Process |
| 全局优先级与「下一步只许做什么」 | **本文（整合）** |

---

## 9. 编排结论（本整合作者）

1. **技术上**：Live Transfer 处于「可演示意图、不可承诺听感」状态；至少存在一类已证实的平台陷阱（SILENT、mute→暂停）和一类结构性产品缺口（无法只听湿声）。  
2. **过程上**：用户判断正确——**窗口端成熟度优先于灵动岛承载**；否则失败会表现为「永远差一点」。  
3. **下一步（仅方向，非本轮实现）**：冻结 Island 上的 Transfer 叙事；用 Full 建立可重复 A/B；在证明「耳机里湿声可开关」之前，不把系统环回标为产品完成。

---

## 10. 文档索引

- [`ANALYSIS_LIVE_TRANSFER_AUDIO_DSP.md`](./ANALYSIS_LIVE_TRANSFER_AUDIO_DSP.md) — [Audio DSP](83b04f4b-b7b5-4182-af17-02ac424f4548)  
- [`ANALYSIS_LIVE_TRANSFER_WINDOWS_PLATFORM.md`](./ANALYSIS_LIVE_TRANSFER_WINDOWS_PLATFORM.md) — [Windows Platform](33f6e482-0b99-4ffc-8076-3a332933458b)  
- [`ANALYSIS_LIVE_TRANSFER_FLUTTER_FFI.md`](./ANALYSIS_LIVE_TRANSFER_FLUTTER_FFI.md) — [Flutter FFI](f88da66f-4674-4777-ab4b-d7155ce8d433)  
- [`ANALYSIS_LIVE_TRANSFER_PRODUCT_PROCESS.md`](./ANALYSIS_LIVE_TRANSFER_PRODUCT_PROCESS.md) — [Product Process](645b5166-4d1a-444a-831e-278263df93cc)  
- 本文：`ANALYSIS_LIVE_TRANSFER_SYNTHESIS.md`
