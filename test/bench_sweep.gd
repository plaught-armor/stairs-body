extends Node3D

## Prices a single body_test_motion sweep, and counts how many the step check
## actually runs in each situation a character spends its time in.
##
##     godot --headless --path <repo root> res://test/bench_sweep.tscn
##
## The point is to find where the per-character cost lives before optimising it.
## Allocation work turned out to be ~2% (test/bench_alloc.gd); if the sweeps are
## the rest, then the only lever that matters is running fewer of them.

const SWEEP_SAMPLES: int = 20000

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

	# Warm up, then price one sweep.
	for _i: int in 2000:
		PhysicsServer3D.body_test_motion(_body.get_rid(), _params, _result)

	var best: int = 1 << 62
	for _run_i: int in 7:
		var started: int = Time.get_ticks_usec()
		for _i: int in SWEEP_SAMPLES:
			PhysicsServer3D.body_test_motion(_body.get_rid(), _params, _result)
		best = mini(best, Time.get_ticks_usec() - started)

	var per_sweep_us: float = float(best) / SWEEP_SAMPLES
	print("one body_test_motion = %.3f us" % per_sweep_us)
	print("  a rejected 4-sweep step check   = %.2f us" % (per_sweep_us * 4.0))
	print("  allocations saved by the hoist  = 0.66 us  (test/bench_alloc.gd)")
	print(
		"  so skipping 3 of 4 sweeps saves %.2f us, or %.1fx the allocation win"
		% [per_sweep_us * 3.0, per_sweep_us * 3.0 / 0.66]
	)
	get_tree().quit()
