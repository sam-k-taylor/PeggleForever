-- Peggle compatibility layer for WoW "forever" (1.60.1, Interface 16001).
--
-- Peggle.lua is minified and its main chunk already uses all 200 local slots,
-- so the replacements below can't be added as locals. Instead Peggle.lua runs
-- inside a private environment (setfenv on its first line): lookups hit this
-- table first and fall through to _G, and global writes go straight to _G.

local _, ns = ...

-- Filled in below; the metatable is attached at the end of this file so the
-- definitions land in env rather than falling through to _G.
local env = {}
ns.env = env

local CreateFrame = CreateFrame
local hooksecurefunc = hooksecurefunc
local GetRaidRosterInfo = GetRaidRosterInfo
local GetGuildRosterInfo = GetGuildRosterInfo
local GetNumGuildMembers = GetNumGuildMembers

local ADDON_PREFIX = "PEGGLE"
local ART_PATH = "Interface\\AddOns\\Peggle\\images\\"

C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)

local function StripRealm(name)
	return name and Ambiguate(name, "none")
end

------------------------------------------------------------------------------
-- Widget fixes applied to every frame and texture Peggle creates
------------------------------------------------------------------------------

-- Texture:SetTexture(r, g, b[, a]) became SetColorTexture.
local function TextureSetTexture(self, a, ...)
	if type(a) == "number" and ... ~= nil then
		return self:SetColorTexture(a, ...)
	end
	return getmetatable(self).__index.SetTexture(self, a, ...)
end

local function WrapTexture(tex)
	tex.SetTexture = TextureSetTexture
	return tex
end

local function FrameCreateTexture(self, ...)
	return WrapTexture(getmetatable(self).__index.CreateTexture(self, ...))
end

-- SetBackdrop moved to BackdropTemplateMixin; mix it in on first use.
local backdropMethods = {
	"SetBackdrop", "GetBackdrop", "SetBackdropColor", "GetBackdropColor",
	"SetBackdropBorderColor", "GetBackdropBorderColor",
}
local backdropStubs = {}
for _, method in ipairs(backdropMethods) do
	backdropStubs[method] = function(self, ...)
		Mixin(self, BackdropTemplateMixin)
		self:HookScript("OnSizeChanged", self.OnBackdropSizeChanged)
		return self[method](self, ...)
	end
end

-- SetMinResize/SetMaxResize were merged into SetResizeBounds.
local function FrameSetMinResize(self, w, h)
	self.peggleMinW, self.peggleMinH = w, h
	self:SetResizeBounds(w, h, self.peggleMaxW, self.peggleMaxH)
end

local function FrameSetMaxResize(self, w, h)
	self.peggleMaxW, self.peggleMaxH = w, h
	self:SetResizeBounds(self.peggleMinW or 1, self.peggleMinH or 1, w, h)
end

-- EditBox limits no longer accept nil; the old client treated it as 0 (no limit).
local function EditBoxSetMaxLetters(self, n)
	return getmetatable(self).__index.SetMaxLetters(self, n or 0)
end

local function EditBoxSetMaxBytes(self, n)
	return getmetatable(self).__index.SetMaxBytes(self, n or 0)
end

local function EditBoxSetNumeric(self, numeric)
	return getmetatable(self).__index.SetNumeric(self, numeric and true or false)
end

local function WrapFrame(frame)
	frame.CreateTexture = FrameCreateTexture
	frame.SetMinResize = FrameSetMinResize
	frame.SetMaxResize = FrameSetMaxResize
	if frame:GetObjectType() == "EditBox" then
		frame.SetMaxLetters = EditBoxSetMaxLetters
		frame.SetMaxBytes = EditBoxSetMaxBytes
		frame.SetNumeric = EditBoxSetNumeric
	end
	if not frame.SetBackdrop then
		for method, stub in pairs(backdropStubs) do
			frame[method] = stub
		end
	end
	return frame
end

------------------------------------------------------------------------------
-- Replacements for templates that no longer exist
------------------------------------------------------------------------------

local renamedTemplates = {
	OptionsButtonTemplate = "UIPanelButtonTemplate",
	OptionsCheckButtonTemplate = "UICheckButtonTemplate",
}

local templateBuilders = {}

