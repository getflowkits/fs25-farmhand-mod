# FS25 Farmhand Companion

*Mod for Farming Simulator.*

A mod for Farming Simulator 25 that streams your own farm's state out of the game, and runs ordinary in-game actions when something outside the game asks it to.
Made by FlowKits.

It is the piece that lets a program on your PC read speed, fuel, fill levels, the fleet, contracts, animals, production, prices and weather, and send back things like "lower the implement" or "set cruise to 15", without keystrokes.

## Free, MIT, for anyone

This mod is free.
It is licensed under the [MIT License](LICENSE), which means you can use it, copy it, change it, build on it, ship it inside your own project, and sell what you build, for any purpose, without asking me.
The only condition is the one in the license file: keep the copyright and permission notice with any copies.

Some things you could build on it:

- A second-monitor dashboard or a browser overlay
- A Stream Deck, Loupedeck, or button-box integration of your own
- A Discord or Twitch bot that reacts to your farm
- A DIY gauge cluster on an Arduino or a Raspberry Pi
- A tool that logs prices or contracts over time

The full protocol is in [PROTOCOL.md](PROTOCOL.md), written for someone who has not read the Lua.
If you want the raw feed with no setup, it also writes the latest frame to a JSON file you can just open.

**No paywall, no account, no gate.**
The mod is downloadable here, in full, by anyone, and does not require any other software to run.
It never has and never will require a purchase.

## Where FlowKits fits

