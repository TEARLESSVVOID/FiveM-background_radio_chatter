-- ============================================================
-- Background Radio Chatter - FiveM 客户端主逻辑（3D 同步版）
-- FiveM client main logic — 3D spatial, server-synced edition
--
-- 移植对照 / Porting notes (from LSPDFR v1.2.1):
--   PlaybackLoop / NextDelayMilliseconds / SelectClip -> 移入服务器指挥端
--     (scheduling moved to the server conductor for perfect sync)
--   WavePlayer.Play + CalculateSafeNormalizationGain -> NUI 端 Web Audio
--   新增 / New in this edition:
--   - 3D 空间音效：每位玩家是一个声源，响度 = 该玩家自己设置的音量；
--     听者双耳由 HRTF PannerNode 自动产生左右差与距离衰减（一边大一边小）
--   - 全服同步播放：服务器统一选曲与开播时刻，客户端时钟校准后对齐
--   - 性能：解码一次多源共享、声源距离裁剪 + 数量上限、位置更新 10Hz 节流
--
-- 调试 / Debug: Config.Debug = true 时所有行为输出到 F8 控制台（前缀 [BRC-CLI]）
-- All actions are logged to the F8 console when Config.Debug is enabled.
-- ============================================================

local DBG = Config.Debug -- 调试开关（config.lua）/ debug switch from config.lua

-- ===== 运行时状态 / Runtime state =====

local settings       = nil        -- 当前设置 / current settings
local radioEnabled   = false      -- 电台总开关 / radio master switch
local menuOpen       = false      -- 菜单是否打开 / menu visibility
local menuIndex      = 1          -- 菜单选中项（1 基）/ menu selection (1-based)
local playToken      = 0          -- 播放令牌（防止过期回调）/ playback token (stale-callback guard)
local playbackEnded  = true       -- 当前片段是否已播完 / has the current clip finished
local isPlaying      = false      -- 是否正在播一条同步广播 / is a synced transmission playing
local pendingTx      = nil        -- 待播放的同步广播 / queued synced transmission
local serverOffset   = nil        -- 服务器时钟偏移（ms）/ server clock offset in ms
local syncPending    = false      -- 是否有校准请求在途 / is a calibration request in flight
local lastVolumes    = {}         -- 最近一次广播携带的音量数组 [{id,vol}] / last volume array
local lastClip       = nil        -- 上一条本地测试播放的片段 / last locally test-played clip
local lastClipVol    = nil        -- 最后下发给 NUI 的声源列表（诊断用）/ last emitter list sent to NUI (debug)

-- 菜单项总数（0~7）/ total menu items (0..7)
-- 说明：同步播放由服务器统一调度，间隔/长静默/防重复等调度类设置已移除（改了也无法生效）。
--       "自启动"决定玩家下次进服是否自动开台；"Radio"只控制本次会话是否发声。
-- Note: playback is server-scheduled; delay/silence/repeat settings were removed (per-player edits cannot apply).
--       "Auto Start" controls whether the radio enables itself on the NEXT join;
--       "Radio" toggles emission for the current session only.
local MENU_ITEMS = 8

local AudioFiles = AudioFiles or {} -- 来自 audio_files.lua 的清单 / manifest from audio_files.lua

-- 调试输出 / debug print helper
local function Dbg(message)
    if DBG then
        print('^3[BRC-CLI]^7 ' .. message)
    end
end

-- ===== 工具函数 / Helpers =====

-- 数值钳制 / clamp a value into [minValue, maxValue]
local function Clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

-- 四舍五入到百分位（音量步进用）/ round to 2 decimals (volume steps)
local function Round2(value)
    return math.floor(value * 100 + 0.5) / 100
end

-- GTA 屏幕通知（受 Notifications 开关控制）/ GTA feed notification (respects Notifications)
local function Notify(message)
    if not settings.Notifications then return end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, true)
end

local function VolumePercent()
    return math.floor(settings.Volume * 100 + 0.5)
end

-- ===== 设置加载与持久化 / Settings load & persistence =====

