extends Node3D

## Why does a walkable ramp report a stair step under Jolt and not under Godot
## Physics?
##
##     godot --headless --path <repo root> res://test/diag_jolt_ramp.tscn
##
## Run it twice, with and without an override.cfg selecting Jolt, and diff the
## output - the scene is identical either way and prints which engine it is on.
##
##     [physics]
##
##     3d/physics_engine="Jolt Physics"
##
## Case 19 of the suite walks a character up a 30 degree slab, inside the default
## floor_max_angle of 45, and asserts it climbs WITHOUT emitting stepped_up: a
## walkable surface is move_and_slide's job, and the walkable-surface bail in
## stair_step_up exists to hand it over. Under Jolt that assertion fails with
## exactly one step-up, while the climb itself is unaffected - the ramp bench
## measures the same 0.364 slope and the same 6.49 m advanced under both engines.
##
## One step-up in ninety frames is one frame where the bail did not fire, so the
## question is what the first sweep reported on that frame. This walks the same
## ramp, runs that same sweep once per frame from outside the addon, and prints
## what it saw on the approach - plus the same sweep again with max_collisions
## raised, in case the engine has more to say than one normal.
##
## RESULT: the engines disagree about the ramp's leading CORNER, for one frame.
##
##     frame 11, x 0.550, same transform on both engines
##       Godot Physics  normal 30.0 deg - the ramp face exactly, so the bail fires
##       Jolt           normal 49.5 deg - four degrees over the limit, so it steps
##     frame 12 onward  both report 30.0 deg and both bail
##
## The slab's top face emerges from the ground at x = 0.879 and the body's radius
## is 0.3, so on that one frame the cylinder is touching the corner where the ramp
## meets the ground rather than the ramp face. A corner has no single normal, and
## the two engines pick differently: Godot Physics answers with the face, Jolt with
## something between the face and the end cap. Neither is wrong.
##
## It scales with the tilt, and that is what makes it a class of geometry rather
## than one unlucky slab. Jolt's steepest reading on the approach, by ramp angle,
## with the frame it lands on:
##
##     10 deg -> 25.6 (f11)   20 deg -> 47.6 (f12)
##     30 deg -> 49.5 (f11)   40 deg -> 76.4 (f11)
##
## So every ramp past ~20 degrees crosses floor_max_angle on one frame of the
## approach and takes a step there; a 10 degree ramp never does.
##
## What it costs, measured: 2 mm. The character ends the 30 degree walk at y 2.545
## under Jolt against 2.543 under Godot Physics, the ramp bench measures the same
## 0.364 slope and the same 6.49 m advanced under both, and the divergence is one
## `stepped_up` signal - a footstep sound on a slope.
##
## THE PART THAT MATTERS, and it took a fourth experiment to find: that step is not
## spurious under Jolt. It is the mechanism.
##
##     a plain CharacterBody3D, no stair stepping at all, same ramp
##       Godot Physics  climbs to y 2.543
##       Jolt           STUCK at x 0.583, y 0.900 - never gets onto the ramp
##
## Jolt's solver reads that corner as too steep to walk, the same way its motion
## query reports it, so move_and_slide will not carry a character onto the slope.
## The stair step at the corner is what does. Suppress it and the character is
## stranded at the foot of every ramp - which is exactly what happened when it was
## tried: case 20's character, walking a ramp with a step at the top of it, stopped
## dead at x 0.705 and climbed nothing.
##
## So the bail's premise - "a walkable surface is move_and_slide's job" - is an
## engine-dependent claim, and case 19 was written against the engine where it
## holds. It now asserts the property that is true on both: the character climbs,
## and does not stair-step its WAY up the slope. Zero steps is what Godot Physics
## does, one is what an ambiguous corner costs, and 77 is what removing the walkable
## bail does - so a ceiling of one keeps the case's teeth.
##
## Four things were tried against this, and they are worth knowing before a fifth:
##
##   - Raising max_collisions to look for a walkable contact behind the steep one.
##     Jolt reports ONE contact at the corner however high the cap goes. (Godot
##     Physics does report a second, the ground at 0 deg - which is exactly why an
##     "any contact walkable" bail would be wrong anyway: a real step reports the
##     ground too.)
##   - Jolt's enhanced internal edge removal, which is already on by default for
##     motion queries. Toggling it changes nothing, because this is an external
##     corner and internal-edge removal is for the seams inside one body.
##   - The slope allowance: bail when the height gained is no more than walking the
##     landing surface forward would have gained. Priced below - the ramp gains
##     +0.0130 against an allowance of 0.0115, so it is on the wrong side by 13%,
##     and only a fudge factor separates it from a real step's +0.1986
##     against 0.0077.
##   - The raised re-sweep: ask again from a few millimetres up, where a corner is
##     no longer ambiguous. This one WORKS as a classifier - the ramp reads its face
##     at 5 mm and a step's riser reads 90 at every lift - and it is still wrong,
##     because what it classifies correctly is a step that has to happen anyway.

