# FS25 Farmhand Companion: protocol

Everything you need to write your own client for this mod, without reading the Lua.
Matches mod 2.20.

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

### Two listeners (2.20)

Since 2.20 the mod serves two listeners at once, and they share nothing either one writes:

| | Stream Deck plugin | FlowKits Companion (Xeneon Edge widget) |
| --- | --- | --- |
| Pipe | `\\.\pipe\flowkits_fs25` | `\\.\pipe\flowkits_fs25_edge` |
| Commands | `commands.xml` | `commands_edge.xml` |
| Session | `session.xml` | `session_edge.xml` |
| File fallback | `telemetry.json` | none |

The plugin's channel is exactly what it was before 2.20.
Every frame below goes to both pipes, built once.
A press written by one listener can never displace the other's, and one listener restarting reconnects only itself.

The widget pipe differs in three additive ways:
- its `hello` also carries `"protocol":"2.20"`;
- `commands_edge.xml` is checked at most every 100 ms (10 times a second) and only while the widget pipe is connected, where `commands.xml` is checked every game frame, so a widget press can take up to 100 ms longer to land;
- a command in `commands_edge.xml` may carry `req="..."`, and the mod answers it on the widget pipe with `{"event":"ack","req":"...","ok":true}` or `{"event":"ack","req":"...","ok":false,"reason":"Not in a vehicle"}`;
- menu commands from `commands_edge.xml` only ever open a page; the same command from the plugin toggles it closed again, as a key press should;
- widget-only frames (every owned field, every sell point, storage, worker detail, contracts, the forecast, players and the save's settings) go to the widget pipe only, and are collected only while it is connected, so a plugin-only player pays nothing for them (see "Widget frames" below).

### Frames

Every line is a JSON object with an `event` key.

| `event` | Cadence | Keys |
| --- | --- | --- |
| `hello` | Once, when the pipe connects | `modVersion`, `userPath` (2.20.1 and later) |
| `state` | 4 Hz | `ctx` (`"vehicle"` or `"onFoot"`), `world`, `vehicle` (only when `ctx` is `"vehicle"`) |
| `farm` | 0.5 Hz | `fleet`, `contracts`, `field` (only when in a vehicle on a field) |
| `estate` | 0.1 Hz | `season`, `husbandries`, `productions`, `prices` |
| `ai` | When it happens | `kind` (`started`, `stopped`, `stuck`), `severity`, and whatever the game reported: `vehicleName`, `vehicleId`, `helperIndex`, `taskIndex`, `taskCount`, `messageClass`, `text` |

`hello` is the version handshake.
Compare on the first three components (`2.19.0`); the fourth is a build number.
In multiplayer the running mod comes from the host, so this is the only reliable way to know what version you are actually talking to.

`userPath` is the game's own user folder, exactly as the game reports it (forward slashes, trailing slash), for example `C:/Users/you/Documents/My Games/FarmingSimulator2025/`.
Write your command and session files under its `modSettings/FS25_Farmhand/`.
Don't assume Documents: a `-profile` launch option can put this folder anywhere, and the Microsoft Store / Game Pass build keeps it inside its package folder.

The shape inside each key (`world`, `vehicle`, `fleet`, and so on) is produced by one function per key in `scripts/Collectors.lua`.
That file is the reference, and it is written to be read.
The quickest way to see the live shape for your own save is to load a game with the mod enabled and open `telemetry.json`.

Lists are capped: `fleet` at 99 entries, `contracts` at 6, `husbandries` and `productions` at 50, `prices` at 200 (in practice every sellable fill type: an alphabetical list is only useful complete).
`prices` lists crops first, then every other fill type, each alphabetical by fill type name, with the best price and the station that pays it.
Prices are per litre, as the game reports them; the game's own price screen shows them per 1,000 litres.
Everything farm-specific is filtered to the local player's own farm.
`prices` is not, because selling station prices are public to every player on the map.

`world.weatherNext` is the weather type of the next forecast block (forecast item 2).
Since 2.20 it is read from the forecast list, because the game's `getNextWeatherType` needs a day and a time and threw without them.

### Widget frames (2.20, widget pipe only)

These go to `\\.\pipe\flowkits_fs25_edge` and nowhere else: never to the plugin's pipe, never to `telemetry.json`.
They are built only while the widget pipe is connected.
On a fresh connection every one of them is sent within about half a second, one per game frame.

| `event` | Cadence | Keys |
| --- | --- | --- |
| `settings` | Every 10 s (built over several game frames), sent only when it changed (and once a minute regardless) | `needs`, `helper`, `daysPerPeriod`, `growthMode`, `fuelUsage`, `economicDifficulty`, `snow`, `max`, `periodNames` (optional), `crops` |
| `players` | Every 10 s, sent only when it changed (and once a minute regardless) | `multiplayer`, `server`, `master`, `me`, `canSetSpeed`, `canManageContracts`, `users` |
| `workers` | 2 s | `wagesPerHour`, `now`, `items` |
| `missions` | 5 s, built over several game frames | `now`, `limit`, `canManage`, `total`, `items` |
| `fields` | 6 s | `owned`, `total`, `period`, `dayInPeriod`, `daysPerPeriod`, `rows` |
| `stations` | 10 s, built over several game frames and sent once complete | `total`, `from`, `items`, `fills` |
| `storage` | 10 s, built over several game frames and sent once complete | `items`, `totals`, `pallets` |
| `sites` | 10 s, built over several game frames and sent once complete | `timeAdjustment`, `pens`, `productions` |
| `weather` | 30 s | `now`, `temp`, `min`, `max`, `raining`, `rainInMin`, `next`, `change`, `items`, `daily` |

Every value the game did not give is JSON `null`, never a guess.
All times are game time: `day` is the game's day counter, `hour` and `minute` the in-game clock, `dayTime` milliseconds since midnight.
`now` (on `workers` and `missions`) is `{day, monotonicDay, hour, minute, dayTime}` at the moment the frame was built.
Fill and crop names are the game's fill type names (`WHEAT`, `SUNFLOWER_OIL`).
Prices are per litre, as everywhere else in this protocol.
Positions are world `x` and `z` in metres; distance from the player is the distance to `stations.from`.
Lists are capped only against a pathological save (500 fields, 200 stations, 200 storages, 99 workers, 200 contracts, 16 forecast blocks, 64 users, 100 pens and 100 production points).
The source of every shape is one function per frame in `scripts/EdgeCollectors.lua`.

#### settings

`needs` is `{lime, plow, weeds, stones}`, each true when this save has that need switched on (`limeRequired`, `plowingRequiredEnabled`, `weedsEnabled`, `stonesEnabled`).
A need that is off never appears in a field's `needs`.
`helper` is `{fuel, seeds, fertilizer, manureSource, slurrySource}`, the hired helper's refill settings.
With `helper.fuel` on, an empty tank is not an alert, because the helper buys more.
`max` is `{lime, plow, spray}`, the game's top level for each soil value.
`crops` has one entry per crop, keyed by name: `{plant, harvest, needsRolling, growthRequiresLime, plantsWeed}`.
`plant` and `harvest` are 12 booleans, index 0 = period 1.
Period 1 is early spring, which the game's calendar labels March on a northern map.
`periodNames`, when present, is the game's own 12 labels.

```json
{"event":"settings","needs":{"lime":true,"plow":false,"weeds":true,"stones":true},"helper":{"fuel":true,"seeds":true,"fertilizer":false,"manureSource":2,"slurrySource":2},"daysPerPeriod":1,"growthMode":1,"fuelUsage":2,"economicDifficulty":1,"snow":true,"max":{"lime":3,"plow":1,"spray":2},"crops":{"WHEAT":{"plant":[false,false,false,false,false,false,true,true,false,false,false,false],"harvest":[false,false,false,true,true,false,false,false,false,false,false,false],"needsRolling":true,"growthRequiresLime":true,"plantsWeed":true}}}
```

#### fields

Every field the farm owns, by the game's field number, ascending.
Each row is `n` (field number), `farmland`, `ha`, `x`, `z`, `crop` (null when fallow), `state`, `growth`, `growthMax`, `needs`, `closing` and `soil`.
`state` is one of `fallow`, `sown`, `growing`, `ready`, `withered`, `harvested`.
`growth` runs from 1 to `growthMax` while the crop grows, equals it when ready, and is null otherwise.
`needs` is a subset of `lime`, `weed`, `stones`, `plow`, `fert`, `roll`, `mulch`, in that order, holding only needs this save has switched on.
`closing` is true when the crop is ready and this is the last period it can be harvested in.
Whether a ready crop then withers is not readable from the save, so `closing` says only that the window closes.
`soil` is the game's raw field state: `growthState`, `lastGrowthState`, `lime`, `plow`, `roller`, `spray`, `sprayType`, `stones`, `stubbleShred`, `weed`, `weedFactor`, `water`, `ground`.

```json
{"event":"fields","owned":4,"total":77,"period":4,"dayInPeriod":1,"daysPerPeriod":1,"rows":[{"n":7,"farmland":7,"ha":7.25,"x":70.0,"z":-70.0,"crop":"POTATO","state":"ready","growth":6,"growthMax":6,"needs":["weed"],"closing":true,"soil":{"growthState":9,"lastGrowthState":8,"lime":1,"plow":1,"roller":1,"spray":0,"sprayType":1,"stones":0,"stubbleShred":1,"weed":2,"weedFactor":0.000,"water":0.000,"ground":2}}]}
```

#### stations

Every sell point the game's own price screen lists, with the price it pays for each fill type it takes.
`items[]` is `{id, name, x, z, prices}`, and each price is `{fill, price, trend, demand}`.
`trend` and `demand` (the great-demand multiplier) appear only when the game reports them.
`fills[]` gives, per fill type, the best `price` and the `station` id paying it, crops first and then the rest, each alphabetical.
A fill also carries `curve` when the game exposes it: the 12 values of the season's price history, period 1 first, as the game stores them in economy.xml.
`from` is the player's position (or the vehicle's), null when unknown.

