local _, addon = ...

local Util = addon.Util

local Injection = {}
addon.Injection = Injection

-- Recover any leftover filter state after load, then clear injected friends.
function Injection:Initialize()
  -- Recover first from a reload or prior crash that happened while a filtered
  -- view was active, before AlterEgo can persist companion-owned mutations.
  self:RestoreHiddenOwn()
  self:PurgeInjected()
  self:HookAlterEgoRender()
end

-- Put back enabled/order for own characters that were hidden in a prior session.
function Injection:RestoreHiddenOwn()
  local characters = Util:GetAlterEgoCharacters()
  if not characters then
    return
  end
  for guid, state in pairs(addon.db.hiddenOwn or {}) do
    if characters[guid] and not addon.db.injected[guid] then
      if type(state) == "table" then
        characters[guid].enabled = state.enabled == "nil" and nil or state.enabled
        characters[guid].order = state.order == "nil" and nil or state.order
      else
        -- Compatibility with the first development schema.
        characters[guid].enabled = state == true
      end
    end
  end
  addon.db.hiddenOwn = {}
end

-- Save AlterEgo checkbox choices for currently injected friend characters.
function Injection:CaptureFriendVisibility()
  local characters = Util:GetAlterEgoCharacters()
  if not characters then
    return
  end
  addon.db.disabledFriends = addon.db.disabledFriends or {}
  for guid, owner in pairs(addon.db.injected or {}) do
    local character = characters[guid]
    if character and character._AEFriendOwner == owner then
      local disabled = addon.db.disabledFriends[owner]
      if character.enabled == false then
        disabled = disabled or {}
        disabled[guid] = true
        addon.db.disabledFriends[owner] = disabled
      elseif disabled then
        disabled[guid] = nil
        if not next(disabled) then
          addon.db.disabledFriends[owner] = nil
        end
      end
    end
  end
end

-- Observe AlterEgo redraws so checkbox changes are persisted immediately.
function Injection:HookAlterEgoRender()
  if self.renderHooked or not hooksecurefunc then
    return
  end
  local AceAddon = LibStub("AceAddon-3.0", true)
  ---@type {Render: fun(self: table)}|false|nil
  local core = AceAddon and AceAddon:GetAddon("AlterEgo", true)
  if core and core.Render then
    hooksecurefunc(core, "Render", function()
      self:CaptureFriendVisibility()
    end)
    self.renderHooked = true
  end
end

-- Remove companion-injected characters from AlterEgo's character table.
function Injection:PurgeInjected()
  local characters = Util:GetAlterEgoCharacters()
  if not characters then
    return
  end
  self:CaptureFriendVisibility()
  for guid, owner in pairs(addon.db.injected or {}) do
    local character = characters[guid]
    if character and character._AEFriendOwner == owner then
      characters[guid] = nil
    end
  end
  addon.db.injected = {}
end

-- Snapshot enabled/order for own characters before a filtered view hides them.
function Injection:CaptureOwn()
  local characters = Util:GetAlterEgoCharacters()
  if not characters then
    return
  end
  addon.db.hiddenOwn = addon.db.hiddenOwn or {}
  for guid, character in pairs(characters) do
    if not addon.db.injected[guid] then
      if addon.db.hiddenOwn[guid] == nil then
        addon.db.hiddenOwn[guid] = {
          enabled = character.enabled == nil and "nil" or character.enabled,
          order = character.order == nil and "nil" or character.order,
        }
      end
    end
  end
end

-- Show or hide previously captured own characters without changing the snapshot.
function Injection:SetOwnVisibility(visible)
  local characters = Util:GetAlterEgoCharacters()
  if not characters then
    return
  end
  for guid, state in pairs(addon.db.hiddenOwn or {}) do
    local character = characters[guid]
    if character and not addon.db.injected[guid] then
      if visible then
        character.enabled = state.enabled == "nil" and nil or state.enabled
      else
        character.enabled = false
      end
    end
  end
end

