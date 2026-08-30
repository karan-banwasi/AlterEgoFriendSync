local _, addon = ...

local Util = addon.Util
local Snapshot = addon.Snapshot
local Transport = addon.Transport

local Protocol = {
  friendsByBattleTag = {},
  friendsByGameAccount = {},
  friendsByCharacter = {},
  lastLocalFingerprints = {},
  -- Peers owed a HELLO/INDEX once addon chat leaves lockdown. Only the newest
  -- handshake and fingerprint map matter, so these collapse to one send each
  -- instead of queueing a packet per attempt for the length of an encounter.
  pendingHello = {},
  pendingIndex = {},
}
addon.Protocol = Protocol

-- True when a Battle.net game account is an online retail WoW session, the only
-- kind of peer this addon can exchange frames with.
local function isRetailWow(gameInfo)
  if type(gameInfo) ~= "table" or not gameInfo.isOnline then
    return false
  end
  local retailProject = WOW_PROJECT_MAINLINE or 1
  return gameInfo.clientProgram == BNET_CLIENT_WOW and gameInfo.wowProjectID == retailProject
end

-- Builds the whitespace-free "Name-Realm" string used to address a game account
-- over addon whispers, or nil when the character is unknown.
local function characterTarget(gameInfo)
  if type(gameInfo) ~= "table" or not gameInfo.characterName or not gameInfo.realmName then
    return nil
  end
  return (gameInfo.characterName .. "-" .. gameInfo.realmName):gsub("%s+", "")
end

-- Starts the periodic friend-refresh/change-check ticker and runs a first pass a
-- few seconds after login, once the game APIs have settled.
function Protocol:Initialize()
  self.periodicTicker = C_Timer.NewTicker(addon.db.settings.periodicSeconds or 60, function()
    self:RefreshFriends(false)
    -- A periodic INDEX also recovers from a dropped/expired multi-part DATA
    -- transfer even when the character data itself has not changed.
    self:CheckForChanges(true)
    -- Safety net in case ADDON_RESTRICTION_STATE_CHANGED was missed.
    self:FlushPending()
  end)

  C_Timer.After(5, function()
    self:RefreshFriends(true)
    self:CheckForChanges(true)
  end)
end

