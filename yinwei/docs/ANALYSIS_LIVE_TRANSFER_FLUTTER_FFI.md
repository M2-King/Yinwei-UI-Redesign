# 分析：Yinwei Live Transfer 持续失败（Flutter ↔ FFI ↔ DLL / UI 接线）

> 范围：仅集成面与 UI 接线。不改应用代码。不含深度 WASAPI / HRTF DSP 根因挖掘。  
> 焦点文件：`live_transfer.dart`、`yinwei_bindings.dart`、`player_screen.dart`、`system_live_monitor_bar.dart`、`island_bar.dart`、`island_now_playing.dart`、`tools/build_native_windows.ps1`。

---

## 1. Verdict（结论）

**Live Transfer「总是失败」在本透镜下，主因不是「环回算法写错了」这一条，而是多层集成/接线假象叠加：**

1. **部署面**：`spatial_core.dll` 被运行中的 Flutter 进程锁住 → `build_native_windows.ps1` 的 `Copy-Item` 失败或只拷到部分路径 → 进程仍加载**无 `yinwei_live_*` 符号的旧 DLL**，或加载到「文件会话」与「live 会话」各一份映射。
2. **ABI / 会话面**：文件播放走 `GLOBAL` `PlayerSession`（`yinwei_*`），系统环回走独立 `LIVE` 单例（`yinwei_live_*`）。Dart 侧若把姿态拖拽写进 `EngineController` → `yinwei_set_params`，**听感路径仍是 live 引擎**，UI 却以为在调湿声。
3. **时序面（历史）**：早期 Dart 曾 **`liveSetParams` / `liveSetMode` 在 `liveStart` 之前**；native 虽可用 `ensure_live()` 建引擎，但 start 会重置队列/线程，且曾从文件会话拷 mode，易落到 **Original / 无有效 params**。当前已改为 **先 `liveStart` 再 `liveSetParams` + `liveSetMode(1)`**，但文档与部分 UI 文案仍滞后。
4. **UI 假阳性**：`IslandNowPlaying.liveTransfer` 对「Yinwei 本地 Spatial 播放」也标 `true` 并显示 **「Yinwei LIVE」**；与真实 WASAPI→HRTF 的 **「HRTF LIVE」** 共用视觉语言（高亮边框、accent、orbit 动画）。用户看到 LIVE ≠ 环回湿声已通。
5. **产品语义漂移**：验收文档仍写「Transfer 时静音源」；实现已刻意 **不静音**（`setSourceMuted` no-op），干声 + 湿声叠听。用户报告「还是干声 / 没空间感」时，可能是 **叠听掩盖湿声**，或 **`running=true` 但 frames 停滞 / 错误 PID**，UI 仍显示 HRTF ON。

**一句话：先把「DLL 是否新鲜 + 符号是否齐全 + start 是否真成功 + frames 是否上涨 + UI 是否把文件 LIVE 当成环回 LIVE」五关在 Full 窗验完，再谈 Island 与 DSP。**

---

## 2. Integration surface map（集成面地图）

```text
┌─ Full: SystemLiveMonitorBar ──┐     ┌─ Island: IslandBar (collapsed/expanded) ─┐
│  「真实Transfer」/「HRTF ON」   │     │  仅 expanded 有「真实Transfer」按钮          │
└────────────┬──────────────────┘     └──────────────────┬──────────────────────┘
             │  onToggleLiveHrtf                          │
             └──────────────────┬─────────────────────────┘
                                ▼
                    PlayerScreen._toggleLiveHrtf
                    ├─ 前置：SMTC hasTrack / pid>0 / !yinwei|flutter
                    ├─ 可选 pause 本地 EngineController
                    └─ LiveTransferController.start/stop
                                ▼
                    YinweiBindings (DynamicLibrary 单例)
                    ├─ 构造时 lookup：yinwei_open / set_params / play …（文件会话）
                    └─ 运行时 lookup：yinwei_live_*（可选符号；失败靠 try/catch）
                                ▼
                    spatial_core.dll
                    ├─ GLOBAL Mutex<PlayerSession>     ← 本地文件 HRTF
                    └─ LIVE  Mutex<LiveTransferEngine> ← WASAPI loopback → HRTF → cpal
```

