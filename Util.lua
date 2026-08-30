local _, addon = ...

local Util = {}
addon.Util = Util

-- True when value is a primitive that can be serialized as-is.
local function isSerializableScalar(value)
  local valueType = type(value)
  return valueType == "nil" or valueType == "boolean" or valueType == "number" or valueType == "string"
end

-- Deep-copies serializable table data, dropping cycles, functions, and oversized trees.
function Util:CopySerializable(value, state, depth)
  if isSerializableScalar(value) then
    return value
  end
  -- If the value is not a table, return nil
  if type(value) ~= "table" then
    return nil
  end

  state = state or {seen = {}, count = 0}
  depth = depth or 0
  -- Defensive check, so recursive isn't infinite
  if depth > 16 or state.count > 10000 or state.seen[value] then
    return nil
  end
  state.seen[value] = true

  local copy = {}
  for key, child in pairs(value) do
    if isSerializableScalar(key) then
      state.count = state.count + 1
      if state.count > 10000 then
        break
      end
      local childCopy = self:CopySerializable(child, state, depth + 1)
      if childCopy ~= nil then
        copy[key] = childCopy
      end
    end
  end

  state.seen[value] = nil
  return copy
end

-- Returns the number of keys in a table, or 0 if the value is not a table.
function Util:Count(tableValue)
  local count = 0
  if type(tableValue) == "table" then
    for _ in pairs(tableValue) do
      count = count + 1
    end
  end
  return count
end

-- Trims and lowercases a BattleTag; returns nil for empty or non-string input.
function Util:NormalizeBattleTag(battleTag)
  if type(battleTag) ~= "string" then
    return nil
  end
  -- Trim whitespace from the beginning and end of the BattleTag
  battleTag = battleTag:match("^%s*(.-)%s*$")
  if battleTag == "" then
    return nil
  end
  return battleTag:lower()
end

-- Strips whitespace and lowercases a character name for comparison.
function Util:NormalizeCharacterName(name)
  if type(name) ~= "string" then
    return nil
  end
  return name:gsub("%s+", ""):lower()
end

-- Current Unix time from the server clock, falling back to local time.
function Util:Now()
  if GetServerTime then
    return GetServerTime()
  end
  return time()
end

-- Formats a Unix timestamp as a short relative age, e.g. "3h ago".
function Util:FormatAge(timestamp)
  if type(timestamp) ~= "number" or timestamp <= 0 then
    return "never"
  end
  local seconds = math.max(0, self:Now() - timestamp)
  if seconds < 60 then
    return seconds .. "s ago"
  elseif seconds < 3600 then
    return math.floor(seconds / 60) .. "m ago"
  elseif seconds < 86400 then
    return math.floor(seconds / 3600) .. "h ago"
  end
  return math.floor(seconds / 86400) .. "d ago"
end

-- Returns a table's keys sorted case-insensitively.
function Util:SortedKeys(tableValue)
  local keys = {}
  for key in pairs(tableValue or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right)
    return tostring(left):lower() < tostring(right):lower()
  end)
  return keys
end

-- Reads the installed AlterEgo addon's version from its TOC metadata.
function Util:GetAlterEgoVersion()
  return C_AddOns.GetAddOnMetadata("AlterEgo", "Version") or "unknown"
end

-- Returns AlterEgo's saved-variable schema version, or 0 if unavailable.
function Util:GetAlterEgoDBVersion()
  local db = _G.AlterEgoDB
  return db and db.global and db.global.dbVersion or 0
end

-- Returns AlterEgo's character table from saved variables, or nil if missing.
function Util:GetAlterEgoCharacters()
  local db = _G.AlterEgoDB
  if type(db) ~= "table" or type(db.global) ~= "table" or type(db.global.characters) ~= "table" then
    return nil
  end
  return db.global.characters
end