const WALK: float = 3.0

## The slab, as case 19 sizes it, and where its top face is to meet the ground.
const RAMP_LENGTH: float = 12.0
const RAMP_THICKNESS: float = 0.5
const RAMP_FOOT_X: float = 0.879

## Case 19's ramp, by its authored numbers rather than by the construction below.
##
## The two are 3.5 mm apart in y, and that is not a rounding difference to wave
## through: measured, the derived slab reports 62.0 degrees at the corner where the
## authored one reports 49.5. Same engine, same frame, same everything else. The
## corner normal is that sensitive, which is itself part of why no threshold on it
## would be safe - and it means the number quoted in the docs has to come from the
## ramp the suite actually builds.
const CASE_19_TILT: float = 30.0
const CASE_19_CENTRE: Vector3 = Vector3(6.2, 2.78, 0.0)
## The control geometry's step, which the check must keep treating as a step.
const STEP_RISE: float = 0.2
## Only the approach to the obstacle is printed - past this the character is on the
## ramp and every frame reports the same face.
const FOOT_WINDOW_X: float = 1.1

const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001
const GRAVITY: float = 9.8
const SETTLE_FRAMES: int = 20
const WALK_FRAMES: int = 90

## Read from the project rather than hardcoded, because the whole point of the
## per-frame sweep below is that it is byte-for-byte the sweep stair_step_up runs -
## and that one uses get_physics_process_delta_time(). Pinning 1/60 here would
## silently break the parity on any project that retunes the tick rate.
var _delta: float = 1.0 / float(Engine.physics_ticks_per_second)

## Case 19's own ramp leads, then shallower and steeper ones - a difference that
## only shows at one angle is an artefact of that one edge, and one that holds
## across the range is the engines disagreeing about corners generally.
var _ramps: PackedFloat32Array = [CASE_19_TILT, 10.0, 20.0, 40.0]

## Packed rather than bare Array literals, which would allocate per call (S6).
var _corner_lifts: PackedFloat32Array = [0.005, 0.01, 0.02]
var _collision_caps: PackedInt32Array = [1, 4]

var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()

# Recorded from the signal, because only the addon knows which frames it stepped
# on. A member rather than a capture (H6).
var _stepped_on_frame: PackedInt32Array = []
var _frame: int = 0


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	print(
		(
			"--- walkable ramps on %s ---"
			% ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT")
		)
	)
	for degrees: float in _ramps:
		await _walk_the_ramp(degrees)
	# The control that decides whether any of this is actionable. If a real step
	# also reports a walkable contact once max_collisions is raised, then reading a
	# walkable contact is not a ramp test and there is nothing here to use.
	await _walk_the_ramp(-1.0)
	# And the control that decides whether the step is a NUISANCE or the mechanism.
	# The bail hands a walkable ramp to move_and_slide on the grounds that
	# move_and_slide will walk it. A plain CharacterBody3D with no stair stepping at
	# all is that claim, tested: if it climbs, the step at the corner is spurious and
	# worth suppressing; if it stalls, the step is what gets the character up.
	await _walk_without_stair_stepping(CASE_19_TILT)
	get_tree().quit(0)


## Where the slab's centre goes so that the lower corner of its TOP face sits at
## (RAMP_FOOT_X, 0) - the point the character actually walks onto, whatever the
## tilt. This is how case 19's ramp was arrived at, but it is NOT how case 19's arm
## here is built: at 30 degrees the authored centre is used verbatim, because the
## construction lands 3.5 mm off it and 3.5 mm is enough to change the number this
## file reports. See CASE_19_CENTRE.
func _ramp_centre(degrees: float) -> Vector3:
	if is_equal_approx(degrees, CASE_19_TILT):
		return CASE_19_CENTRE
	var t: float = deg_to_rad(degrees)
	var along: Vector2 = Vector2(cos(t), sin(t)) * (RAMP_LENGTH * 0.5)
	var out: Vector2 = Vector2(-sin(t), cos(t)) * (RAMP_THICKNESS * 0.5)
	return Vector3(RAMP_FOOT_X + along.x - out.x, along.y - out.y, 0.0)


