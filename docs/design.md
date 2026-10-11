# Design

Why dot-achievements is shaped the way it is, and why the obvious alternative is wrong in each case.

## What this is, and what it is not

A **stat** is a number about a player; dot-stats has those. An **achievement** is a condition over one or more of them, plus what it is called and what it is worth. Nothing here counts anything: the game counts, and this decides.

The two addons do not import each other, and this one carries its own values rather than dot-stats' `DotStatsValues`, for the family reason (naming an absent `class_name` fails to parse) and for a real one: these are **lifetime** numbers and dot-stats' are a **session**.

## The merge, borrowed on purpose

`DotAchievementRule.Merge` is the same four answers `DotStatsDef.Kind` gives, because the one thing every party touching a number has to agree on is what happens when a new reading meets an old one. If this addon answered it differently from the addon producing the numbers, a lifetime counter would be silently replaced by a session one. **The duplication is deliberate and both sides are tested directly**, exactly as `DotStatsDef.merge` and website-city's `PlayerStatMerge` are the same function written twice.

## The bridge is a class, not one `connect`

dot-stats emits `recorded(player, stat, value)` where `value` is the player's running **session** total: its whole design is that a session is what a server counts and a delta is what it reports. Wiring that straight into `record()` adds the session total to the lifetime total on every reading: 1, then 3, then 6, then 10 after four kills.

`DotAchievementStatsLink` holds the last session value per player and stat and files the difference. A value that goes **down** is a new session, not a negative delta. Only `SUM` stats are differenced: a personal best is an absolute in both systems and differencing one would be meaningless.

## A player must be begun

`DotAchievementTracker.record` refuses a player who has not been loaded, with `CODE_STATE`. dot-stats begins a player implicitly and is right to: a session tracker starting from zero is starting from the truth. Here it would evaluate a returning player's lifetime achievements against a blank slate, awarding their first-kill achievement again and then writing that record back over the real one.

For the same reason **a store that cannot read is a failure, not an empty player**. Handing back a fresh `DotAchievementProgress` when a database is down gives a returning player a blank account and then saves it. And **a failed save leaves the dirty flag set**: clearing it is how a store that was briefly unavailable turns into progress quietly discarded at the next autosave.

## The index, and why the catalogue is a class

A reading arrives and something has to decide which achievements it could have moved. Walking the whole catalogue per reading is a hundred players times fifty stats times two hundred achievements, per second, on the busiest thing a server does. The catalogue builds `stat -> achievements` in `validate()` and the tracker evaluates only what the stat touches.

`validate()` also refuses:

- **Two achievements with one id.** The store is keyed by id, so earning either would mark both, for ever, in every save file written afterwards.
- **One stat read with two different merges.** A number cannot be both a running total and a personal best. Caught at boot, because the symptom otherwise is one of the two achievements never unlocking, for one player, on one server, with nothing erroring.
- **A tier with no series to be a tier of.**

## Details that look arbitrary and are not

- **A missing stat reads as zero**, which an `AT_MOST` rule is satisfied by. "Deaths at most zero" is earned by a player who has never been recorded dying. That is what the rule says and not always what its author meant; the self-test has a player earn a flawless-round achievement on their fifth kill so it is discovered here rather than in a bug report.
- **`AT_MOST` has no progress fraction.** "Deaths at most 0" is not 90% done at one death, and a bar drawn at 90% would be a lie. `has_progress()` says whether a bar can be drawn at all.
- **Progress with `require_all` is the mean of the requirements; without it, the best single one.** Any of them finishing is enough in the second case.
- **Hidden and secret are applied in `to_player_dictionary`, not in a UI.** A description withheld by the interface that drew it was still sent to the client, and a determined player reads it out of the packet.
- **Comparisons carry an epsilon.** A value summed a thousand times is not bit-identical to the same value summed in another order.
- **`merge_value` takes `has_current`.** A first reading of 12 seconds on a `LOWEST` stat is 12, not `min(12, 0.0)`: the bug that makes every player's best time zero the day the feature ships.
- **The stored points total is recounted on load.** It is a cache, and a catalogue whose values changed since the file was written makes it wrong.
- **The file store's name is a slug plus a hash of the whole key.** The slug alone is not unique: dot-timer once shipped exactly that, and two map names differing only in their last character shared one records file. The hash is also what stops a key of `../../etc/passwd` writing outside the directory.
- **The tracker defaults to a memory store.** A default that silently starts writing a file per player under `user://` on a dedicated server is one nobody notices until the disk is full.
- **`DotAchievementStoreFile` calls `DotWeb.sync_filesystem()` after every write**, because `user://` in a browser is an IndexedDB mirror. Otherwise nothing here is platform-specific: no socket and no thread.

