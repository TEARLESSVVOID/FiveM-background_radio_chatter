<div align="center">

# 📋 Release Notes / 发行说明

**FiveM port of [Background Radio Chatter](https://www.lcpdfr.com/downloads/gta5mods/scripts/55334-background-radio-chatter/) (LSPDFR, by DDvy.david)**

[README](README.md) · [README 简体中文](README.zh-CN.md)

</div>

---

## v1.1.0 — Auto Start & Persistence Fix (2026-09-10)

### ✨ New

- **Auto Start toggle** — a new menu item (row 2) in `/Sncradio`. Enable it once and the radio turns itself on **every time you join the server**. It controls the *radio*, never the menu — the menu only opens when you type `/Sncradio`.
- The session radio switch and Auto Start are now **independent**: `Radio` = temporary on/off for this session; `Auto Start` = your persistent power-on preference for future sessions.

### 🛠 Fixed

- **Settings no longer lost on relog.** The previous version wrote settings to KVP but never read them back, so volume / normalize / menu position were silently reset on every rejoin. All player settings now load on startup and persist across relogs and server restarts.

### ⚠️ Upgrade Notes

- Legacy KVP data is **auto-migrated**: the old `Enabled` field is read as `AutoStart`. No action needed — players keep their previous choice.
- Apply the update by restarting the resource: `restart background_radio_chatter`. No server.cfg changes required.
- Temporary "radio off" states are intentionally **not** remembered; each join starts from your Auto Start preference.

---

## v1.0.0 — Initial Port (2026-09-09)

### 🚀 Highlights

- **Faithful port of the LSPDFR plugin v1.2.1-era feature set** to native FiveM (Lua + NUI Web Audio).
- **True 3D spatial audio**: HRTF binaural panning, exponential distance rolloff, air-absorption lowpass — each player is a radio emitter at their own volume.
- **Server-conductor sync**: one shared clip sequence for the whole server, RTT/2 clock calibration, frame-perfect start alignment.
- **219 authentic WAV chatter clips** bundled; random scheduling with anti-repeat and long-silence logic.
- **Zero input capture**: keyboard-only NUI menu; keep walking while configuring.
- Receive/emit decoupling — radio off still lets you *hear* nearby radios.

---

## 🔄 Upstream Tracking Policy / 上游跟随策略

> **EN:** This project is a port — we follow the original author. When **[DDvy.david](https://www.lcpdfr.com/profile/680020-ddvydavid/)** updates the LSPDFR plugin on [LCPDFR](https://www.lcpdfr.com/downloads/gta5mods/scripts/55334-background-radio-chatter/), we port the changes here as soon as practical. Watch this repo's Releases to get notified.

> **中文：** 本项目是移植版——我们跟随原作者更新。只要 **DDvy.david** 在 LCPDFR 上更新了原版 LSPDFR 插件，我们会尽快把改动移植到本仓库。Watch 本仓库的 Releases 即可收到更新通知。

| This repo (FiveM port) | Upstream (LSPDFR original) |
|---|---|
| v1.0.0 | v1.2.1-era feature set ported |
| v1.1.0 | + Auto Start, + persistence fix (FiveM-specific) |

---

<div align="center">

[README](README.md) · [README 简体中文](README.zh-CN.md)

</div>
