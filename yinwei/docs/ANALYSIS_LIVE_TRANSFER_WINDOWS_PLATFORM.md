# 分析：Live Transfer 持续失败 — Windows 平台约束视角

> **性质**：只读根因分析。不改代码、不含实现计划。  
> **分析镜头**：Windows 平台能力边界（SMTC ≠ PCM、进程环回 OS 要求、AUMID→PID 歧义、会话静音副作用、`AUDCLNT_BUFFERFLAGS_SILENT`、蓝牙 A2DP 双流、DRM/应用策略）。  
> **证据主文件**：[`system_media.dart`](../apps/yinwei_player/lib/bridge/system_media.dart)、[`live_transfer.rs`](../crates/spatial_core/src/live_transfer.rs)、[`live_transfer.dart`](../apps/yinwei_player/lib/bridge/live_transfer.dart)、[`player_screen.dart`](../apps/yinwei_player/lib/screens/player_screen.dart)。  
> **姊妹文档（不同镜头）**：[`ANALYSIS_LIVE_TRANSFER_PRODUCT_PROCESS.md`](./ANALYSIS_LIVE_TRANSFER_PRODUCT_PROCESS.md)（产品排序）。

---

## 1. 结论（Verdict）

**Live Transfer「检测通了但听感失效」的主因，是 Windows 把「媒体元数据」和「可变换的 PCM」拆成两条互不保证的能力，而 Yinwei 用前者驱动后者。**

具体来说：

1. **SMTC 只保证「谁在播什么歌」**，不提供样本流，也不保证 `SourceAppUserModelId` 能唯一映射到正在渲染音频的进程 PID。
2. **真正的 Transfer 依赖 WASAPI process loopback（Win10 2004+ / Build 20348+）**，且目标进程必须正在向某个 render 端点出声；idle 时往往**没有包**（不是静音包），错误 PID / 被策略挡住时则启动失败或空捕获。
3. **「真正替换干声」在平台上几乎不可得**：对源会话 `ISimpleAudioVolume` 静音/归零会触发汽水、Spotify 等应用的**自动暂停**；于是产品被迫改为「湿声叠加在干声上」——用户感知为「没有真正的 Transfer 效果」。
4. **历史上的「引擎轰鸣」属于平台语义陷阱**：`AUDCLNT_BUFFERFLAGS_SILENT` 时缓冲区内容未定义；当静音包被当 float PCM 再经 HRTF/增益，就变成持续吼叫。代码已修补该读法，但说明这条管线对 OS 语义极度敏感。
5. **因此：元数据绿灯 ≠ 音频变换绿灯。** UI 上有标题、有 pid、甚至有 `frames_captured`，仍可能只是「抓到了错进程的噪声/静默包」，或「干湿同播导致听不出 Spatial」。

---

## 2. 平台能力地图：Windows「白送」什么 vs 必须自己抓什么

