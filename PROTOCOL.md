# FS25 Farmhand Companion: protocol

Everything you need to write your own client for this mod, without reading the Lua.
Matches mod 2.19.

The mod has no idea what is on the other end.
It writes game state out, and it reads commands in.
A Stream Deck plugin is one thing that can sit on the other side; a dashboard, an overlay, a second-monitor app, a Discord bot, or a hardware button box are others.

## The two directions

| Direction | Mechanism | Why |
| --- | --- | --- |
| Game to you | Windows named pipe, plus a file fallback | The FS25 Lua sandbox has no sockets. `io.open` on a pipe path works, so that is the fast path. |
| You to game | A small XML file the mod polls | The sandbox can only read through the engine's XML API. It cannot read a pipe or a JSON file. |

Nothing leaves the machine in either direction.

## Game to you

### Option A: read the file (zero setup)

The mod rewrites this file with the latest frame every time it sends one:

```
%USERPROFILE%\Documents\My Games\FarmingSimulator2025\modSettings\FS25_Farmhand\telemetry.json
```

The whole file is one JSON object, the most recent frame of any kind (see "Frames" below).
Read it whenever you like.
This path works even when the pipe is not being hosted by anyone, so it is the simplest way to get started, and the only way on a machine where named pipes are not available.

The write is not atomic, so a read can occasionally catch a partial file.
Retry on a JSON parse failure.

### Option B: host the pipe (4 Hz, no polling)

Create a named pipe server at:

```
\\.\pipe\flowkits_fs25
```

The mod is the client.
It opens the pipe write-only, writes one JSON object per line (UTF-8, `\n` terminated), and flushes after each line.
If the pipe is not there, the mod retries every 5 seconds, so you can start your program before or after the game.

One thing to know before you build on the pipe: the name is fixed, and Windows lets one server own a name at a time.
If the FlowKits Stream Deck plugin is running, it holds that name and your program cannot.
For a second consumer alongside it, read the file instead.

### Frames

Every line is a JSON object with an `event` key.

| `event` | Cadence | Keys |
| --- | --- | --- |
| `hello` | Once, when the pipe connects | `modVersion` |
| `state` | 4 Hz | `ctx` (`"vehicle"` or `"onFoot"`), `world`, `vehicle` (only when `ctx` is `"vehicle"`) |
| `farm` | 0.5 Hz | `fleet`, `contracts`, `field` (only when in a vehicle on a field) |
| `estate` | 0.1 Hz | `season`, `husbandries`, `productions`, `prices` |
| `ai` | When it happens | `kind` (`started`, `stopped`, `stuck`), `severity`, and whatever the game reported: `vehicleName`, `vehicleId`, `helperIndex`, `taskIndex`, `taskCount`, `messageClass`, `text` |

`hello` is the version handshake.
Compare on the first three components (`2.19.0`); the fourth is a build number.
In multiplayer the running mod comes from the host, so this is the only reliable way to know what version you are actually talking to.

The shape inside each key (`world`, `vehicle`, `fleet`, and so on) is produced by one function per key in `scripts/Collectors.lua`.
That file is the reference, and it is written to be read.
The quickest way to see the live shape for your own save is to load a game with the mod enabled and open `telemetry.json`.

Lists are capped: `fleet` at 99 entries, `contracts` at 6, `husbandries` and `productions` at 8, `prices` at 12.
Everything farm-specific is filtered to the local player's own farm.
`prices` is not, because selling station prices are public to every player on the map.

## You to game

Write this file:

```
%USERPROFILE%\Documents\My Games\FarmingSimulator2025\modSettings\FS25_Farmhand\commands.xml
```

Contents:

```xml
<?xml version="1.0" encoding="utf-8" standalone="no" ?>
<commands id="1724660000" cmd="cruiseSet" value="15" arg="" />
```

| Attribute | Type | Meaning |
| --- | --- | --- |
| `id` | integer | Must increase with every command within a game session. The mod ignores anything at or below the last id it consumed. Seconds since the epoch works well and survives your program restarting. Stay under 2,147,483,647. |
| `cmd` | string | A handler name from the list below. |
| `value` | number | Numeric argument. `0` if unused. |
| `arg` | string | Optional string argument. Omit the attribute if unused. |

