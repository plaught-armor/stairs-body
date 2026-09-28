extends Node3D

## The honest per-frame number: many characters walking real frames, with only
## the move_and_stair_step calls inside the timed region.
##
##     godot --headless --path <repo root> res://test/bench_frame.tscn
##
## Two earlier attempts measured the wrong thing and are worth not repeating.
## Timing across `await get_tree().physics_frame` buries a microsecond effect
## under ~16.67 ms of scheduler wait. Calling the step check
## in a tight loop on a settled body avoids the await but freezes the character
## in a state it never occupies while walking - the forward sweep hits there and
## misses when driven, so the tight loop prices a branch the game does not take.
## Driving real frames and timing only the calls is what is left.
##
##     godot --headless --path <repo root> res://test/bench_frame.tscn -- --grid
##
## walks the characters on a StairsWalkGrid over the level instead, and prints
## the share of timed moves made on it.

const CHARACTERS: int = 200
const FRAMES: int = 200
const SETTLE: int = 30
const WALK: float = 3.0
const LANE: float = 3.0
const RISE: float = 0.2
const TREAD: float = 0.3
const TREADS: int = 40
const FLIGHT_START: float = 152.0

var _flat: Array[StairsBody] = []
var _wall: Array[StairsBody] = []
var _flight: Array[StairsBody] = []
var _grid: StairsWalkGrid = StairsWalkGrid.new() if OS.get_cmdline_user_args().has("--grid") else null


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


func _character(at: Vector3) -> StairsBody:
	var c: StairsBody = StairsBody.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = 0.3
	cyl.height = 1.8
	cyl.margin = 0.001
	shape_node.shape = cyl
	c.add_child(shape_node)
	c.walk_grid = _grid
	add_child(c)
	c.global_position = at
	return c


func _step(group: Array[StairsBody], walk: Vector3) -> void:
	for c: StairsBody in group:
		c.velocity = Vector3(walk.x, c.velocity.y - GRAVITY_STEP, walk.z)
		c.desired_velocity = walk
		c.move_and_stair_step()


const GRAVITY_STEP: float = 0.16


func _measure(label: String, group: Array[StairsBody], walk: Vector3) -> void:
	for _i: int in SETTLE:
		_step(group, walk)
		await get_tree().physics_frame

	var total: int = 0
	var on_grid: int = 0
	for _i: int in FRAMES:
		var started: int = Time.get_ticks_usec()
		_step(group, walk)
		total += Time.get_ticks_usec() - started
		for c: StairsBody in group:
			on_grid += int(c.is_on_walk_grid())
		await get_tree().physics_frame

	print(
		"%-26s %7.2f us per character per frame, %3.0f%% on the grid"
		% [
			label,
			float(total) / (FRAMES * CHARACTERS),
			100.0 * float(on_grid) / float(FRAMES * CHARACTERS),
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

	# A wall the characters walk into and then hold against.
	_box(Vector3(1.0, 6.0, span), Vector3(102.0, 3.0, 0.0))
	for i: int in CHARACTERS:
		_wall.append(_character(Vector3(101.0, 0.9, _lane_z(i))))

	# A long flight the characters climb all through the timed frames.
	for i: int in TREADS:
		var top: float = RISE * float(i + 1)
		_box(
			Vector3(TREAD, top, span),
			Vector3(FLIGHT_START + TREAD * (float(i) + 0.5), top * 0.5, 0.0),
		)
	for i: int in CHARACTERS:
		_flight.append(_character(Vector3(FLIGHT_START - 3.0, 0.9, _lane_z(i))))
	if _grid != null:
		add_child(_grid)

	await _measure("walking, flat ground", _flat, Vector3(WALK, 0, 0))
	await _measure("pressed into a tall wall", _wall, Vector3(WALK, 0, 0))
	await _measure("climbing a flight", _flight, Vector3(WALK, 0, 0))
	get_tree().quit()
