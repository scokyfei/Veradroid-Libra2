-- SPDX-License-Identifier: GPL-3.0-or-later
-- KOReader plugin launcher for VeraDroid Dev (side-by-side with Veradroid-Libra2 release).
local Device = require("device")
if not Device:isKobo() then return { disabled = true } end

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local VeraDroidLibra2Dev = WidgetContainer:extend {
    name = "veradroid_libra2_dev",
    is_doc_only = false,
}

local VD = "/mnt/onboard/.adds/veradroid-libra2-dev"
local BOOT = VD .. "/boot/veradroid.sh"
local STOP = VD .. "/boot/stop.sh"

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

function VeraDroidLibra2Dev:init()
    self.ui.menu:registerToMainMenu(self)
end

function VeraDroidLibra2Dev:addToMainMenu(menu_items)
    menu_items.veradroid_libra2_dev = {
        text = _("VeraDroid (Dev)"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("启动 VeraDroid Dev (Android)"),
                callback = function()
                    self:startVeraDroid()
                end,
            },
            {
                text = _("停止 VeraDroid Dev"),
                callback = function()
                    os.execute("/bin/sh " .. STOP .. " </dev/null >/dev/null 2>&1 &")
                    UIManager:show(InfoMessage:new {
                        text = _("已发送停止指令。"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("查看运行状态"),
                callback = function()
                    local st = isRunning() and "运行中" or "未运行"
                    local ver = readLine(VD .. "/VERSION") or "未知"
                    UIManager:show(InfoMessage:new {
                        text = "VeraDroid Dev 状态：" .. st
                            .. "\n当前版本：" .. ver
                            .. "\n安装目录：" .. VD,
                    })
                end,
            },
        },
    }
end

function VeraDroidLibra2Dev:startVeraDroid()
    if not fileExists(BOOT) then
        UIManager:show(InfoMessage:new {
            text = "未找到开发版启动脚本：\n" .. BOOT,
        })
        return
    end
    UIManager:show(InfoMessage:new {
        text = _("正在启动 VeraDroid Dev，请稍候…"),
        timeout = 2,
    })
    pcall(function() UIManager:forceRePaint() end)
    os.execute("setsid /bin/sh " .. BOOT .. " home </dev/null >/dev/null 2>&1 &")
end

return VeraDroidLibra2Dev
