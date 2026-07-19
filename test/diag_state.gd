extends Node3D

## Diagnostic: what state do the bench_frame characters actually occupy?
##
##     godot --headless --path <repo root> res://test/diag_state.tscn

const CHARACTERS: int = 40
const FRAMES: int = 200
const SETTLE: int = 30
const WALK: float = 3.0
const LANE: float = 3.0
const GRAVITY: float = 9.8
const DELTA: float = 1.0 / 60.0

var _flat: Array[StairsCharacter] = []
var _wall: Array[StairsCharacter] = []


func _ready() -> void:
	call_deferred(&"_run")


func _box(size: Vector3, centre: Vector3) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	add_child(body)
	body.global_position = centre


func _character(at: Vector3) -> StairsCharacter:
	var c: StairsCharacter = StairsCharacter.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = 0.3
	cyl.height = 1.8
	cyl.margin = 0.001
	shape_node.shape = cyl
	c.add_child(shape_node)
	c.collider = shape_node
	add_child(c)
	c.global_position = at
	return c


func _measure(label: String, group: Array[StairsCharacter], walk: Vector3) -> void:
	for _i: int in SETTLE:
		for c: StairsCharacter in group:
			c.velocity.x = walk.x
			c.velocity.z = walk.z
			c.velocity.y -= GRAVITY * DELTA
			c.desired_velocity = walk
			c.move_and_stair_step()
		await get_tree().physics_frame

	var grounded_frames: int = 0
	var on_floor_frames: int = 0
	var moving_frames: int = 0
	var vy_sum: float = 0.0
	var total: int = 0
	for _i: int in FRAMES:
		for c: StairsCharacter in group:
			c.velocity.x = walk.x
			c.velocity.z = walk.z
			c.velocity.y -= GRAVITY * DELTA
			c.desired_velocity = walk
			c.move_and_stair_step()
			total += 1
			if c.grounded:
				grounded_frames += 1
			if c.is_on_floor():
				on_floor_frames += 1
			if Vector3(c.velocity.x, 0.0, c.velocity.z) != Vector3.ZERO:
				moving_frames += 1
			vy_sum += c.velocity.y
		await get_tree().physics_frame

	print(
		"%-26s grounded %.2f  on_floor_after %.2f  moving %.2f  mean velocity.y %+.3f"
		% [
			label,
			float(grounded_frames) / total,
			float(on_floor_frames) / total,
			float(moving_frames) / total,
			vy_sum / total,
		]
	)


# Lanes are centred on the ground box. They used to run from z = 0 upward while
# the ground was centred on the origin, so every character past the halfway lane
# walked off the edge and spent the run in freefall - grounded 0.60, mean
# velocity.y -8.5 - which made the timings an average over a working half and a
# falling half, and left the sweep counts at implausible fractions.
func _lane_z(index: int) -> float:
	return (index - CHARACTERS * 0.5) * LANE


func _run() -> void:
	var span: float = CHARACTERS * LANE + 20.0
	_box(Vector3(400.0, 1.0, span), Vector3(0.0, -0.5, 0.0))
	for i: int in CHARACTERS:
		_flat.append(_character(Vector3(-100.0, 0.9, _lane_z(i))))

	_box(Vector3(1.0, 6.0, span), Vector3(102.0, 3.0, 0.0))
	for i: int in CHARACTERS:
		_wall.append(_character(Vector3(101.0, 0.9, _lane_z(i))))

	await _measure("walking, flat ground", _flat, Vector3(WALK, 0, 0))
	await _measure("pressed into a tall wall", _wall, Vector3(WALK, 0, 0))
	get_tree().quit()
