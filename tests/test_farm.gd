extends Node
## 无界面农田逻辑测试。
## 运行：godot --headless --path . res://tests/test_farm.tscn

var _failures: Array[String] = []


func _ready() -> void:
	_test_till_and_plant()
	_test_growth_timing()
	_test_watering_can()
	_test_harvest()
	_test_carrot()
	_test_flatten()

	if _failures.is_empty():
		print("FARM TESTS PASSED: till, plant, 30s stages, 90s maturity, watering can, harvest, flatten.")
		get_tree().quit(0)
	else:
		for failure in _failures:
			push_error("FARM TEST FAILED: " + failure)
		get_tree().quit(1)


func _test_till_and_plant() -> void:
	var farm := Farm.new()
	var cell := Vector2i(2, 3)
	_check(not farm.is_tilled(cell), "new farm should have no plot")
	_check(farm.till(cell), "hoe should till normal ground")
	_check(farm.is_tilled(cell), "tilled cell should be tracked")
	_check(not farm.till(cell), "already tilled cell should not be tilled twice")
	_check(farm.plant(cell, "potato"), "potato should plant on tilled soil")
	_check(farm.get_crop_id(cell) == "potato", "planted crop should be potato")
	_check(farm.get_crop_stage(cell) == 0, "planted crop should start at stage 0")
	_check(not farm.plant(cell, "carrot"), "occupied soil should reject a second crop")

	var untilled := Vector2i(9, 9)
	_check(not farm.plant(untilled, "potato"), "crops should not plant on normal grass")
	farm.free()


func _test_growth_timing() -> void:
	var farm := Farm.new()
	var cell := Vector2i(0, 0)
	farm.till(cell)
	farm.plant(cell, "potato")
	_check(farm.get_seconds_to_next_stage(cell) == 30.0, "first stage should take 30 seconds")
	_check(farm.get_seconds_to_mature(cell) == 90.0, "full maturity should take 90 seconds")

	farm.advance_growth(29.0)
	_check(farm.get_crop_stage(cell) == 0, "crop should still be stage 0 at 29s")
	farm.advance_growth(1.1)
	_check(farm.get_crop_stage(cell) == 1, "crop should reach stage 1 after 30s")
	_check(not farm.is_mature(cell), "stage 1 crop should not be mature")
	farm.advance_growth(30.0)
	_check(farm.get_crop_stage(cell) == 2, "crop should reach stage 2 after 60s")
	farm.advance_growth(30.0)
	_check(farm.get_crop_stage(cell) == 3, "crop should reach stage 3 after 90s")
	_check(farm.is_mature(cell), "stage 3 potato should be mature")
	_check(farm.get_seconds_to_mature(cell) == 0.0, "mature crop should have no remaining time")
	farm.free()


func _test_watering_can() -> void:
	var farm := Farm.new()
	var cell := Vector2i(4, 4)
	farm.till(cell)
	farm.plant(cell, "potato")
	_check(farm.water(cell), "watering should advance a growing potato")
	_check(farm.get_crop_stage(cell) == 1, "watering should add one stage")
	_check(farm.water(cell), "watering second stage should work")
	_check(farm.water(cell), "watering third stage should work")
	_check(farm.is_mature(cell), "third watering should mature the potato")
	_check(not farm.water(cell), "mature crop should not be watered further")
	_check(not farm.water(Vector2i(20, 20)), "empty ground should not be watered")
	farm.free()


func _test_harvest() -> void:
	var farm := Farm.new()
	var cell := Vector2i(6, 6)
	farm.till(cell)
	farm.plant(cell, "potato")
	_check(farm.harvest(cell).is_empty(), "immature potato should not be harvestable")
	farm.water(cell)
	farm.water(cell)
	farm.water(cell)
	_check(farm.is_mature(cell), "watered potato should be mature")

	var result := farm.harvest(cell)
	_check(not result.is_empty(), "mature potato should harvest")
	_check(result.get("crop_id", "") == "potato", "harvest should return potato")
	var amount := int(result.get("amount", 0))
	_check(amount >= 2 and amount <= 3, "potato harvest should yield 2-3")
	_check(farm.is_tilled(cell), "harvest should leave tilled soil")
	_check(not farm.has_crop(cell), "harvest should remove the crop")
	_check(farm.harvest(cell).is_empty(), "harvested cell should not be harvestable again")

	var capped_farm := Farm.new()
	var capped_cell := Vector2i(8, 8)
	capped_farm.till(capped_cell)
	capped_farm.plant(capped_cell, "potato")
	capped_farm.water(capped_cell)
	capped_farm.water(capped_cell)
	capped_farm.water(capped_cell)
	var capped := capped_farm.harvest(capped_cell, 2)
	_check(int(capped.get("amount", 0)) == 2, "harvest amount should respect inventory capacity cap")
	farm.free()
	capped_farm.free()


func _test_carrot() -> void:
	var farm := Farm.new()
	var cell := Vector2i(10, 2)
	farm.till(cell)
	_check(farm.plant(cell, "carrot"), "carrot should plant on tilled soil")
	_check(farm.get_crop_id(cell) == "carrot", "planted crop should be carrot")
	farm.advance_growth(90.0)
	_check(farm.is_mature(cell), "carrot should mature after 90 seconds")
	var result := farm.harvest(cell)
	_check(result.get("crop_id", "") == "carrot", "harvest should return carrot")
	_check(int(result.get("amount", 0)) >= 2, "carrot harvest should yield at least 2")
	farm.free()


func _test_flatten() -> void:
	var farm := Farm.new()
	var cell := Vector2i(12, 2)
	_check(not farm.flatten(cell), "flatten should fail on normal grass")
	farm.till(cell)
	_check(farm.flatten(cell), "flatten should remove tilled soil")
	_check(not farm.is_tilled(cell), "flattened cell should become normal ground")

	farm.till(cell)
	farm.plant(cell, "potato")
	_check(not farm.flatten(cell), "flatten should fail while a crop is present")
	_check(farm.is_tilled(cell), "farmland should remain after a rejected flatten")
	farm.free()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