-- Rebuilds the Battle.net friend lookup tables from the game's friend list and
-- greets peers that just came online (or every online peer when announce is set).
function Protocol:RefreshFriends(announce)
  if not BNGetNumFriends or not C_BattleNet then
    return
  end

  local ok, friendCount = pcall(BNGetNumFriends)
  if not ok or type(friendCount) ~= "number" then
    return
  end

  local previous = self.friendsByBattleTag
  local byBattleTag = {}
  local byGameAccount = {}
  local byCharacter = {}

  for friendIndex = 1, friendCount do
    local accountOK, accountInfo = pcall(C_BattleNet.GetFriendAccountInfo, friendIndex)
    if accountOK and type(accountInfo) == "table" then
      local key = Util:NormalizeBattleTag(accountInfo.battleTag)
      if key then
        local runtimePeer = {
          key = key,
          battleTag = accountInfo.battleTag,
          displayName = accountInfo.battleTag,
          bnetAccountID = accountInfo.bnetAccountID,
          online = false,
          routes = {},
        }

        local countOK, gameCount = pcall(C_BattleNet.GetFriendNumGameAccounts, friendIndex)
        if not countOK or type(gameCount) ~= "number" then
          gameCount = 0
        end
        -- For each of this friend's game accounts, keep only retail WoW
        -- sessions and record them as delivery routes (gameAccountID /
        -- character) so we can address messages to that peer later.
        for accountIndex = 1, gameCount do
          local gameOK, gameInfo = pcall(C_BattleNet.GetFriendGameAccountInfo, friendIndex, accountIndex)
          if gameOK and type(gameInfo) == "table" and isRetailWow(gameInfo) then
            local route = {
              key = key,
              battleTag = accountInfo.battleTag,
              displayName = accountInfo.battleTag,
              bnetAccountID = accountInfo.bnetAccountID,
              gameAccountID = gameInfo.gameAccountID,
              characterTarget = characterTarget(gameInfo),
              characterName = gameInfo.characterName,
              online = true,
            }
            -- Mark peer online, append this route, and index it for gameAccount/character lookup.
            runtimePeer.online = true
            runtimePeer.routes[#runtimePeer.routes + 1] = route
            if route.gameAccountID then
              byGameAccount[tostring(route.gameAccountID)] = route
            end
            if route.characterTarget then
              byCharacter[Util:NormalizeCharacterName(route.characterTarget)] = route
            end
          end
        end
        -- Prefer the first retail route as the peer's primary target, then store/refresh the peer.
        local primaryRoute = runtimePeer.routes[1]
        if primaryRoute then
          runtimePeer.gameAccountID = primaryRoute.gameAccountID
          runtimePeer.characterTarget = primaryRoute.characterTarget
          runtimePeer.characterName = primaryRoute.characterName
        end
        byBattleTag[key] = runtimePeer
        local storedPeer = addon.db.peers[key]
        if storedPeer then
          storedPeer.key = key
          storedPeer.battleTag = accountInfo.battleTag
          storedPeer.displayName = accountInfo.battleTag
        end
      end
    end
  end

  self.friendsByBattleTag = byBattleTag
  self.friendsByGameAccount = byGameAccount
  self.friendsByCharacter = byCharacter

  -- Hello newly-online peers (or all, if announcing); send friend-index to approved ones.
  for key, runtimePeer in pairs(byBattleTag) do
    if runtimePeer.online and (announce or not (previous[key] and previous[key].online)) then
      self:SendHello(runtimePeer)
      local peer = addon.db.peers[key]
      if peer and peer.approved then
        self:SendIndex(peer)
      end
    end
  end
end

-- Debounces friend-list refreshes so a burst of Battle.net events results in a
-- single rebuild two seconds later.
function Protocol:ScheduleFriendRefresh()
  if self.friendRefreshTimer then
    self.friendRefreshTimer:Cancel()
  end
  self.friendRefreshTimer = C_Timer.NewTimer(2, function()
    self.friendRefreshTimer = nil
    self:RefreshFriends(false)
  end)
end

-- Maps an incoming message's sender (a Battle.net game account ID or a character
-- name) to a runtime peer, querying and caching the account on a cache miss.
function Protocol:ResolveSender(sourceType, sourceID)
  -- If sender is cached return cached, else look up account and build a cached friend
  if sourceType == "BNET" then
    local cached = self.friendsByGameAccount[tostring(sourceID)]
    if cached then
      return cached
    end
    -- Cache miss: ask the game who owns this game account, but only if the
    -- Battle.net APIs we need are actually available.
    if C_BattleNet and C_BattleNet.GetGameAccountInfoByID and C_BattleNet.GetAccountInfoByGUID then
      local gameOK, gameInfo = pcall(C_BattleNet.GetGameAccountInfoByID, sourceID)
      if gameOK and type(gameInfo) == "table" and gameInfo.playerGuid then
        local accountOK, accountInfo = pcall(C_BattleNet.GetAccountInfoByGUID, gameInfo.playerGuid)
        if accountOK and type(accountInfo) == "table" and accountInfo.isFriend then
          local key = Util:NormalizeBattleTag(accountInfo.battleTag)
          if key then
            local runtimePeer = {
              key = key,
              battleTag = accountInfo.battleTag,
              displayName = accountInfo.battleTag,
              bnetAccountID = accountInfo.bnetAccountID,
              gameAccountID = gameInfo.gameAccountID,
              characterTarget = characterTarget(gameInfo),
              characterName = gameInfo.characterName,
              online = isRetailWow(gameInfo),
            }
            self.friendsByBattleTag[key] = runtimePeer
            self.friendsByGameAccount[tostring(sourceID)] = runtimePeer
            if runtimePeer.characterTarget then
              self.friendsByCharacter[Util:NormalizeCharacterName(runtimePeer.characterTarget)] = runtimePeer
            end
            return runtimePeer
          end
        end
      end
    end
    return nil
  end
  return self.friendsByCharacter[Util:NormalizeCharacterName(sourceID)]
