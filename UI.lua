local _, addon = ...

local Util = addon.Util

local UI = {}
addon.UI = UI

-- Register slash commands and retry attaching the titlebar button until LiqUI is ready.
function UI:Initialize()
  SLASH_ALTEREGOFRIEND1 = "/aef"
  SLASH_ALTEREGOFRIEND2 = "/aefriend"
  SlashCmdList.ALTEREGOFRIEND = function(message)
    self:HandleCommand(message)
  end

  -- Retry attaching the titlebar button until LiqUI is ready.
  self.attachTicker = C_Timer.NewTicker(1, function()
    if self:AttachTitlebar() then
      self.attachTicker:Cancel()
      self.attachTicker = nil
    end
  end)
  -- Attach the titlebar button immediately.
  self:AttachTitlebar()
end

-- Add the Friend Sync titlebar button to AlterEgo's main window when available.
function UI:AttachTitlebar()
  local LiqUI = LibStub("LiqUI-1.0", true)
  if not LiqUI then
    return false
  end
  local window = LiqUI:GetElement("Window", "AlterEgoMain")
  if not window then
    return false
  end
  self:AttachCharacterMenuFilter(window)
  if window._AlterEgoFriendButton then
    self.button = window._AlterEgoFriendButton
    return true
  end

  local button = window:AddTitlebarButton({
    name = "FriendSync",
    icon = "Interface\\AddOns\\AlterEgo\\Media\\Icon_Characters.blp",
    iconSize = 14,
    tooltipTitle = "AlterEgo Friend Sync",
    tooltipDescription = "Choose whose characters to show, pair friends, or sync now.",
    onMenu = function(_, rootMenu)
      self:BuildMenu(rootMenu)
    end,
  })
  window._AlterEgoFriendButton = button
  self.button = button
  return true
end

-- Replace AlterEgo's unfiltered character menu only while viewing one friend.
function UI:AttachCharacterMenuFilter(window)
  if window._AlterEgoFriendCharacterMenuHooked then
    return
  end

  local characterButton
  for _, button in ipairs(window.titlebarButtons or {}) do
    local name = button.GetName and button:GetName()
    if name and name:match("Characters$") then
      characterButton = button
      break
    end
  end
  if not characterButton or not characterButton.menuGenerator then
    return
  end

  local originalGenerator = characterButton.menuGenerator
  characterButton.menuGenerator = function(button, rootMenu)
    if addon.db.settings.view ~= "friend" then
      originalGenerator(button, rootMenu)
      return
    end
    self:BuildFriendCharacterMenu(rootMenu)
  end
  window._AlterEgoFriendCharacterMenuHooked = true
end