| 层 | 组件 | 职责 | 易错点 |
|----|------|------|--------|
| UI Full | `SystemLiveMonitorBar` | SMTC 元数据 + Transfer 开关；副标题带 pid / az / **frames** | `running` 为真即「HRTF LIVE」，不校验 frames 斜率 |
| UI Island | `IslandBar` + `IslandNowPlaying` | 合并 Yinwei 文件会话与 SMTC；展开后开关 | `liveTransfer` 语义双载；collapsed **无** Transfer 按钮 |
| 控制 | `PlayerScreen` | 双入口共用 `_live`；SMTC 停播 500ms debounce 自动 stop；dispose 时 stop | 进岛/出岛不 stop；姿态拖拽仍写文件会话 |
| Dart 桥 | `LiveTransferController` | `available` / start / stop / telemetry | `available` 只探 `liveIsRunning`；start 后 params 错误码未检查 |
| FFI | `YinweiBindings` | DLL 路径优先级；live 符号按需 lookup | 多候选路径可命中 stale；isolate 二次 `open` 可造双 GLOBAL |
| 部署 | `build_native_windows.ps1` | cargo release → 拷贝到 runner / Debug / Release | 进程锁 DLL；脚本无「失败即停」对锁文件的提示 |
| Native | `ffi.rs` + `live_transfer.rs` | `ensure_live` → start(~1s 等 PCM) → set_params | start 失败返回 AudioDevice；与 Dart `fail()` 接线依赖 `readLastError` |

**关键数据流（当前正确顺序）：**

1. `liveStart(pid)` → native `ensure_live` + `set_mode(Spatial)` + `eng.start`（阻塞至 ≥128 frames 或失败）
2. Dart `liveSetParams(...)` → native 再次 `ensure_live` + `eng.set_params`
3. Dart `liveSetMode(1)` → Spatial
4. 读一次 `liveCapturedFrames()`，置 `running=true`，`notifyListeners`
5. 80ms timer：`refreshTelemetry()` → frames / `liveIsRunning` 纠偏

---

## 3. Ordered failure timeline（近期迭代失败时间线）

按产品/接线演进顺序（非 git 正式提交号；反映本仓库 Island → SMTC → Live HRTF 迭代）：

| # | 阶段 | 现象 | 集成/接线根因 |
|---|------|------|----------------|
| T0 | Island 仅绑 `EngineController` | 汽水在播，岛上仍是演示曲 | 无 SMTC；「Transfer」= 本地 Spatial 可视化 |
| T1 | SMTC 元数据接入 | 标题对了，副标题曾标 **SMTC LIVE**，仍无湿声 | 元数据当 Transfer；用户以为「LIVE=有 HRTF」 |
| T2 | 冷启动 WinRT / 每 tick 起 PowerShell | 进岛卡 5–15s / 卡顿 | 非 DLL，但是 **Island 验收阻塞**，掩盖后续 Transfer 调试 |
| T3 | 常驻 SMTC daemon + READY 立刻返回 | UI 通了；仍无环回 | 接线完成一半 |
| T4 | 首版 `yinwei_live_*` + Island「真实Transfer」 | 编译过；听感无/启动失败 | **Debug DLL 被锁**，新符号未进运行中 exe 旁 DLL；或 pid=0 |
| T5 | Dart **先 `liveSetParams` 再 `liveStart`** | 偶发无空间感 / mode 怪异 | start 重置 capture；曾从文件会话 sync mode（Original）污染 live |
| T6 | 源会话 SetMute / volume0 | 汽水/Spotify **自动暂停** → SMTC `playing=false` → UI debounce **自动 stop** | 「Transfer 一开就停」像引擎崩，实为 **自打断环** |
| T7 | `setSourceMuted` 改为 no-op；文档仍写 mute | 「HRTF ON」但听起来像干声 | **干+湿叠听**；验收清单与实现矛盾 |
| T8 | 改为 **先 start 后 set_params**；Full 窗加 `SystemLiveMonitorBar` | 启动成功率上升；frames 出现在副标题 | 仍有：姿态写错会话、双 DLL、符号缺失、Yinwei LIVE 假阳性 |
| T9 |（当前） | 间歇失败 / 「显示 LIVE 但没效果」 | 见 §4–§5 |

**当前代码已缓解但仍残留的接线债：**

- `live_transfer.dart` 注释已写明「params after ensure_live inside start」——顺序正确。
- `yinwei_live_start` 注释：**不要**再从文件会话拷 Original mode。
- Full / Island **共用** `_live`，入口对称；但 Island collapsed 无法开 Transfer，用户常在「只看 LIVE 字幕」状态下误判。

---

## 4. Wiring / UX false positives（「显示 LIVE 但干声」）

### 4.1 词语「LIVE」至少三种含义

