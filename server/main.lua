-- ============================================================
-- Background Radio Chatter - 服务器指挥端 / Server conductor
--
-- 职责 / Responsibilities:
--   1) 统一随机选曲 + 统一随机间隔（全服听到完全相同的播放序列，杜绝不同步）
--      Single source of randomness: every player hears the exact same sequence
--   2) 精确同步：广播"开播时刻"（服务器 GetGameTimer 值），客户端校准时钟偏移后对齐
--      Precise sync: broadcasts the exact start instant; clients align via clock offset
--   3) 记录每位玩家的电台音量（声源响度 = 该玩家自己的设置，符合现实扬声器模型）
--      Tracks each player's emission volume (loudness = the emitter's own setting)
--
-- 调试 / Debug: Config.Debug = true 时所有行为输出到服务器与 F8 控制台
-- All actions are logged when Config.Debug is enabled.
-- ============================================================

local DBG = Config.Debug -- 调试开关（config.lua）/ debug switch from config.lua

-- 调试输出 / debug print helper
local function Dbg(message)
    if DBG then
        print('^3[BRC-SRV]^7 ' .. message)
    end
end

-- 玩家音量表 [serverId] = volume(0..1) / per-player emission volume
-- 只收录"电台已开启"的玩家；关闭即移除，杜绝幽灵声源
-- Only players with the radio ON are tracked; switching off removes the entry (no ghost emitters)
local volumes = {}
-- 上一条播放索引（防重复）/ last played index (prevent repeats)
local lastClipIdx = 0

Dbg(('resource started, manifest=%d clips, schedule: %d~%ds gap, long-silence %d%% (+%d~%ds), preventRepeat=%s')
    :format(#AudioFiles,
        Config.Schedule.MinDelay, Config.Schedule.MaxDelay,
        Config.Schedule.LongSilenceChance,
        Config.Schedule.LongSilenceMin, Config.Schedule.LongSilenceMax,
        tostring(Config.Schedule.PreventRepeat)))