## SQL storage, through dot-sql

`DotAchievementStoreSql` is the store for a community whose servers share progress. It holds its driver **untyped** and asks it for `query`, `batch`, `upsert_sql`, `dialect` and `migrate`, so no file in the addon names a dot-sql class and the addon parses without it. Its tables are `DotAchievementSqlSchema`'s plain-dictionary specs, rendered per dialect by the driver, and a database written by a newer build is refused at `open()` rather than read and saved back. A store that is not open fails the load with `CODE_STATE`.

- **Two narrow tables, not a JSON column.** A `progress` column holding the file store's document would be the shortest SQL store there is, and the one nobody can ask "how many have earned this" or "who was first" without parsing every row. `(achievement, unlocked_at)` is indexed for exactly that.
- **A load goes through `DotAchievementProgress.from_dictionary`**, the file store's own parser, so the two cannot disagree about what a progress is. The points total is not stored; the tracker recounts it on load.
- **A save is the whole progress, as one batch**: upsert every held number, insert-if-absent every unlock (an unlock's time is never rewritten), then delete what the progress no longer holds, which is how a revocation reaches the table. Deletes last, so a batch cut off on a driver without transactions leaves a superset rather than a player missing what they had.
- **Saves of one player are serialised**, and the snapshot is taken after the wait. The tracker saves on an unlock *without* awaiting (it is in the middle of a game's scoring) and the autosave saves the same player again; over a network the two can land in either order, and the older one landing second would delete the unlock the newer one just wrote. The suite's `SlowDriver` check fails with the wait removed.

## The backbone reporter

`DotAchievementReporter` speaks three routes that website-city serves (`src/app/api/integration/v1/achievements/*`, scopes `ACHIEVEMENTS_WRITE` and `ACHIEVEMENTS_READ`; enrolled servers get the write scope):

```
POST /api/integration/v1/achievements/define
POST /api/integration/v1/achievements/unlock
GET  /api/integration/v1/achievements/player
```

`define` sends the catalogue in this addon's own shape, `DotAchievement.to_dictionary()` (`id`, `require_all`, `icon`, rules as `{stat, op, value, merge}` with the lower-case names), and the site takes exactly that; it also accepts `key` for `id`, and ignores `app` because the credential names the owner. `unlock` uses the backbone's field names (`player`, `key`, `unlockedAt` in Unix seconds). The two sides were checked side by side: the site's schema test is fed bodies captured from this reporter over a real game's catalogue, and the reporter has been driven through dot-auth's `DotBackboneClient` against a running site. Do that again after changing either side, because the family has twice found a reporter sending its own shape where a schema expected another (dot-leaderboard's and dot-stats'), and every request either would have made would have been refused.

Both writes are idempotent: a re-sent define changes nothing, and an unlock already on file only ever moves its time earlier. An unlock for an achievement the site has no definition for is named in `refused` on a 200 while the rest applies; `flush()` logs it at ERROR, because the tracker declares before it flushes and a refusal therefore means a define that failed or an id missing from the catalogue.

**The tracker drives the reporter; nothing else does.** With `report_to_backbone` on, `DotAchievementTracker` calls `report()` every `report_interval` seconds (10 by default): it declares the catalogue once (retried on a doubling delay while the backbone is unreachable, abandoned after a refusal it will not retry) and then flushes the queue. The tracker is the owner because it is the node a host already places and the family has no autoload to hang a timer on. A host may `await tracker.report()` itself before shutting down, so the last round's unlocks are not left queued.

The reporter refuses a `backbone:`-prefixed account id as a player key before it leaves the process, which is dot-stats' rule and dot-user's reason: an operator must not be able to correlate their players across servers, and a report carrying an account uid would undo that from the reporting side.

## Deliberately not here

- **Art, toasts and a list screen.** `listing()` gives you rows; dot-ui gives you somewhere to put them. `icon_id` is an id this addon never resolves.
- **Counting.** The game counts, or dot-stats does.
- **"Gold implies silver".** Nothing enforces that a higher tier awards the lower ones. A game that wants it states both as rules; the alternative is an achievement whose condition is another achievement, and a store holding one and not the other then disagrees with itself.
- **Cross-server totals.** A tracker is one deployment's. Two servers sharing progress share a `DotAchievementStore`, which is the seam that exists for it; `DotAchievementStoreSql` over one database is the one that ships.
- **Anti-cheat.** A server that files a reading is trusted to have meant it. Nothing here can tell an earned kill from an invented one, and pretending otherwise would be worse than saying so.