-- Sparkle frame: 16 named sparkle textures that Peggle animates itself.
templateBuilders.AutoCastShineTemplate = function(frameType, name, parent)
	local frame = CreateFrame(frameType, name, parent)
	for i = 1, 16 do
		local spark = frame:CreateTexture(name and (name .. i), "OVERLAY")
		spark:SetTexture("Interface\\ItemSocketingFrame\\UI-ItemSockets")
		spark:SetTexCoord(0.3984375, 0.4453125, 0.40234375, 0.44921875)
		spark:SetBlendMode("ADD")
		spark:SetSize(13, 13)
		spark:SetPoint("CENTER")
		spark:Hide()
	end
	return frame
end

-- Talent buttons from the Wrath-era talent frame.
templateBuilders.TalentButtonTemplate = function(frameType, name, parent)
	local button = CreateFrame(frameType, name, parent)
	button:SetSize(37, 37)
	button:SetPoint("TOPLEFT")
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	local slot = button:CreateTexture(name .. "Slot", "BACKGROUND")
	slot:SetTexture("Interface\\Buttons\\UI-EmptySlot-White")
	slot:SetSize(64, 64)
	slot:SetPoint("CENTER")

	local icon = button:CreateTexture(name .. "IconTexture", "BORDER")
	icon:SetAllPoints()

	local normal = WrapTexture(button:CreateTexture(name .. "NormalTexture"))
	normal:SetTexture("Interface\\Buttons\\UI-Quickslot2")
	normal:SetSize(64, 64)
	normal:SetPoint("CENTER")
	button:SetNormalTexture(normal)
	button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
	button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

	local rankBorder = button:CreateTexture(name .. "RankBorder", "OVERLAY")
	rankBorder:SetTexture("Interface\\TalentFrame\\TalentFrame-RankBorder")
	rankBorder:SetSize(32, 32)
	rankBorder:SetPoint("CENTER", button, "BOTTOMRIGHT")

	local rank = button:CreateFontString(name .. "Rank", "OVERLAY", "GameFontNormalSmall")
	rank:SetPoint("CENTER", rankBorder, "CENTER", 1, 0)

	button:SetScript("OnLeave", GameTooltip_Hide)
	return button
end

-- The "exhibit A" easter-egg toast. The modern AchievementAlertFrameTemplate
-- is driven by the alert system, so build a standalone look-alike with the
-- named children Peggle expects.
templateBuilders.AchievementAlertFrameTemplate = function(frameType, name, parent)
	local frame = CreateFrame(frameType, name, parent)
	frame:SetSize(300, 88)
	frame:SetFrameStrata("DIALOG")

	local bg = frame:CreateTexture(nil, "BACKGROUND")
	bg:SetAtlas("ui-achievement-alert-background")
	bg:SetAllPoints()

	frame.glow = frame:CreateTexture(nil, "OVERLAY")
	frame.glow:SetAtlas("ui-achievement-alert-glow-glow")
	frame.glow:SetBlendMode("ADD")
	frame.glow:SetPoint("CENTER")
	frame.glow:Hide()

	frame.shine = frame:CreateTexture(nil, "OVERLAY")
	frame.shine:SetAtlas("ui-achievement-alert-glow-shine")
	frame.shine:SetBlendMode("ADD")
	frame.shine:SetPoint("TOPLEFT")
	frame.shine:Hide()

	local icon = frame:CreateTexture(name .. "IconTexture", "ARTWORK")
	icon:SetSize(72, 72)
	icon:SetPoint("LEFT", 28, -4)

	local title = frame:CreateFontString(name .. "Name", "ARTWORK", "GameFontHighlight")
	title:SetPoint("CENTER")

	local unlocked = frame:CreateFontString(name .. "Unlocked", "ARTWORK", "GameFontNormal")
	unlocked:SetPoint("TOP", 0, -23)
	unlocked:SetText(ACHIEVEMENT_UNLOCKED)

	local shield = CreateFrame("Frame", name .. "Shield", frame)
	shield:SetSize(64, 64)
	shield:SetPoint("RIGHT", -20, -4)
	shield.icon = shield:CreateTexture(nil, "BACKGROUND")
	shield.icon:SetAllPoints()
	shield.icon:SetTexCoord(0, 0.5, 0, 0.45)
	shield.points = shield:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	shield.points:SetPoint("CENTER", 7, 2)

	return frame
end

