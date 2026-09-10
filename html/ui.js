/*
 * ============================================================
 * Background Radio Chatter - NUI 脚本 / NUI script
 * 两部分职责 / Two responsibilities:
 *   1) 设置菜单 UI（纯显示，输入全在 Lua 侧）/ settings menu UI (display only)
 *   2) 3D 音频引擎（Web Audio API）/ 3D audio engine (Web Audio API)
 *      - 响度归一化与原版完全一致 / identical normalization:
 *        gain = clamp(0.18 / RMS, 0.35, 2.5), 再取 min(gain, 0.95 / peak)
 *      - 3D 空间音效 / spatial audio:
 *        每位玩家 = 一个声源（响度 = 该玩家自己设置的音量），经 HRTF PannerNode
 *        定位；听者双耳自动获得左右响度差（一边大一边小）与距离衰减
 *        Each player is an emitter (loudness = their own volume setting) placed
 *        via an HRTF PannerNode; the listener's ears get the left/right level
 *        difference and distance falloff automatically.
 *      - 性能 / performance:
 *        同一条录音只解码一次，所有声源共享同一个 AudioBuffer；
 *        声源数量有上限、超出范围即销毁；位置更新由 Lua 侧 10Hz 节流下发。
 *        One decode per clip shared by all sources; capped emitter pool;
 *        positions arrive throttled at 10 Hz from Lua.
 * ============================================================
 */

'use strict';

var RES_NAME = (typeof GetParentResourceName === 'function') ? GetParentResourceName() : 'background_radio_chatter';

// 调试输出：NUI 的 console.log 会显示在玩家 F8 控制台（前缀 [BRC-NUI]）
// 仅当 Lua 侧下发 debugMode 消息（Config.Debug = true）后才启用，避免刷屏玩家 F8
// Debug output: NUI console.log shows up in the player's F8 console.
// Only enabled after the Lua side pushes 'debugMode' (Config.Debug = true)
var debugEnabled = false;

function dbg() {
    if (!debugEnabled) return; // 非调试模式静默 / silent unless debug mode is on
    var parts = ['[BRC-NUI]'];
    for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i]));
    console.log(parts.join(' '));
}

// ===== 菜单部分（纯显示）/ Menu section (display only) =====

// 菜单项文字（中文；索引与 main.lua 的 values 数组一一对应）
// 8 项：调度类设置（间隔/长静默/防重复）由服务器统一调度，玩家修改无效，已移除。
// Item captions (Chinese; indexes match the values array in main.lua)
// 8 items: scheduling settings (delays/silence/repeat) are server-side only, hence removed.
var ITEMS = [
    '电台开关',
    '自启动',
    '音量',
    '音量均衡',
    '菜单位置',
    '测试播放',
    '重置设置',
    '保存并关闭'
];
var ITEM_COUNT = ITEMS.length;

var menuOpen = false;
var selectedIndex = 0;
var itemsRoot = document.getElementById('items');
var panel = document.getElementById('panel');
var statusLine = document.getElementById('status-line');

// 向客户端脚本发送回调 / post a callback to the client script
function post(name, data) {
    return fetch('https://' + RES_NAME + '/' + name, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data || {})
    }).catch(function () { /* NUI fetch 失败可忽略 / ignore NUI fetch errors */ });
}

// 构建菜单行（只构建一次；纯展示，不含任何鼠标/键盘处理）
// Build the rows once (display only — no mouse/keyboard handling at all)
function buildItems() {
    for (var i = 0; i < ITEM_COUNT; i++) {
        var row = document.createElement('div');
        row.className = 'item';
        var label = document.createElement('span');
        label.className = 'label';
        label.textContent = ITEMS[i];
        var value = document.createElement('span');
        value.className = 'value';
        value.textContent = '';
        row.appendChild(label);
        row.appendChild(value);
        itemsRoot.appendChild(row);
    }
}