end

-- Gatekeeper for inbound frames: the sender must be a known friend, and anything
-- other than a HELLO also requires that the friend has been approved locally.
function Protocol:CanReceiveFrame(sourceType, sourceID, kind)
  if not addon.runtime.initialized or not addon.db then
    return false
  end
  local runtimePeer = self:ResolveSender(sourceType, sourceID)
  if not runtimePeer then
    return false
  end
  if kind == "HELLO" then
    return sourceType == "BNET"
  end
  local peer = addon.db.peers[runtimePeer.key]
  return peer and peer.approved == true
end

-- Returns the saved-variables record for a runtime peer, optionally creating it,
-- and refreshes its identity fields from the live friend data.
function Protocol:GetStoredPeer(runtimePeer, create)
  if not runtimePeer or not runtimePeer.key then
    return nil
  end
  local peer = addon.db.peers[runtimePeer.key]
  if not peer and create then
    peer = {
      battleTag = runtimePeer.battleTag,
      displayName = runtimePeer.displayName,
      approved = false,
      available = false,
      snapshots = {},
      fingerprints = {},
      lastSync = 0,
    }
    addon.db.peers[runtimePeer.key] = peer
  end
  if peer then
    peer.key = runtimePeer.key
    peer.battleTag = runtimePeer.battleTag
    peer.displayName = runtimePeer.displayName
    peer.snapshots = type(peer.snapshots) == "table" and peer.snapshots or {}
    peer.fingerprints = type(peer.fingerprints) == "table" and peer.fingerprints or {}
    if runtimePeer.gameAccountID then
      peer.preferredGameAccountID = runtimePeer.gameAccountID
    end
  end
  return peer
end

-- Inverse of GetStoredPeer: finds the live friend entry for a stored peer,
-- preferring the game account it was last reached on.
function Protocol:GetRuntimePeer(peer)
  if not peer then
    return nil
  end
  local key = peer.key or Util:NormalizeBattleTag(peer.battleTag)
  local aggregate = key and self.friendsByBattleTag[key] or nil
  if aggregate and peer.preferredGameAccountID then
    local preferred = self.friendsByGameAccount[tostring(peer.preferredGameAccountID)]
    if preferred and preferred.key == key then
      return preferred
    end
  end
  return aggregate
end

-- Hands a message to the transport for either a stored or runtime peer, failing
-- fast when that friend is not currently online.
function Protocol:SendTo(peerOrRuntime, kind, body, priority)
  if type(peerOrRuntime) ~= "table" then
    return false, "missing peer"
  end
  local runtimePeer = peerOrRuntime.gameAccountID and peerOrRuntime or self:GetRuntimePeer(peerOrRuntime)
  if not runtimePeer or not runtimePeer.online then
    return false, "friend is offline"
  end
  return Transport:Send(runtimePeer, kind, body, priority)
end

-- Announces this addon's version info to every game account a friend is logged in
-- on, deferring the handshake when addon chat is locked down.
function Protocol:SendHello(runtimePeer)
  if Transport:IsLockedDown() then
    if runtimePeer and runtimePeer.key then
      self.pendingHello[runtimePeer.key] = true
    end
    return false, "addon chat is locked down"
  end
  local body = {
    companionVersion = addon.version,
    alterEgoVersion = Util:GetAlterEgoVersion(),
    alterEgoDBVersion = Util:GetAlterEgoDBVersion(),
  }
  if runtimePeer.routes and #runtimePeer.routes > 0 then
    local sent = false
    for _, route in ipairs(runtimePeer.routes) do
      sent = self:SendTo(route, "HELLO", body, "NORMAL") or sent
    end
    return sent
  end
  return self:SendTo(runtimePeer, "HELLO", body, "NORMAL")
end

