extends Node3D

## Headless test harness for the StairsCharacter addon.
##
##     godot --headless --path <repo root> res://test/test_stairs.tscn
##
## Exit code is the number of failed cases, so it doubles as a CI gate.
## Worlds are built procedurally rather than authored as .tscn files: a case is
## then a few lines of geometry plus an assertion, and adding one costs nothing.
##
## `print` is the harness output, so the usual "no ungated print" rule (S11)
## does not apply here.

const SUBCLASS_SCRIPT: Script = preload("res://test/subclass_character.gd")

const DELTA: float = 1.0 / 60.0
const GRAVITY: float = 9.8

## A cylinder, not a capsule. Upstream's last commit is "Stop making character
## taller, now works with cylinder colliders", and the reference demo scene uses
## a CylinderShape3D. The distinction is load-bearing: a capsule's rounded bottom
## catches the top corner of a step during the drop-back-down phase and reports a
## ~52 degree contact normal, which the floor_max_angle check then rejects. A
## cylinder's flat bottom lands on the step's top face and reports a normal of up.
const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
## Body centre height when it rests on a surface at y = 0.
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001

const WALK_SPEED: float = 3.0
const SETTLE_FRAMES: int = 15
const WALK_FRAMES: int = 60

## Position tolerance. Wider than the collider margin because the solver leaves
## the capsule resting a fraction above the surface.
const EPS: float = 0.05

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	call_deferred(&"_run_all")

# --- harness ----------------------------------------------------------------


func _run_all() -> void:
	print("--- StairsCharacter test run ---")

	await _case_01_step_up()
	await _case_02_step_too_high()
	await _case_03_low_ceiling()
	await _case_04_steep_ramp()
	await _case_05_step_down()
	await _case_06_airborne()
	await _case_07_desired_velocity()
	await _case_08_subclass()
	await _case_09_flags_cleared()
	await _case_10_margin_from_export()
	await _case_11_legacy_collider_node()
	await _case_12_subclass_notification()
	await _case_13_step_down_bounded_by_step_height()
	await _case_14_step_up_bounded_by_step_height()
	await _case_15_legacy_step_height_property()
	await _case_16_step_up_signals()
	await _case_17_no_signal_when_blocked()
	await _case_18_step_down_signals()
	await _case_19_walkable_ramp()
	await _case_20_step_at_the_top_of_a_ramp()
	await _case_21_ceiling_flush_on_the_head()
	await _case_22_vertical_intent_is_ignored()
	await _case_23_legacy_step_height_rejects_non_numbers()
	await _case_24_grounded_tracks_the_previous_frame()
	await _case_25_second_collision_shape_blocks_the_step()
	await _case_26_embedded_character_is_pushed_out()
	await _case_27_force_stair_step_catches_a_ledge_airborne()
	await _case_28_a_step_costs_no_stalled_frame()
	await _case_29_a_clamped_rise_never_sinks_the_character()
	await _case_30_snap_down_reach_is_exactly_step_height()
	await _case_31_step_up_eases_the_visual_down_then_home()
	await _case_32_step_down_eases_the_visual_up()
	await _case_33_zero_smoothing_keeps_the_visual_rigid()
	await _case_34_a_teleport_sized_jump_is_not_smoothed()
	await _case_35_no_smooth_node_leaves_smoothing_off()
	await _case_36_smoothing_setup_does_not_kill_a_subclass_process()
	await _case_37_steps_up_from_a_standstill_against_the_face()
	await _case_38_backpressure_does_not_seat_against_the_push()
	await _case_39_climbs_while_pressed_against_a_wall()
	await _case_40_climbs_at_a_high_tick_rate()
	await _case_41_a_step_does_not_lurch_the_body_forward()

	print("--- %d passed, %d failed ---" % [_passed, _failed])
	get_tree().quit(_failed)


func _check(case_name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
		print("PASS  %s" % case_name)
	else:
		_failed += 1
		print("FAIL  %s — %s" % [case_name, detail])


## Drives one character for `frames` physics frames and returns the highest
## y its origin reached, so cases can assert on a transient step-up.
func _simulate(c: StairsCharacter, horizontal: Vector3, frames: int) -> float:
	var peak: float = -INF
	for _i: int in frames:
		await get_tree().physics_frame
		c.velocity.x = horizontal.x
		c.velocity.z = horizontal.z
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = horizontal
		c.move_and_stair_step()
		peak = maxf(peak, c.global_position.y)
	return peak

# --- world building ---------------------------------------------------------


func _new_world() -> Node3D:
	var world: Node3D = Node3D.new()
	add_child(world)
	return world


func _add_box(world: Node3D, size: Vector3, centre: Vector3, tilt_deg: float = 0.0) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	world.add_child(body)
	body.global_position = centre
	body.rotation.z = deg_to_rad(tilt_deg)


## Ground slab whose top face sits at y = 0, spanning x in [-10, span_x_max].
func _add_ground(world: Node3D, span_x_max: float) -> void:
	var length: float = span_x_max + 10.0
	_add_box(world, Vector3(length, 1.0, 8.0), Vector3(span_x_max - length * 0.5, -0.5, 0.0))


## Step whose top face sits at y = `top`, starting at x = 1.0.
func _add_step(world: Node3D, top: float) -> void:
	_add_box(world, Vector3(4.0, 2.0, 8.0), Vector3(3.0, top - 1.0, 0.0))


## `legacy_node_name` builds the character the way upstream scenes do — a child
## literally called "Collider" and nothing assigned to the export — so the
## compatibility fallback in `_resolve_margin` gets exercised too.
func _add_character(
	world: Node3D,
	script_res: Script,
	start_x: float,
	legacy_node_name: bool = false,
) -> StairsCharacter:
	var c: StairsCharacter = script_res.new() as StairsCharacter
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	shape_node.name = "Shape"
	if legacy_node_name:
		shape_node.name = "Collider"
	var body_shape: CylinderShape3D = CylinderShape3D.new()
	body_shape.radius = BODY_RADIUS
	body_shape.height = BODY_HEIGHT
	body_shape.margin = COLLIDER_MARGIN
	shape_node.shape = body_shape
	c.add_child(shape_node)
	if not legacy_node_name:
		c.collider = shape_node
	world.add_child(c)
	c.global_position = Vector3(start_x, REST_Y, 0.0)
	return c

# --- cases ------------------------------------------------------------------


func _case_01_step_up() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	var on_step: bool = absf(c.global_position.y - (REST_Y + 0.2)) < EPS
	_check(
		"01 step up below step_height",
		on_step and c.global_position.x > 1.0,
		"pos=%v expected y~%.2f, x>1.0" % [c.global_position, REST_Y + 0.2],
	)
	world.queue_free()


func _case_02_step_too_high() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.6)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	var peak: float = await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	_check(
		"02 step above step_height is blocked",
		peak < REST_Y + EPS and c.global_position.x < 1.0,
		"peak=%.3f x=%.3f expected no rise, x<1.0" % [peak, c.global_position.x],
	)
	world.queue_free()


func _case_03_low_ceiling() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	# Head sits at y = 1.8; leave only 0.15 of headroom, less than the step.
	_add_box(world, Vector3(4.0, 1.0, 8.0), Vector3(2.0, 2.45, 0.0))
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	var peak: float = await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	_check(
		"03 low ceiling blocks the step",
		peak < REST_Y + EPS,
		"peak=%.3f expected no rise" % peak,
	)
	world.queue_free()


