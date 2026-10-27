-- ManualRaidOrder.lua
-- Manual raid frame ordering for Puppeteer.
-- Load AFTER all original addon files.
-- Compatible with WoW 1.12-style script handlers.
--
-- Hold Alt, then drag a player onto another player with LMB.
-- Only the visual order changes. Actual raid groups are untouched.

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

local function Message(text)
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff80ff80[Puppeteer]|r " .. text
    )
end

-- Preserve the original ordering until a manual order is saved.
local OriginalGetSortedUIs = GROUP.GetSortedUIs

function GROUP:GetSortedUIs()
    local normalGroups = OriginalGetSortedUIs(self)

    if not IsRaidGroup(self) then
        return normalGroups
    end

    local order = GetOrder(self)

    if not order then
        return normalGroups
    end

    local available = {}
    local normalKeys = {}

    for _, group in ipairs(normalGroups) do
        for _, ui in ipairs(group) do
            local key = GetKey(ui)

            if key and ui:IsShown() and not available[key] then
                available[key] = ui
                table.insert(normalKeys, key)
            end
        end
    end

    local known = {}

    for _, key in ipairs(order) do
        known[key] = true
    end

    -- Add new participants after previously ordered players.
    for _, key in ipairs(normalKeys) do
        if not known[key] then
            table.insert(order, key)
            known[key] = true
        end
    end

    local result = {}

    for _, key in ipairs(order) do
        local ui = available[key]

        if ui then
            table.insert(result, ui)
            available[key] = nil
        end
    end

    -- Keep visual groups of five instead of one continuous group.
    -- These groups are independent of actual raid subgroups.
    local visualGroups = {}
    local currentGroup

    for i, ui in ipairs(result) do
        if math.mod(i - 1, VISUAL_GROUP_SIZE) == 0 then
            currentGroup = {}
            table.insert(visualGroups, currentGroup)
        end

        table.insert(currentGroup, ui)
    end

    return visualGroups
end

local function SwapPlayers(group, sourceKey, targetKey)
    if not sourceKey or not targetKey or sourceKey == targetKey then
        return
    end

    local order = GetOrder(group)

    if not order then
        -- Capture the visible order on the first successful swap.
        order = {}
        local seen = {}

        for _, section in ipairs(group:GetSortedUIs()) do
            for _, ui in ipairs(section) do
                local key = GetKey(ui)

                if key and ui:IsShown() and not seen[key] then
                    table.insert(order, key)
                    seen[key] = true
                end
            end
        end
    else
        -- Include any players who joined since the last update.
        group:GetSortedUIs()
    end

    local sourceIndex
    local targetIndex

    for i, key in ipairs(order) do
        if key == sourceKey then
            sourceIndex = i
        end

        if key == targetKey then
            targetIndex = i
        end
    end

    if not sourceIndex or not targetIndex then
        return
    end

    order[sourceIndex], order[targetIndex] =
        order[targetIndex], order[sourceIndex]

    SaveOrder(group, order)
    group:UpdateUIPositions()
end

-- Cursor label. Does not intercept mouse input.
local ghost = CreateFrame("Frame", nil, UIParent)
ghost:SetFrameStrata("TOOLTIP")
ghost:SetWidth(240)
ghost:SetHeight(24)
ghost:EnableMouse(false)

local ghostText = ghost:CreateFontString(
    nil,
    "OVERLAY",
    "GameFontNormal"
)

ghostText:SetAllPoints(ghost)
ghostText:SetJustifyH("LEFT")
ghostText:SetTextColor(1, 0.85, 0.2)

ghost:Hide()

local function CancelDrag()
    drag = nil
    ghost:Hide()
end

local function UpdateGhost()
    if not drag then
        return
    end

    local root = drag.source:GetRootContainer()

    -- Unit IDs can change ownership after a roster update.
    if not root:IsVisible()
        or GetKey(drag.source) ~= drag.sourceKey then
        CancelDrag()
        return
    end

    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()

    ghost:ClearAllPoints()
    ghost:SetPoint(
        "BOTTOMLEFT",
        UIParent,
        "BOTTOMLEFT",
        x / scale + 16,
        y / scale + 12
    )
end

local function BeginDrag(ui)
    CancelDrag()

    if not IsAltKeyDown() then
        return
    end

    local key = GetKey(ui)

    if not key then
        return
    end

    drag = {
        source = ui,
        sourceKey = key,
        group = ui.owningGroup
    }

    ghostText:SetText(ui:GetName() or key)
    ghost:Show()
    UpdateGhost()
