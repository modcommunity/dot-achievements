extends Node

## The SQL store against a real database, through dot-sql's gateway.
##
## The self-test proves which statements the store sends; this proves a database accepts
## them and gives back what was saved, in all three dialects — and that a tracker using it
## keeps a player's lifetime progress across two sessions. Run by dot-sql's runner, which
## starts a gateway per dialect and sets DOT_SQL_URL, DOT_SQL_DIALECT and DOT_SQL_TOKEN_FILE:
##
## [codeblock]
## ../dot-sql/tools/test_live.sh . res://examples/achievements_sql_live.tscn
## [/codeblock]

const CHECKS := 12

const VALUES := "dot_ach_live_values"
const UNLOCKS := "dot_ach_live_unlocks"

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)

	var dialect := DotSqlDialect.from_name(OS.get_environment("DOT_SQL_DIALECT"))
	var made := DotSql.from_config({
		"driver": "gateway",
		"url": OS.get_environment("DOT_SQL_URL"),
		"dialect": DotSqlDialect.name_of(dialect),
		"token": FileAccess.get_file_as_string(OS.get_environment("DOT_SQL_TOKEN_FILE")).strip_edges(),
	}, self)
	if not made.ok or made.value == null:
		print("set DOT_SQL_URL, DOT_SQL_DIALECT and DOT_SQL_TOKEN_FILE; see dot-sql/tools/test_live.sh")
		get_tree().quit(2)
		return

	var driver: DotSqlDriverGateway = made.value
	print("dot-achievements live: %s" % DotSqlDialect.name_of(dialect))

	# Clean tables every run.
	await driver.open()
	await _drop(driver)

	var store := _store(driver)
	var opened: DotResult = await store.open()
	_check("the store creates its tables", opened.ok, opened)

	var fresh: DotResult = await store.load_progress("nobody")
	_check(
		"a player with no rows loads as a fresh player",
		fresh.ok and (fresh.value as DotAchievementProgress).unlocked_count() == 0
			and (fresh.value as DotAchievementProgress).values.is_empty(),
		fresh
	)

	var who := "p'1 🙃"
	var progress := DotAchievementProgress.new()
	progress.set_value(&"kills", 12.0)
	progress.set_value(&"best_time", 61.123)
	progress.mark_unlocked(&"k10", 1700000000, 5)
	var saved: DotResult = await store.save_progress(who, progress)
	_check("a progress is saved", saved.ok, saved)

	var read := await _load(store, who)
	_check(
		"and reads back: numbers, thousandths, an unlock and its time, under a key with a quote and an emoji",
		read != null and read.value_of(&"kills") == 12.0 and read.value_of(&"best_time") == 61.123
			and read.unlocked_at(&"k10") == 1700000000
	)

	# A second save moves a number and tries to move an unlock's time; the first is an
	# upsert and the second must not be.
	progress.set_value(&"kills", 15.0)
	progress.unlocked[&"k10"] = 1800000000
	progress.mark_unlocked(&"fast", 1700000100, 10)
	await store.save_progress(who, progress)
	read = await _load(store, who)
	_check(
		"saving again updates a number, adds an unlock, and never rewrites when one was earned",
		read != null and read.value_of(&"kills") == 15.0 and read.is_unlocked(&"fast")
			and read.unlocked_at(&"k10") == 1700000000
	)

	progress.revoke(&"fast", 10)
	await store.save_progress(who, progress)
	read = await _load(store, who)
	_check("a revocation reaches the table", read != null and not read.is_unlocked(&"fast") and read.is_unlocked(&"k10"))

	var someone := DotAchievementProgress.new()
	someone.set_value(&"kills", 1.0)
	await store.save_progress("p2", someone)
	read = await _load(store, who)
	var other := await _load(store, "p2")
	_check(
		"two players' rows stay their own",
		read != null and other != null and read.value_of(&"kills") == 15.0 and other.value_of(&"kills") == 1.0
			and other.unlocked_count() == 0
	)

	# Two saves of one player in flight at once, against a real database.
	var racing := DotAchievementProgress.new()
	racing.mark_unlocked(&"a", 1, 1)
	store.save_progress("p3", racing)    # not awaited, as save_on_unlock does
	racing.mark_unlocked(&"b", 2, 1)
	await store.save_progress("p3", racing)
	var raced := await _load(store, "p3")
	_check(
		"two saves in flight land in order, so the newest state is what stays",
		raced != null and raced.is_unlocked(&"a") and raced.is_unlocked(&"b")
	)

	# A tracker over the store: lifetime progress across two sessions.
	var tracker := _tracker(store)
	await tracker.begin("p4")
	for i in 3:
		tracker.record("p4", &"kills", 1.0)
	_check("a tracker over the store earns an achievement", tracker.is_unlocked("p4", &"k3"))
	var ended: DotResult = await tracker.end("p4")
	tracker.queue_free()

	var again := _tracker(store)
	var began: DotResult = await again.begin("p4")
	_check(
		"and a new session loads it back, earned",
		ended.ok and began.ok and again.is_unlocked("p4", &"k3"),
		began
	)
	again.record("p4", &"kills", 2.0)
	_check(
		"with its lifetime count to add to",
		is_equal_approx(again.progress_of("p4").value_of(&"kills"), 5.0)
	)
	again.queue_free()

	var reopen: DotResult = await _store(driver).open()
	_check("opening existing tables again is harmless", reopen.ok, reopen)

	print("%d passed, %d failed" % [_passed, _failed])
	await _drop(driver)
	get_tree().quit(1 if _failed > 0 or _passed + _failed != CHECKS else 0)


func _store(driver) -> DotAchievementStoreSql:
	var store := DotAchievementStoreSql.new(driver)
	store.values_table = VALUES
	store.unlocks_table = UNLOCKS
	return store


func _tracker(store: DotAchievementStore) -> DotAchievementTracker:
	var tracker := DotAchievementTracker.new()
	tracker.register_as = &""
	tracker.catalogue = DotAchievementCatalogue.of([
		DotAchievement.counter(&"k3", "Three", &"kills", 3.0),
	] as Array[DotAchievement])
	tracker.store = store
	tracker.autosave_interval = 0.0
	tracker.save_on_unlock = false
	add_child(tracker)
	return tracker


func _load(store: DotAchievementStoreSql, player: String) -> DotAchievementProgress:
	var got: DotResult = await store.load_progress(player)
	return got.value if got.ok else null


func _drop(driver) -> void:
	await driver.execute("DROP TABLE IF EXISTS %s" % VALUES)
	await driver.execute("DROP TABLE IF EXISTS %s" % UNLOCKS)
	await driver.execute("DELETE FROM dot_sql_migrations WHERE component = ?", ["dot_achievements:%s" % VALUES])


func _check(what: String, passed: bool, res: DotResult = null) -> void:
	if passed:
		_passed += 1
		print("  %-60s ok" % what)
		return
	_failed += 1
	var why := ""
	if res != null and not res.ok and res.error != null:
		why = " — %s (%s)" % [res.error.message, res.error.detail]
	print("  %-60s FAILED%s" % [what, why])