func _case_04_steep_ramp() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	# 70 degrees, well past the default floor_max_angle of 45.
	_add_box(world, Vector3(4.0, 1.0, 8.0), Vector3(2.2, 0.0, 0.0), -70.0)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	var peak: float = await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	_check(
		"04 ramp steeper than floor_max_angle is rejected",
		peak < REST_Y + EPS,
		"peak=%.3f expected no rise" % peak,
	)
	world.queue_free()


func _case_05_step_down() -> void:
	var world: Node3D = _new_world()
	# Upper slab top at y = 0 ending at x = 2, lower slab top at y = -0.2.
	_add_box(world, Vector3(12.0, 1.0, 8.0), Vector3(-4.0, -0.5, 0.0))
	_add_box(world, Vector3(10.0, 1.0, 8.0), Vector3(7.0, -0.7, 0.0))
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	var landed: bool = absf(c.global_position.y - (REST_Y - 0.2)) < EPS
	_check(
		"05 snaps down onto a lower surface",
		landed and c.is_on_floor(),
		"pos=%v on_floor=%s expected y~%.2f" % [c.global_position, c.is_on_floor(), REST_Y - 0.2],
	)
	world.queue_free()


func _case_06_airborne() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	c.velocity.y = 6.0
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), 6)

	_check(
		"06 no step while airborne",
		not c.is_on_floor() and c.global_position.y > REST_Y + 0.3,
		"pos=%v on_floor=%s expected airborne" % [c.global_position, c.is_on_floor()],
	)
	world.queue_free()


func _case_07_desired_velocity() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	# Parked with the capsule just touching the step face at x = 1.0.
	var c: StairsCharacter = _add_character(world, StairsCharacter, 1.0 - BODY_RADIUS - 0.005)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)

	# `stair_step_up` is exercised on its own rather than through
	# `move_and_stair_step`. Driving the whole frame would prove nothing here: the
	# step-up does fire and raises the body onto the step, but with no actual
	# velocity `move_and_slide` cannot carry it forward, so `stair_step_down`
	# drops it back onto the ground it is still standing over. Calling the step
	# check directly isolates the fallback, which is the thing under test.
	await get_tree().physics_frame
	c.velocity = Vector3(0.0, -GRAVITY * DELTA, 0.0)

	# Control: no actual velocity and no intent means no step check at all.
	c.desired_velocity = Vector3.ZERO
	c.stair_step_up()
	var idle_y: float = c.global_position.y

	# Same state, but the controller expresses where it wants to go.
	c.desired_velocity = Vector3(WALK_SPEED, 0.0, 0.0)
	c.stair_step_up()
	var intent_y: float = c.global_position.y

	_check(
		"07 desired_velocity drives the step check at zero velocity",
		absf(idle_y - REST_Y) < EPS and intent_y > REST_Y + 0.1,
		"idle_y=%.3f (expected ~%.2f), intent_y=%.3f (expected > %.2f)"
		% [idle_y, REST_Y, intent_y, REST_Y + 0.1],
	)
	world.queue_free()


func _case_08_subclass() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	var c: StairsCharacter = _add_character(world, SUBCLASS_SCRIPT, 0.0)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	var on_step: bool = absf(c.global_position.y - (REST_Y + 0.2)) < EPS
	_check(
		"08 subclass overriding _ready and _physics_process still steps",
		on_step and c.global_position.x > 1.0,
		(
			"pos=%v expected y~%.2f, x>1.0 | grounded=%s — a false grounded here"
			% [c.global_position, REST_Y + 0.2, c.grounded]
			+ " means the parent's _physics_process never ran (PLAN section 0)"
		),
	)
	world.queue_free()


## Both flags are consume-then-clear, and move_and_stair_step is the only thing
## that clears them now that _physics_process is gone. Upstream documented
## force_stair_step as resetting after the frame but never reset it.
func _case_09_flags_cleared() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)

	await get_tree().physics_frame
	c.desired_velocity = Vector3(WALK_SPEED, 0.0, 0.0)
	c.force_stair_step = true
	c.move_and_stair_step()

	_check(
		"09 desired_velocity and force_stair_step clear after the call",
		c.desired_velocity == Vector3.ZERO and not c.force_stair_step,
		(
			"desired_velocity=%v force_stair_step=%s, expected zero and false"
			% [c.desired_velocity, c.force_stair_step]
		),
	)
	world.queue_free()


## The margin is read from the assigned `collider` export, and it is resolved on
## first use rather than in `_ready` — so a subclass that defines its own `_ready`
## must not be able to leave it at 0.0. Same section 0 principle as case 08.
func _case_10_margin_from_export() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	var c: StairsCharacter = _add_character(world, SUBCLASS_SCRIPT, 0.0)

	# Resolved off NOTIFICATION_READY, which the subclass cannot shadow, so it is
	# already correct here without a single move_and_stair_step call.
	# Read through get() because the query object is private and the linter has no
	# per-line ignore; the resolved margin is what this case exists to assert.
	var margin_at_ready: float = _resolved_margin(c)
	await _simulate(c, Vector3.ZERO, 2)
	var margin_after: float = _resolved_margin(c)

	_check(
		"10 collider margin resolves from the export under a subclass _ready",
		is_equal_approx(margin_at_ready, COLLIDER_MARGIN),
		(
			"at ready=%.4f after stepping=%.4f expected %.4f"
			% [margin_at_ready, margin_after, COLLIDER_MARGIN]
		),
	)
	world.queue_free()


## Upstream scenes have no export to assign — they rely on the child being named
## "Collider". That fallback has to keep working or every existing scene breaks.
func _case_11_legacy_collider_node() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0, true)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	var on_step: bool = absf(c.global_position.y - (REST_Y + 0.2)) < EPS
	var margin: float = _resolved_margin(c)
	_check(
		"11 legacy $Collider node still resolves the margin",
		on_step and is_equal_approx(margin, COLLIDER_MARGIN),
		"pos=%v margin=%.4f expected y~%.2f" % [c.global_position, margin, REST_Y + 0.2],
	)
	world.queue_free()


## The refactor that moved margin resolution off `_ready` and onto
## NOTIFICATION_READY rests on one empirical property of the engine: Godot
## dispatches `_notification` to every script in the inheritance chain rather
## than letting the most-derived override replace it, so a subclass cannot
## shadow it the way it shadows `_ready`. That is the whole justification, and
## it is a property of a dev build, so it gets pinned by a test: both bodies
## must run, the base one having resolved the margin.
func _case_12_subclass_notification() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	var c: StairsCharacter = _add_character(world, SUBCLASS_SCRIPT, 0.0)

	var margin: float = _resolved_margin(c)
	var subclass_ran: int = c.get(&"custom_notifications")

	_check(
		"12 subclass _notification does not shadow the parent's",
		is_equal_approx(margin, COLLIDER_MARGIN) and subclass_ran == 1,
		(
			"margin=%.4f subclass_notifications=%d expected %.4f and 1"
			% [margin, subclass_ran, COLLIDER_MARGIN]
		),
	)
	world.queue_free()


## Counts the frames the character spent off the floor. A successful step down
## keeps it planted the whole way; a rejected one lets it free-fall over the
## edge, which is the difference the two cases below turn on.
func _simulate_counting_airborne(c: StairsCharacter, horizontal: Vector3, frames: int) -> int:
	var airborne: int = 0
	for _i: int in frames:
		await get_tree().physics_frame
		c.velocity.x = horizontal.x
		c.velocity.z = horizontal.z
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = horizontal
		c.move_and_stair_step()
		if not c.is_on_floor():
			airborne += 1
	return airborne


