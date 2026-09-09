@tool
class_name DotAchievement
extends Resource

## One thing a player can earn, as a document that can be checked without loading
## anything.
##
## The same doctrine dot-loadout and dot-user-avatar are built on, for the same
## reason: an achievement is a set of ids and numbers, so a server can validate a
## whole catalogue, decide whether somebody has earned something, and report it,
## **without ever loading a mesh, an icon or a scene**. [member icon_id] is an id a
## game resolves however it likes — through dot-cloud, out of its own build, or not
## at all on a dedicated server, which has no business loading art.

@export_group("Identity")

## Stable id. Goes on the wire, into the store and to the backbone, and must not
## change once anybody has earned it.
@export var id: StringName = &""

@export var display_name: String = ""

@export_multiline var description: String = ""

## For grouping in a list. Free-form.
@export var category: StringName = &""

## An id the game resolves to art. dot-achievements never loads it.
@export var icon_id: StringName = &""

@export_group("Value")

## What this is worth, for a total a game can show or a site can rank on.
@export_range(0, 1000, 1) var points: int = 10

## Not listed until it is earned.
##
## [b]Hidden is about the list, not about the check.[/b] A hidden achievement is
## evaluated exactly like every other one; a game that also wants its *description*
## kept back reads [member secret].
@export var hidden: bool = false

## Show the name but not the description until it is earned.
@export var secret: bool = false

@export_group("Requirements")

## Every rule, or any of them, depending on [member require_all].
@export var requirements: Array[DotAchievementRule] = []

## All of the rules must hold. Off means any one of them does.
@export var require_all: bool = true

@export_group("Tiers")

## Achievements in one progression — bronze, silver, gold — share a series.
##
## Nothing here enforces that earning gold implies silver. A game that wants that
## states both as rules, because the alternative is an achievement whose condition is
## another achievement, and a store that has one and not the other is then a store
## that disagrees with itself.
@export var series: StringName = &""

## Position in the series, ascending. 0 for an achievement outside one.
@export_range(0, 16, 1) var tier: int = 0


static func make(
	p_id: StringName, p_name: String, p_rules: Array[DotAchievementRule]
) -> DotAchievement:
	var out := DotAchievement.new()
	out.id = p_id
	out.display_name = p_name
	out.requirements = p_rules
	return out


## The single-rule form, which is most of them.
static func counter(
	p_id: StringName, p_name: String, stat: StringName, threshold: float
) -> DotAchievement:
	var rules: Array[DotAchievementRule] = [
		DotAchievementRule.make(stat, threshold)
	]
	return make(p_id, p_name, rules)


## Which stats this reads. A catalogue indexes on this.
func watched_stats() -> Array[StringName]:
	var out: Array[StringName] = []
	for rule in requirements:
		if rule != null and not out.has(rule.stat):
			out.append(rule.stat)
	return out


## Whether [param values] earns this.
##
## A missing stat reads as zero. That is right for a counter and worth knowing for a
## [constant DotAchievementRule.Op.AT_MOST] rule: "deaths at most 0" is satisfied by a
## player who has never been recorded dying, which is what the rule says and not
## always what its author meant.
func evaluate(values: Dictionary) -> bool:
	if requirements.is_empty():
		return false

	for rule in requirements:
		if rule == null:
			continue

		var held := float(values.get(rule.stat, 0.0))
		var met := rule.satisfied(held)

		if require_all and not met:
			return false
		if not require_all and met:
			return true

	return require_all


## How far along, 0 to 1, for a bar.
##
## With [member require_all] it is the mean of the rules that can report one — a
## player who is 100% of the way through one requirement and 0% through another is
## halfway, which is the honest answer. Without it, it is the best single rule,
## because any one of them finishing is enough.
func progress(values: Dictionary) -> float:
	if requirements.is_empty():
		return 0.0

	var total := 0.0
	var counted := 0
	var best := 0.0

	for rule in requirements:
		if rule == null:
			continue
		var held := float(values.get(rule.stat, 0.0))
		var fraction := rule.progress(held)
		best = maxf(best, fraction)
		total += fraction
		counted += 1

	if counted == 0:
		return 0.0

	return (total / float(counted)) if require_all else best


