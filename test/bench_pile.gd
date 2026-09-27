extends Node3D

## A crowd pressed together: a game's body pile, the case where every sweep pays
## to push out of the neighbours the body overlaps.
##
##     godot --headless --path <repo root> res://test/bench_pile.tscn
##
## 96 box-shaped bodies on their own layer, which they collide with and ignore for
## steps, press toward one point at walk pace and barely move, as a game measured
## its pile: 2.2 m/s wished, about 0.3 m/s moved. Only the move calls of the last
## half are timed, once the pile has formed.

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
	for body: StairsBody in _bodies:
		speed += Vector2(body.velocity.x, body.velocity.z).length()
	print(
		"piled %.2f us per body per frame, mean speed %.2f m/s"
		% [float(total) / float((FRAMES - TIMED_FROM) * BODIES), speed / float(BODIES)]
	)
	get_tree().quit()


func _spawn(at: Vector3) -> StairsBody:
	var body: StairsBody = StairsBody.new()
	body.collision_layer = CROWD_LAYER
	body.collision_mask = WORLD_LAYER | CROWD_LAYER
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
		wish = to_centre * (WISH / distance)
	var walk: Vector3 = (body.velocity * Vector3(1.0, 0.0, 1.0)).lerp(wish, ACCEL)
	body.velocity = Vector3(walk.x, body.velocity.y - GRAVITY_STEP, walk.z)
	body.desired_velocity = wish
	if wish != Vector3.ZERO:
		body.look_at(body.global_position + wish, Vector3.UP)
	body.move_and_stair_step()
