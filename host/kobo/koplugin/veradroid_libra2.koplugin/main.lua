-- SPDX-License-Identifier: GPL-3.0-or-later
-- KOReader plugin launcher for VeraDroid on Kobo Libra 2.
local Device = require("device")
if not Device:isKobo() then return { disabled = true } end

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local VeraDroidLibra2 = WidgetContainer:extend {
    name = "veradroid_libra2",
    is_doc_only = false,
}

local VD = "/mnt/onboard/.adds/veradroid-libra2"
local BOOT = VD .. "/boot/veradroid.sh"
local STOP = VD .. "/boot/stop.sh"

local function isRunning()
    local rc = os.execute("/bin/sh " .. BOOT .. " status >/dev/null 2>&1")
    return rc == 0 or rc == true
end

function VeraDroidLibra2:init()
    self.ui.menu:registerToMainMenu(self)
end

function VeraDroidLibra2:addToMainMenu(menu_items)
    menu_items.veradroid_libra2 = {
        text = _("VeraDroid (Libra 2)"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("启动 VeraDroid (Android)"),
                callback = function()
                    self:startVeraDroid()
                end,
            },
            {
                text = _("停止 VeraDroid"),
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
                    UIManager:show(InfoMessage:new {
                        text = "VeraDroid 状态：" .. st .. "\n安装目录：" .. VD,
                    })
                end,
            },
        },
    }
end

function VeraDroidLibra2:startVeraDroid()
    local f = io.open(BOOT, "r")
    if not f then
        UIManager:show(InfoMessage:new {
            text = "未找到 VeraDroid 启动脚本：\n" .. BOOT,
        })
        return
    end
    f:close()
    UIManager:show(InfoMessage:new {
        text = _("正在启动 VeraDroid，请稍候…"),
        timeout = 2,
    })
    pcall(function() UIManager:forceRePaint() end)
    os.execute("setsid /bin/sh " .. BOOT .. " home </dev/null >/dev/null 2>&1 &")
end

return VeraDroidLibra2