// 渲染选中高亮（索引由客户端脚本经 state 消息下发）
// Render the highlight (index comes from the client script via the state message)
function renderSelection() {
    var rows = itemsRoot.children;
    for (var i = 0; i < rows.length; i++) {
        var isSelected = (i === selectedIndex);
        var row = rows[i];
        if (isSelected !== row.classList.contains('selected')) {
            row.classList.toggle('selected', isSelected);
        }
        // 选中行显示 "> " 前缀，同原版 / "> " prefix on the selected row
        var label = ITEMS[i];
        row.children[0].textContent = isSelected ? ('> ' + label) : label;
    }
}

// 渲染取值列 / render the value column
function renderValues(values) {
    if (!values || !values.length) return;
    var rows = itemsRoot.children;
    for (var i = 0; i < rows.length && i < values.length; i++) {
        rows[i].children[1].textContent = values[i];
    }
}

// 更新状态行（状态文本汉化）/ update the status line (localized)
function renderStatus(status, count) {
    var statusText = (status === 'ONLINE') ? '已开启' : '已关闭';
    statusLine.textContent = '电台控制面板 • ' + statusText + ' • ' + count + ' 条录音';
    statusLine.classList.toggle('online', status === 'ONLINE');
    statusLine.classList.toggle('offline', status !== 'ONLINE');
}

// 切换停靠位置 / switch the dock position
function setPosition(position) {
    panel.classList.remove('pos-left', 'pos-center', 'pos-right');
    var cls = 'pos-' + String(position || 'Left').toLowerCase();
    panel.classList.add(cls);
}

// ===== 3D 音频引擎 / 3D audio engine =====

var audioCtx = null;
var bufferCache = new Map();    // 已解码缓冲 LRU / decoded-buffer LRU cache
var BUFFER_CACHE_MAX = 8;       // 只缓存最近 8 条，控制内存 / keep 8 recent buffers
var analysisCache = new Map();  // 每个文件的归一化增益 / per-file normalization gain
var current = null;             // 当前播放会话 / active playback session
/*
 * current = {
 *   token, ownSource, ownGain,            自己的声源（直连，不经声像器）
 *                                         own emitter (direct, no panner)
 *   emitters: Map(id -> {src,gain,panner}), 远端声源池 / remote emitter pool
 *   sync: {...},                          声像参数 / panner params
 *   norm, volume, buffer, ended
 * }
 */

// 获取（并唤醒）AudioContext / get (and resume) the AudioContext
function getCtx() {
    if (!audioCtx) {
        var Ctor = window.AudioContext || window.webkitAudioContext;
        audioCtx = new Ctor();
        dbg('AudioContext created, state=', audioCtx.state, 'sampleRate=', audioCtx.sampleRate);
    }
    if (audioCtx.state === 'suspended') {
        dbg('AudioContext suspended -> resume()');
        audioCtx.resume();
    }
    return audioCtx;
}

// 拉取并解码 WAV（相对路径基于 index.html）/ fetch & decode a WAV (relative to index.html)
function fetchBuffer(file) {
    if (bufferCache.has(file)) {
        var cached = bufferCache.get(file);
        // 命中时移到末尾实现 LRU / refresh LRU order on hit
        bufferCache.delete(file);
        bufferCache.set(file, cached);
        dbg('fetchBuffer cache HIT:', file);
        return Promise.resolve(cached);
    }
    dbg('fetchBuffer fetching:', file);
    return fetch(file)
        .then(function (response) {
            dbg('fetchBuffer response:', file, 'status=', response.status);
            return response.arrayBuffer();
        })
        .then(function (raw) { return getCtx().decodeAudioData(raw); })
        .then(function (buffer) {
            bufferCache.set(file, buffer);
            if (bufferCache.size > BUFFER_CACHE_MAX) {
                var oldest = bufferCache.keys().next().value;
                bufferCache.delete(oldest);
            }
            dbg('fetchBuffer decoded:', file, 'duration=', Math.round(buffer.duration * 1000) + 'ms',
                'channels=', buffer.numberOfChannels, 'cache=', bufferCache.size);
            return buffer;
        })
        .catch(function (error) {
            dbg('fetchBuffer FAILED:', file, error && error.message ? error.message : error);
            throw error;
        });
}

