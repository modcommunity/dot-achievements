This is the **achievements** asset for TMC's **Dot** collection. What a player has earned, as a document a dedicated server can check without ever loading a picture.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Achievements
**Rules over per-player numbers, declared once.** Counters, bests, tiers, hidden and secret entries, progress bars that do not lie, a pluggable store, and a batched reporter for the TMC backbone.

## Why

An achievement whose condition lives inside the code that awards it is one nobody can list, show progress towards, or check a save file against. Stating it as data instead means a server can validate the whole catalogue at boot, decide what somebody has earned, and report it — **without loading a mesh, an icon or a scene**, which is the same reason dot-loadout and dot-user-avatar are documents rather than objects.

## Installing

Copy `addons/dot_achievements/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable dot-achievements in *Project → Project Settings → Plugins*.

[dot-stats](https://github.com/modcommunity/dot-stats) is optional and is the natural source of the numbers; `DotAchievementStatsLink` bridges to it without naming it. [dot-auth](https://github.com/modcommunity/dot-auth) supplies the backbone client and is likewise not named anywhere in the source. Requires Godot 4.7 or newer.

## Five minutes

```gdscript
var catalogue := DotAchievementCatalogue.of([
    DotAchievement.counter(&"k10",  "First Blood", &"kills", 10),
    DotAchievement.counter(&"k100", "Centurion",   &"kills", 100),
    DotAchievement.make(&"flawless", "Flawless", [
        DotAchievementRule.make(&"round_wins", 1),
        DotAchievementRule.make(&"deaths", 0, DotAchievementRule.Op.AT_MOST),
    ]),
])

var tracker := DotAchievementTracker.new()
tracker.catalogue = catalogue
tracker.store = DotAchievementStoreFile.new("user://achievements")
tracker.unlocked.connect(func(player: String, a: DotAchievement) -> void:
    hud.toast("%s unlocked" % a.display_name))
add_child(tracker)

await tracker.begin(player_key)         # loads their lifetime numbers
tracker.record(player_key, &"kills", 1)
await tracker.end(player_key)           # saves
```

`record()` merges by the kind the rule declared — a counter adds, a best keeps the better — so one call serves every stat and a game cannot get it the wrong way round.

## With dot-stats

```gdscript
var link := DotAchievementStatsLink.new()
link.tracker = tracker
link.stats = stats_tracker
add_child(link)
```

dot-stats' `recorded` signal carries a player's **session** total, and an achievement is about a lifetime. Wiring the signal straight into `record()` adds the running session total on every kill — two after the second, five after the third, nine after the fourth. The link holds a baseline and files the difference, and treats a total that goes down as a new session rather than as a negative delta.

## Showing them

```gdscript
for row in tracker.listing(player_key):
    print(row["name"], row.get("progress", row.get("unlocked")))
```

Hidden entries are absent until earned and secret ones arrive without their description — filtered here rather than in a UI, because a description withheld by the interface that drew it was still sent to the client.

## Validating

```bash
godot --headless --path . --import
godot --headless --path . res://examples/achievements_selftest.tscn
# 136 checks, all offline. Exits non-zero on any failure.
```