-- Populate AlterEgo's character-checkbox menu with the selected friend's rows.
function UI:BuildFriendCharacterMenu(rootMenu)
  local characters = Util:GetAlterEgoCharacters() or {}
  local filtered = {}
  for guid, character in pairs(characters) do
    if addon.Injection:ShouldShowCharacterCheckbox(guid) then
      filtered[#filtered + 1] = character
    end
  end
  table.sort(filtered, function(left, right)
    local leftOrder, rightOrder = left.order or 0, right.order or 0
    if leftOrder == rightOrder then
      return tostring(left.info and left.info.name or "") < tostring(right.info and right.info.name or "")
    end
    return leftOrder < rightOrder
  end)

  if rootMenu.SetScrollMode and GetScreenHeight then
    rootMenu:SetScrollMode(math.min(20 * 50, GetScreenHeight() - 20))
  end
  for _, character in ipairs(filtered) do
    local guid = character.GUID
    local info = character.info or {}
    local name = info.name or "?"
    if info.class and info.class.file and C_ClassColor and C_ClassColor.GetClassColor and CreateColor then
      local classColor = C_ClassColor.GetClassColor(info.class.file)
      if classColor then
        name = CreateColor(classColor.r, classColor.g, classColor.b, 1):WrapTextInColorCode(name)
      end
    end
    local label = string.format("%s (%s)", name, info.realm or "?")
    rootMenu:CreateCheckbox(
      label,
      function(value)
        local current = characters[value]
        return current and current.enabled ~= false
      end,
      function(value)
        local current = characters[value]
        if current then
          current.enabled = current.enabled == false
          addon.Injection:CaptureFriendVisibility()
          addon.Injection:Render()
        end
      end,
      guid
    )
  end
end

-- Re-attempt titlebar attachment (e.g. after AlterEgo reloads its UI).
function UI:RefreshTitlebar()
  self:AttachTitlebar()
end

-- Populate the titlebar dropdown: character source, pairing, and sync.
function UI:BuildMenu(menu)
  menu:CreateRadio(
    "My Characters",
    function() return addon.db.settings.view == "mine" end,
    function() addon.Injection:SetCharacterSource(nil) end
  )
  for _, key in ipairs(Util:SortedKeys(addon.db.peers)) do
    local peer = addon.db.peers[key]
    if peer.approved then
      local currentKey = key
      menu:CreateRadio(
        peer.battleTag,
        function(value)
          return addon.db.settings.view == "friend"
            and addon.db.settings.selectedPeer == value
        end,
        function(value) addon.Injection:SetCharacterSource(value) end,
        currentKey
      )
    end
  end

  local hasAvailable = false
  for _, peer in pairs(addon.db.peers) do
    if addon.Protocol:IsAvailable(peer) and not peer.approved then
      hasAvailable = true
      break
    end
  end
  if hasAvailable then
    menu:CreateDivider()
    menu:CreateTitle("Friends you can add")
    for _, key in ipairs(Util:SortedKeys(addon.db.peers)) do
      local peer = addon.db.peers[key]
      if addon.Protocol:IsAvailable(peer) and not peer.approved then
        local battleTag = peer.battleTag
        menu:CreateButton(battleTag, function()
          addon.Protocol:Approve(battleTag)
        end)
      end
    end
  end

  menu:CreateDivider()
  menu:CreateButton("Sync now", function()
    addon.Protocol:SyncAll()
  end)
end

-- Print slash-command usage to chat.
function UI:PrintHelp()
  addon:Print("Commands:")
  addon:Print("/aef pair <BattleTag> — approve a discovered friend")
  addon:Print("/aef revoke <BattleTag> — revoke and delete cached data")
  addon:Print("/aef sync — request a sync with approved friends")
  addon:Print("/aef view mine|friend|both — change the AlterEgo view")
  addon:Print("/aef peer all|<BattleTag> — filter the friend view")
  if addon.debug then
    addon:Print("/aef list — list discovered and approved friends")
    addon:Print("/aef status — show connection and cache status")
  end
end

-- Print each discovered peer's approval and online state.
function UI:ListPeers()
  local found = false
  for _, key in ipairs(Util:SortedKeys(addon.db.peers)) do
    local peer = addon.db.peers[key]
    found = true
    local state = peer.approved and "approved" or (addon.Protocol:IsAvailable(peer) and "available to pair" or "offline")
    local runtime = addon.Protocol.friendsByBattleTag[key]
    local online = runtime and runtime.online and ", online" or ", offline"
    addon:Print(peer.battleTag .. " — " .. state .. online .. "; last sync " .. Util:FormatAge(peer.lastSync))
  end
  if not found then
    addon:Print("No companion-addon friends discovered yet. Both players must be online once.")
  end
end

-- Print view/cache/queue status, then list peers.
function UI:PrintStatus()
  addon:Print("View: " .. tostring(addon.db.settings.view) ..
    "; cached peers: " .. Util:Count(addon.db.peers) ..
    "; queued Battle.net packets: " .. #addon.Transport.bnQueue)
  self:ListPeers()
end

-- Dispatch /aef slash commands (pair, revoke, sync, view, peer, etc.).
function UI:HandleCommand(message)
  local command, argument = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
  command = command:lower()

  if command == "" or command == "help" then
    self:PrintHelp()
  elseif command == "list" and addon.debug then
    self:ListPeers()
  elseif command == "pair" then
    local ok, err = addon.Protocol:Approve(argument)
    if not ok then addon:Print(err) end
  elseif command == "revoke" then
    local ok, err = addon.Protocol:Revoke(argument)
    if not ok then addon:Print(err) end
  elseif command == "sync" then
    addon.Protocol:SyncAll()
    addon:Print("Sync requested.")
  elseif command == "view" then
    if not addon.Injection:SetView(argument:lower()) then
      addon:Print("View must be mine, friend, or both.")
    end
  elseif command == "peer" then
    if argument:lower() == "all" then
      addon.Injection:SetSelectedPeer(nil)
    else
      local peer, err = addon.Protocol:FindPeer(argument, false)
      if not peer or not peer.approved then
        addon:Print(err or "Approved friend not found.")
      else
        addon.Injection:SetSelectedPeer(Util:NormalizeBattleTag(peer.battleTag))
      end
    end
  elseif command == "status" and addon.debug then
    self:PrintStatus()
  else
    self:PrintHelp()
  end
end
