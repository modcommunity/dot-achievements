@tool
class_name DotAchievementSqlSchema
extends RefCounted

## The two achievement tables, their statements and their row mapping, in one place.
##
## [b]Two narrow tables, not one JSON column.[/b] The file store writes a player's progress
## as one document, and a `progress` column holding that document would be the shortest
## SQL store there is — and the one nobody can ask "how many players have earned this",
## "who earned it first" or "what is the most anybody has jumped" without reading every row
## in the table and parsing it. A row per held number and a row per unlock is what a site
## page, a rarity figure and an operator's own query all want, and it costs nothing here.
##
## [b]The tables are plain data, rendered by dot-sql.[/b] [method values_spec] and
## [method unlocks_spec] are [Dictionary] specs a dot-sql driver turns into DDL for its own
## dialect. This file names no dot-sql class, so dot-achievements still parses in a project
## without it. Placeholders are [code]?[/code] in every dialect — dot-sql's contract.

const DEFAULT_VALUES_TABLE := "dot_achievement_values"
const DEFAULT_UNLOCKS_TABLE := "dot_achievement_unlocks"

## The component the schema version is recorded under in dot-sql's migration table,
## suffixed with the values table so two stores in one database keep separate versions.
## Bumped by adding a step to [method migration_steps], never by editing one.
const MIGRATION_COMPONENT := "dot_achievements"

const VALUE_COLUMNS := ["player", "stat", "amount", "updated_at"]
const UNLOCK_COLUMNS := ["player", "achievement", "unlocked_at"]


## One row per player per held stat.
##
## `player` and `stat` are `key` (VARCHAR(191) on MySQL), because both are in the primary
## key and MySQL cannot key on TEXT. A player key is the scoped id the identity layer hands
## a server, which is far shorter than that. Times are Unix seconds in a BIGINT.
static func values_spec(table: String = DEFAULT_VALUES_TABLE) -> Dictionary:
	return {
		"name": table,
		"columns": [
			{"name": "player", "type": "key", "null": false},
			{"name": "stat", "type": "key", "null": false},
			{"name": "amount", "type": "real", "null": false, "default": 0},
			{"name": "updated_at", "type": "bigint", "null": false, "default": 0},
		],
		"primary_key": ["player", "stat"],
	}


## One row per player per earned achievement.
##
## [b]Indexed by achievement as well as keyed by player[/b], for the question every
## achievement page asks: how many have earned this, and who was first. The primary key
## answers "what has this player earned"; the index answers the other direction.
static func unlocks_spec(table: String = DEFAULT_UNLOCKS_TABLE) -> Dictionary:
	return {
		"name": table,
		"columns": [
			{"name": "player", "type": "key", "null": false},
			{"name": "achievement", "type": "key", "null": false},
			{"name": "unlocked_at", "type": "bigint", "null": false, "default": 0},
		],
		"primary_key": ["player", "achievement"],
		"indexes": [
			{"name": "earned_idx", "columns": ["achievement", "unlocked_at"]},
		],
	}


## Every schema change, in order, for dot-sql's migrator. Step N brings version N to N+1.
static func migration_steps(
	values: String = DEFAULT_VALUES_TABLE, unlocks: String = DEFAULT_UNLOCKS_TABLE
) -> Array:
	return [
		[values_spec(values), unlocks_spec(unlocks)],
	]


static func select_values(table: String) -> String:
	return "SELECT stat, amount FROM %s WHERE player = ?" % table


static func select_unlocks(table: String) -> String:
	return "SELECT achievement, unlocked_at FROM %s WHERE player = ?" % table


## Deletes a player's rows in [param table] whose [param column] is not one of [param count]
## kept values — or all of them when [param count] is 0. Revocation, and a reset.
##
## The placeholder list is generated from a count, never from the values: each kept id is
## still a bound parameter.
static func delete_except(table: String, column: String, count: int) -> String:
	if count <= 0:
		return "DELETE FROM %s WHERE player = ?" % table
	var marks := PackedStringArray()
	marks.resize(count)
	marks.fill("?")
	return "DELETE FROM %s WHERE player = ? AND %s NOT IN (%s)" % [table, column, ", ".join(marks)]


## Two row sets back into the dictionary [method DotAchievementProgress.from_dictionary]
## reads, so the SQL store and the file store go through one parser.
##
## Numbers may arrive as floats (the gateway speaks JSON) or as text (some drivers return a
## DOUBLE as a string). A row that cannot be read is skipped rather than read as zero: a
## zero that arrived by accident resets a counter a player spent a year on.
static func progress_dictionary(value_rows: Array, unlock_rows: Array) -> Dictionary:
	var values := {}
	for row in value_rows:
		if not (row is Dictionary):
			continue
		var amount: Variant = _number((row as Dictionary).get("amount"))
		if amount != null:
			values[str((row as Dictionary).get("stat", ""))] = amount

	var unlocked := {}
	for row in unlock_rows:
		if not (row is Dictionary):
			continue
		var at: Variant = _number((row as Dictionary).get("unlocked_at"))
		unlocked[str((row as Dictionary).get("achievement", ""))] = int(at) if at != null else 0

	return {"version": 1, "values": values, "unlocked": unlocked}


static func _number(value: Variant) -> Variant:
	if value is float or value is int:
		return float(value)
	if value is String and (value as String).is_valid_float():
		return (value as String).to_float()
	return null


## A dialect's name, for logs and [code]describe()[/code]. The integers are dot-sql's.
static func dialect_name(dialect: int) -> String:
	match dialect:
		0: return "sqlite"
		1: return "postgres"
		2: return "mysql"
	return "unknown"
