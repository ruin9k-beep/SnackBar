-- SnackBar for WoW 1.12 (Octo / Turtle WoW). Written for Lua 5.0.
--
-- AUTO BUTTON: eats the "best" food/drink in your bags.
--   * Only items that restore health and/or mana (must say "remain seated")
--   * Skips anything that grants a stat buff (Well Fed, "you will gain", etc.)
--   * Conjured items are always preferred
--   * Within each of those groups, foods that restore a % of health/mana
--     rank above foods that restore a flat amount
--   * Among the rest, picks whatever restores the most of what you're missing,
--     and on a tie uses the cheaper/smaller item so you don't waste good food.
--
-- CUSTOM BUTTONS: you make as many as 6 in /sb > Custom Buttons. Each one has
--   a list of item names in the order you want them used. The button uses the
--   first listed item that is in your bags; the rest go in its flyout.
--
-- Left or right click = use.  Shift+drag = move.
-- Hover the little arrow above a button for its flyout.
-- /sb            open options
-- /sb custom     open the custom button editor
-- /sb eat        eat the currently prioritized food
-- /sb rescan     recheck your bags
-- /sb reset      reset all button positions

local PREFIX = "|cffffcc00SnackBar:|r "

local function Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

local DEFAULT_SCALE = 1
local DEFAULT_LOCK = 2.0
local SCALE_MIN, SCALE_MAX = 0.5, 3.0
local LOCK_MIN, LOCK_MAX = 0, 30
local FOOD_ICON = "Interface\\Icons\\INV_Misc_Food_15"
local LIST_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local MAX_FLYOUT = 12     -- most items shown in a flyout
local MAX_CUSTOM = 6      -- most custom buttons
local MAX_LIST = 12       -- most items on one custom list
local FLY_SIZE = 32
local FLY_PAD = 5

BINDING_HEADER_SNACKBAR = "SnackBar"
BINDING_NAME_SNACKBAR_EAT = "Eat best food/drink"
for i = 1, MAX_CUSTOM do
    setglobal("BINDING_NAME_SNACKBAR_CUSTOM" .. i, "Use custom button " .. i)
end

local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local DIALOG_BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

----------------------------------------------------------------------
-- Shared state
----------------------------------------------------------------------

local dirty = true            -- bags need rescanning
local combatFlag = false
local retries = 0             -- retries after unready tooltips
local recheckAt               -- GetTime() at which to rescan again (or nil)
local loginChecked = false
local loginCheckAt            -- one-time forced rescan a few seconds after login
local scanIncomplete = false  -- a tooltip wasn't ready during a scan
local cache = {}              -- itemId -> info table, or false if not usable food

local allUnits = {}           -- every button (auto first, then custom slots)
local mainUnit
local customUnits = {}
local customFrame             -- custom button editor window
local RefreshCustomWindow     -- assigned below
local Refresh                 -- assigned below
local RefreshKeyLabels        -- assigned below

