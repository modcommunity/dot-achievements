extends Node

## The SQL section and the check harness of achievements_selftest.gd, split out to keep
## that file under the size budget. The suite extends this.

var _passed := 0
var _failed := 0
var _section_count := 0


## A recording driver whose every statement waits a frame, the way one behind a network
## does — which is what lets two saves of one player be in flight at once.
class SlowDriver extends DotSqlDriverRecording:
	func _init(p_dialect: int = DotSqlDialect.Kind.SQLITE) -> void:
		super(p_dialect)

	func _execute(sql: String, params: Array) -> DotResult:
		await Engine.get_main_loop().process_frame
		return await super(sql, params)


## The SQL store against a driver that records what it is asked.
##
## Which statements, in what order, with which values bound where, and how rows map back.
## examples/achievements_sql_live.tscn runs the same store against real SQLite, Postgres and
## MariaDB through dot-sql's gateway, which is what says the SQL is valid.
func _test_sql_store() -> void:
	_section("the SQL store, against a driver that records what it is asked")

	_check(
		DotSqlSchema.validate(DotAchievementSqlSchema.values_spec()).ok
			and DotSqlSchema.validate(DotAchievementSqlSchema.unlocks_spec()).ok,
		"both table specs are valid: safe names, no reserved words, indexable key columns"
	)

	var driver := DotSqlDriverRecording.new(DotSqlDialect.Kind.POSTGRES)
	driver.answers = {"SELECT version FROM": []}
	var store := DotAchievementStoreSql.new(driver)

	var closed: DotResult = await store.load_progress("ada")
	_check(
		not closed.ok and closed.code() == DotError.CODE_STATE,
		"a store that was never opened fails the load rather than handing back a blank player"
	)

	var opened: DotResult = await store.open()
	_check(opened.ok, "the store opens and creates its schema")
	_check(
		driver.matching("CREATE TABLE IF NOT EXISTS dot_achievement_values").size() == 1
			and driver.matching("CREATE TABLE IF NOT EXISTS dot_achievement_unlocks").size() == 1,
		"both tables are created"
	)
	_check(
		driver.matching("CREATE INDEX IF NOT EXISTS dot_achievement_unlocks_earned_idx").size() == 1,
		"with the index that answers 'how many have earned this'"
	)
	var recorded := driver.matching("INSERT INTO dot_sql_migrations")
	_check(
		recorded.size() == 1
			and (recorded[0]["params"] as Array)[0] == "dot_achievements:dot_achievement_values",
		"and its schema version recorded under its own component"
	)

	# Loading: two reads, both bound, through the file store's own parser.
	driver.clear()
	driver.answers = {
		"SELECT stat, amount": [{"stat": "kills", "amount": 12.0}, {"stat": "best_time", "amount": "9.5"}, {"stat": "junk", "amount": "banana"}],
		"SELECT achievement, unlocked_at": [{"achievement": "k10", "unlocked_at": 1700000000.0}],
	}
	var loaded: DotResult = await store.load_progress("ada's key")
	var progress: DotAchievementProgress = loaded.value if loaded.ok else null
	_check(
		driver.statements.size() == 2
			and (driver.statements[0]["params"] as Array) == ["ada's key"]
			and (driver.statements[1]["params"] as Array) == ["ada's key"]
			and not str(driver.statements[0]["sql"]).contains("ada"),
		"a load is two reads with the player bound, never interpolated"
	)
	_check(
		progress != null and progress.value_of(&"kills") == 12.0 and progress.value_of(&"best_time") == 9.5,
		"held numbers map back, from a float or from text"
	)
	_check(
		progress != null and not progress.has_value(&"junk"),
		"and one that is not a number is skipped rather than read as a zero"
	)
	_check(
		progress != null and progress.is_unlocked(&"k10") and progress.unlocked_at(&"k10") == 1700000000
			and typeof(progress.unlocked[&"k10"]) == TYPE_INT,
		"an unlock maps back with its time as an int"
	)
	_check(progress != null and not progress.dirty, "and a loaded progress is not dirty")

	await _test_sql_save()
	await _test_sql_failures()


