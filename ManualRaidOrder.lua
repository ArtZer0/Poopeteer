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
        "|cff80ff80[Puppeteer]|r " .. text
    )
end

-- Preserve normal sorting for non-raid frame groups.
local OriginalGetSortedUIs = GROUP.GetSortedUIs

function GROUP:GetSortedUIs()
    if not IsRaidGroup(self) then
        return OriginalGetSortedUIs(self)
    end

    local order = GetOrder(self)
    local available = {}
    local rosterKeys = {}
    local realGroups = {}

    for i = 1, 8 do
        realGroups[i] = {}
    end

    -- Build the default layout from actual raid subgroups.
    for i = 1, GetNumRaidMembers() do
        local unit = "raid" .. i
        local ui = self.uis[unit]
        local _, _, subgroup = GetRaidRosterInfo(i)

        if ui and subgroup and realGroups[subgroup] then
            local key = GetKey(ui)

            if key and not available[key] then
                available[key] = ui
                table.insert(rosterKeys, key)
                table.insert(realGroups[subgroup], ui)
                ui:UpdateRole()
            end
        end
    end

    -- Support fake raid frames used by Puppeteer's test mode.
    if PT.TestUI then
        for i = 1, 40 do
            local unit = "raid" .. i
            local ui = self.uis[unit]

            if ui and ui:IsFake() and ui:IsShown() then
                local key = GetKey(ui)

                if key and not available[key] then
                    local subgroup =
                        math.floor((i - 1) / VISUAL_GROUP_SIZE) + 1

                    available[key] = ui
                    table.insert(rosterKeys, key)
                    table.insert(realGroups[subgroup], ui)
                    ui:UpdateRole()
                end
            end
        end
    end

    -- No manual arrangement: show actual raid groups separately.
    -- This does not depend on SplitRaidIntoGroups in the profile.
    if not order then
        local result = {}

        for i = 1, 8 do
            if table.getn(realGroups[i]) > 0 then
                table.insert(result, realGroups[i])
            end
        end

        return result
    end

    -- Manual arrangement: retain saved order.
    local known = {}

    for _, key in ipairs(order) do
        known[key] = true
    end

    -- Append newly joined players.
    for _, key in ipairs(rosterKeys) do
        if not known[key] then
            table.insert(order, key)
            known[key] = true
        end
    end

    local sortedPlayers = {}

    for _, key in ipairs(order) do
        local ui = available[key]

        if ui then
            table.insert(sortedPlayers, ui)
            available[key] = nil
        end
    end

    -- Split the manual order into visual groups of five.
    local visualGroups = {}
    local column

    for i, ui in ipairs(sortedPlayers) do
        if math.mod(i - 1, VISUAL_GROUP_SIZE) == 0 then
            column = {}
            table.insert(visualGroups, column)
        end

        table.insert(column, ui)
    end

    return visualGroups
end

-- Force vertical columns of five for raid player frames.
-- Restore profile values afterwards to avoid changing shared profiles.
local OriginalUpdateUIPositions = GROUP.UpdateUIPositions

function GROUP:UpdateUIPositions()
    if not IsRaidGroup(self) then
        return OriginalUpdateUIPositions(self)
    end

    local profile = self:GetProfile()

    local oldOrientation = profile.Orientation
    local oldMaxUnits = profile.MaxUnitsInAxis

    profile.Orientation = "Vertical"
    profile.MaxUnitsInAxis = VISUAL_GROUP_SIZE

    local ok, err = pcall(OriginalUpdateUIPositions, self)

    profile.Orientation = oldOrientation
    profile.MaxUnitsInAxis = oldMaxUnits

    if not ok then
        error(err)
    end
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
        -- Include any new participants before searching positions.
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

-- Non-interactive label following the mouse cursor.
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

    -- Cancel if the frame disappears or its unit ID changes owner.
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

    -- Dropping outside a player frame cancels the operation.
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

            -- Keep the overlay above aura buttons.
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

-- Attach overlays after normal frame initialization.
local OriginalInitialize = UF.Initialize

function UF:Initialize()
    OriginalInitialize(self)
    InstallOverlay(self)
end

-- Alt is reserved for rearranging raid player frames.
-- This also guards against a click before the next OnUpdate.
local OriginalUnitFrameOnClick = PT.UnitFrame_OnClick

function PT.UnitFrame_OnClick(button, unit, ui)
    if ui and IsRaidGroup(ui.owningGroup) then
        if IsAltKeyDown() or active or drag then
            return
        end
    end

    return OriginalUnitFrameOnClick(button, unit, ui)
end

-- Track Alt without requiring a command.
local watcher = CreateFrame("Frame")

watcher:SetScript("OnUpdate", function()
    local altDown = IsAltKeyDown() and true or false

    -- Keep the overlay active if Alt is released before the mouse.
    local shouldEnable = altDown or drag ~= nil

    SetActive(shouldEnable)

    if drag then
        UpdateGhost()
    end
end)

-- Cancel unfinished dragging when unit IDs may change.
-- Do NOT clear the manual order on every roster or zoning event.
watcher:RegisterEvent("RAID_ROSTER_UPDATE")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")

watcher:SetScript("OnEvent", function()
    CancelDrag()
end)

local function UpdateRaidLayouts()
    for _, group in pairs(PT.UnitFrameGroups) do
        if IsRaidGroup(group) then
            group:UpdateUIPositions()
        end
    end
end

-- Optional manual reset command.
SLASH_PTRAIDRESET1 = "/ptraidreset"

SlashCmdList["PTRAIDRESET"] = function()
    CancelDrag()
    ClearSavedOrder()
    UpdateRaidLayouts()

    Message("Manual raid order reset.")
end

-- Automatic reset once per UI session:
-- login or /reload, but not subsequent zoning.
local resetFrame = CreateFrame("Frame")
resetFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

resetFrame:SetScript("OnEvent", function()
    resetFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")

    CancelDrag()
    ClearSavedOrder()

    -- Wait until the world-entry handlers have finished.
    resetFrame:SetScript("OnUpdate", function()
        resetFrame:SetScript("OnUpdate", nil)
        UpdateRaidLayouts()
    end)
end)
