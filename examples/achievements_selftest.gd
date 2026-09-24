extends Node

## Exercises dot-achievements with no backbone, no dot-stats and no art.
##
## The stats tracker is faked at the one seam that matters — a
## [code]recorded(player, stat, session_value)[/code] signal — because that signal's
## meaning is the whole reason [DotAchievementStatsLink] exists, and a link written
## against the wrong meaning parses cleanly and awards a player nine kills for their
## fourth.
##
## [codeblock]
## godot --headless --path . res://examples/achievements_selftest.tscn
## [/codeblock]

const SECTIONS := 12
const CHECKS := 147

var _passed := 0
var _failed := 0
var _section_count := 0


## A stand-in for dot-stats' tracker, which this addon never names.
##
## The important part is the signal's payload: dot-stats emits the player's running
## SESSION total, not the reading that caused it.
class FakeStats extends Node:
	signal recorded(player_id: StringName, stat_id: StringName, value: float)

	var sessions: Dictionary = {}

	func record(player: StringName, stat: StringName, delta: float) -> void:
		var key := "%s#%s" % [String(player), String(stat)]
		var total := float(sessions.get(key, 0.0)) + delta
		sessions[key] = total
		recorded.emit(player, stat, total)

	func new_session(player: StringName) -> void:
		for key in sessions.keys():
			if str(key).begins_with(String(player) + "#"):
				sessions[key] = 0.0


## A stand-in for dot-auth's DotBackboneClient.
class FakeBackbone extends RefCounted:
	var calls: Array[Dictionary] = []
	var fail: bool = false
	var retryable: bool = true

	func post_integration(path: String, body: Dictionary) -> DotResult:
		calls.append({"path": path, "body": body.duplicate(true)})
		if fail:
			var code := DotError.CODE_NETWORK if retryable else DotError.CODE_INVALID
			return DotResult.fail(code, "the backbone said no")
		return DotResult.success({"ok": true})

	func get_integration(path: String, query: Dictionary) -> DotResult:
		calls.append({"path": path, "query": query.duplicate(true)})
		return DotResult.success({"player": str(query.get("player", "")), "unlocks": []})


## A store that fails on demand, for the paths that matter most and are never run.
class FlakyStore extends DotAchievementStore:
	var inner := DotAchievementStoreMemory.new()
	var fail_loads: bool = false
	var fail_saves: bool = false
	var saves: int = 0

	func _load_progress(player: String) -> DotResult:
		if fail_loads:
			return DotResult.fail(DotError.CODE_IO, "the disk is on fire")
		return await inner.load_progress(player)

	func _save_progress(player: String, progress: DotAchievementProgress) -> DotResult:
		saves += 1
		if fail_saves:
			return DotResult.fail(DotError.CODE_IO, "the disk is still on fire")
		return await inner.save_progress(player, progress)


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	await _run()


func _run() -> void:
	_line("dot-achievements self-test")
	_line("")

	_test_rules()
	_test_achievements()
	_test_catalogue()
	_test_progress()
	_test_stores()
	await _test_tracker()
	await _test_tracker_refusals()
	await _test_listing()
	await _test_stats_link()
	await _test_reporter()
	await _test_tracker_reports()
	await _test_saving()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


# --- Rules -----------------------------------------------------------------