## Saving: upserts, then insert-if-absent unlocks, then the deletes.
func _test_sql_save() -> void:
	var driver := DotSqlDriverRecording.new(DotSqlDialect.Kind.POSTGRES)
	driver.answers = {"SELECT version FROM": []}
	var store := DotAchievementStoreSql.new(driver)
	await store.open()
	driver.clear()
	driver.answers = {}
	driver.rows = []
	var fresh: DotResult = await store.load_progress("nobody")
	_check(
		fresh.ok and (fresh.value as DotAchievementProgress).unlocked_count() == 0,
		"a player with no rows is a fresh player, not a failure"
	)

	var saving := _sample_progress()
	driver.clear()
	var saved: DotResult = await store.save_progress("ada", saving)
	var sqls: Array = driver.statements.map(func(s): return str(s["sql"]))
	_check(saved.ok and sqls.size() == 5, "a save is one value, two unlocks and two deletes (%d)" % sqls.size())
	if sqls.size() == 5:
		_check(
			sqls[0].contains("INSERT INTO dot_achievement_values") and sqls[0].contains("DO UPDATE SET"),
			"a held number is upserted"
		)
		_check(
			(driver.statements[0]["params"] as Array).slice(0, 3) == ["ada", "kills", 40.0],
			"bound as player, stat, amount"
		)
		_check(
			sqls[1].contains("INSERT INTO dot_achievement_unlocks") and sqls[1].contains("DO NOTHING"),
			"an unlock is inserted if absent, so the time it was earned is never rewritten"
		)
		_check(
			sqls[3].begins_with("DELETE FROM dot_achievement_unlocks WHERE player = ? AND achievement NOT IN (?, ?)")
				and (driver.statements[3]["params"] as Array) == ["ada", "k10", "fast"],
			"then what the progress no longer holds is deleted, the kept ids bound"
		)
		_check(
			sqls[4].begins_with("DELETE FROM dot_achievement_values")
				and not (driver.statements[4]["params"] as Array).has("bad"),
			"deletes last, and a non-finite number is left out rather than costing the save"
		)
	else:
		for _i in range(5):
			_check(false, "the save statements were not recorded")

	var revoked := DotAchievementProgress.new()
	driver.clear()
	await store.save_progress("ada", revoked)
	_check(
		driver.matching("DELETE FROM dot_achievement_unlocks WHERE player = ?").size() == 1
			and not str(driver.matching("DELETE FROM dot_achievement_unlocks")[0]["sql"]).contains("NOT IN"),
		"a progress with nothing unlocked deletes every unlock: a revocation reaches the table"
	)

	var mysql := DotSqlDriverRecording.new(DotSqlDialect.Kind.MYSQL)
	mysql.answers = {"SELECT version FROM": []}
	var mysql_store := DotAchievementStoreSql.new(mysql)
	await mysql_store.open()
	mysql.clear()
	await mysql_store.save_progress("ada", saving)
	var mysql_unlock := mysql.matching("INSERT INTO dot_achievement_unlocks")
	_check(
		mysql_unlock.size() == 2 and str(mysql_unlock[0]["sql"]).contains("ON DUPLICATE KEY UPDATE player = player"),
		"on MySQL the insert-if-absent is a no-op update, not INSERT IGNORE"
	)


## Failures are failures, and saves of one player never interleave.
func _test_sql_failures() -> void:
	var driver := DotSqlDriverRecording.new(DotSqlDialect.Kind.POSTGRES)
	driver.answers = {"SELECT version FROM": []}
	var store := DotAchievementStoreSql.new(driver)
	await store.open()
	var saving := _sample_progress()
	driver.clear()
	driver.fail_next = "connection reset"
	var failed_load: DotResult = await store.load_progress("ada")
	_check(not failed_load.ok, "a read failure fails the load: a blank player would be saved over the real one")

	driver.fail_next = "disk full"
	var failed_save: DotResult = await store.save_progress("ada", saving)
	_check(not failed_save.ok, "a write failure fails the save, so the tracker keeps the progress dirty")

	var newer := DotSqlDriverRecording.new(DotSqlDialect.Kind.SQLITE)
	newer.answers = {"SELECT version FROM": [{"version": 99}]}
	var refused: DotResult = await DotAchievementStoreSql.new(newer).open()
	_check(
		not refused.ok and newer.matching("CREATE TABLE IF NOT EXISTS dot_achievement_values").is_empty(),
		"a database from a newer build is refused, and nothing is created in it"
	)

	# Two saves of one player in flight at once — an unlock's save, not awaited, and the
	# autosave. Without serialising them the older snapshot can land second and delete the
	# unlock the newer one just wrote.
	var slow := SlowDriver.new(DotSqlDialect.Kind.SQLITE)
	slow.answers = {"SELECT version FROM": []}
	var slow_store := DotAchievementStoreSql.new(slow)
	await slow_store.open()
	slow.clear()
	var racing := DotAchievementProgress.new()
	racing.mark_unlocked(&"k10", 1, 5)
	slow_store.save_progress("ada", racing)    # not awaited, as save_on_unlock does
	racing.mark_unlocked(&"fast", 2, 10)
	await slow_store.save_progress("ada", racing)
	var order: Array = slow.statements.map(func(st): return str(st["sql"]).left(34))
	var serial := [
		"INSERT INTO dot_achievement_unlock", "DELETE FROM dot_achievement_unlock", "DELETE FROM dot_achievement_values",
		"INSERT INTO dot_achievement_unlock", "INSERT INTO dot_achievement_unlock", "DELETE FROM dot_achievement_unlock", "DELETE FROM dot_achievement_values",
	]
	_check(
		order == serial,
		"two saves of one player run one after the other, with nothing interleaved"
	)
	var last_delete := slow.matching("DELETE FROM dot_achievement_unlocks")
	_check(
		last_delete.size() == 2 and (last_delete[1]["params"] as Array) == ["ada", "k10", "fast"],
		"and the second, which runs last, writes the newest state"
	)


func _sample_progress() -> DotAchievementProgress:
	var saving := DotAchievementProgress.new()
	saving.set_value(&"kills", 40.0)
	saving.set_value(&"bad", NAN)
	saving.mark_unlocked(&"k10", 1700000001, 5)
	saving.mark_unlocked(&"fast", 1700000002, 10)
	return saving


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