```json
{"event":"stations","total":30,"from":{"x":-917.3,"z":183.3},"items":[{"id":490,"name":"Farmers Market","x":0.0,"z":300.0,"prices":[{"fill":"EGG","price":1.1000,"demand":1.50},{"fill":"WHEAT","price":0.4500}]}],"fills":[{"fill":"WHEAT","crop":true,"best":0.4500,"station":490,"curve":[337.0000,361.0000,334.0000,317.0000,286.0000,281.0000,337.0000,366.0000,372.0000,381.0000,408.0000,364.0000]}]}
```

#### storage

`items[]` is each storage the farm owns, `{id, name, capacity, fills}`, with each fill `{fill, lvl, cap}`.
`name` is the name of the building that holds the storage (a silo, a silo extension, an animal pen or a production point), including a map silo that keeps a separate storage per farm; null when none is found.
`totals[]` is `{fill, lvl}`, summed across every storage.
`pallets[]` is `{fill, lvl, count}`: the farm's pallets, big bags and bales, summed per fill type.

```json
{"event":"storage","items":[{"id":135,"name":null,"capacity":100000,"fills":[{"fill":"WHEAT","lvl":5000,"cap":100000}]}],"totals":[{"fill":"WHEAT","lvl":5000}],"pallets":[{"fill":"EGG","lvl":150,"count":1}]}
```