## Case 5's world, but with step_height too low to cover the drop. The snap must
## be refused, so the character goes over the edge instead of walking down it.
## Case 5 is the same world at the default height, where the snap succeeds, so
## the pair pins step_height as the thing that bounds the downward snap.
func _case_13_step_down_bounded_by_step_height() -> void:
	var world: Node3D = _new_world()
	_add_box(world, Vector3(12.0, 1.0, 8.0), Vector3(-4.0, -0.5, 0.0))
	_add_box(world, Vector3(10.0, 1.0, 8.0), Vector3(7.0, -0.7, 0.0))
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	c.step_height = 0.05

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	var airborne: int = await _simulate_counting_airborne(
		c,
		Vector3(WALK_SPEED, 0.0, 0.0),
		WALK_FRAMES,
	)

	# `> 0` is a binary signal here, not a thin threshold: measured on this setup,
	# the snapping case reports exactly 0 airborne frames, because the snap keeps
	# the body planted across the edge rather than letting it leave the floor for
	# a frame and catching it after.
	_check(
		"13 step down is bounded by step_height",
		airborne > 0,
		"airborne_frames=%d expected >0 (a 0.20 drop must not snap at 0.05)" % airborne,
	)
	world.queue_free()


## Case 2's world - a 0.6 step the default rejects - with step_height raised past
## it. The climb must now succeed. Case 2 is the same world at the default
## height, where it is refused, so the pair pins step_height as the thing that
## bounds the climb.
func _case_14_step_up_bounded_by_step_height() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.6)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	c.step_height = 0.7

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	var on_step: bool = absf(c.global_position.y - (REST_Y + 0.6)) < EPS
	_check(
		"14 step up is bounded by step_height",
		on_step and c.global_position.x > 1.0,
		"pos=%v expected y~%.2f, x>1.0" % [c.global_position, REST_Y + 0.6],
	)
	world.queue_free()


## Scenes authored against the old `_step_height` name must not lose their
## tuning on upgrade. Godot drops saved properties that no longer exist on
## the script without saying anything, so the addon intercepts the old name in
## `_set` - which is the same path a scene load takes when it applies a stored
## property that has no matching field.
func _case_15_legacy_step_height_property() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	c.set(&"_step_height", 0.5)

	_check(
		"15 the old _step_height property name still applies",
		is_equal_approx(c.step_height, 0.5),
		"step_height=%.3f expected 0.5" % c.step_height,
	)
	world.queue_free()


## Counts every step signal a character emits. A Dictionary rather than plain
## locals because a lambda captures locals by value (H6) - the container is a
## reference, so the increments are visible to the caller.
## The margin lives on the shared motion-test parameters, which is the only copy
## of it the addon keeps.
func _resolved_margin(c: StairsCharacter) -> float:
	var params: PhysicsTestMotionParameters3D = c.get(&"_params")
	return params.margin


func _count_signals(c: StairsCharacter) -> Dictionary:
	var counts: Dictionary = { "any": 0, "up": 0, "down": 0 }
	c.stepped.connect(
		func() -> void:
			counts["any"] += 1,
	)
	c.stepped_up.connect(
		func() -> void:
			counts["up"] += 1,
	)
	c.stepped_down.connect(
		func() -> void:
			counts["down"] += 1,
	)
	return counts


func _case_16_step_up_signals() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	var counts: Dictionary = _count_signals(c)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	# `stepped` is the sum of the two directional signals, never its own event.
	_check(
		"16 stepping up emits stepped_up and stepped",
		counts["up"] >= 1 and counts["any"] == counts["up"] + counts["down"],
		"up=%d down=%d any=%d expected up>=1 and any==up+down"
		% [counts["up"], counts["down"], counts["any"]],
	)
	world.queue_free()


## The signals mark a position change, so a step the addon refused must be
## silent. This is the case that catches an emit placed above an early return
## rather than on the success path.
func _case_17_no_signal_when_blocked() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.6)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	var counts: Dictionary = _count_signals(c)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	_check(
		"17 a blocked step emits nothing",
		counts["any"] == 0 and counts["up"] == 0 and counts["down"] == 0,
		"up=%d down=%d any=%d expected 0 for all" % [counts["up"], counts["down"], counts["any"]],
	)
	world.queue_free()


func _case_18_step_down_signals() -> void:
	var world: Node3D = _new_world()
	_add_box(world, Vector3(12.0, 1.0, 8.0), Vector3(-4.0, -0.5, 0.0))
	_add_box(world, Vector3(10.0, 1.0, 8.0), Vector3(7.0, -0.7, 0.0))
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	var counts: Dictionary = _count_signals(c)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	_check(
		"18 snapping down emits stepped_down and stepped",
		counts["down"] >= 1 and counts["any"] == counts["up"] + counts["down"],
		"up=%d down=%d any=%d expected down>=1 and any==up+down"
		% [counts["up"], counts["down"], counts["any"]],
	)
	world.queue_free()


## A ramp shallow enough to walk up is move_and_slide's job, not the step
## check's. The character must still get up it, and must not report a stair step
## for doing so.
func _case_19_walkable_ramp() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 12.0)
	# A 30 degree slab, inside the default floor_max_angle of 45, sunk so its
	# lower edge meets the ground rather than presenting an end face to walk into.
	_add_box(world, Vector3(12.0, 0.5, 8.0), Vector3(6.2, 2.78, 0.0), 30.0)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	var counts: Dictionary = _count_signals(c)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), 90)

	_check(
		"19 a walkable ramp is climbed without reporting a step",
		c.global_position.y > REST_Y + 0.5 and counts["up"] == 0,
		(
			"y=%.3f up=%d expected y>%.2f and no stepped_up"
			% [c.global_position.y, counts["up"], REST_Y + 0.5]
		),
	)
	world.queue_free()


## The compound case the early-out could plausibly break: a walkable ramp with a
## real step waiting at the top of it. While on the ramp the forward sweep keeps
## hitting the ramp, so the step check bails every frame - correctly. The step
## must still be taken once the character reaches it, rather than the early-out
## swallowing it and stalling the character against the riser.
func _case_20_step_at_the_top_of_a_ramp() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	# Ramp rising from the ground at x = 1 to the plateau top at y = 1.
	_add_box(world, Vector3(2.0, 0.3, 8.0), Vector3(1.945, 0.37, 0.0), 30.0)
	# Plateau at y = 1, then a 0.2 step up to y = 1.2 partway along it.
	_add_box(world, Vector3(5.3, 2.0, 8.0), Vector3(5.35, 0.0, 0.0))
	_add_box(world, Vector3(3.0, 2.0, 8.0), Vector3(6.5, 0.2, 0.0))
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	var counts: Dictionary = _count_signals(c)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), 150)

	var on_step: bool = absf(c.global_position.y - (REST_Y + 1.2)) < EPS
	_check(
		"20 a step at the top of a ramp is still taken",
		on_step and counts["up"] >= 1,
		(
			"pos=%v up=%d expected y~%.2f and at least one stepped_up"
			% [c.global_position, counts["up"], REST_Y + 1.2]
		),
	)
	world.queue_free()


## Case 3 leaves a little headroom; this leaves none at all, so the raise sweep
## travels nothing. The step must be refused rather than the character being
## shoved through the ceiling, and it is also the path that lets the check bail
## before spending its last two sweeps.
func _case_21_ceiling_flush_on_the_head() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	# Head is at y = 1.8, so this sits directly on it.
	_add_box(world, Vector3(6.0, 1.0, 8.0), Vector3(2.0, 2.3, 0.0))
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	var counts: Dictionary = _count_signals(c)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	var peak: float = await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	_check(
		"21 a ceiling flush on the head blocks the step",
		peak < REST_Y + EPS and counts["up"] == 0,
		"peak=%.3f up=%d expected no rise and no stepped_up" % [peak, counts["up"]],
	)
	world.queue_free()