end

local function FinishDrag()
    local current = drag

    if not current then
        return
    end

    local targetKey

    if GetKey(current.source) == current.sourceKey then
        for _, overlay in ipairs(overlays) do
            local ui = overlay.manualOrderUI

            if ui.owningGroup == current.group
                and overlay:IsVisible()
                and MouseIsOver(overlay) then
                targetKey = GetKey(ui)
                break
            end
        end
    end

    CancelDrag()

    -- Dropping outside another player cancels the operation.
    if targetKey then
        SwapPlayers(
            current.group,
            current.sourceKey,
            targetKey
        )
    end
end

local function SetActive(enabled)
    if active == enabled then
        return
    end

    active = enabled

    if enabled then
        PT.CurrentlyHeldButton = nil
        PT.Mouseover = nil
        PT.MouseoverFrame = nil

        PT.RemoveOverrideBindings()
        PT.HideSpellsTooltip()

        if UF.AuraTooltip then
            UF.AuraTooltip:Hide()
        end
    end

    for _, overlay in ipairs(overlays) do
        local ui = overlay.manualOrderUI

        if enabled then
            ui.pressed = false
            ui.hovered = false
            ui:AdjustHealthPosition()

            -- Place above aura buttons and frame decorations.
            overlay:SetFrameLevel(
                ui.button:GetFrameLevel() + 100
            )

            overlay:Show()
        else
            overlay:Hide()
        end
    end
end

local function InstallOverlay(ui)
    if ui.manualOrderOverlay then
        return
    end

    if not IsRaidGroup(ui.owningGroup) then
        return
    end

    local overlay = CreateFrame(
        "Frame",
        nil,
        ui:GetRootContainer()
    )

    ui.manualOrderOverlay = overlay
    overlay.manualOrderUI = ui

    overlay:SetAllPoints(ui:GetRootContainer())
    overlay:SetFrameLevel(ui.button:GetFrameLevel() + 100)
    overlay:EnableMouse(true)

    local tint = overlay:CreateTexture(nil, "OVERLAY")
    tint:SetAllPoints(overlay)
    tint:SetTexture(0.2, 0.7, 1, 0.18)

    overlay:SetScript("OnMouseDown", function()
        if arg1 == "LeftButton" then
            BeginDrag(ui)
        end
    end)

    overlay:SetScript("OnMouseUp", function()
        if arg1 == "LeftButton" then
            FinishDrag()
        end
    end)

    overlay:SetScript("OnHide", function()
        if drag and drag.source == ui then
            CancelDrag()
        end
    end)

    table.insert(overlays, overlay)

    if active then
        overlay:Show()
    else
        overlay:Hide()
    end
end

-- Install the input overlay after normal initialization.
local OriginalInitialize = UF.Initialize

function UF:Initialize()
    OriginalInitialize(self)
    InstallOverlay(self)
end

-- Block normal raid-frame actions while Alt is reserved for dragging.
-- Also protects against clicks arriving before the next OnUpdate.
local OriginalUnitFrameOnClick = PT.UnitFrame_OnClick

function PT.UnitFrame_OnClick(button, unit, ui)
    if ui and IsRaidGroup(ui.owningGroup) then
        if IsAltKeyDown() or active or drag then
            return
        end
    end

    return OriginalUnitFrameOnClick(button, unit, ui)
end

local watcher = CreateFrame("Frame")

watcher:SetScript("OnUpdate", function()
    local altDown = IsAltKeyDown() and true or false

    -- Retain the overlay if Alt is released before the mouse button.
    local shouldEnable = altDown or drag ~= nil

    SetActive(shouldEnable)

    if drag then
        UpdateGhost()
    end
end)

-- Cancel pending operations when the roster changes.
watcher:RegisterEvent("RAID_ROSTER_UPDATE")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")

watcher:SetScript("OnEvent", function()
    CancelDrag()
end)

-- Optional reset command.
-- No commands are required for normal drag-and-drop.
SLASH_PTRAIDRESET1 = "/ptraidreset"

SlashCmdList["PTRAIDRESET"] = function()
    CancelDrag()

    local orders = GetOrders(false)

    for _, group in pairs(PT.UnitFrameGroups) do
        if IsRaidGroup(group) then
            if orders then
                orders[group.name] = nil
            end

            group:UpdateUIPositions()
        end
    end

    Message("Manual raid order reset.")
end
