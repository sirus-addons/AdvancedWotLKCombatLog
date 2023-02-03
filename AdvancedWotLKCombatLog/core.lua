local ADDON_NAME, PRIVATE_NS = ...

local _G = _G
local date = date
local pairs = pairs
local time = time
local unpack = unpack
local strconcat = strconcat
local strfind = string.find
local strformat = string.format
local strjoin = string.join
local strlen = string.len
local strmatch = string.match
local strsplit = string.split
local strsub = string.sub
local tconcat, tinsert = table.concat, table.insert

local CanInspect = CanInspect
local GetArenaTeam = GetArenaTeam
local GetCurrentMapAreaID = GetCurrentMapAreaID
local GetGuildInfo = GetGuildInfo
local GetInspectArenaTeamData = GetInspectArenaTeamData
local GetInstanceInfo = GetInstanceInfo
local GetInventoryItemLink = GetInventoryItemLink
local GetNumPartyMembers = GetNumPartyMembers
local GetNumRaidMembers = GetNumRaidMembers
local GetNumSavedInstances = GetNumSavedInstances
local GetNumTalents = GetNumTalents
local GetSavedInstanceInfo = GetSavedInstanceInfo
local GetTalentInfo = GetTalentInfo
local IsInInstance = IsInInstance
local UnitClass = UnitClass
local UnitExists = UnitExists
local UnitGUID = UnitGUID
local UnitIsPlayer = UnitIsPlayer
local UnitName = UnitName
local UnitRace = UnitRace
local UnitIsUnit = UnitIsUnit
local UnitSex = UnitSex

local UNKNOWN = UNKNOWN

-- GLOBALS: DEFAULT_CHAT_FRAME, ClearInspectPlayer, LoggingCombat, SlashCmdList

local MESSAGE_LIMITER = {}
local NUM_MESSAGES_PER_MINUTE = 60
local MESSAGE_LIMITER_WIPE_INTERVAL = 60
local MESSAGE_LIMITER_LAST_WIPE = 0

local function valueOrNil(val)
	if val == nil then
		return "nil"
	end
	return val
end

local RPLL = CreateFrame("Frame")
RPLL.VERSION = 35
RPLL.MAX_MESSAGE_LENGTH = 300
RPLL.MESSAGE_PREFIX = "RPLL_H_"
RPLL.MESSAGE_PREFIX_LEN = strlen(RPLL.MESSAGE_PREFIX)
RPLL.CONSOLIDATE_CHARACTER = "{"

RPLL.PlayerInformation = {}
RPLL.PlayerRotation = {}
RPLL.RotationLength = 0
RPLL.RotationIndex = 1
RPLL.ExtraMessages = {}
RPLL.ExtraMessageLength = 0
RPLL.ExtraMessageIndex = 1
RPLL.Synchronizers = {}

RPLL:SetScript("OnEvent", function(self, event, ...)
	self:OnEvent(event, ...)
end)
RPLL:SetScript("OnUpdate", function(self, elapsed)
	self:OnUpdate(elapsed)
end)

do	-- Register events
	RPLL:RegisterEvent("ADDON_LOADED")
	RPLL:RegisterEvent("PLAYER_LOGOUT")
	RPLL:RegisterEvent("PLAYER_ENTERING_WORLD")
	RPLL:RegisterEvent("CHAT_MSG_ADDON")

	RPLL:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
	RPLL:RegisterEvent("PLAYER_TARGET_CHANGED")
	RPLL:RegisterEvent("PLAYER_PET_CHANGED")
	RPLL:RegisterEvent("PET_STABLE_CLOSED")
	RPLL:RegisterEvent("UNIT_INVENTORY_CHANGED")
	RPLL:RegisterEvent("UNIT_PET")
	RPLL:RegisterEvent("UNIT_ENTERED_VEHICLE")
	RPLL:RegisterEvent("RAID_ROSTER_UPDATE")
	RPLL:RegisterEvent("PARTY_MEMBERS_CHANGED")

	RPLL:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	RPLL:RegisterEvent("UPDATE_INSTANCE_INFO")
	RPLL:RegisterEvent("PLAYER_REGEN_ENABLED")
	RPLL:RegisterEvent("PLAYER_DIFFICULTY_CHANGED")

	RPLL:RegisterEvent("CHAT_MSG_LOOT")

	RPLL:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	RPLL:RegisterEvent("INSPECT_TALENT_READY")
end

local eventToUnit = {
	PLAYER_PET_CHANGED = "player",
	PET_STABLE_CLOSED = "player",
	PLAYER_TARGET_CHANGED = "target",
	UPDATE_MOUSEOVER_UNIT = "mouseover",
}

function RPLL:OnEvent(event, ...)
	if event == "UPDATE_MOUSEOVER_UNIT" or event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_PET_CHANGED" or event == "PET_STABLE_CLOSED" then
		self:CollectUnit(eventToUnit[event])
	elseif event == "UNIT_INVENTORY_CHANGED" or event == "UNIT_PET" or event == "UNIT_ENTERED_VEHICLE" then
		self:CollectUnit(...)
	elseif event == "RAID_ROSTER_UPDATE" then
		self:CollectRaidUnits()
	elseif event == "PARTY_MEMBERS_CHANGED" then
		self:CollectPartyUnits()
	elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_DIFFICULTY_CHANGED" then
		self:PushCurrentInstanceInfo()
	elseif event == "ZONE_CHANGED_NEW_AREA" or event == "UPDATE_INSTANCE_INFO" then
		LoggingCombat(IsInInstance("player"))
		self:PushCurrentInstanceInfo()
	elseif event == "INSPECT_TALENT_READY" then
		self:CollectCurrentTalentsAndArenaTeams()
	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		local timestamp, clEvent = ...
		if clEvent == "SPELL_CAST_FAILED" then
			self:RotateSpellFailedMessages()
		end
	elseif event == "CHAT_MSG_LOOT" then
		self:ProcessLootMessage(...)
	elseif event == "CHAT_MSG_ADDON" then
		self:ProcessAddonMessage(...)
	elseif event == "PLAYER_ENTERING_WORLD" then
		self:UnregisterEvent(event)

		UIErrorsFrame:UnregisterEvent("UI_ERROR_MESSAGE")

		self:SendMessage(strformat("LegacyPlayers collector v%s has been loaded. Type /rpll for help.", self.VERSION))

		self:CollectUnit("player")
		self:CollectRaidUnits()
		self:CollectPartyUnits()
	elseif event == "ADDON_LOADED" then
		if ... == ADDON_NAME then
			self:UnregisterEvent(event)

			if not RPLL_PlayerInformation then
				RPLL_PlayerInformation = {}
			else
				self.PlayerInformation = RPLL_PlayerInformation

				local index = 0
				for guid in pairs(self.PlayerInformation) do
					index = index + 1
					self.PlayerRotation[index] = guid
				end

				self.RotationLength = index
			end

			SLASH_rpll1 = "/rpll"
			SLASH_rpll2 = "/RPLL"
			SlashCmdList["rpll"] = self.HandleSlashCommand
		end
	elseif event == "PLAYER_LOGOUT" then
		RPLL_PlayerInformation = self.PlayerInformation
	end