## Case 7 proves the `desired_velocity` fallback works when the controller hands
## over a flat vector. This is the same world with a vertical component in it,
## which is what a controller that assigns its whole movement intent - input plus
## gravity - to `desired_velocity` produces, the usage the README describes.
##
## The fallback has to be flattened the way actual velocity already is. Left
## alone, a downward component aims the first sweep forward *and down*, so it
## reaches the ground before the step face, the ground reports a walkable normal,
## and the walkable-slope bail throws the step away. Measured on this world:
## intent (3, -1, 0) rose 0.0000 against (3, 0, 0)'s 0.2007.
##
## The purely vertical arm is the other half: a vector with no horizontal
## component at all is not intent to move anywhere, so it has to fall through the
## zero-check rather than run four sweeps on a straight-up test velocity.
func _case_22_vertical_intent_is_ignored() -> void:
	var rises: PackedFloat32Array = []
	for intent: Vector3 in [
		Vector3(WALK_SPEED, -1.0, 0.0),
		Vector3(WALK_SPEED, 3.0, 0.0),
		Vector3(0.0, -5.0, 0.0),
	]:
		var world: Node3D = _new_world()
		_add_ground(world, 1.0)
		_add_step(world, 0.2)
		# Parked with the cylinder just touching the step face, as in case 7.
		var c: StairsCharacter = _add_character(world, StairsCharacter, 1.0 - BODY_RADIUS - 0.005)

		await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
		await get_tree().physics_frame
		c.velocity = Vector3(0.0, -GRAVITY * DELTA, 0.0)

		var before: float = c.global_position.y
		c.desired_velocity = intent
		c.stair_step_up()
		rises.append(c.global_position.y - before)
		world.queue_free()

	_check(
		"22 a vertical component in desired_velocity does not change the step",
		rises[0] > 0.1 and rises[1] > 0.1 and absf(rises[2]) < EPS,
		("rises=%s expected the two forward intents to step and the vertical one not to" % [rises]),
	)


## Case 15 covers the legacy `_step_height` name arriving with the float a scene
## would have stored. This is the same path fed something that is not a number,
## which a hand-edited scene or any caller reaching the property by name can do.
##
## `step_height` is a typed float, so the shim has to refuse a non-number rather
## than assign it. Note what this case does and does not pin: the resulting
## `step_height` is the same either way, because an unrefused assignment aborts
## `_set` on a type error and leaves the default in place. What the refusal buys
## is the reporting, which this harness cannot assert on - a bare "Trying to
## assign value of type 'String' to a variable of type 'float'", naming neither
## the addon nor the property, becomes an error that names both.
##
## So this case is a behaviour pin, not a regression test: it fails if a future
## edit makes a bad value clobber `step_height` with 0.0, or makes a good int
## stop applying.
func _case_23_legacy_step_height_rejects_non_numbers() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	var default_height: float = c.step_height
	c.set(&"_step_height", "nonsense")
	var after_string: float = c.step_height

	# An int is a number and still means what the designer typed, so it applies.
	c.set(&"_step_height", 1)
	var after_int: float = c.step_height

	_check(
		"23 the legacy _step_height name refuses a non-numeric value",
		is_equal_approx(after_string, default_height) and is_equal_approx(after_int, 1.0),
		(
			"after_string=%.3f (expected the %.3f default kept), after_int=%.3f (expected 1.0)"
			% [after_string, default_height, after_int]
		),
	)
	world.queue_free()


## `grounded` is documented as the ground state the addon sees, in place of
## `is_on_floor()`. This pins *which* frame's state that is, because the two are
## not interchangeable and the difference is invisible until a character crosses
## an edge.
##
## `move_and_stair_step` refreshes both flags at the top, before it moves
## anything, so after the call `grounded` holds `is_on_floor()` as it stood at
## the start of this frame - the result of last frame's movement - and never this
## frame's. `was_grounded` is the frame before that. Measured walking off a
## ledge: the frame `is_on_floor()` first read false, `grounded` still read true,
## and it flipped on the following frame.
##
## That lag is deliberate rather than incidental. `stair_step_up` runs before
## this frame's `move_and_slide`, so start-of-frame ground state is the correct
## input for it, and `stair_step_down` wants the frame before that, which is what
## `was_grounded` is for.
func _case_24_grounded_tracks_the_previous_frame() -> void:
	var world: Node3D = _new_world()
	# Ground stops at x = 1.0, so the character eventually walks off the end.
	_add_ground(world, 1.0)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)

	var lagged_every_frame: bool = true
	var saw_the_edge: bool = false
	var previous_floor: bool = c.is_on_floor()
	for _i: int in 60:
		await get_tree().physics_frame
		c.velocity.x = WALK_SPEED
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(WALK_SPEED, 0.0, 0.0)
		c.move_and_stair_step()

		if c.grounded != previous_floor:
			lagged_every_frame = false
		# The frame the two disagree is the edge crossing, and the reason this
		# case exists - without it the assertion above passes on a character
		# that never leaves the ground.
		if c.grounded != c.is_on_floor():
			saw_the_edge = true
		previous_floor = c.is_on_floor()

	_check(
		"24 grounded holds the previous frame's is_on_floor",
		lagged_every_frame and saw_the_edge,
		(
			"lagged_every_frame=%s saw_the_edge=%s — expected grounded to track the"
			% [lagged_every_frame, saw_the_edge]
			+ " previous frame across a ledge the character actually walks off"
		),
	)
	world.queue_free()


## The step check must see every collision shape the body owns, not just the one
## `collider` points at. `collider` exists to resolve a margin and to warn about
## shape choice; it was never meant to narrow what gets swept. A character with a
## backpack, a helmet, or any second shape sticking out past the cylinder has to
## be blocked by whatever that shape hits.
##
## The ceiling here clears the cylinder by a wide margin and clears the upper
## shape by 0.15, less than the 0.2 step, so a sweep that only knows about
## `collider` sees an open path and takes a step the whole body cannot fit
## through. Mirrors case 03, which does the same thing with a single shape.
##
## What this pins is the outcome - the body does not rise - and not which sweep
## produces it. That distinction cost something to learn: a variant that moved
## the raise sweep onto a single-shape shape cast still passed this case, via the
## final down sweep rejecting the landing rather than the raise sweep ever seeing
## the upper shape. So if you are changing which primitive a sweep uses, this
## case passing is not on its own evidence that multi-shape bodies still work -
## test/diag_multishape.gd asks the two primitives directly, and they disagree by
## 0.18 on exactly this geometry.
func _case_25_second_collision_shape_blocks_the_step() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	# A second shape sitting on top of the head, from y = 1.8 to y = 2.3.
	var extra: CollisionShape3D = CollisionShape3D.new()
	extra.name = "Backpack"
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(0.4, 0.5, 0.4)
	extra.shape = box
	c.add_child(extra)
	extra.position = Vector3(0.0, BODY_HEIGHT * 0.5 + 0.25, 0.0)

	# Ceiling underside at y = 2.45, leaving the upper shape 0.15 of headroom.
	_add_box(world, Vector3(4.0, 1.0, 8.0), Vector3(2.0, 2.95, 0.0))

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	var peak: float = await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	_check(
		"25 a second collision shape blocks the step",
		peak < REST_Y + EPS,
		"peak=%.3f expected no rise - the upper shape has only 0.15 of headroom" % peak,
	)
	world.queue_free()