| 能力 | Windows 是否「白送」 | Yinwei 现状 | 对 Transfer 的含义 |
|------|---------------------|-------------|-------------------|
| 正在播放的标题/艺人/进度 | **是** — WinRT `GlobalSystemMediaTransportControlsSessionManager` | PowerShell daemon 每 ~400ms 拉 SMTC，JSON 推给 Flutter（`system_media.dart` `_kDaemonScript`） | 检测与灵动岛展示可用；**零 PCM** |
| 播放/暂停控制 | **是** — `TryTogglePlayPauseAsync` | `_kToggleScript` | 控制会话，不捕获音频 |
| 默认设备整机环回 | **是** — 经典 WASAPI loopback（含所有进程） | **已禁用**：`process_id == 0` 直接报错（`live_transfer.rs`），因会把 Yinwei 自己的 cpal 输出再抓回来形成反馈 | 不能靠「整机环回」做干净 Transfer |
| **按进程环回** | **有条件** — `ActivateAudioInterfaceAsync` + `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK`（文档：最低客户端约 **Windows 10 Build 20348**；代码文案写 2004+） | `AudioClient::new_application_loopback_client(process_id, true)` | Transfer 的唯一可行捕获路径；OS 版本与目标树必须对齐 |
| AUMID → 精确渲染 PID | **否** — SMTC 只给 `SourceAppUserModelId` 字符串 | `Resolve-Pid` 用 AUMID 碎片 + 音乐进程名启发式 `Get-Process` | **平台缺口**：启发式必然有错 PID 风险 |
| 静音源会话且保持播放 | **名义上可以**（会话 volume/mute API） | `setSourceMuted` **刻意 no-op**（汽水/Spotify 会自动暂停） | **产品语义塌陷**：无法做到「只听湿声」 |
| 保护内容/DRM 路径 | **应用/策略可阻止或空输出** | 启动超时报 `"Wrong PID or app blocked capture"` | 元数据仍可显示，PCM 侧静默失败 |
| 蓝牙耳机上再开一条输出流 | **有副作用** — A2DP 重协商、卡顿、丢包 | `start` 先等捕获有帧再 `open_output`，注释写明避免失败启动时的 BT/A2DP glitch | 即使环回成功，第二路 cpal 仍可能让听感「像坏了」 |

### 2.1 核心不对称：SMTC vs PCM

```
SMTC (WinRT)                    WASAPI process loopback
─────────────                   ─────────────────────────
会话列表 / 标题 / 艺人            TargetProcessId 的 render 树
PlaybackStatus                  共享模式 Capture + LOOPBACK
Timeline 位置                   事件回调、包大小、SILENT 标志
SourceAppUserModelId (字符串)   真实 float/PCM 样本
        │                                 ▲
        │  Resolve-Pid（启发式）            │
        └────────── pid ──────────────────┘
                    ↑
            这里没有 OS 级保证
```

代码侧这条桥接非常清楚：Flutter 用 SMTC 的 `pid` 调用 `yinwei_live_start(processId)`（`player_screen.dart` → `live_transfer.dart`），原生层再对该 PID 开 process loopback（`live_transfer.rs` `capture_loop`）。**桥两端 API 语义不同，中间没有 Windows 官方「SMTC session → AudioSession/PID」一对一绑定。**

### 2.2 「白送」造成的假安全感

- Daemon 启动即输出 `YINWEI_SMTC_READY`，并在 20s 硬超时后把 `ready=true`（即便尚未真正拉到会话）——**UI 就绪 ≠ 捕获就绪**。
- 监视条文案可同时显示 `SMTC 监测中 · … · pid …` 与 `HRTF LIVE · frames …`（`system_live_monitor_bar.dart`）。`frames_captured` 在静音包被填零后仍会累加（见第 5 节），**帧计数上涨也不等于「有音乐能量」**。

---

## 3. PID / 会话陷阱（AUMID→PID 歧义）

### 3.1 SMTC 给的是 AUMID，不是 PID

Daemon 取「得分最高」会话（Playing=3 > Paused=2），读取：

```text
source = best.SourceAppUserModelId
resolved = Resolve-Pid(source)
```

（`system_media.dart` `_kDaemonScript` 中 `Emit-Once`。）

`SourceAppUserModelId` 典型形如包名/应用模型 ID 字符串，**不是进程句柄**。Windows 也不保证该字符串与「当前正在写 WASAPI render 的那个 PID」一一对应——尤其是：

| 场景 | 风险 |
|------|------|
| UWP / 应用商店壳 + 多进程 | AUMID 对应包，实际出声可能在子进程；`INCLUDE_TARGET_PROCESS_TREE` 依赖**选中的根 PID 是否在树上** |
| 汽水 / 网易云 / QQ 音乐等 | 进程名与 AUMID 碎片不完全一致；启发式靠 `musicHints` 列表碰运气 |
| 浏览器标签页媒体 | 故意延后浏览器匹配（注释：`never browsers first — they steal PID`）；一旦 AUMID 像 Edge/Chrome，仍可能抓到**错误标签/扩展宿主** |
| 多实例 / 残留进程 | `Select-Object -First 1` —— 取到的可能是**未出声的同名进程** |
| Yinwei 自身 | UI 侧有拒绝 `yinwei`/`flutter` 名的防护；若启发式落到别的无关进程，环回「成功」但内容无关 |

