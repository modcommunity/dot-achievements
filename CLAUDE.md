# dot-achievements

Achievements as rules over per-player numbers: declared once, checkable without
loading art, stored behind a pluggable store, reported to the backbone in batches.

**The distributable is `addons/dot_achievements/`.** It requires
[dot-core](../dot-core), a separate repository, and nothing else.

```bash
# Local development setup — the symlink is gitignored on purpose.
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## What this is, and what it is not

A **stat** is a number about a player; dot-stats has those. An **achievement** is a
condition over one or more of them, plus what it is called and what it is worth.
Nothing here counts anything: the game counts, and this decides.

The two addons do not import each other and this one carries its own values rather
than dot-stats' `DotStatsValues`, for the family reason — naming an absent
`class_name` fails to parse — and for a real one: these are **lifetime** numbers and
dot-stats' are a **session**. See the bridge, below.

## The one idea, borrowed on purpose

`DotAchievementRule.Merge` is the same four answers `DotStatsDef.Kind` gives, because
the one thing every party touching a number has to agree on is what happens when a
new reading meets an old one. If this addon answered it differently from the addon
producing the numbers, a lifetime counter would be silently replaced by a session
one. **The duplication is deliberate and both sides are tested directly**, exactly as
`DotStatsDef.merge` and website-city's `PlayerStatMerge` are the same function written
twice.

## The bridge, and why it is a class rather than one `connect`

dot-stats emits `recorded(player, stat, value)` where `value` is the player's running
**session** total — its whole design is that a session is what a server counts and a
delta is what it reports. Wiring that straight into `record()` adds the session total
to the lifetime total on every reading: 1, then 3, then 6, then 10 after four kills.

`DotAchievementStatsLink` holds the last session value per player and stat and files
the difference. A value that goes **down** is a new session, not a negative delta.
Only `SUM` stats are differenced — a personal best is an absolute in both systems and
differencing one would be meaningless.

## Why a player must be begun

`DotAchievementTracker.record` refuses a player who has not been loaded, with
`CODE_STATE`. dot-stats begins a player implicitly and is right to: a session tracker
starting from zero is starting from the truth. Here it would evaluate a returning
player's lifetime achievements against a blank slate — awarding their first-kill
achievement again, and then writing that record back over the real one.

For the same reason **a store that cannot read is a failure, not an empty player**.
Handing back a fresh `DotAchievementProgress` when a database is down gives a
returning player a blank account and then saves it.

And **a failed save leaves the dirty flag set**. Clearing it is how a store that was
briefly unavailable turns into progress quietly discarded at the next autosave.

## The index, and why the catalogue is a class

A reading arrives and something has to decide which achievements it could have moved.
Walking the whole catalogue per reading is a hundred players times fifty stats times
two hundred achievements, per second, on the busiest thing a server does. The
catalogue builds `stat -> achievements` in `validate()` and the tracker evaluates only
what the stat touches.

`validate()` also refuses:

- **Two achievements with one id.** The store is keyed by id, so earning either would
  mark both, for ever, in every save file written afterwards.
- **One stat read with two different merges.** A number cannot be both a running total
  and a personal best. Caught at boot, because the symptom otherwise is one of the two
  achievements never unlocking, for one player, on one server, with nothing erroring.
- **A tier with no series to be a tier of.**

## Details that look arbitrary and are not

- **A missing stat reads as zero**, which an `AT_MOST` rule is satisfied by. "Deaths
  at most zero" is earned by a player who has never been recorded dying. That is what
  the rule says and not always what its author meant; the self-test has a player earn
  a flawless-round achievement on their fifth kill to make sure it is discovered here
  rather than in a bug report.
- **`AT_MOST` has no progress fraction.** "Deaths at most 0" is not 90% done at one
  death, and a bar drawn at 90% would be a lie. `has_progress()` says whether a bar
  can be drawn at all.
- **Progress with `require_all` is the mean of the requirements; without it, the best
  single one.** Any of them finishing is enough in the second case.
- **Hidden and secret are applied in `to_player_dictionary`, not in a UI.** A
  description withheld by the interface that drew it was still sent to the client, and
  a determined player reads it out of the packet.
- **Comparisons carry an epsilon.** A value summed a thousand times is not
  bit-identical to the same value summed in another order.
- **`merge_value` takes `has_current`.** A first reading of 12 seconds on a `LOWEST`
  stat is 12, not `min(12, 0.0)` — the bug that makes every player's best time zero
  the day the feature ships.
- **The stored points total is recounted on load.** It is a cache, and a catalogue
  whose values changed since the file was written makes it wrong.
- **The file store's name is a slug plus a hash of the whole key.** The slug alone is
  not unique: dot-timer shipped exactly that, and `surf_kitsune2` and `surf_kitsune3`
  both became `surf_kitsune_` and shared one records file. The hash is also what stops
  a key of `../../etc/passwd` writing outside the directory.
- **The tracker defaults to a memory store.** A default that silently starts writing a
  file per player under `user://` on a dedicated server is one nobody notices until
  the disk is full.

## The backbone half does not exist yet

`DotAchievementReporter` speaks three routes that **website-city does not have**:

```
POST /api/integration/v1/achievements/define
POST /api/integration/v1/achievements/unlock
GET  /api/integration/v1/achievements/player
```

Field names follow the backbone's existing convention (`key`, `unlockedAt`) rather
than this addon's file format, because the family has now twice found a reporter
sending its own shape where a schema expected another — dot-leaderboard's and
dot-stats' both, and every request either would have made would have been refused.
Reading the two sides side by side is cheaper than a socket, and there is no other
side to read yet. **Leave `report_to_backbone` off until there is.**

The reporter refuses a `backbone:`-prefixed account id as a player key before it
leaves the process, which is dot-stats' rule and dot-user's reason: an operator must
not be able to correlate their players across servers, and a report carrying an
account uid would undo that from the reporting side.

## Where it runs

Everywhere. No socket and no thread; the only platform note is that
`DotAchievementStoreFile` calls `DotWeb.sync_filesystem()` after every write, because
`user://` in a browser is an IndexedDB mirror and without the flush a player's
progress exists in the tab and not in the browser's storage.

## Validating changes

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/achievements_selftest.tscn
# 11 sections, 136 checks, all offline. Exits non-zero on any failure.
```

## Things deliberately not here

- **Art, toasts and a list screen.** `listing()` gives you rows; dot-ui gives you
  somewhere to put them. `icon_id` is an id this addon never resolves.
- **Counting.** The game counts, or dot-stats does.
- **"Gold implies silver".** Nothing enforces that a higher tier awards the lower
  ones. A game that wants it states both as rules — the alternative is an achievement
  whose condition is another achievement, and a store holding one and not the other
  then disagrees with itself.
- **Cross-server totals.** A tracker is one deployment's. Two servers sharing progress
  share a `DotAchievementStore`, which is the seam that exists for it.
- **Anti-cheat.** A server that files a reading is trusted to have meant it. Nothing
  here can tell an earned kill from an invented one, and pretending otherwise would be
  worse than saying so.