end

local INSPECT_QUEUE = {}
local INSPECT_QUEUE_LENGTH = 0
local INSPECT_QUEUE_INDEX = 1
local INSPECT_QUEUE_LAST_INSPECT = 0
local INSPECT_TIMEOUT = 3 -- 3 seconds
local INSPECT_IN_PROGRESS
function RPLL:OnUpdate(elapsed)
	-- Suppress Addon Error frame
	if StaticPopup1 and StaticPopup1:IsShown() then
		local text = StaticPopup1.text:GetText()
		if text and strfind(text, "AdvancedWotLKCombatLog", 1, true) then
			StaticPopup1:Hide()
		end
	end

	local now = time()

	if INSPECT_QUEUE_LENGTH >= INSPECT_QUEUE_INDEX then
		if not INSPECT_IN_PROGRESS or now - INSPECT_QUEUE_LAST_INSPECT >= INSPECT_TIMEOUT then
			INSPECT_IN_PROGRESS = true
			INSPECT_QUEUE_LAST_INSPECT = now
			NotifyInspect(INSPECT_QUEUE[INSPECT_QUEUE_INDEX][1])
			INSPECT_QUEUE_INDEX = INSPECT_QUEUE_INDEX + 1
		end
	end

	if now - MESSAGE_LIMITER_LAST_WIPE >= MESSAGE_LIMITER_WIPE_INTERVAL then
		MESSAGE_LIMITER_LAST_WIPE = now
		MESSAGE_LIMITER = {}
	end
end

function RPLL:SendMessage(...)
	DEFAULT_CHAT_FRAME:AddMessage(strconcat("|cFFFF8080LegacyPlayers|r: ", ...))
end

function RPLL.HandleSlashCommand(msg, ...)
	if msg == "nuke" then
		RPLL_PlayerInformation = {}
		RPLL.PlayerInformation = {}
		RPLL.PlayerRotation = {}
		RPLL.RotationLength = 0
		RPLL.RotationIndex = 1
		RPLL.ExtraMessages = {}
		RPLL.ExtraMessageLength = 0
		RPLL.ExtraMessageIndex = 1
		RPLL:SendMessage("Log nuked")
		RPLL:CollectUnit("player")
		RPLL:RAID_ROSTER_UPDATE()
		RPLL:PARTY_MEMBERS_CHANGED()
	else
		RPLL:SendMessage("LegacyPlayers: To nuke a log type: /rpll nuke!");
	end
end

function RPLL:FindUnitGUID(name)
	for key, val in pairs(self.PlayerInformation) do
		if val["unit_name"] == name then
			return key
		end
	end
	return nil
end

function RPLL:GetPlayerInfo(guid, create)
	local pinfo = self.PlayerInformation[guid]
	if not create then
		return pinfo
	end

	if not pinfo then
		pinfo = {}
		self.PlayerInformation[guid] = pinfo
	end

	if not pinfo["gear"] then
		pinfo["gear"] = {}
	end
	if not pinfo["arena_teams"] then
		pinfo["arena_teams"] = {}
	end

	return pinfo
end

