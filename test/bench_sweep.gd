extends Node3D

## Prices a single body_test_motion sweep, and counts how many the step check
## actually runs in each situation a character spends its time in.
##
##     godot --headless --path <repo root> res://test/bench_sweep.tscn
##
## Sweeps are what the step check costs, so the only lever on this path is
## running fewer of them - allocation work is ~2% by comparison
## (test/bench_alloc.gd).
##
## This times a sweep and stops there, deliberately. Timing move_and_stair_step
## per scenario was tried and thrown away: at one character the run-to-run spread
## is a few microseconds on identical code, wide enough to swallow the effect and
## occasionally to reverse its sign. Sweep COUNTS are deterministic and are the
## honest measure. To recount them, temporarily wrap the body_test_motion calls
## in stairs_character.gd with a static counter and drive each scenario.
##
## Counted that way on 4.8.dev, sweeps per character per frame:
##
##     standing still              0.00   (both step functions bail on entry)
##     walking, flat ground        1.00   (one forward sweep that hits nothing)
##     walking up a ramp           1.00   (4.00 before the walkable-surface bail)
##     walking off a ledge         1.02
##     climbing a staircase        1.67
##     pressed into a tall wall    2.90   (3.85 before the two bails below)
##
## The wall is the state worth caring about: players hold forward into geometry
## for seconds at a time, and it is the only case that still runs a multi-sweep
## check to reach a conclusion it reaches every frame.

const SWEEP_SAMPLES: int = 20000
const RUNS: int = 7
const FRAMES: int = 120
const WALK: float = 3.0

var _body: CharacterBody3D
var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()


func _ready() -> void:
	call_deferred(&"_run")


func _add_box(size: Vector3, centre: Vector3, tilt_deg: float = 0.0) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	add_child(body)
	body.global_position = centre
	body.rotation.z = deg_to_rad(tilt_deg)


func _make_character(at: Vector3) -> StairsCharacter:
	var c: StairsCharacter = StairsCharacter.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var body_shape: CylinderShape3D = CylinderShape3D.new()
	body_shape.radius = 0.3
	body_shape.height = 1.8
	body_shape.margin = 0.001
	shape_node.shape = body_shape
	c.add_child(shape_node)
	c.collider = shape_node
	add_child(c)
	c.global_position = at
	return c


func _run() -> void:
	_add_box(Vector3(40.0, 1.0, 40.0), Vector3(0.0, -0.5, 0.0))
	_add_box(Vector3(4.0, 2.0, 40.0), Vector3(3.0, -0.8, 0.0))
	_body = _make_character(Vector3(0.0, 0.9, 0.0))
	for _i: int in 20:
		await get_tree().physics_frame

	_params.margin = 0.001
	_params.from = _body.global_transform
	_params.motion = Vector3(0.05, 0.0, 0.0)
	for _i: int in 2000:
		PhysicsServer3D.body_test_motion(_body.get_rid(), _params, _result)

	var best: int = 1 << 62
	for _run_i: int in RUNS:
		var started: int = Time.get_ticks_usec()
		for _i: int in SWEEP_SAMPLES:
			PhysicsServer3D.body_test_motion(_body.get_rid(), _params, _result)
		best = mini(best, Time.get_ticks_usec() - started)

	var per_sweep_us: float = float(best) / SWEEP_SAMPLES
	print("one body_test_motion = %.3f us" % per_sweep_us)
	print("a four sweep step check = %.2f us" % (per_sweep_us * 4.0))
	print("reusing the query objects saves 0.66 us (test/bench_alloc.gd)")
	get_tree().quit()
