<div align="center">

# 📻 Background Radio Chatter

**Immersive 3D spatial police radio chatter for FiveM — ported from the LSPDFR plugin**

[![FiveM](https://img.shields.io/badge/platform-FiveM-blue)](https://fivem.net)
[![GTA V](https://img.shields.io/badge/game-GTA%20V-orange)](https://www.rockstargames.com/V/)
[![LSPDFR Port](https://img.shields.io/badge/ported%20from-LSPDFR%20v1.2.1-9cf)](https://www.lcpdfr.com/)
[![License](https://img.shields.io/badge/license-MIT-green)](#-license)
[![Version](https://img.shields.io/badge/version-1.0.0-yellow)]()

**English** | [简体中文](README.zh-CN.md)

</div>

---

## ✨ Overview

**Background Radio Chatter** brings ambient police radio transmissions to your FiveM roleplay server. Every player carries a live radio emitter — broadcasting authentic dispatch chatter that nearby players can *actually hear in 3D space*, with realistic distance falloff and air absorption.

This resource is a **faithful reverse-engineered port** of the popular [LSPDFR](https://www.lcpdfr.com/) plugin *Background Radio Chatter v1.2.1*, rebuilt from the ground up as a native FiveM resource with Lua + NUI (Web Audio API).

<div align="center">

| | |
|:---:|:---:|
| 🎧 **True 3D Audio** | HRTF panning, distance rolloff & muffled far-field sound |
| 🌐 **Server-wide Sync** | Every player hears the *exact same* clip sequence |
| 🎛️ **219 WAV Clips** | Authentic radio chatter, randomly scheduled |
| ⌨️ **Zero Input Capture** | Keyboard-only menu — keep walking while you configure |

</div>

---

## 📋 Table of Contents

- [Features](#-features)
- [How It Works](#-how-it-works)
- [Installation](#-installation)
- [Usage](#-usage)
- [Configuration](#-configuration)
- [Architecture](#-architecture)
- [Diagnostics](#-diagnostics)
- [Credits](#-credits)
- [License](#-license)

---

## 🎯 Features

### 3D Spatial Audio Engine
- **HRTF PannerNode** — binaural left/right panning driven by your gameplay camera orientation; walk around a player and their radio swings between your ears
- **Exponential distance falloff** — full loudness within `1.2 m`, ~8% at 10 m, ~3% at 20 m (inaudible beyond the emitter range)
- **Air absorption** — a lowpass filter sweeps from `19 kHz` (near) down to `1.5 kHz` (far), so distant radios sound naturally muffled
- **Per-emitter loudness** — each radio plays at *its owner's* volume setting, just like a real speaker

### Server Conductor (Perfect Sync)
- The server is the **single source of randomness** — every player hears the identical clip sequence at the identical instant
- Clients **calibrate their clock offset** (RTT/2 method) and re-sync every 30 s to fight timer drift
- Broadcast start instants with a 2.5 s lead time for frame-perfect alignment

### Smart Playback Scheduling
- Random gap of `5–15 s` between transmissions, with a configurable chance of long silences (`10–30 s`)
- Anti-repeat guard — never hears the same clip twice in a row
- Receive/emit decoupling — **turn your radio off and you still hear nearby radios**; the toggle only mutes *your* emitter

### Performance First
- Audio decoded **once** and shared across all emitters
- Emitter distance culling + hard cap (`8` simultaneous sources)
- Listener position updates throttled to `10 Hz`

### Player Experience
- **219 authentic WAV chatter clips** bundled out of the box
- Keyboard-only settings menu (NUI) that **never captures mouse or focus** — movement, camera and chat stay live
- All settings persisted per-player via KVP
- Loudness normalization option to equalize clip volumes

---

## 🚀 Installation

1. **Download** or clone this repository:

   ```bash
   git clone https://github.com/TEARLESSVVOID/FiveM-background_radio_chatter.git
   ```

2. **Copy** the `background_radio_chatter` folder into your server's `resources` directory.

3. **Add** the following line to your `server.cfg`:

   ```cfg
   ensure background_radio_chatter
   ```

4. **Restart** your server. Done! ✔️

> **Requirements:** FiveM server (OneSync recommended for accurate player scoping). No external dependencies — everything is self-contained.

---

## 🎮 Usage

| Command | Description |
|---|---|
| `/Sncradio` | Open the settings menu (the radio on/off switch is the first item) |
| `/brcdebug` | Print full diagnostics for every link in the audio chain |

**Menu controls** (keyboard only, game input never captured):

| Key | Action |
|---|---|
| `↑` / `↓` | Navigate items |
| `←` / `→` | Adjust value |
| `Enter` | Activate (test play / reset / save) |
| `Backspace` / `Esc` | Save & close |

Menu position can be docked **Left / Center / Right**, and the player keeps full control of their character while the menu is open.

---

## ⚙️ Configuration

Everything lives in [`config.lua`](config.lua). Key sections:

### Player Defaults (`Config.Defaults`)

| Key | Default | Description |
|---|---|---|
| `Enabled` | `false` | Auto-start the radio when the resource loads |
| `Notifications` | `true` | GTA feed notifications |
| `Volume` | `0.35` | Master volume `0.0–1.0` |
| `NormalizeVolume` | `true` | Equalize WAV loudness |
| `MenuPosition` | `'Right'` | Menu dock: `Left` / `Center` / `Right` |

### Playback Scheduling (`Config.Schedule`) — *server-only*

| Key | Default | Description |
|---|---|---|
| `MinDelay` / `MaxDelay` | `5` / `15` | Random gap between transmissions (seconds) |
| `PreventRepeat` | `true` | Never play the same clip twice in a row |
| `LongSilenceChance` | `1` | % chance of a long silence per gap |
| `LongSilenceMin` / `LongSilenceMax` | `10` / `30` | Long-silence extra delay (seconds) |

> ⚠️ Schedule changes require a resource restart. These values are server-authoritative by design — per-player edits would break the shared sync.

### 3D Audio & Sync (`Config.Sync`)

| Key | Default | Description |
|---|---|---|
| `StartLead` | `2500` ms | Lead time broadcast before the synced start |
| `ResyncEvery` | `30` s | Clock re-calibration interval |
| `EmitterRange` | `6.0` m | Audible radius; emitters beyond are dropped |
| `RefDistance` | `1.2` m | Full loudness within this radius |
| `Rolloff` | `1.4` | Distance falloff exponent (higher = steeper) |
| `LowpassNear` / `LowpassFar` | `19000` / `1500` Hz | Air-absorption lowpass sweep |
| `MaxEmitters` | `8` | Max simultaneously rendered remote sources |

---

## 🏗️ Architecture

```
┌──────────────────────────── SERVER (conductor) ────────────────────────────┐
│  • Single source of randomness: one shared clip sequence for everyone      │
│  • Broadcasts exact start instants (GetGameTimer + StartLead)              │
│  • Tracks per-player emission volume + on/off state (no ghost emitters)    │
└──────────────┬─────────────────────────────────────────────┬───────────────┘
               │ brc:transmission {clip, startAt, volumes}   │ brc:volumesUpdate
               │ brc:syncReply (clock offset, RTT/2)         │
┌──────────────▼─────────────── CLIENT (Lua) ─────────────────┴───────────────┐
│  • Aligns playback to the server instant via calibrated clock offset       │
│  • Collects nearby emitters within range (10 Hz, capped, distance-sorted)  │
│  • Sends listener pose + emitter list to NUI                              │
└──────────────────────────────┬──────────────────────────────────────────────┘
                               │ SendNUIMessage
┌──────────────────────────────▼──────────── NUI (Web Audio) ─────────────────┐
│  • One shared AudioContext, clips decoded once                             │
│  • HRTF PannerNode per emitter: binaural pan + distance rolloff            │
│  • Lowpass filter sweep simulates air absorption                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Porting notes from LSPDFR v1.2.1:**
- `PlaybackLoop` / `NextDelayMilliseconds` / `SelectClip` → moved into the server conductor for perfect sync
- `WavePlayer.Play` + `CalculateSafeNormalizationGain` → reimplemented on the NUI side with Web Audio

---

## 🔧 Diagnostics

Run `/brcdebug` in-game to dump the state of every hop in the audio chain:

- Local identity, radio state, playback token
- Clock offset (or `nil` = not calibrated)
- Full emitter volume table (raw + currently sent to NUI)
- NUI audio engine status: context state, per-emitter gain/cutoff/distance

Enable `Config.Debug = true` in [config.lua](config.lua) to stream verbose logs from all three layers (server `[BRC-SRV]`, client `[BRC-CLI]`, NUI) to the F8 console.

---

## 🙏 Credits

- **[LSPDFR](https://www.lcpdfr.com/) & the original *Background Radio Chatter* plugin** — this resource is a reverse-engineered port of v1.2.1; all radio chatter audio belongs to the original plugin
- **FiveM / Cfx.re** — the platform this port targets
- Built with Lua 5.4 and the NUI Web Audio API

---

## 📄 License

Released under the [MIT License](LICENSE). The bundled radio chatter audio originates from the LSPDFR plugin — respect the original author's terms when redistributing.

<div align="center">

**English** | [简体中文](README.zh-CN.md)

</div>
