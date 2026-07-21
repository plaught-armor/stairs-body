@icon("res://addons/stairs-character/stairs_character.svg")
extends CharacterBody3D
class_name StairsCharacter

## Emitted on any stair step, in either direction, right after the direction
## specific signal below. It reports one step rather than one frame, so it fires
## twice in a frame where the character steps up onto a plateau and is then
## snapped down off the far edge.
signal stepped
## Emitted when the character has been raised onto a higher surface.
## Fires *before* this frame's move_and_slide, so a handler that writes to
## velocity still affects the movement this frame.
signal stepped_up
## Emitted when the character has been snapped down onto a lower surface.
## Fires *after* this frame's move_and_slide, unlike stepped_up, so a handler
## that writes to velocity only affects the next frame.
signal stepped_down

# Handlers run inside move_and_stair_step, so they must not call back into it,
# and must not free the character - use queue_free if you need to.

@export_category("Stair Stepping")
## Max height the character can step up onto, and be snapped down onto.
## Rule of thumb: 0.15-0.25 x character height, so the default suits a ~2 m one.
## Scale this with your character - the ratio travels, the absolute value does not.
## Past ~0.25 x height a character starts silently climbing crates and low walls.
@export var step_height: float = 0.33

## The character's collision shape. Margin should be as low as you can get it
## without snagging on edges. A CylinderShape3D is strongly recommended: a
## capsule's rounded bottom catches the top corner of a step and reports a
## steep contact normal, which the floor_max_angle check then rejects.
@export var collider: CollisionShape3D

@export_category("Step Smoothing")
## The visual node whose local Y the addon eases after a step, so the camera or
## mesh does not pop the instant the body snaps up or down. Leave it unassigned
## and smoothing is off - the body still snaps exactly as before, which is the
## behaviour every existing scene already has.
##
## This must NOT be the character body itself. The body is the collider, and it
## has to sit at the stepped height the moment the step resolves or move_and_slide
## depenetrates it, is_on_floor reads false, and the step check re-fires next
## frame. Only a *child* can be moved freely, so point this at a dedicated pivot
## between the body and the camera - body -> smooth_node -> camera. The addon owns
## this node's local Y; anything else that writes to it (camera bob, recoil) must
## live on a child of it, or each frame's decay write will wipe that motion.
@export var smooth_node: Node3D

## How fast the visual catches up to the snapped body, as an exponential decay
## rate: higher is snappier. The time constant is 1 / step_smoothing seconds, so
## the default 20 settles in about 150 ms - roughly the Source engine feel. Drop
## toward 8-10 for a floatier rise, push past 30 for an almost-instant one.
##
## Zero turns smoothing off without unassigning smooth_node: the offset is forced
## to zero every frame, so the visual tracks the body rigidly. The decay is
## framerate independent (exp(-rate * dt)), so the same value feels the same at 60
## and 144 Hz.
@export_range(0.0, 60.0, 0.5) var step_smoothing: float = 20.0

# Private variables

# Scratch for the motion tests, held rather than allocated per call (P20).
# Upstream built a fresh pair inside each step function, so up to four objects
# per character per frame for pure scratch. Sharing one pair is safe because both
# functions overwrite `from` and `motion` before every body_test_motion and read
# the result immediately after, so nothing carries between calls.
#
# Worth what it costs, but only just: measured at 0.66 us per character per frame
# (test/bench_alloc.gd), against roughly 30 us of stepping work, so about 2%. The
# four body_test_motion sweeps dominate everything around them.
#
# `margin` is the one field meant to persist - it is the resolved collider margin
# and the only copy of it. If anything ever sets the other parameter fields
# (exclude_bodies, max_collisions, recovery_as_collision) it must reset them too,
# because unlike a fresh instance this one does not start from defaults. Raising
# max_collisions in particular means revisiting both get_collision_normal(0)
# calls below, which are only unambiguous while a sweep reports a single contact.
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()

# We don't want to take the player's vertical speed into account, usually
const _HORIZONTAL: Vector3 = Vector3(1, 0, 1)

# Fallback for a character with no usable collider, and the threshold past which
# a margin is worth warning about.
const _DEFAULT_MARGIN: float = 0.01

# Below this the residual offset is close enough to home to snap and stop, rather
# than chase an exponential tail that never quite reaches zero.
const _SMOOTH_EPSILON: float = 0.0001