-- 读取 KVP 并与默认值合并、做范围钳制（对应 RadioSettings.Load）
-- Read KVP, merge with defaults, then clamp ranges (mirrors RadioSettings.Load)
-- 精简版：只加载菜单中仍可修改的设置 + 通知开关（测试播放的防重复沿用默认值）
-- Trimmed: only the settings still editable in the menu + the notification toggle.
local function LoadSettings()
    local merged = {
        AutoStart       = Config.Defaults.AutoStart,
        Notifications   = Config.Defaults.Notifications,
        Volume          = Config.Defaults.Volume,
        NormalizeVolume = Config.Defaults.NormalizeVolume,
        MenuPosition    = Config.Defaults.MenuPosition,
    }

    local raw = GetResourceKvpString(Config.SettingsKey)
    if raw and raw ~= '' then
        local ok, saved = pcall(json.decode, raw)
        if ok and type(saved) == 'table' then
            -- 只接受类型正确的字段，坏数据回退默认值 / only accept well-typed fields
            -- 兼容旧版数据：老 KVP 里的 Enabled 字段迁移为 AutoStart / migrate legacy Enabled -> AutoStart
            local savedAutoStart = saved.AutoStart
            if savedAutoStart == nil and type(saved.Enabled) == 'boolean' then
                savedAutoStart = saved.Enabled
            end
            if type(savedAutoStart) == 'boolean' then merged.AutoStart = savedAutoStart end
            if type(saved.Notifications) == 'boolean' then merged.Notifications = saved.Notifications end
            if type(saved.Volume) == 'number' then merged.Volume = saved.Volume end
            if type(saved.NormalizeVolume) == 'boolean' then merged.NormalizeVolume = saved.NormalizeVolume end
            if type(saved.MenuPosition) == 'string' then merged.MenuPosition = saved.MenuPosition end
        else
            Dbg('LoadSettings: KVP decode FAILED, using defaults')
        end
    else
        Dbg('LoadSettings: no saved KVP, using defaults')
    end

    -- 范围钳制 / range clamping
    merged.Volume = Clamp(merged.Volume, 0.0, 1.0)
    if merged.MenuPosition ~= 'Left' and merged.MenuPosition ~= 'Center' and merged.MenuPosition ~= 'Right' then
        merged.MenuPosition = 'Left'
    end

    Dbg(('LoadSettings: volume=%.2f normalize=%s pos=%s notif=%s autostart=%s')
        :format(merged.Volume, tostring(merged.NormalizeVolume), merged.MenuPosition,
                tostring(merged.Notifications), tostring(merged.AutoStart)))
    return merged
end

-- 顶层立即加载：脚本加载阶段就初始化 settings，
-- 防止早到的 brc:transmission 等网络事件访问 nil（修复 "attempt to index a nil value (upvalue 'settings')" 崩溃）
-- Load eagerly at top level: settings is initialized during script load,
-- so early net events (e.g. brc:transmission) can never hit a nil settings.
settings = LoadSettings()

-- 保存到客户端 KVP（对应 RadioSettings.Save）/ persist to client KVP (mirrors RadioSettings.Save)
-- 自启动是持久化偏好；本次会话的开关状态（radioEnabled）不写入，避免"临时关台"被记住
-- AutoStart is the persisted preference; the session toggle (radioEnabled) is NOT saved,
-- so a temporary "radio off" is not remembered across relogs.
local function SaveSettings()
    SetResourceKvp(Config.SettingsKey, json.encode({
        AutoStart       = settings.AutoStart,
        Notifications   = settings.Notifications,
        Volume          = settings.Volume,
        NormalizeVolume = settings.NormalizeVolume,
        MenuPosition    = settings.MenuPosition,
    }))
    Dbg(('SaveSettings: autostart=%s volume=%.2f pos=%s')
        :format(tostring(settings.AutoStart), settings.Volume, settings.MenuPosition))
end

-- ===== 时钟校准（全服同步的基石）/ Clock calibration (basis of the sync) =====
-- offset 满足: 服务器当前时间 ≈ GetGameTimer() + serverOffset
-- offset satisfies: serverNow ≈ localTimer + serverOffset
-- 用 RTT/2 消除网络单程延迟；周期性重校准对抗计时器漂移
-- RTT/2 removes one-way latency; periodic re-sync fights timer drift.

local function RequestClockSync()
    if syncPending then return end
    syncPending = true
    Dbg('clock sync request -> server')
    TriggerServerEvent('brc:syncRequest', GetGameTimer())
end

RegisterNetEvent('brc:syncReply', function(sentAt, serverTimer)
    if not syncPending then return end
    syncPending = false
    local now = GetGameTimer()
    local rtt = now - sentAt
    if rtt < 0 or rtt > 5000 then
        Dbg(('clock sync reply DISCARDED (rtt=%s out of range)'):format(tostring(rtt)))
        return
    end
    serverOffset = serverTimer + rtt / 2 - now
    -- rtt 含 GetGameTimer 差值，可能为浮点 / rtt may be a float from timer arithmetic
    Dbg(('clock sync OK: rtt=%.0fms offset=%.0fms'):format(rtt, serverOffset))
end)

-- 周期校准线程 / periodic calibration thread
CreateThread(function()
    while true do
        RequestClockSync()
        Wait(Config.Sync.ResyncEvery * 1000)
    end
end)