## A character that starts overlapping the step has to end up on top of it. The
## sweeps are what resolve this: they depenetrate the body before measuring, so
## an embedded start is pushed out rather than measured from. A sweep that
## instead ignores whatever it is already inside of reads an open path through
## the step and leaves the character where it started.
func _case_26_embedded_character_is_pushed_out() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	# The step face is at x = 1.0 and its top at y = 0.2. Start the body past
	# the face with its feet below the top, so the lowest 0.2 of the cylinder
	# begins inside the step.
	var c: StairsCharacter = _add_character(world, StairsCharacter, 1.2)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	var on_step: bool = absf(c.global_position.y - (REST_Y + 0.2)) < EPS
	_check(
		"26 an embedded character is pushed out onto the step",
		on_step,
		"pos=%v expected y~%.2f, not left inside the step" % [c.global_position, REST_Y + 0.2],
	)
	world.queue_free()


## What force_stair_step is actually for, which case 09 does not cover - it only
## checks the flag is cleared. An airborne character moving into a ledge whose
## top is within reach should be lifted onto it, and the same character without
## the flag should not be: stair_step_up returns on the grounded check.
##
## This is the case that guards any future attempt to skip the step check on
## cheap evidence. An airborne character has no floor contact and no slide
## collisions to read, so a pre-filter built on either would skip precisely the
## check this flag exists to force, and case 09 would still pass.
func _case_27_force_stair_step_catches_a_ledge_airborne() -> void:
	var world: Node3D = _new_world()
	# A ledge whose top face is at y = 0.3, and NO ground in front of it. The
	# first attempt at this case put ground under the character: it landed after
	# two frames and then climbed the ledge the ordinary grounded way, so the
	# control reached the top as well and the case proved nothing. The pit is
	# what keeps the control airborne for the whole run.
	_add_step(world, 0.3)

	# Airborne over the pit, feet at y = 0.15 - nothing underneath, and 0.15
	# below the ledge top, so the ledge is within step_height but the body is not
	# standing on anything. This is the wall-jump snag the flag was written for.
	var caught: StairsCharacter = _add_character(world, StairsCharacter, 0.5)
	caught.global_position.y = REST_Y + 0.15
	var dropped: StairsCharacter = _add_character(world, StairsCharacter, 0.5)
	dropped.global_position.z = 3.0
	dropped.global_position.y = REST_Y + 0.15

	for _i: int in 12:
		await get_tree().physics_frame
		for c: StairsCharacter in [caught, dropped]:
			c.velocity.x = WALK_SPEED
			c.velocity.y -= GRAVITY * DELTA
			c.desired_velocity = Vector3(WALK_SPEED, 0.0, 0.0)
		caught.force_stair_step = true
		caught.move_and_stair_step()
		dropped.move_and_stair_step()

	var on_ledge: bool = caught.global_position.y > REST_Y + 0.3 - EPS
	var control_below: bool = dropped.global_position.y < REST_Y + 0.3 - EPS
	_check(
		"27 force_stair_step catches a ledge while airborne",
		on_ledge and control_below,
		(
			"forced y=%.3f (expected >%.3f), control y=%.3f (expected <%.3f)"
			% [
				caught.global_position.y,
				REST_Y + 0.3 - EPS,
				dropped.global_position.y,
				REST_Y + 0.3 - EPS,
			]
		),
	)
	world.queue_free()


## A step must cost no frame of forward progress. The step check runs before
## move_and_slide and raises the body first, so on the frame a walker reaches a
## climbable step it both rises and keeps moving - it never stands still against
## the face for a frame.
##
## This is the coarse latency guard. Anything that defers the check by a frame -
## reading last frame's collisions rather than sweeping now, rechecking a cached
## answer every N frames - can show up here as a frame where the character is
## against the step, has not yet stepped, and goes nowhere. The height assertions
## in the other cases cannot see that: the character still ends up on top, one
## frame later.
##
## Its limit is worth knowing before trusting it. The threshold below tolerates a
## partial frame of lost progress, and a deferred check that costs less than that
## passes here: the is_on_wall pre-filter measured in test/diag_latency.gd clears
## this case and still climbs a flight of eight steps in 90 frames against 83.
## For a frame-count answer, run that file - this one only catches a full stall.
func _case_28_a_step_costs_no_stalled_frame() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	var counts: Dictionary = _count_signals(c)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)

	# Per frame the walker should cover WALK_SPEED * DELTA. Half of that is the
	# threshold for "stalled" - generous enough that solver jitter and the margin
	# the first contact frame gives up cannot trip it.
	var expected_advance: float = WALK_SPEED * DELTA
	var stalls: int = 0
	var worst_frame: int = -1
	for i: int in WALK_FRAMES:
		await get_tree().physics_frame
		var before_x: float = c.global_position.x
		var stepped_before: int = counts["up"]
		c.velocity.x = WALK_SPEED
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(WALK_SPEED, 0.0, 0.0)
		c.move_and_stair_step()

		# Only frames before the character is up on the step can stall against it.
		if counts["up"] > 0 and stepped_before > 0:
			continue
		if c.global_position.x - before_x < expected_advance * 0.5:
			stalls += 1
			if worst_frame < 0:
				worst_frame = i

	_check(
		"28 climbing a step costs no stalled frame",
		stalls == 0 and counts["up"] >= 1,
		(
			"%d stalled frames (first at %d), stepped_up fired %d times"
			% [stalls, worst_frame, counts["up"]]
		),
	)
	world.queue_free()


