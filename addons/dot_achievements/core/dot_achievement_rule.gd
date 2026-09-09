@tool
class_name DotAchievementRule
extends Resource

## One condition over one number: "kills at least 1000", "deaths at most 0".
##
## An achievement is a set of these. Splitting the condition out is what lets an
## achievement be checked without loading anything — no scene, no icon, no game — and
## what lets a catalogue say, before a single reading arrives, which numbers it needs
## to be told about.
##
## [b][member merge] is the whole contract, and it is deliberately the same four
## answers dot-stats gives.[/b] The one thing every party touching a number has to
## agree on is what happens when a new reading meets an old one, and if this addon
## answered it differently from the addon that produces the numbers, a lifetime
## counter would be silently replaced by a session one. The duplication is on
## purpose, exactly as [code]DotStatsDef.merge[/code] and the backbone's
## [code]PlayerStatMerge[/code] are the same function written twice — and, as there,
## both are tested directly rather than assumed.

## What "satisfied" means.
enum Op {
	AT_LEAST,     ## value >= threshold. Almost everything.
	AT_MOST,      ## value <= threshold. "finish without dying".
	EQUALS,       ## value == threshold, within an epsilon.
	NOT_EQUALS,
}

## How a new reading meets the held one.
enum Merge {
	SUM,      ## Adds. Kills, metres, seconds. A lifetime counter.
	LATEST,   ## Replaces. A level, a rank, a rating.
	HIGHEST,  ## Keeps the larger. A top speed, a longest streak.
	LOWEST,   ## Keeps the smaller. A best time.
}

## Floats are compared with a tolerance, because a value that has been summed a
## thousand times is not bit-identical to the same value summed a thousand times in
## another order — and an achievement that will not unlock on exactly 100.0 after the
## hundredth kill is a bug report nobody can reproduce.
const EPSILON := 0.0001

const MERGE_NAMES: Array[String] = ["sum", "latest", "highest", "lowest"]
const OP_NAMES: Array[String] = ["at_least", "at_most", "equals", "not_equals"]

@export var stat: StringName = &""

@export var op: Op = Op.AT_LEAST

@export var value: float = 1.0

@export var merge: Merge = Merge.SUM


static func make(
	p_stat: StringName,
	p_value: float,
	p_op: Op = Op.AT_LEAST,
	p_merge: Merge = Merge.SUM
) -> DotAchievementRule:
	var out := DotAchievementRule.new()
	out.stat = p_stat
	out.value = p_value
	out.op = p_op
	out.merge = p_merge
	return out


## Applies a reading to the held value under [member merge].
##
## [param has_current] distinguishes "held zero" from "never seen", which matters for
## every kind but [constant Merge.SUM]: a first reading of 12 seconds on a
## [constant Merge.LOWEST] best time must be 12, not min(12, 0.0) — the bug that
## makes every player's best time zero the moment the feature ships.
func merge_value(current: float, incoming: float, has_current: bool = true) -> float:
	if not has_current:
		return incoming

	match merge:
		Merge.SUM:
			return current + incoming
		Merge.HIGHEST:
			return maxf(current, incoming)
		Merge.LOWEST:
			return minf(current, incoming)

	return incoming


func satisfied(held: float) -> bool:
	match op:
		Op.AT_LEAST:
			return held >= value - EPSILON
		Op.AT_MOST:
			return held <= value + EPSILON
		Op.EQUALS:
			return absf(held - value) <= EPSILON
		Op.NOT_EQUALS:
			return absf(held - value) > EPSILON

	return false


## How far along, 0 to 1.
##
## Only [constant Op.AT_LEAST] has a meaningful fraction: "kills at least 1000" is
## 40% done at 400. "deaths at most 0" is not 90% done at 1 — it is not done, and
## drawing a bar at 90% would be a lie. The others report 0 or 1.
func progress(held: float) -> float:
	if op != Op.AT_LEAST:
		return 1.0 if satisfied(held) else 0.0

	if absf(value) <= EPSILON:
		return 1.0 if satisfied(held) else 0.0

	return clampf(held / value, 0.0, 1.0)


## Whether a fraction can be drawn as a bar for this rule.
func has_progress() -> bool:
	return op == Op.AT_LEAST and absf(value) > EPSILON


func validate() -> DotResult:
	if String(stat).strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "A rule needs a stat to read.")

	if is_nan(value) or is_inf(value):
		return DotResult.fail(
			DotError.CODE_INVALID, "A rule's threshold must be a number.", String(stat)
		)

	return DotResult.success(self)


func merge_name() -> String:
	return MERGE_NAMES[int(merge)]


static func merge_from_name(name: String) -> int:
	return MERGE_NAMES.find(name)


func op_name() -> String:
	return OP_NAMES[int(op)]


static func op_from_name(name: String) -> int:
	return OP_NAMES.find(name)


func to_dictionary() -> Dictionary:
	return {
		"stat": String(stat),
		"op": op_name(),
		"value": value,
		"merge": merge_name(),
	}


static func from_dictionary(data: Dictionary) -> DotResult:
	var op_value := op_from_name(str(data.get("op", "at_least")))
	if op_value < 0:
		return DotResult.fail(
			DotError.CODE_PARSE, "Unknown rule operator.", str(data.get("op", ""))
		)

	var merge_value_ := merge_from_name(str(data.get("merge", "sum")))
	if merge_value_ < 0:
		return DotResult.fail(
			DotError.CODE_PARSE, "Unknown merge rule.", str(data.get("merge", ""))
		)

	var out := DotAchievementRule.new()
	out.stat = StringName(str(data.get("stat", "")))
	out.op = op_value as Op
	out.merge = merge_value_ as Merge
	out.value = float(data.get("value", 0.0))

	return out.validate()


func describe() -> String:
	return "%s %s %s" % [String(stat), op_name().replace("_", " "), value]


func _to_string() -> String:
	return "DotAchievementRule(%s)" % describe()