I sell a Stream Deck plugin, [FS25 Farmhand](https://getflowkits.com), that uses this mod as its data source.
That plugin is separate software.
It is not in this repository, it is not covered by this license, and the mod does not need it.
The plugin can download and install the mod for you as a convenience; you can also install it by hand from here and the plugin will happily use that copy.

The line between the two is deliberate.
The mod is the open part, and I want other people to build on it.
The plugin is the Stream Deck part, and that is what I charge for.

The MIT license covers the code and files here.
It does not cover the FlowKits name or logo, so please do not ship your own thing under that name.

## Files

| File | What it covers |
| --- | --- |
| `modDesc.xml` | Mod declaration: version, icon, source files |
| `PROTOCOL.md` | How to talk to the mod from your own program |
| `scripts/Farmhand.lua` | Startup, versioning, the update loop, tick tiers |
| `scripts/Commands.lua` | Everything the mod does to the game |
| `scripts/Collectors.lua` | Everything the mod reads |
| `scripts/Transport.lua` | How data leaves the Lua sandbox |

If you only read one file, read `Commands.lua`.
The `HANDLERS` table is the complete list of what a client can ask the mod to do, one entry per command.

## What it does to the game

Every command is something the player can already do at the machine they are controlling.
It adds no capability, skips no cost, and bypasses no game rule.

Two mechanisms, both documented at the top of `Commands.lua`:

1. A direct call on the controlled vehicle, where the game exposes a function for it (`startMotor`, `setCruiseControlMaxSpeed`, `setLoweredAll`).
   Preferred where an exact value matters, such as setting cruise control to exactly 15 kph.
2. A named `InputAction` raised through the vehicle's own registered action event (`LOWER_IMPLEMENT`, `TOGGLE_AI`, `TOGGLE_PIPE`).
   This runs the game's own bound callback, so it behaves identically to the key press and is immune to the player's keybindings.

No keystrokes are synthesized, and no input is injected at the OS level.

Three details worth stating plainly rather than leaving to be found:

- **Engine start and stop.**
  `MOTOR_STATE_ON` and `MOTOR_STATE_OFF` are the game's own input actions, but they are unbound by default, so in vanilla the engine is normally started with the mouse in the cab.
  The mod raises those existing actions, or calls `startMotor` / `stopMotor`.
  This is a binding convenience, not a new ability.
- **Direct camera and vehicle selection.**
  `camIndex` jumps to camera N instead of cycling to it, and `enterVehicle` enters one of your own vehicles by id instead of cycling to it with the vehicle switch key.
  Both reach the same end state the game's own cycle keys reach, in one press instead of several.
- **Diagnostics.**
  `dumpVehicle`, `dumpActions`, `dumpCategories`, `dumpFillTypes` and `dumpMenu` print to the game log and change nothing.
  They exist because this mod was written by asking the game for its own names rather than guessing them, and they are left in so the same thing can be done again after a game update.

## What it reads

Vehicle and implement state, fleet status, the current field, animals, production points, contracts, weather, the calendar, and selling station prices.
Collectors are in `Collectors.lua`, one function per group.

Everything farm-specific is scoped to the local player's own farm.
`Farmhand.lua` resolves the farm once with `g_currentMission:getFarmId()`, and each collector filters on `ownerFarmId == farmId`.
The active vehicle comes from `g_localPlayer:getCurrentVehicle()`.
Selling station prices are not farm-scoped, because they are the same public prices every player can read on the map and in the prices menu.

## Multiplayer

The mod declares multiplayer support and runs on the client.

It reports nothing that the player running it could not already see for their own farm in their own HUD and menus.
It grants no information about other farms or other players.
It performs no action that player could not perform at the keyboard.
The value it adds in multiplayer is the same as in single player: fewer menu round trips, and one press instead of a key sequence.

## Where the data goes

Nowhere except the local machine.

The FS25 Lua sandbox has no sockets, so there is no network path available to the mod even in principle.
The transport is a Windows named pipe, `\\.\pipe\flowkits_fs25`, with your program hosting and the mod connecting as a client, plus a JSON file fallback.
Frames are newline delimited JSON, at 4 Hz for the active vehicle and slower for everything else.

There is no HTTP, no telemetry service, no analytics, and no account.

## Files it writes

All three live in `modSettings/FS25_Farmhand/` under the user profile, and nothing is written outside that folder.

| File | Direction | Purpose |
| --- | --- | --- |
| `telemetry.json` | mod writes | The latest frame, always, whether or not anyone is on the pipe |
| `commands.xml` | client writes, mod reads and deletes | One pending command |
| `session.xml` | client writes, mod reads | Client instance id, so the mod notices a client restart |

The mod reads files only through the engine XML API, never with `io.open` in read mode.

## What it does not do

- It does not replace, patch, or overwrite any game file.
  It is an ordinary mod loaded from the `mods` folder.
- It does not decompile game code.
  Function signatures came from the public LUADOC on the GIANTS Developer Network, and from the mod's own diagnostic dumps of the live API.
- It contains no GIANTS assets.
  No art, models, sounds, or text from the game are included or redistributed.
- It does not touch money, ownership, prices, fill levels, or any other economic state.
  The commands that mention the shop, the prices page, and the statistics page only open those screens.
- It adds no automation of its own.
  The AI commands toggle the game's own AI worker and steering assist.
- It requires no other mod, and modifies no other mod.

## Installing by hand

Download [FS25_Farmhand.zip](https://github.com/getflowkits/fs25-farmhand-mod/releases/latest/download/FS25_Farmhand.zip) (always the newest release) and put it in your mods folder:

```
%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\
```

Leave it as a zip, and keep the name `FS25_Farmhand.zip`.
FS25 refuses to load folder mods in multiplayer, and it rejects a mod whose file name has anything but letters, digits and underscores: the versioned files in `release/` are for the FlowKits plugin's feed, and the game ignores them if you drop one in as it is.
Then tick "FS25 Farmhand Companion" in the mod list when you load a savegame.

## Building your own zip

Zip the contents of this folder (not the folder itself) so that `modDesc.xml` sits at the root of the archive, with `icon_FS25_Farmhand.dds` and `scripts/` beside it.
Use forward slashes in the entry names; some Windows zip tools write backslashes, and the game then cannot find the scripts.

The `release/` zips are built by a packer in my plugin repository that checks those things automatically.
`release/mod-manifest.json` names the current zip and carries its version and SHA-256, which is what the FlowKits plugin checks before installing it.

## Credits and notices

The named-pipe technique for getting data out of the FS Lua sandbox on Windows was shown to work by [Marciel032's FarmingSimulatorTelemetry](https://github.com/Marciel032/FarmingSimulatorTelemetry) and [upsidedownLS13's LS25_FSTelemetry](https://github.com/upsidedownLS13/LS25_FSTelemetry), both MIT.
No code from either is included here, but the approach is theirs and the credit is owed.

Farming Simulator is a trademark of GIANTS Software GmbH.
This mod is not affiliated with, endorsed by, or produced by GIANTS Software, and contains no assets from Farming Simulator 25.

## Contact

FlowKits
contact@getflowkits.com
https://getflowkits.com
