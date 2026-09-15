# Live Transfer 失败分析（Audio DSP / 信号路径法医）

> 范围：仅 WASAPI process loopback → `HrtfStreamer` → cpal 的实时信号链。  
> 方法：对照 `live_transfer.rs` 与文件播放 `RealtimePlayer`（`playback.rs`），区分**已由代码注释/结构证明的问题**与**待实验室验证的假说**。  
> 本文不包含补丁方案实现，也不改动任何应用代码。

---

## 1. Executive Verdict（执行结论）

Live Transfer **不是「HRTF 算法本身坏了」的单一故障**，而是一条 **时钟未对齐 + 队列无重采样 + 静音包/增益历史雷区 + 干湿双听** 叠加的实时链路。文件播放路径已经用 `content_rate → resample_cubic → device_rate` 解决了同类问题；Live 路径刻意平行实现，却**没有继承同一时钟契约**。

**最可能的「持续失败」根因（按证据强度）：**

1. **Capture 固定 48 kHz（autoconvert）→ HRTF 用启动瞬间的 `sample_rate` → cpal 用设备默认率，中间无 resample** —— 设备非 48 kHz 时，tempo/pitch、HRIR、crossover/reverb 系数与消费速率同时错位；队列要么持续 underrun（输出静音缝/「断」），要么堆积触发 DSP back-pressure。  
2. **历史上把 `AUDCLNT_BUFFERFLAGS_SILENT` 的未定义缓冲当 float PCM，再叠 makeup gain** —— 与「音乐停了仍引擎轰鸣（engine roar）」高度吻合；代码已部分止血，但**健康检查仍把静音包计为“有 PCM”**，启动门禁偏弱。  
3. **为避免源 App auto-pause，故意不 mute 源会话** —— 用户同时听到干声（源 App）+ 湿声（Yinwei），空间感被干声淹没，表现为「没有 Spatial 效果」；这与「双听 / wet-dry」直接对应，而非 HRTF 无输出。

**一句话：** Live Transfer 在「能出声」与「听起来像正确空间化」之间，缺的是 **与 `RealtimePlayer` 同级的采样率契约 + 可靠的 capture 健康语义 + 单一听感路径（只能听 wet）**；否则症状会反复以 roar / 无空间感 / 启动失败 / 停乐后怪声出现。

---

## 2. Evidence from Code（代码证据）

### 2.1 信号拓扑（三线程 + 双队列）

`yinwei/crates/spatial_core/src/live_transfer.rs`：

| 阶段 | 线程/回调 | 数据 | 约略行区 |
|------|-----------|------|----------|
| Capture | `yinwei-live-capt` | WASAPI → `dry_q` | `capture_loop` ~301–411；`start` 启动 ~140–155 |
| DSP | `yinwei-live-dsp` | `dry_q` → `HrtfStreamer` → `wet_q` | `dsp_loop` ~413–473；`start` ~180–188 |
| Output | cpal callback | `wet_q` → 设备 | `build_out` ~257–299；`open_output` ~218–248 |

共享状态：`stop` / `running` / `capture_ok` / `frames_captured` / `sample_rate` / `mode` / `params`（`Shared` ~28–40）。

文件模块头注释已写明策略偏好（~1–4）：**优先 process loopback（`pid > 0`）避免自捕获**；并提示调用方应 mute 源会话——但 Dart 侧已明确违反该假设（见 2.7）。

### 2.2 Capture：固定 48 kHz + SILENT 处理 + 能量门

```313:403:yinwei/crates/spatial_core/src/live_transfer.rs
// desired WaveFormat @ 48000 stereo float, EventsShared { autoconvert: true, 20ms }
// flags.silent → push zeros（注释：UNDEFINED buffer → float = engine roar）
// energy < 1e-8 → frames.fill(0) 再进 dry_q
// frames_captured += n；capture_ok = true
```

要点：

