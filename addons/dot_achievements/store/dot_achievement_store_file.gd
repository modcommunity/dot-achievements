class_name DotAchievementStoreFile
extends DotAchievementStore

## One JSON file per player, under a directory.
##
## For a single-player game, a listen server, or a small community that would rather
## have files it can read than a database it has to run.
##
## [b]The filename is derived, never the player key.[/b] A key arrives from a login
## and can be anything at all; a store that used it directly is one
## [code]../../[/code] away from writing outside its directory. [DotPaths.slugify]
## plus a hash of the whole key is what makes the name both safe and unique — the
## slug alone is not, because two different keys can slugify to the same string, and
## dot-timer shipped exactly that: [code]surf_kitsune2[/code] and
## [code]surf_kitsune3[/code] both became [code]surf_kitsune_[/code] and shared one
## records file.

## Where the files go.
var directory: String = "user://dot_achievements"

## Written atomically. A crash mid-write leaves the old file or the new one and never
## half of one — which for a progress file is indistinguishable from a player losing
## everything.
var atomic: bool = true


func _init(p_directory: String = "user://dot_achievements") -> void:
	directory = p_directory


## The file a player's progress lives in.
func path_for(player: String) -> String:
	var slug := DotPaths.slugify(player, 40)
	if slug == "":
		slug = "player"

	# The hash is what makes it unique; the slug is what makes it readable. Both
	# matter — an operator looking for one player's file should be able to find it,
	# and two players must never share one.
	var digest := DotHash.sha256_text(player).substr(0, 16)

	return "%s/%s-%s.json" % [directory, slug, digest]


func _load_progress(player: String) -> DotResult:
	var path := path_for(player)

	if not FileAccess.file_exists(path):
		return DotResult.success(DotAchievementProgress.new())

	var read := DotPaths.read_json(path)
	if not read.ok:
		# Deliberately a failure and not a fresh player. A file that exists and cannot
		# be read is a file that must not be overwritten with an empty one, which is
		# what handing back a blank progress would cause on the next save.
		return read.wrap("Could not read achievement progress.")

	var data: Variant = read.value
	if typeof(data) != TYPE_DICTIONARY:
		return DotResult.fail(
			DotError.CODE_PARSE, "Achievement progress is an object.", path
		)

	return DotAchievementProgress.from_dictionary(data as Dictionary)


func _save_progress(player: String, progress: DotAchievementProgress) -> DotResult:
	var written := DotPaths.write_json(
		path_for(player), progress.to_dictionary(), true, atomic
	)

	if not written.ok:
		return written.wrap("Could not save achievement progress.")

	# user:// on the web is an IndexedDB mirror that needs an explicit flush. Without
	# it the file exists in the tab and not in the browser's storage, and the first
	# reload loses everything the player earned.
	DotWeb.sync_filesystem()

	return DotResult.success(1)