## The step check must never leave the character lower than it started. That is
## guaranteed by phase 2 of stair_step_up: its sweep clamps `step_up_distance` to
## the rise actually achieved, so phase 4's downward sweep can never travel
## further than the body rose.
##
## Delete that sweep — raise unconditionally and let phase 3's depenetration push
## the body back out of any ceiling — and the guarantee goes with it. The rise is
## then always the full step_height while depenetration has already pulled the
## body back down, so phase 4 drops from a lowered position and can land on
## ground BELOW where the character started. The last line of stair_step_up then
## assigns that height and the character sinks.
##
## Everything this needs is here and nowhere else in the suite: a low ceiling to
## force the depenetration, a lip low enough that the forward sweep still finds
## something, and — the ingredient a ceiling-over-the-step world never has —
## ground beyond the lip that sits BELOW the character's feet, giving phase 4
## somewhere lower to land. Found by adversarial search after an 81-row grid
## comparison of the two variants reported them identical.
func _case_29_a_clamped_rise_never_sinks_the_character() -> void:
	var world: Node3D = _new_world()
	# Ground the character stands on, top face at y = 0, ending at x = 2.6.
	_add_box(world, Vector3(15.6, 1.0, 8.0), Vector3(-5.2, -0.5, 0.0))
	# A 2 cm lip on its edge — tall enough for the forward sweep to catch.
	_add_box(world, Vector3(0.1, 0.02, 8.0), Vector3(2.65, 0.01, 0.0))
	# Ground beyond the lip, 10 cm BELOW the character's feet.
	_add_box(world, Vector3(20.0, 1.0, 8.0), Vector3(12.7, -0.6, 0.0))
	# Ceiling 5 cm above the head, so a full step_height rise cannot happen.
	_add_box(
		world,
		Vector3(30.0, 1.0, 8.0),
		Vector3(2.0, REST_Y + BODY_HEIGHT * 0.5 + 0.05 + 0.5, 0.0),
	)

	var c: StairsCharacter = _add_character(world, StairsCharacter, 2.0)
	c.step_height = 0.3

	await _simulate(c, Vector3.ZERO, 2)
	var start_y: float = c.global_position.y

	# Sampled inside the signal handler, which is the only place the sink is
	# visible: stair_step_up writes global_position.y, then move_and_slide's own
	# recovery shoves the body back out of the ground before the frame ends. A
	# resting-height check at the end of the frame sees nothing wrong.
	var lowest: PackedFloat64Array = [INF]
	var ups: PackedInt32Array = [0]
	c \
			.stepped_up \
			.connect(
		func() -> void:
			lowest[0] = minf(lowest[0], c.global_position.y)
			ups[0] += 1,
	)

	for _i: int in 40:
		await get_tree().physics_frame
		c.velocity.x = 60.0
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(60.0, 0.0, 0.0)
		c.move_and_stair_step()

	var sank: bool = lowest[0] < start_y - EPS
	world.queue_free()

	# Shipping takes no step at all here - phase 2 clamps the rise to the 5 cm of
	# headroom, so phase 4's matching 5 cm drop cannot reach the ground beyond the
	# lip and the check returns before emitting. That means the sink assertion
	# above passes VACUOUSLY on correct code, and a future change that stopped
	# stepping in this geometry for some unrelated reason would pass it in silence.
	#
	# So a control runs the same instrumentation against a plain climbable step.
	# It fires, which is what makes a zero count in the scenario above mean "no
	# step was taken" rather than "the handler never worked".
	var control_world: Node3D = _new_world()
	_add_ground(control_world, 1.0)
	_add_step(control_world, 0.2)
	var control: StairsCharacter = _add_character(control_world, StairsCharacter, 0.0)
	var control_counts: Dictionary = _count_signals(control)
	await _simulate(control, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(control, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	_check(
		"29 a clamped rise never sinks the character",
		not sank and control_counts["up"] >= 1,
		(
			"sink: y=%.4f is %.3f below the start of %.4f after %d step-ups; "
			% [lowest[0], start_y - lowest[0], start_y, ups[0]]
			+ "control took %d step-ups (expected >=1, else the harness sees nothing)"
			% control_counts["up"]
		),
	)
	control_world.queue_free()


## Case 13 covers the same property and does not catch a snap-down that reaches
## too far, because it drops 0.20 against a step_height of 0.05 — four times the
## reach. Tripling the sweep still falls short, so the case passes. Found by
## mutation audit: multiplying the snap distance by three survived the whole
## suite.
##
## This one puts the drop INSIDE the range a loosened sweep would reach: 0.12
## against the same 0.05 step_height, so the character goes briefly airborne and
## a sweep reaching 3x would plant it.
##
## The real threshold here is not step_height. CharacterBody3D snaps to the floor
## on its own within floor_snap_length, which defaults to 0.10, so every drop
## below ~0.11 reports zero airborne frames whatever this addon does. That is what
## sets the floor of the useful range, and it means this case catches snap
## multipliers of roughly 2.4x and up rather than anything above 1x. Enough for
## the tripling it was written for, and worth knowing before tightening it: the
## margin between 0.12 and that 0.11 cliff is about a centimetre, and the cliff
## moves if floor_snap_length is ever set or its default changes.
func _case_30_snap_down_reach_is_exactly_step_height() -> void:
	var world: Node3D = _new_world()
	_add_box(world, Vector3(12.0, 1.0, 8.0), Vector3(-4.0, -0.5, 0.0))
	_add_box(world, Vector3(10.0, 1.0, 8.0), Vector3(7.0, -0.62, 0.0))
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	c.step_height = 0.05

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	var airborne: int = await _simulate_counting_airborne(
		c,
		Vector3(WALK_SPEED, 0.0, 0.0),
		WALK_FRAMES,
	)

	_check(
		"30 snap-down reach is exactly step_height",
		airborne > 0,
		"airborne_frames=%d expected >0 (a 0.12 drop must not snap at 0.05)" % airborne,
	)
	world.queue_free()


## Attaches a smooth_node child at a non-zero rest Y - non-zero on purpose, so a
## test can prove the decay homes to the authored rest rather than to zero.
##
## The editor assigns smooth_node before the node enters the tree, so
## NOTIFICATION_READY captures the rest Y and turns processing on. This harness
## assigns the export after _add_character has already added the body, so that
## one-time setup is re-run explicitly here; it only records the rest Y and
## enables processing.
func _attach_smooth_node(c: StairsCharacter, rest_y: float, smoothing: float) -> Node3D:
	var cam: Node3D = Node3D.new()
	cam.name = "SmoothPivot"
	cam.position = Vector3(0.0, rest_y, 0.0)
	c.add_child(cam)
	c.smooth_node = cam
	c.step_smoothing = smoothing
	c.call(&"_init_step_smoothing")
	return cam


## Reads the private visual offset the decay chases back to rest.
func _smooth_offset(c: StairsCharacter) -> float:
	return c.get(&"_smooth_offset_y")


## The step itself is real, so this exercises the accumulate call on the actual
## apply site. The body steps up +0.2, so the visual has to be pushed the opposite
## way - below rest - and then eased home. Decay is driven with an explicit dt
## rather than by awaiting idle frames: the offset math is what is under test, and
## a fixed dt makes it deterministic instead of hostage to the headless idle rate.
func _case_31_step_up_eases_the_visual_down_then_home() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	var cam: Node3D = _attach_smooth_node(c, 0.5, 20.0)

	# Sampled at the emit, before any decay, so it is the full push.
	var offset_at_step: PackedFloat64Array = [0.0]
	var fired: PackedInt32Array = [0]
	c.stepped_up.connect(
		func() -> void:
			if fired[0] == 0:
				offset_at_step[0] = _smooth_offset(c)
			fired[0] += 1,
	)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	var pushed_down: bool = fired[0] >= 1 and offset_at_step[0] < -0.1

	# Drive the decay to completion with a fixed 60 Hz dt.
	for _i: int in 200:
		c.call(&"_tick_step_smoothing", DELTA)
	var homed: bool = absf(_smooth_offset(c)) < EPS and absf(cam.position.y - 0.5) < EPS

	_check(
		"31 a step up eases the visual down then home",
		pushed_down and homed,
		(
			"offset_at_step=%.4f (expected < -0.1), cam.y=%.4f (expected ~0.50)"
			% [offset_at_step[0], cam.position.y]
		),
	)
	world.queue_free()


## The down direction of the same mechanism. Case 05's world: the body snaps down
## -0.2, so the visual is pushed the opposite way - above rest - before easing
## back. Sign is the whole point, so it is asserted rather than the magnitude.
func _case_32_step_down_eases_the_visual_up() -> void:
	var world: Node3D = _new_world()
	_add_box(world, Vector3(12.0, 1.0, 8.0), Vector3(-4.0, -0.5, 0.0))
	_add_box(world, Vector3(10.0, 1.0, 8.0), Vector3(7.0, -0.7, 0.0))
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	_attach_smooth_node(c, 0.0, 20.0)

	var offset_at_step: PackedFloat64Array = [0.0]
	var fired: PackedInt32Array = [0]
	c.stepped_down.connect(
		func() -> void:
			if fired[0] == 0:
				offset_at_step[0] = _smooth_offset(c)
			fired[0] += 1,
	)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

	_check(
		"32 a step down eases the visual up",
		fired[0] >= 1 and offset_at_step[0] > 0.1,
		"offset_at_step=%.4f (expected > 0.1 on a downward snap)" % offset_at_step[0],
	)
	world.queue_free()


## step_smoothing of zero is the off switch that keeps smooth_node assigned. The
## body must still step, and the visual must not move from rest at all - accumulate
## refuses to bank an offset and the tick collapses any residual to zero.
func _case_33_zero_smoothing_keeps_the_visual_rigid() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	var cam: Node3D = _attach_smooth_node(c, 0.0, 0.0)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)
	await _simulate(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)
	c.call(&"_tick_step_smoothing", DELTA)

	var stepped: bool = absf(c.global_position.y - (REST_Y + 0.2)) < EPS
	var rigid: bool = absf(_smooth_offset(c)) < EPS and absf(cam.position.y) < EPS
	_check(
		"33 zero step_smoothing keeps the visual rigid",
		stepped and rigid,
		(
			"body_y=%.3f (expected ~%.2f), offset=%.4f cam.y=%.4f (expected ~0)"
			% [c.global_position.y, REST_Y + 0.2, _smooth_offset(c), cam.position.y]
		),
	)
	world.queue_free()


## The accumulate gate rejects a jump larger than twice step_height as a teleport,
## so a warp or an external shove does not drag the camera across the whole
## distance. A legitimate step in the same call still banks, clamped to
## step_height. Driven directly because a teleport is awkward to stage in physics.
func _case_34_a_teleport_sized_jump_is_not_smoothed() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	_attach_smooth_node(c, 0.0, 20.0)
	c.step_height = 0.33

	# 5 m is far past 2 * step_height, so it is refused and the offset stays home.
	c.call(&"_accumulate_step_smoothing", 5.0)
	var ignored: bool = absf(_smooth_offset(c)) < EPS

	# A real 0.2 step banks, pushed the opposite way and inside the step_height clamp.
	c.call(&"_accumulate_step_smoothing", 0.2)
	var banked: bool = is_equal_approx(_smooth_offset(c), -0.2)

	_check(
		"34 a teleport-sized jump is not smoothed",
		ignored and banked,
		"after teleport offset should be ~0 then ~-0.2, got %.4f" % _smooth_offset(c),
	)
	world.queue_free()


## The default state: no smooth_node assigned. Smoothing must be entirely inert -
## processing off, accumulate a no-op - which is what lets every one of the 30
## cases above run unchanged. The step behaviour itself is covered there; this
## pins that the new path adds nothing when the export is left empty.
func _case_35_no_smooth_node_leaves_smoothing_off() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	# _init_step_smoothing runs at NOTIFICATION_READY with smooth_node still null.
	var processing_off: bool = not c.is_processing()
	c.call(&"_accumulate_step_smoothing", 0.2)
	var no_op: bool = absf(_smooth_offset(c)) < EPS

	_check(
		"35 no smooth_node leaves smoothing off",
		processing_off and no_op,
		"is_processing=%s offset=%.4f (expected off and 0)" % [c.is_processing(), _smooth_offset(c)],
	)
	world.queue_free()


## The smoothing setup turns idle processing ON, never off. A subclass that
## defines its own _process has processing auto-enabled by the engine; the base's
## _init_step_smoothing runs after that at NOTIFICATION_READY, and must not switch
## it back off when smooth_node is unassigned - doing so would silently kill the
## subclass _process, the same shadowing trap the _notification hooks exist to
## dodge. This is the regression pin for that fix: the subclass here defines
## _process and assigns no smooth_node, the documented "off" state.
func _case_36_smoothing_setup_does_not_kill_a_subclass_process() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	var c: StairsCharacter = _add_character(world, SUBCLASS_SCRIPT, 0.0)

	# NOTIFICATION_READY has already fired inside _add_character, so if the base
	# had disabled processing the subclass _process would already be dead.
	var still_processing: bool = c.is_processing()
	await get_tree().process_frame
	await get_tree().process_frame
	var subclass_ticked: int = c.get(&"custom_process_frames")

	_check(
		"36 smoothing setup does not disable a subclass _process",
		still_processing and subclass_ticked > 0,
		(
			"is_processing=%s custom_process_frames=%d — expected the subclass _process to keep running"
			% [still_processing, subclass_ticked]
		),
	)
	world.queue_free()


## Regression pin for the standstill-against-the-face bug. Case 07 proves the
## desired_velocity fallback raises the body from a dead stop; this proves the
## body actually ENDS UP on the step, which case 07 explicitly does not - it
## drives stair_step_up in isolation and notes the body drops back once
## move_and_slide runs with no velocity to carry it.
##
## The drive models an acceleration controller pressed head-on into the step.
## move_and_slide zeroes the into-wall component of velocity every frame and a
## weak accel rebuilds it only to accel*delta, so velocity stays pinned near zero
## while desired_velocity carries the full intent. Rather than lean on the physics
## to zero it - which depends on the exact gap and margin, and lets a body that
## starts a hair off the face accelerate across the gap and seat the ordinary way,
## hiding the bug - the velocity is pinned here directly: a fixed 0.05 m/s, the
## kind of residue a 3 m/s^2 controller leaves. That deterministically stages the
## failure. Before the fix the probe shrank to that 0.05 and the step was never
## found; the body sat against the face forever.
func _case_37_steps_up_from_a_standstill_against_the_face() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	# Parked flush against the step face at x = 1.0.
	var c: StairsCharacter = _add_character(world, StairsCharacter, 1.0 - BODY_RADIUS - 0.002)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)

	# The residual an acceleration controller cannot climb past while the wall
	# keeps zeroing it - far below what move_and_slide needs to carry the raised
	# body over the lip on its own.
	const WALL_PINNED_VX: float = 0.05
	for _i: int in WALK_FRAMES:
		await get_tree().physics_frame
		c.velocity.x = WALL_PINNED_VX
		c.velocity.z = 0.0
		c.velocity.y -= GRAVITY * DELTA
		# Intent is the full walk target, not the collapsed velocity - this is the
		# value the fix reads to drive the probe when velocity cannot.
		c.desired_velocity = Vector3(WALK_SPEED, 0.0, 0.0)
		c.move_and_stair_step()

	# The height is the discriminator: pinned to the face the body sits at REST_Y,
	# stepped it stands a step higher. x barely advances here only because the test
	# holds velocity at a crawl - the point is that it rose onto the step and rests
	# there rather than dropping straight back, so pair the height with is_on_floor.
	var on_step: bool = absf(c.global_position.y - (REST_Y + 0.2)) < EPS
	_check(
		"37 steps up from a standstill against the face",
		on_step and c.is_on_floor(),
		(
			"pos=%v on_floor=%s expected y~%.2f standing — the body stayed pinned to"
			% [c.global_position, c.is_on_floor(), REST_Y + 0.2]
			+ " the face, which is the standstill-step bug this pins"
		),
	)
	world.queue_free()