- **期望格式锁死 48000**（~313），依赖 WASAPI `autoconvert` 把源进程的原生率转进来。  
- **`flags.silent` 必须当零**（~356–362）：注释直接把「停乐后轰鸣」归因于把 SILENT 包当 PCM。这是**已承认的历史缺陷**，当前实现按正确语义处理。  
- 近静音能量门（~391–394）意图阻止 HRTF/reverb 把底噪放大成 rumble。  
- **无论能量是否被清零，只要凑满 `STREAM_CHUNK` 就 `frames_captured++` 且 `capture_ok=true`**（~395–402）。因此「有帧」≠「有可听内容」。

`pid == 0` 被硬拒绝（~307–310）：`device loopback disabled (feedback risk)`。这与 FFI 注释「0 = default-device loopback」（`ffi.rs` ~442–443）**文档不一致**——实现侧已认定设备环回会反馈。

### 2.3 启动门禁：~1 s 内要有 ≥128「帧」

`start`（~157–178）：每 25 ms 轮询，最多约 1 s；`frames_captured >= 128` 才继续开 DSP/输出。失败文案：`process loopback silent … Wrong PID or app blocked capture`。

结合 2.2：若进程仍在发 **SILENT 包或近零 PCM**，门禁可能 **误通过**（假阳性健康），随后 DSP/reverb 在「名义上在跑」的静音链上工作。

### 2.4 关键时钟错位：DSP 读 rate 的时机 vs 输出写 rate

启动顺序（`start` ~140–190）：

1. 先起 capture  
2. 等 128 frames  
3. **再起 `dsp_loop`**  
4. **然后才 `open_output()`**

`dsp_loop` 入口（~414–415）：

```text
let sr = shared.sample_rate.load(...).max(1);
let mut streamer = HrtfStreamer::new(sr)?;
```

`open_output`（~226–229）才把 **cpal 设备默认 sample rate** 写入 `shared.sample_rate`。

因此：

- `HrtfStreamer` 构造时读到的几乎总是 **默认值 48000**（`new` ~85），或**上一次** run 留下的值。  
- `open_output` 之后改写原子量，**不会重建 streamer**，DSP 也不再读该原子量做 resample。  
- Capture 侧始终按 **48 kHz 帧时钟** 往 `dry_q` 推（在 autoconvert 成功的前提下）。  
- cpal 按 **设备率** 从 `wet_q` 取帧；取不到就填 `(0,0)`（`build_out` ~284）。

**对比 `RealtimePlayer`（已做对的路径）：**

- `playback.rs` 模块注释 ~8–9：设备开在 default rate；**content → device 用 cubic resample**。  
- `dsp_loop` ~411–480：显式 `content_sr` vs `device_sr`，不等则 `resample_cubic`。  
- HRTF 用 **content_sr** 建 `HrtfStreamer`（`ensure_dsp` ~300–301），与文件解码率一致。

Live 路径**没有**等价的 `content_rate` / `output_rate` 分离，也**没有**调用 `resample` 模块。这是结构级差距，不是风格差异。

### 2.5 输出回调：无 makeup gain；underrun = 数字静音

`build_out` ~282–284 注释：

> No makeup gain — silent-packet garbage + gain became an "engine roar".

含义：历史上曾在输出侧抬增益；与 SILENT 垃圾叠加后，停乐后仍可持续大音量噪声。当前 **clamp 到 ±1.0、无额外 gain**。Underrun 策略是 **硬静音**，不是重复上一帧（后者会「嗡」、前者会「断」）。

`wet_q` 无显式 RING_TARGET；DSP 在 `wet_len > STREAM_CHUNK * 20` 时 sleep back-pressure（~425–428）。`dry_q` 过长会丢最旧帧（~396–398）。速率不匹配时：

- **设备率 > 产帧墙钟率** → 持续 underrun → 断续/发虚。  
- **设备率 < 产帧墙钟率** → `wet_q` 堆积 → DSP 降速 → `dry_q` 丢帧 → 时延抖动 / 内容跳帧。

