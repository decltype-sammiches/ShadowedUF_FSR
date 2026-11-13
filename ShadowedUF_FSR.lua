--[[
	Shadowed Unit Frames - Five Second Rule

	Spirit-based mana regen stops for five seconds after mana is spent. This module
	draws that window on top of the player frame's mana bar: a spark sweeping across
	the bar, an optional tinted overlay, and optional countdown text.

	When the player is shapeshifted (power bar showing energy/rage) the overlay moves
	to SUF's druid mana bar if that bar is enabled, otherwise it stays hidden.
]]

local ShadowUF = ShadowUF
if( not ShadowUF ) then return end

local FSR = {}
local KEY = "fsrBar"
ShadowUF:RegisterModule(FSR, KEY, "Five second rule")

local WINDOW = 5
-- A cast and the mana drop it causes arrive as separate events in either order.
local MATCH_WINDOW = 0.4
local MANA = Enum and Enum.PowerType and Enum.PowerType.Mana or 0
local SPARK_TEXTURE = "Interface\\CastingBar\\UI-CastingBar-Spark"

local issecretvalue = _G.issecretvalue
local GetSpellPowerCost = (C_Spell and C_Spell.GetSpellPowerCost) or _G.GetSpellPowerCost

local DEFAULTS = {
	enabled = true,
	spark = true,
	overlay = true,
	overlayColor = {r = 1, g = 1, b = 1, a = 0.25},
	direction = "drain",
	text = false,
	mp5Text = true,
	textSize = 0,
	keepFaderVisible = true,
}

-- Defaults have to be in place before SUF builds its AceDB, which happens on PLAYER_LOGIN.
hooksecurefunc(ShadowUF, "LoadUnitDefaults", function(self)
	local player = self.defaults.profile.units.player
	if( player ) then
		player[KEY] = CopyTable(DEFAULTS)
	end
end)

----------------------------------------------------------------------------
-- Detection
----------------------------------------------------------------------------

local fsrEnd = 0
local activeFrames = {}
local driver = CreateFrame("Frame")
driver:Hide()

local function IsReadable(value)
	return value ~= nil and not ( issecretvalue and issecretvalue(value) )
end

-- Mana can be a secret value (in combat on restricted clients), in which case nil.
local function ReadMana()
	local ok, mana = pcall(UnitPower, "player", MANA)
	if( ok and IsReadable(mana) ) then return mana end
end

local function HasManaCost(spellID)
	if( not spellID or not GetSpellPowerCost ) then return true end

	local ok, costs = pcall(GetSpellPowerCost, spellID)
	if( not ok ) then return true end
	if( type(costs) ~= "table" ) then return false end

	for _, info in ipairs(costs) do
		local okType, isMana = pcall(function() return info.type == MANA end)
		if( okType and isMana ) then
			local okCost, positive = pcall(function() return ( info.cost or 0 ) > 0 or ( info.minCost or 0 ) > 0 end)
			-- An unreadable cost on a mana entry still means the spell costs mana.
			if( not okCost or positive ) then return true end
		end
	end

	return false
end

-- Mana per second outside the five second rule. Kept from the last readable value,
-- since on restricted clients it is secret in combat.
local regenPerSecond

local function RenderIdleFrames()
	if( fsrEnd > 0 ) then return end
	for frame in pairs(activeFrames) do
		FSR:Render(frame, 0)
	end
end

local function RefreshRegen()
	if( not GetManaRegen ) then return end

	local ok, base = pcall(GetManaRegen)
	if( not ok or not IsReadable(base) ) then return end

	-- Zero is what some clients report mid-rule or while shapeshifted; keep the last real value.
	local okCompare, positive = pcall(function() return base > 0 end)
	if( not okCompare or not positive or base == regenPerSecond ) then return end

	regenPerSecond = base
	RenderIdleFrames()
end

-- Stats settle a moment after the aura/gear event that changes them, so check again shortly after.
local regenRecheckQueued
local function QueueRegenRefresh()
	RefreshRegen()
	if( regenRecheckQueued ) then return end
	regenRecheckQueued = true
	C_Timer.After(0.5, function()
		regenRecheckQueued = nil
		RefreshRegen()
	end)
end

