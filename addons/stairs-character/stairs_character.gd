extends CharacterBody3D
class_name StairsCharacter

@export_category("Stair Stepping")
## The max height the character can step up or down
@export var _step_height: float = 0.33

## The character's collision shape. Margin should be as low as you can get it
## without snagging on edges. A CylinderShape3D is strongly recommended: a
## capsule's rounded bottom catches the top corner of a step and reports a
## steep contact normal, which the floor_max_angle check then rejects.
@export var collider: CollisionShape3D

# Private variables

# Holds the margin from the player's collider, resolved once on first use.
var _collider_margin: float = 0.0
var _margin_resolved: bool = false

# We don't want to take the player's vertical speed into account, usually
const _HORIZONTAL: Vector3 = Vector3(1, 0, 1)

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

# Similarly, you can modify this and it will reset after the frame.
# If set, will be used in place of _stepHeight.
var temp_step_height: float = 0

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
	_resolve_margin()

	was_grounded = grounded
	grounded = is_on_floor()

	stair_step_up()
	move_and_slide()
	stair_step_down()

	# Cleared at the end, not the start: the controller sets these just before
	# calling us, so clearing on entry would wipe the intent it just expressed.
	desired_velocity = Vector3.ZERO
	force_stair_step = false


# Resolved on first use rather than in _ready: this class is meant to be
# subclassed, and a subclass defining its own _ready replaces the parent's, which
# left the margin at 0.0 and ran every motion test with the wrong value.
# One-shot, fails loud, then trusted.
func _resolve_margin() -> void:
	if _margin_resolved:
		return
	_margin_resolved = true

	if collider == null:
		# Upstream hardcoded this node name. Kept as a fallback so existing
		# scenes keep working without reassigning the export.
		collider = get_node_or_null(^"Collider") as CollisionShape3D

	if collider == null:
		push_error(
			"[StairsCharacter] 'collider' is unassigned and no child CollisionShape3D named "
			+ "'Collider' was found - using default margin"
		)
		_collider_margin = 0.01
		return

	if collider.shape == null:
		push_error(
			"[StairsCharacter] collider '%s' has no shape assigned - using default margin"
			% collider.name
		)
		_collider_margin = 0.01
		return

	_collider_margin = collider.shape.margin
	if _collider_margin > 0.01:
		push_warning(
			"[StairsCharacter] collider margin %.3f > 0.01, may snag on stair steps"
			% _collider_margin
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
	_resolve_margin()

	# Don't step down if we weren't on the ground last physics frame
	if was_grounded == false || velocity.y >= 0:
		return

	var result = PhysicsTestMotionResult3D.new()
	var parameters = PhysicsTestMotionParameters3D.new()

	parameters.from = global_transform
	parameters.motion = Vector3.DOWN * _step_height
	parameters.margin = _collider_margin

	# Nothing to step down on
	if PhysicsServer3D.body_test_motion(get_rid(), parameters, result) == false:
		return

	global_transform = global_transform.translated(result.get_travel())
	apply_floor_snap()


func stair_step_up() -> void:
	_resolve_margin()

	if (grounded == false && force_stair_step == false):
		return

	var horizontal_velocity = velocity * _HORIZONTAL
	var testing_velocity = horizontal_velocity if horizontal_velocity != Vector3.ZERO else desired_velocity

	# Not moving or attempting to move, skip stair check
	if testing_velocity == Vector3.ZERO:
		return

	var result = PhysicsTestMotionResult3D.new()
	var parameters = PhysicsTestMotionParameters3D.new()
	parameters.margin = _collider_margin

	# This variable gets reused for all the following checks
	var motion_transform = global_transform

	# If you use this function you don't need to pass delta everywhere :D
	var distance = testing_velocity * get_physics_process_delta_time()
	parameters.from = motion_transform
	parameters.motion = distance

	# No stair step to do, we didn't hit any walls
	if PhysicsServer3D.body_test_motion(get_rid(), parameters, result) == false:
		return

	# Move to collision
	var remainder = result.get_remainder()
	motion_transform = motion_transform.translated(result.get_travel())

	# Raise up to ceiling - can't walk on steps if there's a low ceiling
	var step_up = _step_height * Vector3.UP
	parameters.from = motion_transform
	parameters.motion = step_up
	PhysicsServer3D.body_test_motion(get_rid(), parameters, result)
	# GetTravel will be full length if we didn't hit anything
	motion_transform = motion_transform.translated(result.get_travel())
	var step_up_distance = result.get_travel().length()

	# Move forward remaining distance
	parameters.from = motion_transform
	parameters.motion = remainder
	PhysicsServer3D.body_test_motion(get_rid(), parameters, result)
	motion_transform = motion_transform.translated(result.get_travel())

	# And set the collider back down again
	parameters.from = motion_transform
	# But no further than how far we stepped up
	parameters.motion = Vector3.DOWN * step_up_distance

	# Don't bother with the rest if we're not actually gonna land back down on something
	if PhysicsServer3D.body_test_motion(get_rid(), parameters, result) == false:
		return

	motion_transform = motion_transform.translated(result.get_travel())

	var surfaceNormal = result.get_collision_normal(0)
	if (surfaceNormal.angle_to(Vector3.UP) > floor_max_angle):
		return #Can't stand on the thing we're trying to step on anyway

	# Move player to match the step height we just found
	global_position.y = motion_transform.origin.y