-- ===== 音量上报（声源响度 = 本人设置，且必须带开关状态）=====
-- Volume reporting (emission = own setting, ALWAYS with the on/off state)
-- 不带状态会导致关台后仍被服务器记为声源（别人听见你的幽灵电台）
-- Without the state, a switched-off player stays registered as an emitter (ghost radio)

local function ReportVolume()
    Dbg(('ReportVolume -> server: vol=%.2f enabled=%s'):format(settings.Volume, tostring(radioEnabled)))
    TriggerServerEvent('brc:reportVolume', settings.Volume, radioEnabled)
end

-- ===== 同步广播接收与播放 / Synced transmission receive & playback =====

-- 音量表实时更新（任何人改音量/开关时服务器立即推送）
-- Real-time volume-table update (pushed whenever anyone changes volume/toggle)
RegisterNetEvent('brc:volumesUpdate', function(list)
    if type(list) == 'table' then
        lastVolumes = list
        if DBG then
            local parts = {}
            for _, entry in ipairs(list) do
                parts[#parts + 1] = entry.id .. '=' .. string.format('%.2f', entry.vol or -1)
            end
            Dbg('brc:volumesUpdate received: {' .. table.concat(parts, ', ') .. '} (' .. #list .. ' emitters)')
        end
    else
        Dbg('brc:volumesUpdate received INVALID payload (not a table)')
    end
end)

RegisterNetEvent('brc:transmission', function(data)
    if not data or not AudioFiles[data.clip] then
        Dbg('brc:transmission received INVALID payload or clip index out of range: ' .. tostring(data and data.clip))
        return
    end
    local emitterCount = 0
    if type(data.volumes) == 'table' then emitterCount = #data.volumes end
    pendingTx = {
        entry   = AudioFiles[data.clip],
        startAt = data.startAt,
        volumes = data.volumes or {},
    }
    -- 注意：startAt 经 msgpack 往返是浮点数，Lua 5.4 的 %d 会报错，必须用 %.0f
    -- Note: startAt arrives as a float over msgpack; Lua 5.4 %d errors, use %.0f
    Dbg(('brc:transmission queued: clip=%d file=%s dur=%dms startAt=%.0f emitters=%d')
        :format(data.clip, pendingTx.entry.file, pendingTx.entry.dur, data.startAt, emitterCount))
end)

-- 播放调度线程：等齐开播时刻 -> 播放 -> 等播完（间隔由服务器决定，客户端不再自己等待）
-- 关键设计：收听与发声解耦——本地会话 ALWAYS 建立（远端声源要渲染），
-- 自己的电台关闭时只是把"自己的声源"静音（ownVolume=0），仍能听见附近开台者。
-- Scheduler: wait until the synced instant -> play -> wait for the end.
-- Key design: listening is decoupled from emitting — the local session ALWAYS runs
-- (remote emitters must render); with our radio OFF we simply mute our OWN source.
CreateThread(function()
    while true do
        if pendingTx then
            local tx = pendingTx
            pendingTx = nil
            lastVolumes = tx.volumes

            -- 对齐开播时刻：目标本机时刻 = 服务器 startAt - 时钟偏移
            -- Align: local target instant = server startAt - clock offset
            if serverOffset then
                local target = tx.startAt - serverOffset
                local waitMs = target - GetGameTimer()
                -- waitMs/target 是浮点运算结果，用 %.0f / both are floats after arithmetic
                Dbg(('aligning start: wait %.0fms (target=%.0f)'):format(math.max(0, waitMs), target))
                while GetGameTimer() < target do
                    Wait(20) -- 20ms 精度足够，同步误差主要来自网络抖动 / 20ms is plenty
                end
            else
                Dbg('NO clock offset yet -> starting immediately (sync may drift)')
            end
            playToken = playToken + 1
            playbackEnded = false
            isPlaying = true
            -- 自己声源的响度：开台=自己的音量；关台=0（静音，但不影响远端声源）
            -- Own emitter loudness: ON = our volume; OFF = 0 (muted; remote emitters unaffected)
            local ownVol = radioEnabled and settings.Volume or 0
            Dbg(('play3d -> NUI: token=%d file=%s ownVol=%.2f (radioEnabled=%s)')
                :format(playToken, tx.entry.file, ownVol, tostring(radioEnabled)))
            SendNUIMessage({
                type = 'play3d',
                token = playToken,
                file = tx.entry.file,
                ownVolume = ownVol,
                normalize = settings.NormalizeVolume,
                volumes = tx.volumes,
                sync = {
                    refDistance = Config.Sync.RefDistance,
                    rolloff = Config.Sync.Rolloff,
                    maxDistance = Config.Sync.EmitterRange,
                    maxEmitters = Config.Sync.MaxEmitters,
                    lowpassNear = Config.Sync.LowpassNear,
                    lowpassFar = Config.Sync.LowpassFar,
                },
            })
            -- 等待播完（可被测试打断）/ wait for the end (interruptible)
            local myToken = playToken
            while not playbackEnded and playToken == myToken do
                Wait(100)
            end
            isPlaying = false
            Dbg(('playback finished: token=%d (ended=%s)')
                :format(myToken, tostring(playbackEnded)))
        else
            Wait(100) -- 空闲 / idle
        end
    end
end)

-- ===== 声源位置广播线程（10Hz 节流，性能友好）/ Emitter position updater (10 Hz) =====

-- 由相机朝向计算前向向量 / forward vector from the gameplay camera
local function CamForward()
    local rot = GetGameplayCamRot(2)
    local z = math.rad(rot.z)
    local x = math.rad(rot.x)
    local cx = math.abs(math.cos(x))
    return -math.sin(z) * cx, math.cos(z) * cx, math.sin(x)
end

CreateThread(function()
    local lastSig = ''      -- 声源集合签名：变化才打日志 / emitter-set signature, log on change
    local lastBeat = 0      -- 心跳节流 / heartbeat throttle
    while true do
        -- 收听与开关无关：只要本地会话存在就收集声源（关台者也能听见附近开台者）
        -- Listening is independent of the switch: collect emitters whenever a session runs
        if isPlaying then
            local myCoords = GetEntityCoords(PlayerPedId())
            local myServerId = GetPlayerServerId(PlayerId())
            local fx, fy, fz = CamForward()

            -- 收集可闻半径内的远端声源（lastVolumes 现为 [{id, vol}] 数组）
            -- Collect remote emitters within range (lastVolumes is now an array of {id, vol})
            local emitters = {}
            for _, entry in ipairs(lastVolumes) do
                local id, vol = entry.id, entry.vol
                if id ~= myServerId and vol and vol > 0 then
                    local playerId = GetPlayerFromServerId(id)
                    if playerId ~= -1 then
                        local coords = GetEntityCoords(GetPlayerPed(playerId))
                        local dx, dy, dz = coords.x - myCoords.x, coords.y - myCoords.y, coords.z - myCoords.z
                        local distSq = dx * dx + dy * dy + dz * dz
                        if distSq <= Config.Sync.EmitterRange * Config.Sync.EmitterRange then
                            emitters[#emitters + 1] = {
                                id = id,
                                x = coords.x, y = coords.y, z = coords.z,
                                distSq = distSq,
                                vol = vol,
                            }
                        end
                    elseif DBG then
                        -- 音量表里有他但本机看不到该玩家（OneSync/范围问题）
                        -- In the table but not visible locally (OneSync/scoping issue)
                        Dbg('emitter id=' .. id .. ' in volume table but GetPlayerFromServerId == -1')
                    end
                end
            end
            -- 超上限时只保留最近的 N 个（性能保护）/ keep the nearest N when over the cap
            if #emitters > Config.Sync.MaxEmitters then
                table.sort(emitters, function(a, b) return a.distSq < b.distSq end)
                for i = Config.Sync.MaxEmitters + 1, #emitters do emitters[i] = nil end
            end
            lastClipVol = emitters -- 留档供 /brcdebug 诊断 / snapshot for /brcdebug

            -- 调试日志：声源集合变化或每 5 秒心跳才输出，避免 10Hz 刷屏
            -- Debug log: only on emitter-set change or a 5s heartbeat, to avoid spam
            if DBG then
                local sig = tostring(#emitters) .. ':'
                local parts = {}
                for _, e in ipairs(emitters) do
                    parts[#parts + 1] = e.id .. '@' .. string.format('%.1fm', math.sqrt(e.distSq))
                end
                sig = sig .. table.concat(parts, ',')
                local now = GetGameTimer()
                if sig ~= lastSig then
                    lastSig = sig
                    Dbg(('listener tick: myId=%d pos=%.1f,%.1f,%.1f emitters[%d]=%s -> sent to NUI')
                        :format(myServerId, myCoords.x, myCoords.y, myCoords.z, #emitters, sig:sub(sig:find(':') + 1)))
                elseif now - lastBeat > 5000 then
                    lastBeat = now
                    Dbg(('listener heartbeat: emitters[%d] unchanged'):format(#emitters))
                end
            end

            SendNUIMessage({
                type = 'listener',
                lx = myCoords.x, ly = myCoords.y, lz = myCoords.z,
                fx = fx, fy = fy, fz = fz,
                emitters = emitters,
            })
            Wait(100) -- 10Hz 足够平滑 / 10 Hz is smooth enough
        else
            if lastSig ~= '' and DBG then
                Dbg('listener thread idle (no active session)')
                lastSig = ''
            end
            Wait(250) -- 空闲低频 / idle
        end
    end
end)

-- ===== NUI 播放桥 / NUI playback bridge =====

-- 注：电台开关不再销毁会话（只静音自己的声源），'stop' 消息仅用于资源停止清理
-- Note: the radio toggle no longer kills the session (it only mutes our own emitter);
-- the 'stop' message is only used for resource-stop cleanup.

-- NUI 回调：片段播完 / NUI callback: clip finished
RegisterNUICallback('playbackEnded', function(data, cb)
    if data and tonumber(data.token) == playToken then
        Dbg('NUI callback playbackEnded: token=' .. tostring(data.token) .. ' (matches current)')
        playbackEnded = true
    else
        Dbg('NUI callback playbackEnded STALE: token=' .. tostring(data and data.token) .. ' current=' .. tostring(playToken))
    end
    cb('ok')
end)

-- ===== 测试播放（本地自听，对应 QueueTest）/ Test play (local only) =====

-- 随机选一条录音（测试播放用；防重复沿用服务器默认策略）
-- Pick a random clip (for test play; repeat-guard follows the server default policy)
local function SelectClip()
    local count = #AudioFiles
    if count == 0 then return nil end

    local pool = AudioFiles
    if Config.Schedule.PreventRepeat and count > 1 then
        pool = {}
        for _, entry in ipairs(AudioFiles) do
            if entry.file ~= lastClip then pool[#pool + 1] = entry end
        end
    end

    local pick = pool[math.random(#pool)]
    lastClip = pick.file
    return pick
end

-- ===== 菜单数值逻辑（对应 ChangeMenuValue / ActivateMenuItem）=====
-- 菜单项索引（8 项）/ Menu item indexes (8 items):
-- 0 Radio | 1 Auto Start | 2 Volume | 3 Normalize | 4 Menu position
-- 5 Play test | 6 Reset | 7 Save & close
-- 说明：调度类设置（间隔/长静默/防重复）已移除——同步播放由服务器统一调度，
--       玩家本地修改无法影响全服序列，属于无效项。
-- Note: scheduling settings were removed — playback is server-scheduled, so
--       per-player edits could never affect the shared sequence.

local function AdjustSetting(index, delta)
    if index == 0 then
        -- Radio 开关（菜单内集成）：只决定"自己是否发声"；附近开台者照样能听见
        -- Radio toggle: controls whether WE emit only; nearby ON players remain audible
        radioEnabled = not radioEnabled
        Dbg('menu: Radio toggled -> ' .. tostring(radioEnabled) .. ' (mute/unmute own emitter only)')
        -- 不销毁会话：只静音/恢复自己的声源，远端声源与收听不受影响
        -- Don't kill the session: just mute/unmute our own emitter; remote audio unaffected
        SendNUIMessage({ type = 'volume', volume = radioEnabled and settings.Volume or 0 })
        if not radioEnabled then
            Notify('~r~RADIO OFFLINE~s~ (you no longer emit)')
        else
            Notify('~g~RADIO ONLINE~s~ • ' .. #AudioFiles .. ' WAVs • Volume ' .. VolumePercent() .. '%')
        end
    elseif index == 1 then
        -- 自启动开关：决定下次进服是否自动开台（持久化到 KVP，重启/重连不丢失）
        -- Auto Start toggle: radio enables itself on the NEXT join (persisted via KVP)
        settings.AutoStart = not settings.AutoStart
        Dbg('menu: AutoStart -> ' .. tostring(settings.AutoStart))
        if settings.AutoStart then
            Notify('~g~AUTO START ON~s~ Radio will enable itself next time you join.')
        else
            Notify('~y~AUTO START OFF~s~ Radio stays off when you join.')
        end
    elseif index == 2 then
        -- 音量 ±5%，本机声源实时生效 / volume ±5%, applied live to own emitter
        settings.Volume = Round2(Clamp(settings.Volume + delta * 0.05, 0.0, 1.0))
        Dbg(('menu: Volume -> %.2f (sent live to NUI)'):format(settings.Volume))
        -- 关台状态下改音量不得解除静音 / changing volume while OFF must not unmute
        SendNUIMessage({ type = 'volume', volume = radioEnabled and settings.Volume or 0 })
    elseif index == 3 then
        settings.NormalizeVolume = not settings.NormalizeVolume
        Dbg('menu: NormalizeVolume -> ' .. tostring(settings.NormalizeVolume))
    elseif index == 4 then
        -- 菜单位置循环 / cycle dock position
        local nextPosition = { Left = 'Center', Center = 'Right', Right = 'Left' }
        local prevPosition = { Left = 'Right', Center = 'Left', Right = 'Center' }
        settings.MenuPosition = (delta >= 0) and nextPosition[settings.MenuPosition] or prevPosition[settings.MenuPosition]
        Dbg('menu: MenuPosition -> ' .. settings.MenuPosition)
    end

    -- 每次修改立即持久化 + 上报音量（声源响度随改随生效）
    -- Persist on EVERY change + report volume (emission updates immediately)
    SaveSettings()
    ReportVolume()
end

-- ===== 菜单开 / 关 / 状态同步 / Menu open, close & state sync =====

-- 菜单位置中文名 / Chinese labels for the dock position
local PositionNames = { Left = '左侧', Center = '居中', Right = '右侧' }

-- 把当前取值发给 NUI 渲染（取值文本已汉化；selected 供 NUI 高亮选中行）
-- Push current values to the NUI (localized; 'selected' drives the NUI row highlight)
local function SendState()
    SendNUIMessage({
        type = 'state',
        status = radioEnabled and 'ONLINE' or 'OFFLINE',
        count = #AudioFiles,
        position = settings.MenuPosition,
        selected = menuIndex - 1, -- NUI 用 0 基索引高亮 / NUI uses a 0-based highlight index
        values = {
            radioEnabled and '开启' or '关闭',                      -- 0 电台开关
            settings.AutoStart and '开启' or '关闭',                -- 1 自启动
            VolumePercent() .. '%',                                 -- 2 音量
            settings.NormalizeVolume and '开' or '关',              -- 3 音量均衡
            PositionNames[settings.MenuPosition],                   -- 4 菜单位置
            '回车',                                                 -- 5 测试播放
            '回车',                                                 -- 6 重置设置
            '回车',                                                 -- 7 保存并关闭
        },
    })
end

local function CloseMenu()
    if not menuOpen then return end
    menuOpen = false
    Dbg('menu closed (settings saved)')
    -- 不再调用 SetNuiFocus：鼠标与游戏输入全程不被捕获，玩家可自由移动
    -- No SetNuiFocus at all: mouse & game input are never captured, the player can keep moving
    SaveSettings()
    Notify('~g~SETTINGS SAVED~s~ Radio is ' .. (radioEnabled and 'ONLINE' or 'OFFLINE') .. ' • Volume ' .. VolumePercent() .. '%')
    SendNUIMessage({ type = 'close' })
end

local function OpenMenu()
    if menuOpen then return end
    menuOpen = true
    menuIndex = 1 -- 打开时重置选中项（Lua 侧 1 基索引）/ reset selection on open (Lua 1-based index)
    Dbg('menu opened')
    SendState()
    SendNUIMessage({ type = 'open' })
end

-- 确认激活当前选中项（原版 ActivateMenuItem）/ activate the selected item (mirrors ActivateMenuItem)
local function ActivateMenuItem()
    local index = menuIndex - 1 -- 转为 0 基菜单项号 / convert to 0-based item index
    if index <= 4 then
        AdjustSetting(index, 1)
    elseif index == 5 then
        -- 测试播放（本地自听，不参与全服同步）/ local test play, not synced
        local entry = SelectClip()
        if entry then
            playToken = playToken + 1
            playbackEnded = false
            isPlaying = true
            lastVolumes = {} -- 本地测试只有自己的声源 / local test: own emitter only
            Dbg('menu: TEST PLAY -> NUI: token=' .. playToken .. ' file=' .. entry.file)
            SendNUIMessage({
                type = 'play3d',
                token = playToken,
                file = entry.file,
                ownVolume = settings.Volume,
                normalize = settings.NormalizeVolume,
                volumes = {},
                sync = {
                    refDistance = Config.Sync.RefDistance,
                    rolloff = Config.Sync.Rolloff,
                    maxDistance = Config.Sync.EmitterRange,
                    maxEmitters = Config.Sync.MaxEmitters,
                    lowpassNear = Config.Sync.LowpassNear,
                    lowpassFar = Config.Sync.LowpassFar,
                },
            })
            Notify('~b~RADIO CHECK~s~ Playing a random test transmission.')
        else
            Dbg('menu: TEST PLAY failed, manifest empty')
            Notify('~r~AUDIO ERROR~s~ No WAV files found.')
        end
    elseif index == 6 then
        -- 恢复出厂默认并立即保存（与单项修改行为一致）
        -- Restore defaults and persist immediately (same behavior as single-item edits)
        settings = {
            AutoStart       = Config.Defaults.AutoStart,
            Notifications   = Config.Defaults.Notifications,
            Volume          = Config.Defaults.Volume,
            NormalizeVolume = Config.Defaults.NormalizeVolume,
            MenuPosition    = Config.Defaults.MenuPosition,
        }
        radioEnabled = settings.AutoStart
        Dbg('menu: RESET to defaults (radioEnabled=' .. tostring(radioEnabled) .. ')')
        -- 重置只静音/恢复自己的声源，不销毁会话 / reset only mutes/unmutes our own emitter
        SendNUIMessage({ type = 'volume', volume = radioEnabled and settings.Volume or 0 })
        SaveSettings()
        ReportVolume()
        SendNUIMessage({ type = 'position', position = settings.MenuPosition })
        Notify('~y~SETTINGS RESET~s~ Release defaults restored.')
    elseif index == 7 then
        CloseMenu()
    end
    SendState()
end

-- ===== 键盘输入循环（不用 NUI 焦点，玩家可边移动边操作）=====

-- 前端控件编号 / frontend control ids
local CTRL_PHONE        = 27   -- 手机键 / phone
local CTRL_UP, CTRL_DOWN, CTRL_LEFT, CTRL_RIGHT = 172, 173, 174, 175
local CTRL_ACCEPT       = 201  -- 回车 / Enter
local CTRL_CANCEL       = 177  -- 退格/Esc / Backspace/Esc

CreateThread(function()
    while true do
        if menuOpen then
            -- 每帧禁用前端/手机控件，防止游戏自身响应（移动、视角等正常控件不受影响）
            -- Disable the frontend controls every frame; movement/camera controls stay untouched
            DisableControlAction(0, CTRL_PHONE, true)
            DisableControlAction(0, CTRL_UP, true)
            DisableControlAction(0, CTRL_DOWN, true)
            DisableControlAction(0, CTRL_LEFT, true)
            DisableControlAction(0, CTRL_RIGHT, true)
            DisableControlAction(0, CTRL_ACCEPT, true)
            DisableControlAction(0, CTRL_CANCEL, true)

            if IsDisabledControlJustPressed(0, CTRL_UP) then
                menuIndex = (menuIndex + MENU_ITEMS - 2) % MENU_ITEMS + 1 -- 上移并循环 / wrap upward
                SendState()
            elseif IsDisabledControlJustPressed(0, CTRL_DOWN) then
                menuIndex = menuIndex % MENU_ITEMS + 1 -- 下移并循环 / wrap downward
                SendState()
            elseif IsDisabledControlJustPressed(0, CTRL_LEFT) then
                AdjustSetting(menuIndex - 1, -1)
                SendState()
            elseif IsDisabledControlJustPressed(0, CTRL_RIGHT) then
                AdjustSetting(menuIndex - 1, 1)
                SendState()
            elseif IsDisabledControlJustPressed(0, CTRL_ACCEPT) then
                ActivateMenuItem()
            elseif IsDisabledControlJustPressed(0, CTRL_CANCEL) then
                CloseMenu() -- 保存并关闭 / save & close
            end
            Wait(0) -- 菜单打开时逐帧轮询 / poll per frame while open
        else
            Wait(150) -- 菜单关闭时低频空转 / idle while closed
        end
    end
end)

-- ===== 指令与热键注册 / Command & hotkey registration =====

-- 开/关电台统一走菜单第一项 "Radio"（避免 /radio 与语音电台等插件指令重复）
-- The on/off switch lives in menu item "Radio" (avoids /radio clashing with voice-radio plugins)

-- /Sncradio 打开设置菜单 / /Sncradio opens the settings menu
RegisterCommand(Config.Commands.menu, function()
    Dbg('command /' .. Config.Commands.menu .. ' -> toggle menu')
    if menuOpen then CloseMenu() else OpenMenu() end
end, false)

-- 聊天框自动补全提示 / chat suggestions
CreateThread(function()
    TriggerEvent('chat:addSuggestion', '/' .. Config.Commands.menu, '打开电台设置菜单（内含开关）/ open the radio settings menu (toggle included)')
    TriggerEvent('chat:addSuggestion', '/brcdebug', '电台诊断：打印各链路状态 / radio diagnostics: dump every link state')
end)

-- ===== 诊断指令 / Diagnostics command =====
-- /brcdebug 分链路打印：本机标识 -> 时钟同步 -> 音量表 -> NUI 音频引擎状态
-- 用于定位"听不见其他玩家"断在哪一跳 / pinpoints which hop breaks remote audio
local lastDebugStamp = 0

RegisterNUICallback('debugReport', function(data, cb)
    lastDebugStamp = GetGameTimer()
    print('^5[BRC-DEBUG]^7 ---- NUI 音频引擎 / NUI audio engine ----')
    print(('^5[BRC-DEBUG]^7 ctx.state=%s emitters=%s ownGain=%s buffer=%s norm=%s startedAgoMs=%s')
        :format(tostring(data.ctxState), tostring(data.emitterCount), tostring(data.ownGain),
                tostring(data.hasBuffer), tostring(data.norm), tostring(data.startedAgoMs)))
    if data.emitters and #data.emitters > 0 then
        for _, e in ipairs(data.emitters) do
            print(('^5[BRC-DEBUG]^7   emitter id=%s vol=%s dist=%s gain=%s cutoff=%s')
                :format(tostring(e.id), tostring(e.vol), tostring(e.dist), tostring(e.gain), tostring(e.cutoff)))
        end
    end
    cb('ok')
end)

RegisterCommand('brcdebug', function()
    print('^5[BRC-DEBUG]^7 ===== Background Radio Chatter 诊断 / diagnostics =====')
    print(('^5[BRC-DEBUG]^7 myServerId=%s radioEnabled=%s isPlaying=%s playToken=%s')
        :format(tostring(GetPlayerServerId(PlayerId())), tostring(radioEnabled), tostring(isPlaying), tostring(playToken)))
    print(('^5[BRC-DEBUG]^7 clockOffset=%s (nil=未校准/not calibrated) manifest=%s')
        :format(tostring(serverOffset), tostring(#AudioFiles)))
    -- 音量表：lastVolumes 与 lastClipVol（传给 NUI 的当前值）
    -- Volume table: lastVolumes (broadcast array) and lastClipVol (current emitter list)
    print(('^5[BRC-DEBUG]^7 lastVolumes(#%s):'):format(tostring(#lastVolumes)))
    for _, entry in ipairs(lastVolumes) do
        print(('^5[BRC-DEBUG]^7   {id=%s vol=%s}'):format(tostring(entry.id), tostring(entry.vol)))
    end
    print(('^5[BRC-DEBUG]^7 lastClipVol(#%s):'):format(tostring(lastClipVol and #lastClipVol or 0)))
    if lastClipVol then
        for _, e in ipairs(lastClipVol) do
            print(('^5[BRC-DEBUG]^7   {id=%s dist=%s vol=%s}'):format(tostring(e.id), tostring(e.dist), tostring(e.vol)))
        end
    end
    -- 向 NUI 请求引擎状态 / ask the NUI for its engine state
    lastDebugStamp = 0
    SendNUIMessage({ type = 'debug' })
    CreateThread(function()
        local deadline = GetGameTimer() + 1500
        while GetGameTimer() < deadline and lastDebugStamp == 0 do Wait(50) end
        if lastDebugStamp == 0 then
            print('^5[BRC-DEBUG]^7 NUI 未回应 debugReport —— NUI 页面未加载或消息链路断裂')
            print('^5[BRC-DEBUG]^7 NUI did not answer —— the NUI page is not loaded or messaging is broken')
        end
    end)
end, false)

-- ===== 资源生命周期 / Resource lifecycle =====

math.randomseed(GetGameTimer())

CreateThread(function()
    -- 同步调试开关给 NUI（关 = NUI 不往玩家 F8 打日志）/ sync the debug switch to the NUI (off = no NUI logs in the player's F8)
    SendNUIMessage({ type = 'debugMode', enabled = DBG })
    -- settings 已在顶层加载（见 LoadSettings 定义后）/ settings already loaded at top level
    -- 进服初始开关 = 自启动设置（持久化，重连不丢失）/ initial state = AutoStart (persisted across relogs)
    radioEnabled = settings.AutoStart
    Dbg('startup: manifest=' .. #AudioFiles .. ' clips, autoStart=' .. tostring(settings.AutoStart)
        .. ', radioEnabled=' .. tostring(radioEnabled))
    ReportVolume()                  -- 上报声源响度 / report emission volume
    -- 先做一次时钟校准再提示就绪 / calibrate once before announcing readiness
    RequestClockSync()
    Wait(2000)
    if #AudioFiles == 0 then
        Notify('~r~Background Radio Chatter~s~ failed: audio manifest is empty.')
    elseif radioEnabled then
        Notify('~g~RADIO ONLINE~s~ • ' .. #AudioFiles .. ' WAVs • Use /' .. Config.Commands.menu .. ' for settings.')
    else
        -- 关台时仍可听见附近开台者的电台；开关只决定自己是否发声
        -- With the radio OFF you still HEAR nearby ON players; the switch only controls emitting
        Notify('~b~Background Radio Chatter~s~ ready. You can hear nearby radios. Use /' .. Config.Commands.menu .. ' to start emitting.')
    end
end)

-- 资源停止时清理：停声 / cleanup on resource stop: stop audio
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        Dbg('onResourceStop -> stopping audio')
        SendNUIMessage({ type = 'stop' })
    end
end)