func _test_rules() -> void:
	_section("rules")

	var at_least := DotAchievementRule.make(&"kills", 100.0)
	_check(at_least.satisfied(100.0), "at_least is satisfied exactly on the threshold")
	_check(at_least.satisfied(101.0), "and above it")
	_check(not at_least.satisfied(99.0), "and not below")

	var at_most := DotAchievementRule.make(
		&"deaths", 0.0, DotAchievementRule.Op.AT_MOST
	)
	_check(at_most.satisfied(0.0), "at_most is satisfied at zero")
	_check(not at_most.satisfied(1.0), "and not at one")

	# A value summed a thousand times is not bit-identical to the same value summed a
	# thousand times in another order, and an achievement that will not unlock on
	# exactly 100 after the hundredth kill is a bug report nobody can reproduce.
	_check(
		at_least.satisfied(99.99995),
		"a float within an epsilon of the threshold counts"
	)

	_check(is_equal_approx(at_least.progress(40.0), 0.4), "progress is a fraction")
	_check(is_equal_approx(at_least.progress(400.0), 1.0), "clamped at one")
	_check(
		is_equal_approx(at_most.progress(1.0), 0.0),
		"an at_most rule is never 90% done: it is done or it is not"
	)
	_check(at_least.has_progress(), "at_least can draw a bar")
	_check(not at_most.has_progress(), "at_most cannot")

	var sum := DotAchievementRule.make(&"k", 1.0, DotAchievementRule.Op.AT_LEAST,
		DotAchievementRule.Merge.SUM)
	_check(is_equal_approx(sum.merge_value(5.0, 3.0), 8.0), "SUM adds")

	var highest := DotAchievementRule.make(&"speed", 1.0,
		DotAchievementRule.Op.AT_LEAST, DotAchievementRule.Merge.HIGHEST)
	_check(is_equal_approx(highest.merge_value(9.0, 3.0), 9.0), "HIGHEST keeps the larger")

	var lowest := DotAchievementRule.make(&"time", 1.0,
		DotAchievementRule.Op.AT_MOST, DotAchievementRule.Merge.LOWEST)
	_check(is_equal_approx(lowest.merge_value(9.0, 3.0), 3.0), "LOWEST keeps the smaller")

	# The bug that makes every player's best time zero on the day the feature ships.
	_check(
		is_equal_approx(lowest.merge_value(0.0, 12.0, false), 12.0),
		"a first reading on a LOWEST stat is that reading, not min(reading, 0)"
	)

	var all_merges := true
	for value in DotAchievementRule.Merge.values():
		var probe := DotAchievementRule.make(&"s", 1.0,
			DotAchievementRule.Op.AT_LEAST, value)
		if DotAchievementRule.merge_from_name(probe.merge_name()) != value:
			all_merges = false
	_check(all_merges, "every Merge round-trips through its name")

	var all_ops := true
	for value in DotAchievementRule.Op.values():
		var probe := DotAchievementRule.make(&"s", 1.0, value)
		if DotAchievementRule.op_from_name(probe.op_name()) != value:
			all_ops = false
	_check(all_ops, "every Op round-trips through its name")

	var round_trip := DotAchievementRule.from_dictionary(lowest.to_dictionary())
	_check(round_trip.ok, "a rule round-trips through its dictionary")
	_check(
		(round_trip.value as DotAchievementRule).merge == DotAchievementRule.Merge.LOWEST,
		"keeping its merge, which is the one thing every party has to agree on"
	)

	_check(
		not DotAchievementRule.from_dictionary({"stat": "k", "merge": "average"}).ok,
		"an unknown merge name is refused rather than defaulted to SUM"
	)
	_check(
		not DotAchievementRule.make(&"", 1.0).validate().ok,
		"a rule with no stat is refused"
	)


func _test_achievements() -> void:
	_section("achievements")

	var flawless := DotAchievement.make(&"flawless", "Flawless", [
		DotAchievementRule.make(&"round_wins", 1.0),
		DotAchievementRule.make(&"deaths", 0.0, DotAchievementRule.Op.AT_MOST),
	] as Array[DotAchievementRule])

	_check(flawless.validate().ok, "an achievement with rules validates")
	_check(
		flawless.evaluate({&"round_wins": 1.0, &"deaths": 0.0}),
		"all requirements met earns it"
	)
	_check(
		not flawless.evaluate({&"round_wins": 1.0, &"deaths": 1.0}),
		"one unmet does not"
	)
	_check(
		flawless.evaluate({&"round_wins": 1.0}),
		"a missing stat reads as zero, which an at_most rule is satisfied by"
	)

	var either := DotAchievement.make(&"either", "Either", [
		DotAchievementRule.make(&"a", 10.0),
		DotAchievementRule.make(&"b", 10.0),
	] as Array[DotAchievementRule])
	either.require_all = false
	_check(either.evaluate({&"a": 10.0}), "with require_all off, any one is enough")
	_check(not either.evaluate({&"a": 9.0, &"b": 9.0}), "and none is not")

	var counter := DotAchievement.counter(&"k100", "Centurion", &"kills", 100.0)
	_check(is_equal_approx(counter.progress({&"kills": 25.0}), 0.25), "progress reports")

	var mixed := DotAchievement.make(&"mixed", "Mixed", [
		DotAchievementRule.make(&"a", 100.0),
		DotAchievementRule.make(&"b", 100.0),
	] as Array[DotAchievementRule])
	_check(
		is_equal_approx(mixed.progress({&"a": 100.0, &"b": 0.0}), 0.5),
		"with require_all, progress is the mean of the requirements"
	)
	mixed.require_all = false
	_check(
		is_equal_approx(mixed.progress({&"a": 100.0, &"b": 0.0}), 1.0),
		"without it, the best single one, because any of them finishing is enough"
	)

	var empty := DotAchievement.make(&"empty", "Empty", [] as Array[DotAchievementRule])
	_check(
		not empty.validate().ok,
		"an achievement with no requirements can never be earned and is refused"
	)
	_check(not empty.evaluate({}), "and evaluates to false rather than to true")

	var tiered := DotAchievement.counter(&"t", "Tier", &"kills", 10.0)
	tiered.tier = 2
	_check(
		not tiered.validate().ok,
		"a tier with no series to be a tier of is refused"
	)

	var hidden := DotAchievement.counter(&"h", "Hidden", &"kills", 1.0)
	hidden.hidden = true
	_check(
		hidden.to_player_dictionary(false).is_empty(),
		"a hidden achievement is not listed until it is earned"
	)
	_check(
		not hidden.to_player_dictionary(true).is_empty(),
		"and is afterwards"
	)

	var secret := DotAchievement.counter(&"s", "Secret", &"kills", 1.0)
	secret.secret = true
	secret.description = "do the thing"
	var row := secret.to_player_dictionary(false)
	_check(str(row.get("name", "")) == "Secret", "a secret one shows its name")
	_check(
		not row.has("description"),
		"and withholds the description here rather than in a UI: what a UI hides was "
		+ "still sent to the client"
	)

	var back := DotAchievement.from_dictionary(flawless.to_dictionary())
	_check(back.ok, "an achievement round-trips")
	_check(
		(back.value as DotAchievement).requirements.size() == 2,
		"with its rules"
	)


