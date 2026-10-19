extends SceneTree
## 区块生成基准（验收 11）：生成 N 块，统计 avg/p99 并对配置预算断言。
## 运行：godot --headless --path . -s res://tests/bench_chunk_gen.gd [-- --chunks 100]

const DEFAULT_COUNT := 100


func _initialize() -> void:
	var config := WorldGenConfig.load_default()
	var count := DEFAULT_COUNT
	var args := OS.get_cmdline_user_args()
	for index in args.size():
		if str(args[index]) == "--chunks" and index + 1 < args.size():
			count = int(args[index + 1])
	var seed_value := 20250101
	# 预热：把 REGION / 噪声相关的静态缓存建起来（真实运行时也是先有相邻块）。
	var warmup := WorldGenerator.new(config, seed_value)
	warmup.generate_chunk(Vector2i(0, 0))
	var generator := WorldGenerator.new(config, seed_value)
	var times: Array[float] = []
	var side := int(ceil(sqrt(float(count))))
	var generated := 0
	var start_all := Time.get_ticks_usec()
	for index in count:
		var chunk := Vector2i(index % side, index / side)
		var started := Time.get_ticks_usec()
		var data := generator.generate_chunk(chunk)
		var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
		times.append(elapsed)
		generated += 1
		var _unused := data
	var total := float(Time.get_ticks_usec() - start_all) / 1000.0
	times.sort()
	var sum := 0.0
	for value in times:
		sum += value
	var average := sum / float(maxi(1, times.size()))
	var p99 := times[mini(times.size() - 1, int((float(times.size()) * 0.99)))]
	var median := times[times.size() / 2]
	print("BENCH chunks=%d total=%.1fms avg=%.2fms median=%.2fms max=%.2fms p99=%.2fms" % [
		generated, total, average, median, times[times.size() - 1], p99
	])
	print("BENCH budget: avg < %.1fms, p99 < %.1fms" % [config.bench_avg_ms_max, config.bench_p99_ms_max])
	var ok := average < config.bench_avg_ms_max and p99 < config.bench_p99_ms_max
	if ok:
		print("CHUNK GEN BENCH PASSED")
		quit(0)
	else:
		push_error("CHUNK GEN BENCH FAILED: avg %.2f (max %.1f), p99 %.2f (max %.1f)" % [
			average, config.bench_avg_ms_max, p99, config.bench_p99_ms_max
		])
		quit(1)