local function Trim(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function IsDead()
    return UnitIsDeadOrGhost("player") and true or false
end

local function InCombat()
    if UnitAffectingCombat("player") then return true end
    return combatFlag
end

----------------------------------------------------------------------
-- Tooltip scanning (used by the auto button to recognise food)
----------------------------------------------------------------------

local tip = CreateFrame("GameTooltip", "SnackBarScanTip", nil, "GameTooltipTemplate")

local function Num(s)
    if not s then return 0 end
    return tonumber((string.gsub(s, ",", ""))) or 0
end

local function ScanItem(bag, slot)
    tip:ClearLines()
    tip:SetOwner(WorldFrame, "ANCHOR_NONE")
    tip:SetBagItem(bag, slot)

    -- If the tooltip hasn't filled in yet (common right after login), say so
    -- instead of caching a false "not food" answer.
    local nameLine = getglobal("SnackBarScanTipTextLeft1")
    local nameText = nameLine and nameLine:GetText()
    if not nameText or nameText == "" then return nil end

    local info = { health = 0, mana = 0, hpct = 0, mpct = 0,
                   conjured = false, level = 0 }
    local seated, buff = false, false

    for i = 1, tip:NumLines() do
        local fs = getglobal("SnackBarScanTipTextLeft" .. i)
        local text = fs and fs:GetText()
        if text then
            local l = string.lower(text)

            if i == 1 and string.find(l, "^conjured") then info.conjured = true end
            if l == "conjured item" then info.conjured = true end

            local _, _, lvl = string.find(l, "requires level (%d+)")
            if lvl then info.level = tonumber(lvl) end

            if string.find(l, "well fed") then buff = true end

            if string.find(l, "^use:") then
                if string.find(l, "remain seated") then seated = true end

                if string.find(l, "restores") or string.find(l, "regenerat") then
                    -- Flat amounts: "Restores 835 health", "835 mana"
                    local _, _, h = string.find(l, "restores ([%d,]+) health")
                    local _, _, m = string.find(l, "([%d,]+) mana")
                    info.health = Num(h)
                    info.mana = Num(m)

                    -- Percent amounts: "5% of your maximum health and mana",
                    -- "2% health and 3% mana", etc. Takes the nearest number%
                    -- before each of the words "health" / "mana".
                    local _, _, hp = string.find(l, "([%d%.]+)%%[^%d]-health")
                    local _, _, mp = string.find(l, "([%d%.]+)%%[^%d]-mana")
                    info.hpct = tonumber(hp) or 0
                    info.mpct = tonumber(mp) or 0
                end

                -- Anything that grants a timed stat bonus is out.
                if string.find(l, "you will gain")
                    or string.find(l, "increases")
                    or string.find(l, "for %d+ min")
                    or string.find(l, "for %d+ hour") then
                    buff = true
                end
            end
        end
    end

    if (not seated) or buff
        or (info.health == 0 and info.mana == 0 and info.hpct == 0 and info.mpct == 0) then
        return false
    end
    return info
end

local function GetInfo(bag, slot, itemId)
    local c = cache[itemId]
    if c == nil then
        c = ScanItem(bag, slot)
        if c == nil then
            scanIncomplete = true      -- not ready: try again later, don't cache
        else
            cache[itemId] = c
        end
    end
    return c
end

----------------------------------------------------------------------
-- Looking at your bags
----------------------------------------------------------------------

local anyCooldown = false   -- some bag item had a real cooldown at the last scan
local anyGcd = false        -- some bag item was on the global cooldown

-- Returns (cooldownLeft, gcdLeft) in seconds for the item in a bag slot.
-- A cooldown of 1.5s or less is the global cooldown: it greys the button for
-- a moment and blocks clicks, but it does NOT make the button advance to the
-- next item, because it is over almost immediately.
local function CooldownLeft(bag, slot)
    local start, duration = GetContainerItemCooldown(bag, slot)
    if start and duration and start > 0 and duration > 0 then
        local left = start + duration - GetTime()
        if left > 0.05 then
            if duration > 1.5 then
                anyCooldown = true
                return left, 0
            end
            anyGcd = true
            return 0, left
        end
    end
    return 0, 0
end

-- One entry per distinct item. byName is keyed by lower-case item name.
local function BuildInventory()
    anyCooldown = false
    anyGcd = false
    local items, byName, byId = {}, {}, {}
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, _, id = string.find(link, "item:(%d+)")
                local _, _, name = string.find(link, "%[(.+)%]")
                id = id and tonumber(id)
                if id then
                    local texture, count = GetContainerItemInfo(bag, slot)
                    count = count or 1
                    local e = byId[id]
                    if e then
                        e.count = e.count + count
                    else
                        local cdl, gcdl = CooldownLeft(bag, slot)
                        e = { bag = bag, slot = slot, id = id, name = name,
                              texture = texture, count = count,
                              cd = cdl, gcd = gcdl }
                        byId[id] = e
                        table.insert(items, e)
                        if name then byName[string.lower(name)] = e end
                    end
                end
            end
        end
    end
    return { items = items, byName = byName }
end

----------------------------------------------------------------------
-- Choosing the food (auto button)
----------------------------------------------------------------------

local function Better(a, b)
    if not b then return true end
    if a.tier ~= b.tier then return a.tier > b.tier end
    if a.eff ~= b.eff then return a.eff > b.eff end
    return a.raw < b.raw
end

-- hypothetical = true pretends you are empty (used to order things and show
-- an icon when you are already full).
local function GetDeficits(hypothetical)
    local hdef, mdef
    if hypothetical then
        hdef = UnitHealthMax("player")
        mdef = 0
        if UnitPowerType("player") == 0 then mdef = UnitManaMax("player") end
    else
        hdef = UnitHealthMax("player") - UnitHealth("player")
        mdef = 0
        if UnitPowerType("player") == 0 then
            mdef = UnitManaMax("player") - UnitMana("player")
        end
    end
    return hdef, mdef
end

-- Every valid food in the bags, each with a score.
local function GatherFood(items, hdef, mdef)
    local plevel = UnitLevel("player")
    local list = {}

    for i = 1, table.getn(items) do
        local e = items[i]
        local info = GetInfo(e.bag, e.slot, e.id)
        if info and info.level <= plevel then
            -- Percent restores become absolute values using your max.
            local h = info.health + info.hpct / 100 * UnitHealthMax("player")
            local m = info.mana + info.mpct / 100 * UnitManaMax("player")
            if mdef <= 0 then m = 0 end
            local eff = math.min(h, hdef) + math.min(m, mdef)
            local isPct = (info.hpct > 0 or info.mpct > 0)
            table.insert(list, {
                bag = e.bag, slot = e.slot, id = e.id,
                texture = e.texture, count = e.count, info = info,
                cd = e.cd, gcd = e.gcd,
                score = {
                    -- conjured beats everything; % food beats flat food
                    tier = (info.conjured and 2 or 0) + (isPct and 1 or 0),
                    eff = eff,
                    raw = h + m,
                },
            })
        end
    end
    return list
end

-- Best food that is off cooldown; only if every candidate is on cooldown do
-- we fall back to the best of those.
local function PickBest(list)
    local best, bestWaiting
    for i = 1, table.getn(list) do
        local c = list[i]
        if c.score.eff > 0 then
            if (c.cd or 0) > 0 then
                if not bestWaiting or Better(c.score, bestWaiting.score) then
                    bestWaiting = c
                end
            elseif not best or Better(c.score, best.score) then
                best = c
            end
        end
    end
    return best or bestWaiting
end

-- Returns: current (what a click eats now, or nil),
--          shown   (what the icon displays; may be hypothetical when full),
--          others  (every other valid food, best first)
local function ScanAuto(inv)
    local list = GatherFood(inv.items, GetDeficits(false))
    local best = PickBest(list)
    local hypothetical = false

    if not best then
        list = GatherFood(inv.items, GetDeficits(true))
        best = PickBest(list)
        hypothetical = true
    end

    local others = {}
    for i = 1, table.getn(list) do
        if list[i] ~= best then table.insert(others, list[i]) end
    end
    table.sort(others, function(a, b) return Better(a.score, b.score) end)

    local cur = nil
    if not hypothetical then cur = best end
    return cur, best, others
end

-- Custom buttons: the listed items that are in your bags, in list order.
-- Buffs on you, by lower-case name (cached until the auras change).
local buffCache
local function PlayerBuffs()
    if buffCache then return buffCache end
    local set = {}
    for i = 0, 31 do
        local idx = GetPlayerBuff(i, "HELPFUL")
        if not idx or idx < 0 then break end
        tip:ClearLines()
        tip:SetOwner(WorldFrame, "ANCHOR_NONE")
        tip:SetPlayerBuff(idx)
        local fs = getglobal("SnackBarScanTipTextLeft1")
        local t = fs and fs:GetText()
        if t and t ~= "" then set[string.lower(t)] = true end
    end
    buffCache = set
    return set
end

-- Which buff does an item give? The first time a custom button uses it we
-- note your buffs, then see which new ones show up and save them in
-- SnackBarDB.itemBuffs[item name].
local pendingLearn

-- The eating/drinking buffs that food gives while you sit are never counted:
-- they only restore health/mana and say nothing about a consumable's effect.
local RESTORE_BUFFS = {
    ["food"] = true, ["drink"] = true, ["eating"] = true,
    ["drinking"] = true, ["refreshment"] = true,
}

local function StartLearn(name)
    if not name then return end
    buffCache = nil
    local now = GetTime()
    pendingLearn = { name = string.lower(name), before = PlayerBuffs(), t0 = now, check = now + 0.4 }
end

local function ServiceLearn(now)
    local p = pendingLearn
    if not p or now < p.check then return end
    buffCache = nil
    local found = {}
    for k in pairs(PlayerBuffs()) do
        if not p.before[k] and not RESTORE_BUFFS[k] then table.insert(found, k) end
    end
    if table.getn(found) > 0 then
        if not SnackBarDB.itemBuffs then SnackBarDB.itemBuffs = {} end
        SnackBarDB.itemBuffs[p.name] = found
        pendingLearn = nil
    elseif now - p.t0 > 3 then
        pendingLearn = nil      -- no buff appeared (instant item, or already buffed)
    else
        p.check = now + 0.5
    end
end

-- True if you already have every buff this item is known to give.
local function ItemBuffed(name)
    local saved = SnackBarDB and SnackBarDB.itemBuffs and SnackBarDB.itemBuffs[string.lower(name)]
    if not saved then return false end
    local have = PlayerBuffs()
    local counted = 0
    for i = 1, table.getn(saved) do
        if not RESTORE_BUFFS[saved[i]] then
            counted = counted + 1
            if not have[saved[i]] then return false end
        end
    end
    return counted > 0
end

-- Items that aren't in your bags are skipped, and items on cooldown move to
-- the back, so the button always advances to the next usable item in the list.
-- If every listed item is on cooldown, the first one stays on the button.
local function ScanList(cfg, inv)
    local ready, waiting = {}, {}
    local blocked = 0
    for i = 1, table.getn(cfg.items) do
        local e = inv.byName[string.lower(cfg.items[i])]
        if e and cfg.noRebuff and ItemBuffed(cfg.items[i]) then
            blocked = blocked + 1      -- its buff is already on you
        elseif e then
            if (e.cd or 0) > 0 then
                table.insert(waiting, e)
            else
                table.insert(ready, e)
            end
        end
    end
    local ordered = {}
    for i = 1, table.getn(ready) do table.insert(ordered, ready[i]) end
    for i = 1, table.getn(waiting) do table.insert(ordered, waiting[i]) end

    local rest = {}
    for i = 2, table.getn(ordered) do
        table.insert(rest, ordered[i])
    end
    return ordered[1], ordered[1], rest, blocked
end

----------------------------------------------------------------------
-- Visuals shared by every button
----------------------------------------------------------------------

-- "Food" buttons obey the eating rules: no use in combat, shared eat lock,
-- red grey-out in combat. Custom buttons can opt out (potions, bandages...).
-- Per-bar "never use in combat" / "never use out of combat" switches.
-- Returns "combat" or "ooc" when this unit is switched off right now.
local function Restriction(u)
    local c = u.cfg
    local noC, noO
    if c then
        noC, noO = c.noCombat, c.noOoc
    elseif SnackBarDB then
        noC, noO = SnackBarDB.autoNoCombat, SnackBarDB.autoNoOoc
    end
    if InCombat() then
        if noC then return "combat" end
    elseif noO then
        return "ooc"
    end
    return nil
end

local function UnitState(u)
    if IsDead() then return "dead" end
    local r = Restriction(u)
    if r == "combat" then return "combat" end
    if r == "ooc" then return "locked" end
    if u.food then
        if InCombat() then return "combat" end
        if GetTime() < u.lockUntil then return "locked" end
    end
    return "normal"
end

-- state: "normal" | "dim" | "locked" | "combat"
-- combat = grey with a reddish tint, locked = plain grey, dim = already full.
local function PaintIcon(tex, state)
    if state == "combat" then
        if tex.SetDesaturated then tex:SetDesaturated(1) end
        tex:SetVertexColor(0.9, 0.35, 0.35)
    elseif state == "locked" or state == "dead" then
        if tex.SetDesaturated then tex:SetDesaturated(1) end
        tex:SetVertexColor(0.45, 0.45, 0.45)
    elseif state == "dim" then
        if tex.SetDesaturated then tex:SetDesaturated(nil) end
        tex:SetVertexColor(0.5, 0.5, 0.5)
    else
        if tex.SetDesaturated then tex:SetDesaturated(nil) end
        tex:SetVertexColor(1, 1, 1)
    end
end

local function TintFlyout(u, state)
    for i = 1, table.getn(u.flyItems) do
        local b = u.flyItems[i]
        if b:IsShown() then
            if state == "normal" and b.entry
                and ((b.entry.cd or 0) > 0 or (b.entry.gcd or 0) > 0) then
                PaintIcon(b.icon, "locked")      -- on cooldown or GCD: grey
            else
                PaintIcon(b.icon, state)
            end
        end
    end
end

-- Flyout direction. "arrow" = which side of the button the arrow sits on
-- (and points), "grow" = which way the list of items extends from it.
-- A list can't grow back over its own button, so that case grows outward.
local DIRS = { "up", "right", "down", "left" }
local DIR_NAME = { up = "Up", right = "Right", down = "Down", left = "Left" }
local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }
local ARROW_GLYPH = { up = "^", down = "v", left = "<", right = ">" }

