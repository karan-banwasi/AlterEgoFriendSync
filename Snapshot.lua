local _, addon = ...

local Util = addon.Util
local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")

local Snapshot = {}
addon.Snapshot = Snapshot

local function tableOrEmpty(value)
  return type(value) == "table" and value or {}
end

local function text(value)
  if type(value) ~= "string" then
    return ""
  end
  -- self imposed limit of 2048 characters for safety
  return value:sub(1, 2048)
end

local function number(value)
  local parsed
  if type(value) == "number" then
    parsed = value
  elseif type(value) == "string" then
    parsed = tonumber(value)
  end
  -- Reject nil, NaN (the only value where x ~= x), and ±infinity.
  if not parsed or parsed ~= parsed or parsed == math.huge or parsed == -math.huge then
    return 0
  end
  return parsed
end

local function boundedArray(source, maximum, mapper)
  local result = {}
  if type(source) ~= "table" then
    return result
  end
  for index = 1, math.min(#source, maximum) do
    local mapped = mapper(source[index])
    if mapped then
      result[#result + 1] = mapped
    end
  end
  return result
end

local function trimInfo(sourceInfo)
  sourceInfo = tableOrEmpty(sourceInfo)
  local sourceRace = tableOrEmpty(sourceInfo.race)
  local sourceClass = tableOrEmpty(sourceInfo.class)
  local sourceFaction = tableOrEmpty(sourceInfo.factionGroup)
  local sourceIlvl = tableOrEmpty(sourceInfo.ilvl)
  local sourceGuild = tableOrEmpty(sourceInfo.guild)
  return {
    name = text(sourceInfo.name),
    realm = text(sourceInfo.realm),
    level = number(sourceInfo.level),
    race = {name = text(sourceRace.name), file = text(sourceRace.file), id = number(sourceRace.id)},
    class = {name = text(sourceClass.name), file = text(sourceClass.file), id = number(sourceClass.id)},
    factionGroup = {english = text(sourceFaction.english), localized = text(sourceFaction.localized)},
    ilvl = {
      level = number(sourceIlvl.level),
      equipped = number(sourceIlvl.equipped),
      pvp = number(sourceIlvl.pvp),
      color = text(sourceIlvl.color) ~= "" and text(sourceIlvl.color) or "ffffffff",
    },
    guild = {
      isInGuild = sourceGuild.isInGuild == true,
      name = text(sourceGuild.name),
      rankName = text(sourceGuild.rankName),
      rankIndex = number(sourceGuild.rankIndex),
      realm = text(sourceGuild.realm),
    },
  }
end

local function trimMythicplus(sourceMythic)
  sourceMythic = tableOrEmpty(sourceMythic)
  local sourceRuns = tableOrEmpty(sourceMythic.numCompletedDungeonRuns)
  local sourceKeystone = tableOrEmpty(sourceMythic.keystone)
  return {
    rating = number(sourceMythic.rating),
    bestSeasonScore = number(sourceMythic.bestSeasonScore),
    bestSeasonNumber = number(sourceMythic.bestSeasonNumber),
    numCompletedDungeonRuns = {
      heroic = number(sourceRuns.heroic),
      mythic = number(sourceRuns.mythic),
      mythicPlus = number(sourceRuns.mythicPlus),
    },
    keystone = {
      challengeModeID = number(sourceKeystone.challengeModeID),
      mapId = number(sourceKeystone.mapId),
      level = number(sourceKeystone.level),
      color = text(sourceKeystone.color),
      itemId = number(sourceKeystone.itemId),
      itemLink = text(sourceKeystone.itemLink),
    },
    runHistory = boundedArray(sourceMythic.runHistory, 200, function(run)
      if type(run) ~= "table" then return nil end
      return {
        thisWeek = run.thisWeek == true,
        level = number(run.level),
        mapChallengeModeID = number(run.mapChallengeModeID),
      }
    end),
    dungeons = boundedArray(sourceMythic.dungeons, 50, function(dungeon)
      if type(dungeon) ~= "table" then return nil end
      return {
        challengeModeID = number(dungeon.challengeModeID),
        rating = number(dungeon.rating),
        level = number(dungeon.level),
        finishedSuccess = dungeon.finishedSuccess == true,
        bestOverAllScore = number(dungeon.bestOverAllScore),
        bestTimedRun = type(dungeon.bestTimedRun) == "table" and {} or nil,
        bestNotTimedRun = type(dungeon.bestNotTimedRun) == "table" and {} or nil,
        affixScores = boundedArray(dungeon.affixScores, 10, function(score)
          if type(score) ~= "table" then return nil end
          return {
            id = number(score.id),
            name = text(score.name),
            score = number(score.score),
            level = number(score.level),
            durationSec = number(score.durationSec),
            overTime = score.overTime == true,
          }
        end),
      }
    end),
  }
end

local function trimVault(sourceVault)
  sourceVault = tableOrEmpty(sourceVault)
  return {
    hasAvailableRewards = sourceVault.hasAvailableRewards == true,
    slots = boundedArray(sourceVault.slots, 20, function(slot)
      if type(slot) ~= "table" then return nil end
      return {
        id = number(slot.id),
        type = number(slot.type),
        index = number(slot.index),
        progress = number(slot.progress),
        threshold = number(slot.threshold),
        level = number(slot.level),
        activityTierID = number(slot.activityTierID),
        exampleRewardLink = text(slot.exampleRewardLink),
        exampleRewardUpgradeLink = text(slot.exampleRewardUpgradeLink),
      }
    end),
    activityEncounterInfo = boundedArray(sourceVault.activityEncounterInfo, 100, function(encounter)
      if type(encounter) ~= "table" then return nil end
      return {
        type = number(encounter.type),
        index = number(encounter.index),
        instanceID = number(encounter.instanceID),
        encounterID = number(encounter.encounterID),
        bestDifficulty = number(encounter.bestDifficulty),
      }
    end),
    worldActivityProgress = boundedArray(sourceVault.worldActivityProgress, 50, function(progress)
      if type(progress) ~= "table" then return nil end
      return {
        activityTierID = number(progress.activityTierID),
        difficulty = number(progress.difficulty),
        numPoints = number(progress.numPoints),
      }
    end),
  }
end

-- Extract and santize raid data
local function trimRaids(sourceRaids)
  sourceRaids = tableOrEmpty(sourceRaids)
  return {
    savedInstances = boundedArray(sourceRaids.savedInstances, 100, function(instance)
      if type(instance) ~= "table" then return nil end
      return {
        id = number(instance.id),
        name = text(instance.name),
        instanceID = number(instance.instanceID),
        difficultyID = number(instance.difficultyID),
        expires = number(instance.expires),
        encounters = boundedArray(instance.encounters, 100, function(encounter)
          if type(encounter) ~= "table" then return nil end
          return {
            index = number(encounter.index),
            instanceEncounterID = number(encounter.instanceEncounterID),
            bossName = text(encounter.bossName),
            fileDataID = number(encounter.fileDataID),
            isKilled = encounter.isKilled == true,
          }
        end),
      }
    end),
  }
end

-- Sanitize a character into a shareable record with typed fields and bounded arrays.
function Snapshot:Trim(character)
  if type(character) ~= "table" or type(character.GUID) ~= "string" or character.GUID == "" then
    return nil
  end

  return {
    GUID = character.GUID,
    lastUpdate = number(character.lastUpdate),
    currentSeason = number(character.currentSeason),
    currentSeasonID = character.currentSeasonID ~= nil and number(character.currentSeasonID) or nil,
    enabled = true,
    order = number(character.order),
    info = trimInfo(character.info),
    mythicplus = trimMythicplus(character.mythicplus),
    vault = trimVault(character.vault),
    raids = trimRaids(character.raids),

    -- Empty local-only slices keep AlterEgo's renderer nil-safe without sharing them.
    equipment = {},
    currencies = {},
    money = 0,
    prey = {questsCompleted = {}},
  }
end

-- Serialize with stable key order so identical tables always produce the same bytes.
function Snapshot:SerializeStable(value)
  return LibSerialize:SerializeEx({
    stable = true,
    errorOnUnserializableType = true,
  }, value)
end

-- Content hash of a record, ignoring local presentation fields that would cause false updates.
function Snapshot:Fingerprint(record)
  local fingerprintRecord = Util:CopySerializable(record)
  -- These are local presentation/activity fields. AlterEgo rewrites order while
  -- rendering and touches lastUpdate for unrelated events, so including either
  -- would create false network updates.
  fingerprintRecord.order = nil
  fingerprintRecord.enabled = nil
  fingerprintRecord.lastUpdate = nil
  local serialized = self:SerializeStable(fingerprintRecord)
  return tostring(LibDeflate:Adler32(serialized)) .. ":" .. tostring(#serialized)
end

-- Build this player's shareable records and fingerprints, excluding injected friend characters.
function Snapshot:BuildOwn()
  local characters = Util:GetAlterEgoCharacters()
  local records = {}
  local fingerprints = {}
  if not characters then
    return records, fingerprints
  end

  -- Snapshot each owned character; skip friend-injected rows so we do not re-share them.
  local injected = addon.db and addon.db.injected or {}
  for guid, character in pairs(characters) do
    if not injected[guid] then
      local record = self:Trim(character)
      if record then
        records[guid] = record
        fingerprints[guid] = self:Fingerprint(record)
      end
    end
  end
  return records, fingerprints
end

function Snapshot:IsValidRecord(record)
  if type(record) ~= "table" or type(record.GUID) ~= "string" or record.GUID == "" then
    return false
  end
  if type(record.info) ~= "table" or type(record.info.name) ~= "string" then
    return false
  end
  if type(record.mythicplus) ~= "table" or type(record.vault) ~= "table" or type(record.raids) ~= "table" then
    return false
  end
  return true
end
