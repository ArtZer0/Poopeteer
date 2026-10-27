-- ManualRaidOrder.lua
-- Load AFTER all original Puppeteer files.
--
-- Alt + Left Mouse Button: swap two displayed raid players.
-- Actual raid subgroups are NEVER changed.
--
-- Manual ordering is reset once on login or /reload.
-- Zoning does not reset the manual ordering.

local PT = Puppeteer
local UF = PTUnitFrame
local GROUP = PTUnitFrameGroup

local VISUAL_GROUP_SIZE = 5

local overlays = {}
local drag = nil
local active = false

local function IsRaidGroup(group)
    return group
        and group.environment == "raid"
        and not group.petGroup
end

local function GetKey(ui)
    if ui:IsFake() then
        return "TEST:" .. ui:GetUnit()
    end

    if not UnitExists(ui:GetUnit()) then
        return nil
    end

    return UnitName(ui:GetUnit())
end

local function GetOrders(create)
    if not PTOptions then
        return nil
    end

    if not PTOptions.ManualRaidOrders then
        if not create then
            return nil
        end

        PTOptions.ManualRaidOrders = {}
    end

    local realm = GetRealmName() or "Unknown"
    local orders = PTOptions.ManualRaidOrders[realm]

    if not orders and create then
        orders = {}
        PTOptions.ManualRaidOrders[realm] = orders
    end

    return orders
end

local function GetOrder(group)
    local orders = GetOrders(false)
    return orders and orders[group.name]
end

local function SaveOrder(group, order)
    local orders = GetOrders(true)

    if orders then
        orders[group.name] = order
    end
end

local function ClearSavedOrder()
    if PTOptions and PTOptions.ManualRaidOrders then
        local realm = GetRealmName() or "Unknown"
        PTOptions.ManualRaidOrders[realm] = nil
    end
end

local function Message(text)
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff80ff80[Puppeteer
