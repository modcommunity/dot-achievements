class_name DotAchievementReporter
extends RefCounted

## Sends unlocks to the TMC backbone, in batches, through a client it never names.
##
## [b]The endpoint this speaks does not exist in website-city yet, and saying so is
## the point of this paragraph.[/b] dot-stats is the family's precedent for the other
## way round — its `stats/*` routes were written alongside the addon — and the lesson
## from every reporter that came before it is the same one: dot-leaderboard's and
## dot-stats' reporters were both found sending their own file formats where the
## backbone's schemas expected something else, and every request either would have
## made would have been refused. Reading the two sides side by side is cheaper than a
## socket.
##
## So the contract is stated here, in full, and a deployment either implements it or
## leaves [member DotAchievementTracker.report_to_backbone] off:
##
## [codeblock]
## POST /api/integration/v1/achievements/define
##   { "app": "<id>", "achievements": [ <DotAchievement.to_dictionary()>, ... ] }
##
## POST /api/integration/v1/achievements/unlock
##   { "unlocks": [ { "player": "<pseudonymous key>",
##                    "key": "<achievement id>",
##                    "unlockedAt": <unix seconds> }, ... ] }
##
## GET  /api/integration/v1/achievements/player?player=<key>
## [/codeblock]
##
## Field names are the backbone's convention — [code]key[/code] and
## [code]unlockedAt[/code], not [code]id[/code] and [code]at[/code] — because that is
## the shape its stats routes already use and the two disagreeing is the exact bug
## named above.
##
## [b]A player key is a pseudonym, never an account id.[/b] Same rule dot-stats
## enforces and for the same reason: dot-user's whole design is that an operator
## cannot correlate their players across servers, and a report that carried an
## account uid would undo it from the reporting side. An id beginning with
## [code]backbone:[/code] is refused before it leaves the process.

const CHANNEL := "achievements"

## The scopes an integration needs, named so a 403 can say which box to tick.
const SCOPE_WRITE := "ACHIEVEMENTS_WRITE"
const SCOPE_READ := "ACHIEVEMENTS_READ"

const DEFINE_PATH := "achievements/define"
const UNLOCK_PATH := "achievements/unlock"
const PLAYER_PATH := "achievements/player"

## Prefix of an account-shaped id this reporter refuses as a player.
const ACCOUNT_PREFIX := "backbone:"

## The backbone client. Any object with
## [code]post_integration(String, Dictionary)[/code] — dot-auth's
## [code]DotBackboneClient[/code] in practice, which is not named here.
var client: Object = null

## Registry name to find one under when [member client] is not set.
var client_service: StringName = &"dot_backbone_client"

## Unlocks per request. Matched to what a batch endpoint should reasonably cap at.
var batch_limit: int = 50

## Unlocks held between flushes. Past this the oldest is dropped.
##
## A queue with no ceiling is a memory leak with a network outage as its trigger — a
## server that cannot reach the backbone for an hour must not hold an hour of them.
var queue_limit: int = 1000

var sent: int = 0
var dropped: int = 0
var failures: int = 0
var last_error: String = ""

var _queue: Array[Dictionary] = []
var _defined: bool = false

# Edge state for the log, so a condition that lasts is said once when it starts and
# once when it ends, rather than on every flush or every unlock while it holds.
var _failing: bool = false
var _warned_overflow: bool = false
var _warned_no_client: bool = false
var _warned_account_key: bool = false


static func with_client(p_client: Object) -> DotAchievementReporter:
	var out := DotAchievementReporter.new()
	out.client = p_client
	return out


func _client() -> Object:
	if client != null and is_instance_valid(client):
		return client

	var found := DotRegistry.get_service(client_service)
	if found != null and found.has_method("post_integration"):
		return found

	return null


func is_available() -> bool:
	return _client() != null


## Whether an id may be filed as a player.
static func is_player_key(candidate: String) -> bool:
	if candidate.strip_edges() == "" or candidate.length() > 64:
		return false
	if candidate.begins_with(ACCOUNT_PREFIX):
		return false
	return true


## Adds one unlock to the queue. Never blocks and never fails a game.
func queue(player: String, id: StringName, at: int) -> DotResult:
	if not is_player_key(player):
		# Once per reporter: the tracker drops this result, and a game passing account
		# ids is a game none of whose unlocks will ever be reported. WARN, because it is
		# an integration mistake somebody has to fix, and it will not fix itself.
		if not _warned_account_key:
			_warned_account_key = true
			DotLog.warn(CHANNEL, "refusing a player key that is not a pseudonym; unlocks for such keys are not reported", {
				"key": player.substr(0, 16),
			})
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A player key must be a pseudonymous scoped key, not an account id.",
			player.substr(0, 16)
		)

	# Deduplicated against what is already queued. An unlock happens once ever, so two
	# of them in one batch is a bug on this side and the backbone should not be the
	# thing that notices.
	for held in _queue:
		if str(held["player"]) == player and str(held["key"]) == String(id):
			return DotResult.success(0)

	_queue.append({
		"player": player,
		"key": String(id),
		"unlockedAt": at,
	})

	while _queue.size() > queue_limit:
		_queue.remove_at(0)
		dropped += 1

		# Once until the next successful flush. Unlocks are being thrown away, which is
		# either an outage outlasting the queue or nothing calling flush() at all.
		if not _warned_overflow:
			_warned_overflow = true
			DotLog.warn(CHANNEL, "the unlock queue is full; the oldest are being dropped", {
				"limit": queue_limit, "sent": sent, "failures": failures,
			})

	return DotResult.success(_queue.size())