-- Step curve over the mana fraction: 1 below full, 0 at full. UnitPowerPercent evaluates
-- it natively, so this works even when mana itself is a secret value (the result may be
-- secret too, which is why it only ever goes to SetAlpha). Same technique as SUF's fader.
local fullManaCurve
if( C_CurveUtil and C_CurveUtil.CreateCurve and UnitPowerPercent and Enum and Enum.LuaCurveType ) then
	fullManaCurve = C_CurveUtil.CreateCurve()
	fullManaCurve:SetType(Enum.LuaCurveType.Step)
	fullManaCurve:AddPoint(0, 1)
	fullManaCurve:AddPoint(1, 0)
end

local function NotFullAlpha()
	if( fullManaCurve ) then
		local ok, alpha = pcall(UnitPowerPercent, "player", MANA, true, fullManaCurve)
		if( ok and alpha ~= nil ) then return alpha end
	end

	-- Clients without curves: plain comparison when the values are readable.
	local mana = ReadMana()
	local ok, max = pcall(UnitPowerMax, "player", MANA)
	if( mana and ok and IsReadable(max) and max > 0 and mana >= max ) then return 0 end
	return 1
end

----------------------------------------------------------------------------
-- Combat fader: keep the player frame visible while mana isn't full
----------------------------------------------------------------------------

