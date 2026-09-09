class_name DotAchievementTracker
extends Node

## Holds what players have done, decides what they have earned, and says so.
##
## [codeblock]
## var tracker := DotAchievementTracker.new()
## tracker.catalogue = my_catalogue
## tracker.store = DotAchievementStoreFile.new("user://achievements")
## tracker.unlocked.connect(func(player: String, a: DotAchievement) -> void:
##     hud.toast("%s unlocked" % a.display_name))
## add_child(tracker)
##
## await tracker.begin(player_key)          # loads their lifetime numbers
## tracker.record(player_key, &"kills", 1)  # merged by the rule's own kind
## await tracker.end(player_key)            # saves
## [/codeblock]
##
## [b]A player must be begun before anything can be filed for them, and that is not
## an oversight.[/b] dot-stats begins a player implicitly, which is right there: a
## session tracker starting from zero is starting from the truth. Here it would mean
## evaluating a returning player's lifetime achievements against a blank slate — so
## a player who has played for a year would unlock their first-kill achievement
## again, and then have it written back over the real record. Filing a reading for a
## player who is not loaded is refused with [constant DotError.CODE_STATE].

const CHANNEL := "achievements"

const SERVICE := &"dot_achievements"

## Somebody earned something. Fired once per achievement per player, ever.
signal unlocked(player: String, achievement: DotAchievement)

## Progress towards something moved. Only for achievements that can draw a bar, and
## only when the fraction actually changed — a counter at 0.4001 is not news.
signal progressed(player: String, achievement: DotAchievement, fraction: float)

## A player's progress could not be read. They are not begun and nothing will be
## filed for them.
signal load_failed(player: String, error: DotError)

## A save failed. Worth surfacing: it is the one failure a player feels.
signal save_failed(player: String, error: DotError)

@export_group("Catalogue")

@export var catalogue: DotAchievementCatalogue = null

## A JSON catalogue, loaded when [member catalogue] is not set.
@export_file("*.json") var catalogue_file: String = ""

@export_group("Saving")

## Seconds between automatic saves of players whose progress changed. 0 disables it,
## and then nothing is written until [method end] or [method flush].
@export_range(0.0, 600.0, 1.0) var autosave_interval: float = 30.0

## Save a player the moment they earn something, on top of the autosave.
##
## On. An achievement is the one number a player will notice losing, and the window
## between earning it and a crash is otherwise a whole autosave interval.
@export var save_on_unlock: bool = true

@export_group("Integration")

@export var register_as: StringName = SERVICE

## Report unlocks to the backbone through [member reporter].
@export var report_to_backbone: bool = false

## Where progress lives. Defaults to memory — see [DotAchievementStoreMemory] for
## why that rather than a file.
var store: DotAchievementStore = null

## The backbone reporter. Created on start; needs a client to do anything.
var reporter: DotAchievementReporter = null

var _players: Dictionary = {}
var _fractions: Dictionary = {}
var _autosave_left: float = 0.0
var _started: bool = false


func _ready() -> void:
	start()


## Prepares the tracker. Idempotent, and called by [method _ready].
##
## Explicit because a tracker created through a [DotNodeRef] has already run
## [method _ready] by the time its host assigns a catalogue — the ordering that left
## dot-server's audit log unopened in every default configuration.
func start() -> DotResult:
	if _started:
		return DotResult.success(self)

	if catalogue == null and catalogue_file != "":
		var loaded := DotAchievementCatalogue.from_json_file(catalogue_file)
		if not loaded.ok:
			return loaded.wrap("The achievement catalogue could not be loaded.")
		catalogue = loaded.value

	if catalogue == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The tracker has no catalogue."
		)

	var valid := catalogue.validate()
	if not valid.ok:
		return valid.wrap("The achievement catalogue is not usable.")

	if store == null:
		store = DotAchievementStoreMemory.new()

	if reporter == null:
		reporter = DotAchievementReporter.new()

	if register_as != &"":
		DotRegistry.register(register_as, self)

	_autosave_left = autosave_interval
	_started = true
	set_process(autosave_interval > 0.0)

	DotLog.info(CHANNEL, "achievement tracker ready", {
		"achievements": catalogue.size(),
		"points": catalogue.total_points(),
		"stats": catalogue.watched_stats().size(),
	})

	return DotResult.success(self)


func _process(delta: float) -> void:
	if autosave_interval <= 0.0:
		return

	_autosave_left -= delta
	if _autosave_left > 0.0:
		return

	_autosave_left = autosave_interval
	_save_dirty()