### 3.2 Resolve-Pid 的三级启发式（平台缺口的代码化）

```247:287:yinwei/apps/yinwei_player/lib/bridge/system_media.dart
function Resolve-Pid([string]$src) {
  $musicHints = @('SodaMusic','cloudmusic','Spotify',...)
  ...
  # 1) Prefer fragments from SMTC SourceAppUserModelId (AUMID).
  ...
  # 2) Music apps only (never browsers first — they steal PID).
  ...
  # 3) Browsers only if AUMID looks like a browser.
  ...
  return @{ pid = 0; name = '' }
}
```

这是**应用层补偿**，不是 OS API。失败模式：

- `pid = 0` → Flutter 拒绝启动（`pid <= 0`），用户看到「无法解析音乐进程 PID」。
- `pid ≠ 0` 但错误 → 原生可能：
  - 激活失败（`process loopback pid=… failed`）；
  - 或激活成功但对空进程树捕获 → ~1s 内 `frames_captured < 128` → `"process loopback silent … Wrong PID or app blocked capture."`（`live_transfer.rs` `start`）。

### 3.3 Process loopback 的树语义

`new_application_loopback_client(process_id, true)` 对应 Microsoft 的 **include target process tree**：捕获该 PID **及其子进程**的 render。若启发式选中了**兄弟进程**或**已退出播放线程的壳进程**，树下没有活跃 render → 空捕获。这与「SMTC 仍显示 Playing / 有标题」可以并存——**元数据会话与音频渲染进程解耦**。

### 3.4 FFI 注释与实现的小裂缝

`yinwei_live_start` 文档注释写 `process_id 0 = default-device loopback`，但 `capture_loop` **拒绝 0**（反馈风险）。平台上「整机环回」本可捕获任意音乐，却无法在「同时开 Yinwei 湿声输出」时安全使用——这是架构级平台冲突，不是 UI 问题。

---

## 4. 静音 / 暂停因果链（Mute → Auto-pause）

### 4.1 理想产品 vs 平台现实

| 理想 Transfer | Windows + 主流音乐 App 现实 |
|---------------|----------------------------|
| 抓源 PCM → HRTF → 只播湿声 | 抓源需要源进程继续 render |
| 源会话静音，避免干湿双声 | `ISimpleAudioVolume::SetMute` / 音量 0 常被应用解释为「用户静音了本会话」→ **数秒内自动暂停** |
| 听感 = 纯 Spatial | 暂停后 loopback 变空/静默；或被迫不静音 → **干声盖过湿声**，「没有真正效果」 |

### 4.2 代码已记录的因果与当前策略

模块头注释仍写「Callers should mute the source app session」（`live_transfer.rs` L3–4），但 Dart 层已明确反悔：

```138:148:yinwei/apps/yinwei_player/lib/bridge/system_media.dart
  /// Muting / zeroing the music app session (ISimpleAudioVolume) makes many
  /// players (汽水音乐, Spotify, …) auto-pause within a few seconds. Live HRTF
  /// therefore overlays wet Spatial on top of dry source audio instead.
  Future<void> setSourceMuted(bool muted) async {
    ... // intentionally no-op
  }
```

`player_screen.dart` 同样写死：

> Never mute/duck source apps — SetMute/volume0 makes 汽水/Spotify auto-pause.

`live_transfer.dart`：`Start blocks ~1s until capture has PCM … — no mute of source app.`

成功启动后的 SnackBar 也承认双声：

> 「源应用未静音，可同时听到干声+空间湿声」

### 4.3 因果链（会话已知症状）