-- Where the flyout frame attaches to the arrow: [arrow side][grow dir].
local FLY_ANCHOR = {
    up    = { right = { "BOTTOMLEFT", "TOPLEFT" },  left = { "BOTTOMRIGHT", "TOPRIGHT" }, up = { "BOTTOM", "TOP" } },
    down  = { right = { "TOPLEFT", "BOTTOMLEFT" },  left = { "TOPRIGHT", "BOTTOMRIGHT" }, down = { "TOP", "BOTTOM" } },
    right = { down = { "TOPLEFT", "TOPRIGHT" },     up = { "BOTTOMLEFT", "BOTTOMRIGHT" }, right = { "LEFT", "RIGHT" } },
    left  = { down = { "TOPRIGHT", "TOPLEFT" },     up = { "BOTTOMRIGHT", "BOTTOMLEFT" }, left = { "RIGHT", "LEFT" } },
}

local function ResolveDirs(a, g)
    a = a or "up"
    g = g or "right"
    if g == OPPOSITE[a] then g = a end
    return a, g
end

-- The auto button stores its settings on SnackBarDB, custom buttons on cfg.
local function FlyDirs(u)
    local a, g
    if u.cfg then
        a, g = u.cfg.arrow, u.cfg.grow
    elseif SnackBarDB then
        a, g = SnackBarDB.autoArrow, SnackBarDB.autoGrow
    end
    return ResolveDirs(a, g)
end

-- Put the arrow and the flyout frame where the directions say.
local function PlaceFlyout(u)
    local a, g = FlyDirs(u)
    local key = a .. g
    if u.dirKey == key then return end
    u.dirKey = key

    local fb = u.flyBtn
    fb:ClearAllPoints()
    if a == "up" or a == "down" then
        fb:SetWidth(40)
        fb:SetHeight(14)
    else
        fb:SetWidth(14)
        fb:SetHeight(40)
    end
    if a == "up" then fb:SetPoint("BOTTOM", u.btn, "TOP", 0, 0)
    elseif a == "down" then fb:SetPoint("TOP", u.btn, "BOTTOM", 0, 0)
    elseif a == "left" then fb:SetPoint("RIGHT", u.btn, "LEFT", 0, 0)
    else fb:SetPoint("LEFT", u.btn, "RIGHT", 0, 0) end
    u.arrowText:SetText(ARROW_GLYPH[a])

    local anchor = FLY_ANCHOR[a][g]
    u.flyout:ClearAllPoints()
    u.flyout:SetPoint(anchor[1], fb, anchor[2], 0, 0)
end

-- The arrow is shown whenever flyouts are on (even with nothing to list, so
-- clicking it can always recheck the bags) and, optionally, not in combat.
local function UpdateFlyoutButton(u)
    PlaceFlyout(u)
    local show = u.active and SnackBarDB and SnackBarDB.showFlyout
    if show and u.food and SnackBarDB.hideFlyoutCombat and InCombat() then
        show = false
    end
    if show then
        u.flyBtn:Show()
    else
        u.flyBtn:Hide()
        u.flyout:Hide()
    end
end

-- Short text for a button's keybind, e.g. "SHIFT-F5" -> "S-F5".
local KEY_SHORT = {
    PAGEUP = "PgU", PAGEDOWN = "PgD", SPACE = "Spc", BACKSPACE = "Bsp",
    DELETE = "Del", INSERT = "Ins", MOUSEWHEELUP = "MwU", MOUSEWHEELDOWN = "MwD",
}

local function KeyLabel(u)
    if not u.action then return "" end
    local k = GetBindingKey(u.action)
    if not k then return "" end

    local mods, rest = "", k
    while true do
        local _, e, m = string.find(rest, "^(%u+)%-")
        if not (m == "SHIFT" or m == "CTRL" or m == "ALT") then break end
        mods = mods .. string.sub(m, 1, 1) .. "-"
        rest = string.sub(rest, e + 1)
    end

    local base = KEY_SHORT[rest]
    if not base then
        base = string.gsub(rest, "^NUMPAD", "N")
        base = string.gsub(base, "^BUTTON", "M")
    end
    return mods .. base
end

local function ApplyVisual(u)
    if not u.active then return end
    local state = UnitState(u)

    if u.shown then
        u.icon:SetTexture(u.shown.texture)
        u.countText:SetText(u.shown.count)
    else
        u.icon:SetTexture(u.fallback)
        u.countText:SetText("")
    end

    if state ~= "normal" then
        PaintIcon(u.icon, state)
    elseif not u.shown then
        if u.kind == "list" then
            -- empty custom list: keep it clearly visible so it can be found
            PaintIcon(u.icon, "dim")
            u.countText:SetText("+")
        else
            PaintIcon(u.icon, "locked")  -- nothing to eat at all: grey
        end
    elseif u.kind == "auto" and not u.current then
        PaintIcon(u.icon, "dim")         -- already full
    else
        PaintIcon(u.icon, "normal")
    end

    if not (u.food and GetTime() < u.lockUntil) then u.lockText:SetText("") end

    -- Item on cooldown (every candidate was): grey it and count down.
    if state == "normal" and u.shown and (u.shown.cd or 0) > 0 then
        PaintIcon(u.icon, "locked")
        u.lockText:SetText(string.format("%d", math.ceil(u.shown.cd)))
    elseif state == "normal" and u.shown and (u.shown.gcd or 0) > 0 then
        PaintIcon(u.icon, "locked")      -- global cooldown: grey, no number
    end

    u.keyText:SetText(KeyLabel(u))
    TintFlyout(u, state)
    UpdateFlyoutButton(u)
end

----------------------------------------------------------------------
-- Using items (button, flyout, keybind and /sb eat all go through here)
----------------------------------------------------------------------

-- Returns true if this button may use an item right now. Says why if not.
local function CanUse(u)
    if IsDead() then
        Say("You can't use that while dead.")
        return false
    end
    local r = Restriction(u)
    if r then
        local label = (u.cfg and u.cfg.name) or "Auto button"
        Say("'" .. label .. "' is set not to be used " .. (r == "combat" and "in combat." or "out of combat."))
        return false
    end
    if u.food then
        if InCombat() then
            Say("You can't eat in combat.")
            return false
        end
        -- Still locked from the last time we ate: ignore quietly.
        if GetTime() < u.lockUntil then return false end
    end

    -- UseContainerItem would SELL or bank-move the item with these open.
    if (MerchantFrame and MerchantFrame:IsVisible())
        or (BankFrame and BankFrame:IsVisible()) then
        Say("Close the vendor/bank window first.")
        return false
    end
    return true
end

-- How long this bar locks after eating: its own setting, else the main one.
local function LockSeconds(u)
    return (u.cfg and u.cfg.lock) or (SnackBarDB and SnackBarDB.lock) or DEFAULT_LOCK
end

local function UseEntry(u, entry)
    UseContainerItem(entry.bag, entry.slot)
    if u.cfg then StartLearn(entry.name) end
    if u.food then
        u.lockUntil = GetTime() + LockSeconds(u)
    end
end

local function UnitEat(u)
    if not u.active then return end
    if not CanUse(u) then return end

    Refresh(u)
    if not u.current then
        if u.kind == "auto" then
            local hdef, mdef = GetDeficits(false)
            if hdef <= 0 and mdef <= 0 then
                Say("Health and mana are already full.")
            else
                Say("No suitable food or drink in your bags.")
            end
        else
            if (u.blocked or 0) > 0 then
                Say("You already have the buff from everything available on '" .. ((u.cfg and u.cfg.name) or "that button") .. "'.")
            else
                Say("None of the items on that button's list are in your bags.")
            end
        end
        return
    end
    if (u.current.cd or 0) > 0 then
        local label = (u.cfg and u.cfg.name) or "Auto button"
        Say("Everything on '" .. label .. "' is on cooldown (" .. math.ceil(u.current.cd) .. "s left).")
        return
    end
    if (u.current.gcd or 0) > 0 then return end   -- global cooldown: ignore quietly
    UseEntry(u, u.current)
end

local function EatFlyoutItem(u, entry)
    -- On the global cooldown: ignore the click and leave the flyout open.
    if entry and (entry.gcd or 0) > 0 then return end
    u.flyout:Hide()
    if not entry then return end
    if not CanUse(u) then return end

    -- Make sure the item is still where we think it is.
    local link = GetContainerItemLink(entry.bag, entry.slot)
    local _, _, id = string.find(link or "", "item:(%d+)")
    id = id and tonumber(id)
    if id ~= entry.id then
        Refresh(u)
        Say("That item moved; try again.")
        return
    end
    UseEntry(u, entry)
end

----------------------------------------------------------------------
-- Flyout contents
----------------------------------------------------------------------

