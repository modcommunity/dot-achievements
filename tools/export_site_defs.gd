extends SceneTree

## Writes a game's achievements as the site's `dot-achievement-defs` JSON. Run inside the game project:
##   godot --headless --path . --script ../dot-achievements/tools/export_site_defs.gd -- \
##     --source res://game/x_achievements.gd --method catalogue --out deployment/achievement-defs.json [--check] [--game 12]
## --check writes nothing and exits 1 if the file on disk differs.

func _init() -> void:
	var args := _parse(OS.get_cmdline_user_args())
	var source := str(args.get("source", ""))
	var method := str(args.get("method", "catalogue"))
	var out_path := str(args.get("out", "deployment/achievement-defs.json"))
	var script := load(source) as Script
	if script == null or not script.has_method(method):
		printerr("export_site_defs: %s has no static %s()" % [source, method])
		quit(2)
		return
	var catalogue := script.call(method) as DotAchievementCatalogue
	var valid := catalogue.validate()
	if not valid.ok:
		printerr("export_site_defs: catalogue invalid: %s" % valid.message)
		quit(2)
		return
	var text := JSON.stringify(catalogue.to_site_defs(int(args.get("game", 0))), "\t", false) + "\n"
	if args.has("check"):
		if FileAccess.get_file_as_string(out_path) != text:
			printerr("export_site_defs: %s is out of date; re-run without --check" % out_path)
			quit(1)
			return
		print("export_site_defs: %s is current (%d achievements)" % [out_path, catalogue.achievements.size()])
		quit(0)
		return
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("export_site_defs: cannot write %s" % out_path)
		quit(2)
		return
	f.store_string(text)
	f.close()
	print("export_site_defs: wrote %s (%d achievements)" % [out_path, catalogue.achievements.size()])
	quit(0)


func _parse(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var a := argv[i]
		if a.begins_with("--"):
			var k := a.substr(2)
			if i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
				out[k] = argv[i + 1]
				i += 1
			else:
				out[k] = true
		i += 1
	return out
