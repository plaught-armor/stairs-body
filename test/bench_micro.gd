extends Node3D

## Prices the per-call work the step check does *around* its sweeps.
##
##     godot --headless --path <repo root> res://test/bench_micro.tscn

const N: int = 200000
const RUNS: int = 7

var _body: CharacterBody3D
var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var ground: StaticBody3D = StaticBody3D.new()
	var gs: CollisionShape3D = CollisionShape3D.new()
	var gb: BoxShape3D = BoxShape3D.new()
	gb.size = Vector3(40.0, 1.0, 40.0)
	gs.shape = gb
	ground.add_child(gs)
	add_child(ground)
	ground.global_position = Vector3(0.0, -0.5, 0.0)

	_body = CharacterBody3D.new()
	var cs: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = 0.3
	cyl.height = 1.8
	cyl.margin = 0.001
	cs.shape = cyl
	_body.add_child(cs)
	add_child(_body)
	_body.global_position = Vector3(0.0, 0.9, 0.0)
	for _i: int in 10:
		await get_tree().physics_frame

	# Populate _result with a real contact so the getters below are honest.
	_params.margin = 0.001
	_params.from = _body.global_transform
	_params.motion = Vector3.DOWN * 0.5
	PhysicsServer3D.body_test_motion(_body.get_rid(), _params, _result)

	_bench("get_rid()", func() -> void:
		for _i: int in N:
			var _r: RID = _body.get_rid())
	_bench("cached rid read", func() -> void:
		var rid: RID = _body.get_rid()
		for _i: int in N:
			var _r: RID = rid)
	_bench("get_travel() x2", func() -> void:
		for _i: int in N:
			var _a: Vector3 = _result.get_travel()
			var _b: float = _result.get_travel().length())
	_bench("get_travel() x1", func() -> void:
		for _i: int in N:
			var t: Vector3 = _result.get_travel()
			var _b: float = t.length())
	_bench("get_travel() x1, absf(y)", func() -> void:
		for _i: int in N:
			var t: Vector3 = _result.get_travel()
			var _b: float = absf(t.y))

	var normal: Vector3 = _result.get_collision_normal(0)
	var max_angle: float = _body.floor_max_angle
	_bench("angle_to(UP) <= floor_max_angle", func() -> void:
		for _i: int in N:
			var _w: bool = normal.angle_to(Vector3.UP) <= max_angle)
	_bench("normal.y >= cos(floor_max_angle)", func() -> void:
		for _i: int in N:
			var _w: bool = normal.y >= cos(max_angle))
	_bench("get_physics_process_delta_time()", func() -> void:
		for _i: int in N:
			var _d: float = _body.get_physics_process_delta_time())
	_bench("length() < margin", func() -> void:
		var t: Vector3 = _result.get_travel()
		for _i: int in N:
			var _w: bool = t.length() < 0.001)
	_bench("length_squared() < margin*margin", func() -> void:
		var t: Vector3 = _result.get_travel()
		for _i: int in N:
			var _w: bool = t.length_squared() < 0.000001)

	get_tree().quit()


func _bench(label: String, body: Callable) -> void:
	body.call()
	var best: int = 1 << 62
	for _r: int in RUNS:
		var started: int = Time.get_ticks_usec()
		body.call()
		best = mini(best, Time.get_ticks_usec() - started)
	print("%-38s %7.3f ns/op" % [label, float(best) * 1000.0 / N])
