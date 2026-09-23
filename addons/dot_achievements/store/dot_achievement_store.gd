class_name DotAchievementStore
extends RefCounted

## Where a player's progress lives. Subclass point.
##
## Two methods, both of which may be coroutines, because the interesting
## implementations are all remote — a shared database behind a community's four
## servers, an HTTP service, the backbone. A store that could only be synchronous
## would be a store that could only be a file.
##
## [codeblock]
## class MyStore extends DotAchievementStore:
##     func _load_progress(player: String) -> DotResult:
##         var res := await db.query("select * from achievements where player = $1", player)
##         if not res.ok:
##             return res
##         return DotAchievementProgress.from_dictionary(res.value)
##
##     func _save_progress(player: String, progress: DotAchievementProgress) -> DotResult:
##         return await db.upsert(player, progress.to_dictionary())
## [/codeblock]
##
## [b]A load that fails is not an empty player.[/b] Returning a fresh
## [DotAchievementProgress] when a database is down hands a returning player a blank
## account and then writes it back over the real one. Return the failure; the tracker
## refuses to file readings for a player it could not load.

const CHANNEL := "achievements"


## Reads one player's progress. Override.
##
## A player with nothing stored is a success carrying a fresh
## [DotAchievementProgress], not a failure — a first-time player is the most ordinary
## case there is.
func _load_progress(_player: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "This store cannot read."
	)


## Writes one player's progress. Override.
func _save_progress(_player: String, _progress: DotAchievementProgress) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "This store cannot write."
	)


## Whether the last save failed, so an outage is reported on its EDGES.
##
## The tracker keeps a failed save dirty and tries again at every autosave, which is
## right, and means a store that is down for ten minutes fails once per dirty player
## per interval. A WARN for each of those buries the first one.
var _saves_failing: bool = false


## Logged here because every store passes through it, and because the tracker only
## emits [code]load_failed[/code] -- which no game in the family is connected to.
##
## ERROR: the tracker refuses to file readings for a player it could not load, so
## nothing that player does this session counts toward an achievement.
func load_progress(player: String) -> DotResult:
	var res: DotResult = await _load_progress(player)

	if not res.ok:
		DotLog.error(CHANNEL, "a player's achievement progress could not be read", {
			"store": _store_name(),
			"player": player.substr(0, 16),
			"code": res.code(),
			"error": res.error.message if res.error != null else "",
		})

	return res


## WARN on the first failure, DEBUG while it lasts, INFO when a save lands again:
## nothing is lost yet -- the progress stays dirty and is retried -- but a store that
## never comes back loses it all at shutdown, and somebody should look.
func save_progress(player: String, progress: DotAchievementProgress) -> DotResult:
	var res: DotResult = await _save_progress(player, progress)

	if not res.ok:
		var fields := {
			"store": _store_name(),
			"player": player.substr(0, 16),
			"code": res.code(),
			"error": res.error.message if res.error != null else "",
		}

		if _saves_failing:
			DotLog.debug(CHANNEL, "achievement progress still not saving", fields)
		else:
			DotLog.warn(CHANNEL, "achievement progress is not saving; it will be retried", fields)

		_saves_failing = true
	elif _saves_failing:
		_saves_failing = false
		DotLog.info(CHANNEL, "achievement progress is saving again", {"store": _store_name()})

	return res


func _store_name() -> String:
	var script: Script = get_script()
	var named := script.get_global_name() if script != null else &""
	return String(named) if named != &"" else "DotAchievementStore"


## Whether this store can be used at all. Overridden by stores with a connection.
func is_available() -> bool:
	return true