-- 摘要打印音量表 / dump the volume table compactly
local function DumpVolumes(prefix)
    if not DBG then return end
    local parts = {}
    for id, vol in pairs(volumes) do
        parts[#parts + 1] = id .. '=' .. string.format('%.2f', vol)
    end
    Dbg(prefix .. ' volumes{' .. table.concat(parts, ', ') .. '} (' .. #parts .. ' emitters)')
end

-- 清理掉线玩家的音量记录 / drop records of leaving players
AddEventHandler('playerDropped', function()
    if volumes[source] ~= nil then
        Dbg('playerDropped id=' .. source .. ' -> removed from emitter table')
    end
    volumes[source] = nil
end)

-- 序列化音量表为显式数组 [{id, vol}, ...]
-- Serialize the volume table as an explicit array of {id, vol}
-- 关键修复：[serverId]=vol 的稀疏数字键表经 msgpack 传输会变带洞数组/键错位，
-- 导致客户端声源 id 对不上（"听不见某个开了的玩家"的根源）。
-- Key fix: a sparse [serverId]=vol table gets mangled into a holed array over msgpack,
-- so client emitter ids mismatched (the root cause of "can't hear a player who is ON").
local function PackVolumes()
    local list = {}
    for id, vol in pairs(volumes) do
        list[#list + 1] = { id = id, vol = vol }
    end
    return list
end

-- 客户端上报音量 + 开关状态（声源响度 = 该玩家自己的设置）
-- Client reports its volume + on/off state (emission = the player's own setting)
RegisterNetEvent('brc:reportVolume')
AddEventHandler('brc:reportVolume', function(vol, enabled)
    local src = source
    if DBG then
        Dbg(('brc:reportVolume from id=%s vol=%s enabled=%s'):format(tostring(src), tostring(vol), tostring(enabled)))
    end
    if src ~= 0 and type(vol) == 'number' then
        if enabled then
            volumes[src] = math.max(0.0, math.min(1.0, vol))
        else
            volumes[src] = nil -- 电台关闭：不再作为声源 / radio off: not an emitter
        end
        -- 立即把最新音量表推给全服：音量/开关变化实时生效，不必等下一轮广播
        -- Push the fresh table right away so changes take effect instantly
        TriggerClientEvent('brc:volumesUpdate', -1, PackVolumes())
        DumpVolumes('-> pushed brc:volumesUpdate to -1 after report from ' .. src)
    else
        Dbg('brc:reportVolume REJECTED (src=0 or vol not a number)')
    end
end)

-- 时钟校准：回传客户端发送时刻 + 服务器当前时刻（客户端据此算 RTT 与偏移）
-- Clock calibration: echo the client's send time + the server timer (client derives RTT & offset)
RegisterNetEvent('brc:syncRequest')
AddEventHandler('brc:syncRequest', function(sentAt)
    if DBG then
        Dbg(('brc:syncRequest from id=%s sentAt=%s -> replying serverTimer=%s')
            :format(tostring(source), tostring(sentAt), tostring(GetGameTimer())))
    end
    TriggerClientEvent('brc:syncReply', source, sentAt, GetGameTimer())
end)

-- 随机选曲（防重复，逻辑与原版 SelectClip 一致）/ random pick with repeat guard
local function PickClip()
    local count = #AudioFiles
    if count == 0 then return nil end
    local pool = {}
    if Config.Schedule.PreventRepeat and count > 1 then
        for i, _ in ipairs(AudioFiles) do
            if i ~= lastClipIdx then pool[#pool + 1] = i end
        end
    else
        for i = 1, count do pool[#pool + 1] = i end
    end
    local idx = pool[math.random(#pool)]
    lastClipIdx = idx
    return idx
end

-- 计算下一次间隔（含长静默，逻辑与原版 NextDelayMilliseconds 一致，改为服务器统一计算）
-- Next gap incl. long silence (same odds as the original, now decided once for everyone)
local function NextGapSeconds()
    local d = Config.Schedule -- 间隔只读服务器调度配置 / gaps read ONLY from Config.Schedule
    local gap = math.random(d.MinDelay, d.MaxDelay)
    local longPause = false
    if math.random(0, 99) < d.LongSilenceChance then
        gap = gap + math.random(d.LongSilenceMin, d.LongSilenceMax)
        longPause = true
    end
    -- 保护：间隔必须大于广播提前量(StartLead)，否则下一条会与本条重叠
    -- Guard: the gap must exceed StartLead or the next clip would overlap this one
    local minGap = math.ceil(Config.Sync.StartLead / 1000) + 1
    if gap < minGap then
        if DBG then Dbg(('gap %ss < guard %ss -> clamped'):format(gap, minGap)) end
        gap = minGap
    end
    if DBG then
        Dbg(('next gap = %ss%s'):format(gap, longPause and ' (incl. long silence)' or ''))
    end
    return gap
end

-- 指挥主循环 / conductor loop
CreateThread(function()
    math.randomseed(os.time())
    Dbg('conductor loop started')
    while true do
        local idx = PickClip()
        if idx then
            local entry = AudioFiles[idx]
            local startAt = GetGameTimer() + Config.Sync.StartLead
            -- 广播：曲目索引 + 服务器开播时刻 + 当前所有已开启玩家的音量数组
            -- Broadcast: clip index + server-side start instant + the volume array of ON players
            TriggerClientEvent('brc:transmission', -1, {
                clip    = idx,
                startAt = startAt,
                volumes = PackVolumes(),
            })
            DumpVolumes('brc:transmission -> -1 clip=' .. idx .. ' file=' .. tostring(entry.file)
                .. ' dur=' .. entry.dur .. 'ms startAt=' .. startAt .. ',')
            -- 关键修正：Wait 终点 = 本条开播(L=StartLead) + 曲长 + 随机间隔，
            -- 下一条广播恰在其开播前 L 毫秒发出 → 听感间隔恰好 = gap（不再叠加 StartLead 的 2.5 秒）
            -- Key fix: wait until clipEnd + gap; the next broadcast lands exactly L ms
            -- before its own start, so the PERCEIVED gap equals the configured gap exactly.
            local gap = NextGapSeconds()
            Wait(entry.dur + gap * 1000)
        else
            Dbg('manifest is EMPTY, retrying in 5s')
            Wait(5000) -- 清单为空，稍后重试 / empty manifest, retry later
        end
    end
end)