function RPLL:ProcessAddonMessage(prefix, msg, channel, sender)
	if strsub(prefix, 1, self.MESSAGE_PREFIX_LEN) == self.MESSAGE_PREFIX then
		self.Synchronizers[sender] = true

		if MESSAGE_LIMITER[sender] == nil then
			MESSAGE_LIMITER[sender] = 1
		else
			MESSAGE_LIMITER[sender] = MESSAGE_LIMITER[sender] + 1
		end
		if MESSAGE_LIMITER[sender] > NUM_MESSAGES_PER_MINUTE then
			return
		end

		local msgType = strsub(prefix, self.MESSAGE_PREFIX_LEN + 1)

		if msgType == "LOOT" then
			tinsert(self.ExtraMessages, strformat("LOOT: %s&%s", date("%d.%m.%y %H:%M:%S"), msg))
			self.ExtraMessageLength = self.ExtraMessageLength + 1
		elseif msgType == "PET" then
			tinsert(self.ExtraMessages, strformat("PET_SUMMON: %s&%s", date("%d.%m.%y %H:%M:%S"), msg))
			self.ExtraMessageLength = self.ExtraMessageLength + 1
		elseif msgType == "CBT_I_1" then
			local guid, name, race, class, gender, guildName, guildRankName, guildRankIndex = strsplit("&", msg)
			if name == "nil" or race == "nil" or class == "nil" or gender == "nil" then
				return
			end

			local unitGUID = self:FindUnitGUID(sender)
			if unitGUID then
				guid = unitGUID
			end
			if guid == "nil" then
				return
			end

			local pinfo = self:GetPlayerInfo(guid, true)

			pinfo["last_updated"] = date("%d.%m.%y %H:%M:%S")
			pinfo["last_updated_time"] = time()
			pinfo["unit_guid"] = guid
			pinfo["unit_name"] = sender
			pinfo["race"] = race
			pinfo["hero_class"] = class
			pinfo["gender"] = gender

			if guildName ~= "nil" then
				pinfo["guild_name"] = guildName
				pinfo["guild_rank_name"] = guildRankName
				pinfo["guild_rank_index"] = guildRankIndex
			end

			if not self:PlayerIsQueued(guid) then
				tinsert(self.PlayerRotation, sender)
				self.RotationLength = self.RotationLength + 1
			end
		elseif msgType == "CBT_I_2" then
			local guid, talents, team1, team2, team3 = strsplit("&", msg)
			if talents == "nil" then
				return
			end

			local unitGUID = self:FindUnitGUID(sender)
			if unitGUID then
				guid = unitGUID
			end
			if guid == "nil" then
				return
			end

			local pinfo = self:GetPlayerInfo(guid, true)

			pinfo["last_updated"] = date("%d.%m.%y %H:%M:%S")
			pinfo["last_updated_time"] = time()
			pinfo["unit_guid"] = guid
			pinfo["talents"] = talents

			if team1 ~= "nil" then
				pinfo["arena_teams"][2] = team1
			end
			if team2 ~= "nil" then
				pinfo["arena_teams"][3] = team2
			end
			if team3 ~= "nil" then
				pinfo["arena_teams"][5] = team3
			end

			if not self:PlayerIsQueued(guid) then
				tinsert(self.PlayerRotation, sender)
				self.RotationLength = self.RotationLength + 1
			end
		elseif msgType == "CBT_I_3" then
			local guid, gearStr = strsplit("&", msg)
			if gearStr == "nil" then
				return
			end

			local unitGUID = self:FindUnitGUID(sender)
			if unitGUID then
				guid = unitGUID
			end
			if guid == "nil" then
				return
			end

			local pinfo = self:GetPlayerInfo(guid, true)

			pinfo["last_updated"] = date("%d.%m.%y %H:%M:%S")
			pinfo["last_updated_time"] = time()
			pinfo["unit_guid"] = guid

			local g1, g2, g3, g4, g5 = strsplit("}", gearStr)
			if g1 ~= "nil" then
				pinfo["gear"][1] = g1
			end
			if g2 ~= "nil" then
				pinfo["gear"][2] = g2
			end
			if g3 ~= "nil" then
				pinfo["gear"][3] = g3
			end
			if g4 ~= "nil" then
				pinfo["gear"][4] = g4
			end
			if g5 ~= "nil" then
				pinfo["gear"][5] = g5
			end

			if not self:PlayerIsQueued(guid) then
				tinsert(self.PlayerRotation, sender)
				self.RotationLength = self.RotationLength + 1
			end
		elseif msgType == "CBT_I_4" then
			local guid, gearStr = strsplit("&", msg)
			if gearStr == "nil" then
				return
			end

			local unitGUID = self:FindUnitGUID(sender)
			if unitGUID then
				guid = unitGUID
			end
			if guid == "nil" then
				return
			end

			local pinfo = self:GetPlayerInfo(guid, true)

			pinfo["last_updated"] = date("%d.%m.%y %H:%M:%S")
			pinfo["last_updated_time"] = time()
			pinfo["unit_guid"] = guid

			local g6, g7, g8, g9, g10 = strsplit("}", gearStr)
			if g6 ~= "nil" then
				pinfo["gear"][6] = g6
			end
			if g7 ~= "nil" then
				pinfo["gear"][7] = g7
			end
			if g8 ~= "nil" then
				pinfo["gear"][8] = g8
			end
			if g9 ~= "nil" then
				pinfo["gear"][9] = g9
			end
			if g10 ~= "nil" then
				pinfo["gear"][10] = g10
			end

			if not self:PlayerIsQueued(guid) then
				tinsert(self.PlayerRotation, sender)
				self.RotationLength = self.RotationLength + 1
			end
		elseif msgType == "CBT_I_5" then
			local guid, gearStr = strsplit("&", msg)
			if gearStr == "nil" then
				return
			end

			local unitGUID = self:FindUnitGUID(sender)
			if unitGUID then
				guid = unitGUID
			end
			if guid == "nil" then
				return
			end

			local pinfo = self:GetPlayerInfo(guid, true)

			pinfo["last_updated"] = date("%d.%m.%y %H:%M:%S")
			pinfo["last_updated_time"] = time()
			pinfo["unit_guid"] = guid

			local g11, g12, g13, g14, g15 = strsplit("}", gearStr)
			if g11 ~= "nil" then
				pinfo["gear"][11] = g11
			end
			if g12 ~= "nil" then
				pinfo["gear"][12] = g12
			end
			if g13 ~= "nil" then
				pinfo["gear"][13] = g13
			end
			if g14 ~= "nil" then
				pinfo["gear"][14] = g14
			end
			if g15 ~= "nil" then
				pinfo["gear"][15] = g15
			end

			if not self:PlayerIsQueued(guid) then
				tinsert(self.PlayerRotation, sender)
				self.RotationLength = self.RotationLength + 1
			end
		elseif msgType == "CBT_I_6" then
			local guid, gearStr = strsplit("&", msg)
			if gearStr == "nil" then
				return
			end

			local unitGUID = self:FindUnitGUID(sender)
			if unitGUID then
				guid = unitGUID
			end
			if guid == "nil" then
				return
			end

			local pinfo = self:GetPlayerInfo(guid, true)

			pinfo["last_updated"] = date("%d.%m.%y %H:%M:%S")
			pinfo["last_updated_time"] = time()
			pinfo["unit_guid"] = guid

			local g16, g17, g18, g19 = strsplit("}", gearStr)
			if g16 ~= "nil" then
				pinfo["gear"][16] = g16
			end
			if g17 ~= "nil" then
				pinfo["gear"][17] = g17
			end
			if g18 ~= "nil" then
				pinfo["gear"][18] = g18
			end
			if g19 ~= "nil" then
				pinfo["gear"][19] = g19
			end

			if not self:PlayerIsQueued(guid) then
				tinsert(self.PlayerRotation, sender)
				self.RotationLength = self.RotationLength + 1
			end
		end
	end
end

function RPLL:ContainsSynchronizer(msg)
	if msg == nil then
		return true
	end

	for key, val in pairs(RPLL.Synchronizers) do
		if strfind(msg, key) ~= nil then
			return true
		end
	end
	return false
end

function RPLL:UpdatePlayer(guid, name, race, class, gender, guildName, guildRankName, guildRankIndex)
	if not guid or not name then
		return
	end

	local pinfo = self:GetPlayerInfo(guid, true)
	pinfo["unit_guid"] = guid
	pinfo["unit_name"] = name
	pinfo["last_updated"] = date("%d.%m.%y %H:%M:%S")

	if race then
		pinfo["race"] = race
	end

	if class then
		pinfo["hero_class"] = class
	end

	if gender then
		pinfo["gender"] = gender
	end

	if guildName and guildRankName then
		pinfo["guild_name"] = guildName
		pinfo["guild_rank_name"] = guildRankName
		pinfo["guild_rank_index"] = guildRankIndex
	end

	if not RPLL:PlayerIsQueued(guid) then
		tinsert(RPLL.PlayerRotation, guid)
		RPLL.RotationLength = RPLL.RotationLength + 1
	end
