@tool
class_name DotAchievementCatalogue
extends Resource

## Everything a game can award, declared once.
##
## Declared once, and the emphasis is on once: an achievement whose condition lives
## in the code that awards it is one nobody can list, show progress towards, or check
## a save file against. A catalogue is a document; the tracker is the only thing that
## acts on it.
##
## [b]The index is the reason this is a class and not an array.[/b] A reading arrives
## and something has to decide which achievements it could possibly have moved.
## Walking every achievement per reading is O(everything) on the hot path of a busy
## server — a hundred players times fifty stats times two hundred achievements, per
## second — so the catalogue builds [code]stat -> achievements[/code] once and the
## tracker evaluates only what the stat touches.

# No log channel: a document. Parsing and validation return a DotResult, and the tracker
# that loads it at start wraps and returns the failure to its host.

@export var achievements: Array[DotAchievement] = []

var _by_id: Dictionary = {}
var _by_stat: Dictionary = {}
var _indexed: bool = false


static func of(entries: Array[DotAchievement]) -> DotAchievementCatalogue:
	var out := DotAchievementCatalogue.new()
	out.achievements = entries
	return out


## Checks every achievement and builds the index.
##
## [b]Call it at boot and branch on it.[/b] A duplicate id is not a cosmetic problem:
## the store is keyed by id, so two achievements sharing one means earning either
## marks both, for ever, in every save file written from then on.
func validate() -> DotResult:
	_by_id.clear()
	_by_stat.clear()

	var series_tiers: Dictionary = {}

	for achievement in achievements:
		if achievement == null:
			return DotResult.fail(
				DotError.CODE_INVALID, "The catalogue has an empty entry."
			)

		var valid := achievement.validate()
		if not valid.ok:
			return valid

		if _by_id.has(achievement.id):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Two achievements share an id.",
				String(achievement.id)
			)

		_by_id[achievement.id] = achievement

		if achievement.series != &"":
			var key := "%s#%d" % [String(achievement.series), achievement.tier]
			if series_tiers.has(key):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"Two achievements share a series and a tier.",
					key
				)
			series_tiers[key] = achievement.id

		for stat in achievement.watched_stats():
			if not _by_stat.has(stat):
				var fresh: Array[DotAchievement] = []
				_by_stat[stat] = fresh
			(_by_stat[stat] as Array).append(achievement)

	# Two rules reading one stat with different merges is a catalogue that disagrees
	# with itself: one number cannot be both a running total and a personal best. It
	# is caught here rather than at the first reading, because the symptom otherwise
	# is one of the two achievements never unlocking, on a server, for one player, and
	# nothing erroring anywhere.
	var merges: Dictionary = {}

	for achievement in achievements:
		for rule in achievement.requirements:
			if rule == null:
				continue
			if merges.has(rule.stat) and int(merges[rule.stat]) != int(rule.merge):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"One stat is read with two different merge rules.",
					"%s: %s and %s" % [
						String(rule.stat),
						DotAchievementRule.MERGE_NAMES[int(merges[rule.stat])],
						rule.merge_name(),
					]
				)
			merges[rule.stat] = int(rule.merge)

	_indexed = true
	return DotResult.success(achievements.size())


func _ensure_indexed() -> void:
	if not _indexed:
		validate()


func find(id: StringName) -> DotAchievement:
	_ensure_indexed()
	if _by_id.has(id):
		return _by_id[id]
	return null


func has(id: StringName) -> bool:
	_ensure_indexed()
	return _by_id.has(id)


func size() -> int:
	return achievements.size()


## The achievements a reading of [param stat] could have moved.
func affected_by(stat: StringName) -> Array[DotAchievement]:
	_ensure_indexed()
	if _by_stat.has(stat):
		return _by_stat[stat]
	var empty: Array[DotAchievement] = []
	return empty


## Every stat this catalogue reads. What a game hands dot-stats to declare.
func watched_stats() -> Array[StringName]:
	_ensure_indexed()

	var out: Array[StringName] = []
	for key in _by_stat.keys():
		out.append(key as StringName)

	# Not Array.sort(): Godot orders StringNames by their interned pointer, which is
	# arbitrary between two processes. dot-net assigned wire ids from such a sort and
	# two peers gave one message type two different ids.
	out.sort_custom(func(a: StringName, b: StringName) -> bool:
		return String(a) < String(b))

	return out


## How a stat should be merged, for a game wiring this to dot-stats.
##
## Returns [code]-1[/code] when nothing reads the stat. A validated catalogue cannot
## disagree with itself about a merge — [method validate] refuses one that does.
func merge_for(stat: StringName) -> int:
	_ensure_indexed()

	var found := -1

	for achievement in affected_by(stat):
		for rule in achievement.requirements:
			if rule == null or rule.stat != stat:
				continue
			if found >= 0 and found != int(rule.merge):
				return -1
			found = int(rule.merge)

	return found


func by_category(category: StringName) -> Array[DotAchievement]:
	var out: Array[DotAchievement] = []
	for achievement in achievements:
		if achievement != null and achievement.category == category:
			out.append(achievement)
	return out


func in_series(series: StringName) -> Array[DotAchievement]:
	var out: Array[DotAchievement] = []
	for achievement in achievements:
		if achievement != null and achievement.series == series:
			out.append(achievement)

	out.sort_custom(func(a: DotAchievement, b: DotAchievement) -> bool:
		return a.tier < b.tier)

	return out


func total_points() -> int:
	var total := 0
	for achievement in achievements:
		if achievement != null:
			total += achievement.points
	return total


func to_dictionary() -> Dictionary:
	var rows: Array = []
	for achievement in achievements:
		if achievement != null:
			rows.append(achievement.to_dictionary())
	return {"version": 1, "achievements": rows}


static func from_dictionary(data: Dictionary) -> DotResult:
	var rows: Variant = data.get("achievements")
	if typeof(rows) != TYPE_ARRAY:
		return DotResult.fail(
			DotError.CODE_PARSE, "A catalogue needs an achievements array."
		)

	var out := DotAchievementCatalogue.new()

	for entry in (rows as Array):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var parsed := DotAchievement.from_dictionary(entry as Dictionary)
		if not parsed.ok:
			return parsed
		out.achievements.append(parsed.value)

	var valid := out.validate()
	if not valid.ok:
		return valid

	return DotResult.success(out)


static func from_json_file(path: String) -> DotResult:
	var read := DotPaths.read_json(path)
	if not read.ok:
		return read.wrap("Could not read the achievement catalogue.")

	var data: Variant = read.value
	if typeof(data) != TYPE_DICTIONARY:
		return DotResult.fail(
			DotError.CODE_PARSE, "An achievement catalogue is an object.", path
		)

	return from_dictionary(data as Dictionary)


func save_json_file(path: String) -> DotResult:
	return DotPaths.write_json(path, to_dictionary())


func describe_lines() -> PackedStringArray:
	_ensure_indexed()

	var out := PackedStringArray()
	out.append("achievements: %d, %d points, %d stats watched" % [
		achievements.size(), total_points(), _by_stat.size()
	])

	for achievement in achievements:
		if achievement != null:
			out.append("  " + achievement.describe())

	return out
