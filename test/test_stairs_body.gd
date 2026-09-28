extends Node3D

## Headless cases for StairsBody's own machinery: the tunnel guard, the refusal
## cache, the loose-step rule and the rest that test_stairs.gd's cases, which
## began as the old StairsCharacter's, were never written to reach.
##
##     godot --headless --path <repo root> res://test/test_stairs_body.tscn
##
## Exit code is the number of failed cases. `print` is the harness output.

const DELTA: float = 1.0 / 60.0
const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001
const GRAVITY: float = 9.8
const EPS: float = 0.05
## A tick rate whose frames move a slow walk less than a margin, and less than the
## gap Jolt leaves at a face (4.2 mm).
const HIGH_RATE: int = 240
const SLOW_WALK: float = 0.2
const STEP_TOP: float = 0.2
const CROWD_LAYER: int = 32
## How far crowd footprints may end from exactly touching, or a crowd body past a
## wall face, in metres.
const CROWD_TOLERANCE: float = 0.005

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	call_deferred(&"_run_all")


func _run_all() -> void:
	print("--- StairsBody own-machinery run ---")
	await _case_b01_a_fall_past_a_ledge_edge_does_not_end_inside_the_floor()
	await _case_b02_a_slow_walk_at_a_high_tick_rate_moves()
	await _case_b03_a_slow_walk_at_a_high_tick_rate_climbs()
	await _case_b04_a_zero_forward_floor_stalls_the_slow_climb_under_jolt()
	await _case_b05_a_step_refused_for_leftover_travel_is_not_remembered()
	await _case_b07_a_freed_floor_is_let_go()
	await _case_b08_intent_off_the_motion_does_not_steer_the_body()
	await _case_b09_held_against_a_wall_is_on_the_wall()
	await _case_b10_a_loose_crate_is_not_stepped_onto()
	await _case_b11_a_frozen_crate_is_stepped_onto()
	await _case_b12_a_walk_down_a_flight_steps_every_tread()
	await _case_b13_a_step_lands_through_an_ignored_body()
	await _case_b14_a_walk_into_a_wall_lists_the_wall_and_the_floor()
	await _case_b15_held_against_a_wall_lists_the_wall()
	await _case_b16_a_refused_step_lists_none_of_its_sweeps()
	await _case_b17_a_pole_clipped_in_passing_is_listed()
	await _case_b18_a_floor_on_an_ignored_layer_is_never_ridden()
	await _case_b19_a_step_up_is_never_followed_by_a_false_step_down()
	await _case_b20_a_step_onto_a_rounded_nosing_never_launches_the_body()
	await _case_b21_standing_on_an_ignored_body_stays_on_the_floor()
	await _case_b22_a_resting_body_wakes_when_its_floor_or_place_changes()
	await _case_b25_a_resting_body_lists_what_moves_into_it()
	await _case_b23_crowd_bodies_walking_head_on_stop_touching()
	await _case_b24_a_crowd_push_never_shoves_a_body_into_a_wall()
	await _case_b26_a_crowd_member_freed_or_added_mid_frame_is_skipped()
	await _case_b27_a_resting_body_wakes_only_for_a_walker_that_can_enter_it()
	await _case_b28_a_body_set_into_the_floor_comes_out_before_resting()
	await _case_b29_a_resting_body_is_checked_again_when_its_collider_changes()
	await _case_b30_crowd_overlap_under_the_slop_is_left_alone()
	await _case_b31_held_still_at_a_step_with_intent_into_it_climbs()
	print("--- %d passed, %d failed ---" % [_passed, _failed])
	get_tree().quit(_failed)