### 2.6 HRTF / Reverb 在 Live 默认参数下的「共振」风险面

Live 默认 `SpatialParams`（`LiveTransferEngine::new` ~72–79）：`Orbit`、`orbit_hz=0.08`、`envelopment=0.65`、`azimuth=90°`、`elevation=-10°`。

`HrtfStreamer::process_chunk`（`hrtf_render.rs` ~538–701）：

- Mid/Side + envelopment 把 Mid 高频灌进 ambient 路径（~618–623）。  
- `env > 0.05` 即开 ambient HRTF；`env > 0.35` 开第二路（~643–681）——默认 0.65 **双 ambient + Mid**，DSP 负载高。  
- Freeverb 按 `distance_reverb_mix` 混合（~612、693–697）；距离越大 wet 越大（上限 ~0.55）。  
- Orbit 用 8° HRIR 量子 + 偶发 dual-xfade（`ORBIT_HRIR_STEP_DEG`，见 `REPORT_ORBIT_BUZZ` 相关注释）——文件路径已踩过 buzz；Live 默认开 Orbit，**计算量与相位切换风险更高**。

若输入是 SILENT 垃圾（历史）或未门控的底噪：**卷积尾 + Freeverb 状态**会把宽带噪声变成「引擎/风噪」式持续声；停乐后源 App 不再出乐，但 **DSP 状态仍在被错误激励** —— 与症状语义一致。当前 SILENT→0 + energy gate 降低了该路径，但 **reverb 正常衰减尾** 与 **错误激励 rumble** 在听感上仍需 lab 区分。

### 2.7 FFI 与「健康」暴露面

`yinwei/crates/spatial_core/src/ffi.rs`：

- `yinwei_live_start`（~445–465）：先 `pause` 文件 session，再强制 `PlaybackMode::Spatial`，然后 `eng.start(pid)`。  
- `yinwei_live_captured_frames`（~574–588）：给 UI 健康检查用。  
- **无** `yinwei_live_capture_ok` 导出；`capture_ok` 仅在 Rust 内部。  
- **无** capture/device sample rate 遥测。

Dart（仅作信号路径上下文，非本文改动范围）：

- `live_transfer.dart`：明确 **不 mute 源 App**；start 阻塞约 1 s。  
- `system_media.dart` `setSourceMuted`：**故意 no-op**，因 SetMute/volume0 导致汽水/Spotify **数秒内 auto-pause**。  
- `IMPLEMENTATION_FLOATING_ISLAND.md` 仍写「源会话 mute 以避免双声」——与现行实现 **冲突**。

因此「auto-pause」在产品上是**已验证的副作用**（mute 路径），现行策略用 **双听** 换 **源不停**；从 DSP 听感上，这直接削弱「能否听出 Spatial」。

### 2.8 与 RealtimePlayer 的对照表

| 维度 | RealtimePlayer (`playback.rs`) | LiveTransferEngine (`live_transfer.rs`) |
|------|--------------------------------|----------------------------------------|
| 输入时钟 | 解码 `content_rate` | WASAPI 请求 48 kHz + autoconvert |
| HRTF 率 | `HrtfStreamer::new(content_sr)` | `new(shared.sample_rate)`，常为启动前默认 48 k |
| 设备率 | `output_rate`，与 content 分离 | 写入同一 `sample_rate` 原子，且 **晚于** DSP 启动 |
| 重采样 | `resample_cubic` 若不等 | **无** |
| 环形缓冲策略 | `RING_TARGET` / `RING_MAX`，参数更新不清环 | `dry_q`/`wet_q` + 丢旧 / wet back-pressure |
| Underrun | 填静音并推进 playhead（同文件后半） | 填 `(0,0)` |
| 自反馈 | 无 loopback | process-only；device loopback 禁用 |
| Makeup gain | 无（文件路径） | 曾有，已去掉（注释） |
| SILENT 语义 | N/A | 必须零填充（已修） |

