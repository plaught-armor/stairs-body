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

## How far the character can be snapped back down onto a surface, if that should
## differ from how far it can climb. Negative - the default - follows step_height,
## which is what this class has always done and what every existing scene expects.
##
## Worth splitting when up and down want different generosity. A short reach down
## against a tall reach up keeps a character from being hauled onto every ledge it
## walks off, which reads as heavy; a long reach down against a short reach up
## keeps it glued to stairs it can only just climb. Unreal and the stair-step demos
## both carry the pair as separate numbers for this reason.
##
## Reach is what this bounds, not what gets committed: the snap moves the body to
## whatever it lands on within reach, so a bigger number finds more surfaces rather
## than dropping the character further onto the one it would have found anyway.
@export var step_down_height: float = -1.0

## Smallest distance the forward leg of the step check will probe, whatever the
## tick rate. Every distance in the check comes from velocity * delta, and below
## this floor the check stalls outright rather than degrading - see the note on
## _MIN_STEP_FORWARD. Zero removes the floor and restores the pre-fix behaviour,
## which is a stall waiting for a high enough tick rate; it exists to be measured
## against, not to be shipped.
@export_range(0.0, 0.2, 0.001) var min_step_forward: float = _MIN_STEP_FORWARD

## How many times the forward leg may slide along a contact and sweep again. One
## means the old single sweep, which cannot climb a staircase with a wall beside
## it. Past a handful there is nothing left to gain: each slide strictly shrinks
## the motion, so the leg runs out of length long before it runs out of iterations.
@export_range(1, 8) var step_slide_iterations: int = _FORWARD_SLIDE_ITERATIONS

## Move horizontally and vertically as two separate passes rather than one
## combined move. Off by default: it changes how every frame resolves, not just
## the ones near a step, so it is not something to switch on for an existing
## project without walking it.
##
## What it buys, measured: a climb keeps its speed. Running an eight-tread
## staircase at 8 m/s covers the full 12.00 m with the split and 11.57 m without;
## at 14 m/s, 21.00 m against 20.30 m (test/diag_faststairs.gd).
##
## Not what it was written for. dresswithpockets' version exists to stop
## "mis-steps" - frames that end in mid-air while running stairs, which switch the
## step check off because it needs to be grounded. That failure does not happen
## here: the same runs report zero airborne frames with the split both off and on,
## because stair_step_down already catches them.
##
## What it costs: 28% more per character per frame, measured on the ramp bench
## (48.2-48.8 us combined against 61.6-62.2 us split, three runs). That is the
## second move_and_slide, not anything about slopes - the measured slope is 0.364
## either way, and the split covers 6.62 m of a 20 degree ramp where the combined
## move covers 6.49 m, the same slight speed retention it shows on stairs.
##
## What it also costs: a post-move API that reports only the second pass -
## get_slide_collision_count, get_last_slide_collision and get_wall_normal all
## describe the vertical move, so a wall scraped horizontally is invisible to a
## controller reading them after the call. Assumes up_direction is the default
## Vector3.UP; a rotated one is checked for and refused at boot.
@export var split_move: bool = false

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

# Floor under the forward leg of the step check, in metres.
#
# Every distance in stair_step_up comes from velocity * delta, so the whole check
# shrinks with the tick rate. The failure is not a near miss but a permanent
# stall: once move_and_slide has parked the body a probe length short of a step,
# the probe reaches the face and leaves a remainder of nothing, the forward sweep
# below moves that nothing, and the margin bail rejects it - on every frame after,
# because the body never moves again. Measured on 4.8.dev (test/diag_tickrate.gd)
# a 3 m/s walk into a 0.2 m step stalls at 240 Hz and a 0.5 m/s one at 240 and
# 480, while 60 Hz clears every speed.
#
# Jolt carries the same floor for the same reason - CharacterVirtual's
# mWalkStairsMinStepForward, also 0.02, commented "at very high frame rates the
# delta time may be very small, causing a very small step forward".
#
# It only ever lengthens a probe, never the committed movement: the common path
# commits Y alone and leaves the horizontal to move_and_slide. Two cases commit
# the probed horizontal too and so can seat the body up to this far onto the step
# - a standstill, and a frame whose whole reach is shorter than this. Both are
# spelled out at the commit site, and both are cases that are stuck otherwise.
const _MIN_STEP_FORWARD: float = 0.02