func _test_catalogue() -> void:
	_section("catalogue")

	var catalogue := _catalogue()
	var valid := catalogue.validate()
	_check(valid.ok, "a catalogue validates")

	_check(catalogue.find(&"k100") != null, "achievements are found by id")
	_check(catalogue.find(&"nope") == null, "and a missing one is null")

	var watched := catalogue.watched_stats()
	_check(watched.size() == 5, "it knows every stat it reads")
	_check(
		watched[0] == &"attended" and watched[watched.size() - 1] == &"secret_deed",
		"sorted by string, not by StringName pointer order"
	)

	var affected := catalogue.affected_by(&"kills")
	_check(affected.size() == 3, "and which achievements a stat could have moved")
	_check(catalogue.affected_by(&"unwatched").is_empty(), "and which none did")

	_check(
		catalogue.merge_for(&"best_time") == int(DotAchievementRule.Merge.LOWEST),
		"the merge for a stat comes out of the rules that read it"
	)
	_check(catalogue.merge_for(&"unwatched") < 0, "and is -1 for one nothing reads")

	_check(catalogue.in_series(&"kills").size() == 2, "a series comes out")
	_check(
		(catalogue.in_series(&"kills")[0] as DotAchievement).tier == 1,
		"in tier order"
	)
	_check(catalogue.total_points() > 0, "points total")

	var duplicated := DotAchievementCatalogue.of([
		DotAchievement.counter(&"same", "One", &"a", 1.0),
		DotAchievement.counter(&"same", "Two", &"b", 1.0),
	] as Array[DotAchievement])
	_check(
		not duplicated.validate().ok,
		"two achievements sharing an id are refused: the store is keyed by it"
	)

	# One number cannot be both a running total and a personal best. Caught at boot,
	# because the symptom otherwise is one of the two achievements never unlocking.
	var disagreeing := DotAchievementCatalogue.of([
		DotAchievement.make(&"a", "A", [
			DotAchievementRule.make(&"speed", 10.0, DotAchievementRule.Op.AT_LEAST,
				DotAchievementRule.Merge.SUM),
		] as Array[DotAchievementRule]),
		DotAchievement.make(&"b", "B", [
			DotAchievementRule.make(&"speed", 20.0, DotAchievementRule.Op.AT_LEAST,
				DotAchievementRule.Merge.HIGHEST),
		] as Array[DotAchievementRule]),
	] as Array[DotAchievement])
	_check(
		not disagreeing.validate().ok,
		"one stat read with two different merges is refused"
	)

	var json := catalogue.to_dictionary()
	var reloaded := DotAchievementCatalogue.from_dictionary(json)
	_check(reloaded.ok, "a catalogue round-trips through JSON")
	_check(
		(reloaded.value as DotAchievementCatalogue).size() == catalogue.size(),
		"whole"
	)

	_check(
		not DotAchievementCatalogue.from_dictionary({"achievements": "no"}).ok,
		"and something that is not one is refused"
	)