---

## 3. Failure Modes Ranked（失败模式排序）

等级说明：**P0** = 结构上几乎必然在常见 Windows 配置上出问题，或已被注释钉死；**P1** = 强假说，与症状高度同构；**P2** = 加重因子 / 边界。

### P0-A — Capture@48k / HRTF@启动率 / Device@default **无 resample**（结构缺陷）

- **机制：** 墙钟上 1 秒 capture 约 48000 帧进队列；设备若 44100 或 96000，消费速率不匹配。HRTF/crossover/reverb/`orbit` 相位步进全部按错误或碰巧正确的 fs 解释时间。  
- **状态：** **代码结构可证明缺失**；在「设备恰好 48 kHz」的机器上可能被掩盖，造成「有人好用、有人必挂」。  
- **听感：** 音高/速度怪、空间滤波发糊、断续、延迟爬升、或「几乎没处理感」。

### P0-B — 历史 SILENT 包当 PCM + makeup gain → **engine roar**（已部分修复）

- **机制：** `AUDCLNT_BUFFERFLAGS_SILENT` 时缓冲内容未定义；当 float 解读 → 满幅度噪声；再 ×gain → 轰鸣；源停乐后 SILENT 包仍来 → **停乐后更明显**。  
- **状态：** **历史 bug 已被注释承认并修补**（零填充、去 makeup）。若现场仍 roar，优先怀疑：**旧 DLL 未更新**、energy gate 未覆盖的非 SILENT 垃圾、或 reverb 被异常激励（需 lab）。  
- **听感：** 金属/发动机式持续噪声，音乐停后仍在。

### P0-C — 干湿双听（mute 不能用）→ 「没有空间效果」

- **机制：** 源 App 正常出干声到默认设备；Yinwei 再出湿声到同一（或另一）设备。人耳被干声主导时，HRTF 侧链几乎不可辨。  
- **状态：** **策略层已证实**（auto-pause 迫使 no-op mute）；文档仍写 mute，实现已放弃。  
- **听感：** 「Transfer 开了但还是原声 / 略响或略糊」。

### P1-A — 启动健康检查假阳性 / 假阴性

- **假阳性：** SILENT→0 仍计 `frames_captured` → 源暂停也能「启动成功」，随后只有 reverb 态或静音 underrun。  
- **假阴性：** 源刚起播延迟 >1 s、或 PID 错、或应用拒绝 process loopback（需 Win10 2004+）→ `start` 直接 `AudioDevice` 错误。  
- **状态：** 门禁逻辑可证明偏弱；现场失败率需遥测。

### P1-B — Process PID / 捕获权限错误

- **机制：** SMTC PID 与真实出声进程不一致（沙盒、子进程、UWP 代理）；`new_application_loopback_client` 失败或静默。  
- **状态：** 错误字符串已覆盖部分情况；**是否为当前主因需 lab + 日志**。

### P1-C — 高 envelopment + Orbit + Freeverb 在错误激励下的「共鸣」

- **机制：** 默认 env=0.65 开双 ambient HRTF；底噪或错误 PCM 经多路卷积 + reverb → 宽带 rumble。  
- **状态：** 对文件路径 buzz 有专项报告；对 Live roar **是合理假说**，在 SILENT 修复后应减弱，但不能假定为零。

### P2-A — 队列策略导致的可闻伪影

- dry 丢旧帧、wet underrun 硬静音、Mutex 争用在音频回调内 —— 可造成卡顿/滴答，通常不像持续 roar。  
- DSP 负载（Orbit + 多 HRTF）在弱机上加剧 underrun。

### P2-B — 设备环回反馈（已禁用）

- 若未来重新打开 `pid=0` 设备 loopback，Yinwei 自己的 cpal 输出可被再次捕获 → 正反馈啸叫/轰鸣。当前代码路径关闭；**不要**在未做侧链隔离前重开。

---

## 4. Why Symptoms Matched（症状 ↔ 路径）

