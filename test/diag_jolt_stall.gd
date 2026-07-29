extends Node3D

## Why does a slow walk at 120 Hz stall against a step under Jolt?
##
##     godot --headless --path <repo root> res://test/diag_jolt_stall.tscn
##
## Run it twice, with and without an override.cfg selecting Jolt; the scene is
## identical either way and prints which engine it is on.
##
##     [physics]
##
##     3d/physics_engine="Jolt Physics"
##
## diag_tickrate.gd walks the whole rate x speed grid and, under Jolt, finds one
## cell that does not climb: 120 Hz at 0.5 m/s, stuck at 0.90 with the step top at
## 1.10. Every other cell of that grid climbs, and under Godot Physics the whole
## grid climbs - so this is not the tick-rate stall min_step_forward was written
## for, which took out whole rows.
##
## This walks that one cell to the stall, prints the frames as they repeat, and
## then replays stair_step_up's four sweeps by hand on the stalled frame so the
## stage that turns back can be named rather than guessed at.
##
## The replay is a copy of the addon's chain rather than a call into it, for the
## reason diag_lift_probe.gd gives: the addon bails at the first sweep that says
## no, and what is wanted here is what the LATER sweeps would have seen.
##
## RESULT, before the fix: the two engines park a blocked body differently.
##
##     Godot Physics  x 1.0190, climbing, 1 step-up      - rests flush
##     Jolt           x 0.6958, 0.00000 m a frame, 0 ups - rests 4.2 mm short
##     both           sweep1 MISS - nothing within 0.00417 m
##
## The face is at x = 1.0 and the body's radius is 0.3, so contact is at 0.7 and
## Jolt has parked it 4.2 mm off. The probe is velocity * delta = 0.5 / 120 =
## 4.17 mm. It misses by three hundredths of a millimetre, so the check never
## starts, so nothing moves, so it misses again - the deadlock the minimum forward
## leg was written for, reached by a route that floor did not cover. It only ever
## lengthened the FORWARD leg, which is phase three; nothing had ever lengthened
## the first sweep, because against an engine that rests a body flush against a
## face there was no gap to cross.
##
## Fixed by applying the same floor to the first sweep. Both engines now climb
## every cell of diag_tickrate.gd's rate x speed grid, and case 52 pins it.
##
## Worth keeping in mind for anything else that reasons about "the body is touching
## the face": under Jolt it may be millimetres away and still be as far forward as
## move_and_slide will ever put it.

const RATE: int = 120
const WALK: float = 0.5
const STEP_TOP: float = 0.2

const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001
const GRAVITY: float = 9.8
const SECONDS: float = 2.0
const SETTLE_SECONDS: float = 0.25
## How many of the last frames to print. The stall repeats, so a handful is all of
## it.
const TAIL_FRAMES: int = 4

var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()

# A member rather than a capture (H6).
var _ups: int = 0


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	print(
		(
			"--- %.1f m/s at %d Hz into a %.2f m step, on %s ---"
			% [
				WALK,
				RATE,
				STEP_TOP,
				ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT"),
			]
		)
	)
	var original_rate: int = Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = RATE
	await _walk_into_the_step()
	Engine.physics_ticks_per_second = original_rate
	get_tree().quit(0)


func _walk_into_the_step() -> void:
	var delta: float = 1.0 / float(RATE)

	var world: Node3D = Node3D.new()
	add_child(world)
	_box(world, Vector3(22.0, 1.0, 8.0), Vector3(1.0, -0.5, 0.0))
	_box(world, Vector3(20.0, 2.0, 8.0), Vector3(11.0, STEP_TOP - 1.0, 0.0))

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
	c.stepped_up.connect(_count_up)

	for _i: int in int(SETTLE_SECONDS * float(RATE)):
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * delta
		c.move_and_stair_step()

	_ups = 0
	var worst_advance: float = 0.0
	var frames: int = int(SECONDS * float(RATE))
	for i: int in frames:
		await get_tree().physics_frame
		c.velocity.x = WALK
		c.velocity.y -= GRAVITY * delta
		c.desired_velocity = Vector3(WALK, 0.0, 0.0)

		var before_ups: int = _ups
		var before_x: float = c.global_position.x
		c.move_and_stair_step()

		# The frame's own reach is WALK * delta; anything above that came from the
		# addon seating the body itself, which is what the floor makes possible and
		# what has to stay bounded.
		worst_advance = maxf(worst_advance, c.global_position.x - before_x)

		if i >= frames - TAIL_FRAMES:
			print(
				(
					"  frame %d: x %.4f -> %.4f (%.5f m), y %.4f, velocity x %.4f, stepped %d"
					% [
						i,
						before_x,
						c.global_position.x,
						c.global_position.x - before_x,
						c.global_position.y,
						c.velocity.x,
						_ups - before_ups,
					]
				)
			)

	print(
		(
			"  ended at x %.4f y %.4f (step top is %.2f), %d step-ups in %d frames, "
			% [c.global_position.x, c.global_position.y, REST_Y + STEP_TOP, _ups, frames]
			+ "worst frame advanced %.5f m against a %.5f m frame reach"
			% [worst_advance, WALK * delta]
		)
	)

	# The probe the addon would build on this frame. velocity.x is whatever
	# move_and_slide left, and desired_velocity is the full walk, so the larger of
	# the two drives it - which against a step face is the intent.
	var testing: Vector3 = Vector3(WALK, 0.0, 0.0)
	_params.margin = COLLIDER_MARGIN
	_trace(c, testing * delta, maxf(testing.length() * delta, c.min_step_forward))

	world.queue_free()
	await get_tree().process_frame


