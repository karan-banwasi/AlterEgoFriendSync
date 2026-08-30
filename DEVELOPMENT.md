 # Development notes

This file is for local development and release packaging. It is excluded from
release archives by `.pkgmeta`. The player-facing guide is `README.md`.

## Debug builds

`addon.debug` is `false` in packaged releases. A git checkout keeps it `true`
because the BigWigs packager strips the `@debug@` block in `Boot.lua`. Debug
chat, `/aef list`, and `/aef status` are available only in that checkout.

Do not set `addon.debug = true` outside the `@debug@` block. That assignment
would ship to CurseForge and Wago.

## Patch 12.1 verification

The implementation checks and queues around Midnight chat lockdown. These two
behaviors still require a live two-client test because Blizzard's published
documentation does not settle them:

1. Whether idle time inside a dungeon is restricted, or only an active M+ run
   and encounter.
2. Whether `C_BattleNet.SendGameData` is subject to the same lockdown.

To force lockdown on a test client:

```text
/console addonChatRestrictionsForced 1
/reload
```

Run `/aef sync`, confirm `/aef status` shows queued packets, then disable it:

```text
/console addonChatRestrictionsForced 0
/reload
```

The queued update should deliver when the restriction clears. Also verify a
normal cross-realm sync, a completed key, a friend going offline and online,
all three views, `/reload` while friend-only view is active, and revoke.

## Repository and CurseForge packaging

The repository root is the addon source root: the TOC, Lua files, libraries,
and player `README.md` are all here. Development-only tests live under
`tests/` and are excluded from release archives by `.pkgmeta`.

This layout is compatible with the BigWigs packager commonly used for
CurseForge and Wago releases. When a CurseForge project has been created, add
its numeric project ID to the TOC as `## X-Curse-Project-ID` and configure the
packager with the corresponding API token. The generated archive will contain
one installable top-level folder named `AlterEgoFriendSync`.