## The forward leg of the step check slides along whatever it meets. Without that
## a wall beside a staircase steals the first contact from the step, the leftover
## motion still points into the wall, and the leg travels nothing - so a player
## holding a diagonal into a banister cannot climb, while the same walk one push
## away from the wall climbs fine. Pinned as the pair, because a world where
## neither run climbs is a broken world rather than a regression.
##
## test/diag_wallhug.gd is the roomier version of this, a four step staircase
## walked three ways; this is the smallest shape that still fails without the fix.
func _case_39_climbs_while_pressed_against_a_wall() -> void:
	# One character per world, like every other case: the first run finishes
	# standing on the step, and leaving it there as scenery for the second is the
	# kind of coupling that survives until someone moves the step.
	var hugging: Vector3 = await _walk_beside_a_wall(Vector3(WALK_SPEED, 0.0, WALK_SPEED))
	var open: Vector3 = await _walk_beside_a_wall(Vector3(WALK_SPEED, 0.0, 0.0))

	var target_y: float = REST_Y + 0.2
	var hugging_climbed: bool = absf(hugging.y - target_y) < EPS
	var open_climbed: bool = absf(open.y - target_y) < EPS
	var why: String = "the sideways push cost the climb"
	if not open_climbed:
		why = (
			"the world is wrong, neither climbed"
			if not hugging_climbed
			else "only the straight walk failed, which is a broken control"
		)
	_check(
		"39 climbs a step while pressed against a wall beside it",
		hugging_climbed and open_climbed,
		"hugging=%v open=%v expected both at y~%.2f - %s" % [hugging, open, target_y, why],
	)