func _walk_the_ramp(degrees: float) -> void:
	var world: Node3D = Node3D.new()
	add_child(world)

	# The same geometry case 19 builds, placed the same way it places it - the body
	# is what carries the position and the tilt, so the slab rotates about its own
	# centre. Ground spans x in [-10, 12] with its top face at y = 0.
	_box(world, Vector3(22.0, 1.0, 8.0), Vector3(1.0, -0.5, 0.0), 0.0)
	if degrees < 0.0:
		# The control: an ordinary 0.2 m step, whose face starts at x = 1.0 - the
		# thing the check is FOR, and which must keep reading as non-walkable.
		_box(world, Vector3(20.0, 2.0, 8.0), Vector3(11.0, STEP_RISE - 1.0, 0.0), 0.0)
	else:
		_box(world, Vector3(RAMP_LENGTH, RAMP_THICKNESS, 8.0), _ramp_centre(degrees), degrees)

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
	c.stepped_up.connect(_record_step)

	for _i: int in SETTLE_FRAMES:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * _delta
		c.move_and_stair_step()

	_params.margin = COLLIDER_MARGIN
	_stepped_on_frame = []

	var walkable_limit: float = c.floor_max_angle
	for i: int in WALK_FRAMES:
		await get_tree().physics_frame
		_frame = i
		c.velocity.x = WALK
		c.velocity.y -= GRAVITY * _delta
		c.desired_velocity = Vector3(WALK, 0.0, 0.0)

		# The addon's first sweep, run from outside it and BEFORE it, so this sees
		# what the bail is about to see. Anything walkable here is handed to
		# move_and_slide and the other three sweeps never run.
		var before: Transform3D = c.global_transform
		_params.from = before
		_params.motion = Vector3(WALK * _delta, 0.0, 0.0)
		var hit: bool = PhysicsServer3D.body_test_motion(c.get_rid(), _params, _result)
		var normal: Vector3 = _result.get_collision_normal(0) if hit else Vector3.UP
		var angle: float = normal.angle_to(Vector3.UP)

		# Every probe below runs from `before` as well. Sweeping after the move
		# instead is what makes this look like max_collisions changes the answer: by
		# then the body is standing ON the ramp, and of course the ramp face is what
		# it reports.
		if hit and c.global_position.x < FOOT_WINDOW_X:
			print(
				(
					"  frame %2d at x %.3f y %.3f: normal %v, %.1f deg%s"
					% [
						i,
						before.origin.x,
						before.origin.y,
						normal,
						rad_to_deg(angle),
						" - WALKABLE, bails" if angle <= walkable_limit else " - NOT walkable, steps",
					]
				)
			)
			_report_every_contact(c, before, walkable_limit)
			_report_the_rest_of_the_chain(c, before, walkable_limit)

		c.move_and_stair_step()

	var label: String = "a %.0f m step" % STEP_RISE if degrees < 0.0 else "%.0f deg" % degrees
	print(
		(
			"  %s: climbed to y %.3f, stepped up on frames %s"
			% [label, c.global_position.y, str(_stepped_on_frame)]
		)
	)
	world.queue_free()
	await get_tree().process_frame


## The addon leaves max_collisions at 1 and reads get_collision_normal(0), so it
## sees one contact and that contact is the whole of what the bail knows. If the
## engine has a walkable contact to report alongside the steep one, an "any contact
## walkable" bail becomes possible - at the price of a more expensive sweep on every
## frame, and of revisiting both normal(0) reads in the addon. So this asks whether
## that price would buy anything before anyone pays it.
##
## Runs on its own parameters, not the addon's: raising max_collisions on the shared
## _params would leak into the very next real sweep. Both settings are run here, on
## equally fresh objects, so the only variable between them is max_collisions
## itself - which is the claim being made.
func _report_every_contact(c: StairsCharacter, from: Transform3D, walkable_limit: float) -> void:
	for cap: int in _collision_caps:
		var params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
		params.margin = COLLIDER_MARGIN
		params.max_collisions = cap
		params.from = from
		params.motion = Vector3(WALK * _delta, 0.0, 0.0)

		var result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
		if not PhysicsServer3D.body_test_motion(c.get_rid(), params, result):
			print("    max_collisions %d: nothing reported" % cap)
			continue

		var count: int = result.get_collision_count()
		for i: int in count:
			var n: Vector3 = result.get_collision_normal(i)
			var a: float = n.angle_to(Vector3.UP)
			print(
				(
					"    max_collisions %d, contact %d of %d: normal %v, %.1f deg%s"
					% [
						cap,
						i,
						count,
						n,
						rad_to_deg(a),
						" - WALKABLE" if a <= walkable_limit else "",
					]
				)
			)


