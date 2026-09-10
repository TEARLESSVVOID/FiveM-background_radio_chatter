-- ============================================================
-- Background Radio Chatter - FiveM 版
-- FiveM port of the LSPDFR "Background Radio Chatter" plugin
--
-- 安装说明 / Installation:
--   1. 把 background_radio_chatter 文件夹放到服务器 resources 目录
--      (Put this folder into your server's resources directory)
--   2. 在 server.cfg 中添加: ensure background_radio_chatter
--   3. 游戏内指令 / In-game commands:
--      /radiomenu 打开设置菜单（电台开关在菜单第一项 "Radio"）
--      /radiomenu opens the settings menu (the on-off switch is menu item "Radio")
--   4. 菜单为纯键盘操作且不占用游戏输入：方向键选择/修改、回车确认、退格/Esc 保存关闭，
--      菜单打开时玩家仍可正常移动（不捕获鼠标、不锁定视角）
--      Keyboard-only menu that never captures input: arrows navigate, Enter activates,
--      Backspace/Esc saves & closes; the player can keep moving while it is open.
-- ============================================================

fx_version 'cerulean'
game 'gta5'

name 'background_radio_chatter'
description 'Background police radio chatter player (ported from LSPDFR v1.2.1) - 背景警用电台杂谈播放器'
author 'Reverse-engineered & ported'
version '1.0.0'

-- 共享脚本（配置 + 音频清单，双端加载）/ shared scripts (config + manifest, both contexts)
shared_scripts {
    'config.lua',
    'client/audio_files.lua',
}

-- 客户端脚本 / client script
client_scripts {
    'client/main.lua',
}

-- 服务器指挥端：统一随机选曲与全服同步 / server conductor: synced clip scheduling
server_scripts {
    'server/main.lua',
}

-- NUI 设置菜单 / NUI settings menu
ui_page 'html/index.html'

files {
    'html/index.html',
    'html/ui.js',
    'html/ui.css',
    'html/audio/*.wav',
}