```
Transfer ON
  → （旧路径）mute 源会话
  → 汽水/Spotify 检测会话静音/无输出意图
  → 应用自动 Pause
  → SMTC PlaybackStatus → Paused（检测仍「有会话」）
  → process loopback 无活跃 render / SILENT
  → 听感中断或轰鸣（若 SILENT 未正确处理）
```

当前路径改为不静音后，自动暂停症状缓解，但引入新的平台听感失败：

```
Transfer ON（不静音）
  → 源 App 继续走默认设备干声（往往已是用户习惯的 A2DP/扬声器路径）
  → Yinwei 再开一路 cpal Spatial 湿声
  → 同一耳机上两路混音：干声响度/延迟通常占优
  → 用户结论：「没有真正的 Transfer 效果」
```

**这不是 HRTF 系数算错的主因，而是 Windows 会话模型 + 应用保活策略堵住了「替换式」Transfer。**

---

## 5. Silent-buffer 轰鸣（`AUDCLNT_BUFFERFLAGS_SILENT`）

### 5.1 平台语义（必须按字面遵守）

微软 / 实务约定：

- 包带 **`AUDCLNT_BUFFERFLAGS_SILENT`** 时：**把该段当作静音**；缓冲区**内存内容未定义**，不得当 PCM 解读。
- 目标进程 idle 时，process/device loopback 常见行为是 **`GetNextPacketSize == 0`（根本不送包）**，而不是连续送全零包。

二者都不是「正常小声音乐」。

### 5.2 与「引擎咆哮」的对应关系

`live_transfer.rs` 现已显式处理：

```356:367:yinwei/crates/spatial_core/src/live_transfer.rs
            // CRITICAL: AUDCLNT_BUFFERFLAGS_SILENT means buffer contents are UNDEFINED.
            // Treating them as float PCM produces loud "engine roar" that continues
            // after the music app has stopped.
            if flags.silent {
                for _ in 0..got_bytes {
                    byte_q.push_back(0);
                }
            } else {
                ...
            }
```

输出路径也去掉 makeup gain，注释写明：

> No makeup gain — silent-packet garbage + gain became an "engine roar".

另有近静音能量门限（`energy < 1e-8` 则填零），防止 HRTF/混响把底噪放大成隆隆声。

### 5.3 为何这仍是「持续失败」叙事的一部分

1. **历史症状真实且可复现于平台语义错误**——不是玄学。
2. **修补静音标志 ≠ 修好 Transfer**：只是去掉一种灾难性假阳性；真正音乐能量仍依赖正确 PID + 活跃 render + 可听湿声相对干声的策略。
3. **与 mute/auto-pause 耦合**：源被应用暂停后，更容易进入 SILENT / 无包状态；旧管线若误读 SILENT，会出现「歌停了还在吼」——与会话描述完全吻合。

### 5.4 帧计数陷阱

静音包被替换为 0 字节后，仍会组装成 `STREAM_CHUNK` 帧并 `frames_captured.fetch_add`。因此：

- 启动门槛 `frames_captured >= 128` 可能被**全零帧**满足（若持续有 SILENT 包而非无包）；
- UI `frames=…` 上涨不能证明「抓住了音乐」。

（若目标完全 idle 且 OS 不送包，则仍会在 ~1s 超时失败——另一类失败。）

---

## 6. Win10/11 上「可工作的 process-loopback Transfer」前置清单

下列任一项不满足，都会表现为「SMTC 正常 / Transfer 失败或无效」。本清单只谈**平台与会话前置条件**，不谈 Flutter 布局。

### 6.1 OS / API

- [ ] Windows 10 **Build ≥ 20348**（或经实测确认本机 `ActivateAudioInterfaceAsync` process loopback 可用）；更旧系统仅有设备环回。
- [ ] 构建启用 `spatial_core` 的 `realtime` + `windows`（`live_transfer` 受 `cfg` 门控）。
- [ ] 默认输出设备稳定；避免在环回启动瞬间热插拔声卡/切换「空间音效」增强。

