-- Lightweight runtime tests for pure-data behavior. Run from the repository
-- root with: npx -p fengari-node-cli fengari tests/addon_test.lua
--
-- Cases run top-to-bottom and share mutable fixture state. Keep that order.

--------------------------------------------------------------------------------
-- Environment stubs (Fengari / WoW API surface used by the addon)
--------------------------------------------------------------------------------

_G = _G or _ENV
function strmatch(value, pattern) return string.match(value, pattern) end

C_AddOns = {
  GetAddOnMetadata = function(name, field)
    if field == "Title" then return name end
    if field == "Version" then return "test" end
  end,
}
DEFAULT_CHAT_FRAME = {AddMessage = function(_, message) end}
GetServerTime = function() return 1000 end
GetTime = function() return 10 end
time = function() return 1000 end

-- Fengari provides these; WoW's Lua LS runtime does not declare them.
---@type fun(filename: string)
local dofile = _G["dofile"]
---@type fun(filename: string): function?
local loadfile = _G["loadfile"]

dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/LibSerialize/LibSerialize.lua")
dofile("Libs/LibDeflate/LibDeflate.lua")

local function check(case, condition, message)
  assert(condition, case .. ": " .. (message or "failed"))
end

--------------------------------------------------------------------------------
-- Shared fixture
--------------------------------------------------------------------------------

local addon = {}

local function loadModule(filename)
  local chunk = assert(loadfile(filename), "missing " .. filename)
  chunk("AlterEgoFriendSync", addon)
end

local function resetFixture()
  addon.db = {injected = {}}
  AlterEgoDB = {
    global = {
      dbVersion = 38,
      characters = {
        ["Player-1"] = {
          GUID = "Player-1",
          lastUpdate = 100,
          enabled = true,
          order = 9,
          currentSeason = 1,
          info = {
            name = "Alpha",
            realm = "Realm",
            level = 80,
            race = {name = "Human"},
            class = {file = "MAGE", id = 8},
            factionGroup = {},
            ilvl = {level = 600},
            guild = {},
          },
          mythicplus = {
            rating = 1234,
            numCompletedDungeonRuns = {},
            keystone = {level = 7},
            runHistory = {},
            dungeons = {},
          },
          vault = {},
          raids = {},
          equipment = {{itemLink = "must not be shared"}},
          currencies = {{id = 1, quantity = 99}},
        },
      },
    },
  }
end

loadModule("Boot.lua")
check("boot", addon.debug == true, "git checkout must enable addon.debug via the @debug@ block")
loadModule("Util.lua")
loadModule("Snapshot.lua")
resetFixture()

--------------------------------------------------------------------------------
-- Snapshot
--------------------------------------------------------------------------------

