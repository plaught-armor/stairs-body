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
# because unlike a fresh instance this one does not start from defaults.
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()

# We don't want to take the player's vertical speed into account, usually
const _HORIZONTAL: Vector3 = Vector3(1, 0, 1)

# Fallback for a character with no usable collider, and the threshold past which
# a margin is worth warning about.
const _DEFAULT_MARGIN: float = 0.01

# Public variables

# Use was_grounded instead of is_on_floor() - because of the stair step mechanism, sometimes this
# script will snap the player to the floor, but is_on_floor() will still read as false.
# Both are refreshed by move_and_stair_step, so read them *after* that call - before it
# they still hold last frame's values.
var grounded: bool
var was_grounded: bool

# Force a stair step check this frame
# I use this for things like wall jumps, where it feels like you should've
# been able to land on a ledge but snagged just below it.
# Cleared by move_and_stair_step, so it only applies to the frame you set it in.
var force_stair_step: bool = false

# DesiredVelocity should be set in your character controller just so we know where we _want_ to go.
# Set it before you call move_and_stair_step, which consumes it and then clears it.
# Should match the direction where your input wants to take you.
var desired_velocity: Vector3 = Vector3.ZERO


# Replace your move_and_slide with this function.
# The grounded bookkeeping lives here rather than in _physics_process on purpose:
# this class is meant to be subclassed, and a subclass that defines its own
# _physics_process replaces the parent's, which left grounded stuck at false and
# silently disabled every step up. This function is the one thing every user
# provably calls.
func move_and_stair_step():
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


func stair_step_down() -> void:
	# Don't step down if we weren't on the ground last physics frame
	if was_grounded == false || velocity.y >= 0:
		return

	_params.from = global_transform
	_params.motion = Vector3.DOWN * step_height
	# Nothing to step down on
	if PhysicsServer3D.body_test_motion(get_rid(), _params, _result) == false:
		return

	global_transform = global_transform.translated(_result.get_travel())
	apply_floor_snap()

	stepped_down.emit()
	stepped.emit()


func stair_step_up() -> void:
	if (grounded == false && force_stair_step == false):
		return

	var horizontal_velocity = velocity * _HORIZONTAL
	var testing_velocity = horizontal_velocity if horizontal_velocity != Vector3.ZERO else desired_velocity

	# Not moving or attempting to move, skip stair check
	if testing_velocity == Vector3.ZERO:
		return

	# This variable gets reused for all the following checks
	var motion_transform = global_transform

	# If you use this function you don't need to pass delta everywhere :D
	var distance = testing_velocity * get_physics_process_delta_time()
	_params.from = motion_transform
	_params.motion = distance

	# No stair step to do, we didn't hit any walls
	if PhysicsServer3D.body_test_motion(get_rid(), _params, _result) == false:
		return

	# Move to collision
	var remainder = _result.get_remainder()
	motion_transform = motion_transform.translated(_result.get_travel())

	# Raise up to ceiling - can't walk on steps if there's a low ceiling
	var step_up = step_height * Vector3.UP
	_params.from = motion_transform
	_params.motion = step_up
	PhysicsServer3D.body_test_motion(get_rid(), _params, _result)
	# GetTravel will be full length if we didn't hit anything
	motion_transform = motion_transform.translated(_result.get_travel())
	var step_up_distance = _result.get_travel().length()

	# Move forward remaining distance
	_params.from = motion_transform
	_params.motion = remainder
	PhysicsServer3D.body_test_motion(get_rid(), _params, _result)
	motion_transform = motion_transform.translated(_result.get_travel())

	# And set the collider back down again
	_params.from = motion_transform
	# But no further than how far we stepped up
	_params.motion = Vector3.DOWN * step_up_distance

	# Don't bother with the rest if we're not actually gonna land back down on something
	if PhysicsServer3D.body_test_motion(get_rid(), _params, _result) == false:
		return

	motion_transform = motion_transform.translated(_result.get_travel())

	var surface_normal = _result.get_collision_normal(0)
	if (surface_normal.angle_to(Vector3.UP) > floor_max_angle):
		return #Can't stand on the thing we're trying to step on anyway

	# Move player to match the step height we just found
	global_position.y = motion_transform.origin.y

	stepped_up.emit()
	stepped.emit()
