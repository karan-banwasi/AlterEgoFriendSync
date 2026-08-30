# AlterEgo Friend Sync

A companion addon for AlterEgo that shares Mythic+ progress, Great Vault
progress, and raid lockouts with explicitly approved Battle.net friends. The
original AlterEgo addon is not modified.

## Install

Copy the packaged `AlterEgoFriendSync` folder beside `AlterEgo`:

```text
World of Warcraft/_retail_/Interface/AddOns/
  AlterEgo/
  AlterEgoFriendSync/
```

Both players need both addons enabled. Friend Sync requires AlterEgo and will
not load without it.

## Pair

1. Both players log into retail WoW and remain online together for a few
   seconds.
2. Open AlterEgo and click the Friend Sync titlebar button.
3. Under **Available to Pair**, each player approves the other. Approval is
   intentionally mutual.
4. Click **Sync now** if you do not want to wait for the automatic sync.

The `/aef pair FriendName#1234` and `/aef sync` commands provide the same
actions as troubleshooting fallbacks.

No character data is accepted from an unapproved account. Revoking a friend
immediately deletes their cached data:

```text
/aef revoke FriendName#1234
```

## Views

Use the Friend Sync button in AlterEgo's titlebar or:

```text
/aef view mine
/aef view friend
/aef view both
```

Friend characters have a Battle.net icon before their names. Switching to the
friend-only view hides your own characters and restores your usual columns
when you switch views, reload the UI, or log out.

## Sync behavior

- Syncs after login, when an approved friend comes online, after relevant
  Mythic+/vault/raid events, every 60 seconds as a backstop, and on demand.
- A key-completion update normally arrives a few seconds after the run ends.
- Both players must be online at the same time. Last received data remains
  cached and shows its age while the friend is offline.
- Data is sent point-to-point over Battle.net. Same-realm addon whisper is
  the only fallback. Nothing is broadcast to a guild or party.
- Equipment, currencies, money, and prey progress are not sent.

## Commands

```text
/aef help
/aef pair <BattleTag>
/aef revoke <BattleTag>
/aef sync
/aef view mine|friend|both
/aef peer all|<BattleTag>
```