// 计算安全归一化增益（公式与 CalculateSafeNormalizationGain 完全一致）
// Safe normalization gain (identical to CalculateSafeNormalizationGain)
function computeGain(file, buffer) {
    if (analysisCache.has(file)) {
        return Promise.resolve(analysisCache.get(file));
    }
    var peak = 0, squaredSum = 0, sampleCount = 0;
    for (var ch = 0; ch < buffer.numberOfChannels; ch++) {
        var data = buffer.getChannelData(ch);
        for (var i = 0; i < data.length; i++) {
            var sample = data[i];
            var magnitude = Math.abs(sample);
            if (magnitude > peak) peak = magnitude;
            squaredSum += sample * sample;
            sampleCount++;
        }
    }
    var gain = 1;
    if (sampleCount > 0 && peak > 0.0001) {
        var rms = Math.sqrt(squaredSum / sampleCount);
        if (rms > 0.0001) {
            // RMS 目标 0.18，增益钳制 0.35~2.5 / target RMS 0.18, gain clamped to 0.35..2.5
            gain = Math.max(0.35, Math.min(2.5, 0.18 / rms));
            // 峰值上限 0.95 防削波 / peak cap 0.95 to avoid clipping
            gain = Math.min(gain, 0.95 / peak);
        }
    }
    analysisCache.set(file, gain);
    dbg('computeGain:', file, 'gain=' + gain.toFixed(3), 'peak=' + peak.toFixed(3));
    return Promise.resolve(gain);
}

// ===== 主总线限制器 / Master-bus limiter =====
// 多人声源叠加可能超过 1.0 造成数字削波（爆音）；
// 用 DynamicsCompressor 作透明限制器：安静时完全不动， loud 时平滑压回，如同现实中多台收音机互相掩蔽。
// Overlapping loud emitters can exceed 1.0 and clip; a transparent limiter keeps it clean,
// mimicking how multiple radios mask each other in real life.

var masterBus = null; // 所有声源汇入的总线 / all sources feed into this bus

function getMasterBus() {
    if (!masterBus) {
        var ctx = getCtx();
        masterBus = ctx.createDynamicsCompressor();
        // 限制器参数：阈值 -6dB、高比率、快启动——只削峰，不影响正常响度
        // Limiter: -6dB threshold, high ratio, fast attack — peak-only, transparent when quiet
        masterBus.threshold.value = -6;
        masterBus.knee.value = 6;
        masterBus.ratio.value = 12;
        masterBus.attack.value = 0.003;
        masterBus.release.value = 0.25;
        masterBus.connect(ctx.destination);
        dbg('master limiter bus created');
    }
    return masterBus;
}

// 销毁单个声源 / tear down a single source
function killSource(src, gain, panner, lowpass) {
    try { src.onended = null; src.stop(); } catch (e) { /* 已停止 / already stopped */ }
    try {
        src.disconnect(); gain.disconnect();
        if (lowpass) lowpass.disconnect();
        if (panner) panner.disconnect();
    } catch (e) { /* 忽略 / ignore */ }
}

// 停止并清理当前会话 / stop & clean up the current session
function stopPlayback() {
    if (!current) return;
    var session = current;
    current = null;
    dbg('stopPlayback: killing session token=', session.token,
        'ownSource +', session.emitters.size, 'emitter(s)');
    killSource(session.ownSource, session.ownGain, null, null);
    session.emitters.forEach(function (node) {
        killSource(node.src, node.gain, node.panner, node.lowpass);
    });
}

