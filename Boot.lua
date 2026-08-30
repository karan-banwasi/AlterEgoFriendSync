local addonName, addon = ...

addon.name = addonName
addon.title = C_AddOns.GetAddOnMetadata(addonName, "Title") or addonName
addon.version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "0"
addon.protocolVersion = 1
addon.databaseVersion = 1
addon.prefix = "AEFriend"
-- icon attached to friends characters names
addon.marker = "|TInterface\\AddOns\\AlterEgo\\Media\\Icon_Characters.blp:12:12:0:0|t "

addon.modules = {}
addon.runtime = {
  initialized = false,
  timers = {},
}

-- Packaged releases keep this false. The BigWigs packager strips the
-- @debug@ block, so a git checkout in Interface/AddOns has debug on.
addon.debug = false
--@debug@
addon.debug = true
--@end-debug@

-- Reusable print to chat function prfixed with addon title
function addon:Print(message)
  (DEFAULT_CHAT_FRAME --[[@as MessageFrame]]):AddMessage("|cff3399ff" .. self.title .. ":|r " .. tostring(message))
end

-- Reusable debug print to chat function prfixed with addon title but grey text
function addon:Debug(message)
  if self.debug then
    self:Print("|cffaaaaaa" .. tostring(message) .. "|r")
  end
end