-- Talent tree arrow/branch coordinates from the Wrath-era talent frame.
env.TALENT_BRANCH_TEXTURECOORDS = {
	down = { [1] = { 0.12890625, 0.25390625, 0.484375, 0 }, [-1] = { 0.12890625, 0.25390625, 1.0, 0.515625 } },
}
env.TALENT_ARROW_TEXTURECOORDS = {
	top = { [1] = { 0, 0.5, 0, 0.5 }, [-1] = { 0, 0.5, 0.5, 1.0 } },
}

------------------------------------------------------------------------------
-- CreateFrame
------------------------------------------------------------------------------

-- Wrap a frame's OnEvent so CHAT_MSG_ADDON senders arrive without the realm
-- suffix, matching the bare names Peggle compares against and stores.
local function StripAddonSenderRealm(frame)
	local setScript = frame.SetScript
	frame.SetScript = function(self, handler, func)
		if handler == "OnEvent" and func then
			local original = func
			func = function(f, event, prefix, message, channel, sender, ...)
				if event == "CHAT_MSG_ADDON" then
					sender = StripRealm(sender)
				end
				return original(f, event, prefix, message, channel, sender, ...)
			end
		end
		return setScript(self, handler, func)
	end
end

function env.CreateFrame(frameType, name, parent, template, id)
	if name == "" then
		name = nil
	end
	local frame
	local builder = template and templateBuilders[template]
	if builder then
		frame = builder(frameType, name, parent)
	else
		frame = CreateFrame(frameType, name, parent, template and renamedTemplates[template] or template, id)
	end
	if name == "PeggleNet" then
		StripAddonSenderRealm(frame)
	end
	return WrapFrame(frame)
end

------------------------------------------------------------------------------
-- Removed or moved global functions
------------------------------------------------------------------------------

function env.getglobal(name)
	return _G[name]
end

function env.SetDesaturation(texture, desaturate)
	texture:SetDesaturated(desaturate and true or false)
end

function env.MouseIsOver(frame, top, bottom, left, right)
	return frame:IsMouseOver(top, bottom, left, right)
end

-- DrawRouteLine was the taxi-map line helper; DrawLine replaced it and takes
-- the line factor explicitly (the old function used TAXIROUTE_LINEFACTOR).
local ROUTE_LINE_FACTOR = 32 / 30
function env.DrawRouteLine(texture, canvas, startX, startY, endX, endY, width, relPoint)
	DrawLine(texture, canvas, startX, startY, endX, endY, width, ROUTE_LINE_FACTOR, relPoint)
end

function env.SendAddonMessage(prefix, message, chatType, target)
	return C_ChatInfo.SendAddonMessage(prefix, message, chatType, target)
end

function env.SendChatMessage(message, chatType, languageID, target)
	return C_ChatInfo.SendChatMessage(message, chatType, languageID, target)
end

-- Chat filters can be handed secret values in restricted contexts; let those
-- pass through untouched instead of erroring inside Peggle's string handling.
local wrappedFilters = {}
local function SafeFilter(callback)
	local wrapped = wrappedFilters[callback]
	if not wrapped then
		wrapped = function(frame, event, message, ...)
			if issecretvalue(message) then
				return false
			end
			return callback(frame, event, message, ...)
		end
		wrappedFilters[callback] = wrapped
	end
	return wrapped
end

function env.ChatFrame_AddMessageEventFilter(event, callback)
	ChatFrameUtil.AddMessageEventFilter(event, SafeFilter(callback))
end

function env.ChatFrame_RemoveMessageEventFilter(event, callback)
	ChatFrameUtil.RemoveMessageEventFilter(event, SafeFilter(callback))
end

function env.RaidNotice_AddMessage(_noticeFrame, text, colorInfo, displayTime)
	RaidWarningUtil.AddMessage(text, colorInfo, displayTime)
end

-- Group roster
function env.GetNumRaidMembers()
	return IsInRaid() and GetNumGroupMembers() or 0
end

function env.IsRaidOfficer()
	return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

local lootMethodNames = {
	[Enum.LootMethod.Freeforall] = "freeforall",
	[Enum.LootMethod.Roundrobin] = "roundrobin",
	[Enum.LootMethod.Masterlooter] = "master",
	[Enum.LootMethod.Group] = "group",
	[Enum.LootMethod.Needbeforegreed] = "needbeforegreed",
	[Enum.LootMethod.Personal] = "personalloot",
}

function env.GetLootMethod()
	local method, masterLootPartyID, masterLooterRaidID = C_PartyInfo.GetLootMethod()
	return lootMethodNames[method], masterLootPartyID, masterLooterRaidID