local function GetFlyItem(u, i)
    local b = u.flyItems[i]
    if b then return b end

    b = CreateFrame("Button", u.name .. "Fly" .. i, u.flyout)
    b:SetWidth(FLY_SIZE)
    b:SetHeight(FLY_SIZE)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetBackdrop(BACKDROP)
    b:SetBackdropColor(0, 0, 0, 0.8)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 3)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 3)

    b:SetScript("OnClick", function()
        EatFlyoutItem(u, this.entry)   -- left or right click
    end)
    b:SetScript("OnEnter", function()
        if this.entry then
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
            GameTooltip:SetBagItem(this.entry.bag, this.entry.slot)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    u.flyItems[i] = b
    return b
end

local function LayoutFlyout(u)
    PlaceFlyout(u)
    local _, g = FlyDirs(u)
    local step = FLY_SIZE + 2
    local others = u.others
    local n = table.getn(others)
    if n > MAX_FLYOUT then n = MAX_FLYOUT end

    for i = 1, n do
        local b = GetFlyItem(u, i)
        local e = others[i]
        b.entry = e
        b.icon:SetTexture(e.texture)
        b.count:SetText(e.count)
        b:ClearAllPoints()
        local off = FLY_PAD + (i - 1) * step
        if g == "right" then b:SetPoint("LEFT", u.flyout, "LEFT", off, 0)
        elseif g == "left" then b:SetPoint("RIGHT", u.flyout, "RIGHT", -off, 0)
        elseif g == "up" then b:SetPoint("BOTTOM", u.flyout, "BOTTOM", 0, off)
        else b:SetPoint("TOP", u.flyout, "TOP", 0, -off) end
        b:Show()
    end
    for i = n + 1, table.getn(u.flyItems) do
        u.flyItems[i].entry = nil
        u.flyItems[i]:Hide()
    end

    local thick = FLY_SIZE + 2 * FLY_PAD
    if n > 0 then
        u.flyEmpty:Hide()
        local len = 2 * FLY_PAD + n * FLY_SIZE + (n - 1) * 2
        if g == "up" or g == "down" then
            u.flyout:SetWidth(thick)
            u.flyout:SetHeight(len)
        else
            u.flyout:SetWidth(len)
            u.flyout:SetHeight(thick)
        end
    else
        u.flyEmpty:Show()
        u.flyout:SetWidth(110)
        u.flyout:SetHeight(thick)
    end
    TintFlyout(u, UnitState(u))
end

----------------------------------------------------------------------
-- Scanning and refreshing
----------------------------------------------------------------------

function Refresh(u, inv)
    if not u.active then return end
    if not inv then inv = BuildInventory() end

    if u.kind == "auto" then
        u.current, u.shown, u.others = ScanAuto(inv)
        u.blocked = 0
    else
        u.current, u.shown, u.others, u.blocked = ScanList(u.cfg, inv)
    end

    ApplyVisual(u)
    if u.flyout:IsShown() then LayoutFlyout(u) end
end

local function RefreshAll()
    scanIncomplete = false
    local inv = BuildInventory()
    for i = 1, table.getn(allUnits) do
        Refresh(allUnits[i], inv)
    end

    -- Some tooltips weren't ready: look again shortly (a few tries at most).
    if scanIncomplete and retries < 5 then
        retries = retries + 1
        recheckAt = GetTime() + 1
    elseif not scanIncomplete then
        retries = 0
    end

    if customFrame and customFrame:IsShown() then
        RefreshCustomWindow(inv)
    end
end

-- Throw away cached tooltip results and rescan the bags from scratch.
local function ForceRescan()
    cache = {}
    retries = 0
    RefreshAll()
end

local function ShowFlyout(u)
    if not u.flyBtn:IsShown() then return end
    ForceRescan()                              -- fresh list, fresh tooltips
    if not u.flyBtn:IsShown() then return end
    LayoutFlyout(u)
    u.flyout:Show()
end

-- True while the mouse is on this button's arrow, flyout, or anything inside.
local function MouseInFlyout(u)
    local f = GetMouseFocus()
    while f do
        if f == u.flyBtn or f == u.flyout then return true end
        f = f:GetParent()
    end
    return false
end

----------------------------------------------------------------------
-- Position and scale (positions are stored in UIParent units)
----------------------------------------------------------------------

local function PosStore(u)
    if u.cfg then return u.cfg end
    return SnackBarDB
end

local function SavePosition(u)
    local l, b = u.btn:GetLeft(), u.btn:GetBottom()
    local store = PosStore(u)
    if l and b and store then
        local s = u.btn:GetScale()
        store.x = l * s
        store.y = b * s
    end
end

local function ApplyPosition(u)
    local s = u.btn:GetScale()
    local store = PosStore(u)
    u.btn:ClearAllPoints()
    if store and store.x and store.y then
        u.btn:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", store.x / s, store.y / s)
    else
        u.btn:SetPoint("CENTER", UIParent, "CENTER", u.defX / s, u.defY / s)
    end
end

local function ApplyScaleAll(v)
    for i = 1, table.getn(allUnits) do SavePosition(allUnits[i]) end   -- old scale
    for i = 1, table.getn(allUnits) do allUnits[i].btn:SetScale(v) end
    if SnackBarDB then SnackBarDB.scale = v end
    for i = 1, table.getn(allUnits) do ApplyPosition(allUnits[i]) end
end

----------------------------------------------------------------------
-- Building a button ("unit"): main frame + flyout arrow + flyout bar
----------------------------------------------------------------------

local function NewUnit(frameName, fallback, defX, defY)
    local u = {
        name = frameName, fallback = fallback, defX = defX, defY = defY,
        kind = "auto", food = true, active = false,
        others = {}, flyItems = {}, flyIdle = 0, lockUntil = 0,
    }

    local btn = CreateFrame("Button", frameName, UIParent)
    btn:SetWidth(40)
    btn:SetHeight(40)
    btn:SetPoint("CENTER", UIParent, "CENTER", defX, defY)
    btn:SetFrameStrata("MEDIUM")
    btn:SetMovable(true)
    btn:SetClampedToScreen(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetBackdrop(BACKDROP)
    btn:SetBackdropColor(0, 0, 0, 0.8)
    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    u.btn = btn

    u.icon = btn:CreateTexture(nil, "ARTWORK")
    u.icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 4, -4)
    u.icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -4, 4)
    u.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    u.icon:SetTexture(fallback)

    local overlay = CreateFrame("Frame", frameName .. "Overlay", btn)
    overlay:SetAllPoints(btn)
    overlay:SetFrameLevel(btn:GetFrameLevel() + 2)

    u.countText = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    u.countText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -4, 4)

    u.lockText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    u.lockText:SetPoint("CENTER", btn, "CENTER", 0, 0)

    -- Keybind label in the top-left corner (like action bars).
    u.keyText = overlay:CreateFontString(frameName .. "Key", "OVERLAY", "GameFontHighlightSmall")
    u.keyText:SetPoint("TOPLEFT", btn, "TOPLEFT", 4, -4)
    u.keyText:SetJustifyH("LEFT")

    btn:SetScript("OnClick", function()
        UnitEat(u)   -- left or right click
    end)

    btn:SetScript("OnDragStart", function()
        if IsShiftKeyDown() then this:StartMoving() end
    end)
    btn:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        SavePosition(u)
    end)

    btn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        if u.current then
            GameTooltip:SetBagItem(u.current.bag, u.current.slot)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Left or right click to use. Shift+drag to move.", 0.6, 0.6, 0.6)
        elseif u.kind == "list" then
            GameTooltip:SetText((u.cfg and u.cfg.name) or "SnackBar")
            GameTooltip:AddLine("None of the listed items are in your bags.", 1, 1, 1)
            GameTooltip:AddLine("Shift+drag to move. /sb custom to edit.", 0.6, 0.6, 0.6)
        else
            GameTooltip:SetText("SnackBar")
            GameTooltip:AddLine("Nothing to eat right now.", 1, 1, 1)
            GameTooltip:AddLine("Shift+drag to move. /sb for options.", 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Flyout arrow ----------------------------------------------------
    local flyBtn = CreateFrame("Button", frameName .. "Arrow", btn)
    flyBtn:SetWidth(40)
    flyBtn:SetHeight(14)
    flyBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    flyBtn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    flyBtn:SetBackdropColor(0, 0, 0, 0.8)
    flyBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    u.flyBtn = flyBtn

    u.arrowText = flyBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    u.arrowText:SetPoint("CENTER", flyBtn, "CENTER", 0, -1)

    -- Flyout bar ------------------------------------------------------
    local flyout = CreateFrame("Frame", frameName .. "Flyout", btn)
    flyout:SetFrameStrata("HIGH")
    flyout:SetWidth(FLY_SIZE + 2 * FLY_PAD)
    flyout:SetHeight(FLY_SIZE + 2 * FLY_PAD)
    flyout:EnableMouse(true)       -- so the gaps between icons still count as "over"
    flyout:SetBackdrop(BACKDROP)
    flyout:SetBackdropColor(0, 0, 0, 0.85)
    flyout:Hide()
    u.flyout = flyout

    u.flyEmpty = flyout:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    u.flyEmpty:SetPoint("CENTER", flyout, "CENTER", 0, 0)
    u.flyEmpty:SetText("No other items")
    u.flyEmpty:Hide()

    flyBtn:SetScript("OnEnter", function()
        ShowFlyout(u)
    end)
    flyBtn:SetScript("OnClick", function()
        -- Every click rechecks the bags too, and makes sure the flyout is open.
        ForceRescan()
        LayoutFlyout(u)
        flyout:Show()
    end)

    return u
end

-- The auto button, plus a pool of slots for custom buttons.
mainUnit = NewUnit("SnackBarButton", FOOD_ICON, 0, -150)
mainUnit.active = true
mainUnit.action = "SNACKBAR_EAT"
table.insert(allUnits, mainUnit)

for i = 1, MAX_CUSTOM do
    -- Default spots: a row well below the options/editor windows (which cover
    -- the area around screen center), so new buttons and their flyout arrows
    -- are never hidden behind them. Shift+drag to move.
    local u = NewUnit("SnackBarCustom" .. i, LIST_ICON, -140 + 56 * (i - 1), -230)
    u.kind = "list"
    u.action = "SNACKBAR_CUSTOM" .. i
    u.btn:Hide()
    customUnits[i] = u
    table.insert(allUnits, u)
end

-- Update every button's keybind label (call after any binding change).
function RefreshKeyLabels()
    for i = 1, table.getn(allUnits) do
        local u = allUnits[i]
        u.keyText:SetText(KeyLabel(u))
    end
end

----------------------------------------------------------------------
-- Visibility rules
----------------------------------------------------------------------

-- One place decides which buttons are shown: the unit must be active, its own
-- "show" box ticked, and (for food buttons) not hidden by the combat option.
local function ApplyCombatVisibility()
    for i = 1, table.getn(allUnits) do
        local u = allUnits[i]
        local want = u.active
        if want and u.cfg and u.cfg.shown == false then want = false end
        if want and u.food and SnackBarDB and SnackBarDB.hideFrameCombat and InCombat() then
            want = false
        end
        if want then
            if not u.btn:IsShown() then u.btn:Show() end
        else
            u.flyout:Hide()
            if u.btn:IsShown() then u.btn:Hide() end
        end
        UpdateFlyoutButton(u)
    end
end

-- Hook custom slots up to the saved configs.
local function BindCustomUnits()
    local list = (SnackBarDB and SnackBarDB.buttons) or {}
    for i = 1, MAX_CUSTOM do
        local u = customUnits[i]
        local cfg = list[i]
        if cfg then
            u.cfg = cfg
            u.active = true
            u.food = (cfg.food ~= false)
            ApplyPosition(u)
        else
            u.cfg = nil
            u.active = false
            u.current, u.shown, u.others = nil, nil, {}
        end
    end
    ApplyCombatVisibility()
    dirty = true
end

-- Keybind entry points (see Bindings.xml)
function SnackBar_Eat()
    UnitEat(mainUnit)
end

function SnackBar_UseCustom(i)
    local u = customUnits[i]
    if u and u.active then UnitEat(u) end
end

----------------------------------------------------------------------
-- Small UI helpers
----------------------------------------------------------------------

-- Slider + text box pair. Returns slider, box, and a silent setter.
local function MakeSlider(name, parent, label, minV, maxV, step, fmt, y, onChange, x)
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetWidth(180)
    s:SetPoint("TOPLEFT", parent, "TOPLEFT", x or 26, y)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    getglobal(name .. "Low"):SetText(string.format(fmt, minV))
    getglobal(name .. "High"):SetText(string.format(fmt, maxV))
    getglobal(name .. "Text"):SetText(label)

    local box = CreateFrame("EditBox", name .. "Box", parent, "InputBoxTemplate")
    box:SetWidth(50)
    box:SetHeight(20)
    box:SetPoint("LEFT", s, "RIGHT", 18, 0)
    box:SetAutoFocus(false)
    box:SetMaxLetters(6)

    local syncing = false

    local function Snap(v)
        if v < minV then v = minV end
        if v > maxV then v = maxV end
        v = math.floor(v / step + 0.5) * step
        return math.floor(v * 100 + 0.5) / 100
    end

    s:SetValue(minV)

    s:SetScript("OnValueChanged", function()
        local v = Snap(arg1)
        box:SetText(string.format(fmt, v))
        if not syncing then onChange(v) end
    end)

    box:SetScript("OnEnterPressed", function()
        local v = tonumber(box:GetText())
        if v then
            v = Snap(v)
            s:SetValue(v)
            box:SetText(string.format(fmt, v))
        else
            box:SetText(string.format(fmt, Snap(s:GetValue())))
        end
        box:ClearFocus()
    end)

    box:SetScript("OnEscapePressed", function()
        box:SetText(string.format(fmt, Snap(s:GetValue())))
        box:ClearFocus()
    end)

    local function setter(v)
        syncing = true
        s:SetValue(v)
        syncing = false
        box:SetText(string.format(fmt, Snap(v)))
    end

    return s, box, setter
end

local function MakeCheckBox(name, parent, label, x, y, onToggle)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    cb:SetWidth(24)
    cb:SetHeight(24)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    getglobal(name .. "Text"):SetText(label)
    cb:SetScript("OnClick", function()
        onToggle(this:GetChecked() and true or false)
    end)
    return cb
end

local function MakeSmallButton(name, parent, label, w, h)
    local b = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    b:SetWidth(w)
    b:SetHeight(h)
    b:SetText(label)
    return b
end

-- Two cycle buttons for a bar's flyout: arrow side and growth direction.
-- Left-click goes to the next direction, right-click to the previous.
-- get(key)/set(key, dir) read and write "arrow" / "grow". Returns a refresh function.
local function MakeDirButtons(name, parent, x, y, w, get, set)
    local ab = MakeSmallButton(name .. "Arrow", parent, "", w, 22)
    ab:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local gb = MakeSmallButton(name .. "Grow", parent, "", w, 22)
    gb:SetPoint("LEFT", ab, "RIGHT", 8, 0)
    ab:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    gb:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local function current()
        return ResolveDirs(get("arrow"), get("grow"))
    end
    local function refresh()
        local a, g = current()
        ab:SetText("Arrow: " .. DIR_NAME[a])
        gb:SetText("Grows: " .. DIR_NAME[g])
    end
    local function cycle(key, delta)
        local a, g = current()
        local cur = (key == "arrow") and a or g
        local idx = 1
        for i = 1, 4 do if DIRS[i] == cur then idx = i end end
        for _ = 1, 4 do
            idx = idx + delta
            if idx > 4 then idx = 1 end
            if idx < 1 then idx = 4 end
            -- the list can't grow back over its own button
            if key == "arrow" or DIRS[idx] ~= OPPOSITE[a] then break end
        end
        set(key, DIRS[idx])
        refresh()
        RefreshAll()
    end
    ab:SetScript("OnClick", function()
        cycle("arrow", (arg1 == "RightButton") and -1 or 1)
    end)
    gb:SetScript("OnClick", function()
        cycle("grow", (arg1 == "RightButton") and -1 or 1)
    end)
    return refresh
end

local function Trunc(s, n)
    if string.len(s) > n then return string.sub(s, 1, n - 2) .. ".." end
    return s
end

-- Key-capture button for a binding action. getAction() returns the action
-- name to bind (or nil if there is nothing to bind right now).
-- Left-click, then press a key. Right-click clears. Esc cancels.
local function MakeKeyCapture(name, parent, getAction)
    local b = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    b:SetWidth(150)
    b:SetHeight(22)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local capturing = false

    function b.Refresh()
        RefreshKeyLabels()
        if capturing then
            b:SetText("Press a key...")
            return
        end
        local action = getAction()
        local k = action and GetBindingKey(action)
        if k then
            local text = k
            if GetBindingText then text = GetBindingText(k, "KEY_") or k end
            b:SetText(text)
        else
            b:SetText("Not bound")
        end
    end

    function b.Stop()
        capturing = false
        b:EnableKeyboard(false)
        b.Refresh()
    end

    b:SetScript("OnClick", function()
        if capturing then
            b.Stop()
            return
        end
        local action = getAction()
        if not action then return end
        if arg1 == "RightButton" then
            local k1, k2 = GetBindingKey(action)
            if k1 then SetBinding(k1) end
            if k2 then SetBinding(k2) end
            SaveBindings(GetCurrentBindingSet())
            b.Refresh()
        else
            capturing = true
            b:EnableKeyboard(true)
            b.Refresh()
        end
    end)

    b:SetScript("OnKeyDown", function()
        if not capturing then return end
        local key = arg1
        if key == "ESCAPE" then
            b.Stop()
            return
        end
        if key == "SHIFT" or key == "CTRL" or key == "ALT"
            or key == "LSHIFT" or key == "RSHIFT"
            or key == "LCTRL" or key == "RCTRL"
            or key == "LALT" or key == "RALT" then
            return   -- wait for the real key
        end
        local action = getAction()
        if not action then
            b.Stop()
            return
        end
        if IsShiftKeyDown() then key = "SHIFT-" .. key end
        if IsControlKeyDown() then key = "CTRL-" .. key end
        if IsAltKeyDown() then key = "ALT-" .. key end

        local old = GetBindingAction(key)
        if old and old ~= "" and old ~= action then
            Say(key .. " was bound to " .. old .. "; replaced.")
        end

        local k1, k2 = GetBindingKey(action)
        if k1 then SetBinding(k1) end
        if k2 then SetBinding(k2) end
        SetBinding(key, action)
        SaveBindings(GetCurrentBindingSet())
        b.Stop()
    end)

    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Keybind")
        GameTooltip:AddLine("Left-click, then press a key.", 1, 1, 1)
        GameTooltip:AddLine("Esc cancels. Right-click clears.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return b
end

-- Keybinds belong to a button's slot number, so when a button is deleted the
-- keys of the buttons after it move down one slot with them.
local function ShiftBindingsDown(removed, total)
    local k1, k2 = GetBindingKey("SNACKBAR_CUSTOM" .. removed)
    if k1 then SetBinding(k1) end
    if k2 then SetBinding(k2) end
    for j = removed + 1, total do
        local a, b = GetBindingKey("SNACKBAR_CUSTOM" .. j)
        if a then
            SetBinding(a)
            SetBinding(a, "SNACKBAR_CUSTOM" .. (j - 1))
        end
        if b then
            SetBinding(b)
            SetBinding(b, "SNACKBAR_CUSTOM" .. (j - 1))
        end
    end
    SaveBindings(GetCurrentBindingSet())
    RefreshKeyLabels()
end

----------------------------------------------------------------------
-- Custom button editor window
----------------------------------------------------------------------

local cw = { selected = 1, rows = {}, itemRows = {} }

local function Buttons()
    return (SnackBarDB and SnackBarDB.buttons) or {}
end

local function SelectedCfg()
    return Buttons()[cw.selected]
end

function RefreshCustomWindow(inv)
    if not customFrame or not cw.panel then return end
    inv = inv or BuildInventory()

    local buttons = Buttons()
    local n = table.getn(buttons)
    if cw.selected > n then cw.selected = n end
    if cw.selected < 1 and n > 0 then cw.selected = 1 end

    -- Left-hand list of buttons
    for i = 1, MAX_CUSTOM do
        local row = cw.rows[i]
        local cfg = buttons[i]
        if cfg then
            row.text:SetText(Trunc(cfg.name or ("Button " .. i), 16))
            row:Show()
            if i == cw.selected then row.sel:Show() else row.sel:Hide() end
        else
            row:Hide()
        end
    end

    local cfg = buttons[cw.selected]
    if not cfg then
        cw.panel:Hide()
        cw.emptyHint:Show()
        return
    end
    cw.emptyHint:Hide()
    cw.panel:Show()

    cw.nameBox:SetText(cfg.name or "")
    cw.cbShown:SetChecked(cfg.shown ~= false and 1 or nil)
    cw.cbFood:SetChecked(cfg.food ~= false and 1 or nil)
    cw.cbNoCombat:SetChecked(cfg.noCombat and 1 or nil)
    cw.cbNoOoc:SetChecked(cfg.noOoc and 1 or nil)
    cw.cbRebuff:SetChecked(cfg.noRebuff and 1 or nil)
    cw.setLock(cfg.lock or (SnackBarDB and SnackBarDB.lock) or DEFAULT_LOCK)
    cw.refreshDirs()
    if cw.keyBtn then cw.keyBtn.Refresh() end

    -- Item rows: green = in your bags (with count), grey = not in bags
    local m = table.getn(cfg.items)
    for i = 1, MAX_LIST do
        local r = cw.itemRows[i]
        local name = cfg.items[i]
        if name then
            local label = i .. ". " .. Trunc(name, 24)
            local e = inv.byName[string.lower(name)]
            if e then
                r.text:SetText("|cff55ff55" .. label .. " (" .. e.count .. ")|r")
            else
                r.text:SetText("|cff888888" .. label .. "|r")
            end
            if i == 1 then r.up:Disable() else r.up:Enable() end
            if i == m then r.down:Disable() else r.down:Enable() end
            r:Show()
        else
            r:Hide()
        end
    end
end

-- Something about the buttons changed: rebuild everything that depends on it.
local function ConfigChanged()
    if cw.keyBtn then cw.keyBtn.Stop() end    -- cancel any half-finished capture
    BindCustomUnits()
    RefreshAll()
end

local function BuildCustomWindow()
    local RX = 180   -- left edge of the right-hand column

    local f = CreateFrame("Frame", "SnackBarCustomFrame", UIParent)
    f:SetWidth(470)
    f:SetHeight(638)
    -- The options window is 330 wide, centered at x=0. Start this one just to
    -- its right (165 + 10 gap + 235 half-width) with the tops lined up.
    f:SetPoint("CENTER", UIParent, "CENTER", 410, 10)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetBackdrop(DIALOG_BACKDROP)
    f:SetScript("OnMouseDown", function() this:StartMoving() end)
    f:SetScript("OnMouseUp", function() this:StopMovingOrSizing() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("SnackBar Custom Buttons")

    local close = CreateFrame("Button", "SnackBarCustomClose", f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    -- Left column: list of buttons ------------------------------------
    local listLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -52)
    listLabel:SetText("Buttons")

    for i = 1, MAX_CUSTOM do
        local idx = i
        local row = CreateFrame("Button", "SnackBarCustomRow" .. i, f)
        row:SetWidth(136)
        row:SetHeight(22)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -72 - (i - 1) * 24)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints(row)
        row.sel:SetTexture(0.2, 0.4, 0.8, 0.5)
        row.sel:Hide()
        row:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.text:SetWidth(124)
        row.text:SetJustifyH("LEFT")
        row:SetScript("OnClick", function()
            cw.selected = idx
            if cw.keyBtn then cw.keyBtn.Stop() end
            RefreshCustomWindow()
        end)
        cw.rows[i] = row
    end

    local newBtn = MakeSmallButton("SnackBarCustomNew", f, "New", 64, 22)
    newBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -224)
    newBtn:SetScript("OnClick", function()
        local buttons = Buttons()
        if table.getn(buttons) >= MAX_CUSTOM then
            Say("You can have at most " .. MAX_CUSTOM .. " custom buttons.")
            return
        end
        table.insert(buttons, {
            name = "Button " .. (table.getn(buttons) + 1),
            items = {}, food = true, shown = true,
        })
        cw.selected = table.getn(buttons)
        ConfigChanged()
        Say("Created '" .. buttons[cw.selected].name .. "'. Look for the \"?\" button below the options window; Shift+drag to move it.")
    end)

    local delBtn = MakeSmallButton("SnackBarCustomDelete", f, "Delete", 64, 22)
    delBtn:SetPoint("LEFT", newBtn, "RIGHT", 8, 0)
    delBtn:SetScript("OnClick", function()
        local buttons = Buttons()
        if buttons[cw.selected] then
            local removed, total = cw.selected, table.getn(buttons)
            table.remove(buttons, removed)
            ShiftBindingsDown(removed, total)
            ConfigChanged()
        end
    end)

    local leftHint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    leftHint:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -256)
    leftHint:SetWidth(136)
    leftHint:SetJustifyH("LEFT")
    leftHint:SetText("Up to " .. MAX_CUSTOM .. " buttons. Shift+drag a button on screen to move it.")

    cw.emptyHint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cw.emptyHint:SetPoint("TOPLEFT", f, "TOPLEFT", RX + 6, -90)
    cw.emptyHint:SetText("Click New to make a custom button.")

    -- Right column: everything for the selected button ----------------
    local panel = CreateFrame("Frame", "SnackBarCustomPanel", f)
    panel:SetAllPoints(f)
    cw.panel = panel

    local nameLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", RX, -52)
    nameLabel:SetText("Name:")

    local nameBox = CreateFrame("EditBox", "SnackBarCustomName", panel, "InputBoxTemplate")
    nameBox:SetWidth(170)
    nameBox:SetHeight(20)
    nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 12, 0)
    nameBox:SetAutoFocus(false)
    nameBox:SetMaxLetters(20)
    cw.nameBox = nameBox

    local function CommitName()
        local cfg = SelectedCfg()
        if not cfg then return end
        local t = Trim(nameBox:GetText() or "")
        if t ~= "" then cfg.name = t end
        RefreshCustomWindow()
    end
    nameBox:SetScript("OnEnterPressed", function()
        CommitName()
        nameBox:ClearFocus()
    end)
    nameBox:SetScript("OnEditFocusLost", function()
        CommitName()
    end)
    nameBox:SetScript("OnEscapePressed", function()
        local cfg = SelectedCfg()
        nameBox:SetText((cfg and cfg.name) or "")
        nameBox:ClearFocus()
    end)

    cw.cbShown = MakeCheckBox("SnackBarCustomShown", panel, "Show this button",
        RX - 4, -74, function(on)
            local cfg = SelectedCfg()
            if cfg then cfg.shown = on end
            ApplyCombatVisibility()
        end)

    cw.cbFood = MakeCheckBox("SnackBarCustomFood", panel, "Food (eat lock, not in combat)",
        RX - 4, -98, function(on)
            local cfg = SelectedCfg()
            if cfg then cfg.food = on end
            ConfigChanged()
        end)

    cw.cbNoCombat = MakeCheckBox("SnackBarCustomNoCombat", panel, "Don't use in combat",
        RX - 4, -122, function(on)
            local cfg = SelectedCfg()
            if cfg then cfg.noCombat = on and true or nil end
            RefreshAll()
        end)

    cw.cbNoOoc = MakeCheckBox("SnackBarCustomNoOoc", panel, "Don't use out of combat",
        RX - 4, -146, function(on)
            local cfg = SelectedCfg()
            if cfg then cfg.noOoc = on and true or nil end
            RefreshAll()
        end)

    cw.cbRebuff = MakeCheckBox("SnackBarCustomRebuff", panel, "Skip items whose buff is already on me",
        RX - 4, -170, function(on)
            local cfg = SelectedCfg()
            if cfg then cfg.noRebuff = on and true or nil end
            RefreshAll()
        end)
    local rebuffHint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rebuffHint:SetPoint("TOPLEFT", panel, "TOPLEFT", RX + 22, -196)
    rebuffHint:SetText("Learns each item's buff the first time you use it.")

    local _, _, setBarLock = MakeSlider("SnackBarCustomLock", panel,
        "Lock after eating (sec)", LOCK_MIN, LOCK_MAX, 0.1, "%.1f", -224,
        function(v)
            local cfg = SelectedCfg()
            if cfg then cfg.lock = v end
        end, RX)
    cw.setLock = setBarLock

    cw.refreshDirs = MakeDirButtons("SnackBarCustomDir", panel, RX, -260, 128,
        function(key)
            local cfg = SelectedCfg()
            return cfg and cfg[key]
        end,
        function(key, dir)
            local cfg = SelectedCfg()
            if cfg then cfg[key] = dir end
        end)

    -- Keybind for the selected button ----------------------------------
    local keyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    keyLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", RX, -292)
    keyLabel:SetText("Keybind:")

    cw.keyBtn = MakeKeyCapture("SnackBarCustomKeyButton", panel, function()
        if SelectedCfg() then return "SNACKBAR_CUSTOM" .. cw.selected end
        return nil
    end)
    cw.keyBtn:SetPoint("LEFT", keyLabel, "RIGHT", 12, 0)

    local itemsLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemsLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", RX, -322)
    itemsLabel:SetText("Items (top is used first):")

    for i = 1, MAX_LIST do
        local idx = i
        local r = CreateFrame("Frame", "SnackBarCustomItem" .. i, panel)
        r:SetWidth(250)
        r:SetHeight(20)
        r:SetPoint("TOPLEFT", panel, "TOPLEFT", RX, -340 - (i - 1) * 20)

        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", r, "LEFT", 0, 0)
        r.text:SetWidth(178)
        r.text:SetJustifyH("LEFT")

        r.up = MakeSmallButton("SnackBarCustomItem" .. i .. "Up", r, "^", 20, 18)
        r.up:SetPoint("LEFT", r, "LEFT", 182, 0)
        r.up:SetScript("OnClick", function()
            local cfg = SelectedCfg()
            if cfg and cfg.items[idx] and cfg.items[idx - 1] then
                local t = cfg.items[idx - 1]
                cfg.items[idx - 1] = cfg.items[idx]
                cfg.items[idx] = t
                RefreshAll()
            end
        end)

        r.down = MakeSmallButton("SnackBarCustomItem" .. i .. "Down", r, "v", 20, 18)
        r.down:SetPoint("LEFT", r, "LEFT", 204, 0)
        r.down:SetScript("OnClick", function()
            local cfg = SelectedCfg()
            if cfg and cfg.items[idx] and cfg.items[idx + 1] then
                local t = cfg.items[idx + 1]
                cfg.items[idx + 1] = cfg.items[idx]
                cfg.items[idx] = t
                RefreshAll()
            end
        end)

        r.del = MakeSmallButton("SnackBarCustomItem" .. i .. "Del", r, "x", 20, 18)
        r.del:SetPoint("LEFT", r, "LEFT", 226, 0)
        r.del:SetScript("OnClick", function()
            local cfg = SelectedCfg()
            if cfg and cfg.items[idx] then
                table.remove(cfg.items, idx)
                RefreshAll()
            end
        end)

        cw.itemRows[i] = r
    end

    local addLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    addLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", RX, -588)
    addLabel:SetText("Add item by name:")

    local addBox = CreateFrame("EditBox", "SnackBarCustomAdd", panel, "InputBoxTemplate")
    addBox:SetWidth(180)
    addBox:SetHeight(20)
    addBox:SetPoint("TOPLEFT", panel, "TOPLEFT", RX + 6, -604)
    addBox:SetAutoFocus(false)
    addBox:SetMaxLetters(64)

    local function DoAdd()
        local cfg = SelectedCfg()
        if not cfg then return end
        local text = addBox:GetText() or ""
        local _, _, linkName = string.find(text, "%[(.-)%]")   -- accept [Item Name]
        if linkName then text = linkName end
        text = Trim(text)
        if text == "" then return end
        if table.getn(cfg.items) >= MAX_LIST then
            Say("A list holds at most " .. MAX_LIST .. " items.")
            return
        end
        local lower = string.lower(text)
        for i = 1, table.getn(cfg.items) do
            if string.lower(cfg.items[i]) == lower then
                Say(text .. " is already on that list.")
                return
            end
        end
        table.insert(cfg.items, text)
        addBox:SetText("")
        RefreshAll()
    end

    addBox:SetScript("OnEnterPressed", function() DoAdd() end)
    addBox:SetScript("OnEscapePressed", function()
        addBox:SetText("")
        addBox:ClearFocus()
    end)

    local addBtn = MakeSmallButton("SnackBarCustomAddButton", panel, "Add", 60, 22)
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 10, 0)
    addBtn:SetScript("OnClick", function() DoAdd() end)

    f:SetScript("OnShow", function()
        RefreshCustomWindow()
    end)

    table.insert(UISpecialFrames, "SnackBarCustomFrame")   -- Esc closes it
    f:Hide()
    return f