func _test_progress() -> void:
	_section("progress")

	var progress := DotAchievementProgress.new()
	_check(not progress.dirty, "a fresh progress is clean")

	progress.set_value(&"kills", 5.0)
	_check(progress.dirty, "a write marks it dirty")
	_check(is_equal_approx(progress.value_of(&"kills"), 5.0), "and holds the value")
	_check(not progress.has_value(&"deaths"), "and knows what it has never seen")

	_check(progress.mark_unlocked(&"k100", 1000, 25), "an unlock takes")
	_check(not progress.mark_unlocked(&"k100", 2000, 25), "and only once")
	_check(progress.points == 25, "points accumulate once")

	var dict := progress.to_dictionary()
	(dict["values"] as Dictionary)[&"kills"] = 999.0
	_check(
		is_equal_approx(progress.value_of(&"kills"), 5.0),
		"to_dictionary hands out a copy, not the live dictionary"
	)

	var back := DotAchievementProgress.from_dictionary(progress.to_dictionary())
	_check(back.ok, "progress round-trips")
	var restored: DotAchievementProgress = back.value
	_check(restored.is_unlocked(&"k100"), "with its unlocks")
	_check(restored.unlocked_at(&"k100") == 1000, "and when they happened")
	_check(not restored.dirty, "and comes back clean")

	# The stored total is a cache, and a catalogue whose values changed since the file
	# was written makes it wrong.
	restored.points = 9999
	restored.recount(_catalogue())
	_check(restored.points == 25, "points are recounted from the catalogue, not trusted")

	restored.revoke(&"k100", 25)
	_check(not restored.is_unlocked(&"k100"), "an unlock can be revoked")
	_check(restored.points == 0, "and takes its points with it")


func _test_stores() -> void:
	_section("stores")

	var memory := DotAchievementStoreMemory.new()
	var fresh: DotResult = await memory.load_progress("nobody")
	_check(fresh.ok, "an unknown player loads")
	_check(
		(fresh.value as DotAchievementProgress).unlocked_count() == 0,
		"as a fresh progress rather than as a failure"
	)

	var progress := DotAchievementProgress.new()
	progress.mark_unlocked(&"k100", 5, 25)
	await memory.save_progress("ada", progress)

	var read: DotResult = await memory.load_progress("ada")
	_check((read.value as DotAchievementProgress).is_unlocked(&"k100"), "a save reads back")

	var second: DotResult = await memory.load_progress("ada")
	(second.value as DotAchievementProgress).mark_unlocked(&"other", 6, 5)
	var third: DotResult = await memory.load_progress("ada")
	_check(
		not (third.value as DotAchievementProgress).is_unlocked(&"other"),
		"a store hands out copies: two callers holding one object is two writers"
	)

	var directory := "user://dot_achievements_selftest"
	# From nothing, every run: "a player with no file is a fresh player" and every
	# save-then-load below mean nothing against a directory the last run left full.
	DotPaths.remove_tree(directory)
	var file := DotAchievementStoreFile.new(directory)

	# Two keys that slugify identically. dot-timer shipped exactly this: surf_kitsune2
	# and surf_kitsune3 both became surf_kitsune_ and shared one records file.
	var a := file.path_for("player one!")
	var b := file.path_for("player one?")
	_check(a != b, "two keys that slugify the same still get different files")

	_check(
		not file.path_for("../../etc/passwd").contains(".."),
		"a key cannot walk out of the directory it is stored in"
	)

	await file.save_progress("ada", progress)
	var from_disk: DotResult = await file.load_progress("ada")
	_check(from_disk.ok, "a file store saves and loads")
	_check(
		(from_disk.value as DotAchievementProgress).is_unlocked(&"k100"),
		"with the unlocks in it"
	)

	var missing: DotResult = await file.load_progress("never-seen")
	_check(
		missing.ok and (missing.value as DotAchievementProgress).unlocked_count() == 0,
		"a player with no file is a fresh player, not an error"
	)

	DotPaths.write_text(file.path_for("broken"), "{ this is not json")
	var corrupt: DotResult = await file.load_progress("broken")
	_check(
		not corrupt.ok,
		"a file that exists and cannot be read fails, so it is not overwritten with "
		+ "a blank one on the next save"
	)