#### sites

The farm's animal pens and production points: the same ones, in the same order, as the `estate` frame's `husbandries` and `productions`.
Every `perHour` is in litres (or units) per GAME hour, so time to empty is `lvl / perHour` game hours.
The rates are the game's own, not measured: each husbandry keeps `litersPerHour`, and every game hour it uses `litersPerHour x timeAdjustment`, so that product is what is sent.
`timeAdjustment` is the game's days-per-month factor (1 at one day per month), sent so a client can undo it.

`pens[]`: each pen carries
- `id` (the pen's network object id, which `showOnMap` and `mapTarget` take as `husbandry:<id>`), `name`, `type` (the game's animal type, `COW`, `SHEEP`, `PIG`, `CHICKEN`, `HORSE`), `count` and `max`;
- `productivity` (0 to 1) and `health` (0 to 100, averaged over the herd), or null;
- `breeds[]`: `{name, subType, count}`, where `name` is the breed as the Animals screen shows it (`ANGUS`) and `subType` the game's subtype name (`COW_ANGUS`); absent when the game does not say;
- `food`: `{lvl, cap, perHour, groups}`, where each group is `{name, weight, lvl, fills}`, the animals screen's own split (the groups share the trough's one capacity, and `weight` is the group's share of productivity);
- `water`: `{lvl, cap, perHour, auto}`, or null when the pen takes no water; with `auto` true the water never runs out;
- `straw`: `{lvl, cap, perHour}`, or null when the pen uses no straw;
- `outputs[]`: `{fill, kind, lvl, cap, perHour}` for milk, slurry and manure (`kind` `storage`, the pen's own tank) and for wool, eggs and the like (`kind` `pallets`, what stands on the pen's pallets now);
- `palletFull`, true when the pen has no room for another pallet.

