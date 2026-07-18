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
	var airborne: int = await _simulate_counting_airborne(c, Vector3(WALK_SPEED, 0.0, 0.0), WALK_FRAMES)

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
	var counts: Dictionary = {"any": 0, "up": 0, "down": 0}
	c.stepped.connect(func() -> void: counts["any"] += 1)
	c.stepped_up.connect(func() -> void: counts["up"] += 1)
	c.stepped_down.connect(func() -> void: counts["down"] += 1)
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
		"up=%d down=%d any=%d expected up>=1 and any==up+down" % [counts["up"], counts["down"], counts["any"]],
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
		"up=%d down=%d any=%d expected down>=1 and any==up+down" % [counts["up"], counts["down"], counts["any"]],
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
