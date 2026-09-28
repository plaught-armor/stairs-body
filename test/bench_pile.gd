extends Node3D

## A crowd pressed together: a pile of bodies, the case where every sweep pays
## to push out of the neighbours the body overlaps.
##
##     godot --headless --path <repo root> res://test/bench_pile.tscn
##
## 96 box-shaped bodies on their own layer, which they collide with and ignore for
## steps, press toward one point at walk pace and barely move, as a game measured
## its pile: 2.2 m/s wished, about 0.3 m/s moved. Only the move calls of the last
## half are timed, once the pile has formed.
##
##     godot --headless --path <repo root> res://test/bench_pile.tscn -- --idle
##
## runs the same bodies with nothing wished, standing still where they spawned, apart:
## a crowd waiting, the case a resting body skips its checks for.
##
##     godot --headless --path <repo root> res://test/bench_pile.tscn -- --crowd
##
## keeps the bodies apart by crowd separation instead: their own layer leaves their
## masks and goes in crowd_layers. Besides the time, a run prints the mean speed,
## the mean distance from the centre, which says how tight the pile packed, and how
## deep bodies sit inside each other, by the physics server's own depenetration.

const BODIES: int = 96
const PER_RING: int = 24
const FRAMES: int = 300
const TIMED_FROM: int = 150
const WISH: float = 2.2
# Share of the gap to the wished velocity closed per tick.
const ACCEL: float = 0.15
const GRAVITY_STEP: float = 0.16
const WORLD_LAYER: int = 1
const CROWD_LAYER: int = 32

var _bodies: Array[StairsBody] = []
var _wish_speed: float = 0.0 if OS.get_cmdline_user_args().has("--idle") else WISH
var _crowd: bool = OS.get_cmdline_user_args().has("--crowd")


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var ground: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(60.0, 1.0, 60.0)
	shape_node.shape = box
	ground.add_child(shape_node)
	add_child(ground)
	ground.global_position = Vector3(0.0, -0.5, 0.0)
	ground.collision_layer = WORLD_LAYER
	for i: int in BODIES:
		var angle: float = TAU * float(i) / float(PER_RING)
		var radius: float = 1.0 + 0.25 * float(i / PER_RING)
		_bodies.append(_spawn(Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)))

	var total: int = 0
	for f: int in FRAMES:
		await get_tree().physics_frame
		var started: int = Time.get_ticks_usec()
		for body: StairsBody in _bodies:
			_step(body)
		if f >= TIMED_FROM:
			total += Time.get_ticks_usec() - started
	var speed: float = 0.0
	var spread: float = 0.0
	for body: StairsBody in _bodies:
		speed += Vector2(body.velocity.x, body.velocity.z).length()
		spread += Vector2(body.global_position.x, body.global_position.z).length()
	var overlap: Vector2 = _overlap()
	print(
		(
			"piled %.2f us per body per frame, mean speed %.2f m/s, mean distance from centre %.3f m,"
			+ " overlap mean %.1f mm max %.1f mm"
		)
		% [
			float(total) / float((FRAMES - TIMED_FROM) * BODIES),
			speed / float(BODIES),
			spread / float(BODIES),
			overlap.x * 1000.0,
			overlap.y * 1000.0,
		]
	)
	get_tree().quit()


## How deep each body sits inside the others, by the physics server's own
## depenetration: mean and max, in metres. Outside the timed region.
func _overlap() -> Vector2:
	var params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
	params.recovery_as_collision = true
	params.margin = 0.001
	var result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
	var total: float = 0.0
	var deepest: float = 0.0
	for body: StairsBody in _bodies:
		var mask: int = body.collision_mask
		body.collision_mask = CROWD_LAYER
		params.from = body.global_transform
		var depth: float = 0.0
		if PhysicsServer3D.body_test_motion(body.get_rid(), params, result):
			depth = result.get_travel().length()
		body.collision_mask = mask
		total += depth
		deepest = maxf(deepest, depth)
	return Vector2(total / float(BODIES), deepest)


func _spawn(at: Vector3) -> StairsBody:
	var body: StairsBody = StairsBody.new()
	body.collision_layer = CROWD_LAYER
	body.collision_mask = WORLD_LAYER if _crowd else WORLD_LAYER | CROWD_LAYER
	if _crowd:
		body.crowd_layers = CROWD_LAYER
	body.step_ignore_layers = CROWD_LAYER
	body.step_height = 0.06
	body.step_down_height = 0.06
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(0.06, 0.07, 0.18)
	box.margin = 0.004
	shape_node.shape = box
	shape_node.position = Vector3(0.0, 0.035, -0.005)
	body.add_child(shape_node)
	add_child(body)
	body.global_position = at
	return body


func _step(body: StairsBody) -> void:
	var to_centre: Vector3 = -body.global_position * Vector3(1.0, 0.0, 1.0)
	var distance: float = to_centre.length()
	var wish: Vector3 = Vector3.ZERO
	if distance > 0.05:
		wish = to_centre * (_wish_speed / distance)
	var walk: Vector3 = (body.velocity * Vector3(1.0, 0.0, 1.0)).lerp(wish, ACCEL)
	body.velocity = Vector3(walk.x, body.velocity.y - GRAVITY_STEP, walk.z)
	body.desired_velocity = wish
	if wish != Vector3.ZERO:
		body.look_at(body.global_position + wish, Vector3.UP)
	body.move_and_stair_step()
