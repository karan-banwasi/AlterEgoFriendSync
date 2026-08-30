local _, addon = ...

local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")

local Transport = {
  transfers = {},
  bnQueue = {},
  bnSending = false,
  nextTransferID = 0,
}
addon.Transport = Transport

-- Addon whispers cap at 255 bytes. Worst-case frame header is 27
-- ("1|HELLO|" + 10-hex transfer id + "|128|128|").
local CHAT_CHUNK_SIZE = 227
local BNET_CHUNK_SIZE = 3900
local MAX_CHUNKS = 128
local MAX_TRANSFER_BYTES = 256 * 1024
local MAX_DECOMPRESSED_BYTES = 512 * 1024
local MAX_ACTIVE_TRANSFERS = 32
local MAX_ACTIVE_TRANSFERS_PER_SENDER = 4
local TRANSFER_TIMEOUT = 30
local VALID_KINDS = {
  HELLO = true, -- discovery handshake (versions); accepted from unpaired Battle.net friends
  INDEX = true, -- fingerprint map of the sender's characters so the peer can request diffs
  REQ = true, -- request full records for a list of character GUIDs
  DATA = true, -- trimmed character records for the requested GUIDs
  SYNC = true, -- nudge the peer to send a fresh INDEX (approve / manual sync)
}

-- Look up an enum key, falling back if the table or key is missing.
local function enumValue(enumTable, key, fallback)
  return enumTable and enumTable[key] or fallback
end

local SEND_RESULT = Enum and Enum.SendAddonMessageResult or nil
local SUCCESS = enumValue(SEND_RESULT, "Success", 0)
local THROTTLED = enumValue(SEND_RESULT, "AddonMessageThrottle", 3)
local CHANNEL_THROTTLED = enumValue(SEND_RESULT, "ChannelThrottle", 8)
local LOCKDOWN = enumValue(SEND_RESULT, "AddOnMessageLockdown", 11)

-- Register the addon-message prefix and start the transfer-expiry ticker.
function Transport:Initialize()
  local result = C_ChatInfo.RegisterAddonMessagePrefix(addon.prefix)
  local registered = Enum and Enum.RegisterAddonMessagePrefixResult
  local success = registered and registered.Success or 0
  local duplicate = registered and registered.DuplicatePrefix or 1
  if result ~= success and result ~= duplicate then
    addon:Print("Could not register the addon-message prefix (result " .. tostring(result) .. ").")
  end

  self.cleanupTicker = C_Timer.NewTicker(10, function()
    self:ExpireTransfers()
  end)
end

-- Return whether WoW is currently blocking addon chat.
function Transport:IsLockedDown()
  if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
    return true
  end
  return false
end

-- Serialize (and compress, except HELLO) a kind/body envelope for the wire.
function Transport:EncodeEnvelope(kind, body)
  local envelope = {
    v = addon.protocolVersion,
    kind = kind,
    body = body,
  }
  local serialized = LibSerialize:Serialize(envelope)
  if kind == "HELLO" then
    -- HELLO is accepted from unpaired Battle.net friends, so keep it
    -- uncompressed to avoid exposing a decompressor to unapproved input.
    return LibDeflate:EncodeForWoWAddonChannel(serialized)
  end
  local compressed = LibDeflate:CompressDeflate(serialized)
  return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

-- Decode and validate a received envelope, skipping decompression for HELLO.
function Transport:DecodeEnvelope(payload, expectedKind)
  local decodeOK, decoded = pcall(LibDeflate.DecodeForWoWAddonChannel, LibDeflate, payload)
  if not decodeOK or not decoded then
    return nil
  end
  local decompressed = decoded
  if expectedKind ~= "HELLO" then
    local decompressOK, inflated = pcall(LibDeflate.DecompressDeflate, LibDeflate, decoded)
    if not decompressOK or type(inflated) ~= "string" or #inflated > MAX_DECOMPRESSED_BYTES then
      return nil
    end
    decompressed = inflated
  end
  local callOK, ok, envelope = pcall(LibSerialize.Deserialize, LibSerialize, decompressed)
  if not callOK then
    return nil
  end
  if not ok or type(envelope) ~= "table" then
    return nil
  end
  if envelope.v ~= addon.protocolVersion or type(envelope.kind) ~= "string" then
    return nil
  end
  return envelope