-- Sends an approved friend the fingerprint of every local character so they can
-- request only the records that changed; deferred during a chat lockdown.
function Protocol:SendIndex(peer)
  if not peer or not peer.approved then
    return false, "friend is not approved"
  end
  local key = peer.key or Util:NormalizeBattleTag(peer.battleTag)
  if Transport:IsLockedDown() then
    if key then
      self.pendingIndex[key] = true
    end
    return false, "addon chat is locked down"
  end
  local _, fingerprints = Snapshot:BuildOwn()
  local sent, err = self:SendTo(peer, "INDEX", {
    fingerprints = fingerprints,
    alterEgoVersion = Util:GetAlterEgoVersion(),
    alterEgoDBVersion = Util:GetAlterEgoDBVersion(),
  }, "NORMAL")
  if sent and key then
    self.pendingIndex[key] = nil
  end
  return sent, err
end

-- Send the handshakes and fingerprint maps deferred during a chat lockdown.
function Protocol:FlushPending()
  -- Restriction events can arrive before PLAYER_LOGIN builds the database.
  if not addon.db or Transport:IsLockedDown() then
    return
  end

  local hello = self.pendingHello
  self.pendingHello = {}
  for key in pairs(hello) do
    local runtimePeer = self.friendsByBattleTag[key]
    if runtimePeer and runtimePeer.online then
      self:SendHello(runtimePeer)
    end
  end

  local index = self.pendingIndex
  self.pendingIndex = {}
  for key in pairs(index) do
    local peer = addon.db.peers[key]
    if peer and peer.approved then
      self:SendIndex(peer)
    end
  end
end

-- Answers a peer's REQ by sending back the snapshots for the requested GUIDs,
-- capped at 200 records and queued at bulk priority.
function Protocol:SendRequestedData(peer, guids)
  if not peer.approved or type(guids) ~= "table" then
    return
  end
  local records, fingerprints = Snapshot:BuildOwn()
  local requestedRecords = {}
  local requestedFingerprints = {}
  local count = 0
  for _, guid in ipairs(guids) do
    if records[guid] and count < 200 then
      requestedRecords[guid] = records[guid]
      requestedFingerprints[guid] = fingerprints[guid]
      count = count + 1
    end
  end
  self:SendTo(peer, "DATA", {
    records = requestedRecords,
    fingerprints = requestedFingerprints,
    alterEgoDBVersion = Util:GetAlterEgoDBVersion(),
  }, "BULK")
end

-- Entry point for decoded frames: resolves the sender and dispatches the envelope
-- to the handler for its kind, dropping data messages from unapproved friends.
function Protocol:Receive(sourceType, sourceID, envelope)
  local runtimePeer = self:ResolveSender(sourceType, sourceID)
  if not runtimePeer then
    return
  end

  local peer = self:GetStoredPeer(runtimePeer, envelope.kind == "HELLO")
  if not peer then
    return
  end

  if envelope.kind == "HELLO" then
    self:ReceiveHello(peer, envelope.body)
    return
  end

  -- All data-bearing messages require explicit local approval.
  if not peer.approved then
    return
  end
  if envelope.kind == "INDEX" then
    self:ReceiveIndex(peer, envelope.body)
  elseif envelope.kind == "REQ" then
    self:ReceiveRequest(peer, envelope.body)
  elseif envelope.kind == "DATA" then
    self:ReceiveData(peer, envelope.body)
  elseif envelope.kind == "SYNC" then
    self:SendIndex(peer)
  end
end

-- Records a peer's advertised versions and marks them available, replying with our
-- own HELLO when they were not already known to be running the addon.
function Protocol:ReceiveHello(peer, body)
  if type(body) ~= "table" then
    return
  end
  local wasAvailable = peer.available == true
  peer.available = true
  peer.lastSeen = Util:Now()
  peer.remoteCompanionVersion = tostring(body.companionVersion or "unknown")
  peer.remoteAlterEgoVersion = tostring(body.alterEgoVersion or "unknown")
  peer.remoteDBVersion = tonumber(body.alterEgoDBVersion) or 0
  if addon.UI then
    addon.UI:RefreshTitlebar()
  end
  -- If this is a new friend, send them a HELLO to kick off the handshake.
  if not wasAvailable then
    local runtimePeer = self:GetRuntimePeer(peer)
    if runtimePeer then
      self:SendHello(runtimePeer)
    end
  end