# The visual offset the decay chases back to zero, and the rest local Y it decays
# toward. On a step the body snaps and this is bumped the opposite way, so the
# child stays put in world space for one frame and then eases home. Rest is
# captured at NOTIFICATION_READY so a smooth_node authored at a non-zero local Y
# still settles where it was placed rather than at zero.
var _smooth_offset_y: float = 0.0
var _smooth_rest_y: float = 0.0

# Public variables

# Use was_grounded instead of is_on_floor() - because of the stair step mechanism, sometimes this
# script will snap the player to the floor, but is_on_floor() will still read as false.
#
# Both are refreshed at the top of move_and_stair_step, before it moves anything,
# so they lag by design: after the call `grounded` holds is_on_floor() as it
# stood at the *start* of this frame, which is the result of last frame's
# movement, and `was_grounded` the frame before that. Neither ever reports this
# frame's post-move state, so don't reach for them to answer "did I just land" -
# is_on_floor() answers that, with the snapping caveat above.
#
# The lag is what the step functions want. stair_step_up runs before this frame's
# move_and_slide, so start-of-frame ground state is the correct input for it, and
# stair_step_down keys off the frame before that.
#
# Case 24 pins `grounded` - that it reports the previous frame's is_on_floor
# rather than this one's. It does NOT pin stair_step_down's use of `was_grounded`
# over `grounded`: a mutation audit swapped that and the whole suite still
# passed. That is expected rather than a hole, for the reason set out on the
# guard itself, which measured the two as producing identical outcomes and keeps
# `was_grounded` for the cases it cannot easily stage. Read that note before
# changing it - the choice is deliberate and deliberately untested.
var grounded: bool
var was_grounded: bool

# Force a stair step check this frame even when not grounded.
# I use this for things like wall jumps, where it feels like you should've
# been able to land on a ledge but snagged just below it.
# Cleared by move_and_stair_step, so it only applies to the frame you set it in.
# It lifts the grounded requirement, not every check: a forward collision with a
# surface shallow enough to walk on still short-circuits the step, since
# move_and_slide handles that case. Ledges present a vertical face, so the ones
# this flag exists for are unaffected.
var force_stair_step: bool = false

# DesiredVelocity should be set in your character controller just so we know where we _want_ to go.
# Set it before you call move_and_stair_step, which consumes it and then clears it.
# Should match the direction where your input wants to take you.
# Only the horizontal part is read, so passing a whole movement vector with
# gravity already folded in is fine.
var desired_velocity: Vector3 = Vector3.ZERO


# Replace your move_and_slide with this function.
# The grounded bookkeeping lives here rather than in _physics_process on purpose:
# this class is meant to be subclassed, and a subclass that defines its own
# _physics_process replaces the parent's, which left grounded stuck at false and
# silently disabled every step up. This function is the one thing every user
# provably calls.
func move_and_stair_step() -> void:
	was_grounded = grounded
	grounded = is_on_floor()

	stair_step_up()
	move_and_slide()
	stair_step_down()

	# Cleared at the end, not the start: the controller sets these just before
	# calling us, so clearing on entry would wipe the intent it just expressed.
	desired_velocity = Vector3.ZERO
	force_stair_step = false


# Hooked to NOTIFICATION_READY rather than to _ready(): this class is meant to be
# subclassed, and a subclass defining its own _ready replaces the parent's, which
# left the margin at 0.0 and ran every motion test with the wrong value.
# _notification is the one virtual Godot dispatches to *every* script in the
# inheritance chain, so a subclass cannot shadow this even by overriding
# _notification itself. Verified on 4.8.dev, both bodies run, base first.
func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		_resolve_margin()
		_init_step_smoothing()
	# NOTIFICATION_PROCESS is dispatched to _notification on every script in the
	# chain, so a subclass defining its own _process cannot switch this off the way
	# it could shadow a _process method - the same reason margin resolution hangs
	# off NOTIFICATION_READY above. get_process_delta_time is the render-frame dt,
	# which is what visual smoothing wants: it runs once per drawn frame, not once
	# per physics tick.
	elif what == NOTIFICATION_PROCESS:
		_tick_step_smoothing(get_process_delta_time())