// 创建远端声源（同一 AudioBuffer 可被多个 source 共享，开销极小）
// 迟加入的声源从会话当前播放进度 offset 处接上，保持全服同步
// Create a remote emitter; late joiners resume at the session's elapsed offset
function createEmitter(session, id, x, y, z, vol) {
    var ctx = getCtx();
    // 播放进度偏移：超过剩余时长就不再创建（片段马上结束）
    // Elapsed offset: skip creation when the clip is about to end
    var offset = ctx.currentTime - session.startedAt;
    if (offset >= session.buffer.duration - 0.05) {
        dbg('createEmitter SKIP (clip nearly over, offset=' + Math.round(offset * 1000) + 'ms) id=', id);
        return null;
    }

    var src = ctx.createBufferSource();
    src.buffer = session.buffer;
    var gain = ctx.createGain();
    // 声源响度 = 该玩家自己设置的音量 × 归一化增益（钳制 0~1，与原版一致）
    // Emission = that player's own volume setting x normalization gain (clamped, as the original)
    gain.gain.value = Math.max(0, Math.min(1, vol * session.norm));
    var panner = ctx.createPanner();
    panner.panningModel = 'HRTF';                       // 双耳渲染：左右耳响度差 / binaural rendering
    panner.distanceModel = 'exponential';               // 指数衰减：远处衰减快，符合真实点声源
                                                        // exponential: fast far-field falloff, like a real point source
    panner.refDistance = session.sync.refDistance || 1.2;
    panner.rolloffFactor = session.sync.rolloff || 1.4;
    // 位置节点链：src -> gain -> lowpass -> panner -> 主总线
    // Node chain: src -> gain -> lowpass -> panner -> master bus
    // 低通模拟空气吸声：越远高频丢失越多（声音发闷），真实感的关键
    // The lowpass emulates air absorption: highs vanish with distance (muffling) — key to realism
    var lowpass = ctx.createBiquadFilter();
    lowpass.type = 'lowpass';
    lowpass.Q.value = 0.5; // 缓滚降，避免染色 / gentle slope, no coloration
    lowpass.frequency.value = session.sync.lowpassNear || 19000;
    panner.positionX.value = x;
    panner.positionY.value = y;
    panner.positionZ.value = z;
    src.connect(gain);
    gain.connect(lowpass);
    lowpass.connect(panner);
    panner.connect(getMasterBus()); // 经主总线限制器，防多人叠加削波 / via the master limiter
    src.start(0, offset);           // 从当前进度接上 / resume at the elapsed offset
    return { src: src, gain: gain, panner: panner, lowpass: lowpass };
}

// 播放同步广播（3D 版）/ play a synced transmission (3D)
function play3d(msg) {
    getCtx();
    stopPlayback();
    var token = msg.token;
    dbg('play3d: token=', token, 'file=', msg.file, 'ownVol=', msg.ownVolume,
        'normalize=', msg.normalize, 'remoteCount=', (msg.volumes || []).length,
        'refDist=', msg.sync && msg.sync.refDistance, 'rolloff=', msg.sync && msg.sync.rolloff);
    fetchBuffer(msg.file)
        .then(function (buffer) {
            return computeGain(msg.file, buffer).then(function (norm) {
                if (current && current.token !== token) return; // 已有更新的播放 / superseded
                var ctx = getCtx();
                var emitters = new Map();

                // 1) 自己的声源：直连增益节点（就在自己身上，无需声像器）
                //    Own emitter: direct gain (it is on our body, no panner needed)
                //    注意不能用 "|| 0.35"——音量为 0 时会被误判 / never use "||" here
                var ownVol = (typeof msg.ownVolume === 'number') ? msg.ownVolume : 0.35;
                var ownGain = ctx.createGain();
                ownGain.gain.value = Math.max(0, Math.min(1, ownVol * norm));
                var ownSource = ctx.createBufferSource();
                ownSource.buffer = buffer;
                ownSource.connect(ownGain);
                ownGain.connect(getMasterBus()); // 经主总线限制器 / via the master limiter

                // 2) 远端声源：不再依赖广播时刻的音量快照（旧做法的致命缺陷：
                //    对方在两次广播之间开台，快照里没有他，就永远建不出声源）。
                //    现在完全由 10Hz 的 listener 消息实时创建/更新/销毁，见 updateListener。
                //    Remote emitters: no longer built from the broadcast snapshot (its flaw:
                //    someone toggling ON between broadcasts never got a source).
                //    They are now created/updated/destroyed live by 10 Hz listener messages.
                var emitters = new Map();

                current = {
                    token: token,
                    buffer: buffer,
                    norm: norm,
                    ownSource: ownSource,
                    ownGain: ownGain,
                    emitters: emitters,
                    sync: msg.sync || {},
                    volume: ownVol,
                    startedAt: ctx.currentTime, // 播放起点：迟到的声源从此进度接上 / late joiners resume from here
                    ended: false,
                };

                // 自己的声源结束 = 全体结束（同一缓冲同时起播，时长一致）
                // Own source ending ends the session (same buffer, same start, same length)
                ownSource.onended = function () {
                    if (current && current.token === token && !current.ended) {
                        current.ended = true;
                        dbg('own source ended: token=', token);
                        post('playbackEnded', { token: token });
                    }
                };
                ownSource.start();
                dbg('playback started: token=', token, 'ownGain=', ownGain.gain.value.toFixed(3),
                    'bufferDur=', Math.round(buffer.duration * 1000) + 'ms');
            });
        })
        .catch(function (error) {
            console.error('[BackgroundRadioChatter] play3d failed:', msg.file, error);
            post('playbackEnded', { token: token }); // 失败也放行 / let the loop continue on failure
        });
}

