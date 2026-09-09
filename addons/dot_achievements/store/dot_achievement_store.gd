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


func load_progress(player: String) -> DotResult:
	var res: DotResult = await _load_progress(player)
	return res


func save_progress(player: String, progress: DotAchievementProgress) -> DotResult:
	var res: DotResult = await _save_progress(player, progress)
	return res


## Whether this store can be used at all. Overridden by stores with a connection.
func is_available() -> bool:
	return true
