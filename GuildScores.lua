-- Guild leaderboard: best scores shared with guildmates who also run Peggle Forever.
--
-- Everything travels as hidden addon messages on our own prefix, so nothing ever shows in
-- chat and older versions of the addon (which only listen on "PEGGLE") ignore it:
--
--   "R2:<account>"                     "send me your scores" (guild channel); every other
--                                      player answers by sending their scores to the guild
--   "S2:<account>:<class>:<key>=<score>/<flags>;..."
--                                      some of the sender's best scores (guild channel).
--                                      A full set is split over as many messages
--                                      as it needs; each message stands alone.
--
-- <account> is a random id saved once per WoW account (PeggleData.guildAccount). Best scores
-- are saved per account, not per character, so the board lists each account once, under the
-- character it last heard from. It also tells us which guild messages are our own echoes.
--
-- Level keys are the level number for the original levels and the pack key ("pack:level")
-- for level pack levels, so packs installed in a different order still line up. Flags are
-- Peggle's completion flags (0 none, 1 played, 2 beaten, 3 all pegs cleared).
--
-- We send our scores (and ask for everyone else's) shortly after logging in, send them again
-- after finishing a level, and ask again when the leaderboard tab is opened if we haven't
-- asked for a while. Received scores are kept in PeggleData.guildScores, per guild.
--
-- Peggle.lua finds this as PeggleGuild (see Compat.lua for why it lives in the addon
-- environment) and calls Install, CreateScreen and ScoresChanged.

local _, ns = ...
local env = ns.env
-- Compat's CreateFrame gives frames SetBackdrop on clients that moved it to a mixin.
local CreateFrame = env.CreateFrame
-- Compat's UnitName includes the surname ("Name Surname"), as addon message senders do.
local UnitName = env.UnitName

local PREFIX = "PeggleFvrGuild"
local PROTOCOL = "2"
local MAX_MESSAGE = 250 -- addon messages are capped at 255 bytes
local SEND_INTERVAL = 0.4 -- seconds between our queued messages
local RETRY_DELAY = 5 -- after the client refuses a message (throttled, locked down)
local MAX_RETRIES = 6
local HELLO_DELAY = 10 -- after loading, so the guild roster and realm name are known
local BROADCAST_DELAY = 2 -- batches several score changes into one send
local REQUEST_COOLDOWN = 120 -- between our own requests
local REPLY_DELAY = 5 -- longest random wait before answering a request
local FORGET_AFTER = 90 * 24 * 60 * 60 -- drop players we haven't heard from in this long
local MAX_KEY = 64
local MAX_SCORE = 999999999
local ROWS = 14

local TEXT = {
	title = "GUILD LEADERBOARD",
	rank = "#",
	player = "Player",
	score = "Score",
	empty = "No guild scores for this level yet.",
	noGuild = "Join a guild to compare scores with your guildmates.",
	info = "Best scores are shared automatically with guild members who also have Peggle Forever.",
	asking = "Asking your guild for their scores...",
	updated = "Updated %s ago",
	you = "(you)",
	range = "%d-%d of %d",
	beaten = "Level beaten",
	cleared = "All orange pegs cleared",
}

local Guild = {}
rawset(env, "PeggleGuild", Guild)

C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

------------------------------------------------------------------------------
-- Names and saved data
------------------------------------------------------------------------------

local function MyRealm()
	return GetNormalizedRealmName() or ((GetRealmName() or ""):gsub("[%s%-]", ""))
end

-- "Name-Realm" for any sender, so the same player is the same key whichever way we heard them.
local function FullName(name)
	if not name:find("-", 1, true) then
		return name .. "-" .. MyRealm()
	end
	return name
end

local function MyName()
	return FullName(UnitName("player"))
end

-- Random id shared by every character on this WoW account (see the top of the file).
local function MyAccount()
	if not PeggleData.guildAccount then
		-- the clock as well as math.random, in case math.random isn't seeded differently per account
		local clock = math.floor((debugprofilestop and debugprofilestop() or 0) + GetTime() * 1000 + time())
		PeggleData.guildAccount = string.format("%06x%06x", math.random(0, 0xFFFFFF), clock % 0x1000000)
	end
	return PeggleData.guildAccount
end

local function MyClass()
	local _, class = UnitClass("player")
	return class or ""
end

-- Scores are kept per guild ("Guild Name-Realm"), since saved data is shared by every
-- character on the account and they may be in different guilds.
local function GuildKey()
	local name, _, _, realm = GetGuildInfo("player")
	if not name then
		return nil
	end
	return name .. "-" .. (realm or MyRealm())
end

local function GuildTable(create)
	local key = GuildKey()
	if not key then
		return nil
	end
	local all = PeggleData.guildScores
	if not all[key] and create then
		all[key] = {}
	end
	return all[key]
end

------------------------------------------------------------------------------
-- Our own scores
------------------------------------------------------------------------------

local function Extra()
	return rawget(env, "PeggleExtra")
end

-- The key a level is shared under, or nil if this level id isn't installed.
function Guild:KeyFor(id)
	if id <= 12 then
		return tostring(id)
	end
	local level = Extra():Get(id)
	return level and level.key
end

-- score, flags for one of our own levels.
function Guild:OwnScore(id)
	local extra = Extra()
	return extra:Best(id, self.best) or 0, extra:Flags(id, self.best) or 0
end

-- "key=score/flags" for every level we have a score on.
function Guild:OwnEntries()
	local list = {}
	local function add(id)
		local key = self:KeyFor(id)
		local score, flags = self:OwnScore(id)
		if key and score > 0 then
			list[#list + 1] = key .. "=" .. score .. "/" .. flags
		end
	end
	for id = 1, 12 do
		add(id)
	end
	for _, level in ipairs(Extra().levels) do
		add(level.id)
	end
	return list
end

-- Our scores as a list of messages, each under the size limit.
function Guild:ScoreMessages()
	local head = "S" .. PROTOCOL .. ":" .. MyAccount() .. ":" .. MyClass() .. ":"
	local messages, body = {}, ""
	for _, entry in ipairs(self:OwnEntries()) do
		if #head + #body + #entry + 1 > MAX_MESSAGE then
			messages[#messages + 1] = head .. body
			body = ""
		end
		body = body == "" and entry or (body .. ";" .. entry)
	end
	if body ~= "" then
		messages[#messages + 1] = head .. body
	end
	return messages
end

------------------------------------------------------------------------------
-- Sending: one message at a time, so a full set of scores never trips the client's throttle
------------------------------------------------------------------------------

local net = CreateFrame("Frame")
local queue = {}
local wait = 0

local function Debug(...)
	if Guild.debug then
		print("|cFFFFDD00Peggle guild:|r", ...)
	end
end

local function Sent(result)
	-- older clients return nothing or a boolean, newer ones Enum.SendAddonMessageResult
	return result == nil or result == true or result == 0
end

net:SetScript("OnUpdate", function(_, elapsed)
	wait = wait - elapsed
	if wait > 0 or #queue == 0 then
		return
	end
	wait = SEND_INTERVAL
	local item = table.remove(queue, 1)
	if item.channel == "GUILD" and not IsInGuild() then
		return
	end
	local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, item.text, item.channel, item.target)
	Debug("sent", item.channel, item.text, ok and Sent(result) and "" or ("|cFFFF4040failed: " .. tostring(result)))
	if not (ok and Sent(result)) then
		item.tries = (item.tries or 0) + 1
		if item.tries < MAX_RETRIES then
			table.insert(queue, 1, item)
			wait = RETRY_DELAY
		end
	end
end)

local function Queue(text, channel, target)
	queue[#queue + 1] = { text = text, channel = channel, target = target }
end

-- Queues our scores for one channel, replacing any not yet sent there (they're out of date).
function Guild:SendScores(channel, target)
	for i = #queue, 1, -1 do
		local item = queue[i]
		if item.channel == channel and item.target == target and item.text:sub(1, 1) == "S" then
			table.remove(queue, i)
		end
	end
	for _, text in ipairs(self:ScoreMessages()) do
		Queue(text, channel, target)
	end
end

function Guild:BroadcastScores(force)
	if self.disabled or not self.best or not IsInGuild() then
		return
	end
	-- nothing new since we last told the guild: they already have these
	local all = table.concat(self:OwnEntries(), ";")
	if all == "" or (all == self.lastBroadcast and not force) then
		return
	end
	self.lastBroadcast = all
	self.lastGuildSend = GetTime()
	self:SendScores("GUILD")
end

function Guild:RequestScores()
	if self.disabled or not IsInGuild() then
		return
	end
	self.lastRequest = GetTime()
	Queue("R" .. PROTOCOL .. ":" .. MyAccount(), "GUILD")
	self:Refresh()
end

-- Called by Peggle.lua after a level's result is saved.
function Guild:ScoresChanged()
	if self.broadcastPending then
		return
	end
	self.broadcastPending = true
	C_Timer.After(BROADCAST_DELAY, function()
		self.broadcastPending = nil
		self:BroadcastScores()
		self:Refresh()
	end)
end

-- After logging in: tell the guild our scores and ask for theirs.
function Guild:Hello()
	if self.disabled or self.helloDone then
		return
	end
	if not IsInGuild() or not GuildKey() then
		self.waitingForGuild = true -- PLAYER_GUILD_UPDATE tries again
		return
	end
	self.waitingForGuild = nil
	self.helloDone = true
	self:RequestScores()
	self:BroadcastScores(true)
end

------------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------------

local function ParseScores(account, sender, class, body)
	local guild = GuildTable(true)
	if not guild then
		return
	end
	local player = guild[account]
	if not player then
		player = { scores = {} }
		guild[account] = player
	end
	player.name = sender -- the account's most recently seen character
	if class ~= "" then
		player.class = class
	end
	player.seen = time()
	for entry in body:gmatch("[^;]+") do
		local key, score, flags = entry:match("^(.+)=(%d+)/(%d)$")
		score = tonumber(score)
		if key and #key <= MAX_KEY and score and score <= MAX_SCORE then
			player.scores[key] = { score, tonumber(flags) }
		end
	end
end

local function OnAddonMessage(text, channel, sender)
	if Guild.disabled or not Guild.best then
		return
	end
	sender = FullName(sender)
	Debug("from", sender, text)
	local kind, version = text:sub(1, 1), text:sub(2, 2)
	if version ~= PROTOCOL then
		return
	end
	local account = text:match("^%a%d:(%x+)")
	if not account or account == MyAccount() then
		return -- our own guild messages come back to us, as do our alts' on this account
	end
	if kind == "S" then
		local class, body = text:match("^S%d:%x+:([%u_]*):(.*)$")
		if body then
			ParseScores(account, sender, class, body)
			Guild:Refresh()
		end
	elseif kind == "R" then
		-- Answer on the guild channel, not by whisper: senders arrive as "Name Surname-Realm",
		-- which isn't a name a whisper can be sent to. Answers wait a random moment, as the
		-- whole guild gets the request at once, and requests that arrive meanwhile share it.
		if Guild.replyPending then
			return
		end
		Guild.replyPending = true
		local asked = GetTime()
		C_Timer.After(1 + math.random() * (REPLY_DELAY - 1), function()
			Guild.replyPending = nil
			if not (Guild.lastGuildSend and Guild.lastGuildSend >= asked) then
				Guild:BroadcastScores(true)
			end
		end)
	end
end

net:RegisterEvent("CHAT_MSG_ADDON")
net:RegisterEvent("PLAYER_GUILD_UPDATE")
net:SetScript("OnEvent", function(_, event, prefix, text, channel, sender)
	if event == "PLAYER_GUILD_UPDATE" then
		if Guild.waitingForGuild then
			Guild:Hello()
		end
		Guild:Refresh()
		return
	end
	-- chat payloads can be secret values (e.g. in combat or instances); comparing them errors
	if issecretvalue and (issecretvalue(prefix) or issecretvalue(text) or issecretvalue(sender)) then
		return
	end
	if prefix == PREFIX and channel == "GUILD" and text and sender then
		OnAddonMessage(text, channel, sender)
	end
end)

------------------------------------------------------------------------------
-- Setup (Peggle.lua, once the saved scores are loaded)
------------------------------------------------------------------------------

-- best: Peggle.lua's score table for levels 1-12 (best[id] score, best[id + 12] flags).
function Guild:Install(best)
	self.best = best
	-- scores saved before entries were kept per account (version 1, by character name)
	if PeggleData.guildScoresVersion ~= 2 then
		PeggleData.guildScores = nil
		PeggleData.guildScoresVersion = 2
	end
	PeggleData.guildScores = PeggleData.guildScores or {}
	MyAccount()
	local cutoff = time() - FORGET_AFTER
	for key, players in pairs(PeggleData.guildScores) do
		for name, player in pairs(players) do
			if (player.seen or 0) < cutoff then
				players[name] = nil
			end
		end
		if next(players) == nil then
			PeggleData.guildScores[key] = nil
		end
	end
	C_Timer.After(HELLO_DELAY, function()
		self:Hello()
	end)
end

------------------------------------------------------------------------------
-- The leaderboard screen: the shared level list on the left, the ranking on the right
------------------------------------------------------------------------------

local function Backdrop(bgFile)
	return {
		bgFile = bgFile or "Interface\\Tooltips\\UI-Tooltip-Background",
		tile = true,
		tileSize = 128,
		edgeFile = "Interface\\Glues\\Common\\TextPanel-Border",
		edgeSize = 32,
		insets = { top = 5, right = 5, left = 5, bottom = 5 },
	}
end

-- Names without the realm: the sender's realm suffix doesn't always match our own realm's
-- spelling, so Ambiguate can't be relied on to drop it for same-realm players.
local function DisplayName(name)
	return (name:gsub("%-[^%-]*$", ""))
end

local function ClassColor(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then
		return c.r, c.g, c.b
	end
	return 1, 1, 1
end

-- Everyone with a score on a level, best first: { name, score, flags, class, seen, me }.
function Guild:Ranking(id)
	local list = {}
	local key = self:KeyFor(id)
	if not key then
		return list
	end
	local score, flags = self:OwnScore(id)
	if score > 0 then
		list[1] = { name = MyName(), score = score, flags = flags, class = MyClass(), me = true }
	end
	local guild = GuildTable()
	if guild then
		local me = MyAccount()
		for account, player in pairs(guild) do
			local s = player.scores[key]
			if s and player.name and account ~= me then
				list[#list + 1] = { name = player.name, score = s[1], flags = s[2], class = player.class, seen = player.seen }
			end
		end
	end
	table.sort(list, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.name < b.name
	end)
	-- equal scores share a rank
	for i, row in ipairs(list) do
		local prev = list[i - 1]
		row.rank = (prev and prev.score == row.score) and prev.rank or i
	end
	return list
end

local function FormatScore(n)
	local s = tostring(n)
	repeat
		local k
		s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
	until k == 0
	return s
end

local function RowEnter(row)
	local data = row.data
	if not data then
		return
	end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:AddLine(DisplayName(data.name), ClassColor(data.class))
	GameTooltip:AddLine(FormatScore(data.score), 1, 1, 1)
	if data.flags >= 3 then
		GameTooltip:AddLine(TEXT.cleared, 0.4, 0.6, 1)
	elseif data.flags >= 2 then
		GameTooltip:AddLine(TEXT.beaten, 1, 0.3, 0.3)
	end
	if data.seen and SecondsToTime then
		local ago = math.max(time() - data.seen, 60)
		GameTooltip:AddLine(TEXT.updated:format(SecondsToTime(ago, true)), 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end

local function RowLeave()
	GameTooltip:Hide()
end

-- parent: Peggle's screen container; levelList: the level list shared by the screens;
-- artPath: Peggle's image folder (for the game font and banners).
function Guild:CreateScreen(parent, levelList, artPath)
	local font = artPath .. "OVERLOAD.ttf"
	local function Caption(owner, size, r, g, b, fontFile, flags)
		local fs = owner:CreateFontString(nil, "OVERLAY")
		fs:SetFont(fontFile or font, size, flags or "OUTLINE")
		fs:SetTextColor(r, g, b)
		return fs
	end

	local screen = CreateFrame("Frame", nil, parent)
	screen:SetPoint("TopLeft", 5, -9)
	screen:SetPoint("BottomRight", -4, 4)
	screen:SetBackdrop(Backdrop())
	screen:SetBackdropColor(0, 0, 0, 0.5)
	screen:SetBackdropBorderColor(1, 1, 1)
	screen:SetFrameLevel(parent:GetFrameLevel() + 1)
	screen:Hide()
	screen.showID = 1
	screen.offset = 0
	self.screen = screen

	-- the level list calls this when a level is picked
	screen.UpdateDisplay = function(s, id)
		if id and id ~= s.showID then
			s.offset = 0
		end
		s.showID = id or s.showID
		Guild:Refresh()
	end
	screen:SetScript("OnShow", function(s)
		levelList:SetParent(s)
		levelList:UpdateList()
		levelList:Show()
		s:UpdateDisplay(s.showID)
		if not Guild.lastRequest or GetTime() - Guild.lastRequest > REQUEST_COOLDOWN then
			Guild:RequestScores()
		end
	end)

	local title = Caption(screen, 40, 0.05, 0.66, 1)
	title:SetPoint("Top", 0, -22)
	title:SetText(TEXT.title)

	-- under the level list
	local info = Caption(screen, 12, 0.8, 0.8, 0.8, STANDARD_TEXT_FONT, "")
	info:SetPoint("TopLeft", screen, "BottomLeft", 24, 92)
	info:SetWidth(292)
	info:SetJustifyH("LEFT")
	info:SetText(TEXT.info)
	local status = Caption(screen, 12, 1, 0.82, 0, STANDARD_TEXT_FONT, "")
	status:SetPoint("TopLeft", info, "BottomLeft", 0, -8)
	status:SetWidth(292)
	status:SetJustifyH("LEFT")
	screen.status = status

	-- the ranking
	local levelName = Caption(screen, 26, 1, 0.82, 0)
	levelName:SetPoint("Top", screen, "TopRight", -(20 + 275 / 2), -60)
	levelName:SetWidth(275)
	levelName:SetWordWrap(false)
	screen.levelName = levelName

	local panel = CreateFrame("Frame", nil, screen)
	panel:SetPoint("TopLeft", 340, -90)
	panel:SetPoint("BottomRight", -20, 20)
	panel:SetBackdrop(Backdrop(artPath .. "windowBackground"))
	panel:SetBackdropColor(0, 0, 0, 0.5)
	panel:SetBackdropBorderColor(1, 0.8, 0.45)
	panel:EnableMouseWheel(true)
	panel:SetScript("OnMouseWheel", function(_, delta)
		screen.offset = screen.offset - delta * 3
		Guild:Refresh()
	end)
	screen.panel = panel

	local head = Caption(panel, 13, 1, 0.82, 0, STANDARD_TEXT_FONT)
	head:SetPoint("TopLeft", 12, -12)
	head:SetText(TEXT.rank)
	head = Caption(panel, 13, 1, 0.82, 0, STANDARD_TEXT_FONT)
	head:SetPoint("TopLeft", 42, -12)
	head:SetText(TEXT.player)
	head = Caption(panel, 13, 1, 0.82, 0, STANDARD_TEXT_FONT)
	head:SetPoint("TopRight", -46, -12)
	head:SetText(TEXT.score)

	screen.rows = {}
	for i = 1, ROWS do
		local row = CreateFrame("Frame", nil, panel)
		row:SetPoint("TopLeft", 8, -30 - (i - 1) * 20)
		row:SetPoint("TopRight", -8, -30 - (i - 1) * 20)
		row:SetHeight(20)
		row:EnableMouse(true)
		row:SetScript("OnEnter", RowEnter)
		row:SetScript("OnLeave", RowLeave)
		-- wheel events go to the row under the mouse, not the panel behind it
		row:EnableMouseWheel(true)
		row:SetScript("OnMouseWheel", panel:GetScript("OnMouseWheel"))

		row.highlight = row:CreateTexture(nil, "ARTWORK")
		row.highlight:SetAllPoints()
		row.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
		row.highlight:SetVertexColor(1, 0.82, 0)
		row.highlight:SetBlendMode("ADD")
		row.highlight:SetAlpha(0.35)

		row.rank = Caption(row, 17, 1, 1, 1)
		row.rank:SetPoint("Left", 4, 0)
		row.rank:SetWidth(30)
		row.rank:SetJustifyH("LEFT")

		row.name = Caption(row, 13, 1, 1, 1, STANDARD_TEXT_FONT)
		row.name:SetPoint("Left", 34, 0)
		row.name:SetWidth(122)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)

		row.score = Caption(row, 17, 1, 1, 1)
		row.score:SetPoint("Right", -38, 0)
		row.score:SetJustifyH("RIGHT")

		row.flagA = row:CreateTexture(nil, "OVERLAY")
		row.flagA:SetSize(16, 16)
		row.flagA:SetPoint("Right", -18, 0)
		row.flagA:SetTexture(artPath .. "bannerSmallRed")
		row.flagB = row:CreateTexture(nil, "OVERLAY")
		row.flagB:SetSize(16, 16)
		row.flagB:SetPoint("Right", -2, 0)
		row.flagB:SetTexture(artPath .. "bannerSmallBlue")

		screen.rows[i] = row
	end

	local message = Caption(panel, 14, 0.8, 0.8, 0.8, STANDARD_TEXT_FONT, "")
	message:SetPoint("Center")
	message:SetWidth(220)
	screen.message = message

	local range = Caption(panel, 11, 0.7, 0.7, 0.7, STANDARD_TEXT_FONT, "")
	range:SetPoint("Bottom", 0, 10)
	screen.range = range

	return screen
end

function Guild:Refresh()
	local screen = self.screen
	if not screen or not screen:IsVisible() then
		return
	end
	local id = screen.showID
	local locale = Extra().locale
	screen.levelName:SetText(locale and locale["_LEVEL_NAME" .. id] or "")

	if self.lastRequest and GetTime() - self.lastRequest < 10 then
		screen.status:SetText(TEXT.asking)
	else
		screen.status:SetText("")
	end

	local list = IsInGuild() and self:Ranking(id) or {}
	local maxOffset = math.max(0, #list - ROWS)
	screen.offset = math.min(math.max(screen.offset or 0, 0), maxOffset)

	for i, row in ipairs(screen.rows) do
		local data = list[screen.offset + i]
		row.data = data
		if data then
			row.rank:SetText(data.rank)
			local name = DisplayName(data.name)
			row.name:SetText(data.me and (name .. " |cFFAAAAAA" .. TEXT.you .. "|r") or name)
			row.name:SetTextColor(ClassColor(data.class))
			row.score:SetText(FormatScore(data.score))
			row.flagA:SetShown(data.flags >= 2)
			row.flagB:SetShown(data.flags >= 3)
			row.highlight:SetShown(data.me == true)
			row:Show()
		else
			row:Hide()
		end
	end

	if not IsInGuild() then
		screen.message:SetText(TEXT.noGuild)
	elseif #list == 0 then
		screen.message:SetText(TEXT.empty)
	else
		screen.message:SetText("")
	end
	if #list > ROWS then
		screen.range:SetFormattedText(TEXT.range, screen.offset + 1, math.min(screen.offset + ROWS, #list), #list)
	else
		screen.range:SetText("")
	end
	-- the countdown on the "asking" line
	if screen.status:GetText() ~= "" and not self.statusTimer then
		self.statusTimer = true
		C_Timer.After(10, function()
			self.statusTimer = nil
			self:Refresh()
		end)
	end
end

------------------------------------------------------------------------------
-- /peggleguild: what the leaderboard knows, for testing. "/peggleguild debug" prints every
-- message sent and received; "/peggleguild ask" asks the guild for scores now.
------------------------------------------------------------------------------

SLASH_PEGGLEGUILD1 = "/peggleguild"
SlashCmdList["PEGGLEGUILD"] = function(arg)
	arg = (arg or ""):lower()
	if arg == "debug" then
		Guild.debug = not Guild.debug
		print("|cFFFFDD00Peggle guild:|r debug " .. (Guild.debug and "on" or "off"))
		return
	elseif arg == "ask" then
		Guild:RequestScores()
		Guild:BroadcastScores(true)
		return
	end
	local guild = PeggleData.guildScores and GuildTable()
	print("|cFFFFDD00Peggle guild:|r account " .. tostring(PeggleData.guildAccount) .. ", guild " .. tostring(GuildKey())
		.. ", " .. #queue .. " message(s) queued")
	for account, player in pairs(guild or {}) do
		local n = 0
		for _ in pairs(player.scores) do
			n = n + 1
		end
		print("  " .. tostring(player.name) .. " (" .. account .. "): " .. n .. " level(s)")
	end
end