| UI 文案 | 真实含义 | 是否 WASAPI 环回 |
|---------|----------|------------------|
| `Yinwei LIVE az …°` | 本地文件 Spatial 播放中 | 否 |
| `HRTF LIVE · pid …` | `LiveTransferController.running` | 是（声称） |
| 历史 `SMTC LIVE` | 仅系统媒体元数据 | 否 |

`IslandNowPlaying.resolve`：

- `liveHrtfRunning && system.hasTrack` → 真环回字幕；
- 否则若 Yinwei 有打开文件且 Spatial+playing → **`liveTransfer: true` +「Yinwei LIVE」**。

Island 边框 / `_MiniPose.active` / envelopment meter 都看 `now.liveTransfer`，**不区分**上述两种。Full 状态栏 `HRTF LIVE · $backend` 只看 `_live.running`，相对干净；Island 更容易误导。

### 4.2 `running=true` 仍可能「听不到湿声」

- **叠听设计**：干声未静音，湿声弱或设备混音时听感≈干声。SnackBar 已写「干声+空间湿声」，但按钮文案仍是「HRTF ON」，像独家湿声路径。
- **frames 冻结**：`refreshTelemetry` 会在 `!liveIsRunning` 时清 `running`；若 native 卡在 running 但 capture 空转，UI 仍 LIVE。副标题有 frames，但 **无「帧率/斜率」告警色**。
- **启动瞬间 frames**：start 成功后立刻读 frames（通常 ≥128）。若用户只看 SnackBar 里的数字、随后 capture 挂掉，需依赖 80ms 轮询纠偏——短暂窗口内仍显示成功。
- **姿态拖拽假通**：Full 窗 `OrbitVisualizer.onPoseChanged` → `c.setParams` → **`yinwei_set_params`（文件会话）**，**不**调用 `liveSetParams`。球在动、本地 params 变，live 湿声姿态不动 → 「UI 有空间、耳机仍干」。

### 4.3 自动 stop 假失败

`_onSmtcChange`：live 运行中且 SMTC 无轨/暂停 → 500ms 后 `_stopLiveHrtf`。

- 源应用缓冲/切歌瞬间 `playing=false` → Transfer 被掐断；
- 历史 mute 策略会主动制造该路径（T6）。

### 4.4 `available` / 符号假阴性与假阳性

- `available`：`tryLoad` 成功后只调用 `liveIsRunning()`；符号缺失 → false → 明确错误「缺少 live API」（好）。
- `liveStart` / `liveSetParams` **无** try/catch：DLL 有部分符号或签名不匹配时可能直接抛给 isolate/UI。
- `liveSetParams` / `liveSetMode` 返回码在 start 成功路径上 **被忽略** → params 失败仍 `running=true`（空间参数未生效的静默假阳性）。

### 4.5 双入口不一致

| | Full `SystemLiveMonitorBar` | Island expanded | Island collapsed |
|--|----------------------------|-----------------|------------------|
| Transfer 开关 | 有 | 有 | **无** |
| frames 遥测 | 有 | 无（仅 az） | 无 |
| LIVE 语义 | 仅 `_live.running` | 混用 `now.liveTransfer` | 同左 |

---

## 5. Build / deploy footguns（构建与部署陷阱）

### 5.1 DLL 锁与多副本

`build_native_windows.ps1` 向三处拷贝：

- `apps/yinwei_player/windows/runner/spatial_core.dll`
- `build/windows/x64/runner/Debug/spatial_core.dll`
- `build/windows/x64/runner/Release/spatial_core.dll`

**运行中的 `flutter run` / 已启动的 exe 会锁住 Debug（或 runner）下的 DLL。** 迭代记录中已出现「Debug copy 失败、runner 拷上了」——下次启动若从仍锁定的旧 Debug 目录加载，**新 live 符号永远进不了进程**。

热重载 / hot restart：**不会**重新 `DynamicLibrary.open`。必须 **完全退出进程** 再跑脚本再启动。

### 5.2 加载路径优先级（`YinweiBindings._openLib`）

优先：`exeDir\spatial_core.dll` → 再 cwd 下 Debug/Release/runner/cwd/裸名。

设计意图是避开 cwd 陈旧副本；仍可能：

- 开发时 cwd 与 exeDir 不一致，误以为「脚本已拷贝」；
- isolate 若未 `loadFromPath(resolvedLibraryPath)` 而再 `open` 相对路径 → **第二份映射 → 第二份 GLOBAL**（`native_engine.dart` 注释已警告；live 的 `LIVE` 单例同样按模块实例隔离）。

### 5.3 Mock 与 Native 并存的认知陷阱

