# Peggle Forever

PopCap's 2009 World of Warcraft Peggle addon (v1.02), patched to run on WoW Forever (1.60.1, Interface 16001).

The game code is PopCap's original. Almost everything the modern client removed or changed is handled by a compatibility layer, `Compat.lua`. The only edits to `Peggle.lua` are the `setfenv` on its first line, reading its addon path from `PEGGLE_ADDON_PATH`, and passing the now-required flags argument (`""`) to `SetFont`.

## Layout

```
PeggleForever.toc Addon manifest (Interface 16001 = WoW Forever 1.60.1)
Compat.lua        Compatibility layer: maps removed APIs, templates and widget methods onto modern ones
Peggle.lua        PopCap's original game code (minified with LuaSrcDiet, reformatted with StyLua)
stylua.toml       StyLua settings used to format Peggle.lua
images/           Textures (.tga): pegs, backgrounds, banners, UI art
sounds/           Sound effects
changelog.txt     Version history, including the forever patch notes
readme.txt        PopCap's original copyright notice and third-party licences
```

## Install

Symlink (or copy) this folder into `World of Warcraft/_forever_/Interface/AddOns/PeggleForever`.

The folder must be named `PeggleForever` to match `PeggleForever.toc`. Art and sound paths aren't hard-coded: `Compat.lua` builds them from the addon's folder name and passes them to `Peggle.lua` as `PEGGLE_ADDON_PATH`. The only fixed path is the `IconTexture` line in the .toc.

## Slash commands

`/peggle` or `/peg` toggle the game window · `/peggle resetwindow` (move the window back to the centre at its default size) · `/peggle achievement` (replay the easter egg toast once unlocked) · `/peggleloot [item link]` (start a Peggle Loot challenge; Master Looter only)

## How the compatibility layer works

`Peggle.lua` was minified, so its locals have one- or two-letter names, and its main chunk already uses all 200 local slots, so replacements can't be added to it as locals. Instead, `Peggle.lua` runs inside a private environment (a `setfenv` on its first line). `Compat.lua` fills that environment table (`ns.env`); lookups hit it first and fall through to `_G`, and global writes go straight to `_G`.

What `Compat.lua` covers:

- **Widgets.** Every frame and texture Peggle creates is wrapped so the old calls still work:
  - `Texture:SetTexture(r, g, b[, a])` goes to `SetColorTexture`.
  - `SetBackdrop` and friends mix in `BackdropTemplateMixin` on first use.
  - `SetMinResize`/`SetMaxResize` go to `SetResizeBounds`.
  - `nil` EditBox limits (`SetMaxLetters`, `SetMaxBytes`, `SetNumeric`) default to 0, as the old client did.
- **Missing templates.** Look-alike replacements for the sparkle frame, the Wrath-era talent buttons, arrows and branches, and the achievement alert toast used by the easter egg.
- **Removed globals.** `MouseIsOver`, `DrawRouteLine` (now `DrawLine`), `RaidNotice_AddMessage`, `GetLootMethod` (now `C_PartyInfo`), the old raid, friends and guild roster functions, and `CalendarGetDate`.
- **Addon messages.** Registers the `PEGGLE` prefix, and strips same-realm suffixes from `CHAT_MSG_ADDON` senders and guild roster names so they match the bare names Peggle compares against.
- **Chat filters.** Secret values handed to chat filters in restricted contexts pass through untouched instead of erroring in Peggle's string handling.
- **Dropdowns.** Peggle hooks `ToggleDropDownMenu` for every addon's dropdowns. The hook now overlays Peggle's background on Peggle's own menus only, instead of swapping the (now NineSlice) list backdrop.

## Debugging

`Peggle.lua` has been reformatted to one statement per line, so error line numbers point at a single statement. The names are still minified, so check the locals in the error dump (BugSack or `/console scriptErrors 1`) to work out which frame or function is involved. Frames created through `Compat.lua` show `<Compat.lua:...>` as their origin.

When something is missing, fix it in `Compat.lua` rather than editing `Peggle.lua`.

The reformat changed layout only. Compiled with Lua 5.1's `luac -l -l -s`, it gives the same instructions, constants, locals and upvalues as the original once line numbers are ignored. Two strings that held raw `0xA9` bytes were rewritten as `\169` escapes, so the file is plain ASCII and editors can't re-encode it. To see what's changed since the 2009 version, ignoring formatting, diff against the reformat commit rather than `ecaec3b`. Keep `Peggle.lua` formatted with `stylua Peggle.lua`.

## Credits and licence

Peggle for World of Warcraft is © 2007, 2009 PopCap Games, Inc. All rights reserved. See `readme.txt` for the original notice and the Lua and LuaSrcDiet licences. This is an unofficial compatibility update and isn't affiliated with or endorsed by PopCap Games or Electronic Arts.
