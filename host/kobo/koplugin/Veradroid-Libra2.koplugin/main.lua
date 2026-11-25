-- SPDX-License-Identifier: GPL-3.0-or-later
-- KOReader plugin launcher for Veradroid-Libra2 on Kobo Libra 2 (N418).
local Device = require("device")
if not Device:isKobo() then return { disabled = true } end

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local VeradroidLibra2 = WidgetContainer:extend {
    name = "Veradroid-Libra2",
    is_doc_only = false,
}

local VD = "/mnt/onboard/.adds/Veradroid-Libra2"
local BOOT = VD .. "/boot/veradroid.sh"
local STOP = VD .. "/boot/stop.sh"
local UPDATER = VD .. "/boot/lib/localupdate.sh"

local function isRunning()
    local rc = os.execute("/bin/sh " .. BOOT .. " status >/dev/null 2>&1")
    return rc == 0 or rc == true
end

local function readLine(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return s
end

local function fileExists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

function VeradroidLibra2:init()
    self.ui.menu:registerToMainMenu(self)
end

function VeradroidLibra2:addToMainMenu(menu_items)
    menu_items.veradroid_libra2_pkg = {
        text = _("Veradroid-Libra2"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("启动 Veradroid-Libra2 (Android)"),
                callback = function()
                    self:startVeraDroid()
                end,
            },
            {
                text = _("停止 Veradroid-Libra2"),
                callback = function()
                    os.execute("/bin/sh " .. STOP .. " </dev/null >/dev/null 2>&1 &")
                    UIManager:show(InfoMessage:new {
                        text = _("已发送停止指令。"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("应用离线升级包"),
                callback = function()
                    self:applyUpdate()
                end,
            },
            {
                text = _("查看运行状态与版本"),
                callback = function()
                    local st = isRunning() and "运行中" or "未运行"
                    local ver = readLine(VD .. "/VERSION") or "未知"
                    local img = fileExists(VD .. "/veradroid-sys.img") and "已初始化" or "未初始化（首次启动将自动创建）"
                    UIManager:show(InfoMessage:new {
                        text = "Veradroid-Libra2 状态：" .. st
                            .. "\n当前版本：" .. ver
                            .. "\n系统镜像：" .. img
                            .. "\n安装目录：" .. VD,
                    })
                end,
            },
        },
    }
end

function VeradroidLibra2:startVeraDroid()
    if not fileExists(BOOT) then
        UIManager:show(InfoMessage:new {
            text = "未找到 Veradroid-Libra2 启动脚本：\n" .. BOOT,
        })
        return
    end
    local msg = fileExists(VD .. "/veradroid-sys.img")
        and _("正在启动 Veradroid-Libra2，请稍候…")
        or _("首次启动：将自动初始化 Android 系统镜像（约 1–2 分钟），请稍候…")
    UIManager:show(InfoMessage:new {
        text = msg,
        timeout = 3,
    })
    pcall(function() UIManager:forceRePaint() end)
    os.execute("setsid /bin/sh " .. BOOT .. " home </dev/null >/dev/null 2>&1 &")
end

function VeradroidLibra2:applyUpdate()
    if not fileExists(UPDATER) then
        UIManager:show(InfoMessage:new {
            text = "未找到离线升级脚本：\n" .. UPDATER,
        })
        return
    end
    local p = io.popen("/bin/sh " .. UPDATER .. " install 2>&1")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    out = out:gsub("^%s+", ""):gsub("%s+$", "")
    if out == "" then
        out = "未在 update/ 目录发现可用的升级包。\n请将 Veradroid-Libra2-*.zip 放入：\n" .. VD .. "/update/"
    end
    UIManager:show(InfoMessage:new {
        text = out,
    })
end

return VeradroidLibra2