local function test_snapshot_build_own()
  local records = addon.Snapshot:BuildOwn()
  check("snapshot/build", records["Player-1"], "own character was not snapshotted")
  check("snapshot/build", #records["Player-1"].equipment == 0, "equipment leaked into snapshot")
  check("snapshot/build", #records["Player-1"].currencies == 0, "currencies leaked into snapshot")
  check("snapshot/build", records["Player-1"].mythicplus.rating == 1234, "core data missing")
end

local function test_snapshot_trim_sanitizes()
  local records = addon.Snapshot:BuildOwn()
  local malformed = addon.Util:CopySerializable(records["Player-1"])
  malformed.info.level = {}
  malformed.info.ilvl.level = "not-a-number"
  malformed.mythicplus.dungeons = {
    {challengeModeID = {}, affixScores = {{score = "bad", durationSec = {}}}},
  }

  local sanitized = addon.Snapshot:Trim(malformed)
  check("snapshot/trim", sanitized.info.level == 0, "malformed level was not sanitized")
  check("snapshot/trim", sanitized.info.ilvl.level == 0, "malformed item level was not sanitized")
  check(
    "snapshot/trim",
    sanitized.mythicplus.dungeons[1].challengeModeID == 0,
    "malformed dungeon ID was not sanitized"
  )
  check(
    "snapshot/trim",
    sanitized.mythicplus.dungeons[1].affixScores[1].durationSec == 0,
    "malformed affix data was not sanitized"
  )
end

local function test_snapshot_fingerprint()
  local _, fingerprints = addon.Snapshot:BuildOwn()
  local firstFingerprint = fingerprints["Player-1"]

  AlterEgoDB.global.characters["Player-1"].lastUpdate = 999
  AlterEgoDB.global.characters["Player-1"].order = 1
  local _, secondFingerprints = addon.Snapshot:BuildOwn()
  check(
    "snapshot/fingerprint",
    firstFingerprint == secondFingerprints["Player-1"],
    "volatile fields changed the fingerprint"
  )

  AlterEgoDB.global.characters["Player-1"].mythicplus.rating = 1300
  local _, thirdFingerprints = addon.Snapshot:BuildOwn()
  check(
    "snapshot/fingerprint",
    firstFingerprint ~= thirdFingerprints["Player-1"],
    "core change did not change the fingerprint"
  )
end

local function test_snapshot_excludes_injected()
  addon.db.injected["Player-1"] = "friend#1234"
  local excluded = addon.Snapshot:BuildOwn()
  check("snapshot/injected", not excluded["Player-1"], "injected friend character was re-shared")
  addon.db.injected = {}
end

--------------------------------------------------------------------------------
-- Injection
--------------------------------------------------------------------------------

local function setup_injection()
  local aceAddon = LibStub:NewLibrary("AceAddon-3.0", 1)
  aceAddon.GetAddon = function()
    return {
      Render = function()
        for _, character in pairs(AlterEgoDB.global.characters) do
          character.order = (character.order or 0) + 1
        end
      end,
    }
  end

  addon.db.settings = {view = "mine"}
  addon.db.hiddenOwn = {}

  local remoteRecord = addon.Snapshot:Trim(AlterEgoDB.global.characters["Player-1"])
  remoteRecord.GUID = "Player-2"
  remoteRecord.info.name = "Beta"
  addon.db.peers = {
    ["friend#1234"] = {
      approved = true,
      snapshots = {["Player-2"] = remoteRecord},
    },
  }

  loadModule("Injection.lua")
end

local function test_injection_views()
  setup_injection()
  local ownBeforeView = addon.Snapshot:SerializeStable(AlterEgoDB.global.characters["Player-1"])

  addon.Injection:SetView("both")
  check("injection/both", AlterEgoDB.global.characters["Player-1"], "both view removed own character")
  check("injection/both", AlterEgoDB.global.characters["Player-2"], "both view did not inject friend")
  check(
    "injection/both",
    AlterEgoDB.global.characters["Player-2"].info.name:find("Beta", 1, true),
    "friend marker removed name"
  )

  addon.Injection:SetView("friend")
  check(
    "injection/friend",
    AlterEgoDB.global.characters["Player-1"].enabled == false,
    "friend view did not hide own character"
  )
  check(
    "injection/friend",
    AlterEgoDB.global.characters["Player-2"].enabled == true,
    "friend view hid friend character"
  )

  addon.Injection:Shutdown()
  check(
    "injection/shutdown",
    AlterEgoDB.global.characters["Player-1"].enabled == true,
    "shutdown did not restore own state"
  )
  check(
    "injection/shutdown",
    not AlterEgoDB.global.characters["Player-2"],
    "shutdown did not purge injected friend"
  )
  check(
    "injection/shutdown",
    ownBeforeView == addon.Snapshot:SerializeStable(AlterEgoDB.global.characters["Player-1"]),
    "view cycle changed the own-character record"
  )
end

--------------------------------------------------------------------------------
-- Transport
--------------------------------------------------------------------------------

local function setup_transport()
  C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return 0 end,
    InChatMessagingLockdown = function() return false end,
    AreOutgoingAddonChatMessagesRestricted = function() return false end,
  }
  C_BattleNet = {SendGameData = function() return 0 end}
  C_Timer = {
    NewTicker = function() return {Cancel = function() end} end,
    After = function(_, callback) callback() end,
  }
  Enum = {
    SendAddonMessageResult = {
      Success = 0,
      AddonMessageThrottle = 3,
      ChannelThrottle = 8,
      AddOnMessageLockdown = 11,
    },
    RegisterAddonMessagePrefixResult = {Success = 0, DuplicatePrefix = 1},
  }

  loadModule("Transport.lua")

  -- LibDeflate targets WoW's Lua 5.1 numeric/bit behavior and its compressed
  -- output does not round-trip under Fengari's Lua 5.3 VM. Keep transport logic
  -- testable here with an identity codec; the bundled canonical LibDeflate build
  -- must be exercised in the live-client checklist.
  local deflater = LibStub("LibDeflate")
  deflater.CompressDeflate = function(_, value) return value end
  deflater.DecompressDeflate = function(_, value) return value end
  deflater.EncodeForWoWAddonChannel = function(_, value) return value end
  deflater.DecodeForWoWAddonChannel = function(_, value) return value end
end

local function test_serializer_round_trip()
  local serializer = LibStub("LibSerialize")
  local raw = serializer:Serialize({value = "round trip"})
  local deserializeOK = serializer:Deserialize(raw)
  check("transport/serialize", deserializeOK, "serializer round-trip failed")
end

local function test_transport_out_of_order_reassembly()
  local received
  addon.Protocol = {
    CanReceiveFrame = function() return true end,
    Receive = function(_, sourceType, sourceID, envelope)
      received = {sourceType, sourceID, envelope}
    end,
  }

  local payload = addon.Transport:EncodeEnvelope("DATA", {value = string.rep("abc", 1000)})
  local directEnvelope = addon.Transport:DecodeEnvelope(payload, "DATA")
  check(
    "transport/envelope",
    directEnvelope and directEnvelope.kind == "DATA",
    "direct envelope round-trip failed"
  )

  local chunks = assert(addon.Transport:FramePayload("DATA", payload, 100))
  for index = #chunks, 1, -1 do
    addon.Transport:Receive("BNET", 42, chunks[index])
  end

  check("transport/reassemble", received, "out-of-order transfer was not reassembled")
  check("transport/reassemble", received[1] == "BNET" and received[2] == 42, "sender metadata changed")
  check("transport/reassemble", received[3].kind == "DATA", "message kind changed")
  check(
    "transport/reassemble",
    received[3].body.value == string.rep("abc", 1000),
    "payload changed"
  )
end

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------

test_snapshot_build_own()
test_snapshot_trim_sanitizes()
test_snapshot_fingerprint()
test_snapshot_excludes_injected()

test_injection_views()

setup_transport()
test_serializer_round_trip()
test_transport_out_of_order_reassembly()

print("AlterEgoFriend data and transport tests passed.")
