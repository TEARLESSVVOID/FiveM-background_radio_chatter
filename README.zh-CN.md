<div align="center">

# 📻 背景警用电台杂谈 / Background Radio Chatter

**FiveM 沉浸式 3D 空间警用电台环境音 —— 由 LSPDFR 插件移植而来**

[![FiveM](https://img.shields.io/badge/platform-FiveM-blue)](https://fivem.net)
[![GTA V](https://img.shields.io/badge/game-GTA%20V-orange)](https://www.rockstargames.com/V/)
[![LSPDFR 移植](https://img.shields.io/badge/ported%20from-LSPDFR%20v1.2.1-9cf)](https://www.lcpdfr.com/)
[![License](https://img.shields.io/badge/license-MIT-green)](#-开源许可)
[![Version](https://img.shields.io/badge/version-1.0.0-yellow)]()

[English](README.md) | **简体中文**

</div>

---

## ✨ 概述

**Background Radio Chatter** 为你的 FiveM 角色扮演服务器带来真实的警用电台环境音。每位玩家都是一个"活的电台声源"——播报真实的调度杂谈，附近玩家可以在 **3D 空间中真切听到**，并带有真实的距离衰减与空气吸声效果。

本资源是对 LSPDFR 知名插件 *Background Radio Chatter v1.2.1* 的**逆向移植版**，以 Lua + NUI（Web Audio API）从零重建为原生 FiveM 资源。

<div align="center">

| | |
|:---:|:---:|
| 🎧 **真 3D 音效** | HRTF 双耳声像、距离衰减、远场闷音 |
| 🌐 **全服同步** | 所有玩家听到*完全相同*的播放序列 |
| 🎛️ **219 条 WAV** | 真实电台杂谈，随机调度播放 |
| ⌨️ **零输入占用** | 纯键盘菜单——边走边设置不卡移动 |

</div>

---

## 📋 目录

- [核心特性](#-核心特性)
- [工作原理](#-工作原理)
- [安装](#-安装)
- [使用方法](#-使用方法)
- [配置说明](#-配置说明)
- [架构设计](#-架构设计)
- [诊断排查](#-诊断排查)
- [致谢](#-致谢)
- [开源许可](#-开源许可)

---

## 🎯 核心特性

### 3D 空间音效引擎
- **HRTF PannerNode** —— 双耳声像由游戏相机朝向实时驱动；绕着某位玩家走一圈，他的电台会在你两耳间自然摆动
- **指数距离衰减** —— `1.2 m` 内全额响度，10 m 处约 8%，20 m 处约 3%（超出声源半径几乎不可闻——远处的电台就该快听不见）
- **空气吸声** —— 低通滤波器从 `19 kHz`（近处）扫到 `1.5 kHz`（远处），远处的电台听起来自然发闷
- **按声源计响度** —— 每台电台以*其主人设置的音量*发声，与现实中的扬声器一致

### 服务器指挥端（完美同步）
- 服务器是**唯一的随机源**——所有玩家听到完全相同的片段、完全相同的时刻
- 客户端通过 **RTT/2 时钟校准**对齐服务器时刻，并每 30 秒重校准对抗计时器漂移
- 提前 2.5 秒广播开播时刻，实现帧级对齐

### 智能播放调度
- 两条录音之间随机间隔 `5–15 秒`，并有一定概率触发长静默（`10–30 秒`）
- 防重复机制——绝不会连续听到同一条录音
- 收听与发声解耦——**关掉自己的电台依然能听见附近开台者**；开关只静音*你自己的*声源

### 性能优先
- 音频**解码一次**，所有声源共享
- 声源距离裁剪 + 数量硬上限（同时最多 `8` 个远端声源）
- 听者位置更新节流至 `10 Hz`

### 玩家体验
- 内置 **219 条真实 WAV 电台杂谈**
- 纯键盘设置菜单（NUI），**全程不捕获鼠标与焦点**——移动、视角、聊天一切照常
- 所有设置通过 KVP 按玩家持久化
- 音量均衡选项，拉平各条录音的响度差异

---

## 🚀 安装

1. **下载**或克隆本仓库：

   ```bash
   git clone https://github.com/TEARLESSVVOID/FiveM-background_radio_chatter.git
   ```

2. 将 `background_radio_chatter` 文件夹**复制**到服务器的 `resources` 目录。

3. 在 `server.cfg` 中**添加**以下一行：

   ```cfg
   ensure background_radio_chatter
   ```

4. **重启**服务器。搞定！✔️

> **环境要求：** FiveM 服务器（推荐开启 OneSync 以获得准确的玩家范围判定）。无任何外部依赖——资源完全自包含。

---

## 🎮 使用方法

| 指令 | 说明 |
|---|---|
| `/Sncradio` | 打开设置菜单（电台开关就是菜单第一项） |
| `/brcdebug` | 打印音频链路每一跳的完整诊断信息 |

**菜单操作**（纯键盘，不占用游戏输入）：

| 按键 | 功能 |
|---|---|
| `↑` / `↓` | 上下选择 |
| `←` / `→` | 修改数值 |
| `回车` | 确认（测试播放 / 重置 / 保存） |
| `退格` / `Esc` | 保存并关闭 |

菜单可停靠在**左侧 / 居中 / 右侧**，菜单打开期间玩家依然可以自由移动角色。

---

## ⚙️ 配置说明

所有参数集中在 [`config.lua`](config.lua)。核心配置：

### 玩家默认设置（`Config.Defaults`）

| 键 | 默认值 | 说明 |
|---|---|---|
| `Enabled` | `false` | 资源加载后自动开启电台 |
| `Notifications` | `true` | GTA 屏幕通知 |
| `Volume` | `0.35` | 主音量 `0.0–1.0` |
| `NormalizeVolume` | `true` | 均衡各 WAV 响度 |
| `MenuPosition` | `'Right'` | 菜单停靠：`Left` / `Center` / `Right` |

### 播放调度（`Config.Schedule`）——*仅服务器生效*

| 键 | 默认值 | 说明 |
|---|---|---|
| `MinDelay` / `MaxDelay` | `5` / `15` | 录音间随机间隔（秒） |
| `PreventRepeat` | `true` | 不连续播放同一条录音 |
| `LongSilenceChance` | `1` | 每个间隔触发长静默的概率（%） |
| `LongSilenceMin` / `LongSilenceMax` | `10` / `30` | 长静默追加时长（秒） |

> ⚠️ 修改调度参数需重启资源（`restart background_radio_chatter`）。这些值由服务器全权管理——这是刻意设计，因为玩家本地修改会破坏全服同步。

### 3D 音效与同步（`Config.Sync`）

| 键 | 默认值 | 说明 |
|---|---|---|
| `StartLead` | `2500` 毫秒 | 同步开播前的广播提前量 |
| `ResyncEvery` | `30` 秒 | 时钟重校准间隔 |
| `EmitterRange` | `6.0` 米 | 电台可闻半径，超出即销毁声源 |
| `RefDistance` | `1.2` 米 | 此距离内全额响度 |
| `Rolloff` | `1.4` | 距离衰减指数（越大衰减越快） |
| `LowpassNear` / `LowpassFar` | `19000` / `1500` Hz | 空气吸声低通扫频 |
| `MaxEmitters` | `8` | 同时渲染的远端声源上限 |

---

## 🏗️ 架构设计

```
┌──────────────────────── 服务器（指挥端）────────────────────────┐
│  • 唯一随机源：全服共享同一条播放序列                            │
│  • 广播精确开播时刻（GetGameTimer + StartLead）                  │
│  • 记录每位玩家的发声音量 + 开关状态（杜绝幽灵声源）              │
└──────────────┬────────────────────────────────────┬────────────┘
               │ brc:transmission {clip, startAt, …} │ brc:volumesUpdate
               │ brc:syncReply（时钟偏移，RTT/2）     │
┌──────────────▼───────── 客户端（Lua）──────────────┴────────────┐
│  • 依据校准后的时钟偏移，对齐服务器开播时刻                      │
│  • 收集可闻半径内的声源（10Hz、数量上限、按距离排序）            │
│  • 将听者位姿 + 声源列表下发给 NUI                               │
└──────────────────────────────┬───────────────────────────────────┘
                               │ SendNUIMessage
┌──────────────────────────────▼──────── NUI（Web Audio）─────────┐
│  • 单一共享 AudioContext，片段只解码一次                         │
│  • 每个声源一个 HRTF PannerNode：双耳声像 + 距离衰减             │
│  • 低通滤波器扫频模拟空气吸声                                    │
└─────────────────────────────────────────────────────────────────┘
```

**LSPDFR v1.2.1 移植对照：**
- `PlaybackLoop` / `NextDelayMilliseconds` / `SelectClip` → 移入服务器指挥端，实现完美同步
- `WavePlayer.Play` + `CalculateSafeNormalizationGain` → 在 NUI 侧用 Web Audio 重新实现

---

## 🔧 诊断排查

在游戏内运行 `/brcdebug`，打印音频链路每一跳的状态：

- 本机标识、电台状态、播放令牌
- 时钟偏移（`nil` = 未校准）
- 完整声源音量表（原始值 + 当前下发给 NUI 的值）
- NUI 音频引擎状态：上下文状态、每个声源的增益/截止频率/距离

在 [config.lua](config.lua) 中开启 `Config.Debug = true`，三层（服务器 `[BRC-SRV]`、客户端 `[BRC-CLI]`、NUI）的详细日志将全部输出到 F8 控制台。

---

## 🙏 致谢

- **[LSPDFR](https://www.lcpdfr.com/) 与原版 *Background Radio Chatter* 插件** —— 本资源是 v1.2.1 的逆向移植版；全部电台杂谈音频版权归原插件所有
- **FiveM / Cfx.re** —— 本移植版的目标平台
- 基于 Lua 5.4 与 NUI Web Audio API 构建

---

## 📄 开源许可

基于 [MIT License](LICENSE) 发布。内置电台杂谈音频源自 LSPDFR 插件——二次分发请遵守原作者的条款。

<div align="center">

[English](README.md) | **简体中文**

</div>