### 6.2 源应用与 PID

- [ ] 目标音乐 App **正在 Playing**，且 **该 PID 进程树内确有 WASAPI render**（任务管理器/音频会话列表可核对）。
- [ ] SMTC `SourceAppUserModelId` 经解析得到的 PID **与出声进程一致**（不要只信 UI 上的 process 名字符串）。
- [ ] PID ≠ Yinwei / Flutter / 终端 / 浏览器误伤实例。
- [ ] 目标未处于「仅有媒体会话、音频由另一进程渲染」的壳模式（否则需树根选对）。

### 6.3 策略 / DRM / 权限

- [ ] 源 App 未对环回输出实施保护性静默（部分流媒体/商店应用可能阻止或空数据——表现为 silent / blocked capture）。
- [ ] 企业/隐私策略未禁用环回类捕获（较少见，但失败码应记入诊断）。
- [ ] 源 App **不会因为会话 mute/duck 而自动暂停**——若产品坚持「只听湿声」，需接受：在汽水/Spotify 上**当前 Windows 公开 API 路径基本不可用**。

### 6.4 输出与双流（听感）

- [ ] 接受现状策略则：干湿同播，湿声需足够响/可 A/B（否则「无真正效果」）。
- [ ] 若使用蓝牙 A2DP：预留重协商毛刺；代码已「先捕获后开 cpal」，但仍无法消除**第二路流**本身的平台副作用。
- [ ] 有线耳机 / 同设备共时钟时，双流延迟差通常更可控，更适合验收。

### 6.5 管线健康（平台语义）

- [ ] 捕获侧尊重 `AUDCLNT_BUFFERFLAGS_SILENT`（已做）。
- [ ] 启动判定不能仅靠 `frames_captured`；应有**能量/频谱门禁**才能宣称「抓住了音乐」（当前能量门只用于压底噪，不用于启动成功标准）。
- [ ] 设备环回（pid=0）在「Yinwei 同时输出」场景下保持禁用，除非改为 exclude-self 树或独立虚声卡——否则平台反馈不可避免。

### 6.6 「元数据工作 ≠ 音频变换工作」验收句式

| 绿灯 | 只能证明 | 不能证明 |
|------|----------|----------|
| SMTC 标题/艺人 | 媒体会话存在 | 能抓到 PCM |
| `pid > 0` | 启发式找到了某进程 | 该进程正在出声 |
| `yinwei_live_start == 0` | 环回客户端启动且短期内有帧 | 帧是音乐而非静音/噪声 |
| `HRTF LIVE` 字幕 / az 在动 | DSP 线程在跑 | 用户听到可辨的 Spatial 替换效果 |
| SnackBar「已叠加」 | 产品选择了不静音策略 | Transfer 语义完成 |

---

## 7. 范围外（Out of scope）

本稿**不**分析、不评价：

- Flutter Island / Full 窗口 chrome、置顶、click-through、DPI；
- 产品排序与验收门禁设计（见 [`ANALYSIS_LIVE_TRANSFER_PRODUCT_PROCESS.md`](./ANALYSIS_LIVE_TRANSFER_PRODUCT_PROCESS.md)）；
- HRTF 滤波器质量、orbit buzz、pose slew 等**文件播放** DSP 问题；
- 具体修复补丁、API 选型实现方案或代码改动。

---

## 8. 一句话收束

在 Windows 上，Yinwei Live Transfer 卡在**平台能力缝**：SMTC 负责「看见媒体」，process loopback 负责「听见进程」，二者靠不可靠的 AUMID→PID 粘合；而「静音源以完成真正替换」又撞上音乐 App 的自动暂停策略——所以会出现会话已知的整组症状：**检测滞后但可用、mute 导致停播、SILENT 误读曾吼叫、错 PID、以及最终听感上没有真正的 Transfer。**