// 为会话创建缺失的远端声源（由 listener 消息驱动，10Hz 实时增删）
// Emitters are created/updated/destroyed live by 10 Hz listener messages (authoritative)

// 更新听者（自己）位置/朝向 + 远端声源位置（Lua 侧 10Hz 下发）
// Update listener position/orientation + emitter positions (10 Hz from Lua)
function updateListener(msg) {
    if (!current) return;
    var ctx = getCtx();
    var L = ctx.listener;
    // 位置 / position
    if (L.positionX) {
        L.positionX.value = msg.lx; L.positionY.value = msg.ly; L.positionZ.value = msg.lz;
        L.forwardX.value = msg.fx; L.forwardY.value = msg.fy; L.forwardZ.value = msg.fz;
        L.upX.value = 0; L.upY.value = 0; L.upZ.value = 1;
    } else {
        // 旧版 CEF 回退 API / legacy CEF fallback API
        L.setPosition(msg.lx, msg.ly, msg.lz);
        L.setOrientation(msg.fx, msg.fy, msg.fz, 0, 0, 1);
    }
    // 远端声源实时同步：缺失即创建（覆盖"中途开台/进服"），多余即销毁（关台/离开/超距）
    // Live emitter sync: create missing (mid-play toggles/joins), destroy stale (off/left/out of range)
    var seen = {};
    var list = msg.emitters || [];
    var syncParams = current.sync || {};
    var nearHz = syncParams.lowpassNear || 19000;
    var farHz = syncParams.lowpassFar || 1500;
    var refDist = syncParams.refDistance || 1.2;
    var maxDist = syncParams.maxDistance || 20;
    var maxEmitters = syncParams.maxEmitters || 8;
    var t = ctx.currentTime;
    for (var i = 0; i < list.length; i++) {
        var e = list[i];
        var key = String(e.id);
        seen[key] = true;

        // 缺失即建：迟加入者从当前播放进度接上 / create missing: late joiner resumes mid-clip
        if (!current.emitters.has(key)) {
            if (current.emitters.size >= maxEmitters) continue; // 上限保护 / cap
            var created = createEmitter(current, e.id, e.x, e.y, e.z, e.vol);
            if (created) {
                current.emitters.set(key, created);
                dbg('emitter +', key, 'vol=', e.vol);
            }
            continue; // 新建的位置即最新，无需再平滑 / freshly created at the latest position
        }

        var node = current.emitters.get(key);
        // 位置平滑更新（直接赋值会爆音）/ smooth position updates (avoid zipper noise)
        node.panner.positionX.setTargetAtTime(e.x, t, 0.05);
        node.panner.positionY.setTargetAtTime(e.y, t, 0.05);
        node.panner.positionZ.setTargetAtTime(e.z, t, 0.05);
        // 音量实时跟随：对方改音量下一拍生效 / volume follows live (their setting changes)
        var wantGain = Math.max(0, Math.min(1, (e.vol || 0) * current.norm));
        if (Math.abs(node.gain.gain.value - wantGain) > 0.001) {
            node.gain.gain.setTargetAtTime(wantGain, t, 0.05);
        }
        // 距离低通（空气吸声）：按听者->声源距离插值截止频率
        // Distance lowpass (air absorption): interpolate cutoff by listener->emitter distance
        var ddx = e.x - msg.lx, ddy = e.y - msg.ly, ddz = e.z - msg.lz;
        var dist = Math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz);
        var k = Math.max(0, Math.min(1, (dist - refDist) / Math.max(0.01, maxDist - refDist)));
        node.lowpass.frequency.setTargetAtTime(nearHz + (farHz - nearHz) * k, t, 0.1);
    }
    // 销毁列表外的声源（关台/掉线/超出可闻半径）/ destroy emitters no longer present
    current.emitters.forEach(function (node, key) {
        if (!seen[key]) {
            dbg('emitter -', key);
            killSource(node.src, node.gain, node.panner, node.lowpass);
            current.emitters.delete(key);
        }
    });
}

