-- ============================================================
-- 配置文件 / Configuration file
-- 所有可调参数集中在此 / All tunable parameters are centralized here
-- 默认值与原 LSPDFR 插件 v1.2.1 保持一致
-- Defaults match the original LSPDFR plugin v1.2.1
-- ============================================================

Config = {}

-- 调试开关：true = 所有行为输出到 F8 控制台（三层：server / client / NUI）
-- Debug switch: true = log every action to the F8 console (server / client / NUI layers)
Config.Debug = false

-- 菜单指令 / Menu command（唯一的聊天指令；如与其他插件重名可在此改名）
-- The only chat command; rename here if it collides with another resource
Config.Commands = {
    menu = 'Sncradio',  -- 打开设置菜单 / open the settings menu
}

-- 出厂默认设置 / Factory default settings
-- 说明：这里全部是"玩家可在菜单里修改并持久化"的个人设置；
--       播放节奏（间隔/长静默/防重复）在下方 Config.Schedule（服务器专用）。
-- Note: everything here is a per-player setting editable in the menu;
--       playback rhythm lives in Config.Schedule below (server-only).
Config.Defaults = {
    Enabled          = false,  -- 资源启动后是否自动开启 / auto-start when the resource loads
    Notifications    = true,   -- 屏幕左上角通知 / GTA feed notifications
    Volume           = 0.35,   -- 主音量 0.0 ~ 1.0 / master volume 0..1
    NormalizeVolume  = true,   -- 均衡各 WAV 响度 / normalize WAV loudness
    MenuPosition     = 'Right', -- 菜单停靠: Left / Center / Right
}

-- 玩家设置持久化键名 / KVP key used to persist player settings
Config.SettingsKey = 'brc_settings_v1'

-- ===== 播放调度参数（服务器专用，全服唯一节奏来源）=====
-- ===== Playback scheduling (SERVER-ONLY; the single rhythm source) =====
-- 说明：间隔"全部"只从这里读取——服务器指挥端是全服唯一的调度者，
--       玩家本地无法修改（同步播放的节奏必须全服一致）。
--       修改后需重启资源（restart background_radio_chatter）生效。
-- Note: ALL gap values are read ONLY from here. The server conductor is the sole
--       scheduler (per-player edits would break the shared sync). Restart the
--       resource after changing these.
-- 听感间隔定义 / perceived gap definition:
--   上一条录音结束 → 下一条录音开始 = 随机 [Schedule.MinDelay, Schedule.MaxDelay] 秒
--   (previous clip end -> next clip start = random within [MinDelay, MaxDelay])
Config.Schedule = {
    MinDelay          = 5,   -- 最小间隔（秒）/ min gap, seconds
    MaxDelay          = 15,  -- 最大间隔（秒）/ max gap, seconds
    PreventRepeat     = true,-- 防止连续重复同一条 / avoid repeating the last clip
    LongSilenceChance = 1,   -- 触发长静默的概率（0~100 %）/ chance of a long silence, %
    LongSilenceMin    = 10,  -- 长静默最小追加（秒）/ long-silence min extra, seconds
    LongSilenceMax    = 30,  -- 长静默最大追加（秒）/ long-silence max extra, seconds
}

-- ===== 3D 空间音效与全服同步参数 / 3D audio & server-wide sync =====
-- 声学依据 / acoustics basis：
--   指数衰减 exponential 模型下，增益 = (RefDistance / 距离)^Rolloff
--   10m 处 ≈ 8%，15m ≈ 5%，20m ≈ 3%（几乎不可闻）——远处的电台就该快被听不见
Config.Sync = {
    StartLead    = 2500, -- 广播提前量(毫秒)：服务器提前宣布开播时刻，各客户端对齐
                         -- lead time (ms) before the synced start so clients can align
    ResyncEvery  = 30,   -- 时钟重校准间隔(秒) / clock re-calibration interval, seconds
    EmitterRange = 6.0, -- 电台可闻半径(米)，超过即销毁声源 / audible radius, emitters beyond are dropped
    RefDistance  = 1.2,  -- 距离衰减参考距离(米)：此距离内全额响度 / full loudness within this radius
    Rolloff      = 1.4,  -- 距离衰减指数：越大远处衰减越快 / falloff exponent: higher = steeper
    LowpassNear  = 19000, -- 近处低通截止(Hz)：几乎不闷 / near-field lowpass cutoff, Hz
    LowpassFar   = 1500,  -- 远处低通截止(Hz)：空气吸声，远处声音发闷 / far-field cutoff (air absorption)
    MaxEmitters  = 8,    -- 同时渲染的远端声源上限（性能保护）/ max rendered remote emitters (perf guard)
}
