-- ManualRaidOrder.lua
-- Manual raid frame ordering for Puppeteer.
-- Load AFTER all original addon files.
-- Uses the WoW 1.12 event/script conventions.

local PT = Puppeteer
local UF = PTUnitFrame
local GROUP = PTUnitFrameGroup

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

-- Keep the original sorting for normal operation.
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

    -- New participants are placed after previously ordered players.
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

    -- Manual order overrides visual raid subgroup splitting.
    return {result}
end

local function SwapPlayers(group, sourceKey, targetKey)
    if not sourceKey or not targetKey or sourceKey == targetKey then
        return
    end

    local order = GetOrder(group)

    if not order then
        -- Capture the currently displayed order on the first swap.
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
        -- Synchronize participants before searching for positions.
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

-- Non-interactive label following the cursor.
local ghost = CreateFrame("Frame", nil, UIParent)
ghost:SetFrameStrata("TOOLTIP")
ghost:SetWidth(240)
ghost:SetHeight(24)
ghost:EnableMouse(false)

local ghostText = ghost:CreateFontString(
    nil, "OVERLAY", "GameFontNormal"
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

            -- Keep above aura buttons and other frame decorations.
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
        "Frame", nil, ui:GetRootContainer()
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

-- Attach the overlay after normal frame initialization.
local OriginalInitialize = UF.Initialize

function UF:Initialize()
    OriginalInitialize(self)
    InstallOverlay(self)
end

-- Protect against an Alt-click arriving before the next OnUpdate.
-- The original click function is otherwise unchanged.
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

    -- If Alt is released first, retain mouse capture until release.
    local shouldEnable = altDown or drag ~= nil

    SetActive(shouldEnable)

    if drag then
        UpdateGhost()
    end
end)

-- A roster change can reassign raid1, raid2, etc.
-- Cancel a pending operation rather than moving the wrong player.
watcher:RegisterEvent("RAID_ROSTER_UPDATE")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:SetScript("OnEvent", function()
    CancelDrag()
end)

-- Optional command: reset saved ordering.
-- Not required for normal rearrangement.
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
