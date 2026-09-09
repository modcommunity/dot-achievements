class_name DotAchievementProgress
extends RefCounted

## One player's numbers and what they have earned.
##
## [b]Lifetime, not session.[/b] That distinction is the whole reason this holds its
## own values rather than reading dot-stats': an achievement for a thousand kills is
## about a thousand kills ever, and a session tracker knows about the last forty
## minutes. A tracker fed by session totals without a baseline awards nothing to a
## player who has been playing for a year.

## stat -> held value.
var values: Dictionary = {}

## achievement id -> unix seconds it was earned.
var unlocked: Dictionary = {}

## Set when anything changed and cleared by a save. What an autosave checks, so a
## server full of idle players is not rewriting their files every thirty seconds.
var dirty: bool = false

## Points earned, cached so a HUD can draw it without walking the catalogue.
var points: int = 0


func is_unlocked(id: StringName) -> bool:
	return unlocked.has(id)


func unlocked_at(id: StringName) -> int:
	return int(unlocked.get(id, 0))


func value_of(stat: StringName) -> float:
	return float(values.get(stat, 0.0))


func has_value(stat: StringName) -> bool:
	return values.has(stat)


func set_value(stat: StringName, value: float) -> void:
	values[stat] = value
	dirty = true


func mark_unlocked(id: StringName, at: int, worth: int) -> bool:
	if unlocked.has(id):
		return false
	unlocked[id] = at
	points += worth
	dirty = true
	return true


## Removes an unlock. For a moderator, or for a game that resets a season.
func revoke(id: StringName, worth: int) -> bool:
	if not unlocked.has(id):
		return false
	unlocked.erase(id)
	points = maxi(0, points - worth)
	dirty = true
	return true


func unlocked_count() -> int:
	return unlocked.size()


func to_dictionary() -> Dictionary:
	# Copies, not the live dictionaries. A Dictionary is a reference in GDScript, and
	# handing out the live one is how DotLeaderboardDef ended up with every scoped
	# board and the template it came from being one object.
	return {
		"version": 1,
		"values": values.duplicate(true),
		"unlocked": unlocked.duplicate(true),
		"points": points,
	}


static func from_dictionary(data: Dictionary) -> DotResult:
	var out := DotAchievementProgress.new()

	var values_raw: Variant = data.get("values")
	if typeof(values_raw) == TYPE_DICTIONARY:
		for key in (values_raw as Dictionary).keys():
			out.values[StringName(str(key))] = float((values_raw as Dictionary)[key])

	var unlocked_raw: Variant = data.get("unlocked")
	if typeof(unlocked_raw) == TYPE_DICTIONARY:
		for key in (unlocked_raw as Dictionary).keys():
			out.unlocked[StringName(str(key))] = int((unlocked_raw as Dictionary)[key])

	out.points = int(data.get("points", 0))
	out.dirty = false

	return DotResult.success(out)


## Recomputes [member points] from a catalogue.
##
## The cached total is a cache, and a catalogue whose point values changed since a
## file was written makes it wrong. Called after a load rather than trusted.
func recount(catalogue: DotAchievementCatalogue) -> int:
	var total := 0

	for id in unlocked.keys():
		var achievement := catalogue.find(id as StringName)
		if achievement != null:
			total += achievement.points

	points = total
	return total


func describe() -> String:
	return "%d unlocked, %d points, %d stats held" % [
		unlocked.size(), points, values.size()
	]
