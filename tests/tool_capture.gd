extends Node
## 截图：真实 main.tscn 跑若干帧后把视口存成 PNG（人工核对地形/树/矿）。
## 运行：godot --headless --path . res://tests/tool_capture.tscn -- --out /tmp/shot.png
func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path := "/tmp/pigfac-shot.png"
	for index in args.size():
		if str(args[index]) == "--out" and index + 1 < args.size():
			out_path = str(args[index + 1])
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	for _i in 400:
		await get_tree().process_frame
	var viewport := get_viewport()
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var error := image.save_png(out_path)
	print("capture: %dx%d -> %s (err=%d)" % [image.get_width(), image.get_height(), out_path, error])
	get_tree().quit(0 if error == OK else 1)