-- Capture own characters, then disable them so only friends remain visible.
function Injection:HideOwn()
  self:CaptureOwn()
  local characters = Util:GetAlterEgoCharacters()
  for guid in pairs(addon.db.hiddenOwn or {}) do
    local character = characters and characters[guid]
    if character and not addon.db.injected[guid] then
      character.enabled = false
    end
  end
end

-- True when the peer is approved and matches the current selected-peer filter.
function Injection:ShouldIncludePeer(key, peer)
  if not peer.approved then
    return false
  end
  local selected = addon.db.settings.selectedPeer
  return not selected or selected == "" or selected == key
end

-- Friend-only character menus should contain only the active friend's rows.
function Injection:ShouldShowCharacterCheckbox(guid)
  if addon.db.settings.view ~= "friend" then
    return true
  end
  local owner = addon.db.injected[guid]
  local peer = owner and addon.db.peers[owner]
  return peer ~= nil and self:ShouldIncludePeer(owner, peer)
end

-- Insert approved peer snapshots into AlterEgo, marked as companion-owned.
function Injection:InjectFriends()
  local characters = Util:GetAlterEgoCharacters()
  if not characters then
    return
  end

  for key, peer in pairs(addon.db.peers) do
    if self:ShouldIncludePeer(key, peer) then
      for guid, snapshot in pairs(peer.snapshots or {}) do
        -- Never replace a character that was not created by this companion.
        if not characters[guid] or addon.db.injected[guid] then
          local copy = Util:CopySerializable(snapshot)
          if copy and copy.info then
            copy.info.name = addon.marker .. (copy.info.name or "?")
            local disabled = addon.db.disabledFriends and addon.db.disabledFriends[key]
            copy.enabled = not (disabled and disabled[guid])
            copy._AEFriendOwner = key
            addon.db.injected[guid] = key
            characters[guid] = copy
          end
        end
      end
    end
  end
end

-- Switch between mine / friend / both views and refresh AlterEgo.
function Injection:SetView(view)
  if view ~= "mine" and view ~= "friend" and view ~= "both" then
    return false
  end
  addon.db.settings.view = view
  self:RefreshView()
  return true
end

-- Switch directly between own characters and one approved friend's characters.
function Injection:SetCharacterSource(key)
  if key ~= nil then
    local peer = addon.db.peers[key]
    if not peer or not peer.approved then
      return false
    end
  end
  addon.db.settings.selectedPeer = key
  addon.db.settings.view = key and "friend" or "mine"
  self:RefreshView()
  return true
end

-- Narrow friend injection to one peer (or clear the filter) and refresh.
function Injection:SetSelectedPeer(key)
  addon.db.settings.selectedPeer = key
  self:RefreshView()
end

-- Rebuild the current view: restore/hide own chars and inject friends as needed.
function Injection:RefreshView()
  self:PurgeInjected()

  local view = addon.db.settings.view or "mine"
  if view == "mine" then
    self:RestoreHiddenOwn()
  elseif view == "friend" then
    self:HideOwn()
    self:InjectFriends()
  elseif view == "both" then
    self:CaptureOwn()
    self:SetOwnVisibility(true)
    self:InjectFriends()
  end
  self:Render()
end

-- Ask AlterEgo to redraw after character table changes.
function Injection:Render()
  local AceAddon = LibStub("AceAddon-3.0", true)
  -- AceAddon:GetAddon is typed as a generic AceAddon; AlterEgo adds Render.
  ---@type {Render: fun(self: table)}|false|nil
  local core = AceAddon and AceAddon:GetAddon("AlterEgo", true)
  if core and core.Render then
    local ok, err = pcall(core.Render, core)
    if not ok then
      addon:Print("AlterEgo could not refresh: " .. tostring(err))
    end
  end
end

-- Leave AlterEgo clean: restore own characters and remove all injections.
function Injection:Shutdown()
  self:RestoreHiddenOwn()
  self:PurgeInjected()
end