## One run of case 39's world, torn down after. `push` carries the sideways
## component: with it the body rides the wall, without it the same walk runs a
## push away from it, which is the control.
func _walk_beside_a_wall(push: Vector3) -> Vector3:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	# A wall along the walk, its face exactly on the character's radius so a
	# sideways push holds contact without ever embedding the body.
	_add_box(world, Vector3(20.0, 6.0, 0.5), Vector3(0.0, 3.0, BODY_RADIUS + 0.25))

	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)
	await _simulate(c, push, WALK_FRAMES)

	var where: Vector3 = c.global_position
	world.queue_free()
	await get_tree().physics_frame
	return where


## Every distance in the step check is velocity * delta, so the whole check
## shrinks with the tick rate. Left unclamped it stalls outright rather than
## degrading: move_and_slide parks the body a probe length short of the step, the
## probe reaches the face with nothing left over, the forward leg moves that
## nothing and is rejected - on that frame and every frame after, because nothing
## ever moves again. _MIN_STEP_FORWARD is the floor that stops it, and this walks
## the same step at four times the default rate to hold that floor in place.
##
## test/diag_tickrate.gd sweeps the whole rate x speed grid; this pins one cell
## that was stuck before the floor existed.
func _case_40_climbs_at_a_high_tick_rate() -> void:
	const RATE: int = 240
	var original_rate: int = Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = RATE
	var delta: float = 1.0 / float(RATE)

	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	# Started part way in rather than at the far end: where the body first meets
	# the face decides how much of the probe is left over, and this offset is the
	# one measured stuck at this rate before the floor existed.
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.4)

	# Four times the frames for four times the rate, here and in the walk below,
	# so both cover the same simulated time as every other case.
	for _i: int in SETTLE_FRAMES * 4:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * delta
		c.move_and_stair_step()

	for _i: int in WALK_FRAMES * 4:
		await get_tree().physics_frame
		c.velocity.x = WALK_SPEED
		c.velocity.y -= GRAVITY * delta
		c.desired_velocity = Vector3(WALK_SPEED, 0.0, 0.0)
		c.move_and_stair_step()

	var climbed: bool = absf(c.global_position.y - (REST_Y + 0.2)) < EPS
	Engine.physics_ticks_per_second = original_rate
	_check(
		"40 climbs a step at a high physics tick rate",
		climbed,
		(
			"pos=%v at %d Hz, expected y~%.2f - the body stalled at the step face,"
			% [c.global_position, RATE, REST_Y + 0.2]
			+ " which is the short-probe deadlock the minimum forward leg prevents"
		),
	)
	world.queue_free()


## Case 28 pins the floor under a step-up frame - it must not stall. This pins the
## ceiling over it: it must not lurch either.
##
## The forward leg is probed, not travelled, so whenever the addon seats the
## horizontal itself move_and_slide is about to cover that ground again. The seat
## is gated on the frame being too short for move_and_slide to reach the landing,
## and getting that gate wrong is not visible in any end-position assertion: an
## earlier revision keyed it off "was the leg lengthened" instead, which is true on
## ordinary walking frames too, and a 0.05 m frame advanced 0.12 m on the step
## while still arriving at the right place. Only a per-frame measurement sees it.
##
## The start offset is load-bearing, in the way case 40's is. Where the body first
## touches the face decides how much of the probe is left over, and the burst only
## exists on frames where that leftover is short enough for the leg to be
## lengthened. Starting at zero, at WALK_SPEED and the default rate, first touch
## lands in that zone. Change any one of the three and check the case still fails
## on the revision it pins, or it is quietly guarding nothing.
func _case_41_a_step_does_not_lurch_the_body_forward() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	var c: StairsCharacter = _add_character(world, StairsCharacter, 0.0)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)

	# What one frame of walking covers, and the most a single frame is allowed to
	# cover. Generous: the burst this pins was 2.4x, so half again leaves room for
	# solver noise without leaving room for the bug.
	var per_frame: float = WALK_SPEED * DELTA
	var ceiling: float = per_frame * 1.5

	var worst: float = 0.0
	var previous_x: float = c.global_position.x
	for _i: int in WALK_FRAMES:
		await get_tree().physics_frame
		c.velocity.x = WALK_SPEED
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(WALK_SPEED, 0.0, 0.0)
		c.move_and_stair_step()
		# Magnitude, not signed: a step that shoved the body backward would clamp to
		# the zero this starts at and pass a check named for the worst frame.
		worst = maxf(worst, absf(c.global_position.x - previous_x))
		previous_x = c.global_position.x

	var climbed: bool = absf(c.global_position.y - (REST_Y + 0.2)) < EPS
	_check(
		"41 a step does not lurch the body forward",
		climbed and worst <= ceiling,
		(
			"climbed=%s worst frame advanced %.4f m against %.4f expected, ceiling %.4f"
			% [climbed, worst, per_frame, ceiling]
			+ " - the step frame seated the horizontal move_and_slide was going to cover"
		),
	)
	world.queue_free()


## Guards the intent-probe against backpressure. When velocity opposes the held
## intent - knockback, an explosion, a shove into the step while forward is still
## pressed - intent is the larger vector, so a naive "probe the bigger one" would
## seat the body forward onto the step while move_and_slide carries it backward,
## popping it on and off the lip every frame. The dot < 0 guard keeps velocity the
## trusted signal there, leaving the shove to move_and_slide as before.
##
## Driven one frame in isolation, like case 07: with velocity pointing away from
## the step the probe must find nothing and leave the body where it is. Before the
## guard, the forward intent probed forward, found the step and seated the body
## onto it - the pop this pins against. The standstill fix is untouched: a
## wall-pinned near-zero velocity still points forward, dots positive with intent,
## and falls through to the intent probe (case 37 covers that).
func _case_38_backpressure_does_not_seat_against_the_push() -> void:
	var world: Node3D = _new_world()
	_add_ground(world, 1.0)
	_add_step(world, 0.2)
	# Flush against the step face, the same standstill start as case 37.
	var c: StairsCharacter = _add_character(world, StairsCharacter, 1.0 - BODY_RADIUS - 0.002)

	await _simulate(c, Vector3.ZERO, SETTLE_FRAMES)

	await get_tree().physics_frame
	c.grounded = true
	# Being shoved back off the step while the player still holds forward. Intent is
	# the larger vector; the guard must not let it seat the body against the push.
	c.velocity = Vector3(-2.0, -GRAVITY * DELTA, 0.0)
	c.desired_velocity = Vector3(WALK_SPEED, 0.0, 0.0)
	var before: Vector3 = c.global_position
	c.stair_step_up()

	# stair_step_up commits only Y and X/Z, never touching a body it found no step
	# for. The probe ran backward, found nothing, and left the body put.
	var stayed: bool = c.global_position.is_equal_approx(before)
	_check(
		"38 backpressure does not seat the body against the push",
		stayed,
		(
			"pos went %v -> %v — a velocity opposing intent seated the body forward,"
			% [before, c.global_position]
			+ " the backpressure pop the dot guard exists to stop"
		),
	)
	world.queue_free()
