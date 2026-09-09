@tool
extends EditorPlugin

## Editor entry point for dot-achievements. Registers inspector types only.
##
## No autoloads. A process running a server and a client holds two trackers, and an
## autoload could be neither twice.

const _ICON := "res://addons/dot_achievements/icon_placeholder.svg"

const _TYPES := [
	[
		"DotAchievementTracker",
		"Node",
		"res://addons/dot_achievements/runtime/dot_achievement_tracker.gd",
	],
	[
		"DotAchievementStatsLink",
		"Node",
		"res://addons/dot_achievements/runtime/dot_achievement_stats_link.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for entry in _TYPES:
		remove_custom_type(entry[0])