### 4.1 「音乐停了之后引擎轰鸣（engine roar）」

| 解释 | 类型 | 匹配度 |
|------|------|--------|
| SILENT 未定义缓冲当 PCM，停乐后 SILENT 包比例上升 | **历史已证** | 极高 |
| 再叠加 makeup gain | **历史已证** | 极高 |
| Freeverb / HRTF 尾被噪声激励，停乐后仍响 | 假说（修复后应短衰减） | 中 |
| 设备环回自反馈 | 当前禁用；若误用 device loopback | 高（但路径关） |
| 单纯 underrun 填零 | 应为安静，不是 roar | 低 |

**结论：** 该症状的经典解释是 **静音包语义错误 × 增益**；现行代码意图消除它。若复现，先证明 DLL 是否含 SILENT 分支，再录 `flags.silent` 比例与输出 RMS。

### 4.2 「没有空间效果（no spatial）」

| 解释 | 类型 | 匹配度 |
|------|------|--------|
| 干声未 mute，双听掩盖 wet | **现行策略可证** | 极高 |
| 采样率错导致 HRTF/ITD/ILD 时间尺度错误，像「差一点 EQ」 | 结构缺陷 | 高（非 48k 设备） |
| `mode` 实际为 Original | 弱：FFI start 强制 Spatial | 低 |
| envelopment/reverb 把定位糊掉 | 假说 | 中 |
| 捕获到的不是目标 App 音频（错 PID） | 假说 | 中高（启动失败或静音时） |

### 4.3 「历史上源 App 自动暂停（auto-pause）」

| 解释 | 类型 | 匹配度 |
|------|------|--------|
| `ISimpleAudioVolume` mute / volume=0 触发播放器策略 | **工程注释已钉死** | 极高 |
| 与 HRTF/DSP 无关 | 是 | — |

现行用双听规避 auto-pause，把问题从「停播」转移到「听感无效」—— **症状迁移，不是根因消失**。

### 4.4 「启动失败 / 跑一会自己停」

| 解释 | 类型 | 匹配度 |
|------|------|--------|
| 1 s 内不足 128 frames（错 PID / 无声 / 权限） | 代码可证 | 高 |
| capture 线程 Err → `running=false` | 代码可证（~147–151） | 高 |
| UI 仅看 `liveIsRunning` / frames，无 rate 健康 | 可证 | 中 |

---

## 5. What Must Be Proven in Lab Before Shipping（上线前实验室证明清单）

以下均为 **测量项**，不是实现建议清单的展开实现。

### 5.1 时钟与队列（对 P0-A 一票否决级）

1. 记录三联率：`WASAPI 实际回调帧率`、`HrtfStreamer` 构造 fs、`cpal default_output_config.sample_rate`。  
2. 在 **44.1 / 48 / 96 kHz** 默认输出设备上各跑 60 s：测 `dry_q`/`wet_q` 深度均值与峰值、underrun 计数（callback 取到 0 的帧数）、端到端时延。  
3. 播放已知 1 kHz 测试音（源 App）：测 Yinwei 输出频率是否仍为 1 kHz（偏离 → 速率契约失败）。  
4. 与同机 `RealtimePlayer` 播同内容对比：ITD/音高/时延。

**通过标准（建议）：** 三率一致或存在可审计的 resample；1 kHz 频偏 < 0.5%；60 s 内 underrun 帧比低于可接受阈值（需产品定标）。

### 5.2 SILENT / 停乐 roar（对 P0-B）

1. 源播放 → 暂停/停止，保持 Live running：记录每包 `flags.silent`、读缓冲最大 \|sample\|、输出 RMS。  
2. 确认 SILENT 包路径输出 RMS ≈ 数字静音（仅允许短 reverb 衰减，秒级内落到噪声底）。  
3. 对比「旧 DLL（若可得）」与当前构建的停乐后频谱。

**通过标准：** 停乐后 2 s 内无持续全频带高能量；无「发动机」稳态。