## Declares the catalogue, so a site can show an achievement nobody has earned yet.
func define(catalogue: DotAchievementCatalogue, app: String = "") -> DotResult:
	var backbone := _client()
	if backbone == null:
		return DotResult.fail(
			DotError.CODE_STATE, "No backbone client is available."
		)

	var body := {"achievements": (catalogue.to_dictionary())["achievements"]}
	if app != "":
		body["app"] = app

	var res: DotResult = await backbone.call("post_integration", DEFINE_PATH, body)
	if res.ok:
		_defined = true
	else:
		# WARN: unlocks still report without it; what is lost is a site showing the
		# achievements nobody has earned yet.
		DotLog.result(CHANNEL, "the achievement catalogue was not declared", res, DotLog.Level.WARN)

	return res


## Sends everything queued, in batches.
func flush() -> DotResult:
	if _queue.is_empty():
		return DotResult.success(0)

	var backbone := _client()
	if backbone == null:
		if not _warned_no_client:
			_warned_no_client = true
			DotLog.warn(CHANNEL, "unlocks are queued and there is no backbone client to send them", {
				"service": String(client_service), "pending": _queue.size(),
			})
		return DotResult.fail(
			DotError.CODE_STATE, "No backbone client is available."
		)

	var total := 0

	while not _queue.is_empty():
		var batch: Array = []
		while not _queue.is_empty() and batch.size() < batch_limit:
			batch.append(_queue.pop_front())

		var res: DotResult = await backbone.call(
			"post_integration", UNLOCK_PATH, {"unlocks": batch}
		)

		if not res.ok:
			failures += 1
			last_error = str(res.error)

			# Put them back at the front, in order, unless the backbone said the
			# request itself was wrong. A retryable failure is a network problem and
			# the unlocks are still true; a 400 means resending them forever would be
			# a loop nobody notices until the log fills.
			if res.error != null and res.error.is_retryable():
				for i in range(batch.size() - 1, -1, -1):
					_queue.push_front(batch[i])

				# Retryable: nothing is lost yet, so the outage is reported on its
				# edges -- WARN when it starts, DEBUG while every flush repeats it.
				if _failing:
					DotLog.debug(CHANNEL, "unlock reporting still failing", {
						"pending": _queue.size(), "error": last_error,
					})
				else:
					DotLog.warn(CHANNEL, "unlock reporting is failing; the batch will be retried", {
						"pending": _queue.size(), "error": last_error,
					})
				_failing = true
			else:
				dropped += batch.size()
				# ERROR every time: these unlocks are gone, and a refusal the backbone
				# will not retry is usually a contract or a scope the operator can fix.
				DotLog.error(CHANNEL, "the backbone refused unlocks; the batch was dropped", {
					"dropped": batch.size(), "error": last_error, "scope": SCOPE_WRITE,
				})

			return res.wrap("Could not report achievement unlocks.")

		sent += batch.size()
		total += batch.size()

	if _failing:
		_failing = false
		DotLog.info(CHANNEL, "unlock reporting recovered", {"sent": total})

	_warned_overflow = false
	_warned_no_client = false

	return DotResult.success(total)


## Reads a player's unlocks back from the backbone.
func fetch_player(player: String) -> DotResult:
	var backbone := _client()
	if backbone == null:
		return DotResult.fail(DotError.CODE_STATE, "No backbone client is available.")

	if not backbone.has_method("get_integration"):
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "That client cannot make integration reads."
		)

	if not is_player_key(player):
		return DotResult.fail(
			DotError.CODE_INVALID, "That is not a player key."
		)

	var res: DotResult = await backbone.call(
		"get_integration", PLAYER_PATH, {"player": player}
	)
	return res


func pending() -> int:
	return _queue.size()


func describe() -> Dictionary:
	return {
		"available": is_available(),
		"defined": _defined,
		"pending": _queue.size(),
		"sent": sent,
		"dropped": dropped,
		"failures": failures,
		"last_error": last_error,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("achievement reporter: %d pending, %d sent, %d dropped, %d failures" % [
		_queue.size(), sent, dropped, failures
	])
	if not is_available():
		out.append("  no backbone client; nothing is being reported")
	if last_error != "":
		out.append("  last error: %s" % last_error)
	return out
