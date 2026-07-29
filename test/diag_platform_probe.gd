extends Node3D

## Why does the first sweep miss a step on a fast-moving platform?
##
##     godot --headless --path <repo root> res://test/diag_platform_probe.tscn
##
## diag_platform_stairs.gd establishes the failure and stops there: a character
## riding a staircase that slides at 5 m/s parks 9 mm from the first step face and
## every frame bails at sweep1-miss, with a healthy 0.05 m probe. A 50 mm sweep
## from 9 mm away should hit. This walks that exact scenario to the stall and then
## interrogates the stalled frame directly, one hypothesis per sweep.
##
## Hypotheses, in the order the sweeps below test them:
##
##   1. The physics server has the platform somewhere other than where the node
##      says it is - the sweep is aimed at geometry that has already moved.
##      Checked by comparing the node transform against BODY_STATE_TRANSFORM.
##   2. The character is overlapping the platform, so the motion is consumed by
##      depenetration and never reported, because recovery_as_collision defaults
##      to false. Checked by re-running the same sweep with it true.
##   3. The sweep is simply too short for whatever gap the server sees. Checked by
##      lengthening the motion until something is reported.
##   4. sync_to_physics changes what the server holds mid-frame. Checked by
##      running the whole scenario again with it off.

const PLATFORM_SPEED: float = 5.0
const WALK: float = 3.0
const STEP_RISE: float = 0.2
const STEP_FACE_X: float = 1.0

const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001
const GRAVITY: float = 9.8
const DELTA: float = 1.0 / 60.0
const SETTLE_FRAMES: int = 20
const WALK_FRAMES: int = 40

var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	print("--- interrogating the stalled frame ---")
	await _probe(true)
	await _probe(false)
	get_tree().quit(0)


func _probe(sync_to_physics: bool) -> void:
	print("sync_to_physics = %s" % sync_to_physics)

	var world: Node3D = Node3D.new()
	add_child(world)

	var platform: AnimatableBody3D = AnimatableBody3D.new()
	platform.sync_to_physics = sync_to_physics
	_shape(platform, Vector3(30.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	_shape(platform, Vector3(20.0, 2.0, 8.0), Vector3(STEP_FACE_X + 10.0, STEP_RISE - 1.0, 0.0))
	world.add_child(platform)
	platform.global_position = Vector3.ZERO

	var c: StairsCharacter = StairsCharacter.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = BODY_RADIUS
	cyl.height = BODY_HEIGHT
	cyl.margin = COLLIDER_MARGIN
	shape_node.shape = cyl
	c.add_child(shape_node)
	c.collider = shape_node
	world.add_child(c)
	c.global_position = Vector3(0.0, REST_Y, 0.0)

	for _i: int in SETTLE_FRAMES:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()

	for _i: int in WALK_FRAMES:
		await get_tree().physics_frame
		platform.global_position.x += PLATFORM_SPEED * DELTA
		c.velocity.x = WALK
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(WALK, 0.0, 0.0)
		c.move_and_stair_step()

	var relative_x: float = c.global_position.x - platform.global_position.x
	print(
		"  parked at relative x %.4f, contact is at %.4f" % [relative_x, STEP_FACE_X - BODY_RADIUS]
	)
	print("  climbed: %s" % (c.global_position.y - platform.global_position.y > REST_Y + 0.05))

	# Hypothesis 1 - does the server agree with the node about where the platform
	# is? Anything other than zero here means every sweep is aimed at stale
	# geometry, and the gap the sweep sees is not the gap the numbers describe.
	var server_transform: Transform3D = PhysicsServer3D.body_get_state(
		platform.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM,
	)
	print(
		(
			"  node x %.4f, server x %.4f, lag %.4f m (a frame at %.1f m/s is %.4f)"
			% [
				platform.global_position.x,
				server_transform.origin.x,
				platform.global_position.x - server_transform.origin.x,
				PLATFORM_SPEED,
				PLATFORM_SPEED * DELTA,
			]
		)
	)

	# The sweep the addon actually runs, reproduced here so the rest is comparable.
	_params.margin = COLLIDER_MARGIN
	_params.recovery_as_collision = false
	print("  plain sweep 0.0500: %s" % _sweep(c, Vector3(WALK * DELTA, 0.0, 0.0)))

	# Hypothesis 2 - motion eaten by depenetration and not reported.
	_params.recovery_as_collision = true
	print("  same, recovery_as_collision: %s" % _sweep(c, Vector3(WALK * DELTA, 0.0, 0.0)))
	_params.recovery_as_collision = false

	# Hypothesis 3 - how far does the sweep have to reach before it sees anything?
	for reach: float in [0.05, 0.10, 0.15, 0.20, 0.40]:
		print("  reach %.2f: %s" % [reach, _sweep(c, Vector3(reach, 0.0, 0.0))])

	world.queue_free()
	await get_tree().process_frame


## One body_test_motion, described.
func _sweep(c: StairsCharacter, motion: Vector3) -> String:
	_params.from = c.global_transform
	_params.motion = motion
	if not PhysicsServer3D.body_test_motion(c.get_rid(), _params, _result):
		return "no collision"
	return (
		"hit, travel %.4f, normal %v"
		% [_result.get_travel().length(), _result.get_collision_normal(0)]
	)


func _shape(body: PhysicsBody3D, size: Vector3, centre: Vector3) -> void:
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	shape_node.position = centre
	body.add_child(shape_node)