end

function RPLL:CollectGear(unit)
	local guid = UnitGUID(unit)
	local pinfo = self:GetPlayerInfo(guid)
	if not pinfo then return end

	local gear = {}
	for i = 1, 19 do
		local itemLink = GetInventoryItemLink(unit, i)
		if itemLink then
			local linkData = strmatch(itemLink, "item:([^\124]+)")
			if linkData then
				gear[i] = linkData
			end
		end
	end

	if next(gear) then
		pinfo["gear"] = gear
	end

	if not RPLL:PlayerIsQueued(guid) then
		tinsert(RPLL.PlayerRotation, guid)
		RPLL.RotationLength = RPLL.RotationLength + 1
	end
end

function RPLL:CollectCurrentTalentsAndArenaTeams()
	if INSPECT_QUEUE_INDEX - 1 > INSPECT_QUEUE_LENGTH then
		return
	end

	local inspectData = INSPECT_QUEUE[INSPECT_QUEUE_INDEX - 1]
	local unit, guid = inspectData[1], inspectData[2]

	if guid ~= UnitGUID(unit) then return end

	local pinfo = self:GetPlayerInfo(guid)
	if not pinfo then return end

	local playerGUID = UnitGUID("player")

	do	-- Talents
		local index = 1
		local talents = {}
		for tabIndex = 1, 3 do
			local numTalents = GetNumTalents(tabIndex, guid ~= playerGUID)
			for talentIndex = 1, numTalents do
				local name, _, _, _, curRank = GetTalentInfo(tabIndex, talentIndex, guid ~= playerGUID)
				talents[index] = name and curRank or "0"
				index = index + 1
			end
			if tabIndex ~= 3 then
				talents[index] = "}"
				index = index + 1
			end
		end

		if index > 10 then
			pinfo["talents"] = tconcat(talents, "")
		end
	end

	do	-- Arena teams
		table.wipe(pinfo["arena_teams"])

		for i = 1, 3 do
			local teamName, teamSize
			if guid == playerGUID then
				teamName, teamSize = GetArenaTeam(i)
			else
				teamName, teamSize = GetInspectArenaTeamData(i)
			end

			if teamName and teamSize then
				pinfo["arena_teams"][teamSize] = teamName
			end
		end
	end

	INSPECT_IN_PROGRESS = nil
	ClearInspectPlayer()

	if not RPLL:PlayerIsQueued(guid) then
		tinsert(RPLL.PlayerRotation, guid)
		RPLL.RotationLength = RPLL.RotationLength + 1
	end
end

function RPLL:PlayerIsQueued(guid)
	for i = RPLL.RotationIndex, RPLL.RotationLength do
		if RPLL.PlayerRotation[i] == guid then
			return true
		end
	end
	return false
end

function RPLL:CollectPartyUnits()
	for i = 1, GetNumPartyMembers() do
		if UnitExists("party" .. i) then
			self:CollectUnit("party" .. i)
		end
	end
end

function RPLL:CollectRaidUnits()
	for i = 1, GetNumRaidMembers() do
		if UnitExists("raid" .. i) then
			self:CollectUnit("raid" .. i)
		end
	end
end

function RPLL:CollectUnit(unit)
	if not UnitIsPlayer(unit) then
		return
	end

	local unitGUID = UnitGUID(unit)
	if unitGUID and unitGUID == UnitGUID("player") then
		unit = "player"
	end

	local unitName = UnitName(unit)
	if unitName == UNKNOWN then
		return
	end

	if RPLL:ContainsSynchronizer(unitName) then
		return
	end

	if CanInspect(unit) then
		tinsert(INSPECT_QUEUE, {unit, unitGUID})
		INSPECT_QUEUE_LENGTH = INSPECT_QUEUE_LENGTH + 1
	end

	local _, unitRace = UnitRace(unit)
	local _, unitClass = UnitClass(unit)
	local unit_gender = UnitSex(unit)
	local guildName, guildRankName, guildRankIndex = GetGuildInfo(unit)

	RPLL:PushPet(unit)
	RPLL:UpdatePlayer(unitGUID, unitName, unitRace, unitClass, unit_gender, guildName, guildRankName, guildRankIndex)
	RPLL:CollectGear(unit)
end

