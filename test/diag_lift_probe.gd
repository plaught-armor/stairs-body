extends Node3D

## Why can a character not climb a staircase that is riding a descending lift?
##
##     godot --headless --path <repo root> res://test/diag_lift_probe.tscn
##
## diag_platform_stairs.gd establishes the failure and stops there: a staircase on
## a lift descending at 1 m/s is never climbed, while the same flight at rest or
## rising is. The character stays grounded on every frame, so it is not the
## `grounded` guard at the top of stair_step_up, and the horizontal platform carry
## that fixed the sliding case is zero here by construction, so nothing in that fix
## applies either.
##
## This walks that exact scenario to the stall, counts what the addon does on every
## frame, and then replays stair_step_up's four sweeps by hand on the stalled
## frame, printing what each one sees.
##
## The replay is deliberately a copy rather than a call into the addon: the addon
## bails at the first sweep that says no, and what we want is what the LATER sweeps
## would have seen had it not. Keep it in step with stair_step_up if that changes.
##
## RESULT, before the fix, and it was none of the sweeps:
##
##     as shipped   sweep1 hit at 90.0 deg  rose 0.3300  forward 0.0492
##                  would step up +0.1999 m
##     the frames   47 step-ups and 47 step-downs in 60, gaining 0.00 m
##     the same, with gravity reset on the ground    47 and 47, 0.00 m
##     the same, with the horizontal seated          4 ups, 0 downs, 0.80 m
##
## Read in that order: every sweep succeeded and the check committed a real 0.20 m
## step, on every single frame, and every single one was given back. The unbounded
## velocity.y the first run shows (-7.68 by frame 60) is a SYMPTOM - the body is
## lifted clear of the deck each frame and never lands to have gravity cancelled -
## and the second run proves it, because resetting gravity on the ground changes
## nothing at all.
##
## The third run is the answer. stair_step_up commits Y alone in the common case and
## leaves the horizontal to move_and_slide, and move_and_slide applies the FLOOR's
## displacement as a move of its own before the character's. So on a descending lift
## the body - committed at tread height, footprint still behind the lip - was dropped
## a frame of lift travel below that lip before it moved forward at all, and the
## forward move then met the step face side-on and slid back down. Seating the
## horizontal in the commit sidesteps it entirely: 0.80 m, four steps, no snap-downs.
##
## The shipped fix is the other half of the same observation, and cheaper: carry the
## vertical too and net it off at the commit, so the body is committed one carry high
## and the platform push lands it exactly on the lip - where a static floor has it,
## and where the ordinary forward move clears as it always did.
##
## Run it today and every row climbs, so the numbers above are the record rather
## than the output: 0.60 m in 60 frames on the descending lift, four step-ups and
## one snap-down, and a stalled frame to interrogate no longer exists - the replay
## reports sweep1 MISS because the character has walked off the end of the flight
## by then. To watch the failure again, take the vertical half of platform_carry
## back out of stair_step_up.
##
## The hypotheses this was built to test, kept because they are the ones it ruled
## out: that the sweeps were aimed at geometry the lift had already moved (the
## node and the server agree to 0.0000 m, and the offset replay reports the same
## +0.1999 m step as the un-offset one), and that the stale-ness landed on one
## specific stage - the rise, the forward leg, the set-down or the height-gain
## check. Every stage prints, and every stage was fine.

const LIFT_SPEED: float = -1.0
const WALK: float = 3.0

const STEPS: int = 4
const STEP_RISE: float = 0.2
const STEP_RUN: float = 0.8
const STEP_FACE_X: float = 1.0

const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001
const GRAVITY: float = 9.8
const DELTA: float = 1.0 / 60.0
const SETTLE_FRAMES: int = 20
const WALK_FRAMES: int = 60
## How many of the last walk frames to print. The stall repeats, so a handful is
## the whole of it.
const TAIL_FRAMES: int = 5

## What stair_step_up would probe with on the stalled frame: the walk, one tick.
const PROBE: Vector3 = Vector3(WALK * DELTA, 0.0, 0.0)

var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()