-- The fader picks fade in/out with a plain branch, so it needs a plain boolean. A
-- secret mana value can't give one, so when mana is unreadable this goes by activity:
-- mana is still filling if it changed recently (regen updates stop once it's full),
-- or if the five second rule is running (no regen, but mana was just spent).
local MANA_SETTLE_TIME = 2.5
local lastManaChangeAt = 0
local manaNotFull = false

local function ComputeManaNotFull()
	local mana = ReadMana()
	local ok, max = pcall(UnitPowerMax, "player", MANA)
	if( mana and ok and IsReadable(max) ) then
		return max > 0 and mana < max
	end

	return fsrEnd > 0 or GetTime() - lastManaChangeAt < MANA_SETTLE_TIME
end

local function KeepsFaderIn(frame)
	local widget = activeFrames[frame] and frame[KEY]
	if( not widget or not widget.config or not widget.config.keepFaderVisible ) then return false end

	return ComputeManaNotFull()
end

-- Re-run the fader when the answer flips; nothing else would tell it that mana settled.
local function RefreshFader()
	local Fader = ShadowUF.modules.fader
	local notFull = ComputeManaNotFull()
	if( not Fader or notFull == manaNotFull ) then return end
	manaNotFull = notFull

	for frame in pairs(activeFrames) do
		if( frame.visibility.fader and frame.fader ) then
			Fader:Update(frame)
		end
	end
end

local settleCheckQueued
local function QueueSettleCheck()
	if( settleCheckQueued ) then return end
	settleCheckQueued = true

	local function check()
		local wait = lastManaChangeAt + MANA_SETTLE_TIME - GetTime()
		if( wait > 0 ) then
			C_Timer.After(wait + 0.05, check)
			return
		end
		settleCheckQueued = nil
		RefreshFader()
	end
	C_Timer.After(MANA_SETTLE_TIME + 0.05, check)
end

-- SUF dispatches fader events by method name, so replacing the method covers them all.
-- Its "stay visible" branches live in local functions; for this call the plugin borrows
-- the fader's own casting flag, which takes the stay-visible path out of combat.
do
	local Fader = ShadowUF.modules.fader
	if( Fader and Fader.Update ) then
		local originalUpdate = Fader.Update
		Fader.Update = function(self, frame, event, ...)
			local fader = frame.fader
			if( fader and not fader.playerCasting and KeepsFaderIn(frame) ) then
				fader.playerCasting = true
				local ok, err = pcall(originalUpdate, self, frame, event, ...)
				fader.playerCasting = nil
				if( not ok ) then geterrorhandler()(err) end
				return
			end

			return originalUpdate(self, frame, event, ...)
		end
	end
end

local function StartWindow()
	fsrEnd = GetTime() + WINDOW
	driver:Show()
	RefreshFader()
end

local function StopWindow()
	fsrEnd = 0
	driver:Hide()
	RefreshFader()
	QueueSettleCheck()
	for frame in pairs(activeFrames) do
		FSR:Render(frame, 0)
	end
end

local lastMana, lastDropAt, castPendingUntil = nil, 0, 0

local detector = CreateFrame("Frame")
detector:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
detector:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
detector:RegisterUnitEvent("UNIT_MAXPOWER", "player")
detector:RegisterEvent("PLAYER_DEAD")
detector:RegisterEvent("PLAYER_ENTERING_WORLD")
detector:RegisterUnitEvent("UNIT_AURA", "player")
detector:RegisterUnitEvent("UNIT_STATS", "player")
detector:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
detector:RegisterEvent("PLAYER_LEVEL_UP")
detector:RegisterEvent("PLAYER_REGEN_ENABLED")

local REGEN_EVENTS = {
	UNIT_AURA = true, UNIT_STATS = true, PLAYER_EQUIPMENT_CHANGED = true,
	PLAYER_LEVEL_UP = true, PLAYER_REGEN_ENABLED = true, PLAYER_ENTERING_WORLD = true,
}

detector:SetScript("OnEvent", function(self, event, unit, arg2, arg3)
	if( REGEN_EVENTS[event] ) then
		QueueRegenRefresh()
	end

	if( event == "UNIT_POWER_FREQUENT" ) then
		if( arg2 ~= "MANA" ) then return end

		local mana = ReadMana()
		if( mana and lastMana and mana < lastMana ) then
			local now = GetTime()
			lastDropAt = now
			if( now <= castPendingUntil ) then
				castPendingUntil = 0
				StartWindow()
			end
		end
		lastMana = mana
		lastManaChangeAt = GetTime()
		RenderIdleFrames()
		RefreshFader()
		QueueSettleCheck()

	elseif( event == "UNIT_MAXPOWER" ) then
		if( arg2 == "MANA" ) then
			RenderIdleFrames()
			RefreshFader()
		end

	elseif( event == "UNIT_SPELLCAST_SUCCEEDED" ) then
		if( not HasManaCost(arg3) ) then return end

		local now = GetTime()
		local mana = ReadMana()
		if( not mana or not lastMana ) then
			-- Mana isn't readable, so the cast itself is the only signal. Free casts
			-- (Clearcasting) can't be told apart here and will trigger too.
			lastMana = mana
			StartWindow()
		elseif( now - lastDropAt <= MATCH_WINDOW ) then
			StartWindow()
		else
			-- Wait for the mana drop; if it never comes the cast was free.
			castPendingUntil = now + MATCH_WINDOW
		end

	elseif( event == "PLAYER_DEAD" ) then
		StopWindow()

	elseif( event == "PLAYER_ENTERING_WORLD" ) then
		lastMana = ReadMana()
		RenderIdleFrames()
	end
end)

driver:SetScript("OnUpdate", function()
	local remaining = fsrEnd - GetTime()
	if( remaining <= 0 ) then
		StopWindow()
		return
	end

	for frame in pairs(activeFrames) do
		FSR:Render(frame, remaining)
	end
end)

----------------------------------------------------------------------------
-- Display
----------------------------------------------------------------------------

-- The bar currently showing the player's mana, if any.
local function GetManaBar(frame)
	if( frame.inVehicle ) then return nil end

	local power = frame.powerBar
	if( power and frame.visibility.powerBar and power:IsShown() and power.currentType == "MANA" ) then
		return power
	end

	local druid = frame.druidBar
	if( druid and frame.visibility.druidBar and druid:IsShown() ) then
		return druid
	end
end

local function HideWidget(widget)
	widget:Hide()
	widget.text:Hide()
end

function FSR:OnInitialize()
	-- Covers a profile created before this plugin was installed if the defaults hook missed.
	local units = ShadowUF.db and ShadowUF.db.profile.units
	if( units and units.player and not units.player[KEY] ) then
		units.player[KEY] = CopyTable(DEFAULTS)
	end
end

function FSR:OnEnable(frame)
	if( not frame[KEY] ) then
		local widget = CreateFrame("Frame", nil, frame)
		widget:SetClipsChildren(true)

		widget.bar = CreateFrame("StatusBar", nil, widget)
		widget.bar:SetAllPoints(widget)
		widget.bar:SetMinMaxValues(0, 1)

		widget.spark = widget.bar:CreateTexture(nil, "OVERLAY")
		widget.spark:SetTexture(SPARK_TEXTURE)
		widget.spark:SetBlendMode("ADD")

		-- On the high frame so it sits with SUF's own text, above every bar.
		widget.text = frame.highFrame:CreateFontString(nil, "OVERLAY")
		widget.text:SetPoint("CENTER", widget, "CENTER", 0, 0)

		HideWidget(widget)
		frame[KEY] = widget
	end

	activeFrames[frame] = true

	-- Shapeshifting moves the mana display between the power and druid bars.
	frame:RegisterUnitEvent("UNIT_DISPLAYPOWER", self, "QueueRender")
end

-- Deferred a frame so SUF's own power/druid bar handlers have already shown or hidden their bars.
function FSR:QueueRender(frame)
	C_Timer.After(0, function()
		if( activeFrames[frame] ) then
			self:Render(frame, fsrEnd - GetTime())
		end
	end)
end

function FSR:OnDisable(frame)
	activeFrames[frame] = nil
	frame:UnregisterAll(self)
	if( frame[KEY] ) then HideWidget(frame[KEY]) end
end

function FSR:OnLayoutApplied(frame, config)
	local widget = frame[KEY]
	if( not widget or not frame.visibility[KEY] ) then return end

	local cfg = config[KEY]
	widget.config = cfg
	-- Force a re-anchor; the bar it follows may have moved or changed orientation.
	widget.target = nil

	widget.bar:SetStatusBarTexture(ShadowUF.Layout.mediaPath.statusbar)
	widget.bar:GetStatusBarTexture():SetHorizTile(false)
	local color = cfg.overlayColor or DEFAULTS.overlayColor
	widget.bar:SetStatusBarColor(color.r, color.g, color.b, cfg.overlay and color.a or 0)

	ShadowUF.Layout:SetupFontString(widget.text, cfg.textSize or 0)
	widget.text:SetTextColor(1, 1, 1)

	self:Render(frame, fsrEnd - GetTime())
end

function FSR:Anchor(widget, target)
	widget.target = target
	widget:ClearAllPoints()
	widget:SetAllPoints(target)
	widget:SetFrameLevel(target:GetFrameLevel() + 1)

	local vertical = target:GetOrientation() == "VERTICAL"
	widget.vertical = vertical
	widget.reverse = target:GetReverseFill()
	widget.bar:SetOrientation(vertical and "VERTICAL" or "HORIZONTAL")
	widget.bar:SetReverseFill(widget.reverse)
	widget.spark:SetRotation(vertical and math.pi / 2 or 0)
end

function FSR:Render(frame, remaining)
	local widget = frame[KEY]
	if( not widget or not widget.config ) then return end

	local target = GetManaBar(frame)
	if( not target ) then
		HideWidget(widget)
		return
	end

	if( widget.target ~= target ) then
		self:Anchor(widget, target)
	end

	local cfg = widget.config

	-- Outside the rule: no spark/overlay, just the regen rate.
	if( remaining <= 0 ) then
		widget:Hide()
		if( cfg.mp5Text and regenPerSecond ) then
			widget.text:SetFormattedText("%d mp5", math.floor(regenPerSecond * 5 + 0.5))
			widget.text:SetAlpha(NotFullAlpha())
			widget.text:Show()
		else
			widget.text:Hide()
		end
		return
	end

	local progress = remaining / WINDOW
	local value = cfg.direction == "fill" and ( 1 - progress ) or progress
	widget.bar:SetValue(value)
	widget:Show()

	if( cfg.spark ) then
		local width, height = widget:GetSize()
		local spark = widget.spark
		spark:ClearAllPoints()

		if( widget.vertical ) then
			spark:SetSize(width * 2.2, 20)
			local offset = height * value
			if( widget.reverse ) then
				spark:SetPoint("CENTER", widget, "TOP", 0, -offset)
			else
				spark:SetPoint("CENTER", widget, "BOTTOM", 0, offset)
			end
		else
			spark:SetSize(20, height * 2.2)
			local offset = width * value
			if( widget.reverse ) then
				spark:SetPoint("CENTER", widget, "RIGHT", -offset, 0)
			else
				spark:SetPoint("CENTER", widget, "LEFT", offset, 0)
			end
		end
		spark:Show()
	else
		widget.spark:Hide()
	end

	if( cfg.text ) then
		widget.text:SetFormattedText("%.1f", remaining)
		widget.text:SetAlpha(1)
		widget.text:Show()
	else
		widget.text:Hide()
	end
end

----------------------------------------------------------------------------
-- Options (ShadowedUF_Options is load-on-demand and fires this when it loads)
----------------------------------------------------------------------------

local function GetConfig()
	return ShadowUF.db.profile.units.player[KEY]
end

local function Reload()
	ShadowUF.Layout:Reload("player")
end

function FSR:OnConfigurationLoad()
	local options = ShadowUF.Config and ShadowUF.Config.options
	if( not options ) then return end

	local function disabled() return not GetConfig().enabled end

	options.args.fiveSecondRule = {
		type = "group",
		name = "Five second rule",
		order = 7.6,
		get = function(info) return GetConfig()[info[#info]] end,
		set = function(info, value)
			GetConfig()[info[#info]] = value
			Reload()
		end,
		args = {
			description = {
				order = 0,
				type = "description",
				name = "Shows the five seconds after you spend mana, during which spirit regeneration is paused, on the player frame's mana bar. While shapeshifted it uses the druid mana bar if that bar is enabled.\n\nWhere mana values are restricted in combat, every cast with a mana cost starts the timer, including free (Clearcasting) casts.\n",
				fontSize = "medium",
			},
			enabled = {
				order = 1,
				type = "toggle",
				name = "Enable",
				desc = "Show the five second rule on the player frame.",
				width = "full",
			},
			spark = {
				order = 2,
				type = "toggle",
				name = "Show spark",
				desc = "A spark that travels across the mana bar as the five seconds run out.",
				disabled = disabled,
			},
			overlay = {
				order = 3,
				type = "toggle",
				name = "Show overlay",
				desc = "Tint the part of the mana bar that represents the time remaining.",
				disabled = disabled,
			},
			overlayColor = {
				order = 4,
				type = "color",
				name = "Overlay color",
				hasAlpha = true,
				disabled = function() return disabled() or not GetConfig().overlay end,
				get = function()
					local color = GetConfig().overlayColor
					return color.r, color.g, color.b, color.a
				end,
				set = function(info, r, g, b, a)
					local color = GetConfig().overlayColor
					color.r, color.g, color.b, color.a = r, g, b, a
					Reload()
				end,
			},
			direction = {
				order = 5,
				type = "select",
				name = "Direction",
				desc = "Whether the timer empties out or fills up over the five seconds.",
				values = {drain = "Drain (full to empty)", fill = "Fill (empty to full)"},
				disabled = disabled,
			},
			text = {
				order = 6,
				type = "toggle",
				name = "Show countdown text",
				desc = "Seconds remaining, centered on the mana bar.",
				disabled = disabled,
			},
			mp5Text = {
				order = 6.5,
				type = "toggle",
				name = "Show MP5 when idle",
				desc = "Outside the five seconds, show your mana regeneration per 5 seconds in the same spot, hidden while mana is full. Where mana values are restricted in combat, the mp5 number is the last value read out of combat.",
				disabled = disabled,
			},
			textSize = {
				order = 7,
				type = "range",
				name = "Text size adjust",
				desc = "Relative to the global SUF font size.",
				min = -10, max = 10, step = 1,
				disabled = function() return disabled() or not ( GetConfig().text or GetConfig().mp5Text ) end,
			},
			keepFaderVisible = {
				order = 7.5,
				type = "toggle",
				name = "Fader: stay visible until mana is full",
				desc = "With SUF's combat fader enabled on the player frame, don't fade out while mana is missing, including while shapeshifted. Where mana values are restricted, the frame fades about 2.5 seconds after mana stops changing.",
				width = "full",
				disabled = disabled,
			},
			preview = {
				order = 8,
				type = "execute",
				name = "Preview",
				desc = "Run the five second timer once without casting.",
				disabled = disabled,
				func = StartWindow,
			},
		},
	}
end

-- /suffsr prints what the client reports, for diagnosing the mp5 text.
local function Describe(value)
	if( issecretvalue and issecretvalue(value) ) then return "secret" end
	return tostring(value)
end

SLASH_SUFFSR1 = "/suffsr"
SlashCmdList.SUFFSR = function()
	local p = "|cff33ff99SUF FSR|r"
	local okMana, mana = pcall(UnitPower, "player", MANA)
	local okMax, max = pcall(UnitPowerMax, "player", MANA)
	print(p, "mana:", okMana and Describe(mana) or "error", "max:", okMax and Describe(max) or "error")
	print(p, "curve:", fullManaCurve and "yes" or "no", "alpha at this mana:", Describe(NotFullAlpha()))
	print(p, "regen/s:", Describe(regenPerSecond), "timer running:", tostring(fsrEnd > 0))
	print(p, "mana not full (fader):", tostring(ComputeManaNotFull()), string.format("last mana change %.1fs ago", GetTime() - lastManaChangeAt))
	for frame in pairs(activeFrames) do
		local widget = frame[KEY]
		print(p, "bar:", widget.target == frame.powerBar and "power" or widget.target == frame.druidBar and "druid" or "none",
			"text shown:", tostring(widget.text:IsShown()), "text alpha:", Describe(widget.text:GetAlpha()))
	end
end

-- Exposed for /run and other addons.
FSR.Start = StartWindow
FSR.Stop = StopWindow
