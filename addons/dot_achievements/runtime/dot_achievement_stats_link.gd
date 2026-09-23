class_name DotAchievementStatsLink
extends Node

## Feeds a [DotAchievementTracker] from a dot-stats tracker, without naming one.
##
## [b]This class exists because of one subtlety, and it is the kind that ships.[/b]
## dot-stats' [code]recorded[/code] signal carries the player's [i]session[/i] total,
## not the reading that caused it — its whole design is that a session is what a
## server counts and a delta is what it reports. An achievement is about a lifetime.
## Wiring the signal straight into [method DotAchievementTracker.record] therefore
## adds the running session total to the lifetime total on every single kill: two
## after the second kill, five after the third, nine after the fourth.
##
## So this holds the last session value it saw per player and stat, and files the
## difference. A value that goes [i]down[/i] is a new session — dot-stats begins a
## player at zero — and the whole value is filed rather than a negative one.
##
## [codeblock]
## var link := DotAchievementStatsLink.new()
## link.tracker = achievements
## link.stats = stats_tracker      # anything with a `recorded` signal
## add_child(link)
## [/codeblock]
##
## Only [constant DotAchievementRule.Merge.SUM] stats are differenced. A highest, a
## lowest or a latest is an absolute value in both systems and is passed through
## unchanged — differencing a personal best would be meaningless.

# No log channel: a signal adapter. start() returns a DotResult that every host in the
# family checks, and a reading for a player the tracker does not hold is dropped by
# design -- the tracker has not loaded them, and filing it would be the bug.

@export var register_as: StringName = &""

## The achievement tracker to feed.
var tracker: DotAchievementTracker = null

## Anything with a [code]recorded(player_id, stat_id, value)[/code] signal.
## dot-stats' [code]DotStatsTracker[/code], in practice, which is not named here.
var stats: Object = null

## Registry name to find one under when [member stats] is not set.
var stats_service: StringName = &"dot_stats_tracker"

var _last_session: Dictionary = {}
var _connected: bool = false


func _ready() -> void:
	start()


func start() -> DotResult:
	if _connected:
		return DotResult.success(self)

	if tracker == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The link has no achievement tracker."
		)

	var source := stats
	if source == null:
		source = DotRegistry.get_service(stats_service)

	if source == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"No stats tracker to link to.",
			String(stats_service)
		)

	if not source.has_signal("recorded"):
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"That object has no 'recorded' signal to listen to.",
			source.get_class()
		)

	stats = source
	source.connect("recorded", _on_recorded)
	_connected = true

	if register_as != &"":
		DotRegistry.register(register_as, self)

	return DotResult.success(self)


## Forgets a player's session baseline. Call it when they disconnect, alongside
## [method DotAchievementTracker.end] — otherwise a server that has been up for a
## week holds a row per stat per player who ever connected.
func forget(player: String) -> void:
	for key in _last_session.keys():
		if str(key).begins_with(player + "#"):
			_last_session.erase(key)


func _on_recorded(player_id: StringName, stat_id: StringName, value: float) -> void:
	var player := String(player_id)

	if not tracker.has(player):
		# Not begun here. Silently ignored rather than warned per reading: a game may
		# well count stats for players it does not track achievements for, and a log
		# line per kill is itself the bug.
		return

	var merge := tracker.catalogue.merge_for(stat_id)
	if merge < 0:
		return

	if merge != int(DotAchievementRule.Merge.SUM):
		tracker.record(player, stat_id, value)
		return

	var key := "%s#%s" % [player, String(stat_id)]
	var held := float(_last_session.get(key, 0.0))

	# A session total that went down is a new session, not a negative delta.
	var delta := value - held if value >= held else value

	_last_session[key] = value

	if absf(delta) > 0.0:
		tracker.record(player, stat_id, delta)


func _exit_tree() -> void:
	if _connected and stats != null and is_instance_valid(stats):
		if stats.is_connected("recorded", _on_recorded):
			stats.disconnect("recorded", _on_recorded)

	if register_as != &"":
		DotRegistry.unregister_instance(register_as, self)


func describe() -> Dictionary:
	return {
		"connected": _connected,
		"baselines": _last_session.size(),
	}