# --- Players ---------------------------------------------------------------

## Loads a player's lifetime progress. Await it before filing anything for them.
func begin(player: String) -> DotResult:
	if not _started:
		var started := start()
		if not started.ok:
			return started

	if player.strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "A player needs a key.")

	if _players.has(player):
		return DotResult.success(_players[player])

	# Assigned to a variable and then checked. `await store.load(x).ok` binds the
	# await to the property access rather than to the call, so the coroutine is never
	# awaited and the branch reads a property of a signal.
	var res: DotResult = await store.load_progress(player)
	if not res.ok:
		load_failed.emit(player, res.error)
		return res.wrap("Could not load achievement progress for a player.")

	var progress: DotAchievementProgress = res.value

	# The stored points total is a cache, and a catalogue whose values changed since
	# the file was written makes it wrong. Recounted rather than trusted.
	progress.recount(catalogue)

	_players[player] = progress
	return DotResult.success(progress)


func has(player: String) -> bool:
	return _players.has(player)


## Saves and forgets a player. Call it when they disconnect.
func end(player: String) -> DotResult:
	if not _players.has(player):
		return DotResult.success(0)

	var progress: DotAchievementProgress = _players[player]
	var res: DotResult = await _save(player, progress)

	_players.erase(player)
	_fractions.erase(player)

	return res


func progress_of(player: String) -> DotAchievementProgress:
	if _players.has(player):
		return _players[player]
	return null


func is_unlocked(player: String, id: StringName) -> bool:
	var progress := progress_of(player)
	return progress != null and progress.is_unlocked(id)


func points_of(player: String) -> int:
	var progress := progress_of(player)
	return progress.points if progress != null else 0


# --- Recording -------------------------------------------------------------

## Files one reading, merged by the rule kind the catalogue declared for that stat.
##
## For a [constant DotAchievementRule.Merge.SUM] stat that is a delta — one kill,
## twelve metres. For the others it is the value itself: a top speed, a level, a best
## time. The stat's own declaration decides, which is why one method serves both and
## why a game cannot get it the wrong way round by calling the wrong one.
func record(player: String, stat: StringName, reading: float = 1.0) -> DotResult:
	if not _started:
		var started := start()
		if not started.ok:
			return started

	if not _players.has(player):
		return DotResult.fail(
			DotError.CODE_STATE,
			"That player is not loaded; call begin() and await it first.",
			player
		)

	var merge := catalogue.merge_for(stat)
	if merge < 0:
		# Not a failure. A game reports far more than a catalogue reads, and refusing
		# every unwatched stat would make the call site branch on which stats happen
		# to have achievements today.
		return DotResult.success(0)

	var progress: DotAchievementProgress = _players[player]
	var had := progress.has_value(stat)
	var held := progress.value_of(stat)

	var rule := DotAchievementRule.make(stat, 0.0, DotAchievementRule.Op.AT_LEAST, merge as DotAchievementRule.Merge)
	progress.set_value(stat, rule.merge_value(held, reading, had))

	return _evaluate(player, progress, stat)


## Overwrites a held value, ignoring the merge rule.
##
## For a game seeding a player's lifetime numbers from somewhere else — a save file,
## a backbone profile, a migration. Not for gameplay: a reading filed this way skips
## the one rule every party is supposed to agree on.
func set_value(player: String, stat: StringName, value: float) -> DotResult:
	if not _players.has(player):
		return DotResult.fail(
			DotError.CODE_STATE, "That player is not loaded.", player
		)

	var progress: DotAchievementProgress = _players[player]
	progress.set_value(stat, value)

	return _evaluate(player, progress, stat)


## Awards something directly, with no rule involved.
##
## For an achievement whose condition is not a number — "played on the day the server
## opened", "was in the room when somebody did the thing". A catalogue still has to
## declare it, so it can be listed and is worth points.
func unlock(player: String, id: StringName, reason: String = "") -> DotResult:
	if not _players.has(player):
		return DotResult.fail(
			DotError.CODE_STATE, "That player is not loaded.", player
		)

	var achievement := catalogue.find(id)
	if achievement == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "No such achievement.", String(id)
		)

	var progress: DotAchievementProgress = _players[player]
	if not _award(player, progress, achievement, reason):
		return DotResult.success(false)

	return DotResult.success(true)