end

local function ToggleCustomWindow()
    if not customFrame then customFrame = BuildCustomWindow() end
    if customFrame:IsShown() then
        customFrame:Hide()
    else
        customFrame:Show()
    end
end

----------------------------------------------------------------------
-- Main options window
----------------------------------------------------------------------

local optionsFrame

local function BuildOptions()
    local f = CreateFrame("Frame", "SnackBarOptionsFrame", UIParent)
    f:SetWidth(330)
    f:SetHeight(446)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 50)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetBackdrop(DIALOG_BACKDROP)
    f:SetScript("OnMouseDown", function() this:StartMoving() end)
    f:SetScript("OnMouseUp", function() this:StopMovingOrSizing() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("SnackBar Options")

    local close = CreateFrame("Button", "SnackBarOptionsClose", f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    -- Keybind ---------------------------------------------------------
    local keyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    keyLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 26, -56)
    keyLabel:SetText("Keybind:")

    local keyBtn = MakeKeyCapture("SnackBarKeyButton", f, function()
        return "SNACKBAR_EAT"
    end)
    keyBtn:SetPoint("LEFT", keyLabel, "RIGHT", 12, 0)

    local keyHint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    keyHint:SetPoint("TOPLEFT", keyLabel, "BOTTOMLEFT", 0, -8)
    keyHint:SetText("Left-click to set (Esc cancels), right-click to clear.")

    -- Visibility checkboxes -------------------------------------------
    local function BoolOption(key)
        return function(on)
            if SnackBarDB then SnackBarDB[key] = on end
            ApplyCombatVisibility()
        end
    end

    local cbShow = MakeCheckBox("SnackBarCheckShowFlyout", f,
        "Show flyout buttons", 22, -100, BoolOption("showFlyout"))
    local cbHideFly = MakeCheckBox("SnackBarCheckHideFlyout", f,
        "Hide flyout buttons in combat", 22, -124, BoolOption("hideFlyoutCombat"))
    local cbHideFrame = MakeCheckBox("SnackBarCheckHideFrame", f,
        "Hide food buttons entirely in combat", 22, -148, BoolOption("hideFrameCombat"))
    local function AutoOption(key)
        return function(on)
            if SnackBarDB then SnackBarDB[key] = on and true or nil end
            RefreshAll()
        end
    end
    local cbAutoNoCombat = MakeCheckBox("SnackBarCheckAutoNoCombat", f,
        "Main button: don't use in combat", 22, -172, AutoOption("autoNoCombat"))
    local cbAutoNoOoc = MakeCheckBox("SnackBarCheckAutoNoOoc", f,
        "Main button: don't use out of combat", 22, -196, AutoOption("autoNoOoc"))

    -- Main button's flyout direction ----------------------------------
    local refreshDirs = MakeDirButtons("SnackBarMainDir", f, 26, -224, 130,
        function(key)
            if not SnackBarDB then return nil end
            if key == "arrow" then return SnackBarDB.autoArrow end
            return SnackBarDB.autoGrow
        end,
        function(key, dir)
            if SnackBarDB then
                if key == "arrow" then SnackBarDB.autoArrow = dir else SnackBarDB.autoGrow = dir end
            end
        end)

    -- Sliders ---------------------------------------------------------
    local _, _, setScale = MakeSlider("SnackBarScaleSlider", f, "Button scale",
        SCALE_MIN, SCALE_MAX, 0.05, "%.2f", -278,
        function(v) ApplyScaleAll(v) end)

    local _, _, setLock = MakeSlider("SnackBarLockSlider", f, "Main button: lock after eating (sec)",
        LOCK_MIN, LOCK_MAX, 0.1, "%.1f", -344,
        function(v) if SnackBarDB then SnackBarDB.lock = v end end)

    local lockHint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lockHint:SetPoint("TOPLEFT", f, "TOPLEFT", 26, -378)
    lockHint:SetWidth(280)
    lockHint:SetJustifyH("LEFT")
    lockHint:SetText("Food buttons ignore clicks this long after eating (0 = off). Custom buttons have their own setting.")

    local customBtn = MakeSmallButton("SnackBarOpenCustom", f, "Custom Buttons...", 170, 24)
    customBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 20)
    customBtn:SetScript("OnClick", function()
        ToggleCustomWindow()
    end)

    f:SetScript("OnShow", function()
        local db = SnackBarDB or {}
        setScale(db.scale or DEFAULT_SCALE)
        setLock(db.lock or DEFAULT_LOCK)
        cbShow:SetChecked(db.showFlyout and 1 or nil)
        cbHideFly:SetChecked(db.hideFlyoutCombat and 1 or nil)
        cbHideFrame:SetChecked(db.hideFrameCombat and 1 or nil)
        cbAutoNoCombat:SetChecked(db.autoNoCombat and 1 or nil)
        cbAutoNoOoc:SetChecked(db.autoNoOoc and 1 or nil)
        refreshDirs()
        keyBtn.Refresh()
    end)

    f:SetScript("OnHide", function()
        keyBtn.Stop()
    end)

    table.insert(UISpecialFrames, "SnackBarOptionsFrame")   -- Esc closes it
    f:Hide()
    return f
