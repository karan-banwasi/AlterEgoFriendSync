local _, addon = ...

local frame = CreateFrame("Frame", "AlterEgoFriendEventFrame")
addon.frame = frame

local DATA_CHANGE_EVENTS = {
  BAG_UPDATE_DELAYED = true,
  BOSS_KILL = true,
  CHALLENGE_MODE_COMPLETED = true,
  CHALLENGE_MODE_MAPS_UPDATE = true,
  ENCOUNTER_END = true,
  ITEM_CHANGED = true,
  LFG_UPDATE_RANDOM_INFO = true,
  MYTHIC_PLUS_NEW_WEEKLY_RECORD = true,
  PLAYER_EQUIPMENT_CHANGED = true,
  QUEST_LOG_UPDATE = true,
  UNIT_INVENTORY_CHANGED = true,
  UPDATE_INSTANCE_INFO = true,
  WEEKLY_REWARDS_UPDATE = true,
}

-- Fill missing keys on target from defaults, recursively for nested tables.
local function applyDefaults(target, defaults)
  for key, value in pairs(defaults) do
    if target[key] == nil then
      if type(value) == "table" then
        target[key] = {}
        applyDefaults(target[key], value)
      else
        target[key] = value
      end
    elseif type(value) == "table" and type(target[key]) == "table" then
      applyDefaults(target[key], value)
    end
  end
end

-- Create or migrate saved variables and attach them to self.db.
function addon:InitializeDatabase()
  AlterEgoFriendSyncDB = type(AlterEgoFriendSyncDB) == "table" and AlterEgoFriendSyncDB or {}
  local defaults = {
    version = self.databaseVersion,
    settings = {
      view = "mine",
      selectedPeer = nil,
      periodicSeconds = 60,
    },
    peers = {},
    injected = {},
    hiddenOwn = {},
    disabledFriends = {},
  }
  applyDefaults(AlterEgoFriendSyncDB, defaults)
  self.db = AlterEgoFriendSyncDB
  self.db.settings.debug = nil

  if self.db.version ~= self.databaseVersion then
    -- Preserve pairings and recover temporary view mutations when migrating.
    self.db.injected = self.db.injected or {}
    self.db.hiddenOwn = self.db.hiddenOwn or {}
    self.db.disabledFriends = self.db.disabledFriends or {}
    self.db.version = self.databaseVersion
  end
end

-- Boot subsystems once after login and refresh the injected AlterEgo view.
function addon:Initialize()
  if self.runtime.initialized then
    return
  end
  self.runtime.initialized = true

  self:InitializeDatabase()
  self.Injection:Initialize()
  self.Transport:Initialize()
  self.Protocol:Initialize()
  self.UI:Initialize()
  self.Injection:RefreshView()
  self:Debug("Initialized with AlterEgo " .. self.Util:GetAlterEgoVersion() .. ".")
end

-- Tear down injection hooks before logout so AlterEgo is left clean.
function addon:Shutdown()
  if self.Injection then
    self.Injection:Shutdown()
  end
end

-- Route WoW events to init, transport, discovery, and change-check handlers.
frame:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    addon:Initialize()
  elseif event == "PLAYER_LOGOUT" then
    addon:Shutdown()
  elseif event == "CHAT_MSG_ADDON" then
    local prefix, text, _, sender = ...
    -- Chat fallback is never a discovery channel. Ignore packets unless the
    -- sender is already a Battle.net friend resolved during discovery.
    if prefix == addon.prefix and addon.Protocol:ResolveSender("CHAT", sender) then
      addon.Transport:Receive("CHAT", sender, text)
    end
  elseif event == "BN_CHAT_MSG_ADDON" then
    local prefix, text, _, senderID = ...
    if prefix == addon.prefix then
      addon.Transport:Receive("BNET", senderID, text)
    end
  elseif event == "BN_CONNECTED" or event == "BN_FRIEND_INFO_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
    if addon.runtime.initialized then
      addon.Protocol:ScheduleFriendRefresh()
    end
  elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
    local _, state = ...
    addon.Transport:OnRestrictionsChanged(state)
  elseif DATA_CHANGE_EVENTS[event] and addon.runtime.initialized then
    addon.Protocol:ScheduleChangeCheck()
  end
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
-- Addon message sent on addon chat channel.
frame:RegisterEvent("CHAT_MSG_ADDON")
-- Addon message sent on Battle.net chat channel.
frame:RegisterEvent("BN_CHAT_MSG_ADDON")
-- Battle.net connected.
frame:RegisterEvent("BN_CONNECTED")
frame:RegisterEvent("BN_FRIEND_INFO_CHANGED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")

for event in pairs(DATA_CHANGE_EVENTS) do
  frame:RegisterEvent(event)
end