# Members rather than captures, because a lambda captures a local by value and
# these are counted from inside the walk loop (H6).
var _ups: int = 0
var _downs: int = 0


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	print("--- interrogating a stalled frame on a descending lift ---")
	await _probe(LIFT_SPEED, false)
	# The control. Same geometry, same walk, a lift that is not moving - so any
	# stage that reports differently below is reporting on the motion rather than
	# on the staircase.
	await _probe(0.0, false)
	# The same descending lift under the controller shape every real one has:
	# gravity only while airborne. The harness above accumulates it unconditionally,
	# which is what diag_platform_stairs.gd does, and if that is what the stall
	# needs then the failure is the harness rather than the addon.
	await _probe(LIFT_SPEED, true)
	# The step is committed Y-only and move_and_slide is trusted to carry the body
	# forward over the lip. Declaring an intent larger than the velocity is the one
	# lever the public API has to make stair_step_up seat the horizontal itself, so
	# this run says whether the missing forward seat is the whole failure - without
	# touching the addon to find out.
	await _probe(LIFT_SPEED, false, 1.2)
	get_tree().quit(0)


## `intent_scale` multiplies desired_velocity against the velocity actually set,
## so anything above 1 makes intent the stronger signal and flips the addon onto
## the path that commits X and Z as well as Y.
func _probe(lift_speed: float, reset_gravity_when_grounded: bool, intent_scale: float = 1.0) -> void:
	print(
		(
			"lift %+.1f m/s, gravity reset on the ground: %s, intent x%.1f"
			% [lift_speed, reset_gravity_when_grounded, intent_scale]
		)
	)

	var world: Node3D = Node3D.new()
	add_child(world)

	# The same flight diag_platform_stairs.gd rides, so the stall reproduced here
	# is the one recorded there rather than a lookalike.
	var platform: AnimatableBody3D = AnimatableBody3D.new()
	_shape(platform, Vector3(30.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	for i: int in STEPS:
		var top: float = STEP_RISE * float(i + 1)
		var length: float = STEP_RUN * float(STEPS - i) + 6.0
		var centre_x: float = STEP_FACE_X + STEP_RUN * float(i) + length * 0.5
		_shape(platform, Vector3(length, 2.0, 8.0), Vector3(centre_x, top - 1.0, 0.0))
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

	# Signals rather than positions, because the two answer different questions: a
	# frame can commit a step and lose it again to the move that follows, and only
	# the signal says the check got that far.
	_ups = 0
	_downs = 0
	c.stepped_up.connect(_count_up)
	c.stepped_down.connect(_count_down)

	# Relative to the platform, for the reason diag_platform_stairs.gd gives: the
	# absolute number rides the lift and says nothing about climbing.
	var start_gap: float = c.global_position.y - platform.global_position.y

	for i: int in WALK_FRAMES:
		await get_tree().physics_frame
		platform.global_position.y += lift_speed * DELTA
		c.velocity.x = WALK
		if reset_gravity_when_grounded and c.is_on_floor():
			c.velocity.y = 0.0
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(WALK * intent_scale, 0.0, 0.0)

		var before_ups: int = _ups
		var before_downs: int = _downs
		var before: Vector3 = c.global_position - platform.global_position
		c.move_and_stair_step()
		var after: Vector3 = c.global_position - platform.global_position

		# Only the tail, and only once the stall has settled - the interesting frames
		# are the ones that repeat forever, not the approach.
		if i >= WALK_FRAMES - TAIL_FRAMES:
			print(
				(
					"  frame %d: relative x %.4f y %.4f -> x %.4f y %.4f, up %d down %d, "
					% [
						i,
						before.x,
						before.y,
						after.x,
						after.y,
						_ups - before_ups,
						_downs - before_downs,
					]
					+ "grounded %s, velocity y %.3f" % [c.is_on_floor(), c.velocity.y]
				)
			)

	print(
		(
			"  gained %.2f m on the platform, %d step-ups and %d step-downs across %d frames"
			% [
				(c.global_position.y - platform.global_position.y) - start_gap,
				_ups,
				_downs,
				WALK_FRAMES,
			]
		)
	)

	var relative: Vector3 = c.global_position - platform.global_position
	print(
		(
			"  parked at relative %v, the face is at x %.4f, the tread at y %.4f"
			% [relative, STEP_FACE_X - BODY_RADIUS, REST_Y + STEP_RISE]
		)
	)
	print(
		(
			"  grounded %s, platform velocity %v, own velocity %v"
			% [c.is_on_floor(), c.get_platform_velocity(), c.velocity]
		)
	)

	# Hypothesis 3 - does the server agree with the node about where the lift is?
	var server: Transform3D = PhysicsServer3D.body_get_state(
		platform.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM,
	)
	print(
		(
			"  node y %.4f, server y %.4f, lag %.4f m (a frame at %.1f m/s is %.4f)"
			% [
				platform.global_position.y,
				server.origin.y,
				platform.global_position.y - server.origin.y,
				lift_speed,
				absf(lift_speed) * DELTA,
			]
		)
	)

	_params.margin = COLLIDER_MARGIN
	_params.recovery_as_collision = false

	# Hypothesis 1 and 2 - replay the four sweeps, first from where the body
	# actually is (what the addon does today) and then from where the lift is about
	# to put it. If the second climbs and the first does not, the stale-ness is the
	# whole story and it is vertical rather than horizontal.
	_trace(c, "  as shipped (no carry)   ", Vector3.ZERO)
	_trace(c, "  offset by the lift carry", Vector3(0.0, lift_speed * DELTA, 0.0))

	world.queue_free()
	await get_tree().process_frame


## stair_step_up's sweep chain, replayed stage by stage and printed rather than
## bailed out of. `carry` offsets the start the way the shipped horizontal carry
## does, so the two calls above differ only in where the sweeps begin.
func _trace(c: StairsCharacter, label: String, carry: Vector3) -> void:
	var start: Transform3D = c.global_transform.translated(carry)
	var motion_transform: Transform3D = start

	# Sweep 1 - is there anything in front of us, and is it too steep to walk up?
	_params.from = motion_transform
	_params.motion = PROBE
	if not PhysicsServer3D.body_test_motion(c.get_rid(), _params, _result):
		print("%s sweep1 MISS (nothing within %.4f m)" % [label, PROBE.x])
		return
	var normal: Vector3 = _result.get_collision_normal(0)
	var angle: float = normal.angle_to(Vector3.UP)
	if angle <= c.floor_max_angle:
		print(
			(
				"%s sweep1 hit a WALKABLE face, normal %v at %.1f deg - handed to move_and_slide"
				% [label, normal, rad_to_deg(angle)]
			)
		)
		return
	var remainder: Vector3 = _result.get_remainder()
	motion_transform = motion_transform.translated(_result.get_travel())
	print(
		(
			"%s sweep1 hit at %.1f deg, travel %.4f, remainder %.4f"
			% [label, rad_to_deg(angle), _result.get_travel().length(), remainder.length()]
		)
	)

	# Sweep 2 - the rise.
	_params.from = motion_transform
	_params.motion = c.step_height * Vector3.UP
	PhysicsServer3D.body_test_motion(c.get_rid(), _params, _result)
	var rise: Vector3 = _result.get_travel()
	motion_transform = motion_transform.translated(rise)
	if rise.length() < _params.margin:
		print("%s   rise BLOCKED at %.4f m (a ceiling)" % [label, rise.length()])
		return
	print("%s   rose %.4f of %.4f" % [label, rise.length(), c.step_height])

	# Sweep 3 - the forward leg, with the same floor and the same slide loop.
	var forward_motion: Vector3 = remainder
	if forward_motion.length() < c.min_step_forward:
		forward_motion = PROBE.normalized() * c.min_step_forward
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
		forward_motion = _result.get_remainder().slide(_result.get_collision_normal(0)) * Vector3(
			1,
			0,
			1,
		)
		if forward_motion.length() < _params.margin:
			break
	if forward_travel.length() < _params.margin:
		print("%s   forward leg BLOCKED, travelled %.4f" % [label, forward_travel.length()])
		return
	print("%s   forward %.4f" % [label, forward_travel.length()])

	# Sweep 4 - set the body back down, no further than it rose.
	_params.from = motion_transform
	_params.motion = Vector3.DOWN * rise.length()
	if not PhysicsServer3D.body_test_motion(c.get_rid(), _params, _result):
		print("%s   set-down found NOTHING within %.4f m" % [label, rise.length()])
		return
	motion_transform = motion_transform.translated(_result.get_travel())
	var landing: Vector3 = _result.get_collision_normal(0)
	if landing.angle_to(Vector3.UP) > c.floor_max_angle:
		print("%s   landing too STEEP, normal %v" % [label, landing])
		return

	# The last check Jolt makes, and the one that decides whether any of this was
	# a step. Measured against the body's real Y rather than the offset start,
	# exactly as the addon does it.
	var gain: float = motion_transform.origin.y - c.global_position.y
	if gain < _params.margin:
		print(
			"%s   NO HEIGHT GAINED: %+.4f m, under the %.4f margin" % [label, gain, _params.margin]
		)
		return
	print("%s   would step up %+.4f m" % [label, gain])


func _count_up() -> void:
	_ups += 1


func _count_down() -> void:
	_downs += 1


func _shape(body: PhysicsBody3D, size: Vector3, centre: Vector3) -> void:
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	shape_node.position = centre
	body.add_child(shape_node)