# --- The tracker -----------------------------------------------------------

func _test_tracker() -> void:
	_section("tracker")

	var tracker := _tracker()
	var began: DotResult = await tracker.begin("ada")
	_check(began.ok, "a player begins")

	var unlocks: Array[String] = []
	tracker.unlocked.connect(func(player: String, a: DotAchievement) -> void:
		# A lambda captures locals by value; append to a captured Array.
		unlocks.append("%s/%s" % [player, String(a.id)]))

	var bars: Array[float] = []
	tracker.progressed.connect(
		func(_p: String, _a: DotAchievement, fraction: float) -> void:
			bars.append(fraction))

	for i in 9:
		tracker.record("ada", &"kills", 1.0)
	_check(bars.size() > 0, "progress is reported on the way")

	# Not nothing. `flawless` is "five kills and at most zero deaths", and a player
	# who has never been recorded dying holds no deaths value at all — which reads as
	# zero, which satisfies an at_most rule. That is exactly what the rule says and
	# not always what its author meant, and it is worth a player earning it on their
	# fifth kill in a suite rather than in a bug report.
	_check(
		unlocks.size() == 1 and unlocks[0] == "ada/flawless",
		"nine kills earns the flawless one, because a missing stat reads as zero"
	)

	tracker.record("ada", &"kills", 1.0)
	_check(unlocks.size() == 2, "the tenth earns the first kill tier")
	_check(unlocks.has("ada/k10"), "the right one")

	tracker.record("ada", &"kills", 1.0)
	_check(unlocks.size() == 2, "and not again")

	var progress := tracker.progress_of("ada")
	_check(is_equal_approx(progress.value_of(&"kills"), 11.0), "SUM accumulates")
	_check(tracker.points_of("ada") == 20, "points are held for both")

	tracker.record("ada", &"best_time", 30.0)
	_check(
		is_equal_approx(progress.value_of(&"best_time"), 30.0),
		"a first LOWEST reading is that reading"
	)
	tracker.record("ada", &"best_time", 40.0)
	_check(
		is_equal_approx(progress.value_of(&"best_time"), 30.0),
		"and a worse one does not replace it"
	)
	_check(not tracker.is_unlocked("ada", &"fast"), "which has not earned the fast one")

	tracker.record("ada", &"best_time", 9.0)
	_check(tracker.is_unlocked("ada", &"fast"), "a better one does, and earns it")

	# A game reports far more than a catalogue reads. Refusing every unwatched stat
	# would make the call site branch on which stats happen to have achievements.
	var unwatched := tracker.record("ada", &"shots_fired", 40.0)
	_check(unwatched.ok, "an unwatched stat is accepted and ignored")

	var manual := tracker.unlock("ada", &"opening_day", "was there")
	_check(manual.ok and bool(manual.value), "an achievement can be awarded directly")
	_check(
		tracker.unlock("ada", &"opening_day").ok
		and not bool(tracker.unlock("ada", &"opening_day").value),
		"and is not awarded twice"
	)

	_check(not tracker.unlock("ada", &"nonexistent").ok, "an unknown id is refused")

	tracker.revoke("ada", &"opening_day")
	_check(not tracker.is_unlocked("ada", &"opening_day"), "and can be taken back")

	tracker.queue_free()


func _test_tracker_refusals() -> void:
	_section("tracker: refusals")

	var tracker := _tracker()

	# The one that matters. dot-stats begins a player implicitly and is right to;
	# here it would evaluate a returning player's lifetime achievements against a
	# blank slate, award their first-kill achievement again, and write it back over
	# the real record.
	var early := tracker.record("nobody", &"kills", 1.0)
	_check(
		not early.ok and early.code() == DotError.CODE_STATE,
		"filing for a player who is not loaded is refused rather than starting them "
		+ "from zero"
	)

	_check(not tracker.unlock("nobody", &"k10").ok, "so is awarding to one")
	_check(not (await tracker.begin("")).ok, "and a player with no key")

	var flaky := FlakyStore.new()
	flaky.fail_loads = true

	var refusing := _tracker()
	refusing.store = flaky

	var failures: Array[String] = []
	refusing.load_failed.connect(func(player: String, _e: DotError) -> void:
		failures.append(player))

	var failed: DotResult = await refusing.begin("ada")
	_check(not failed.ok, "a store that cannot read is a failure, not an empty player")
	_check(failures.size() == 1, "and is announced")
	_check(
		not refusing.has("ada"),
		"the player is not loaded, so nothing can be filed for them"
	)

	var without := DotAchievementTracker.new()
	without.register_as = &""
	_check(
		not without.start().ok,
		"a tracker with no catalogue refuses to start rather than awarding nothing "
		+ "quietly"
	)

	tracker.queue_free()
	refusing.queue_free()
	without.queue_free()