Write it atomically: write to a temporary name in the same folder, then rename over `commands.xml`.
The mod reads the file every frame and deletes it after consuming it, so the file disappearing is your acknowledgement.
Give up waiting after about 600 ms; if the game is paused or on a menu nothing will consume it.

One command at a time.
If you write a second before the first is consumed, the first is lost.

At savegame load the mod deletes any leftover `commands.xml` and resets its last-seen id to 0, so a stale command from a previous session can never fire.

### Handlers

Each name is a key in the `HANDLERS` table in `scripts/Commands.lua`.
The comment above each handler says what `value` and `arg` mean for it, where they mean anything.

Vehicle:
`engineOn` `engineOff` `engineToggle` `cruiseToggle` `cruiseSet` (value: speed) `cruiseSetToggle` `cruiseSpeed` `crabSteer` `honk` `indicatorLeft` `indicatorRight` `hazards` `switchVehicle` `switchVehicleBack` `switchImplement` `enterExit` `enterVehicle` (arg: vehicle id, as a string) `camSwitch` `camIndex` (value: camera index) `camInside` `camOutside`

Lights:
`lightsToggle` `beaconToggle` `highBeamToggle` `workFrontToggle` `workBackToggle` `flashlight`

Implements:
`toolToggle` `turnOnAll` `lowerImplement` `lowerAll` `foldToggle` `foldAll` `attach` `detach` `pipeToggle` `unloadToggle` `unload` `coverToggle` `tipToggle` `tipGround` `tipSide` `tensionBelts` `implementExtra` `implementExtra2` `implementExtra3` `seedsNext` `seedsPrev` `doubleSpray` `chopperToggle`

Joints (loaders, cranes, excavators):
`axis` (arg: slot name from the vehicle's `joints` list, value: direction) `axisStop`

AI:
`aiToggle` `aiModeToggle` `steeringToggle` `steeringLines`

Forestry and hand tools:
`treeAlign` `treeDrop` `cutLength` `headTilt` `handtoolCycle` `handtoolPress` `handtoolRelease` `handtoolToggle` `buildMode`

Session:
`timeUp` `timeDown` `timeCycle` `pause` `menu` `screenshot` `mapToggle` `mapSize` `helpToggle` `radioToggle` `radioNext` `radioPrev` `radioChannel` (value: channel)

Open a screen:
`openCalendar` `openAnimals` `openContracts` `openProduction` `openMap` `openStats` `openPrices` `openShop`

Diagnostics (print to the game log, change nothing):
`dumpVehicle` `dumpActions` `dumpCategories` `dumpFillTypes` `dumpMenu`

Every one of these is something the player can already do at the keyboard or with the mouse.
There is nothing here that skips a cost, reads another farm, or touches money.

## Tell the mod when you restart

Write this file when your program starts:

```
%USERPROFILE%\Documents\My Games\FarmingSimulator2025\modSettings\FS25_Farmhand\session.xml
```

```xml
<?xml version="1.0" encoding="utf-8" standalone="no" ?>
<session id="1724660000123" />
```

Any string that differs from the last one will do; the FlowKits plugin uses milliseconds since the epoch.

Why this exists: on Windows, a write to a pipe whose server has gone away does not reliably fail.
If your program restarts and re-creates the pipe, the mod keeps writing into its old dead handle and never notices.
It re-reads `session.xml` every 2 seconds, and a changed id makes it drop the old handle and reconnect at once.
Skip this and telemetry goes quiet after your first restart until the player reloads the save.

If you only read `telemetry.json` and never host the pipe, you do not need this file.

## Folders

The mod creates `modSettings\FS25_Farmhand\` itself.
If you write `commands.xml` or `session.xml` before the game has ever run, create the folder, but never create `FarmingSimulator2025` or `My Games` above it.
Those belong to the game, and inventing them puts files where the game may never look.

## Stability

The envelope above (event names, top-level keys, the command file, the session file) is what I hold stable across mod versions.
Fields inside `vehicle`, `fleet` and the rest gain keys as the mod learns to read more of the game; existing keys keep their meaning.
A version bump in the first two components (`2.x` to `3.x`) is the signal that something in the envelope changed.