// 实时调整自己声源的音量（菜单改音量时）/ live volume of own emitter
function setOwnVolume(volume) {
    if (current) {
        current.volume = volume;
        current.ownGain.gain.value = Math.max(0, Math.min(1, volume * current.norm));
    }
}

// 诊断回报：引擎整体状态 + 声源池明细 / diagnostics: engine state + emitter pool details
function reportDebug() {
    var data = { emitterCount: 0, emitters: [] };
    if (audioCtx) data.ctxState = audioCtx.state; else data.ctxState = 'no-context';
    if (current) {
        data.ownGain = current.ownGain ? current.ownGain.gain.value : null;
        data.hasBuffer = !!current.buffer;
        data.norm = current.norm;
        data.startedAgoMs = Math.round((getCtx().currentTime - current.startedAt) * 1000);
        data.emitterCount = current.emitters.size;
        current.emitters.forEach(function (node, key) {
            data.emitters.push({
                id: key,
                vol: node.gain ? node.gain.gain.value : null,
                dist: node.panner && node.panner.positionX
                    ? Math.round(Math.sqrt(
                        Math.pow(node.panner.positionX.value - 0, 2) + // 仅示意；距离由 Lua 计算
                        Math.pow(node.panner.positionZ.value - 0, 2)) * 10) / 10
                    : null,
                gain: node.gain ? node.gain.gain.value : null,
                cutoff: node.lowpass ? Math.round(node.lowpass.frequency.value) : null,
            });
        });
    }
    post('debugReport', data);
}

// ===== 消息分发 / Message dispatch =====

// listener 消息 10Hz 高频，仅每 5 秒打一条心跳；其余消息逐条记录
// 'listener' arrives at 10 Hz: heartbeat-log every 5s; everything else logs per message
var lastListenerLog = 0;

window.addEventListener('message', function (event) {
    var msg = event.data || {};
    if (msg.type === 'listener') {
        var now = Date.now();
        if (now - lastListenerLog > 5000) {
            lastListenerLog = now;
            dbg('listener msg (heartbeat 5s): emitters=', (msg.emitters || []).length,
                'at', Math.round(msg.lx) + ',' + Math.round(msg.ly) + ',' + Math.round(msg.lz));
        }
    } else {
        dbg('message received:', msg.type);
    }
    switch (msg.type) {
        // ---- 菜单 ----
        case 'open':
            menuOpen = true;
            panel.classList.remove('hidden');
            if (msg.position) setPosition(msg.position);
            break;
        case 'close':
            menuOpen = false;
            panel.classList.add('hidden');
            break;
        case 'state':
            renderValues(msg.values);
            renderStatus(msg.status, msg.count || 0);
            if (msg.position) setPosition(msg.position);
            if (typeof msg.selected === 'number') {
                selectedIndex = msg.selected;
            }
            renderSelection();
            break;
        // ---- 3D 音频 ----
        case 'play3d':
            play3d(msg);
            break;
        case 'stop':
            stopPlayback();
            break;
        case 'volume':
            setOwnVolume(msg.volume);
            break;
        case 'listener':
            updateListener(msg);
            break;
        case 'position':
            setPosition(msg.position);
            break;
        // ---- 诊断 / diagnostics ----
        case 'debug':
            reportDebug();
            break;
        // ---- 调试开关（Lua 启动时下发）/ debug switch pushed by Lua at startup ----
        case 'debugMode':
            debugEnabled = !!msg.enabled;
            break;
    }
});

// ===== 初始化 / Init =====
buildItems();
renderSelection();