end

function env.GetRaidRosterInfo(index)
	local name = GetRaidRosterInfo(index)
	return StripRealm(name), select(2, GetRaidRosterInfo(index))
end

-- Friends: same return order as the old GetFriendInfo.
function env.GetNumFriends()
	return C_FriendList.GetNumFriends()
end

function env.GetFriendInfo(index)
	local info = C_FriendList.GetFriendInfoByIndex(index)
	if not info then
		return nil
	end
	return info.name, info.level, info.className, info.area, info.connected,
		info.afk and CHAT_FLAG_AFK or info.dnd and CHAT_FLAG_DND or "", info.notes
end

-- Guild roster: names come back as "Name-Realm"; strip same-realm suffixes so
-- they match addon-message senders.
function env.GetGuildRosterInfo(index)
	local name = GetGuildRosterInfo(index)
	return StripRealm(name), select(2, GetGuildRosterInfo(index))
end

function env.GetNumGuildMembers()
	C_GuildInfo.GuildRoster()
	return GetNumGuildMembers()
end

-- Date: CalendarGetDate returned weekday, month, day, year.
function env.CalendarGetDate()
	local now = C_DateAndTime.GetCurrentCalendarTime()
	return now.weekday, now.month, now.monthDay, now.year
end

------------------------------------------------------------------------------
-- Achievement easter egg ("/peggle achievement")
------------------------------------------------------------------------------

-- The toast above doesn't need Blizzard_AchievementUI, which may not be
-- available on this client.
function env.AchievementFrame_LoadUI()
end

function env.AchievementShield_SetPoints(points, pointString, normalFont, smallFont)
	pointString:SetFontObject(points >= 100 and smallFont or normalFont)
	pointString:SetText(points)
end

-- Fade in, hold for self.holdDuration, then fade out.
local FADE_IN, FADE_OUT = 0.2, 1.5
function env.AchievementAlertFrame_OnUpdate(self, elapsed)
	self.elapsed = (self.elapsed or 0) + elapsed
	local t = self.elapsed
	local hold = self.holdDuration or 5
	if t < FADE_IN then
		self:SetAlpha(t / FADE_IN)
		self.glow:Show()
		self.glow:SetAlpha(1 - t / FADE_IN)
	elseif t < FADE_IN + hold then
		self:SetAlpha(1)
		self.glow:Hide()
	elseif t < FADE_IN + hold + FADE_OUT then
		self:SetAlpha(1 - (t - FADE_IN - hold) / FADE_OUT)
	else
		self:SetAlpha(1)
		self:Hide()
		self:SetScript("OnUpdate", nil)
	end
end

------------------------------------------------------------------------------
-- Dropdown skinning
------------------------------------------------------------------------------

-- Peggle hooks ToggleDropDownMenu (for every addon's dropdowns) and swaps the
-- list backdrop via Get/SetBackdrop. Dropdown lists now use a NineSlice
-- tooltip border, so overlay Peggle's background on its own menus instead.
local function SkinDropdown()
	local level = UIDROPDOWNMENU_MENU_LEVEL or 1
	local list = _G["DropDownList" .. level .. "MenuBackdrop"]
	if not list then
		return
	end
	if not list.peggleSkin then
		list.peggleSkin = list:CreateTexture(nil, "BACKGROUND", nil, 7)
		list.peggleSkin:SetPoint("TOPLEFT", 3, -3)
		list.peggleSkin:SetPoint("BOTTOMRIGHT", -3, 3)
		list.peggleSkin:SetTexture(ART_PATH .. "windowBackground", "REPEAT", "REPEAT")
		list.peggleSkin:SetHorizTile(true)
		list.peggleSkin:SetVertTile(true)
	end
	local menu = UIDROPDOWNMENU_OPEN_MENU
	if type(menu) == "string" then
		menu = _G[menu]
	end
	list.peggleSkin:SetShown(type(menu) == "table" and menu.peggleMenu and true or false)
end

function env.hooksecurefunc(target, method, hook)
	if target == "ToggleDropDownMenu" then
		return hooksecurefunc("ToggleDropDownMenu", SkinDropdown)
	end
	if hook then
		return hooksecurefunc(target, method, hook)
	end
	return hooksecurefunc(target, method)
end

setmetatable(env, { __index = _G, __newindex = _G })