`EngineBootstrap`：DLL 都打不开 → Mock；状态栏「Mock · 请运行 build…」。

但也可能：**基础 `yinwei_*` 在，live 符号不在** → Native 文件播放正常，Transfer 报「缺少 live API」。用户以为「已经是 Native 了为什么 Transfer 不行」。

### 5.4 脚本缺口

- 无「目标文件是否被占用」预检；
- 无拷贝后 **导出符号表 / 版本戳** 校验（例如确认 `yinwei_live_start` 存在）；
- 成功文案只提示「Status bar: Native · spatial_core」，**不**提示验证 live API。

---

## 6. What Full-window validation harness should look like（先 Full，后 Island）

在动 Island / click-through / 窗口 morph 之前，Full 窗应成为 **唯一合格判据**：

### 6.1 前置清单（每次验听）

1. 退出所有 `yinwei_player.exe` / `flutter run`。
2. `powershell -ExecutionPolicy Bypass -File yinwei/tools/build_native_windows.ps1` —— 三处 Copy 均成功。
3. （建议）对实际将加载的 DLL 做符号检查：`yinwei_live_start` / `yinwei_live_set_params` / `yinwei_live_captured_frames`。
4. `flutter run -d windows`（冷启，非 hot restart）。
5. 状态栏：`Native · spatial_core`（非 Mock）。

### 6.2 Full 窗操作序列

1. 耳机播放 **汽水音乐**（或 Spotify），确认 `SystemLiveMonitorBar` 标题/进程名/ **pid>0**。
2. 点 **真实Transfer**。
3. **Pass 条件（全部满足）**：
   - 按钮变 **HRTF ON**，副标题 `HRTF LIVE · … · pid N · az … · frames F`；
   - **F 在数秒内持续上涨**（不仅启动瞬间 ≥128）；
   - SnackBar 无错误；`lastError` 为空；
   - 听感：在已知「干+湿叠听」前提下，能辨出空间/方位变化（可临时降源音量人工对比——**不要**用会触发应用 pause 的 session mute）。
4. 点 **HRTF ON** 关闭 → frames 归零、`running=false`。
5. 再开一次 → 同上（防「只能开一次」的 dispose/线程泄漏）。
6. 播放中暂停源应用 → ≤1s 内自动 stop（验证 debounce，非崩溃）。
7. **负例**：pid 指向 yinwei/flutter → 应明确拒绝啸叫，而非假 LIVE。

### 6.3 接线探针（建议写进验收，不必改 DSP）

| 探针 | 期望 |
|------|------|
| `YinweiBindings.resolvedLibraryPath` | 指向刚拷贝的那份 DLL |
| start 前后 `liveCapturedFrames` | 失败≈0；成功单调增 |
| 拖球时 | 若 live 运行，姿态应走 `liveSetParams`（当前未接——harness 应标为 **已知缺口**） |
| Full ↔ Island 切换中途 | live 应保持或明确 stop（当前保持；勿当失败） |

### 6.4 再进 Island

仅当 §6.2 全绿后：

- 展开岛 → 真实Transfer → 字幕 `HRTF LIVE · pid …`（**不是** `Yinwei LIVE`）；
- collapsed 仅展示状态，不作为开关键入口；
- 勿把「边框变亮」当成湿声证据。

---

## 7. Out of scope（本稿不做）

- WASAPI process loopback 权限、Silent 进程、蓝牙 A2DP 设备协商等 **深度捕获/DSP** 问题；
- `HrtfStreamer` / orbit HRIR / pose slew buzz（见 `REPORT_*` / `IMPLEMENTATION_ORBIT_*`）；
- SMTC PowerShell 守护进程稳定性以外的 WinRT 细节；
- 改代码、改脚本、改验收自动化实现（本稿只定义 harness 应长什么样）。

---

## 8. 对本透镜的优先修复方向（建议，非实施）

1. **部署**：锁文件检测 + 强制冷启 + live 符号冒烟。  
2. **语义**：拆开 `liveTransfer`（环回）与 `yinweiSpatialLive`（文件）；Island 禁用「Yinwei LIVE」抢 HRTF 视觉。  
3. **接线**：live 运行时 pose/sidebar → `liveSetParams`；检查 set_params 返回码。  
4. **遥测**：frames 斜率告警；`running && frames` 停滞则降级 UI。  
5. **文档**：与「不静音源 / 干湿叠听」对齐，删除「source muted」验收句。

---

*分析透镜：Flutter ↔ FFI ↔ DLL integration & UI wiring。日期：2026-09-13。*
