extends Node3D

## Prices the per-call work the step check does *around* its sweeps.
##
##     godot --headless --path <repo root> res://test/bench_micro.tscn
##
## Measured on 4.8.dev, 200000 iterations, best of 7:
##
##     _params.margin property read     23.4 ns   cached margin float      6.5
##     _params.from write               19.8      _params.motion write    19.5
##     get_travel() x2                  28.9      get_travel() x1         21.3
##     angle_to(UP) <= floor_max_angle  16.5      normal.y >= hoisted cos 13.0
##     get_rid()                        12.8      cached rid read          6.0
##     length() < margin                12.5      length_squared()        13.1
##
## Two things fall out, and both say leave this code alone.
##
## First, the dominant term is not arithmetic, it is property access on the
## parameters object - and most of it is writes, which are not optional. A full
## four-sweep check writes `from` and `motion` eight times for ~157 ns. That is
## how the API takes its input.
##
## Second, everything that COULD be shaved totals about 99 ns: caching the rid
## (27), caching the margin (50), a hoisted cosine (7), and not calling
## get_travel twice (15). A full check spends 17-45 us in its four sweeps, and
## bench_frame's run-to-run spread is +-350 ns - so the entire available win is a
## quarter of the noise floor of the rig that would have to measure it.
##
## Two of those four are also hazards rather than wins. cos(floor_max_angle)
## cannot be cached: floor_max_angle is a user-settable CharacterBody3D property
## and a cached cosine goes stale silently when a controller changes it. A cached
## margin float contradicts the invariant on _params in stairs_character.gd -
## that object's margin is deliberately the only copy - and buys a desync surface
## for 50 ns.
##
## Only the get_travel double-call was changed, and for readability: a local
## makes it plain the translate and the length are the same vector. The 15 ns is
## a coincidence, not a reason.
##
## Note the naive rewrites that measured SLOWER: recomputing cos() per call
## (20.4 against angle_to's 16.5) and length_squared() against a squared margin
## (13.1 against 12.5). Neither is worth having, and neither is obvious from
## reading the code - which is the argument for this file existing.

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

	_bench(
		"get_rid()",
		func() -> void:
			for _i: int in N:
				var _r: RID = _body.get_rid(),
	)
	_bench(
		"cached rid read",
		func() -> void:
			var rid: RID = _body.get_rid()
			for _i: int in N:
				var _r: RID = rid,
	)
	_bench(
		"get_travel() x2",
		func() -> void:
			for _i: int in N:
				var _a: Vector3 = _result.get_travel()
				var _b: float = _result.get_travel().length(),
	)
	_bench(
		"get_travel() x1",
		func() -> void:
			for _i: int in N:
				var t: Vector3 = _result.get_travel()
				var _b: float = t.length(),
	)
	_bench(
		"get_travel() x1, absf(y)",
		func() -> void:
			for _i: int in N:
				var t: Vector3 = _result.get_travel()
				var _b: float = absf(t.y),
	)

	var normal: Vector3 = _result.get_collision_normal(0)
	var max_angle: float = _body.floor_max_angle
	_bench(
		"angle_to(UP) <= floor_max_angle",
		func() -> void:
			for _i: int in N:
				var _w: bool = normal.angle_to(Vector3.UP) <= max_angle,
	)
	_bench(
		"normal.y >= cos(floor_max_angle)",
		func() -> void:
			for _i: int in N:
				var _w: bool = normal.y >= cos(max_angle),
	)
	# The fair version of the above: a real implementation would resolve the
	# cosine once, next to the margin, not recompute it per call.
	_bench(
		"normal.y >= hoisted cos",
		func() -> void:
			var limit: float = cos(max_angle)
			for _i: int in N:
				var _w: bool = normal.y >= limit,
	)
	_bench(
		"normal.dot(UP) >= hoisted cos",
		func() -> void:
			var limit: float = cos(max_angle)
			for _i: int in N:
				var _w: bool = normal.dot(Vector3.UP) >= limit,
	)
	# margin is read three times per step check, through the parameters object.
	_bench(
		"_params.margin property read",
		func() -> void:
			for _i: int in N:
				var _m: float = _params.margin,
	)
	_bench(
		"cached margin float",
		func() -> void:
			var margin: float = _params.margin
			for _i: int in N:
				var _m: float = margin,
	)
	# The step check writes from+motion once per sweep, so eight property writes
	# per full check against three margin reads. If a write costs what a read
	# costs, these are the whole of the work around the sweeps, and they are not
	# optional - the API takes its input this way.
	var here: Transform3D = _body.global_transform
	_bench(
		"_params.from write",
		func() -> void:
			for _i: int in N:
				_params.from = here,
	)
	_bench(
		"_params.motion write",
		func() -> void:
			for _i: int in N:
				_params.motion = Vector3.DOWN,
	)
	_bench(
		"get_physics_process_delta_time()",
		func() -> void:
			for _i: int in N:
				var _d: float = _body.get_physics_process_delta_time(),
	)
	_bench(
		"length() < margin",
		func() -> void:
			var t: Vector3 = _result.get_travel()
			for _i: int in N:
				var _w: bool = t.length() < 0.001,
	)
	_bench(
		"length_squared() < margin*margin",
		func() -> void:
			var t: Vector3 = _result.get_travel()
			for _i: int in N:
				var _w: bool = t.length_squared() < 0.000001,
	)

	get_tree().quit()


func _bench(label: String, body: Callable) -> void:
	body.call()
	var best: int = 1 << 62
	for _r: int in RUNS:
		var started: int = Time.get_ticks_usec()
		body.call()
		best = mini(best, Time.get_ticks_usec() - started)
	print("%-38s %7.3f ns/op" % [label, float(best) * 1000.0 / N])