## Whether a meaningful bar can be drawn at all.
##
## An achievement of pure [constant DotAchievementRule.Op.AT_MOST] rules is earned or
## not, and a bar for it would move from 0 to 1 in one step — which reads to a player
## as a bar that is broken.
func has_progress() -> bool:
	for rule in requirements:
		if rule != null and rule.has_progress():
			return true
	return false


func validate() -> DotResult:
	if String(id).strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "An achievement needs an id.")

	if requirements.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"An achievement with no requirements can never be earned.",
			String(id)
		)

	for rule in requirements:
		if rule == null:
			return DotResult.fail(
				DotError.CODE_INVALID, "An achievement has an empty rule.", String(id)
			)
		var valid := rule.validate()
		if not valid.ok:
			return valid.wrap("Achievement '%s' has a bad rule." % String(id))

	if tier > 0 and String(series).strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"An achievement with a tier needs a series to be a tier of.",
			String(id)
		)

	return DotResult.success(self)


## The player-facing form, with [member secret] and [member hidden] applied.
##
## [b]Applied here rather than in a UI.[/b] A description withheld by the interface
## that drew it is a description that was still sent to the client, and a determined
## player reads it out of the packet. If it is worth hiding it is worth not sending.
func to_player_dictionary(unlocked: bool) -> Dictionary:
	if hidden and not unlocked:
		return {}

	var out := {
		"id": String(id),
		"name": display_name,
		"points": points,
		"category": String(category),
		"unlocked": unlocked,
	}

	if not secret or unlocked:
		out["description"] = description
		out["icon"] = String(icon_id)

	return out


func to_dictionary() -> Dictionary:
	var rules: Array = []
	for rule in requirements:
		if rule != null:
			rules.append(rule.to_dictionary())

	var out := {
		"id": String(id),
		"name": display_name,
		"description": description,
		"points": points,
		"require_all": require_all,
		"rules": rules,
	}

	if category != &"":
		out["category"] = String(category)
	if icon_id != &"":
		out["icon"] = String(icon_id)
	if hidden:
		out["hidden"] = true
	if secret:
		out["secret"] = true
	if series != &"":
		out["series"] = String(series)
		out["tier"] = tier

	return out


static func from_dictionary(data: Dictionary) -> DotResult:
	var out := DotAchievement.new()
	out.id = StringName(str(data.get("id", "")))
	out.display_name = str(data.get("name", ""))
	out.description = str(data.get("description", ""))
	out.category = StringName(str(data.get("category", "")))
	out.icon_id = StringName(str(data.get("icon", "")))
	out.points = int(data.get("points", 10))
	out.hidden = bool(data.get("hidden", false))
	out.secret = bool(data.get("secret", false))
	out.require_all = bool(data.get("require_all", true))
	out.series = StringName(str(data.get("series", "")))
	out.tier = int(data.get("tier", 0))

	var rules: Variant = data.get("rules")
	if typeof(rules) != TYPE_ARRAY:
		return DotResult.fail(
			DotError.CODE_PARSE, "An achievement needs a rules array.", String(out.id)
		)

	for entry in (rules as Array):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var parsed := DotAchievementRule.from_dictionary(entry as Dictionary)
		if not parsed.ok:
			return parsed.wrap("Achievement '%s' has a bad rule." % String(out.id))
		out.requirements.append(parsed.value)

	return out.validate()


func describe() -> String:
	var parts := PackedStringArray()
	for rule in requirements:
		if rule != null:
			parts.append(rule.describe())

	return "%s (%d pts): %s" % [
		String(id), points, (" and " if require_all else " or ").join(Array(parts))
	]


func _to_string() -> String:
	return "DotAchievement(%s)" % String(id)
