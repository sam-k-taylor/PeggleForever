-- Extra levels from level packs: separate addons that call PeggleForever_RegisterLevelPack.
--
-- The original game has 12 levels whose best scores and talent flags live in the packed,
-- checksummed PeggleData.data string, so extra levels keep their own records in
-- PeggleData.extraLevels (keyed by "<pack id>:<level key>", so installing or removing packs
-- never moves a score to another level) and never award talent points. Pack levels can be
-- played in Quick Play and in duels; duel invites name the level by key (see Ref), and the
-- opponent's game declines with a reason if it doesn't have the same pack. Battles and Peggle
-- Loot stay on levels 1-12.
--
-- Peggle.lua's main chunk has no free local slots, so the game-side helpers live in the
-- addon environment (see Compat.lua) where Peggle.lua finds them as PeggleExtra.
--
-- A level pack (with ## Dependencies: PeggleForever in its .toc) registers like this:
--
--   PeggleForever_RegisterLevelPack({
--       id = "wow",                                   -- unique, used in saved progress
--       title = "World of Warcraft",                  -- shown in the level pack menu
--       art = "Interface\\AddOns\\MyPack\\images\\",  -- folder holding the level images
--       levels = {
--           -- data: the level's object stream (tools/levelconv in PeggleForever_WoWLevels)
--           -- images: <art><key>.tga (512x512 background), <art><key>_thumb.tga (128x128)
--           { key = "hogger", name = "Wanted: Hogger", data = "..." },
--       },
--   })
--
-- Pack and level keys may not contain "+" or "@" (they travel in duel invites).

local _, ns = ...

local FIRST_ID = 13
local LAST_ID = 69 -- level ids are stored as one base-70 digit
local ROWS = 12

local Extra = {
	levels = {}, -- by id - 12: { id, key, name, data, hash, art, pack }
	packs = {}, -- by pack id
	byKey = {}, -- "<pack>:<key>" -> level
}
rawset(ns.env, "PeggleExtra", Extra)

local function IdChar(id)
	if id < 27 then
		return string.char(96 + id)
	end
	return string.char(48 + id - 27)
end

-- Short fingerprint of a level's data, so duels only start when both players have the same
-- version of the level (peg colours are sent as indexes into the level's objects).
local function Hash(s)
	local h = 0
	for i = 1, #s do
		h = (h * 31 + s:byte(i)) % 16777213
	end
	return tostring(h)
end

-- Adds one level to the game's level table (once Install has run).
local function AddToGame(level)
	if Extra.levelTable then
		Extra.levelTable[level.id] = IdChar(level.id) .. level.data
		Extra.locale["_LEVEL_NAME" .. level.id] = level.name
	end
end

local function Fail(pack, msg)
	print("|cFFFF4040Peggle Forever:|r level pack " .. tostring(pack and pack.id) .. ": " .. msg)
end

local function BadKey(k)
	return type(k) ~= "string" or k == "" or k:find("[%+@]")
end

function PeggleForever_RegisterLevelPack(pack)
	if type(pack) ~= "table" or BadKey(pack.id) or type(pack.levels) ~= "table" then
		return Fail(pack, "needs an id (without + or @) and a levels table")
	end
	if Extra.packs[pack.id] then
		return Fail(pack, "is already registered")
	end
	Extra.packs[pack.id] = pack
	pack.title = pack.title or pack.id
	for _, l in ipairs(pack.levels) do
		local id = FIRST_ID + #Extra.levels
		if id > LAST_ID then
			Fail(pack, "too many extra levels installed (the game supports " .. (LAST_ID - FIRST_ID + 1) .. ")")
			break
		end
		if BadKey(l.key) or type(l.data) ~= "string" or l.data == "" then
			Fail(pack, "level " .. tostring(l.key) .. " has no usable key or data, skipped")
		else
			local level = {
				id = id,
				key = pack.id .. ":" .. l.key,
				name = l.name or l.key,
				data = l.data,
				hash = Hash(l.data),
				art = (pack.art or "") .. l.key,
				pack = pack,
			}
			Extra.levels[id - FIRST_ID + 1] = level
			Extra.byKey[level.key] = level
			AddToGame(level)
		end
	end
	Extra.sections = nil
end

-- Called by Peggle.lua once its own levels are loaded (VARIABLES_LOADED, after every addon has
-- loaded, so packs are normally registered by then; later ones are added as they come).
function Extra:Install(levelTable, locale)
	self.levelTable = levelTable
	self.locale = locale
	self.sections = nil
	PeggleData.extraLevels = PeggleData.extraLevels or {}
	for _, level in ipairs(self.levels) do
		AddToGame(level)
	end
	-- Scores from before levels were saved by key (ids 13+ in registration order).
	local old = PeggleData.extraBest
	if old then
		for _, level in ipairs(self.levels) do
			if old[level.id] then
				local rec = self:Record(level.id)
				rec.best = math.max(rec.best or 0, old[level.id])
				rec.flags = math.max(rec.flags or 0, 1) -- played; old saves didn't record wins
			end
		end
		PeggleData.extraBest = nil
	end
end

function Extra:Get(id)
	return id and self.levels[id - FIRST_ID + 1]
end

function Extra:Count()
	return #self.levels
end

function Extra:IsExtra(id)
	return id ~= nil and id >= FIRST_ID
end

-- Saved progress for an extra level: { best = score, flags = 1 played, 2 beaten, 3 cleared }.
function Extra:Record(id)
	local level = self:Get(id)
	if not level then
		return {}
	end
	PeggleData.extraLevels = PeggleData.extraLevels or {}
	local rec = PeggleData.extraLevels[level.key]
	if not rec then
		rec = {}
		PeggleData.extraLevels[level.key] = rec
	end
	return rec
end

-- Best score for any level; `best` is Peggle.lua's table for levels 1-12.
function Extra:Best(id, best)
	if not self:IsExtra(id) then
		return best[id]
	end
	return self:Record(id).best or 0
end

-- Completion flags for any level (0 none, 1 played, 2 beaten, 3 all pegs cleared).
function Extra:Flags(id, best)
	if not self:IsExtra(id) then
		return best[id + 12]
	end
	return self:Record(id).flags or 0
end

-- Records a finished extra level, as Peggle.lua's save does for levels 1-12: keeps the best
-- score and the highest completion flag.
function Extra:SaveBest(id, score, flags)
	local rec = self:Record(id)
	if score and score > (rec.best or 0) then
		rec.best = score
	end
	if flags and flags > (rec.flags or 0) then
		rec.flags = flags
	end
end

-- Key for PeggleProfile.levelTracking (duel wins/losses per level): the level number for
-- levels 1-12, the level key for pack levels (their numbers depend on load order).
function Extra:TrackingKey(id)
	local level = self:IsExtra(id) and self:Get(id)
	return level and level.key or id
end

-- Texture paths. Levels 1-12 use the addon's own bg<id>.tga.
function Extra:Background(id, artPath)
	local level = self:IsExtra(id) and self:Get(id)
	return level and level.art or (artPath .. "bg" .. id)
end

function Extra:Thumbnail(id, artPath)
	return self:Background(id, artPath) .. "_thumb"
end

------------------------------------------------------------------------------
-- Duels
------------------------------------------------------------------------------

-- What a duel invite sends for a pack level: "<pack>:<key>@<hash>".
function Extra:Ref(id)
	local level = self:Get(id)
	return level.key .. "@" .. level.hash
end

-- The local level id for a received Ref, or nil and the reason ("missing" or "version").
function Extra:Resolve(ref)
	local key, hash = strsplit("@", ref or "")
	local level = self.byKey[key]
	if not level then
		return nil, "missing"
	end
	if level.hash ~= hash then
		return nil, "version"
	end
	return level.id
end

-- Used if the game's text table doesn't have these (keys must start with "_": Peggle.lua frees
-- every other entry once its UI is built).
local DUEL_TEXT = {
	_DUEL_PACK_MISSING = "%s doesn't have the %s level pack.",
	_DUEL_PACK_VERSION = "%s has a different version of the %s level pack.",
	_DUEL_PACK_NOANSWER = "No answer from %s. They need the latest Peggle Forever and the %s level pack.",
}

-- Duel status text for pack invites. reason: "missing", "version" (from the opponent's reply)
-- or "noanswer" (no reply: an older Peggle Forever, which ignores pack invites).
function Extra:DuelText(reason, name, id)
	local level = self:Get(id)
	local title = level and level.pack.title or "?"
	local key = "_DUEL_PACK_" .. string.upper(reason or "missing")
	local fmt = (self.locale and self.locale[key]) or DUEL_TEXT[key] or DUEL_TEXT._DUEL_PACK_MISSING
	return string.format(fmt, name or "", title)
end

------------------------------------------------------------------------------
-- Level list sections: the original game, then each pack (12 levels per section)
------------------------------------------------------------------------------

function Extra:Sections()
	if not self.sections then
		local list = { { title = self.locale and self.locale["_LEVELS_ORIGINAL"] or "Original", ids = {} } }
		for id = 1, 12 do
			list[1].ids[id] = id
		end
		local current
		for _, level in ipairs(self.levels) do
			if not current or current.pack ~= level.pack or #current.ids == ROWS then
				current = { pack = level.pack, title = level.pack.title, ids = {} }
				table.insert(list, current)
			end
			table.insert(current.ids, level.id)
		end
		-- number the parts of packs that need more than one section
		local parts = {}
		for _, s in ipairs(list) do
			if s.pack then
				parts[s.pack] = (parts[s.pack] or 0) + 1
				s.part = parts[s.pack]
			end
		end
		for _, s in ipairs(list) do
			if s.pack and parts[s.pack] > 1 then
				s.title = string.format("%s (%d/%d)", s.title, s.part, parts[s.pack])
			end
		end
		self.sections = list
	end
	return self.sections
end

function Extra:SectionOf(id)
	for i, s in ipairs(self:Sections()) do
		for _, sid in ipairs(s.ids) do
			if sid == id then
				return i
			end
		end
	end
	return 1
end

-- The "level pack" drop-down above the level list. `list` is Peggle.lua's level list frame;
-- the section shown is kept per screen (Quick Play and Duel), in screen.levelSection.
function Extra:InitPackMenu(dropdown, list)
	local function Select(_, section)
		list:GetParent().levelSection = section
		list:UpdateList()
		CloseDropDownMenus()
	end
	UIDropDownMenu_Initialize(dropdown, function()
		local current = list:GetParent().levelSection or 1
		for i, s in ipairs(Extra:Sections()) do
			local info = {}
			info.text = s.title
			info.arg1 = i
			info.func = Select
			info.checked = (i == current)
			info.fontObject = dropdown.fontObject
			UIDropDownMenu_AddButton(info)
		end
	end)
end