# Compatibility shim for scenes authored against the old `_step_height` name.
# Godot silently drops a saved property whose name no longer exists on the
# script, so without this a character that was tuned to 0.5 would come back at
# the 0.33 default with nothing logged - the tuning just quietly disappears.
# Unknown properties are routed here at load time, so the authored value lands.
#
# A scene storing both names is the one case to know about: Godot applies stored
# properties in the order they appear in the .tscn, so if `_step_height` sits
# below `step_height` it wins, and the newer value is the one that gets lost.
# Re-saving fixes it permanently, since the old name is no longer serialised.
# Drop this at the next breaking release.
func _set(property: StringName, value: Variant) -> bool:
	if property != &"_step_height":
		return false

	# `value` arrives as a Variant, and `step_height` is a typed float, so a
	# stored value that is not a number aborts this function on the assignment
	# below with a bare engine error - "Trying to assign value of type 'String'
	# to a variable of type 'float'" - naming neither the addon nor the property
	# that caused it, and skipping the warning below on the way out. Refusing it
	# here is what turns that into a message a user can act on.
	#
	# The `true` is idiom rather than mechanism: for a property Godot has no
	# other home for, returning true and returning false were measured to behave
	# identically at scene load, so the push_error is doing the actual work. True
	# is still the honest answer - the shim did handle this property, by
	# rejecting it on purpose.
	var value_type: int = typeof(value)
	if value_type != TYPE_FLOAT and value_type != TYPE_INT:
		push_error(
			(
				"[StairsCharacter] '_step_height' was stored as %s, expected a number - "
				% type_string(value_type)
				+ "the value was discarded, set 'step_height' on the node instead"
			)
		)
		return true

	step_height = value
	push_warning(
		(
			"[StairsCharacter] '_step_height' has been renamed to 'step_height' - "
			+ "the saved value was applied, re-save the scene to update it"
		)
	)
	return true


# Resolved here, then trusted (M10) - the step functions use the resolved
# _params.margin directly and never re-check. Runs again if NOTIFICATION_READY re-fires, which
# only happens after request_ready(), and re-resolving is the right answer there:
# the collider may have been swapped while the node was out of the tree. The
# warnings repeat in that case, which is a fair trade for not going stale.
func _resolve_margin() -> void:
	if collider == null:
		# Upstream hardcoded this node name. Kept as a fallback so existing
		# scenes keep working without reassigning the export.
		collider = get_node_or_null(^"Collider") as CollisionShape3D

	if collider == null:
		push_error(
			"[StairsCharacter] 'collider' is unassigned and no child CollisionShape3D named "
			+ "'Collider' was found - using default margin"
		)
		_params.margin = _DEFAULT_MARGIN
		return

	if collider.shape == null:
		push_error(
			"[StairsCharacter] collider '%s' has no shape assigned - using default margin"
			% collider.name
		)
		_params.margin = _DEFAULT_MARGIN
		return

	_params.margin = collider.shape.margin
	if _params.margin > _DEFAULT_MARGIN:
		push_warning(
			"[StairsCharacter] collider margin %.3f > %.2f, may snag on stair steps"
			% [_params.margin, _DEFAULT_MARGIN]
		)
	if not (collider.shape is CylinderShape3D):
		push_warning(
			(
				"[StairsCharacter] collider shape is %s - a CylinderShape3D is recommended, "
				+ "rounded shapes catch the top corner of a step and get rejected by floor_max_angle"
			)
			% collider.shape.get_class()
		)


# Runs at NOTIFICATION_READY, which re-fires after request_ready() - so this
# resets the offset rather than leaving a mid-decay value to be re-applied against
# a freshly captured rest, which would pop the visual for one frame.
#
# Idle processing is only ever turned ON here, never off. A subclass that defines
# its own _process has idle processing auto-enabled by the engine, and toggling it
# off from this base handler - which runs after the subclass is set up - would
# silently kill that _process, the same shadowing trap NOTIFICATION_READY exists
# to avoid. When smooth_node is null we leave processing untouched; _tick_step_smoothing
# returns immediately in that case, so the per-frame cost is one branch at most.
func _init_step_smoothing() -> void:
	_smooth_offset_y = 0.0
	if smooth_node == null:
		return
	_smooth_rest_y = smooth_node.position.y
	set_process(true)


# Called from the two apply sites with the signed height the body just moved:
# positive up, negative down. The visual is pushed the opposite way, so it holds
# its world position for a frame before the decay pulls it home.
func _accumulate_step_smoothing(step_delta_y: float) -> void:
	if smooth_node == null or step_smoothing <= 0.0:
		return

	# Only ease genuine steps. A jump larger than a full step in either direction
	# is a teleport, a respawn, or an external shove - easing that would drag the
	# camera across the whole distance. step_height is the most the body can move
	# in one legitimate step up; a snap down can add floor_snap_length on top, so
	# the gate is generous at twice step_height rather than exactly it.
	if absf(step_delta_y) > step_height * 2.0:
		return

	# Clamped to one step_height so a burst of steps in quick succession cannot
	# stack the offset into a visible lurch larger than a single step.
	_smooth_offset_y = clampf(_smooth_offset_y - step_delta_y, -step_height, step_height)