end

local function ToggleOptions()
    if not optionsFrame then optionsFrame = BuildOptions() end
    if optionsFrame:IsVisible() then
        optionsFrame:Hide()
    else
        optionsFrame:Show()
    end
end

----------------------------------------------------------------------
-- Events and per-frame updates (a hidden-proof driver frame)
----------------------------------------------------------------------

local driver = CreateFrame("Frame", "SnackBarDriver", UIParent)
local elapsedSum = 0
local cdElapsed = 0
local lastCombat, lastDead

driver:SetScript("OnUpdate", function()
    local now = GetTime()
    ServiceLearn(now)
    local combat = InCombat()
    local n = table.getn(allUnits)

    -- One-time full recheck a few seconds after logging in.
    if loginCheckAt and now >= loginCheckAt then
        loginCheckAt = nil
        ForceRescan()
    end

    -- Delayed follow-up scan (after bag changes or unready tooltips).
    if recheckAt and now >= recheckAt then
        recheckAt = nil
        dirty = true
    end

    -- Re-skin only when combat/lock state actually changes.
    local dead = IsDead()
    if combat ~= lastCombat or dead ~= lastDead then
        lastCombat = combat
        lastDead = dead
        ApplyCombatVisibility()
        for i = 1, n do ApplyVisual(allUnits[i]) end
    end
    -- Each bar has its own lock: re-skin it when it starts/ends, count it down.
    for i = 1, n do
        local u = allUnits[i]
        local l = u.active and u.food and now < u.lockUntil
        if l ~= u.wasLocked then
            u.wasLocked = l
            ApplyVisual(u)
        end
        if l then u.lockText:SetText(string.format("%.1f", u.lockUntil - now)) end
    end

    -- Close flyouts shortly after the mouse leaves them.
    for i = 1, n do
        local u = allUnits[i]
        if u.flyout:IsShown() then
            if MouseInFlyout(u) then
                u.flyIdle = 0
            else
                u.flyIdle = u.flyIdle + arg1
                if u.flyIdle > 0.25 then
                    u.flyout:Hide()
                    u.flyIdle = 0
                end
            end
        else
            u.flyIdle = 0
        end
    end

    -- While any item is on cooldown, rescan twice a second so buttons advance
    -- to the next item and come back the moment a cooldown ends.
    -- The global cooldown is short, so check more often while it runs.
    if anyCooldown or anyGcd then
        cdElapsed = cdElapsed + arg1
        local interval = anyGcd and 0.1 or 0.5
        if cdElapsed > interval then
            cdElapsed = 0
            dirty = true
        end
    else
        cdElapsed = 0
    end

    -- Throttled re-scan of the bags.
    elapsedSum = elapsedSum + arg1
    if dirty and elapsedSum > 0.15 then
        elapsedSum = 0
        dirty = false
        RefreshAll()
    end
end)