# Bounded (NASA rule 2) slide iterations for the forward leg. Walking head-on
# into a wall slides to zero on the first try and breaks out, so the ordinary
# blocked case still costs one sweep; only motion that survives a slide pays for
# more.
const _FORWARD_SLIDE_ITERATIONS: int = 4

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
	if split_move:
		_move_split()
	else:
		move_and_slide()
	stair_step_down()

	# Cleared at the end, not the start: the controller sets these just before
	# calling us, so clearing on entry would wipe the intent it just expressed.
	desired_velocity = Vector3.ZERO
	force_stair_step = false


# split_move takes the frame apart along Y, and _HORIZONTAL hardcodes which axis
# that is. A character with a rotated up_direction - a wall walker, a floating
# controller - would get its passes split along an axis move_and_slide does not
# agree is horizontal, and the result is not a near miss but a different movement
# model. Refused at boot rather than left to be discovered.
#
# Only checked when split_move is on. The combined path does not care, and
# stair_step_up's own use of _HORIZONTAL predates this and is unchanged by it.
func _check_split_move_assumptions() -> void:
	if not split_move:
		return
	if not up_direction.is_equal_approx(Vector3.UP):
		push_error(
			(
				"[StairsCharacter] split_move needs the default up_direction, got %v - "
				% up_direction
				+ "turning split_move off"
			)
		)
		split_move = false


# Two move_and_slide calls instead of one: horizontal first, then vertical, with
# velocity reassembled from what each pass gave back. dresswithpockets' write-up
# moves this way and names the failure it is for - running stairs fast enough that
# a combined move ends the frame in mid-air, which reads as not grounded and turns
# the step check off for the frame that most needed it.
#
# The reassembly is the fiddly part. Each pass writes its own result back into
# velocity, so the horizontal one has to be saved before the vertical one runs or
# the vertical pass's zeroes overwrite it. What comes out is the horizontal from
# the first pass and the vertical from the second, which is the same shape a
# single call would have produced had the two not interfered.
#
# is_on_floor comes from the last call, so it reports the vertical pass - the pass
# that actually meets the floor. So does every other post-move getter, which is
# the API cost named on the export above.
func _move_split() -> void:
	var falling: float = velocity.y

	velocity = velocity * _HORIZONTAL
	move_and_slide()
	var slid: Vector3 = velocity * _HORIZONTAL

	# The platform push is applied by move_and_slide itself, before it looks at the
	# character's own velocity, so a frame that calls it twice rides the platform
	# twice. Measured (test/diag_platform.gd) a rider with no input of its own
	# drifted 7.417 m across a platform that travelled 7.500 m - it is carried off
	# the front at very nearly platform speed, which is not a subtle wrongness.
	#
	# The layers are the lever. move_and_slide recomputes the push each call and
	# drops it to zero when the floor's layer is not in platform_floor_layers, so
	# clearing them for the second pass suppresses the second push without touching
	# how the floor itself is detected. The first pass keeps the push, which is the
	# one the frame is owed.
	#
	# Costs one thing worth naming: platform_on_leave also reads the suppressed
	# value, so a character that steps off a platform during the vertical pass does
	# not inherit its velocity. The horizontal pass is what carries a walker off an
	# edge, and that one is untouched.
	var floor_layers: int = platform_floor_layers
	var wall_layers: int = platform_wall_layers
	platform_floor_layers = 0
	platform_wall_layers = 0

	velocity = Vector3(0.0, falling, 0.0)
	move_and_slide()

	platform_floor_layers = floor_layers
	platform_wall_layers = wall_layers

	velocity = slid + Vector3(0.0, velocity.y, 0.0)


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
		_check_split_move_assumptions()
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


# How far down the snap may reach, resolving the "follow step_height" default.
# Read at every use rather than resolved once, because both numbers are plain
# exports a controller is free to retune between frames - a crouch that lowers the
# step reach, a difficulty setting - and caching would hold the old pair until
# something re-ran the resolve.
func _step_down_reach() -> float:
	return step_height if step_down_height < 0.0 else step_down_height


