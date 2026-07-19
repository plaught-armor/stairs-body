extends Node3D

## Prices the sweep primitives the step check could be built out of.
##
##     godot --headless --path <repo root> res://test/bench_primitive.tscn
##
## body_test_motion runs three phases (godot_space_3d.cpp:652): STEP 1
## depenetration - a broadphase cull plus a full narrowphase solve pass, on
## every call, whether or not the body is stuck - STEP 2 the actual cast, and
## STEP 3 rest info, which is gated on a collision having happened. cast_motion
## (godot_space_3d.cpp:265) is STEP 2 alone. The step check reads a normal off
## two of its four sweeps and only a distance off the other two, so the question
## is what STEP 1 and STEP 3 cost, and whether the two distance-only sweeps can
## be bought cheaper.
##
## Measured on 4.8.dev, 20000 calls, best of 7:
##
##     body_test_motion, hits a wall             11.341 us/call
##     body_test_motion, hits nothing             4.238
##     cast_motion, hits a wall                    6.052
##     cast_motion, hits nothing                   0.642
##     intersect_ray, hits a wall                  0.516
##     body_test_motion, recovery_as_collision    11.328
##     body_test_motion, max_collisions=4         11.371
##     body_test_motion, 8x longer miss            4.342
##     get_rest_info, at the wall                  2.382
##     cast_motion + get_rest_info                 8.635
##
## So STEP 1 plus STEP 3 is most of the price: dropping to a bare cast is 1.9x on
## a hit and 6.6x on a miss, and the miss is what the walking character runs
## every frame. Neither recovery_as_collision nor max_collisions=4 costs anything
## measurable, and motion length is nearly free - an 8x longer miss is 2% dearer.
##
## The 6.6x turned out not to be spendable, for reasons that are about
## correctness rather than cost. cast_motion sweeps one shape RID where
## body_test_motion sweeps the whole body (test/diag_multishape.gd: 0.18 m apart
## on a two-shape body), and even on a single-shape body the substitution loses
## steps in two separate ways (test/diag_castmotion.gd). Read that file before
## reaching for these numbers again.

const N: int = 20000
const RUNS: int = 7

var _body: CharacterBody3D
var _shape_rid: RID
var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
var _query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
var _ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.new()
var _space: PhysicsDirectSpaceState3D


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


func _run() -> void:
	_box(Vector3(40.0, 1.0, 40.0), Vector3(0.0, -0.5, 0.0))
	# A wall taller than any step, at x = 0.6, so a forward sweep hits it.
	_box(Vector3(1.0, 4.0, 40.0), Vector3(1.2, 2.0, 0.0))

	_body = CharacterBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = 0.3
	cyl.height = 1.8
	cyl.margin = 0.001
	shape_node.shape = cyl
	_body.add_child(shape_node)
	add_child(_body)
	_body.global_position = Vector3(0.0, 0.9, 0.0)
	for _i: int in 10:
		await get_tree().physics_frame

	_space = get_world_3d().direct_space_state
	_shape_rid = cyl.get_rid()
	_params.margin = 0.001
	_query.shape_rid = _shape_rid
	_query.margin = 0.001
	_query.exclude = [_body.get_rid()]
	_ray.exclude = [_body.get_rid()]

	var here: Transform3D = _body.global_transform
	var rid: RID = _body.get_rid()
	var hit: Vector3 = Vector3(0.5, 0.0, 0.0) # reaches the wall
	var miss: Vector3 = Vector3(-0.5, 0.0, 0.0) # open air
	_bench(
		"body_test_motion, hits a wall",
		func() -> void:
			_params.from = here
			_params.motion = hit
			for _i: int in N:
				PhysicsServer3D.body_test_motion(rid, _params, _result),
	)

	_bench(
		"body_test_motion, hits nothing",
		func() -> void:
			_params.from = here
			_params.motion = miss
			for _i: int in N:
				PhysicsServer3D.body_test_motion(rid, _params, _result),
	)

	_bench(
		"cast_motion, hits a wall",
		func() -> void:
			_query.transform = here
			_query.motion = hit
			for _i: int in N:
				var _r: PackedFloat32Array = _space.cast_motion(_query),
	)

	_bench(
		"cast_motion, hits nothing",
		func() -> void:
			_query.transform = here
			_query.motion = miss
			for _i: int in N:
				var _r: PackedFloat32Array = _space.cast_motion(_query),
	)

	_bench(
		"intersect_ray, hits a wall",
		func() -> void:
			_ray.from = Vector3(0.0, 0.9, 0.0)
			_ray.to = Vector3(1.0, 0.9, 0.0)
			for _i: int in N:
				var _r: Dictionary = _space.intersect_ray(_ray),
	)

	# Does raising max_collisions or recovery_as_collision change the price?
	_bench(
		"body_test_motion, recovery_as_collision",
		func() -> void:
			_params.from = here
			_params.motion = hit
			_params.recovery_as_collision = true
			for _i: int in N:
				PhysicsServer3D.body_test_motion(rid, _params, _result)
			_params.recovery_as_collision = false,
	)

	_bench(
		"body_test_motion, max_collisions=4",
		func() -> void:
			_params.from = here
			_params.motion = hit
			_params.max_collisions = 4
			for _i: int in N:
				PhysicsServer3D.body_test_motion(rid, _params, _result)
			_params.max_collisions = 1,
	)

	# What does the motion length itself cost? The step check's four sweeps are
	# short; a long one merges a bigger AABB and culls more.
	_bench(
		"body_test_motion, 8x longer miss",
		func() -> void:
			_params.from = here
			_params.motion = miss * 8.0
			for _i: int in N:
				PhysicsServer3D.body_test_motion(rid, _params, _result),
	)

	_bench(
		"get_rest_info, at the wall",
		func() -> void:
			_query.transform = here.translated(Vector3(0.45, 0.0, 0.0))
			_query.motion = Vector3.ZERO
			for _i: int in N:
				var _r: Dictionary = _space.get_rest_info(_query),
	)

	_bench(
		"cast_motion + get_rest_info",
		func() -> void:
			for _i: int in N:
				_query.transform = here
				_query.motion = hit
				var f: PackedFloat32Array = _space.cast_motion(_query)
				if f[0] < 1.0:
					_query.transform = here.translated(hit * f[1])
					_query.motion = Vector3.ZERO
					var _r: Dictionary = _space.get_rest_info(_query),
	)

	get_tree().quit()


func _bench(label: String, body: Callable) -> void:
	body.call()
	var best: int = 1 << 62
	for _r: int in RUNS:
		var started: int = Time.get_ticks_usec()
		body.call()
		best = mini(best, Time.get_ticks_usec() - started)
	print("%-40s %7.3f us/call" % [label, float(best) / N])