end

-- True when a peer is online and has completed a handshake within the last two
-- minutes, meaning they are reachable for a sync right now.
function Protocol:IsAvailable(peer)
  if not peer or not peer.available or type(peer.lastSeen) ~= "number" then
    return false
  end
  local runtimePeer = self:GetRuntimePeer(peer)
  return runtimePeer ~= nil and runtimePeer.online == true and (Util:Now() - peer.lastSeen) <= 120
end

-- Verifies both sides run the same AlterEgo database version, storing and printing
-- an explanation when they differ so mismatched records are never merged.
function Protocol:IsCompatible(peer, remoteDBVersion)
  local localVersion = Util:GetAlterEgoDBVersion()
  remoteDBVersion = tonumber(remoteDBVersion or peer.remoteDBVersion) or 0
  if localVersion ~= remoteDBVersion then
    peer.compatibilityError = "AlterEgo database versions differ (" .. localVersion .. " vs " .. remoteDBVersion .. ")"
    addon:Print(peer.battleTag .. " cannot sync: " .. peer.compatibilityError .. ".")
    return false
  end
  peer.compatibilityError = nil
  return true
end

-- Diffs a peer's fingerprint map against our cache: drops characters they no longer
-- have and requests the ones that are new or changed.
function Protocol:ReceiveIndex(peer, body)
  if type(body) ~= "table" or type(body.fingerprints) ~= "table" then
    return
  end
  if not self:IsCompatible(peer, body.alterEgoDBVersion) then
    return
  end

  local request = {}
  local remoteSet = {}
  local count = 0
  for guid, fingerprint in pairs(body.fingerprints) do
    if type(guid) == "string" and type(fingerprint) == "string" and count < 200 then
      remoteSet[guid] = true
      -- If the fingerprint or snapshot is missing or different, request the record.
      if peer.fingerprints[guid] ~= fingerprint or not peer.snapshots[guid] then
        request[#request + 1] = guid
      end
      count = count + 1
    end
  end

  -- Drop records we no longer have.
  for guid in pairs(peer.snapshots) do
    if not remoteSet[guid] then
      peer.snapshots[guid] = nil
      peer.fingerprints[guid] = nil
    end
  end

  if #request > 0 then
    -- Send the request to the peer.
    self:SendTo(peer, "REQ", {guids = request}, "NORMAL")
  else
    -- If no requests were made, mark the peer as synced and refresh the view.
    peer.lastSync = Util:Now()
    if addon.Injection then
      addon.Injection:RefreshView()
    end
  end
end

-- Validates an incoming REQ payload and forwards its GUID list to
-- SendRequestedData.
function Protocol:ReceiveRequest(peer, body)
  if type(body) ~= "table" or type(body.guids) ~= "table" then
    return
  end
  self:SendRequestedData(peer, body.guids)
end

-- Stores incoming character records after checking each one's shape and matching
-- its fingerprint, then refreshes the AlterEgo view if anything was accepted.
function Protocol:ReceiveData(peer, body)
  if type(body) ~= "table" or type(body.records) ~= "table" or type(body.fingerprints) ~= "table" then
    return
  end
  if not self:IsCompatible(peer, body.alterEgoDBVersion) then
    return
  end

  local accepted = 0 
  -- Process the incoming records, stopping at 200 or the end of the list.
  for guid, record in pairs(body.records) do
    if accepted >= 200 then
      break
    end
    -- Check if the record is valid and matches the GUID.
    if type(record) == "table" and guid == record.GUID and Snapshot:IsValidRecord(record) then
      local normalized = Snapshot:Trim(record)
      local fingerprint = normalized and Snapshot:Fingerprint(normalized)
      -- Check if the fingerprint matches the expected one.
      if fingerprint == body.fingerprints[guid] then
        peer.snapshots[guid] = normalized
        peer.fingerprints[guid] = fingerprint
        accepted = accepted + 1
      end
    end
  end

  -- If any records were accepted, mark the peer as synced and refresh the view.
  if accepted > 0 then
    peer.lastSync = Util:Now()
    addon:Debug("Received " .. accepted .. " character update(s) from " .. peer.battleTag)
    if addon.Injection then
      addon.Injection:RefreshView()
    end
    if addon.UI then
      addon.UI:RefreshTitlebar()
    end
  end
end

-- Compares fresh local fingerprints against the last known set and pushes an INDEX
-- to every approved friend when a character changed (or when force is set).
function Protocol:CheckForChanges(force)
  local _, fingerprints = Snapshot:BuildOwn()
  local changed = force == true
  if not changed then
    -- Check if any of our own fingerprints changed.
    for guid, fingerprint in pairs(fingerprints) do
      if self.lastLocalFingerprints[guid] ~= fingerprint then
        changed = true
        break
      end
    end
    -- If no fingerprints changed, check if any of our own fingerprints are missing.
    if not changed then
      for guid in pairs(self.lastLocalFingerprints) do
        if not fingerprints[guid] then
          changed = true
          break
        end
      end
    end
  end
  self.lastLocalFingerprints = fingerprints

  -- If any fingerprints changed, send an INDEX to every approved friend.
  if changed then
    for _, peer in pairs(addon.db.peers) do
      if peer.approved then
        self:SendIndex(peer)
      end
    end
  end
end

-- Debounces change detection so a flurry of game events (zoning, loot, lockout
-- updates) triggers a single check five seconds later.
function Protocol:ScheduleChangeCheck()
  -- Cancel any existing timer and schedule a new one for five seconds later.
  if self.changeTimer then
    self.changeTimer:Cancel()
  end
  -- Schedule a new timer for five seconds later.
  self.changeTimer = C_Timer.NewTimer(5, function()
    self.changeTimer = nil
    self:CheckForChanges()
  end)
end

-- Looks up a stored peer by BattleTag, preferring an exact match and accepting a
-- single substring match; returns an error when the query is ambiguous.
function Protocol:FindPeer(query, requireAvailable)
  query = query and query:lower() or ""
  local exact
  local partial
  for key, peer in pairs(addon.db.peers) do
    -- Check if the peer is available and matches the query.
    if not requireAvailable or self:IsAvailable(peer) then
      local label = (peer.battleTag or key):lower()
      -- Check if the peer's label matches the query exactly or partially.
      if label == query or key == query then
        exact = peer
      elseif label:find(query, 1, true) then
        if partial then
          return nil, "more than one friend matches"
        end
        partial = peer
      end
    end
  end
  -- Return the exact or partial match.
  return exact or partial
end

-- Grants a friend permission to exchange character data and immediately kicks off
-- a two-way sync with them.
function Protocol:Approve(query)
  local peer, err = self:FindPeer(query, true)
  if not peer then
    return false, err or "friend not found; both players must be online once for discovery"
  end
  peer.approved = true
  addon:Print("Approved " .. peer.battleTag .. " for AlterEgo sync.")
  self:SendTo(peer, "SYNC", {}, "NORMAL")
  self:SendIndex(peer)
  return true
end

-- Refreshes the friend list and asks every approved peer for their index while
-- sending ours, forcing a full round of reconciliation.
function Protocol:SyncAll()
  self:RefreshFriends(false)
  for _, peer in pairs(addon.db.peers) do
    if peer.approved then
      self:SendTo(peer, "SYNC", {}, "NORMAL")
      self:SendIndex(peer)
    end
  end
end

-- Withdraws a friend's approval and deletes every snapshot cached from them, then
-- refreshes the view so their characters disappear.
function Protocol:Revoke(query)
  local peer, err = self:FindPeer(query, false)
  if not peer then
    return false, err or "friend not found"
  end
  peer.approved = false
  peer.snapshots = {}
  peer.fingerprints = {}
  peer.lastSync = 0
  if addon.Injection then
    addon.Injection:RefreshView()
  end
  addon:Print("Revoked and deleted cached data for " .. peer.battleTag .. ".")
  return true
end