# Render-frame decay of the visual offset back to the rest position. Framerate
# independent: exp(-rate * dt) closes the same fraction of the remaining distance
# per second whatever the frame rate, unlike a fixed-fraction lerp.
func _tick_step_smoothing(delta: float) -> void:
	if smooth_node == null:
		return

	# step_smoothing of zero means "off": collapse the offset immediately so the
	# visual tracks the body rigidly, rather than freezing at whatever offset an
	# earlier non-zero setting left behind.
	if step_smoothing <= 0.0:
		_smooth_offset_y = 0.0
	else:
		_smooth_offset_y *= exp(-step_smoothing * delta)
		if absf(_smooth_offset_y) < _SMOOTH_EPSILON:
			_smooth_offset_y = 0.0

	smooth_node.position.y = _smooth_rest_y + _smooth_offset_y


func stair_step_down() -> void:
	# Don't step down if we weren't on the ground before this frame's movement.
	# `was_grounded` reaches back two frames rather than one - see the note on the
	# flags above - so this guard stays open for a frame after a character has
	# actually left the ground.
	#
	# Switching it to `grounded` was tried and measured rather than argued about.
	# Across 36 walk-off-a-ledge runs (4 speeds from 1 to 15 m/s, 9 drops from
	# 0.05 to 0.5, spanning both sides of step_height) the frame where the two
	# flags disagree produced a snap exactly zero times: by then the character has
	# either already been snapped on an earlier frame or the surface is out of
	# reach. So the extra frame costs one sweep that finds nothing and changes no
	# outcome, and the whole suite passes either way.
	#
	# Left on `was_grounded` because that is the side that errs forgiving - the
	# frame a walker crosses an edge is exactly the frame a snap is wanted - and
	# because a tick rate, a moving platform, or velocity from outside the
	# controller could all put a reachable surface under that divergent frame,
	# which is a case the sweep should be allowed to find.
	if not was_grounded or velocity.y >= 0:
		return

	_params.from = global_transform
	_params.motion = Vector3.DOWN * step_height
	# Nothing to step down on
	if not PhysicsServer3D.body_test_motion(get_rid(), _params, _result):
		return

	# Measured across the whole downward move - the snap travel plus whatever
	# apply_floor_snap adds - so the visual eases the full drop the eye sees.
	var pre_step_y: float = global_position.y
	global_transform = global_transform.translated(_result.get_travel())
	apply_floor_snap()
	_accumulate_step_smoothing(global_position.y - pre_step_y)

	stepped_down.emit()
	stepped.emit()