### 5.3 双听与「可感知 Spatial」（对 P0-C）

1. 在 **仅 Yinwei 出声**（源会话真正静音或源改出到虚拟/另一设备）vs **现行双听** 做 AB：听者能否辨方位/Orbit。  
2. 不依赖 mute API 的隔离方案（虚拟线缆、专用输出设备、应用侧「仅耳机监听 wet」）必须在听感上证明 Spatial 可辨，再谈产品化。

**通过标准：** 在单听 wet 条件下，固定方位与 Orbit 可被盲听区分；双听若保留，需证明仍可辨或明确标为「预览级」。

### 5.4 Capture 健康语义

1. 源暂停但仍有 SILENT 包时，`frames_captured` 是否仍增长；UI 是否显示「健康」。  
2. 错 PID / 无音频进程：是否稳定失败且错误可理解。  
3. 长时间跑：`capture_ok` 与真实能量的相关性。

**通过标准：** 「running」必须绑定 **近期非静音能量** 或等价健康信号，而非累计帧计数 alone。

### 5.5 DSP 负载与 Orbit

1. 默认 Live 参数下 CPU、callback 时长、是否触发 wet back-pressure。  
2. Fixed + env=0 vs Orbit + env=0.65 的 underrun 差。

### 5.6 回归对照

- 文件 `RealtimePlayer` 在同设备率矩阵上必须保持绿（证明问题在 Live 契约，而非整机音频栈）。

---

## 6. Explicit Out of Scope（明确不在本文范围）

- Island / Floating Island UX、窗口点击穿透、DPI、SMTC 守护进程产品流程。  
- 产品策略（是否主打「真实 Transfer」、定价、竞品）。  
- Flutter UI 文案、视觉器美观度。  
- 具体代码补丁、API 重设计落地（本文只标必须被 lab **证明** 的命题）。  
- 非 Windows 平台、非 WASAPI 捕获方案选型深潜。  
- 文件离线渲染 / 导出 WAV 质量（除作为 RealtimePlayer 对照）。

---

## 7. Hypotheses vs Proven（速查）

| 命题 | 判定 |
|------|------|
| SILENT 缓冲当 PCM 可致停乐后 roar | **Proven（历史）**；现行有修复意图 |
| Makeup gain 放大该 roar | **Proven（历史注释）**；已移除 |
| Device loopback 有反馈风险 | **Proven（实现禁用）** |
| Mute 源会话 → 汽水/Spotify auto-pause | **Proven（工程决策注释）** |
| 现行不 mute → 干湿双听削弱空间感 | **Proven 策略**；听感幅度待 lab |
| Live 无 content→device resample | **Proven 结构缺失** |
| DSP 在 `open_output` 前锁定 HRTF fs | **Proven 时序** |
| 默认 48 k 设备上 Live「碰巧正常」 | **假说**（可解释偶发成功） |
| 高 envelopment/Orbit/reverb 单独导致 roar | **假说**（错误激励时加重） |
| 错 PID 是现场主因 | **假说**（需日志） |
| energy gate 已彻底消灭 rumble | **未证**；仅降低风险 |

---

## 8. Bottom Line（给读者的收束）

从 **DSP / 信号路径** 看，Live Transfer 反复失败，是因为这条链在「实时正确」所需的三件事上同时薄弱：

1. **单一、正确的采样率契约**（Capture = HRTF = 经 resample 后的 Device）——文件路径有，Live 没有。  
2. **Capture 包语义与健康定义**（SILENT、能量、帧计数）——曾直接制造 roar；门禁仍偏粗。  
3. **听感上的单路径湿声**——为避开 auto-pause 而接受双听，使「无空间效果」成为预期内后果。

在实验室用 **率矩阵 + 停乐 RMS + 单听/双听 AB + 1 kHz 频偏** 把上表 P0 项证伪或坐实之前，不宜把 Live Transfer 视为可发货的实时引擎路径。