func _check(case_name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
		print("PASS  %s" % case_name)
	else:
		_failed += 1
		print("FAIL  %s — %s" % [case_name, detail])


func _new_world() -> Node3D:
	var world: Node3D = Node3D.new()
	add_child(world)
	return world


func _add_box(world: Node3D, size: Vector3, centre: Vector3) -> StaticBody3D:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	world.add_child(body)
	body.global_position = centre
	return body


func _is_jolt() -> bool:
	return ProjectSettings.get_setting("physics/3d/physics_engine") == "Jolt Physics"


## Flat ground, and when `with_step` a step whose face is at x = 1.0 and top at
## STEP_TOP. The body starts at x = 0.4 and settles there before it walks.
func _slow_walk_world(with_step: bool) -> Node3D:
	var world: Node3D = _new_world()
	_add_box(world, Vector3(11.0, 1.0, 8.0), Vector3(-4.5, -0.5, 0.0))
	if with_step:
		_add_box(world, Vector3(4.0, 2.0, 8.0), Vector3(3.0, STEP_TOP - 1.0, 0.0))
	return world


## Settles `c`, then walks it along +x at `speed` for `seconds` at HIGH_RATE.
func _slow_walk(c: StairsBody, seconds: float, speed: float = SLOW_WALK) -> void:
	var delta: float = 1.0 / float(HIGH_RATE)
	for _i: int in HIGH_RATE / 4:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * delta
		c.move_and_stair_step()
	for _i: int in int(seconds * float(HIGH_RATE)):
		await get_tree().physics_frame
		c.velocity.x = speed
		c.velocity.y -= GRAVITY * delta
		c.desired_velocity = Vector3(speed, 0.0, 0.0)
		c.move_and_stair_step()


func _add_body(world: Node3D, at: Vector3, c: StairsBody = StairsBody.new()) -> StairsBody:
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cylinder: CylinderShape3D = CylinderShape3D.new()
	cylinder.radius = BODY_RADIUS
	cylinder.height = BODY_HEIGHT
	cylinder.margin = COLLIDER_MARGIN
	shape_node.shape = cylinder
	c.add_child(shape_node)
	world.add_child(c)
	c.global_position = at
	return c


## Jolt's body_test_motion can report no collision and the full motion as travel
## when its cast stopped on a contact its own motion-direction filter then threw
## away. Measured: a cylinder whose rim sits 10 um past a ledge edge, moved 0.33 m
## straight down, ends 0.13 m inside the floor 0.2 m below. x = 2.29999 over an
## edge at 2.0 is one such spot; its neighbours either side are not.
##
## The fall is one frame at 19.8 m/s so the move sweep is exactly that 0.33 m. The
## raw sweep is reported alongside, so a run shows whether this engine tunnels at
## all - under Godot Physics it does not, and the case passes without the guard
## having anything to do.
func _case_b01_a_fall_past_a_ledge_edge_does_not_end_inside_the_floor() -> void:
	const START: Vector3 = Vector3(2.29999, 0.900074, 0.0)
	const DROP: float = 0.33
	const LOWER_TOP: float = -0.2

	var world: Node3D = _new_world()
	_add_box(world, Vector3(12.0, 1.0, 8.0), Vector3(-4.0, -0.5, 0.0))
	_add_box(world, Vector3(10.0, 1.0, 8.0), Vector3(7.0, LOWER_TOP - 0.5, 0.0))
	var c: StairsBody = _add_body(world, START)
	await get_tree().physics_frame

	var params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
	var result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
	params.margin = COLLIDER_MARGIN
	params.from = Transform3D(Basis.IDENTITY, START)
	params.motion = Vector3.DOWN * DROP
	var raw_hit: bool = PhysicsServer3D.body_test_motion(c.get_rid(), params, result)
	var raw_bottom: float = START.y - REST_Y + result.get_travel().y

	c.global_position = START
	c.velocity = Vector3.DOWN * (DROP / DELTA)
	c.move_and_stair_step()

	# Landing on the lower floor, or stopped short above it, is fine. Ending below
	# it is the tunnel; ending shoved sideways is depenetration taken as a repair.
	var bottom: float = c.global_position.y - REST_Y
	var shove: float = absf(c.global_position.x - START.x) + absf(c.global_position.z)
	_check(
		"b01 a fall past a ledge edge does not end inside the floor",
		bottom >= LOWER_TOP - 0.01 and shove < 0.05,
		(
			"body bottom at %.4f, floor top at %.2f, moved %.4f sideways (raw sweep: hit=%s, bottom %.4f)"
			% [bottom, LOWER_TOP, shove, raw_hit, raw_bottom]
		),
	)
	print("      raw sweep here: hit=%s, bottom ends at %.4f" % [raw_hit, raw_bottom])
	world.queue_free()


## At 240 Hz a 0.2 m/s walk moves 0.83 mm a frame, under the collision margin. The
## move loop once treated any sweep that short as nothing left to do, and the body
## stood still. min_step_forward is zeroed so the step probe does not stretch the
## sweep past the margin and hide it.
func _case_b02_a_slow_walk_at_a_high_tick_rate_moves() -> void:
	const SECONDS: float = 1.0
	var original_rate: int = Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = HIGH_RATE
	var world: Node3D = _slow_walk_world(false)
	var c: StairsBody = _add_body(world, Vector3(0.4, REST_Y, 0.0))
	c.min_step_forward = 0.0
	await _slow_walk(c, SECONDS)
	Engine.physics_ticks_per_second = original_rate

	var moved: float = c.global_position.x - 0.4
	_check(
		"b02 a slow walk at a high tick rate moves",
		absf(moved - SLOW_WALK * SECONDS) < EPS,
		"moved %.4f m in %.1f s at %.1f m/s" % [moved, SECONDS, SLOW_WALK],
	)
	world.queue_free()


## The same slow walk into a step. A frame's travel is shorter than the gap Jolt
## leaves at a face, so without min_step_forward the move sweep never reaches the
## face and nothing triggers a step. b04 is the control.
func _case_b03_a_slow_walk_at_a_high_tick_rate_climbs() -> void:
	var original_rate: int = Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = HIGH_RATE
	var world: Node3D = _slow_walk_world(true)
	var c: StairsBody = _add_body(world, Vector3(0.4, REST_Y, 0.0))
	await _slow_walk(c, 4.0)
	Engine.physics_ticks_per_second = original_rate

	_check(
		"b03 a slow walk at a high tick rate climbs",
		absf(c.global_position.y - (REST_Y + STEP_TOP)) < EPS,
		"pos=%v, expected to be up on the step" % c.global_position,
	)
	world.queue_free()


## Control for b03: with min_step_forward zeroed, Jolt stalls at the face, so b03
## climbs because of min_step_forward. Godot Physics leaves a 0.15 mm gap, which a
## slow frame still crosses, so there is nothing to control for and it is skipped.
func _case_b04_a_zero_forward_floor_stalls_the_slow_climb_under_jolt() -> void:
	const CASE_NAME: String = "b04 a zero forward floor stalls the slow climb under Jolt"
	if not _is_jolt():
		print("SKIP  %s — Jolt only" % CASE_NAME)
		return
	var original_rate: int = Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = HIGH_RATE
	var world: Node3D = _slow_walk_world(true)
	var c: StairsBody = _add_body(world, Vector3(0.4, REST_Y, 0.0))
	c.min_step_forward = 0.0
	await _slow_walk(c, 4.0)
	Engine.physics_ticks_per_second = original_rate

	_check(
		CASE_NAME,
		absf(c.global_position.y - REST_Y) < EPS,
		(
			"pos=%v climbed with min_step_forward at zero, so b03 is passing for some"
			% c.global_position
			+ " other reason and min_step_forward is not wired"
		),
	)
	world.queue_free()


## The frame that first meets the face has only its leftover travel for the step's
## forward leg; with min_step_forward zeroed that is under a margin, and the step
## is refused. The refusal cache once kept that, and every later frame from the
## same spot hit the cache instead of trying with a full frame's travel. Measured
## stuck under Godot Physics, which stops the body 0.15 mm from the face. Jolt
## stops it 4.2 mm off, leaves more than a margin over, and steps on first contact,
## so there is no refusal to set up and the case is skipped.
func _case_b05_a_step_refused_for_leftover_travel_is_not_remembered() -> void:
	const CASE_NAME: String = "b05 a step refused for leftover travel is not remembered"
	const WALK: float = 3.0
	if _is_jolt():
		print("SKIP  %s — Godot Physics only" % CASE_NAME)
		return
	var original_rate: int = Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = HIGH_RATE
	var world: Node3D = _slow_walk_world(true)
	var c: StairsBody = _add_body(world, Vector3(0.4, REST_Y, 0.0))
	c.min_step_forward = 0.0
	# The premise, recorded so a green run shows it held: the frame that first meets
	# the face does not step, and a later one does.
	# [frame, frame of the first step up]: a lambda captures locals by value, so the
	# handler writes through a shared array. Not packed: a Packed*Array is copied on
	# write, so the handler's writes would never reach this one.
	var frames: Array[int] = [0, -1] # gdlint: ignore[S6]
	var first_contact: int = -1
	c.stepped_up.connect(
		func(_rise: float) -> void:
			if frames[1] < 0:
				frames[1] = frames[0],
	)
	var delta: float = 1.0 / float(HIGH_RATE)
	for _i: int in HIGH_RATE / 4:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * delta
		c.move_and_stair_step()
	for i: int in HIGH_RATE / 2:
		await get_tree().physics_frame
		frames[0] = i
		c.velocity.x = WALK
		c.velocity.y -= GRAVITY * delta
		c.desired_velocity = Vector3(WALK, 0.0, 0.0)
		c.move_and_stair_step()
		if first_contact < 0 and (c.is_on_wall() or frames[1] >= 0):
			first_contact = i
	Engine.physics_ticks_per_second = original_rate
	var stepped_at: int = frames[1]

	var refused_first: bool = first_contact >= 0 and stepped_at > first_contact
	_check(
		CASE_NAME,
		refused_first and c.global_position.y > REST_Y + STEP_TOP - EPS,
		(
			"pos=%v, first contact on frame %d, stepped on frame %d - expected a refusal at"
			% [c.global_position, first_contact, stepped_at]
			+ " first contact and the body up on the step after it"
		),
	)
	world.queue_free()


## A freed body's RID stays non-zero, and the physics server reads a freed RID as
## a static body, so a floor kept by RID alone was never let go: every frame after
## the platform died asked the server about it again. Measured by the engine errors
## those calls raise.
func _case_b07_a_freed_floor_is_let_go() -> void:
	const PLATFORM_SPEED: float = 5.0
	var world: Node3D = _new_world()
	_add_box(world, Vector3(40.0, 1.0, 8.0), Vector3(0.0, -3.5, 0.0))
	var platform: AnimatableBody3D = AnimatableBody3D.new()
	var platform_shape: CollisionShape3D = CollisionShape3D.new()
	var platform_box: BoxShape3D = BoxShape3D.new()
	platform_box.size = Vector3(40.0, 1.0, 8.0)
	platform_shape.shape = platform_box
	platform.add_child(platform_shape)
	world.add_child(platform)
	platform.global_position = Vector3(0.0, -0.5, 0.0)
	var c: StairsBody = _add_body(world, Vector3(0.0, REST_Y, 0.0))
	for _i: int in 30:
		await get_tree().physics_frame
		platform.global_position.x += PLATFORM_SPEED * DELTA
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	var rode: bool = c.is_on_floor() and c.get_platform_velocity().length() > 1.0

	var counter: ErrorCounter = ErrorCounter.new()
	OS.add_logger(counter)
	platform.free()
	for _i: int in 30:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	OS.remove_logger(counter)

	_check(
		"b07 a freed floor is let go",
		rode and counter.errors == 0,
		"rode=%s, %d engine errors after the floor was freed" % [rode, counter.errors],
	)
	world.queue_free()


## At a slow walk the step probe is stretched to min_step_forward, and when intent
## is the longer vector it is stretched along intent. Its sweep then runs off the
## frame's motion, and taking its travel as the body's once moved the body along
## intent - here into a wall it was walking beside, rather than along it.
func _case_b08_intent_off_the_motion_does_not_steer_the_body() -> void:
	const ALONG: float = 0.3
	const WALL_GAP: float = 0.01
	const SECONDS: float = 0.5
	var original_rate: int = Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = HIGH_RATE
	var delta: float = 1.0 / float(HIGH_RATE)
	var world: Node3D = _slow_walk_world(false)
	# A wall too tall to step, its face WALL_GAP past the body's side.
	_add_box(world, Vector3(1.0, 4.0, 8.0), Vector3(BODY_RADIUS + WALL_GAP + 0.5, 2.0, 0.0))
	var c: StairsBody = _add_body(world, Vector3(0.0, REST_Y, 0.0))
	for _i: int in HIGH_RATE / 4:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * delta
		c.move_and_stair_step()
	var start: Vector3 = c.global_position
	for _i: int in int(SECONDS * float(HIGH_RATE)):
		await get_tree().physics_frame
		c.velocity = Vector3(0.0, c.velocity.y - GRAVITY * delta, ALONG)
		c.desired_velocity = Vector3(3.0, 0.0, 0.0)
		c.move_and_stair_step()
	Engine.physics_ticks_per_second = original_rate

	var moved: Vector3 = c.global_position - start
	_check(
		"b08 intent off the motion does not steer the body",
		absf(moved.x) < 0.001 and absf(moved.z - ALONG * SECONDS) < EPS,
		"moved %v, expected %.3f along z and nothing along x" % [moved, ALONG * SECONDS],
	)
	world.queue_free()


## Held still against a wall it cannot step - velocity zero, intent into the wall -
## the body is on that wall. The frame has no motion, so the only sweep is the
## step probe along intent, and that sweep has to report the wall.
func _case_b09_held_against_a_wall_is_on_the_wall() -> void:
	var world: Node3D = _slow_walk_world(false)
	_add_box(world, Vector3(1.0, 4.0, 8.0), Vector3(BODY_RADIUS + 0.5, 2.0, 0.0))
	var c: StairsBody = _add_body(world, Vector3(0.0, REST_Y, 0.0))
	for _i: int in 15:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	for _i: int in 30:
		await get_tree().physics_frame
		c.velocity = Vector3(0.0, c.velocity.y - GRAVITY * DELTA, 0.0)
		c.desired_velocity = Vector3(3.0, 0.0, 0.0)
		c.move_and_stair_step()

	_check(
		"b09 held against a wall is on the wall",
		c.is_on_wall() and c.get_wall_normal().dot(Vector3.LEFT) > 0.9,
		"is_on_wall=%s wall_normal=%v" % [c.is_on_wall(), c.get_wall_normal()],
	)
	world.queue_free()


## Walks the body at a crate 0.3 m tall - inside step_height - for two seconds and
## returns the most it rose. The crate is simulating unless `frozen`.
func _walk_into_crate(frozen: bool) -> float:
	const CRATE: Vector3 = Vector3(0.45, 0.3, 0.45)
	var world: Node3D = _new_world()
	_add_box(world, Vector3(40.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	var crate: RigidBody3D = RigidBody3D.new()
	var crate_shape: CollisionShape3D = CollisionShape3D.new()
	var crate_box: BoxShape3D = BoxShape3D.new()
	crate_box.size = CRATE
	crate_shape.shape = crate_box
	crate.add_child(crate_shape)
	crate.mass = 10.0
	crate.freeze = frozen
	world.add_child(crate)
	crate.global_position = Vector3(1.5, CRATE.y * 0.5, 0.0)
	var c: StairsBody = _add_body(world, Vector3(0.0, REST_Y, 0.0))
	for _i: int in 30:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	var base: float = c.global_position.y
	var rise: float = 0.0
	for _i: int in 120:
		await get_tree().physics_frame
		c.velocity = Vector3(3.0, c.velocity.y - GRAVITY * DELTA, 0.0)
		c.move_and_stair_step()
		rise = maxf(rise, c.global_position.y - base)
	if crate.global_position.y < 0.0:
		push_error("[b10/b11] the crate fell out of the world - the lane measures nothing")
		rise = -1.0
	world.queue_free()
	return rise


## A step is a teleport, so committing one onto a simulating body leaves the solver
## to separate them by moving the body underneath - which rises and offers the next
## frame another step. Measured under Jolt before the refusal, with this crate
## dropped from 5 cm up: it lifted the body 1.085 m and left at 5.6 m/s. Resting as
## here, both engines just climb it - still a step onto something that can move out
## from under the body. b11 is the control.
func _case_b10_a_loose_crate_is_not_stepped_onto() -> void:
	var rise: float = await _walk_into_crate(false)
	_check(
		"b10 a loose crate is not stepped onto",
		rise >= 0.0 and rise < 0.05,
		"rose %.3f m walking into a simulating crate 0.3 m tall" % rise,
	)


## The same crate frozen is static to the physics server, and a stair like any other.
func _case_b11_a_frozen_crate_is_stepped_onto() -> void:
	var rise: float = await _walk_into_crate(true)
	_check(
		"b11 a frozen crate is stepped onto",
		absf(rise - 0.3) < EPS,
		"rose %.3f m walking onto a frozen crate 0.3 m tall" % rise,
	)


## Walking off a tread, a flat bottom's trailing rim can drop onto the curve Jolt
## rounds a box's top edge with (its margin, 0.04 m by default here) and read a
## steep normal a few millimetres down. Measured before _probe_off_corner, with
## a game's player cylinder: airborne on 3 of 16 treads at walk speed, falling
## across them. Where a rim meets an edge is chaotic in speed and radius, so the
## lanes are that game's four speeds with its player's collider. Without the fix the
## three slower lanes fail; the sprint lane never meets a curve and is a control.
## A shift of one margin instead of the curve's depth fails the same three. Godot
## Physics has square edges, and passes without the fix.
func _case_b12_a_walk_down_a_flight_steps_every_tread() -> void:
	const TREADS: int = 16
	const RISE: float = 0.25
	const GOING: float = 0.28
	var speeds: PackedFloat32Array = [0.818, 1.944, 3.828, 5.687]
	const LANE_GAP: float = 2.0
	var world: Node3D = _new_world()
	var width: float = LANE_GAP * speeds.size()
	# Long enough that the fastest lane is still on it after the last frame.
	_add_box(world, Vector3(width, 1.0, 40.0), Vector3(0.0, -0.5, -20.0))
	for i: int in TREADS:
		_add_box(
			world,
			Vector3(width, 1.0, GOING),
			Vector3(0.0, RISE * (i + 1) - 0.5, GOING * (i + 0.5)),
		)
	var top: float = RISE * TREADS
	_add_box(world, Vector3(width, 1.0, 2.0), Vector3(0.0, top - 0.5, GOING * TREADS + 1.0))
	var bodies: Array[StairsBody] = []
	var downs: PackedInt32Array = []
	var air: PackedInt32Array = []
	for lane: int in speeds.size():
		var at: Vector3 = Vector3(LANE_GAP * (lane - 1.5), top + 0.6, GOING * TREADS + 1.0)
		bodies.append(_add_player_body(world, at))
		downs.append(0)
		air.append(0)
	var counts: Array[PackedInt32Array] = [downs]
	for lane: int in bodies.size():
		bodies[lane].stepped_down.connect(
			func(_drop: float) -> void:
				counts[0][lane] += 1,
		)
	for _i: int in 40:
		await get_tree().physics_frame
		for c: StairsBody in bodies:
			c.velocity.y -= GRAVITY * DELTA
			c.move_and_stair_step()
	for _i: int in 300:
		await get_tree().physics_frame
		for lane: int in bodies.size():
			var c: StairsBody = bodies[lane]
			c.velocity = Vector3(0.0, c.velocity.y - GRAVITY * DELTA, -speeds[lane])
			c.desired_velocity = Vector3(0.0, 0.0, -speeds[lane])
			c.move_and_stair_step()
			if not c.is_on_floor():
				air[lane] += 1

	for lane: int in bodies.size():
		_check(
			"b12 a walk down a flight at %.3f m/s never leaves the floor" % speeds[lane],
			air[lane] == 0,
			"airborne %d frames, %d step downs" % [air[lane], counts[0][lane]],
		)
	world.queue_free()


## A game's player collider: origin at the feet, which is where it is measured.
func _add_player_body(world: Node3D, at: Vector3) -> StairsBody:
	var c: StairsBody = StairsBody.new()
	c.step_down_height = 0.5
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cylinder: CylinderShape3D = CylinderShape3D.new()
	cylinder.radius = 0.27
	cylinder.height = 1.75
	cylinder.margin = COLLIDER_MARGIN
	shape_node.shape = cylinder
	shape_node.position = Vector3(0.0, 0.875, 0.0)
	c.add_child(shape_node)
	world.add_child(c)
	c.global_position = at
	return c


## A body on a step_ignore_layers layer lying on a kerb's top. The step sweeps run
## with that layer out of the mask, so the down leg lands on the kerb through it;
## without the masking it lands on the ignored body and is refused. The ignored body
## is loose, as a crowd member is. Past the kerb's edge the slab still blocks the
## body, as a crowd member would, so only the climb is asserted.
func _case_b13_a_step_lands_through_an_ignored_body() -> void:
	const IGNORED_LAYER: int = 2
	const SLAB: Vector3 = Vector3(0.6, 0.05, 1.0)
	var world: Node3D = _slow_walk_world(true)
	var slab: RigidBody3D = RigidBody3D.new()
	var slab_shape: CollisionShape3D = CollisionShape3D.new()
	var slab_box: BoxShape3D = BoxShape3D.new()
	slab_box.size = SLAB
	slab_shape.shape = slab_box
	slab.add_child(slab_shape)
	slab.collision_layer = IGNORED_LAYER
	slab.collision_mask = 1 | IGNORED_LAYER
	world.add_child(slab)
	slab.global_position = Vector3(1.0 + SLAB.x * 0.5, STEP_TOP + SLAB.y * 0.5, 0.0)
	var c: StairsBody = StairsBody.new()
	c.collision_mask = 1 | IGNORED_LAYER
	c.step_ignore_layers = IGNORED_LAYER
	_add_body(world, Vector3(0.0, REST_Y, 0.0), c)
	# Shared with the handler and not packed, for the reason given in b05.
	var ups: Array[int] = [0] # gdlint: ignore[S6]
	c.stepped_up.connect(
		func(_rise: float) -> void:
			ups[0] += 1,
	)
	for _i: int in 15:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	for _i: int in 60:
		await get_tree().physics_frame
		c.velocity = Vector3(1.5, c.velocity.y - GRAVITY * DELTA, 0.0)
		c.desired_velocity = Vector3(1.5, 0.0, 0.0)
		c.move_and_stair_step()

	_check(
		"b13 a step lands through an ignored body",
		ups[0] >= 1 and absf(c.global_position.y - (STEP_TOP + REST_Y)) < EPS,
		"%d step ups, ended at %v" % [ups[0], c.global_position],
	)
	world.queue_free()


## Index of the first contact on `body` whose normal is within ~25 degrees of
## `normal`, or -1. Checks the collider, its id and the normal together.
func _find_contact(c: StairsBody, body: Node, normal: Vector3) -> int:
	for i: int in c.get_contact_count():
		if (
			c.get_contact_collider(i) == body
			and c.get_contact_collider_id(i) == body.get_instance_id()
			and c.get_contact_normal(i).dot(normal) > 0.9
		):
			return i
	return -1


## A sprint into a wall meets it on the slide sweep, and the floor comes from the
## resting contacts of the post-move test. The position is on the wall's face.
func _case_b14_a_walk_into_a_wall_lists_the_wall_and_the_floor() -> void:
	var world: Node3D = _new_world()
	var ground: StaticBody3D = _add_box(world, Vector3(20.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	var wall: StaticBody3D = _add_box(world, Vector3(1.0, 4.0, 8.0), Vector3(3.5, 2.0, 0.0))
	var c: StairsBody = _add_body(world, Vector3(0.0, REST_Y, 0.0))
	var wall_frames: int = 0
	var floor_frames: int = 0
	var face_x: float = INF
	for _i: int in 15:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	for _i: int in 45:
		await get_tree().physics_frame
		c.velocity = Vector3(8.0, c.velocity.y - GRAVITY * DELTA, 0.0)
		c.desired_velocity = Vector3(8.0, 0.0, 0.0)
		c.move_and_stair_step()
		var at_wall: int = _find_contact(c, wall, Vector3.LEFT)
		if at_wall >= 0:
			wall_frames += 1
			face_x = c.get_contact_position(at_wall).x
		if _find_contact(c, ground, Vector3.UP) >= 0:
			floor_frames += 1

	_check(
		"b14 a walk into a wall lists the wall and the floor",
		wall_frames > 0 and floor_frames == 45 and absf(face_x - 3.0) < EPS,
		"wall on %d frames, floor on %d of 45, wall contact x=%.4f expected ~3.0"
		% [wall_frames, floor_frames, face_x],
	)
	world.queue_free()


## Held against a wall with no motion - Jolt parks the body 4.2 mm off the face,
## out of reach of the resting contacts - the intent probe is what touches it.
func _case_b15_held_against_a_wall_lists_the_wall() -> void:
	var world: Node3D = _slow_walk_world(false)
	var wall: StaticBody3D = _add_box(
		world,
		Vector3(1.0, 4.0, 8.0),
		Vector3(BODY_RADIUS + 0.5, 2.0, 0.0),
	)
	var c: StairsBody = _add_body(world, Vector3(0.0, REST_Y, 0.0))
	var held_frames: int = 0
	for _i: int in 15:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	for _i: int in 30:
		await get_tree().physics_frame
		c.velocity = Vector3(0.0, c.velocity.y - GRAVITY * DELTA, 0.0)
		c.desired_velocity = Vector3(3.0, 0.0, 0.0)
		c.move_and_stair_step()
		if _find_contact(c, wall, Vector3.LEFT) >= 0:
			held_frames += 1

	_check(
		"b15 held against a wall lists the wall",
		held_frames == 30,
		"wall listed on %d of 30 frames" % held_frames,
	)
	world.queue_free()


## A step the body did not take leaves none of its sweeps in the list. A ceiling
## 0.1 m over the body's head lets the up sweep rise less than the 0.2 m step, so
## the forward leg is blocked and the step refused - and the up sweep's ceiling
## hit, the one contact only a step sweep can make here, must not be listed.
func _case_b16_a_refused_step_lists_none_of_its_sweeps() -> void:
	var world: Node3D = _slow_walk_world(true)
	var ceiling: StaticBody3D = _add_box(
		world,
		Vector3(20.0, 0.2, 8.0),
		Vector3(0.0, BODY_HEIGHT + 0.2, 0.0),
	)
	var c: StairsBody = _add_body(world, Vector3(0.0, REST_Y, 0.0))
	var face_frames: int = 0
	var ceiling_frames: int = 0
	for _i: int in 15:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	for _i: int in 60:
		await get_tree().physics_frame
		c.velocity = Vector3(3.0, c.velocity.y - GRAVITY * DELTA, 0.0)
		c.desired_velocity = Vector3(3.0, 0.0, 0.0)
		c.move_and_stair_step()
		for i: int in c.get_contact_count():
			if c.get_contact_normal(i).dot(Vector3.LEFT) > 0.9:
				face_frames += 1
			if c.get_contact_collider(i) == ceiling:
				ceiling_frames += 1

	_check(
		"b16 a refused step lists none of its sweeps",
		face_frames > 0 and ceiling_frames == 0 and absf(c.global_position.y - REST_Y) < EPS,
		"step face listed %d times, ceiling %d times, y=%.4f expected face>0, ceiling 0, y~%.2f"
		% [face_frames, ceiling_frames, c.global_position.y, REST_Y],
	)
	world.queue_free()


## A sprint that clips a thin pole slides off it within the same move and ends
## clear of it, so only the slide sweep ever touches the pole: the resting
## contacts after the move cannot list it. Measured on both engines: listed once.
func _case_b17_a_pole_clipped_in_passing_is_listed() -> void:
	var world: Node3D = _new_world()
	_add_box(world, Vector3(20.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	var pole: StaticBody3D = _add_box(world, Vector3(0.1, 4.0, 0.1), Vector3(2.0, 2.0, 0.3))
	var c: StairsBody = _add_body(world, Vector3(0.0, REST_Y, 0.0))
	var listed: int = 0
	for _i: int in 15:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	for _i: int in 40:
		await get_tree().physics_frame
		c.velocity = Vector3(8.0, c.velocity.y - GRAVITY * DELTA, c.velocity.z)
		c.desired_velocity = Vector3(8.0, 0.0, 0.0)
		c.move_and_stair_step()
		for i: int in c.get_contact_count():
			if c.get_contact_collider(i) == pole:
				listed += 1

	_check(
		"b17 a pole clipped in passing is listed",
		listed > 0 and c.global_position.x > 4.0,
		"pole listed %d times, pos=%v expected listed>0 and x>4" % [listed, c.global_position],
	)
	world.queue_free()


## Stands a rider on a StairsBody that is teleported 0.2 m back and forth every
## tick. Returns the most platform speed the rider read, and the lowest it sat once
## the teleports began. The floor body is on its own layer, which the rider
## collides with and, when `ignore`, ignores for steps.
func _ride_a_teleported_body(ignore: bool) -> PackedFloat64Array:
	const IGNORED_LAYER: int = 2
	const SETTLE: int = 20
	var world: Node3D = _slow_walk_world(false)
	var floor_body: StairsBody = StairsBody.new()
	floor_body.collision_layer = IGNORED_LAYER
	_add_body(world, Vector3(0.0, REST_Y, 0.0), floor_body)
	var rider: StairsBody = StairsBody.new()
	rider.collision_mask = 1 | IGNORED_LAYER
	if ignore:
		rider.step_ignore_layers = IGNORED_LAYER
	_add_body(world, Vector3(0.0, BODY_HEIGHT + REST_Y + 0.01, 0.0), rider)
	var peak: float = 0.0
	var lowest: float = INF
	for i: int in 60:
		await get_tree().physics_frame
		rider.velocity.y -= GRAVITY * DELTA
		rider.move_and_stair_step()
		peak = maxf(peak, rider.get_platform_velocity().length())
		if i >= SETTLE:
			lowest = minf(lowest, rider.global_position.y)
			floor_body.global_position.x += 0.2 if i % 2 == 0 else -0.2
	world.queue_free()
	return [peak, lowest]


## A teleported kinematic body reports the jump as velocity, so standing on one
## would carry the rider at that speed - measured 12 m/s here, on both engines,
## and 26-67 m/s in a game's crowds. A floor on step_ignore_layers holds the
## rider up without carrying it: both halves are checked, since a rider that fell
## through to the ground would read no platform speed either. The control proves
## the teleport is seen at all.
func _case_b18_a_floor_on_an_ignored_layer_is_never_ridden() -> void:
	var carried: PackedFloat64Array = await _ride_a_teleported_body(false)
	var ignored: PackedFloat64Array = await _ride_a_teleported_body(true)
	var held_up: bool = ignored[1] > BODY_HEIGHT + REST_Y - EPS

	_check(
		"b18 a floor on an ignored layer is never ridden",
		carried[0] > 5.0 and ignored[0] == 0.0 and held_up,
		(
			"platform speed %.2f without the ignore (expected > 5), %.2f with it (expected 0);"
			+ " lowest y with it %.4f (expected ~%.2f, on the floor body)"
		)
		% [carried[0], ignored[0], ignored[1], BODY_HEIGHT + REST_Y],
	)


## A game's player running a flight: a 0.27 x 1.75 m cylinder at 3.83 m/s up
## 0.25 m rises on 0.5 m goings. Under Jolt, whose box edges are rounded by their
## margin, a step can land with only the rim over the nosing and read a tilted
## normal; followed as a slope, it lifted the body and the probe dropped it back,
## a step down reported on a tick the body rose. Measured once in 90 ticks here.
func _case_b19_a_step_up_is_never_followed_by_a_false_step_down() -> void:
	const RISE: float = 0.25
	const GOING: float = 0.5
	const TREADS: int = 8
	const SPEED: float = 3.83
	var world: Node3D = _new_world()
	_add_box(world, Vector3(20.0, 1.0, 8.0), Vector3(-8.0, -0.5, 0.0))
	for k: int in TREADS:
		var top: float = RISE * float(k + 1)
		_add_box(
			world,
			Vector3(GOING, top, 8.0),
			Vector3(2.0 + GOING * (float(k) + 0.5), top * 0.5, 0.0),
		)
	var c: StairsBody = _add_player_body(world, Vector3.ZERO)
	var drops: PackedInt32Array = [0]
	c.stepped_down.connect(
		func(_drop: float) -> void:
			drops[0] += 1,
	)
	for _i: int in 15:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	var false_drops: int = 0
	for _i: int in 90:
		await get_tree().physics_frame
		var before_y: float = c.global_position.y
		var before_drops: int = drops[0]
		c.velocity.x = SPEED
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(SPEED, 0.0, 0.0)
		c.move_and_stair_step()
		if drops[0] > before_drops and c.global_position.y > before_y:
			false_drops += 1
	var top_y: float = RISE * float(TREADS)

	_check(
		"b19 a step up is never followed by a false step down",
		false_drops == 0 and absf(c.global_position.y - top_y) < EPS,
		"%d step downs on ticks the body rose, y=%.4f expected ~%.3f (the top tread)"
		% [false_drops, c.global_position.y, top_y],
	)
	world.queue_free()


## A game's flight: each tread is one box from its nosing to the end of the run.
## A step can land with only 20 mm of rim over a nosing, sitting 5 mm down Jolt's
## rounded edge. A landing that recorded a level floor there sent the next move
## into the curve, whose 28 degree normal the slide turned the velocity along: a
## 1.6 m/s launch, 42 of 170 ticks in the air in that game.
func _case_b20_a_step_onto_a_rounded_nosing_never_launches_the_body() -> void:
	const RISE: float = 0.25
	const GOING: float = 0.5
	const TREADS: int = 8
	const SPEED: float = 3.83
	const RUN_END: float = 20.0
	const TICKS: int = 90
	# m/s. The launch measured 1.55; walking up the flight never rises at all.
	const MAX_UP_SPEED: float = 0.1
	var world: Node3D = _new_world()
	_add_box(world, Vector3(40.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	for k: int in TREADS:
		var top: float = RISE * float(k + 1)
		var nosing: float = 2.0 + GOING * float(k)
		_add_box(
			world,
			Vector3(RUN_END - nosing, top, 8.0),
			Vector3((nosing + RUN_END) * 0.5, top * 0.5, 0.0),
		)
	var c: StairsBody = _add_player_body(world, Vector3.ZERO)
	for _i: int in 15:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	var airborne: int = 0
	var peak_up_speed: float = 0.0
	for _i: int in TICKS:
		await get_tree().physics_frame
		c.velocity.x = SPEED
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(SPEED, 0.0, 0.0)
		c.move_and_stair_step()
		peak_up_speed = maxf(peak_up_speed, c.velocity.y)
		if not c.is_on_floor():
			airborne += 1
	var top_y: float = RISE * float(TREADS)

	_check(
		"b20 a step onto a rounded nosing never launches the body",
		airborne == 0 and peak_up_speed < MAX_UP_SPEED and absf(c.global_position.y - top_y) < EPS,
		"%d of %d ticks airborne, peak upward speed %.2f m/s, y=%.4f expected 0, ~0, ~%.3f"
		% [airborne, TICKS, peak_up_speed, c.global_position.y, top_y],
	)
	world.queue_free()


## The check after the move runs with step_ignore_layers masked out, which in a
## crowd skips depenetrating from every neighbour. A body standing on one of those
## bodies finds no floor that way, and the floor probe, masked the same, cannot
## reach past a slab taller than step_height: without the unmasked retry the body
## read airborne on every other tick, still or walking.
func _case_b21_standing_on_an_ignored_body_stays_on_the_floor() -> void:
	const IGNORED_LAYER: int = 2
	const SLAB_TOP: float = 0.5
	const SETTLE: int = 20
	const TICKS: int = 80
	var world: Node3D = _new_world()
	_add_box(world, Vector3(20.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	var slab: StaticBody3D = _add_box(
		world,
		Vector3(4.0, SLAB_TOP, 4.0),
		Vector3(0.0, SLAB_TOP * 0.5, 0.0),
	)
	slab.collision_layer = IGNORED_LAYER
	var c: StairsBody = StairsBody.new()
	c.collision_mask = 1 | IGNORED_LAYER
	c.step_ignore_layers = IGNORED_LAYER
	_add_body(world, Vector3(0.0, SLAB_TOP + REST_Y, 0.0), c)
	for _i: int in SETTLE:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	var airborne: int = 0
	for i: int in TICKS:
		await get_tree().physics_frame
		var walk: float = SLOW_WALK if i >= TICKS / 2 else 0.0
		c.velocity = Vector3(walk, c.velocity.y - GRAVITY * DELTA, 0.0)
		c.desired_velocity = Vector3(walk, 0.0, 0.0)
		c.move_and_stair_step()
		if not c.is_on_floor():
			airborne += 1

	_check(
		"b21 standing on an ignored body stays on the floor",
		airborne == 0 and absf(c.global_position.y - SLAB_TOP - REST_Y) < EPS,
		"%d of %d ticks off the floor, y=%.4f expected 0, ~%.2f"
		% [airborne, TICKS, c.global_position.y, SLAB_TOP + REST_Y],
	)
	world.queue_free()


## Ticks a still body: gravity in, no intent, as a caller holding it still does.
func _hold_still(c: StairsBody, ticks: int) -> void:
	for _i: int in ticks:
		await get_tree().physics_frame
		c.velocity = Vector3(0.0, c.velocity.y - GRAVITY * DELTA, 0.0)
		c.move_and_stair_step()


## A still body on a static floor skips its checks while nothing changes, and has
## to notice when something does: its floor moved, its floor freed, or the body
## itself moved by the caller. Without each wake the body hovered where it came to
## rest, or kept reading on the floor in mid-air.
func _case_b22_a_resting_body_wakes_when_its_floor_or_place_changes() -> void:
	const REST: int = 20
	const FOLLOW: int = 10
	const DROP: float = 0.1
	var world: Node3D = _new_world()
	var floor_box: StaticBody3D = _add_box(world, Vector3(8.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	var c: StairsBody = _add_body(world, Vector3(0.0, REST_Y, 0.0))
	await _hold_still(c, REST)
	floor_box.global_position.y -= DROP
	await _hold_still(c, FOLLOW)
	var followed_y: float = c.global_position.y

	await _hold_still(c, REST)
	c.global_position.y += 1.0
	await _hold_still(c, 1)
	var lifted_on_floor: bool = c.is_on_floor()

	world.queue_free()

	# A floor at the identity transform: a freed body's transform reads back as the
	# identity, so only the floor's object says it is gone.
	world = _new_world()
	floor_box = _add_box(world, Vector3(8.0, 1.0, 8.0), Vector3.ZERO)
	_add_box(world, Vector3(8.0, 1.0, 8.0), Vector3(0.0, -3.0, 0.0))
	c = _add_body(world, Vector3(0.0, 0.5 + REST_Y, 0.0))
	await _hold_still(c, REST)
	var counter: ErrorCounter = ErrorCounter.new()
	OS.add_logger(counter)
	floor_box.free()
	await _hold_still(c, FOLLOW)
	OS.remove_logger(counter)
	var fell: bool = not c.is_on_floor() and c.global_position.y < 0.5 + REST_Y - EPS

	_check(
		"b22 a resting body wakes when its floor or place changes",
		(
			absf(followed_y - (REST_Y - DROP)) < EPS
			and not lifted_on_floor and fell and counter.errors == 0
		),
		(
			"followed its floor to y=%.4f expected ~%.2f, on floor lifted into the air=%s,"
			+ " fell once a floor at the identity was freed=%s, %d engine errors"
		)
		% [followed_y, REST_Y - DROP, lifted_on_floor, fell, counter.errors],
	)
	world.queue_free()


## A resting body skips its checks, and something moved into it has to reach its
## contact list anyway: a game may shove its crowd by what their owner reads there.
## Here a kinematic body is teleported into it; in the game it is a walker that
## leaves the crowd's layer out of its own mask. Without the wake the list kept the
## floor alone, and the body was never shoved.
func _case_b25_a_resting_body_lists_what_moves_into_it() -> void:
	const REST: int = 20
	const OVERLAP: float = 0.05
	const SIDE: float = 0.4
	var world: Node3D = _new_world()
	_add_box(world, Vector3(8.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	var c: StairsBody = _add_body(world, Vector3(0.0, REST_Y, 0.0))
	var walker: AnimatableBody3D = AnimatableBody3D.new()
	walker.sync_to_physics = false
	var walker_shape: CollisionShape3D = CollisionShape3D.new()
	var walker_box: BoxShape3D = BoxShape3D.new()
	walker_box.size = Vector3(SIDE, SIDE, SIDE)
	walker_shape.shape = walker_box
	walker.add_child(walker_shape)
	world.add_child(walker)
	walker.global_position = Vector3(3.0, SIDE * 0.5, 0.0)
	await _hold_still(c, REST)
	walker.global_position = Vector3(BODY_RADIUS + SIDE * 0.5 - OVERLAP, SIDE * 0.5, 0.0)
	await _hold_still(c, 2)
	var listed: int = _find_contact(c, walker, Vector3.LEFT)

	_check(
		"b25 a resting body lists what moves into it",
		listed >= 0,
		"walker listed at %d of %d contacts" % [listed, c.get_contact_count()],
	)
	world.queue_free()


## A body on CROWD_LAYER that leaves that layer out of its mask and keeps apart
## from others on it by crowd separation.
func _add_crowd_body(world: Node3D, at: Vector3) -> StairsBody:
	var c: StairsBody = StairsBody.new()
	c.collision_layer = CROWD_LAYER
	c.collision_mask = 1
	c.crowd_layers = CROWD_LAYER
	return _add_body(world, at, c)


## Crowd bodies do not collide, so only separation stops two walking into each
## other: they stop with their footprints touching, never overlapping on the way,
## and each lists the other, its normal pointing back at the lister, as a physics
## contact would. They close 10 cm a tick, twice the neighbour lookahead, and
## start 7 cm past a whole number of ticks apart, so no tick lands them touching.
func _case_b23_crowd_bodies_walking_head_on_stop_touching() -> void:
	const SPEED: float = 3.0
	const TICKS: int = 90
	var world: Node3D = _new_world()
	_add_box(world, Vector3(20.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	var a: StairsBody = _add_crowd_body(world, Vector3(-1.0, REST_Y, 0.0))
	var b: StairsBody = _add_crowd_body(world, Vector3(1.07, REST_Y, 0.0))
	var closest: float = INF
	for _i: int in TICKS:
		await get_tree().physics_frame
		for pair: Array in [[a, 1.0], [b, -1.0]]:
			var c: StairsBody = pair[0]
			var walk: float = pair[1] * SPEED
			c.velocity = Vector3(walk, c.velocity.y - GRAVITY * DELTA, 0.0)
			c.desired_velocity = Vector3(walk, 0.0, 0.0)
			c.move_and_stair_step()
		closest = minf(closest, b.global_position.x - a.global_position.x)
	var apart: float = b.global_position.x - a.global_position.x
	var a_lists: int = _find_contact(a, b, Vector3.LEFT)
	var b_lists: int = _find_contact(b, a, Vector3.RIGHT)

	_check(
		"b23 crowd bodies walking head-on stop touching",
		(
			absf(apart - 2.0 * BODY_RADIUS) < CROWD_TOLERANCE
			and closest > 2.0 * BODY_RADIUS - CROWD_TOLERANCE and a_lists >= 0 and b_lists >= 0
		),
		"%.4f m apart expected %.2f, closest %.4f, a lists b at %d, b lists a at %d"
		% [apart, 2.0 * BODY_RADIUS, closest, a_lists, b_lists],
	)
	world.queue_free()


## A body left overlapping another that rests against a wall: separation pushes
## both apart, and each push is carried by its own body's next move, so it is swept
## against the world. The one at the wall stays out of it and the other takes the
## whole of the gap.
func _case_b24_a_crowd_push_never_shoves_a_body_into_a_wall() -> void:
	const OVERLAP: float = 0.2
	const REST: int = 20
	const TICKS: int = 10
	const WALL_FACE: float = 0.5
	var world: Node3D = _new_world()
	_add_box(world, Vector3(20.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	_add_box(world, Vector3(1.0, 3.0, 8.0), Vector3(WALL_FACE + 0.5, 1.5, 0.0))
	var at_wall: StairsBody = _add_crowd_body(world, Vector3(WALL_FACE - BODY_RADIUS, REST_Y, 0.0))
	await _hold_still(at_wall, REST)
	var shoved: StairsBody = _add_crowd_body(
		world,
		Vector3(WALL_FACE - 3.0 * BODY_RADIUS + OVERLAP, REST_Y, 0.0),
	)
	for _i: int in TICKS:
		await get_tree().physics_frame
		for c: StairsBody in [at_wall, shoved]:
			c.velocity = Vector3(0.0, c.velocity.y - GRAVITY * DELTA, 0.0)
			c.move_and_stair_step()
	var wall_side: float = at_wall.global_position.x + BODY_RADIUS
	var apart: float = at_wall.global_position.x - shoved.global_position.x

	_check(
		"b24 a crowd push never shoves a body into a wall",
		wall_side < WALL_FACE + CROWD_TOLERANCE and apart > 2.0 * BODY_RADIUS - CROWD_TOLERANCE,
		"side at x=%.4f against a face at %.2f, %.4f m apart expected >= %.2f"
		% [wall_side, WALL_FACE, apart, 2.0 * BODY_RADIUS],
	)
	world.queue_free()


## The crowd pass reads every member once per physics frame. A member freed after
## that, or added after it, must not be read by others moving later in the same
## frame: the freed one would be a dangling read.
func _case_b26_a_crowd_member_freed_or_added_mid_frame_is_skipped() -> void:
	const OVERLAP: float = 0.2
	const TICKS: int = 5
	var world: Node3D = _new_world()
	_add_box(world, Vector3(20.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	var stays: StairsBody = _add_crowd_body(world, Vector3(0.0, REST_Y, 0.0))
	var freed: StairsBody = _add_crowd_body(
		world,
		Vector3(2.0 * BODY_RADIUS - OVERLAP, REST_Y, 0.0),
	)
	await get_tree().physics_frame
	var counter: ErrorCounter = ErrorCounter.new()
	OS.add_logger(counter)
	stays.move_and_stair_step()
	freed.free()
	var added: StairsBody = _add_crowd_body(
		world,
		Vector3(-2.0 * BODY_RADIUS + OVERLAP, REST_Y, 0.0),
	)
	stays.move_and_stair_step()
	added.move_and_stair_step()
	for _i: int in TICKS:
		await get_tree().physics_frame
		for c: StairsBody in [stays, added]:
			c.velocity = Vector3(0.0, c.velocity.y - GRAVITY * DELTA, 0.0)
			c.move_and_stair_step()
	OS.remove_logger(counter)
	var apart: float = stays.global_position.x - added.global_position.x

	_check(
		"b26 a crowd member freed or added mid-frame is skipped",
		counter.errors == 0 and absf(apart - 2.0 * BODY_RADIUS) < CROWD_TOLERANCE,
		"%d engine errors, %.4f m apart expected %.2f" % [counter.errors, apart, 2.0 * BODY_RADIUS],
	)
	world.queue_free()


## A resting body touched only by StairsBody neighbours that collide with it stays
## at rest: they stop at its surface, so a pile of still bodies does not wake itself
## every frame. A StairsBody that leaves the body's layer out of its mask walks into
## it, and has to wake it, so that the body lists it: a game may shove a crowd that way.
func _case_b27_a_resting_body_wakes_only_for_a_walker_that_can_enter_it() -> void:
	const REST: int = 20
	const TICKS: int = 20
	const SPEED: float = 1.0
	const PILE_LAYER: int = 2
	const WALKER_LAYER: int = 64
	const GAP: float = 0.1
	var world: Node3D = _new_world()
	_add_box(world, Vector3(8.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	# c and its neighbour on a layer of their own, colliding with each other; the
	# walker leaves that layer out of its mask, as a shoving walker does.
	var c: StairsBody = StairsBody.new()
	c.collision_layer = PILE_LAYER
	c.collision_mask = 1 | PILE_LAYER | WALKER_LAYER
	_add_body(world, Vector3(0.0, REST_Y, 0.0), c)
	var neighbour: StairsBody = StairsBody.new()
	neighbour.collision_layer = PILE_LAYER
	neighbour.collision_mask = 1 | PILE_LAYER
	_add_body(world, Vector3(-2.0 * BODY_RADIUS - GAP, REST_Y, 0.0), neighbour)
	await _hold_still(c, REST)
	var rested_contacts: int = c.get_contact_count()
	# The colliding neighbour presses into c: c stays at rest, so its contacts are
	# still the ones it came to rest with.
	for _i: int in TICKS:
		await get_tree().physics_frame
		neighbour.velocity = Vector3(SPEED, neighbour.velocity.y - GRAVITY * DELTA, 0.0)
		neighbour.desired_velocity = Vector3(SPEED, 0.0, 0.0)
		neighbour.move_and_stair_step()
		c.velocity = Vector3(0.0, c.velocity.y - GRAVITY * DELTA, 0.0)
		c.move_and_stair_step()
	var kept_rest: bool = (
		c.get_contact_count() == rested_contacts and _find_contact(c, neighbour, Vector3.RIGHT) < 0
	)

	var walker: StairsBody = StairsBody.new()
	walker.collision_layer = WALKER_LAYER
	walker.collision_mask = 1
	_add_body(world, Vector3(2.0, REST_Y, 0.0), walker)
	for _i: int in TICKS * 3:
		await get_tree().physics_frame
		walker.velocity = Vector3(-SPEED * 3.0, walker.velocity.y - GRAVITY * DELTA, 0.0)
		walker.desired_velocity = Vector3(-SPEED * 3.0, 0.0, 0.0)
		walker.move_and_stair_step()
		c.velocity = Vector3(0.0, c.velocity.y - GRAVITY * DELTA, 0.0)
		c.move_and_stair_step()
		if _find_contact(c, walker, Vector3.LEFT) >= 0:
			break
	var listed: int = _find_contact(c, walker, Vector3.LEFT)

	_check(
		"b27 a resting body wakes only for a walker that can enter it",
		kept_rest and listed >= 0,
		"kept rest %s, walker listed at %d" % [kept_rest, listed],
	)
	world.queue_free()


## A body set into the floor comes out of it before it rests. Resting there, it
## was never pushed out: a game's dummy spawned 0.058 m deep, and standing up
## from a crouch then swept from that sunk pose, past a beam above it.
func _case_b28_a_body_set_into_the_floor_comes_out_before_resting() -> void:
	const SINK: float = 0.058
	const TICKS: int = 60
	const SETTLED: float = 0.005
	var world: Node3D = _new_world()
	_add_box(world, Vector3(8.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	var c: StairsBody = _add_body(world, Vector3(0.0, REST_Y - SINK, 0.0))
	await _hold_still(c, TICKS)

	_check(
		"b28 a body set into the floor comes out before resting",
		absf(c.global_position.y - REST_Y) < SETTLED,
		"y=%.4f expected %.4f" % [c.global_position.y, REST_Y],
	)
	world.queue_free()


## A resting body whose own collider changes is checked again, as a sleeping rigid
## body is woken by a shape change: a crouch that stands up grows the collider, and
## only the checks push the body back out of what it now overlaps. Grown taller about
## its centre, then moved down on its node, the collider sinks into the floor both
## times, and each time the body rises out of it. Switched off, it no longer stands
## on anything, and the body falls.
func _case_b29_a_resting_body_is_checked_again_when_its_collider_changes() -> void:
	const REST: int = 20
	const TICKS: int = 30
	const GROW: float = 0.2
	const LOWER: float = 0.1
	const SETTLED: float = 0.005
	var world: Node3D = _new_world()
	_add_box(world, Vector3(8.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	var c: StairsBody = _add_body(world, Vector3(0.0, REST_Y, 0.0))
	await _hold_still(c, REST)
	var shape_node: CollisionShape3D = c.get_child(0) as CollisionShape3D
	var cylinder: CylinderShape3D = shape_node.shape as CylinderShape3D
	cylinder.height = BODY_HEIGHT + GROW
	await _hold_still(c, TICKS)
	var grown_y: float = c.global_position.y
	shape_node.position = Vector3(0.0, -LOWER, 0.0)
	await _hold_still(c, TICKS)
	var lowered_y: float = c.global_position.y
	shape_node.disabled = true
	await _hold_still(c, TICKS)
	var fell: bool = c.global_position.y < lowered_y - EPS

	_check(
		"b29 a resting body is checked again when its collider changes",
		(
			absf(grown_y - (REST_Y + GROW * 0.5)) < SETTLED
			and absf(lowered_y - (REST_Y + GROW * 0.5 + LOWER)) < SETTLED and fell
		),
		"grown y=%.4f expected %.4f, lowered y=%.4f expected %.4f, fell when switched off %s"
		% [grown_y, REST_Y + GROW * 0.5, lowered_y, REST_Y + GROW * 0.5 + LOWER, fell],
	)
	world.queue_free()


## Crowd separation leaves an overlap under its slop alone, as Box2D's contact solver
## does, so still bodies in a pile stop being nudged and can rest. Deeper overlap is
## pushed all the way back to touching. Two still pairs: one set 3 mm into each other
## stays exactly where it was put, one set 30 mm in ends touching.
func _case_b30_crowd_overlap_under_the_slop_is_left_alone() -> void:
	# Under CROWD_SLOP (5 mm, src/stairs_body.h); retune both together.
	const SHALLOW: float = 0.003
	const DEEP: float = 0.03
	const TICKS: int = 30
	const HELD: float = 0.0001
	const CONVERGED: float = 0.001
	var world: Node3D = _new_world()
	_add_box(world, Vector3(20.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	var bodies: Array[StairsBody] = []
	for spec: Vector2 in [Vector2(-3.0, SHALLOW), Vector2(3.0, DEEP)]:
		var left_x: float = spec.x - BODY_RADIUS + spec.y * 0.5
		var right_x: float = spec.x + BODY_RADIUS - spec.y * 0.5
		bodies.append(_add_crowd_body(world, Vector3(left_x, REST_Y, 0.0)))
		bodies.append(_add_crowd_body(world, Vector3(right_x, REST_Y, 0.0)))
	var shallow_left: float = bodies[0].global_position.x
	var shallow_right: float = bodies[1].global_position.x
	for _i: int in TICKS:
		await get_tree().physics_frame
		for c: StairsBody in bodies:
			c.velocity = Vector3(0.0, c.velocity.y - GRAVITY * DELTA, 0.0)
			c.move_and_stair_step()
	var shallow_held: bool = (
		absf(bodies[0].global_position.x - shallow_left) < HELD
		and absf(bodies[1].global_position.x - shallow_right) < HELD
	)
	var deep_overlap: float = 2.0 * BODY_RADIUS - (
		bodies[3].global_position.x - bodies[2].global_position.x
	)

	_check(
		"b30 crowd overlap under the slop is left alone",
		shallow_held and absf(deep_overlap) < CONVERGED,
		"shallow pair held %s, deep pair overlaps %.4f m expected 0" % [shallow_held, deep_overlap],
	)
	world.queue_free()


## Counts engine errors, so a case can say none were raised. Warnings reach the
## same callback and are not counted. Unlocked: the physics that raises them runs
## on the main thread in this project.
class ErrorCounter:
	extends Logger

	var errors: int = 0


	func _log_error(
		_function: String,
		_file: String,
		_line: int,
		_code: String,
		_rationale: String,
		_editor_notify: bool,
		error_type: int,
		_script_backtraces: Array[ScriptBacktrace],
	) -> void:
		if error_type == ERROR_TYPE_ERROR:
			errors += 1


## Held still at a step face - velocity zero, intent into the face - the body climbs.
## The frame has no motion, so the only sweep that can meet the face is the step
## probe along intent. Gating that probe to where a step can be must keep this.
func _case_b31_held_still_at_a_step_with_intent_into_it_climbs() -> void:
	const FACE_GAP: float = 0.002
	var world: Node3D = _slow_walk_world(true)
	var c: StairsBody = _add_body(world, Vector3(1.0 - BODY_RADIUS - FACE_GAP, REST_Y, 0.0))
	for _i: int in 15:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	var start_y: float = c.global_position.y
	for _i: int in 30:
		await get_tree().physics_frame
		c.velocity = Vector3(0.0, c.velocity.y - GRAVITY * DELTA, 0.0)
		c.desired_velocity = Vector3(3.0, 0.0, 0.0)
		c.move_and_stair_step()

	var rose: float = c.global_position.y - start_y
	_check(
		"b31 held still at a step with intent into it climbs",
		absf(rose - STEP_TOP) < EPS,
		"rose %.3f m, expected %.3f" % [rose, STEP_TOP],
	)
	world.queue_free()