func _test_listing() -> void:
	_section("listing")

	var tracker := _tracker()
	await tracker.begin("ada")

	var rows := tracker.listing("ada")
	var ids := PackedStringArray()
	for row in rows:
		ids.append(str(row.get("id", "")))

	_check(not ids.has("hidden_one"), "a hidden achievement is not listed")
	_check(ids.has("k10"), "an ordinary one is")

	for row in rows:
		if str(row.get("id", "")) == "k10":
			_check(row.has("progress"), "with a bar it can draw")

	tracker.record("ada", &"secret_deed", 1.0)
	var after := tracker.listing("ada")
	var found := false
	for row in after:
		if str(row.get("id", "")) == "hidden_one":
			found = true
			_check(bool(row.get("unlocked", false)), "and appears once it is earned")
	_check(found, "a hidden achievement is listed after it is earned")

	tracker.queue_free()


# --- The dot-stats bridge --------------------------------------------------

func _test_stats_link() -> void:
	_section("the dot-stats bridge")

	var tracker := _tracker()
	await tracker.begin("ada")

	var stats := FakeStats.new()
	add_child(stats)

	var link := DotAchievementStatsLink.new()
	link.tracker = tracker
	link.stats = stats
	add_child(link)

	_check(link.describe()["connected"], "the link connects")

	# dot-stats emits the SESSION total, not the reading. Wiring the signal straight
	# into record() would add 1, then 2, then 3 — nine after four kills.
	for i in 4:
		stats.record(&"ada", &"kills", 1.0)

	var progress := tracker.progress_of("ada")
	_check(
		is_equal_approx(progress.value_of(&"kills"), 4.0),
		"four kills is four, not nine: a session total is differenced, not added"
	)

	stats.new_session(&"ada")
	stats.record(&"ada", &"kills", 1.0)
	_check(
		is_equal_approx(progress.value_of(&"kills"), 5.0),
		"a session total that goes down is a new session, not a negative delta"
	)

	# A best time is an absolute in both systems. Differencing one would be
	# meaningless, so it is passed through.
	stats.record(&"ada", &"best_time", 12.0)
	_check(
		is_equal_approx(progress.value_of(&"best_time"), 12.0),
		"a LOWEST stat is passed through rather than differenced"
	)

	var unknown := DotAchievementStatsLink.new()
	unknown.tracker = tracker
	unknown.stats_service = &"nothing_registered"
	_check(not unknown.start().ok, "a link with nothing to listen to refuses to start")

	var wrong := DotAchievementStatsLink.new()
	wrong.tracker = tracker
	wrong.stats = RefCounted.new()
	_check(
		not wrong.start().ok,
		"and so does one pointed at something with no 'recorded' signal"
	)

	link.queue_free()
	stats.queue_free()
	tracker.queue_free()
	unknown.queue_free()
	wrong.queue_free()