## stair_step_up's sweep chain, replayed stage by stage and printed rather than
## bailed out of. Keep it in step with the addon if that changes.
func _trace(c: StairsCharacter, distance: Vector3, forward_floor: float) -> void:
	var motion_transform: Transform3D = c.global_transform

	_params.from = motion_transform
	_params.motion = distance
	if not PhysicsServer3D.body_test_motion(c.get_rid(), _params, _result):
		print(
			"  sweep1 MISS - nothing within %.5f m, so the check never starts" % distance.length()
		)
		return
	var normal: Vector3 = _result.get_collision_normal(0)
	var angle: float = normal.angle_to(Vector3.UP)
	if angle <= c.floor_max_angle:
		print(
			"  sweep1 hit a WALKABLE %.1f deg face - handed to move_and_slide" % rad_to_deg(angle)
		)
		return
	var remainder: Vector3 = _result.get_remainder()
	motion_transform = motion_transform.translated(_result.get_travel())
	print(
		(
			"  sweep1 hit at %.1f deg, travel %.5f, remainder %.5f"
			% [rad_to_deg(angle), _result.get_travel().length(), remainder.length()]
		)
	)

	_params.from = motion_transform
	_params.motion = c.step_height * Vector3.UP
	PhysicsServer3D.body_test_motion(c.get_rid(), _params, _result)
	var rise: Vector3 = _result.get_travel()
	motion_transform = motion_transform.translated(rise)
	if rise.length() < _params.margin:
		print("    rise BLOCKED at %.5f m" % rise.length())
		return
	print("    rose %.5f of %.5f" % [rise.length(), c.step_height])

	var forward_motion: Vector3 = remainder
	if forward_motion.length() < forward_floor:
		forward_motion = distance.normalized() * forward_floor
	var forward_travel: Vector3 = Vector3.ZERO
	for _i: int in c.step_slide_iterations:
		_params.from = motion_transform
		_params.motion = forward_motion
		var blocked: bool = PhysicsServer3D.body_test_motion(c.get_rid(), _params, _result)
		var leg: Vector3 = _result.get_travel()
		motion_transform = motion_transform.translated(leg)
		forward_travel += leg
		if not blocked:
			break
		forward_motion = (_result.get_remainder().slide(_result.get_collision_normal(0)) * Vector3(
				1,
				0,
				1,
			))
		if forward_motion.length() < _params.margin:
			break
	if forward_travel.length() < _params.margin:
		print(
			(
				"    forward leg BLOCKED, travelled %.5f of a %.5f probe (margin %.5f)"
				% [forward_travel.length(), forward_floor, _params.margin]
			)
		)
		return
	print("    forward %.5f of a %.5f probe" % [forward_travel.length(), forward_floor])

	_params.from = motion_transform
	_params.motion = Vector3.DOWN * rise.length()
	if not PhysicsServer3D.body_test_motion(c.get_rid(), _params, _result):
		print("    set-down found NOTHING within %.5f m" % rise.length())
		return
	motion_transform = motion_transform.translated(_result.get_travel())
	var landing: Vector3 = _result.get_collision_normal(0)
	if landing.angle_to(Vector3.UP) > c.floor_max_angle:
		print("    landing too STEEP at %.1f deg" % rad_to_deg(landing.angle_to(Vector3.UP)))
		return

	var gain: float = motion_transform.origin.y - c.global_position.y
	if gain < _params.margin:
		print("    NO HEIGHT GAINED: %+.5f m, under the %.5f margin" % [gain, _params.margin])
		return
	print("    would step up %+.5f m" % gain)


func _count_up() -> void:
	_ups += 1


func _box(world: Node3D, size: Vector3, centre: Vector3) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	world.add_child(body)
	body.global_position = centre
