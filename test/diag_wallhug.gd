extends Node3D

## Can the character climb a staircase while pressed against a wall beside it?
##
##     godot --headless --path <repo root> res://test/diag_wallhug.tscn
##
## Every sweep in stair_step_up is a single body_test_motion that stops dead at
## the first contact. Reference implementations that iterate - Jolt's WalkStairs,
## and the sweep loop in dresswithpockets' write-up - slide the remaining motion
## along the contact normal and sweep again. This asks whether that difference is
## reachable from ordinary play, or only from contrived geometry.
##
## The world is a four step staircase with a wall running alongside it. The
## character walks up it twice: once straight, once with a constant sideways push
## into the wall, which is what a player holding a diagonal against a banister
## does. Straight is the control - if that fails the world is wrong, not the addon.

const FRAMES: int = 120
const SETTLE: int = 20
const WALK: float = 3.0
const GRAVITY: float = 9.8
const DELTA: float = 1.0 / 60.0

const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001

const STEP_RISE: float = 0.2
const STEP_RUN: float = 1.0
const STEPS: int = 4

## Wall face sits exactly on the character's radius, so a sideways push holds it
## in contact without ever embedding it.
const WALL_FACE_Z: float = BODY_RADIUS


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	print("--- wall-hug stair climb ---")
	var open: Vector3 = await _walk(Vector3(WALK, 0.0, 0.0), false)
	var beside: Vector3 = await _walk(Vector3(WALK, 0.0, 0.0), true)
	var hugging: Vector3 = await _walk(Vector3(WALK, 0.0, WALK), true)

	print("no wall, straight push          x=%.2f y=%.2f" % [open.x, open.y])
	print("wall alongside, straight push   x=%.2f y=%.2f" % [beside.x, beside.y])
	print("wall alongside, pushed into it  x=%.2f y=%.2f" % [hugging.x, hugging.y])
	print("top of the staircase is y=%.2f" % (STEPS * STEP_RISE + REST_Y))
	get_tree().quit(0)


## Walks one character up the staircase and returns where it ended up.
func _walk(push: Vector3, with_wall: bool) -> Vector3:
	var world: Node3D = Node3D.new()
	add_child(world)
	_add_box(world, Vector3(20.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	for i: int in STEPS:
		var top: float = STEP_RISE * float(i + 1)
		_add_box(
			world,
			Vector3(STEP_RUN * float(STEPS - i) + 4.0, 2.0, 8.0),
			Vector3(
				STEP_RUN * float(i + 1) + (STEP_RUN * float(STEPS - i) + 4.0) * 0.5,
				top - 1.0,
				0.0,
			),
		)
	if with_wall:
		_add_box(world, Vector3(20.0, 6.0, 0.5), Vector3(0.0, 3.0, WALL_FACE_Z + 0.25))

	var c: StairsCharacter = StairsCharacter.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var body_shape: CylinderShape3D = CylinderShape3D.new()
	body_shape.radius = BODY_RADIUS
	body_shape.height = BODY_HEIGHT
	body_shape.margin = COLLIDER_MARGIN
	shape_node.shape = body_shape
	c.add_child(shape_node)
	c.collider = shape_node
	world.add_child(c)
	c.global_position = Vector3(0.0, REST_Y, 0.0)

	for _i: int in SETTLE:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()

	for _i: int in FRAMES:
		await get_tree().physics_frame
		c.velocity.x = push.x
		c.velocity.z = push.z
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = push
		c.move_and_stair_step()

	var where: Vector3 = c.global_position
	world.queue_free()
	await get_tree().physics_frame
	return where


func _add_box(world: Node3D, size: Vector3, centre: Vector3) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	world.add_child(body)
	body.global_position = centre