# Called from the two apply sites with the signed height the body just moved:
# positive up, negative down. The visual is pushed the opposite way, so it holds
# its world position for a frame before the decay pulls it home.
func _accumulate_step_smoothing(step_delta_y: float) -> void:
	if smooth_node == null or step_smoothing <= 0.0:
		return

	# Only ease genuine steps. A jump larger than a full step in either direction
	# is a teleport, a respawn, or an external shove - easing that would drag the
	# camera across the whole distance. The larger of the two reaches is the most
	# the body can move in one legitimate step; a snap down can add
	# floor_snap_length on top, so the gate is generous at twice that rather than
	# exactly it. Taking the larger rather than the matching one keeps this a single
	# comparison, and the cost of being generous here is only that a teleport of
	# between one and two steps is eased instead of skipped.
	var reach: float = maxf(step_height, _step_down_reach())
	if absf(step_delta_y) > reach * 2.0:
		return

	# Clamped to one step so a burst of steps in quick succession cannot stack the
	# offset into a visible lurch larger than a single step.
	_smooth_offset_y = clampf(_smooth_offset_y - step_delta_y, -reach, reach)


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
	_params.motion = Vector3.DOWN * _step_down_reach()
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

	# Both inputs are flattened the same way. A controller that hands over its
	# whole movement intent - input plus gravity - puts a vertical component in
	# here, and an unflattened one aims the first sweep forward and down, so it
	# reaches the ground before the step face. The ground reports a walkable normal
	# and the bail below throws away a step that should have happened. Flattening
	# also lets a purely vertical intent fall through the zero-check, rather than
	# running four sweeps on a straight-up test velocity.
	var horizontal_velocity: Vector3 = velocity * _HORIZONTAL
	var intent: Vector3 = desired_velocity * _HORIZONTAL

	# Probe along whichever is larger: actual velocity, or the intent the
	# controller declared in desired_velocity. They usually agree, but pressed
	# head-on into a step from a standstill they do not: move_and_slide zeroes the
	# into-wall component of velocity every frame, and an acceleration-based
	# controller (move_toward, friction) can only rebuild it to accel*delta before
	# the next frame's wall contact kills it again - so velocity stays pinned near
	# zero and the probe distance (testing_velocity * delta) shrinks to nothing,
	# never reaching far enough onto the step to register a rise. desired_velocity
	# carries the full intended speed, unpolluted by the collision, so it drives
	# the probe when velocity cannot. carried_by_velocity records which won,
	# because the apply site below needs to know: a step the probe found on intent
	# alone has no velocity behind it for move_and_slide to seat with.
	#
	# Two guards keep velocity as the trusted signal:
	#   - it is at least as fast as intent (the ordinary moving case), or
	#   - it points against intent (dot < 0). This is the backpressure case -
	#     knockback, an explosion, a shove - where the controller still holds
	#     forward but the body is being pushed back. Intent is larger there, so
	#     without this the probe would seat the body forward onto the step while
	#     move_and_slide carries it backward, popping it on and off the lip each
	#     frame. Trusting the opposing velocity instead leaves it to move_and_slide,
	#     which is what handled it before the fix. A wall-pinned near-zero velocity
	#     still dots positive with intent (both point forward), so it correctly
	#     falls through to intent - the bug this fixes is untouched.
	#
	# Backward compatible - a controller that never sets desired_velocity leaves
	# intent at zero, so both guards hold (0 >= 0, dot is 0 not negative) and this
	# reduces to the original "use velocity" behaviour. The old code fell to
	# desired_velocity only when the *horizontal* velocity was exactly zero; the
	# magnitude test widens that to "whenever intent is the stronger forward
	# signal", which is what a near-zero-but-not-zero wall-pinned velocity needs.
	# Ties in magnitude break to velocity, keeping the probe aligned with the body's
	# real motion when the two speeds match.
	var carried_by_velocity: bool = (
		horizontal_velocity.length_squared() >= intent.length_squared()
		or horizontal_velocity.dot(intent) < 0.0
	)
	var testing_velocity: Vector3 = horizontal_velocity if carried_by_velocity else intent

	# Not moving or attempting to move, skip stair check
	if testing_velocity == Vector3.ZERO:
		return

	# If you use this function you don't need to pass delta everywhere :D
	var delta: float = get_physics_process_delta_time()
	var distance: Vector3 = testing_velocity * delta

	# Where the floor is about to carry the body, which is where the sweeps have to
	# start from when that floor is moving.
	#
	# This runs before move_and_slide, and move_and_slide is what re-seats the body
	# on a moving platform - it applies the floor's velocity before it looks at the
	# character's own. So at this moment the body is still standing where the last
	# frame left it while the platform has moved on, and every sweep below measures
	# from a position one platform-frame stale. On a staircase bolted to a moving
	# platform that inflates the gap to the next step by exactly the platform's
	# travel: measured (test/diag_platform_probe.gd) a 5 m/s platform put the step
	# face 0.0919 m away when the probe was 0.05 m, so the sweep missed on that
	# frame and on every frame after, and the character never climbed.
	#
	# Offsetting the start by the same displacement move_and_slide is about to apply
	# puts the sweep where the body will actually be. Co-moving geometry stays
	# consistent, which is what makes this different from lengthening the probe:
	# the step moved with the platform too, so the offset cancels and a character
	# standing still on a moving platform still finds nothing to climb.
	#
	# Vertical is carried too, and it has to be subtracted again at the commit or it
	# rides into the step height and moves the rise by a frame of lift travel. That
	# pairing is the whole of it, and it is what a descending lift needs.
	#
	# The failure it fixes, measured (test/diag_lift_probe.gd): a staircase on a lift
	# descending at 1 m/s stepped up on EVERY frame and was snapped back down on
	# every frame - 47 of each in 60 frames, gaining nothing. The sweeps were never
	# at fault; replayed by hand on a stalled frame all four succeeded and reported a
	# +0.20 m step. What the commit could not survive was the move that follows it:
	# move_and_slide applies the floor's displacement as its own move BEFORE the
	# character's, so a body committed to the tread height and left behind the lip -
	# the ordinary Y-only commit, with the horizontal owed to move_and_slide - was
	# dropped a frame of lift travel below that lip first, and the forward move then
	# met the step face side-on and slid straight back down. Committing one carry
	# higher lets that push land the body exactly on the lip, which is where a static
	# floor has it, and the forward move clears as it always did.
	#
	# Static floors and horizontal platforms report zero here, so neither changes.
	#
	# What this is exact for is a platform at steady state, which is what it is
	# read as. get_platform_velocity is last frame's observation, so on any frame
	# where the platform's motion CHANGES - boarding it, leaving it, accelerating,
	# stopping dead, reversing - the offset describes the frame before rather than
	# this one. Every one of those is a single frame that the next observation
	# corrects, and none is worse than the un-offset behaviour they replace, but
	# they are the frames where this is an approximation rather than a correction.
	# The one that bites hardest is a platform reversing at speed, where the offset
	# points the wrong way entirely for that frame - and now by twice the travel
	# rather than once, since the commit nets off a carry the platform no longer has.
	#
	# Measured rather than left as a worry (test/diag_platform_stairs.gd): a lift
	# reversing between +1 and -1 m/s every 1, 2, 5 and 20 frames climbs the full
	# 0.80 m at every one of those periods. The un-offset code it replaces managed
	# 0.40 m on the 20-frame flip, so the frames where this is least exact are still
	# ahead of where they were. What the fast flips do cost is contact: the grounded
	# fraction falls to 0.36 when the lift reverses every frame or two, against 1.00
	# for a lift that holds its direction.
	#
	# Grounded only. get_platform_velocity holds what the LAST move_and_slide saw,
	# so an airborne frame - a force_stair_step ledge catch one frame after jumping
	# off a moving platform - would still be carrying that platform's velocity and
	# would aim the sweep at a displacement nothing is about to apply.
	var platform_carry: Vector3 = Vector3.ZERO
	if grounded:
		platform_carry = get_platform_velocity() * delta

	# This variable gets reused for all the following checks
	var motion_transform: Transform3D = global_transform.translated(platform_carry)
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

	# Move forward remaining distance, sliding along anything it meets on the way.
	#
	# A single sweep that stops at its first contact cannot climb a staircase with
	# a wall beside it: hold a diagonal into the wall and the wall, not the step,
	# is what the first sweep hits, so the remainder still points into it and this
	# leg travels nothing. Measured on 4.8.dev (test/diag_wallhug.gd) the character
	# is pinned at the foot of the first step for as long as the push is held,
	# while the same walk one push away from the wall climbs. Sliding the leftover
	# motion along the contact normal and sweeping again turns the diagonal into
	# the along-the-wall component, which is the direction the stairs run in.
	#
	# Kept horizontal so a sloped contact cannot tilt the leg into a rise or a
	# dive: this leg advances the body over the lip, and the height it may gain
	# was already decided and clamped by the raise above.
	#
	# Both reference implementations iterate here for the same reason - Jolt's
	# WalkStairs moves the shape rather than sweeping once, and dresswithpockets'
	# write-up wraps its sweeps in an explicit slide loop.
	var forward_motion: Vector3 = remainder
	if forward_motion.length() < min_step_forward:
		forward_motion = testing_velocity.normalized() * min_step_forward

	# Whether this frame can cover the ground the probe is about to, which decides
	# who owns the horizontal at the commit below.
	#
	# Deliberately keyed off the whole frame's reach rather than off "was the leg
	# clamped": the leftover is short on any frame that ends up near a face, so
	# clamping is common at every tick rate, while move_and_slide falls short of
	# the probe only when the frame's entire travel is under the minimum. Keying
	# off the clamp instead was measured seating the body on ordinary 60 Hz walking
	# frames, where move_and_slide then adds its full share on top: a 0.05 m frame
	# advanced 0.12 m on the step, a visible burst on the one frame that should
	# look like every other.
	var probe_outruns_the_frame: bool = distance.length() < min_step_forward

	var forward_travel: Vector3 = Vector3.ZERO
	for _i: int in step_slide_iterations:
		_params.from = motion_transform
		_params.motion = forward_motion
		var blocked: bool = PhysicsServer3D.body_test_motion(get_rid(), _params, _result)
		var leg: Vector3 = _result.get_travel()
		motion_transform = motion_transform.translated(leg)
		forward_travel += leg
		if not blocked:
			break
		forward_motion = _result.get_remainder().slide(_result.get_collision_normal(0)) * _HORIZONTAL
		if forward_motion.length() < _params.margin:
			break

	var forward_distance: float = forward_travel.length()

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

	# What the body will actually be left at, which is the sweep result minus the
	# displacement move_and_slide is about to apply itself. On a static floor or a
	# horizontal platform the carry has no vertical part and this is the sweep result
	# unchanged; on a lift it is one frame of lift travel away from it, and it is this
	# number - not the raw sweep - that both the check below and the commit want.
	var committed_y: float = motion_transform.origin.y - platform_carry.y

	# A step that ends no higher than it started is not a step. The sweeps can
	# reach here having risen, travelled forward and come straight back down onto
	# the floor they left - a lip too shallow to land on, or a forward leg that
	# never cleared the face - and committing that writes the same Y back while
	# the seat below still plants the body forward into the obstacle, which then
	# blocks it there for good.
	#
	# Jolt makes the same check last, for the same reason: "If we don't gain any
	# height compared to our contact then the stair walk is pointless."
	#
	# Reached rather than theorised. The minimum forward leg is what exposed it:
	# before that, a frame with nothing left to travel turned back at the margin
	# bail on the forward sweep instead of arriving here with a flat result.
	if committed_y - global_position.y < _params.margin:
		return

	# Move player to match the step height we just found. Only the Y is committed
	# in the common case: move_and_slide runs right after and owns the horizontal,
	# carrying the raised body forward over the lip using velocity. Committing X/Z
	# here as well would double that frame's forward motion.
	#
	# Two cases have to seat the horizontal as well, and both are cases where
	# move_and_slide will not cover the ground the probe just did:
	#
	#   - The step was found on intent rather than velocity (carried_by_velocity
	#     false - a standstill against the face, see the probe above). There is no
	#     velocity for move_and_slide to carry with, so Y alone leaves the body
	#     floating at step height with its footprint still behind the lip;
	#     unsupported, it drops straight back next frame and the character is stuck
	#     pressing forward forever.
	#   - The frame's whole reach is shorter than _MIN_STEP_FORWARD, so the forward
	#     leg probed further ahead than move_and_slide will travel. Y alone then
	#     lands the body short of the lip and the snap-down puts it right back.
	#     Measured: at 60 Hz and 1 m/s this is the difference between climbing a
	#     0.2 m step and being pinned at its face for good.
	#
	# Neither doubles the frame's motion, because in both the horizontal the probe
	# used is the horizontal move_and_slide is about to not have.
	var pre_step_y: float = global_position.y
	global_position.y = committed_y
	if not carried_by_velocity or probe_outruns_the_frame:
		# Minus the platform carry, because move_and_slide is still going to apply
		# that displacement itself. The sweeps needed it to look in the right place;
		# committing it here as well would ride the platform twice, which is the same
		# double-push _move_split had to suppress. The Y above is netted off for the
		# same reason.
		global_position.x = motion_transform.origin.x - platform_carry.x
		global_position.z = motion_transform.origin.z - platform_carry.z
	_accumulate_step_smoothing(global_position.y - pre_step_y)

	stepped_up.emit()
	stepped.emit()
