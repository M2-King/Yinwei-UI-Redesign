# 音围 — 分段 Implementation

> UI 已锁定（桌面 + 手机）。下文按可交付段推进后端 → 联调 → 打包。  
> 主规格：[`IMPLEMENTATION.md`](./IMPLEMENTATION.md)

---

## 总览

```mermaid
flowchart LR
  P0[P0_EngineExport] --> P1[P1_RealtimeCpal]
  P1 --> P2[P2_FlutterBridge]
  P2 --> P3[P3_WinPack]
```

| 段 | 目标 | 验收 | 状态 |
|----|------|------|------|
| **P0** | 离线 HRTF + CLI 导出 WAV | `cargo test` + `yinwei … -o out.wav` | **完成** |
| **P1** | 实时试听（cpal）+ 参数热更新 | 本机耳机可听 Original/Spatial/音位 | **P1.1–P1.3 代码已合入**（云端无声卡则跳过听感） |
| **P2** | Flutter ↔ Rust（FRB）接到锁定 UI | 点播放/音位/导出走真引擎 | **P2.0–P2.4 进行中**（Session+Dart 已合；Windows codegen 待办） |
| **P3** | Windows `.exe` 打包 | 安装后离线可用 | 未开始 |

---

## P0 — 离线引擎（已完成）

**交付物**

- `spatial_core`: decode → Mid/Side → HRTF → reverb → `export_wav`
- `yinwei_cli` 离线导出
- HRIR: `IRC_1002_C.bin`

**命令**

```bash
cd yinwei
cargo test -p spatial_core
cargo run -p yinwei_cli --release -- in.wav -o out.wav --preset left-rear
```

---

## P1 — 实时试听（本段）

### P1.1 预览缓冲 API

- `Engine::render_frames() -> Vec<(f32,f32)>`  
  按当前 `PlaybackMode` + `SpatialParams` 生成可播立体声（短曲可整轨渲染）。
- 参数变更 → `preview_dirty`；下次 play / 显式 `rebuild_preview()` 重渲。

### P1.2 cpal 输出

- `playback::OutputPlayer`：从共享 ring/buffer 拉流到默认输出设备。
- API：`start` / `stop` / `pause` / `seek` / `set_frames`.
- 无声卡环境（CI/云）：`start` 返回可识别错误，不崩。

### P1.3 CLI `--play`

```bash
yinwei in.wav --play --preset right --motion orbit
# Ctrl+C 停止
```

### P1 验收

- [ ] `render_frames` 单测：Spatial ≠ Original（能量/相关差异）
- [ ] 有声卡机器：`--play` 可听方位变化
- [ ] 无声卡：单元测试仍绿

### P1 不做

- 边解码边 HRTF 的超低延迟流式（P1.5+）
- Flutter 联调（P2）

---

## P2 — Flutter 桥接

> **详细规格（先于代码）**：[`IMPLEMENTATION_P2.md`](./IMPLEMENTATION_P2.md)

### P2.0 规格

- API / DTO / UI 事件 / FRB 策略 / 验收 — 见上文件 §1–§9

### P2.1–P2.5（摘要）

| 子段 | 内容 |
|------|------|
| P2.1 | Rust `PlayerSession` |
| P2.2 | DTO 与 Dart 模型对齐 |
| P2.3 | `EngineController` + UI 接线 |
| P2.4 | FRB 脚手架（Windows codegen） |
| P2.5 | 文件选择器 + 导出进度 |

### P2 验收

- Windows：打开 → 试听 → 改音位 → 导出  
- 与手机/桌面样图控件一一对应  
- 云端：Session + Dart 契约可测，无 Flutter 不阻塞 P2.1–P2.3  

---

## P3 — Windows 打包

- `flutter build windows` + 附带 `spatial_core` DLL  
- 安装包 / 绿色 zip  
- 离线运行说明（耳机推荐）  

---

## 目录约定（随段增长）

```
yinwei/
  docs/IMPLEMENTATION.md          # 产品+UI+引擎契约
  docs/IMPLEMENTATION_PHASES.md   # 本文件：分段计划
  crates/spatial_core/            # P0–P1 引擎
  crates/yinwei_cli/              # P0 导出 / P1 --play
  apps/yinwei_player/             # P2 Flutter
  apps/web_preview/               # UI 预览（只读参考）
```

## 当前执行焦点

**P2.0 规格已锁定**：[`IMPLEMENTATION_P2.md`](./IMPLEMENTATION_P2.md)。  
**正在做 P2.1**：Rust `PlayerSession`。
