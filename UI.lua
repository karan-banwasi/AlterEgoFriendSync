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

-- Re-attempt titlebar attachment (e.g. after AlterEgo reloads its UI).
function UI:RefreshTitlebar()
  self:AttachTitlebar()
end

-- Populate the titlebar dropdown: view mode, peer filter, pairing, and sync.
function UI:BuildMenu(menu)
  menu:CreateTitle("Character View")
  local views = {
    {id = "mine", label = "My characters"},
    {id = "friend", label = "Friend characters"},
    {id = "both", label = "My characters + friends"},
  }
  for _, view in ipairs(views) do
    menu:CreateRadio(
      view.label,
      function(id) return addon.db.settings.view == id end,
      function(id) addon.Injection:SetView(id) end,
      view.id
    )
  end

  menu:CreateDivider()
  menu:CreateTitle("Friend Filter")
  menu:CreateRadio(
    "All approved friends",
    function() return not addon.db.settings.selectedPeer or addon.db.settings.selectedPeer == "" end,
    function() addon.Injection:SetSelectedPeer(nil) end
  )
  for _, key in ipairs(Util:SortedKeys(addon.db.peers)) do
    local peer = addon.db.peers[key]
    if peer.approved then
      local currentKey = key
      local label = peer.battleTag .. " (" .. Util:FormatAge(peer.lastSync) .. ")"
      menu:CreateRadio(
        label,
        function(value) return addon.db.settings.selectedPeer == value end,
        function(value) addon.Injection:SetSelectedPeer(value) end,
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
    menu:CreateTitle("Available to Pair")
    for _, key in ipairs(Util:SortedKeys(addon.db.peers)) do
      local peer = addon.db.peers[key]
      if addon.Protocol:IsAvailable(peer) and not peer.approved then
        local battleTag = peer.battleTag
        menu:CreateButton("Approve " .. battleTag, function()
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