func _test_reporter() -> void:
	_section("reporter")

	var backbone := FakeBackbone.new()
	var reporter := DotAchievementReporter.with_client(backbone)

	_check(reporter.is_available(), "a reporter with a client is available")

	# dot-user's whole design is that an operator cannot correlate their players
	# across servers. A report carrying an account uid would undo it from this side.
	var refused := reporter.queue("backbone:12345", &"k10", 1)
	_check(
		not refused.ok and refused.code() == DotError.CODE_INVALID,
		"an account id is refused as a player key before it leaves the process"
	)

	_check(reporter.queue("u_ada", &"k10", 100).ok, "a pseudonymous key is accepted")
	reporter.queue("u_ada", &"k10", 100)
	_check(reporter.pending() == 1, "the same unlock twice is queued once")

	reporter.queue("u_bo", &"k10", 101)
	var flushed: DotResult = await reporter.flush()
	_check(flushed.ok and int(flushed.value) == 2, "a flush sends everything queued")
	_check(reporter.pending() == 0, "and empties the queue")

	var body: Dictionary = backbone.calls[0]["body"]
	var unlocks: Array = body["unlocks"]
	var row: Dictionary = unlocks[0]
	_check(
		row.has("player") and row.has("key") and row.has("unlockedAt"),
		"in the backbone's field names, not this addon's file format"
	)

	backbone.fail = true
	backbone.retryable = true
	reporter.queue("u_cy", &"k10", 102)
	var failed: DotResult = await reporter.flush()
	_check(not failed.ok, "a failed flush is a failure")
	_check(
		reporter.pending() == 1,
		"and a retryable one puts the unlocks back: they are still true"
	)

	backbone.retryable = false
	await reporter.flush()
	_check(
		reporter.pending() == 0,
		"a refusal drops them instead, rather than resending them for ever"
	)

	var homeless := DotAchievementReporter.new()
	_check(not homeless.is_available(), "a reporter with no client is not available")
	var nowhere: DotResult = await homeless.flush()
	_check(nowhere.ok, "and flushing an empty queue is not a failure")