## What phases two to four see on a frame the bail let through, because the fix for
## this has to come from something the addon can tell apart. Two candidates are
## priced here:
##
##   - the SLOPE ALLOWANCE. If the surface being landed on is walkable, walking
##     forward along it would have gained `forward * tan(angle)` by itself. A step
##     that gains no more than that is one move_and_slide could have taken, so it
##     needs no stair step. Costs nothing - every number is already in hand.
##   - the RAISED RE-SWEEP. A corner is only ambiguous at the corner: sweeping the
##     same motion again from a few millimetres higher should report the face on a
##     ramp and the riser on a step. Costs one extra sweep on frames with a steep
##     contact, which is every stair frame.
func _report_the_rest_of_the_chain(c: StairsCharacter, from: Transform3D, walkable_limit: float) -> void:
	var params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
	params.margin = COLLIDER_MARGIN
	var result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
	var motion: Vector3 = Vector3(WALK * _delta, 0.0, 0.0)

	# The raised re-sweep, before anything else moves, so it is measured from the
	# same place the real first sweep starts.
	for lift: float in _corner_lifts:
		params.from = from.translated(Vector3(0.0, lift, 0.0))
		params.motion = motion
		if not PhysicsServer3D.body_test_motion(c.get_rid(), params, result):
			print("    re-swept %.3f m higher: MISSES - obstacle is shorter than that" % lift)
			continue
		var lifted: float = result.get_collision_normal(0).angle_to(Vector3.UP)
		print(
			(
				"    re-swept %.3f m higher: %.1f deg%s"
				% [lift, rad_to_deg(lifted), " - WALKABLE" if lifted <= walkable_limit else ""]
			)
		)

	# Now the chain itself, to reach the landing surface and the height gained.
	params.from = from
	params.motion = motion
	if not PhysicsServer3D.body_test_motion(c.get_rid(), params, result):
		return
	var remainder: Vector3 = result.get_remainder()
	var motion_transform: Transform3D = from.translated(result.get_travel())

	params.from = motion_transform
	params.motion = c.step_height * Vector3.UP
	PhysicsServer3D.body_test_motion(c.get_rid(), params, result)
	var rise: Vector3 = result.get_travel()
	motion_transform = motion_transform.translated(rise)

	var forward_motion: Vector3 = remainder
	if forward_motion.length() < c.min_step_forward:
		forward_motion = motion.normalized() * c.min_step_forward
	params.from = motion_transform
	params.motion = forward_motion
	PhysicsServer3D.body_test_motion(c.get_rid(), params, result)
	var forward: Vector3 = result.get_travel()
	motion_transform = motion_transform.translated(forward)

	params.from = motion_transform
	params.motion = Vector3.DOWN * rise.length()
	if not PhysicsServer3D.body_test_motion(c.get_rid(), params, result):
		print("    set-down finds nothing")
		return
	motion_transform = motion_transform.translated(result.get_travel())

	var landing: float = result.get_collision_normal(0).angle_to(Vector3.UP)
	var gain: float = motion_transform.origin.y - from.origin.y
	var allowance: float = forward.length() * tan(landing)
	print(
		(
			"    lands on %.1f deg, forward %.4f, gains %+.4f, walking that surface would"
			% [rad_to_deg(landing), forward.length(), gain]
			+ " gain %.4f - slope allowance says %s"
			% [allowance, "BAIL" if gain <= allowance else "step"]
		)
	)


## The same walk up the same ramp with a bare CharacterBody3D, so the only thing
## missing is the stair check itself.
func _walk_without_stair_stepping(degrees: float) -> void:
	var world: Node3D = Node3D.new()
	add_child(world)
	_box(world, Vector3(22.0, 1.0, 8.0), Vector3(1.0, -0.5, 0.0), 0.0)
	_box(world, Vector3(RAMP_LENGTH, RAMP_THICKNESS, 8.0), _ramp_centre(degrees), degrees)

	var c: CharacterBody3D = CharacterBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = BODY_RADIUS
	cyl.height = BODY_HEIGHT
	cyl.margin = COLLIDER_MARGIN
	shape_node.shape = cyl
	c.add_child(shape_node)
	world.add_child(c)
	c.global_position = Vector3(0.0, REST_Y, 0.0)

	for _i: int in SETTLE_FRAMES:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * _delta
		c.move_and_slide()

	for _i: int in WALK_FRAMES:
		await get_tree().physics_frame
		c.velocity.x = WALK
		c.velocity.y -= GRAVITY * _delta
		c.move_and_slide()

	print(
		(
			"  %.0f deg with NO stair stepping at all: reached x %.3f y %.3f"
			% [degrees, c.global_position.x, c.global_position.y]
		)
	)
	world.queue_free()
	await get_tree().process_frame


func _record_step() -> void:
	_stepped_on_frame.append(_frame)


func _box(world: Node3D, size: Vector3, centre: Vector3, tilt_degrees: float) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	world.add_child(body)
	body.global_position = centre
	body.rotation.z = deg_to_rad(tilt_degrees)