`productions[]`: each production point carries
- `id` (its placeable's network object id, `production:<id>`), `name`, and `on` (any line switched on);
- `lines[]`: `{name, on, status, cyclesPerHour}`, where `status` is the game's own name (`RUNNING`, `MISSING_INPUTS`, `NO_OUTPUT_SPACE`, `INACTIVE`);
- `inputs[]`: `{fill, lvl, cap, perHour}`, the use per game hour of the lines that are on;
- `outputs[]`: `{fill, mode, lvl, cap, perHour}`, with `mode` `store` (kept here), `distribute` (delivered to your storage) or `sell` (sold at once);
- `palletFull`, and `stopped`: `off` (no line on), `inputEmpty` (a line that is on has an empty input), `outputFull` (a stored output or the pallet space is full), or null while it runs.

A line's use and yield per game hour are its amount per cycle x `cyclesPerHour` x `timeAdjustment`, shared between the lines that are on, as the game itself does unless the point opts out.

```json
{"event":"sites","timeAdjustment":1.000,"pens":[{"id":131,"name":"Cow Barn","type":"COW","count":20,"max":30,"productivity":0.850,"health":90,"food":{"lvl":1500,"cap":10000,"perHour":50.00,"groups":[{"name":"Grass","weight":0.40,"lvl":1000,"fills":["GRASS_WINDROW"]},{"name":"Silage","weight":0.60,"lvl":500,"fills":["SILAGE"]}]},"water":{"lvl":3000,"cap":5000,"perHour":100.00,"auto":false},"straw":{"lvl":0,"cap":5000,"perHour":20.00},"outputs":[{"fill":"MILK","kind":"storage","lvl":2000,"cap":5000,"perHour":40.00}],"palletFull":null}],"productions":[{"id":133,"name":"Grain Mill","on":true,"lines":[{"name":"Flour","on":true,"status":"RUNNING","cyclesPerHour":10.00}],"inputs":[{"fill":"WHEAT","lvl":500,"cap":20000,"perHour":20.00}],"outputs":[{"fill":"FLOUR","mode":"distribute","lvl":100,"cap":20000,"perHour":10.00}],"palletFull":false,"stopped":null}]}
```

#### workers

Every machine of this farm with a worker on it (the game's helper, Courseplay or AutoDrive), and every machine whose worker the game stopped or that finished its job.
Only the machine that holds the job is listed; an implement hitched to it appears in its `implements`, never as a worker of its own.
A stopped or finished machine stays listed until it is hired again, sold, or the player gets in.
A worker the player dismissed leaves at once.
Each item carries:
- `id`, the vehicle id that `enterVehicle`, `stopWorker` and `showOnMap` take;
- `name`, `letter` (the worker's letter, "H") and `category` (the store category);
- `kind`: `ai`, `courseplay` or `autodrive`;
- `jobType`: `fieldWork`, `goTo`, `deliver`, `baleFinder`, `conveyor`, or null; and `job`, the game's own job text;
- `x`, `z`, and `field`, the field it works or stands on;
- `state`, `blocked`, `turning`, `stillMs` and `stop`;
- `fuel` (percent), `damage` (0 to 1), `fills`, `implement`, `implements` and `wagePerHour`.

`state` is `working`, `stuck`, `stopped` (the game stopped it) or `finished`.
`stuck` means no movement and no fill change for 90 s, the same detector as the plugin's stuck event.
`stop` appears on a stopped or finished machine: `{class, severity, text, day, hour, minute}`, with the time it stopped.
`class` is the game's stop reason class (`AIMessageErrorOutOfFuel`, `AIMessageSuccessFinishedJob`), the same names the `ai` event carries.
`stillMs` is how long the machine has stood still, up to the game's own limit (5,000 ms), and is absent when the game does not report it.
Each `implements[]` item is `{name, fills, damage}`; `damage` (0 to 1) is left out when the implement does not report it.
`fills` and each implement's `fills` have the shape of `vehicle.fills`.
There is no progress percentage: the game does not report one for a field job, so none is sent.

```json
{"event":"workers","wagesPerHour":1800,"now":{"day":16,"monotonicDay":16,"hour":23,"minute":49,"dayTime":85749746},"items":[{"id":104,"name":"Fendt 942","letter":"H","category":"TRACTORSL","kind":"ai","jobType":"fieldWork","job":"Field work","x":51.0,"z":-49.0,"field":5,"state":"working","blocked":false,"turning":true,"stillMs":0,"fuel":75,"damage":0.120,"fills":[{"type":"DIESEL","lvl":300,"cap":400}],"implement":"Kuhn Plough","implements":[{"name":"Kuhn Plough","fills":[]}],"wagePerHour":1800}]}
```

#### missions

The farm's own contracts (any status) and every contract still on offer, never another farm's.
Yours come first, then offers by reward, highest first.
Each item carries:
- `id`, the mission's uniqueId, which `acceptContract` and `showOnMap` take;
- `type`, `title`, `progressTitle`, `desc`, `location`, `farmland`, `field` and `ha`;
- `status`: `CREATED`, `PREPARING`, `RUNNING`, `FINISHED` or `DISMISSED`; and `mine`;
- `reward`, `reimbursement`, `leaseCost` (what leasing its machines takes from the payout) and `leased`;
- `completion` (0 to 1) and `fieldPercentageDone`;
- `endDay` and `endDayTime`, the deadline (game day on the `monotonicDay` counter, and time of day), and `minutesLeft`, the game's own reading of that deadline in game minutes;
- `fill`, `x` and `z`.

`limit` is `{active, max}`, the farm's running contracts against the game's cap.
`canManage` is true when this player may accept contracts.

```json
{"event":"missions","now":{"day":16,"monotonicDay":16,"hour":23,"minute":49,"dayTime":85749746},"limit":{"active":1,"max":3},"canManage":true,"total":19,"items":[{"id":"missiondd22c2b4624c76b7d4d9862368a4a864","type":"harvestMission","title":"Harvesting","progressTitle":"Harvesting (Field 10)","desc":"Harvest the field and take the product to the specified selling station.","location":"Farmland 10","farmland":10,"field":10,"ha":7.25,"status":"CREATED","mine":false,"reward":2439,"reimbursement":0,"leaseCost":1200,"leased":false,"completion":0.000,"fieldPercentageDone":0.000,"endDay":16,"endDayTime":86399999,"minutesLeft":11,"fill":"SUNFLOWER","x":70.0,"z":-70.0}]}
```

#### weather

`now` is the current weather type: 1 SUN, 2 PARTIALLY_CLOUDY, 3 CLOUDY, 4 RAIN, 5 SNOW, 6 HAIL, 7 TWISTER, 8 THUNDER (the game's WeatherType).
`temp` is the temperature now, and `min` and `max` today's range, in degrees Celsius.
`rainInMin` is the game minutes until rain today, or null.
`items[]` is the forecast, one block each, `{type, day, hour, minute, durationMin}`; the first is the weather now.
`next` is the block after the current one, and `change` the first block whose weather differs from now.
`daily[]` is `{day, type, high, low}` for the days ahead, when the game gives them.

```json
{"event":"weather","now":1,"temp":26.1,"min":24,"max":34,"raining":false,"rainInMin":null,"next":{"type":1,"day":17,"hour":10,"minute":0,"durationMin":480},"change":{"type":4,"day":17,"hour":18,"minute":0,"durationMin":120},"items":[{"type":1,"day":16,"hour":23,"minute":0,"durationMin":660},{"type":1,"day":17,"hour":10,"minute":0,"durationMin":480},{"type":4,"day":17,"hour":18,"minute":0,"durationMin":120}],"daily":[]}
```

#### players

`server` is true on the host (and in single player), and `master` is true for an admin.
`canSetSpeed` is true only on the host: game speed belongs to the host.
`users[]` is `{id, name, farm, master}`.

```json
{"event":"players","multiplayer":false,"server":true,"master":true,"me":1,"canSetSpeed":true,"canManageContracts":true,"users":[{"id":1,"name":"PC","farm":null,"master":true}]}
```

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
| `id` | integer | Must differ from the previous command's id. The mod ignores a file whose id equals the last one it consumed, so the same file read twice never fires twice. Increasing ids (seconds since the epoch, then +1) are still the right habit. Seconds since the epoch works well and survives your program restarting. Stay under 2,147,483,647. |
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

Widget (2.20, sent through `commands_edge.xml`; every one works on foot):

| `cmd` | `arg` / `value` | Refusal reasons |
| --- | --- | --- |
| `showOnMap` | arg: `vehicle:<id>`, `field:<n>`, `contract:<id>`, `station:<id>`, `husbandry:<name or id>`, `production:<name or id>` | `Not found`, `Not on the map`, `Not supported` (an unknown kind), `Not available` |
| `mapTarget` | arg: `station:<id>`, `husbandry:<name or id>`, `production:<name or id>`, `field:<n>`, and also `vehicle:<id>` and `contract:<id>` | `Not found`, `Not on the map`, `Not supported`, `Not available` |
| `stopWorker` | arg: the vehicle id from `workers` | `Not found`, `Not working`, `Not available` (an AutoDrive driver, or a job the game will not stop) |
| `acceptContract` | arg: the mission id from `missions`; value: 1 to lease its machines, 0 to use your own | `Not found`, `Already accepted`, `Not available` (taken, expired or no longer on offer), `Host only` (this player may not manage contracts), `Contract limit reached`, `No space for the machines` |
| `setTimeScale` | value: the speed, 1 to 120 | `Host only`, `Not available` |
| `enterVehicle` | arg: the vehicle id from `fleet` or `workers` | `Not found`, `No cab`, `Not available` |

`showOnMap` opens the map page with that item selected.
`mapTarget` sets the map flag and the route to it, and never toggles it off.
`stopWorker` dismisses the worker the way the game's own hire key does, so the `ai` event that follows reads `AIMessageSuccessStoppedByUser`.
`acceptContract` sends the game's own start request, so its ack means "asked".
The game's answer is the contract itself: the next `missions` frame, sent about a second later, shows it `PREPARING` or `RUNNING` and `mine`.
`husbandry:` and `production:` take the name the `estate` frame sends, or a network object id.

Diagnostics (print to the game log, change nothing):
`dumpVehicle` `dumpActions` `dumpCategories` `dumpFillTypes` `dumpMenu` `probeReport` (writes `probe.txt` beside the command file)

`probeTimeScale` (value: a speed) sets the game speed, reads it back and restores the speed it found at once.
It exists to check that a mod can set the speed at all.

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

Nothing in 2.20 changes what the plugin's pipe, files or frames carry; it only adds a second, separate channel.
The one exception is a fix: `world.weatherNext`, which the 2.19 mod never managed to send, now arrives.


The envelope above (event names, top-level keys, the command file, the session file) is what I hold stable across mod versions.
Fields inside `vehicle`, `fleet` and the rest gain keys as the mod learns to read more of the game; existing keys keep their meaning.
A version bump in the first two components (`2.x` to `3.x`) is the signal that something in the envelope changed.