func _calls_to(backbone: FakeBackbone, path: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for call in backbone.calls:
		if str(call.get("path", "")) == path:
			out.append(call)
	return out


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## The tracker drives the reporter. Nothing did until it did: with report_to_backbone on,
## every unlock was queued, nothing ever called define() or flush(), and the queue limit
## dropped them. So this goes through the tracker's own timer, to a fake backbone, and
## never calls the reporter by hand.
func _test_tracker_reports() -> void:
	_section("the tracker reports unlocks")

	var backbone := FakeBackbone.new()
	var tracker := _tracker()
	tracker.report_to_backbone = true
	tracker.report_interval = 0.05
	tracker.report_app = "selftest"
	tracker.reporter = DotAchievementReporter.with_client(backbone)

	await tracker.begin("u_ada")
	# Ten kills earn two: k10, and flawless (five kills, no deaths).
	tracker.record("u_ada", &"kills", 10.0)
	_check(tracker.reporter.pending() == 2, "the unlocks are queued")

	await _wait(0.3)

	var defines := _calls_to(backbone, DotAchievementReporter.DEFINE_PATH)
	var unlocks := _calls_to(backbone, DotAchievementReporter.UNLOCK_PATH)
	_check(
		defines.size() == 1
		and (defines[0]["body"]["achievements"] as Array).size() == tracker.catalogue.size()
		and str(defines[0]["body"].get("app", "")) == "selftest",
		"the catalogue is declared, whole, with the app id"
	)
	var keys: Array[String] = []
	if unlocks.size() == 1:
		for row in unlocks[0]["body"]["unlocks"]:
			if str(row.get("player", "")) == "u_ada":
				keys.append(str(row.get("key", "")))
	keys.sort()
	_check(
		keys.size() == 2 and keys[0] == "flawless" and keys[1] == "k10",
		"and the unlocks reach the backbone on the tracker's own timer, in one batch"
	)
	_check(
		tracker.reporter.pending() == 0 and tracker.reporter.sent == 2,
		"leaving nothing queued"
	)

	tracker.record("u_ada", &"kills", 90.0)
	await _wait(0.3)
	_check(
		_calls_to(backbone, DotAchievementReporter.DEFINE_PATH).size() == 1,
		"the catalogue is declared once, not on every send"
	)
	_check(
		_calls_to(backbone, DotAchievementReporter.UNLOCK_PATH).size() == 2
		and tracker.reporter.sent == 3,
		"a later unlock goes out on a later tick"
	)
	tracker.queue_free()

	# A backbone that is down: the declaration is retried later, and the unlock is kept.
	var down := FakeBackbone.new()
	down.fail = true
	down.retryable = true
	var patient := _tracker()
	patient.report_to_backbone = true
	patient.report_interval = 0.05
	patient.reporter = DotAchievementReporter.with_client(down)

	await patient.begin("u_bo")
	patient.unlock("u_bo", &"opening_day")
	await _wait(0.12)
	_check(
		patient.reporter.pending() == 1 and patient.reporter.sent == 0,
		"while the backbone is down the unlock stays queued"
	)

	down.fail = false
	await _wait(0.5)
	_check(
		_calls_to(down, DotAchievementReporter.DEFINE_PATH).size() >= 2,
		"the declaration is retried once it is back"
	)
	_check(
		patient.reporter.pending() == 0 and patient.reporter.sent == 1,
		"and the kept unlock is delivered"
	)
	patient.queue_free()

	# Off means off: nothing is queued and nothing is sent.
	var quiet_backbone := FakeBackbone.new()
	var quiet := _tracker()
	quiet.reporter = DotAchievementReporter.with_client(quiet_backbone)
	quiet.report_interval = 0.05
	await quiet.begin("u_cy")
	quiet.record("u_cy", &"kills", 10.0)
	await _wait(0.15)
	_check(
		quiet_backbone.calls.is_empty() and quiet.reporter.pending() == 0,
		"with report_to_backbone off, nothing is queued or sent"
	)

	# A host can send on demand, e.g. before a shutdown.
	quiet.report_to_backbone = true
	quiet.report_interval = 600.0
	quiet.record("u_cy", &"kills", 90.0)
	var sent: DotResult = await quiet.report()
	_check(
		sent.ok and int(sent.value) == 1 and quiet.reporter.sent == 1,
		"report() sends what is queued without waiting for the timer"
	)
	quiet.queue_free()


func _test_saving() -> void:
	_section("saving")

	var flaky := FlakyStore.new()

	var tracker := _tracker()
	tracker.store = flaky
	tracker.autosave_interval = 0.0
	tracker.save_on_unlock = false

	await tracker.begin("ada")
	tracker.record("ada", &"kills", 3.0)
	_check(tracker.progress_of("ada").dirty, "a reading marks the player dirty")

	var saved: DotResult = await tracker.flush()
	_check(saved.ok and int(saved.value) == 1, "a flush saves the dirty player")
	_check(not tracker.progress_of("ada").dirty, "and marks them clean")

	var again: DotResult = await tracker.flush()
	_check(
		int(again.value) == 0,
		"a second flush writes nothing: a server full of idle players is not "
		+ "rewriting their files every interval"
	)

	tracker.record("ada", &"kills", 1.0)
	flaky.fail_saves = true

	var save_failures: Array[String] = []
	tracker.save_failed.connect(func(player: String, _e: DotError) -> void:
		save_failures.append(player))

	await tracker.flush()
	_check(save_failures.size() == 1, "a failed save is announced")
	_check(
		tracker.progress_of("ada").dirty,
		"and leaves the player dirty, so a store that was briefly down does not "
		+ "quietly discard their progress"
	)

	flaky.fail_saves = false
	await tracker.end("ada")
	_check(not tracker.has("ada"), "ending a player forgets them")

	var reloaded: DotResult = await flaky.load_progress("ada")
	_check(
		is_equal_approx((reloaded.value as DotAchievementProgress).value_of(&"kills"), 4.0),
		"and what was saved is what they had"
	)

	tracker.queue_free()


# --- Fixtures --------------------------------------------------------------

func _catalogue() -> DotAchievementCatalogue:
	var k10 := DotAchievement.counter(&"k10", "First Blood", &"kills", 10.0)
	k10.series = &"kills"
	k10.tier = 1
	k10.points = 10

	var k100 := DotAchievement.counter(&"k100", "Centurion", &"kills", 100.0)
	k100.series = &"kills"
	k100.tier = 2
	k100.points = 25

	var flawless := DotAchievement.make(&"flawless", "Flawless", [
		DotAchievementRule.make(&"kills", 5.0),
		DotAchievementRule.make(&"deaths", 0.0, DotAchievementRule.Op.AT_MOST),
	] as Array[DotAchievementRule])

	var fast := DotAchievement.make(&"fast", "Quick", [
		DotAchievementRule.make(
			&"best_time", 10.0, DotAchievementRule.Op.AT_MOST,
			DotAchievementRule.Merge.LOWEST
		),
	] as Array[DotAchievementRule])

	var hidden := DotAchievement.counter(&"hidden_one", "Curious", &"secret_deed", 1.0)
	hidden.hidden = true

	var manual := DotAchievement.counter(&"opening_day", "Day One", &"attended", 1.0)

	return DotAchievementCatalogue.of([
		k10, k100, flawless, fast, hidden, manual
	] as Array[DotAchievement])


func _tracker() -> DotAchievementTracker:
	var tracker := DotAchievementTracker.new()
	tracker.register_as = &""
	tracker.catalogue = _catalogue()
	tracker.store = DotAchievementStoreMemory.new()
	tracker.autosave_interval = 0.0
	add_child(tracker)
	return tracker


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