end

-- Check that global and per-sender transfer limits still have room.
function Transport:CanStartTransfer(sourceType, sourceID)
  local total = 0
  local senderTotal = 0
  local senderPrefix = sourceType .. ":" .. tostring(sourceID) .. ":"
  for key in pairs(self.transfers) do
    total = total + 1
    if key:sub(1, #senderPrefix) == senderPrefix then
      senderTotal = senderTotal + 1
    end
  end
  return total < MAX_ACTIVE_TRANSFERS and senderTotal < MAX_ACTIVE_TRANSFERS_PER_SENDER
end

-- Allocate a unique hex transfer id from time and a counter.
-- Example: "a1b2c31" (unpadded time hex + counter hex).
function Transport:NewTransferID()
  self.nextTransferID = self.nextTransferID + 1
  return string.format("%x%x", math.floor(GetTime() * 1000) % 0xFFFFFF, self.nextTransferID % 0xFFFF)
end

-- Split a payload into sequenced pipe-delimited chunks.
function Transport:FramePayload(kind, payload, chunkSize)
  local transferID = self:NewTransferID()
  local chunks = {}
  local total = math.max(1, math.ceil(#payload / chunkSize))
  if total > MAX_CHUNKS then
    return nil, "payload is too large"
  end
  for sequence = 1, total do
    local first = ((sequence - 1) * chunkSize) + 1
    local chunk = payload:sub(first, first + chunkSize - 1)
    chunks[sequence] = table.concat({
      tostring(addon.protocolVersion),
      kind,
      transferID,
      tostring(sequence),
      tostring(total),
      chunk,
    }, "|")
  end
  return chunks
end

-- Encode, frame, and queue a message to a peer over Battle.net or whisper.
function Transport:Send(peer, kind, body, priority)
  if type(peer) ~= "table" then
    return false, "missing peer"
  end

  local payload = self:EncodeEnvelope(kind, body)
  if #payload > MAX_TRANSFER_BYTES then
    return false, "payload is too large"
  end
  local route
  local chunkSize
  if peer.gameAccountID and C_BattleNet and C_BattleNet.SendGameData then
    route = "BNET"
    chunkSize = BNET_CHUNK_SIZE
  elseif peer.characterTarget then
    route = "WHISPER"
    chunkSize = CHAT_CHUNK_SIZE
  else
    return false, "peer is not online"
  end

  local chunks, err = self:FramePayload(kind, payload, chunkSize)
  if not chunks then
    return false, err
  end

  for _, chunk in ipairs(chunks) do
    if route == "BNET" then
      self.bnQueue[#self.bnQueue + 1] = {
        target = peer.gameAccountID,
        text = chunk,
        attempts = 0,
      }
    else
      self:QueueChatPacket(peer.characterTarget, chunk, priority or "BULK")
    end
  end

  -- Flush queue that was build in for loop above
  if route == "BNET" then
    self:PumpBattleNetQueue()
  end
  return true
end

-- Send a whisper addon packet via ChatThrottleLib, retrying on throttle or lockdown.
function Transport:QueueChatPacket(target, text, priority)
  local packet = {
    target = target,
    text = text,
    priority = priority,
  }

  -- Submit the packet, retrying after 1s if chat is locked down or throttled.
  local function submit()
    if self:IsLockedDown() then
      C_Timer.After(1, submit)
      return
    end
    ChatThrottleLib:SendAddonMessage(
      packet.priority,
      addon.prefix,
      packet.text,
      "WHISPER",
      packet.target,
      addon.prefix,
      function(_, didSend, result)
        if not didSend and (result == LOCKDOWN or result == THROTTLED or result == CHANNEL_THROTTLED) then
          C_Timer.After(1, submit)
        elseif not didSend then
          addon:Debug("Chat packet failed with result " .. tostring(result))
        end
      end
    )
  end

  submit()
end

-- Send the next Battle.net packet and schedule the following attempt.
function Transport:PumpBattleNetQueue()
  if self.bnSending or #self.bnQueue == 0 then
    return
  end
  if self:IsLockedDown() then
    return
  end

  self.bnSending = true
  local packet = self.bnQueue[1]
  packet.attempts = packet.attempts + 1
  -- The API stub declares no parameters, but the real signature is
  -- SendGameData(gameAccountID, prefix, text).
  ---@diagnostic disable-next-line: redundant-parameter
  local result = C_BattleNet.SendGameData(packet.target, addon.prefix, packet.text)

  if result == SUCCESS or result == true or result == nil then
    table.remove(self.bnQueue, 1)
  elseif result == THROTTLED or result == CHANNEL_THROTTLED or result == LOCKDOWN then
    -- Keep it at the head of the queue and retry after the throttle/lockdown clears.
  else
    addon:Debug("Battle.net packet failed with result " .. tostring(result))
    table.remove(self.bnQueue, 1)
  end

  local delay = (result == THROTTLED or result == CHANNEL_THROTTLED) and 1 or (0.20 + math.random() * 0.10)
  C_Timer.After(delay, function()
    self.bnSending = false
    self:PumpBattleNetQueue()
  end)
end

-- Resume deferred traffic when addon-message restrictions lift. The event also
-- fires for restriction types we do not care about (combat, map), so confirm
-- chat is actually usable before flushing.
function Transport:OnRestrictionsChanged(state)
  local inactive = enumValue(Enum and Enum.AddOnRestrictionState, "Inactive", 0)
  if state ~= inactive or self:IsLockedDown() then
    return
  end
  self:PumpBattleNetQueue()
  if addon.Protocol then
    addon.Protocol:FlushPending()
  end
end

-- Parse a framed packet into version, kind, transfer id, sequence, total, and payload.
local function parseFrame(text)
  if type(text) ~= "string" then
    return nil
  end
  local separators = {}
  local start = 1
  for index = 1, 5 do
    local position = text:find("|", start, true)
    if not position then
      return nil
    end
    separators[index] = position
    start = position + 1
  end

  local version = tonumber(text:sub(1, separators[1] - 1))
  local kind = text:sub(separators[1] + 1, separators[2] - 1)
  local transferID = text:sub(separators[2] + 1, separators[3] - 1)
  local sequence = tonumber(text:sub(separators[3] + 1, separators[4] - 1))
  local total = tonumber(text:sub(separators[4] + 1, separators[5] - 1))
  local payload = text:sub(separators[5] + 1)
  return version, kind, transferID, sequence, total, payload
end

-- Reassemble incoming chunks and hand a complete envelope to Protocol.
function Transport:Receive(sourceType, sourceID, text)
  local version, kind, transferID, sequence, total, payload = parseFrame(text)
  if version ~= addon.protocolVersion or not VALID_KINDS[kind] or not transferID or transferID == "" then
    return
  end
  if not sequence or not total or sequence < 1 or sequence > total or total > MAX_CHUNKS then
    return
  end
  if kind == "HELLO" and total ~= 1 then
    return
  end
  if not addon.Protocol or not addon.Protocol:CanReceiveFrame(sourceType, sourceID, kind) then
    return
  end

  local key = sourceType .. ":" .. tostring(sourceID) .. ":" .. kind .. ":" .. transferID
  local transfer = self.transfers[key]
  if not transfer then
    if not self:CanStartTransfer(sourceType, sourceID) then
      return
    end
    transfer = {
      created = GetTime(),
      chunks = {},
      received = 0,
      bytes = 0,
      total = total,
    }
    self.transfers[key] = transfer
  elseif transfer.total ~= total then
    self.transfers[key] = nil
    return
  end

  if not transfer.chunks[sequence] then
    transfer.chunks[sequence] = payload
    transfer.received = transfer.received + 1
    transfer.bytes = transfer.bytes + #payload
  end
  if transfer.bytes > MAX_TRANSFER_BYTES then
    self.transfers[key] = nil
    return
  end

  if transfer.received == transfer.total then
    local complete = table.concat(transfer.chunks)
    self.transfers[key] = nil
    local envelope = self:DecodeEnvelope(complete, kind)
    if envelope and envelope.kind == kind and addon.Protocol then
      addon.Protocol:Receive(sourceType, sourceID, envelope)
    end
  end
end

-- Drop incomplete transfers that have exceeded the timeout.
function Transport:ExpireTransfers()
  local now = GetTime()
  for key, transfer in pairs(self.transfers) do
    if now - transfer.created > TRANSFER_TIMEOUT then
      self.transfers[key] = nil
    end
  end
end