func stair_step_up() -> void:
	if not grounded and not force_stair_step:
		return

	# The fallback is flattened the same way actual velocity is. A controller that
	# hands over its whole movement intent - input plus gravity - puts a vertical
	# component in here, and an unflattened one aims the first sweep forward and
	# down, so it reaches the ground before the step face. The ground reports a
	# walkable normal and the bail below throws away a step that should have
	# happened. Flattening also lets a purely vertical intent fall through the
	# zero-check, rather than running four sweeps on a straight-up test velocity.
	var horizontal_velocity: Vector3 = velocity * _HORIZONTAL
	var testing_velocity: Vector3 = (
		horizontal_velocity
		if horizontal_velocity != Vector3.ZERO
		else desired_velocity * _HORIZONTAL
	)

	# Not moving or attempting to move, skip stair check
	if testing_velocity == Vector3.ZERO:
		return

	# This variable gets reused for all the following checks
	var motion_transform: Transform3D = global_transform

	# If you use this function you don't need to pass delta everywhere :D
	var distance: Vector3 = testing_velocity * get_physics_process_delta_time()
	_params.from = motion_transform
	_params.motion = distance

	# No stair step to do, we didn't hit any walls
	if not PhysicsServer3D.body_test_motion(get_rid(), _params, _result):
		return

	# Contact 0 is the only contact, since max_collisions is left at its default
	# of 1, and it is the earliest point of impact.
	# If what we hit is shallow enough to walk on, move_and_slide will walk up it
	# and there is no step to take. Bailing here skips the three remaining sweeps,
	# which is most of the cost of this function: a sweep is ~4.3 us against the
	# ~0.66 us the query objects cost to allocate (test/bench_sweep.gd). Without
	# this, a character walking up a ramp runs the full check and succeeds on
	# nearly every frame, stair stepping its way up a slope.
	if _result.get_collision_normal(0).angle_to(Vector3.UP) <= floor_max_angle:
		return

	# Move to collision
	var remainder: Vector3 = _result.get_remainder()
	motion_transform = motion_transform.translated(_result.get_travel())

	# Raise up to ceiling - can't walk on steps if there's a low ceiling
	var step_up: Vector3 = step_height * Vector3.UP
	_params.from = motion_transform
	_params.motion = step_up
	PhysicsServer3D.body_test_motion(get_rid(), _params, _result)
	# GetTravel will be full length if we didn't hit anything
	var step_up_travel: Vector3 = _result.get_travel()
	motion_transform = motion_transform.translated(step_up_travel)
	var step_up_distance: float = step_up_travel.length()

	# A ceiling left us no room to rise, so there is no height to step onto and
	# the last two sweeps would only confirm it. Movement below the collision
	# margin is not movement - strictly below, because a motion of exactly the
	# margin is what the collision boundary produces on a legitimate touch.
	#
	# Mostly an optimisation. Deleting it changes no POSITIONAL outcome anywhere in
	# the 81-row ceiling grid (test/diag_phase2.gd): with the rise clamped to
	# nothing the forward sweep below is blocked from the same place and bails on
	# its own, so what the bail saves is the two sweeps it takes to get there.
	#
	# Not purely an optimisation, though, and the difference is signals rather than
	# position. In a narrow window - clearance around 1.5x the margin, at speed -
	# removing it lets the check run to the end and emit stepped_up on a frame that
	# moves the body nowhere. So a mutation audit finding its removal "survives" is
	# a statement about the cases that exist, not proof that none could be written.
	if step_up_distance < _params.margin:
		return

	# Move forward remaining distance
	_params.from = motion_transform
	_params.motion = remainder
	PhysicsServer3D.body_test_motion(get_rid(), _params, _result)
	var forward_travel: Vector3 = _result.get_travel()
	var forward_distance: float = forward_travel.length()
	motion_transform = motion_transform.translated(forward_travel)

	# Raising the body did not get it past the obstacle, so whatever we walked
	# into is taller than step_height and there is no ledge to come down onto.
	# This is the character-pressed-against-a-wall case, which is otherwise a
	# permanent four sweeps a frame to reach the same conclusion.
	#
	# Strictly below the margin, not at it: on the frame a walker first touches a
	# step, the first sweep stops exactly one margin short, so the remainder this
	# sweep moves is exactly the margin. Bailing there would postpone a real step
	# by a frame - unnoticeable while walking, but force_stair_step ledge catches
	# get one frame before gravity carries the character past the ledge.
	if forward_distance < _params.margin:
		return

	# And set the collider back down again
	_params.from = motion_transform
	# But no further than how far we stepped up
	_params.motion = Vector3.DOWN * step_up_distance

	# Don't bother with the rest if we're not actually gonna land back down on something
	if not PhysicsServer3D.body_test_motion(get_rid(), _params, _result):
		return

	motion_transform = motion_transform.translated(_result.get_travel())

	# Defensive, and deliberately untested. A mutation audit deleted this check and
	# the whole suite passed, so a case was attempted - and the geometry needed to
	# reach it turned out to be a knife edge. Searching 192 shapes
	# (test/diag_steep_landing.gd) found 188 that reach this line at all and only 4
	# whose landing face is steeper than floor_max_angle, and in those, moving the
	# obstacle 5 mm flips the outcome. A test pinned on that would fail on drift
	# rather than on regressions.
	#
	# The reason it is so hard to reach: to land on a steep face the body must
	# first get FORWARD past something, and anything steep enough to matter is
	# usually also tall enough to stop the forward sweep, which bails above. Keep
	# the check - it costs one comparison and the alternative is standing on a
	# wall - but do not read the missing test as an oversight.
	var surface_normal: Vector3 = _result.get_collision_normal(0)
	if surface_normal.angle_to(Vector3.UP) > floor_max_angle:
		return #Can't stand on the thing we're trying to step on anyway

	# Move player to match the step height we just found
	var pre_step_y: float = global_position.y
	global_position.y = motion_transform.origin.y
	_accumulate_step_smoothing(global_position.y - pre_step_y)

	stepped_up.emit()
	stepped.emit()