function RPLL:PushCurrentInstanceInfo()
	local name, instanceType, difficultyIndex, difficultyName, maxPlayers, playerDifficulty = GetInstanceInfo()

	if not instanceType or instanceType == "none" then
		RPLL:PushExtraMessage("NONE_ZONE_INFO", "")
		return
	end

	--	RequestRaidInfo() -> UPDATE_INSTANCE_INFO
	local instanceID
	for i = 1, GetNumSavedInstances() do
		local savedInstanceName, savedInstanceID, _, _, _, _, _, _, _, savedInstanceDifficultyName = GetSavedInstanceInfo(i)
		if name == savedInstanceName and difficultyName == savedInstanceDifficultyName then
			instanceID = savedInstanceID
			break
		end
	end

	local guids = {}
	guids[#guids + 1] = UnitGUID("player")

	for i = 1, GetNumRaidMembers() do
		if UnitExists("raid" .. i) then
			guids[#guids + 1] = UnitGUID("raid" .. i)
		end
	end

	for i = 1, GetNumPartyMembers() do
		if UnitExists("party" .. i) then
			guids[#guids + 1] = UnitGUID("party" .. i)
		end
	end

	RPLL:PushExtraMessage("ZONE_INFO", strjoin("&", name, instanceType, difficultyIndex, difficultyName, maxPlayers, playerDifficulty, GetCurrentMapAreaID(), valueOrNil(instanceID), unpack(guids)))
end

function RPLL:PushPet(unit)
	if not IsInInstance() then
		return
	end

	local petGUID
	if unit == "player" then
		petGUID = UnitGUID("pet")
	elseif strsub(unit, 1, 4) == "raid" then
		petGUID = UnitGUID("raidpet" .. strsub(unit, 5))
	elseif strsub(unit, 1, 5) == "party" then
		petGUID = UnitGUID("partypet" .. strsub(unit, 6))
	end

	if not petGUID then
		return
	end

	RPLL:PushExtraMessage("PET_SUMMON", strjoin("&", UnitGUID(unit), petGUID))
end

local CHAT_LOOT_SELF_PATTERNS = {}
local CHAT_LOOT_OTHER_PATTERNS = {}
do
	if GetLocale() == "ruRU" then
		-- LOOT_ITEM_PUSHED_SELF
		CHAT_LOOT_SELF_PATTERNS["^Вы получаете предмет: (.+)%.$"] = "%s receives item: %s%s."

		-- LOOT_ITEM_PUSHED_SELF_MULTIPLE
		CHAT_LOOT_SELF_PATTERNS["^Вы получаете предмет: (.+)x(%d+)%.$"] = "%s receives item: %sx%s."

		-- LOOT_ITEM_SELF
		CHAT_LOOT_SELF_PATTERNS["^Ваша добыча: (.+)%.$"] = "%s receives loot: %s%s."

		-- LOOT_ITEM_SELF_MULTIPLE
		CHAT_LOOT_SELF_PATTERNS["^Ваша добыча: (.+)x(%d+)%.$"] = "%s receives loot: %sx%s."

		-- LOOT_ITEM_CREATED_SELF
		CHAT_LOOT_SELF_PATTERNS["^Вы создаете: (.+)%.$"] = "%s creates: %s%s."

		-- LOOT_ITEM_CREATED_SELF_MULTIPLE
		CHAT_LOOT_SELF_PATTERNS["^Вы создаете: (.+)x(%d+)%.$"] = "%s creates: %sx%s."

		-- TRADESKILL_LOG_FIRSTPERSON
	--	CHAT_LOOT_SELF_PATTERNS["^Вы создаете: (.+)%.$"] = "%s creates %s%s."

		-- LOOT_ITEM
		CHAT_LOOT_OTHER_PATTERNS["^(.+) получает добычу: (.+)%.$"] = "%s receives loot: %s%s."

		-- LOOT_ITEM_MULTIPLE
		CHAT_LOOT_OTHER_PATTERNS["^(.+) получает добычу: (.+)x(%d+)%.$"] = "%s receives loot: %sx%s."
	else
		-- LOOT_ITEM_PUSHED_SELF
		CHAT_LOOT_SELF_PATTERNS["You receive item: (.+)%.$"] = "%s receives item: %s%s."

		-- LOOT_ITEM_PUSHED_SELF_MULTIPLE
		CHAT_LOOT_SELF_PATTERNS["^You receive item: (.+)x(%d+)%.$"] = "%s receives item: %sx%s."

		-- LOOT_ITEM_SELF
		CHAT_LOOT_SELF_PATTERNS["^You receive loot: (.+)%.$"] = "%s receives loot: %s%s."

		-- LOOT_ITEM_SELF_MULTIPLE
		CHAT_LOOT_SELF_PATTERNS["^You receive loot: (.+)x(%d+)%."] = "%s receives loot: %sx%s."

		-- LOOT_ITEM_CREATED_SELF
		CHAT_LOOT_SELF_PATTERNS["^You create: (.+)%.$"] = "%s creates: %s%s."

		-- LOOT_ITEM_CREATED_SELF_MULTIPLE
		CHAT_LOOT_SELF_PATTERNS["^You create: (.+)x(%d+)%.$"] = "%s creates: %sx%s."

		-- TRADESKILL_LOG_FIRSTPERSON
		CHAT_LOOT_SELF_PATTERNS["^You create (.+)%.$"] = "%s creates %s%s."

		-- LOOT_ITEM
		CHAT_LOOT_OTHER_PATTERNS["^(.+) receives loot: (.+)%.$"] = "%s receives loot: %s%s."

		-- LOOT_ITEM_MULTIPLE
	--	CHAT_LOOT_OTHER_PATTERNS["^(.+) receives loot: (.+)x(%d+)."] = "%s receives loot: %sx%s."
	end
end

function RPLL:ProcessLootMessage(message)
	if not IsInInstance() or RPLL:ContainsSynchronizer(message) then
		return
	end

	local result
	local playerName = UnitName("player")

	for pattern, replaceMessage in pairs(CHAT_LOOT_SELF_PATTERNS) do
		local loot, count = strmatch(message, pattern)
		if loot then
			if count then
				result = replaceMessage:format(replaceMessage, playerName, loot, count)
			else
				result = replaceMessage:format(playerName, loot, "x1")
			end
			break
		end
	end

	if not result then
		for pattern, replaceMessage in pairs(CHAT_LOOT_OTHER_PATTERNS) do
			local resultName, loot, count = strmatch(message, pattern)
			if resultName then
				if count then
					result = replaceMessage:format(replaceMessage, resultName, loot, count)
				else
					result = replaceMessage:format(replaceMessage, resultName, loot, "x1")
				end
				break
			end
		end
	end

	if result then
		RPLL:PushExtraMessage("LOOT", result)
	end
end

do	-- Extra message
	local spellFailedCombatLogEvents = {
		"SPELL_FAILED_AFFECTING_COMBAT",
		"SPELL_FAILED_ALREADY_BEING_TAMED",
		"SPELL_FAILED_ALREADY_HAVE_CHARM",
		"SPELL_FAILED_ALREADY_HAVE_SUMMON",
		"SPELL_FAILED_ALREADY_OPEN",
		"SPELL_FAILED_ARTISAN_RIDING_REQUIREMENT",
		"SPELL_FAILED_AURA_BOUNCED",
		"SPELL_FAILED_BAD_IMPLICIT_TARGETS",
		"SPELL_FAILED_BAD_TARGETS",
		"SPELL_FAILED_BM_OR_INVISGOD",
		"SPELL_FAILED_CANT_BE_CHARMED",
		"SPELL_FAILED_CANT_BE_DISENCHANTED",
		"SPELL_FAILED_CANT_BE_DISENCHANTED_SKILL",
		"SPELL_FAILED_CANT_BE_MILLED",
		"SPELL_FAILED_CANT_BE_PROSPECTED",
		"SPELL_FAILED_CANT_CAST_ON_TAPPED",
		"SPELL_FAILED_CANT_DO_THAT_RIGHT_NOW",
		"SPELL_FAILED_CANT_DUEL_WHILE_INVISIBLE",
		"SPELL_FAILED_CANT_DUEL_WHILE_STEALTHED",
		"SPELL_FAILED_CANT_STEALTH",
		"SPELL_FAILED_CASTER_AURASTATE",
		"SPELL_FAILED_CASTER_DEAD",
		"SPELL_FAILED_CASTER_DEAD_FEMALE",
		"SPELL_FAILED_CAST_NOT_HERE",
		"SPELL_FAILED_CHARMED",
		"SPELL_FAILED_CHEST_IN_USE",
		"SPELL_FAILED_CONFUSED",
		"SPELL_FAILED_CUSTOM_ERROR_1",
		"SPELL_FAILED_CUSTOM_ERROR_10",
		"SPELL_FAILED_CUSTOM_ERROR_11",
		"SPELL_FAILED_CUSTOM_ERROR_12",
		"SPELL_FAILED_CUSTOM_ERROR_13",
		"SPELL_FAILED_CUSTOM_ERROR_14_NONE",
		"SPELL_FAILED_CUSTOM_ERROR_15",
		"SPELL_FAILED_CUSTOM_ERROR_16",
		"SPELL_FAILED_CUSTOM_ERROR_17",
		"SPELL_FAILED_CUSTOM_ERROR_18",
		"SPELL_FAILED_CUSTOM_ERROR_19",
		"SPELL_FAILED_CUSTOM_ERROR_2",
		"SPELL_FAILED_CUSTOM_ERROR_20",
		"SPELL_FAILED_CUSTOM_ERROR_21",
		"SPELL_FAILED_CUSTOM_ERROR_22",
		"SPELL_FAILED_CUSTOM_ERROR_23",
		"SPELL_FAILED_CUSTOM_ERROR_24",
		"SPELL_FAILED_CUSTOM_ERROR_25",
		"SPELL_FAILED_CUSTOM_ERROR_26",
		"SPELL_FAILED_CUSTOM_ERROR_27",
		"SPELL_FAILED_CUSTOM_ERROR_28",
		"SPELL_FAILED_CUSTOM_ERROR_29",
		"SPELL_FAILED_CUSTOM_ERROR_3",
		"SPELL_FAILED_CUSTOM_ERROR_30",
		"SPELL_FAILED_CUSTOM_ERROR_31",
		"SPELL_FAILED_CUSTOM_ERROR_32",
		"SPELL_FAILED_CUSTOM_ERROR_33",
		"SPELL_FAILED_CUSTOM_ERROR_34",
		"SPELL_FAILED_CUSTOM_ERROR_35",
		"SPELL_FAILED_CUSTOM_ERROR_36",
		"SPELL_FAILED_CUSTOM_ERROR_37",
		"SPELL_FAILED_CUSTOM_ERROR_38",
		"SPELL_FAILED_CUSTOM_ERROR_39",
		"SPELL_FAILED_CUSTOM_ERROR_4",
		"SPELL_FAILED_CUSTOM_ERROR_40",
		"SPELL_FAILED_CUSTOM_ERROR_41",
		"SPELL_FAILED_CUSTOM_ERROR_42",
		"SPELL_FAILED_CUSTOM_ERROR_43",
		"SPELL_FAILED_CUSTOM_ERROR_44",
		"SPELL_FAILED_CUSTOM_ERROR_45",
		"SPELL_FAILED_CUSTOM_ERROR_46",
		"SPELL_FAILED_CUSTOM_ERROR_47",
		"SPELL_FAILED_CUSTOM_ERROR_48",
		"SPELL_FAILED_CUSTOM_ERROR_49",
		"SPELL_FAILED_CUSTOM_ERROR_5",
		"SPELL_FAILED_CUSTOM_ERROR_50",
		"SPELL_FAILED_CUSTOM_ERROR_51",
		"SPELL_FAILED_CUSTOM_ERROR_52",
		"SPELL_FAILED_CUSTOM_ERROR_53",
		"SPELL_FAILED_CUSTOM_ERROR_54",
		"SPELL_FAILED_CUSTOM_ERROR_55",
		"SPELL_FAILED_CUSTOM_ERROR_56",
		"SPELL_FAILED_CUSTOM_ERROR_57",
		"SPELL_FAILED_CUSTOM_ERROR_58",
		"SPELL_FAILED_CUSTOM_ERROR_59",
		"SPELL_FAILED_CUSTOM_ERROR_6",
		"SPELL_FAILED_CUSTOM_ERROR_60",
		"SPELL_FAILED_CUSTOM_ERROR_61",
		"SPELL_FAILED_CUSTOM_ERROR_62",
		"SPELL_FAILED_CUSTOM_ERROR_63_NONE",
		"SPELL_FAILED_CUSTOM_ERROR_64_NONE",
		"SPELL_FAILED_CUSTOM_ERROR_65",
		"SPELL_FAILED_CUSTOM_ERROR_66",
		"SPELL_FAILED_CUSTOM_ERROR_67",
		"SPELL_FAILED_CUSTOM_ERROR_7",
		"SPELL_FAILED_CUSTOM_ERROR_75",
		"SPELL_FAILED_CUSTOM_ERROR_76",
		"SPELL_FAILED_CUSTOM_ERROR_77",
		"SPELL_FAILED_CUSTOM_ERROR_78",
		"SPELL_FAILED_CUSTOM_ERROR_79",
		"SPELL_FAILED_CUSTOM_ERROR_8",
		"SPELL_FAILED_CUSTOM_ERROR_83",
		"SPELL_FAILED_CUSTOM_ERROR_84",
		"SPELL_FAILED_CUSTOM_ERROR_85",
		"SPELL_FAILED_CUSTOM_ERROR_86",
		"SPELL_FAILED_CUSTOM_ERROR_87",
		"SPELL_FAILED_CUSTOM_ERROR_88",
		"SPELL_FAILED_CUSTOM_ERROR_9",
		"SPELL_FAILED_CUSTOM_ERROR_90",
		"SPELL_FAILED_CUSTOM_ERROR_96",
		"SPELL_FAILED_CUSTOM_ERROR_97",
		"SPELL_FAILED_CUSTOM_ERROR_98",
		"SPELL_FAILED_CUSTOM_ERROR_99",
		"SPELL_FAILED_DAMAGE_IMMUNE",
		"SPELL_FAILED_EQUIPPED_ITEM",
		"SPELL_FAILED_EQUIPPED_ITEM_CLASS",
		"SPELL_FAILED_EQUIPPED_ITEM_CLASS_MAINHAND",
		"SPELL_FAILED_EQUIPPED_ITEM_CLASS_OFFHAND",
		"SPELL_FAILED_ERROR",
		"SPELL_FAILED_EXPERT_RIDING_REQUIREMENT",
		"SPELL_FAILED_FISHING_TOO_LOW",
		"SPELL_FAILED_FIZZLE",
		"SPELL_FAILED_FLEEING",
		"SPELL_FAILED_FOOD_LOWLEVEL",
		"SPELL_FAILED_GLYPH_SOCKET_LOCKED",
		"SPELL_FAILED_HIGHLEVEL",
		"SPELL_FAILED_IMMUNE",
		"SPELL_FAILED_INCORRECT_AREA",
		"SPELL_FAILED_INTERRUPTED",
		"SPELL_FAILED_INTERRUPTED_COMBAT",
		"SPELL_FAILED_INVALID_GLYPH",
		"SPELL_FAILED_ITEM_ALREADY_ENCHANTED",
		"SPELL_FAILED_ITEM_AT_MAX_CHARGES",
		"SPELL_FAILED_ITEM_ENCHANT_TRADE_WINDOW",
		"SPELL_FAILED_ITEM_GONE",
		"SPELL_FAILED_ITEM_NOT_FOUND",
		"SPELL_FAILED_ITEM_NOT_READY",
		"SPELL_FAILED_LEVEL_REQUIREMENT",
		"SPELL_FAILED_LEVEL_REQUIREMENT_PET",
		"SPELL_FAILED_LIMIT_CATEGORY_EXCEEDED",
		"SPELL_FAILED_LINE_OF_SIGHT",
		"SPELL_FAILED_LOWLEVEL",
		"SPELL_FAILED_LOW_CASTLEVEL",
		"SPELL_FAILED_MAINHAND_EMPTY",
		"SPELL_FAILED_MIN_SKILL",
		"SPELL_FAILED_MOVING",
		"SPELL_FAILED_NEED_AMMO",
		"SPELL_FAILED_NEED_AMMO_POUCH",
		"SPELL_FAILED_NEED_EXOTIC_AMMO",
		"SPELL_FAILED_NEED_MORE_ITEMS",
		"SPELL_FAILED_NOPATH",
		"SPELL_FAILED_NOTHING_TO_DISPEL",
		"SPELL_FAILED_NOTHING_TO_STEAL",
		"SPELL_FAILED_NOT_BEHIND",
		"SPELL_FAILED_NOT_FISHABLE",
		"SPELL_FAILED_NOT_FLYING",
		"SPELL_FAILED_NOT_HERE",
		"SPELL_FAILED_NOT_IDLE",
		"SPELL_FAILED_NOT_INACTIVE",
		"SPELL_FAILED_NOT_INFRONT",
		"SPELL_FAILED_NOT_IN_ARENA",
		"SPELL_FAILED_NOT_IN_BARBERSHOP",
		"SPELL_FAILED_NOT_IN_BATTLEGROUND",
		"SPELL_FAILED_NOT_IN_CONTROL",
		"SPELL_FAILED_NOT_IN_RAID_INSTANCE",
		"SPELL_FAILED_NOT_KNOWN",
		"SPELL_FAILED_NOT_MOUNTED",
		"SPELL_FAILED_NOT_ON_DAMAGE_IMMUNE",
		"SPELL_FAILED_NOT_ON_GROUND",
		"SPELL_FAILED_NOT_ON_MOUNTED",
		"SPELL_FAILED_NOT_ON_SHAPESHIFT",
		"SPELL_FAILED_NOT_ON_STEALTHED",
		"SPELL_FAILED_NOT_ON_TAXI",
		"SPELL_FAILED_NOT_ON_TRANSPORT",
		"SPELL_FAILED_NOT_READY",
		"SPELL_FAILED_NOT_SHAPESHIFT",
		"SPELL_FAILED_NOT_STANDING",
		"SPELL_FAILED_NOT_TRADEABLE",
		"SPELL_FAILED_NOT_TRADING",
		"SPELL_FAILED_NOT_UNSHEATHED",
		"SPELL_FAILED_NOT_WHILE_FATIGUED",
		"SPELL_FAILED_NOT_WHILE_GHOST",
		"SPELL_FAILED_NOT_WHILE_LOOTING",
		"SPELL_FAILED_NOT_WHILE_TRADING",
		"SPELL_FAILED_NO_AMMO",
		"SPELL_FAILED_NO_CHAMPION",
		"SPELL_FAILED_NO_CHARGES_REMAIN",
		"SPELL_FAILED_NO_COMBO_POINTS",
		"SPELL_FAILED_NO_DUELING",
		"SPELL_FAILED_NO_EDIBLE_CORPSES",
		"SPELL_FAILED_NO_ENDURANCE",
		"SPELL_FAILED_NO_EVASIVE_CHARGES",
		"SPELL_FAILED_NO_FISH",
		"SPELL_FAILED_NO_ITEMS_WHILE_SHAPESHIFTED",
		"SPELL_FAILED_NO_MAGIC_TO_CONSUME",
		"SPELL_FAILED_NO_MOUNTS_ALLOWED",
		"SPELL_FAILED_NO_PET",
		"SPELL_FAILED_NO_PLAYTIME",
		"SPELL_FAILED_ONLY_ABOVEWATER",
		"SPELL_FAILED_ONLY_BATTLEGROUNDS",
		"SPELL_FAILED_ONLY_DAYTIME",
		"SPELL_FAILED_ONLY_INDOORS",
		"SPELL_FAILED_ONLY_IN_ARENA",
		"SPELL_FAILED_ONLY_MOUNTED",
		"SPELL_FAILED_ONLY_NIGHTTIME",
		"SPELL_FAILED_ONLY_OUTDOORS",
		"SPELL_FAILED_ONLY_SHAPESHIFT",
		"SPELL_FAILED_ONLY_STEALTHED",
		"SPELL_FAILED_ONLY_UNDERWATER",
		"SPELL_FAILED_OUT_OF_RANGE",
		"SPELL_FAILED_PACIFIED",
		"SPELL_FAILED_PARTIAL_PLAYTIME",
		"SPELL_FAILED_PET_CAN_RENAME",
		"SPELL_FAILED_POSSESSED",
		"SPELL_FAILED_PREVENTED_BY_MECHANIC",
		"SPELL_FAILED_REAGENTS",
		"SPELL_FAILED_REPUTATION",
		"SPELL_FAILED_REQUIRES_AREA",
		"SPELL_FAILED_REQUIRES_SPELL_FOCUS",
		"SPELL_FAILED_ROCKET_PACK",
		"SPELL_FAILED_ROOTED",
		"SPELL_FAILED_SILENCED",
		"SPELL_FAILED_SPELL_IN_PROGRESS",
		"SPELL_FAILED_SPELL_LEARNED",
		"SPELL_FAILED_SPELL_UNAVAILABLE",
		"SPELL_FAILED_SPELL_UNAVAILABLE_PET",
		"SPELL_FAILED_STUNNED",
		"SPELL_FAILED_SUMMON_PENDING",
		"SPELL_FAILED_TARGETS_DEAD",
		"SPELL_FAILED_TARGET_AFFECTING_COMBAT",
		"SPELL_FAILED_TARGET_AURASTATE",
		"SPELL_FAILED_TARGET_CANNOT_BE_RESURRECTED",
		"SPELL_FAILED_TARGET_DUELING",
		"SPELL_FAILED_TARGET_ENEMY",
		"SPELL_FAILED_TARGET_ENRAGED",
		"SPELL_FAILED_TARGET_FREEFORALL",
		"SPELL_FAILED_TARGET_FRIENDLY",
		"SPELL_FAILED_TARGET_IN_COMBAT",
		"SPELL_FAILED_TARGET_IS_PLAYER",
		"SPELL_FAILED_TARGET_IS_PLAYER_CONTROLLED",
		"SPELL_FAILED_TARGET_IS_TRIVIAL",
		"SPELL_FAILED_TARGET_LOCKED_TO_RAID_INSTANCE",
		"SPELL_FAILED_TARGET_NOT_DEAD",
		"SPELL_FAILED_TARGET_NOT_GHOST",
		"SPELL_FAILED_TARGET_NOT_IN_INSTANCE",
		"SPELL_FAILED_TARGET_NOT_IN_PARTY",
		"SPELL_FAILED_TARGET_NOT_IN_RAID",
		"SPELL_FAILED_TARGET_NOT_IN_SANCTUARY",
		"SPELL_FAILED_TARGET_NOT_LOOTED",
		"SPELL_FAILED_TARGET_NOT_PLAYER",
		"SPELL_FAILED_TARGET_NO_POCKETS",
		"SPELL_FAILED_TARGET_NO_RANGED_WEAPONS",
		"SPELL_FAILED_TARGET_NO_WEAPONS",
		"SPELL_FAILED_TARGET_ON_TAXI",
		"SPELL_FAILED_TARGET_UNSKINNABLE",
		"SPELL_FAILED_TOO_CLOSE",
		"SPELL_FAILED_TOO_MANY_OF_ITEM",
		"SPELL_FAILED_TOO_SHALLOW",
		"SPELL_FAILED_TOTEMS",
		"SPELL_FAILED_TOTEM_CATEGORY",
		"SPELL_FAILED_TRANSFORM_UNUSABLE",
		"SPELL_FAILED_TRY_AGAIN",
		"SPELL_FAILED_UNIQUE_GLYPH",
		"SPELL_FAILED_UNIT_NOT_BEHIND",
		"SPELL_FAILED_UNIT_NOT_INFRONT",
		"SPELL_FAILED_UNKNOWN",
		"SPELL_FAILED_WRONG_PET_FOOD",
		"SPELL_FAILED_WRONG_WEATHER",
		"ERR_OUT_OF_ENERGY",
		"ERR_OUT_OF_FOCUS",
		"ERR_OUT_OF_HEALTH",
		"ERR_OUT_OF_MANA",
		"ERR_OUT_OF_RANGE",
		"ERR_OUT_OF_RUNES",
		"ERR_OUT_OF_RUNIC_POWER",
	}

	function RPLL:PushExtraMessage(prefix, msg)
		tinsert(RPLL.ExtraMessages, strformat("%s: %s&%s", prefix, date("%d.%m.%y %H:%M:%S"), msg))
		RPLL.ExtraMessageLength = RPLL.ExtraMessageLength + 1
	end

	function RPLL:SerializePlayerInformation()
		local pinfo = RPLL.PlayerInformation[RPLL.PlayerRotation[RPLL.RotationIndex]]

		local gear = valueOrNil(pinfo["gear"][1])
		for i = 2, 19 do
			gear = gear .. "}" .. valueOrNil(pinfo["gear"][i])
		end

		return strjoin("&", pinfo["last_updated"], valueOrNil(pinfo["unit_guid"]), valueOrNil(pinfo["unit_name"]),
			valueOrNil(pinfo["race"]), valueOrNil(pinfo["hero_class"]), valueOrNil(pinfo["gender"]), valueOrNil(pinfo["guild_name"]),
			valueOrNil(pinfo["guild_rank_name"]), valueOrNil(pinfo["guild_rank_index"]), gear, valueOrNil(pinfo["talents"]),
			valueOrNil(pinfo["arena_teams"][2]), valueOrNil(pinfo["arena_teams"][3]), valueOrNil(pinfo["arena_teams"][5]))
	end

	function RPLL:RotateSpellFailedMessages()
		local result
		if self.ExtraMessageIndex <= self.ExtraMessageLength then
			local consolidate_count = 1
			local current_result = "CONSOLIDATED: " .. self.ExtraMessages[self.ExtraMessageIndex]

			for i = self.ExtraMessageIndex + 1, self.ExtraMessageLength do
				local pot_new_result = current_result .. self.CONSOLIDATE_CHARACTER .. self.ExtraMessages[i]
				if strlen(pot_new_result) < self.MAX_MESSAGE_LENGTH then
					current_result = pot_new_result
					consolidate_count = consolidate_count + 1
				else
					break
				end
			end

			result = current_result
			self.ExtraMessageIndex = self.ExtraMessageIndex + consolidate_count
		elseif self.RotationIndex <= self.RotationLength and self.PlayerInformation[self.PlayerRotation[self.RotationIndex]] ~= nil then
			result = "COMBATANT_INFO: "..self:SerializePlayerInformation()
			self.RotationIndex = self.RotationIndex + 1
		else
			result = "NONE"
		end

		for _, evt in pairs(spellFailedCombatLogEvents) do
			_G[evt] = result
		end
	end
end