driver:RegisterEvent("VARIABLES_LOADED")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("PLAYER_REGEN_DISABLED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterEvent("BAG_UPDATE")
driver:RegisterEvent("BAG_UPDATE_COOLDOWN")
driver:RegisterEvent("UPDATE_BINDINGS")
driver:RegisterEvent("UNIT_HEALTH")
driver:RegisterEvent("UNIT_MANA")
driver:RegisterEvent("UNIT_MAXHEALTH")
driver:RegisterEvent("UNIT_MAXMANA")
driver:RegisterEvent("PLAYER_LEVEL_UP")
driver:RegisterEvent("PLAYER_AURAS_CHANGED")

driver:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        if not SnackBarDB then SnackBarDB = {} end
        if not SnackBarDB.scale then SnackBarDB.scale = DEFAULT_SCALE end
        if not SnackBarDB.lock then SnackBarDB.lock = DEFAULT_LOCK end
        if SnackBarDB.showFlyout == nil then SnackBarDB.showFlyout = true end
        if SnackBarDB.hideFlyoutCombat == nil then SnackBarDB.hideFlyoutCombat = false end
        if SnackBarDB.hideFrameCombat == nil then SnackBarDB.hideFrameCombat = false end
        if not SnackBarDB.buttons then SnackBarDB.buttons = {} end
        for i = 1, table.getn(allUnits) do
            allUnits[i].btn:SetScale(SnackBarDB.scale)
        end
        ApplyPosition(mainUnit)
        BindCustomUnits()
        dirty = true
    elseif event == "PLAYER_ENTERING_WORLD" then
        combatFlag = UnitAffectingCombat("player") and true or false
        ApplyCombatVisibility()
        dirty = true
        if not loginChecked then
            loginChecked = true
            loginCheckAt = GetTime() + 5     -- one-time recheck a few seconds after login
        end
    elseif event == "PLAYER_AURAS_CHANGED" then
        buffCache = nil
        dirty = true
    elseif event == "PLAYER_REGEN_DISABLED" then
        combatFlag = true
        ApplyCombatVisibility()
        for i = 1, table.getn(allUnits) do ApplyVisual(allUnits[i]) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        combatFlag = false
        ApplyCombatVisibility()
        for i = 1, table.getn(allUnits) do ApplyVisual(allUnits[i]) end
        dirty = true
    elseif event == "UPDATE_BINDINGS" then
        RefreshKeyLabels()
    elseif event == "BAG_UPDATE" then
        dirty = true
        retries = 0
        recheckAt = GetTime() + 0.6      -- second pass in case item data lagged
    elseif string.find(event, "^UNIT_") then
        if arg1 == "player" then dirty = true end
    else
        dirty = true
    end
end)

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------

SLASH_SNACKBAR1 = "/sb"
SLASH_SNACKBAR2 = "/snackbar"
SlashCmdList["SNACKBAR"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "" or msg == "options" or msg == "config" then
        ToggleOptions()
    elseif msg == "custom" then
        ToggleCustomWindow()
    elseif msg == "eat" then
        SnackBar_Eat()
    elseif msg == "rescan" then
        ForceRescan()
        Say("Bags rescanned.")
    elseif msg == "reset" then
        if SnackBarDB then
            SnackBarDB.x = nil
            SnackBarDB.y = nil
            for i = 1, table.getn(SnackBarDB.buttons or {}) do
                SnackBarDB.buttons[i].x = nil
                SnackBarDB.buttons[i].y = nil
            end
        end
        for i = 1, table.getn(allUnits) do ApplyPosition(allUnits[i]) end
        Say("Positions reset.")
    else
        Say("/sb - open options")
        Say("/sb custom - edit custom buttons")
        Say("/sb eat - eat the best food now")
        Say("/sb rescan - recheck your bags")
        Say("/sb reset - reset button positions")
        Say("Shift+drag a button to move it.")
    end
end