## Takes one back. For a moderator, or a game resetting a season.
func revoke(player: String, id: StringName) -> DotResult:
	if not _players.has(player):
		return DotResult.fail(
			DotError.CODE_STATE, "That player is not loaded.", player
		)

	var achievement := catalogue.find(id)
	if achievement == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "No such achievement.", String(id)
		)

	var progress: DotAchievementProgress = _players[player]
	return DotResult.success(progress.revoke(id, achievement.points))


func _evaluate(
	player: String, progress: DotAchievementProgress, stat: StringName
) -> DotResult:
	var awarded := 0

	# Only the achievements this stat could have moved. Walking the whole catalogue
	# per reading is a hundred players times fifty stats times two hundred
	# achievements, per second, on the busiest thing a server does.
	for achievement in catalogue.affected_by(stat):
		if progress.is_unlocked(achievement.id):
			continue

		if achievement.evaluate(progress.values):
			if _award(player, progress, achievement, "earned"):
				awarded += 1
			continue

		if not achievement.has_progress():
			continue

		var fraction := achievement.progress(progress.values)
		var key := "%s#%s" % [player, String(achievement.id)]
		var before := float(_fractions.get(key, -1.0))

		# Only when it actually moved. A counter that ticks a thousand times a round
		# would otherwise emit a thousand signals for a bar that moved a pixel.
		if absf(fraction - before) >= 0.005:
			_fractions[key] = fraction
			progressed.emit(player, achievement, fraction)

	return DotResult.success(awarded)


func _award(
	player: String,
	progress: DotAchievementProgress,
	achievement: DotAchievement,
	reason: String
) -> bool:
	var at := int(Time.get_unix_time_from_system())

	if not progress.mark_unlocked(achievement.id, at, achievement.points):
		return false

	DotLog.info(CHANNEL, "achievement unlocked", {
		"player": player.substr(0, 16),
		"achievement": String(achievement.id),
		"points": achievement.points,
		"reason": reason,
	})

	if report_to_backbone and reporter != null:
		reporter.queue(player, achievement.id, at)

	unlocked.emit(player, achievement)

	if save_on_unlock:
		# Deliberately not awaited. This is called from the middle of a game's
		# scoring, and a store behind a network is a store that would stall it. The
		# save runs and its failure is reported through save_failed; the autosave and
		# end() are the backstops.
		_save(player, progress)

	return true


# --- Saving ----------------------------------------------------------------

## Saves every player whose progress changed.
func flush() -> DotResult:
	return await _save_dirty()


func _save_dirty() -> DotResult:
	var saved := 0

	for player in _players.keys():
		var progress: DotAchievementProgress = _players[player]
		if not progress.dirty:
			continue
		var res: DotResult = await _save(str(player), progress)
		if res.ok:
			saved += 1

	return DotResult.success(saved)


func _save(player: String, progress: DotAchievementProgress) -> DotResult:
	var res: DotResult = await store.save_progress(player, progress)

	if not res.ok:
		# The dirty flag is deliberately left set. Clearing it on a failed save is how
		# a store that was briefly unavailable turns into a player's progress being
		# quietly discarded at the next autosave.
		save_failed.emit(player, res.error)
		return res

	progress.dirty = false
	return res


# --- Reading ---------------------------------------------------------------

## The player-facing list: what to draw, with hidden and secret applied.
##
## Filtered here rather than in a UI, because a description withheld by the interface
## that drew it was still sent to the client.
func listing(player: String) -> Array[Dictionary]:
	var progress := progress_of(player)
	var out: Array[Dictionary] = []

	for achievement in catalogue.achievements:
		if achievement == null:
			continue

		var is_unlocked_ := progress != null and progress.is_unlocked(achievement.id)
		var row := achievement.to_player_dictionary(is_unlocked_)

		if row.is_empty():
			continue

		if is_unlocked_ and progress != null:
			row["at"] = progress.unlocked_at(achievement.id)
		elif progress != null and achievement.has_progress():
			row["progress"] = achievement.progress(progress.values)

		out.append(row)

	return out


func _exit_tree() -> void:
	if register_as != &"":
		DotRegistry.unregister_instance(register_as, self)


func describe() -> Dictionary:
	return {
		"achievements": catalogue.size() if catalogue != null else 0,
		"players": _players.size(),
		"store": store.get_class() if store != null else "",
		"reporting": report_to_backbone,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("achievement tracker: %d players loaded" % _players.size())

	if catalogue != null:
		out.append_array(catalogue.describe_lines())

	for player in _players.keys():
		var progress: DotAchievementProgress = _players[player]
		out.append("  %s: %s" % [str(player).substr(0, 16), progress.describe()])

	return out
