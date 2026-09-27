@icon("res://addons/stairs-character/stairs_character.svg")
extends AnimatableBody3D
class_name StairsBody

## Kinematic character body with stair stepping built into its own move, rather
## than wrapped around CharacterBody3D.move_and_slide. Aims at the same behaviour
## as StairsCharacter with fewer physics queries per frame.
##
## Replaces move_and_slide entirely, so none of CharacterBody3D's API exists here.
## The getters below keep its names where no native method is in the way.
##
## Queries per frame, the budget this class is built around:
##   walking on flat ground   2   (the move sweep, the contact test)
##   pressed into a wall      2   (the same two; the step attempt is cached)
##   intent off the motion   +1   (a sweep along intent, which only looks for a step)
##   climbing a step          5   (move sweep, up, forward, down, contact test)
##   leaving a floor         +1   (the floor probe, only where contact is lost)
##   on a moving platform    +1   (the carry, as its own sweep)
##
## Assumes world up is Vector3.UP, like StairsCharacter.

## Emitted on any stair step, in either direction, after the direction-specific one.
signal stepped
## Emitted when the body has been raised onto a higher surface.
signal stepped_up
## Emitted when the floor probe has set the body down onto a lower surface.
signal stepped_down

## Max height the body can step up onto.
@export var step_height: float = 0.33
## How far the floor probe reaches down to stay on the ground or step down.
## Negative follows step_height.
@export var step_down_height: float = -1.0
## Smallest distance a step probe looks ahead, whatever the tick rate.
@export_range(0.0, 0.2, 0.001) var min_step_forward: float = _MIN_STEP_FORWARD
## Slide iterations for the forward leg of a step.
@export_range(1, 8) var step_slide_iterations: int = 4
## Steepest surface that counts as floor, in radians.
@export_range(0.0, 180.0, 0.1, "radians_as_degrees") var floor_max_angle: float = deg_to_rad(45.0)
## Slide iterations for the main move.
@export_range(1, 8) var max_slides: int = 4
## Collision margin used by every sweep.
@export_range(0.001, 0.1, 0.001) var safe_margin: float = 0.001

@export_category("Step Smoothing")
## The visual node whose local Y is eased after a step, so the camera or mesh does
## not pop when the body snaps up or down. Unassigned, smoothing is off.
##
## Must be a child of the body, never the body: the collider has to sit at the
## stepped height the moment the step resolves. Point it at a pivot between the
## body and the camera - body -> smooth_node -> camera. This class owns the node's
## local Y; camera bob or recoil belongs on a child of it. Same contract as
## StairsCharacter.smooth_node.
@export var smooth_node: Node3D
## Exponential decay rate of the eased offset: higher is snappier. The time
## constant is 1 / step_smoothing seconds, so 20 settles in about 150 ms. Zero
## keeps the visual rigid without unassigning smooth_node. Framerate independent.
@export_range(0.0, 60.0, 0.5) var step_smoothing: float = 20.0

## Velocity in m/s. Written back after each move: clipped against what the body
## hit, and with any downward part zeroed while on the floor.
var velocity: Vector3 = Vector3.ZERO
## Horizontal intent for this frame. Drives the step probe when velocity has been
## pinned near zero by the face it is pushing into. Cleared after each move.
var desired_velocity: Vector3 = Vector3.ZERO
## Allow a step this frame even when airborne. Cleared after each move.
var force_stair_step: bool = false

const _MIN_STEP_FORWARD: float = 0.02
const _HORIZONTAL: Vector3 = Vector3(1, 0, 1)
## Smallest drop the floor probe reports as a step down rather than as keeping
## contact with the floor it was already on.
const _STEP_DOWN_SIGNAL_MIN: float = 0.01
## Contacts the floor-contact check reads. A wall and a floor at once is the case
## that needs more than one; four covers a corner.
const _CONTACT_MAX: int = 4
## Depenetration past this many margins means the body is inside something rather
## than resting on it, and _settle pushes it back out. A resting contact recovers
## under one margin on both engines (measured 0.75 on Jolt, 0.81 on Godot Physics).
const _EMBED_MARGINS: float = 4.0
## Eased offset below which the visual is snapped home.
const _SMOOTH_EPSILON: float = 0.0001

var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
# The floor-contact check's own parameters, so its zero motion, reported recovery
# contacts and wider collision count never leak into the sweeps above.
var _contact_params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
# Shape casts that check a sweep reporting no collision, in the rare re-slide.
var _cast_params: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()

# Contact state from the last move.
var _on_floor: bool = false
var _on_wall: bool = false
var _on_ceiling: bool = false
var _floor_normal: Vector3 = Vector3.UP
var _wall_normal: Vector3 = Vector3.ZERO
var _floor_rid: RID = RID()
# The floor's object, which says whether it still exists: a freed body's RID stays
# non-zero, and the physics server reads it as static. Assumes every collider is
# a node; a body made straight on the server has id 0 and reads as freed.
var _floor_id: int = 0
var _platform_velocity: Vector3 = Vector3.ZERO

# The last step attempt that a wall refused, so pressing into the same wall from
# the same spot does not pay for the up and forward sweeps every frame. Only
# static colliders are cached: anything that moves can turn into a step.
var _refused_valid: bool = false
var _refused_at: Vector3 = Vector3.ZERO
var _refused_normal: Vector3 = Vector3.ZERO
var _refused_rid: RID = RID()
var _refused_height: float = 0.0

# Where a successful step left the body, and how far it rose. Written by _try_step;
# the rise is announced once the move is final, since a re-slide can redo the step.
var _step_to: Transform3D = Transform3D.IDENTITY
var _step_rise: float = 0.0

# The visual offset the decay chases back to zero, and smooth_node's authored local
# Y it decays toward, captured at NOTIFICATION_READY.
var _smooth_offset_y: float = 0.0
var _smooth_rest_y: float = 0.0


func _init() -> void:
	# Moves are teleports of a kinematic body, the way CharacterBody3D moves.
	sync_to_physics = false
	_contact_params.recovery_as_collision = true
	_contact_params.max_collisions = _CONTACT_MAX


# NOTIFICATION_READY and NOTIFICATION_PROCESS reach every script in the chain, so a
# subclass defining its own _ready or _process cannot shadow these the way it would
# shadow a method. Process delta is the render frame's: smoothing is visual.
func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		_init_step_smoothing()
	elif what == NOTIFICATION_PROCESS:
		_tick_step_smoothing(get_process_delta_time())


func is_on_floor() -> bool:
	return _on_floor


func is_on_wall() -> bool:
	return _on_wall


func is_on_ceiling() -> bool:
	return _on_ceiling


func get_floor_normal() -> Vector3:
	return _floor_normal


func get_wall_normal() -> Vector3:
	return _wall_normal


func get_platform_velocity() -> Vector3:
	return _platform_velocity


## Moves the body by velocity for one physics frame, stepping up and down stairs.
func move_and_stair_step() -> void:
	_params.margin = safe_margin
	var delta: float = get_physics_process_delta_time()
	var was_on_floor: bool = _on_floor
	if was_on_floor:
		_refresh_platform_velocity()
		_carry(_platform_velocity * delta)

	var start: Transform3D = global_transform
	var start_velocity: Vector3 = velocity
	var motion: Vector3 = _intended_motion(was_on_floor, delta)
	var may_step: bool = was_on_floor or force_stair_step
	_clear_contacts()
	_slide(motion, may_step, delta, false)
	if _settle():
		# A sweep went through something. Redo the move checking every sweep.
		global_transform = start
		velocity = start_velocity
		_clear_contacts()
		_slide(motion, may_step, delta, true)
		# Best effort: still embedded after this, the body is left where it is and
		# the next move's recovery works on it.
		_settle()
	if _step_rise > 0.0:
		_accumulate_step_smoothing(_step_rise)
		stepped_up.emit()
		stepped.emit()

	if was_on_floor and not _on_floor and velocity.y <= 0.0:
		_probe_floor()

	if was_on_floor and not _on_floor:
		velocity += _platform_velocity
		_platform_velocity = Vector3.ZERO
		_floor_rid = RID()
		_floor_id = 0
	if _on_floor and velocity.y < 0.0:
		velocity.y = 0.0

	desired_velocity = Vector3.ZERO
	force_stair_step = false


func _clear_contacts() -> void:
	_step_rise = 0.0
	_on_floor = false
	_on_wall = false
	_on_ceiling = false


func _step_down_reach() -> float:
	return step_height if step_down_height < 0.0 else step_down_height


# Grounded and not moving up, the move follows the floor at the horizontal speed
# and drops gravity: the floor probe keeps the body down, so sweeping gravity into
# the floor every frame buys nothing and doubles that sweep's cost.
func _intended_motion(was_on_floor: bool, delta: float) -> Vector3:
	if not was_on_floor or velocity.y > 0.0:
		return velocity * delta
	var horizontal: Vector3 = velocity * _HORIZONTAL
	if horizontal == Vector3.ZERO:
		return Vector3.ZERO
	var along: Vector3 = horizontal.slide(_floor_normal)
	return along.normalized() * horizontal.length() * delta


# Fresh platform velocity for a moving floor. A static floor's collider velocity is
# already exact - zero, or a conveyor's constant velocity - so it is left alone.
func _refresh_platform_velocity() -> void:
	if not _floor_rid.is_valid():
		return
	if not is_instance_id_valid(_floor_id):
		_platform_velocity = Vector3.ZERO
		_floor_rid = RID()
		_floor_id = 0
		return
	if PhysicsServer3D.body_get_mode(_floor_rid) == PhysicsServer3D.BODY_MODE_STATIC:
		return
	var state: PhysicsDirectBodyState3D = PhysicsServer3D.body_get_direct_state(_floor_rid)
	if state == null:
		_platform_velocity = Vector3.ZERO
		_floor_rid = RID()
		_floor_id = 0
		return
	_platform_velocity = state.get_velocity_at_local_position(
		global_position - state.transform.origin
	)


# The floor's displacement as its own sweep, with the floor excluded so the body
# is carried rather than blocked by what carries it. Only runs on a moving floor.
func _carry(motion: Vector3) -> void:
	if motion == Vector3.ZERO:
		return
	_params.from = global_transform
	_params.motion = motion
	_params.exclude_bodies = [_floor_rid]
	PhysicsServer3D.body_test_motion(get_rid(), _params, _result)
	_params.exclude_bodies = []
	global_transform = global_transform.translated(_result.get_travel())


# `verify` checks each sweep that reports no collision against a shape cast, and
# stops it where the cast does - see _settle for why a sweep can need that.
func _slide(motion: Vector3, may_step: bool, delta: float, verify: bool) -> void:
	var from: Transform3D = global_transform
	var probe: Vector3 = motion if verify else _step_probe(motion, may_step, delta)
	if probe != motion and probe.normalized().dot(motion.normalized()) < _PARALLEL:
		# Intent points away from this frame's motion, so the probe's sweep says
		# nothing about where the body can go. It only looks for a step.
		if _intent_step(from, probe, motion.length(), delta):
			global_transform = _step_to
			return
		probe = motion
	var previous_normal: Vector3 = Vector3.ZERO
	for i: int in max_slides:
		var sweep: Vector3 = probe if i == 0 else motion
		# A clipped remainder under a margin is not worth a sweep, but the frame's
		# own move is: a slow walk at a high tick rate moves less than a margin a
		# frame, and dropping it leaves the body standing still.
		if sweep == Vector3.ZERO or (i > 0 and sweep.length() < safe_margin):
			break
		_params.from = from
		_params.motion = sweep
		if not PhysicsServer3D.body_test_motion(get_rid(), _params, _result):
			var reach: float = _unblocked_fraction(from, sweep) if verify else 1.0
			if reach >= 1.0:
				from = from.translated(motion)
				break
			from = from.translated(sweep * reach)
			motion = sweep * (1.0 - reach)
			continue
		var travel: Vector3 = _result.get_travel()
		var remainder: Vector3 = _result.get_remainder()
		if i == 0 and sweep != motion:
			# The probe looked further along the same line than this frame moves. Its
			# hit only matters to the step below; the body travels no further than
			# motion.
			travel = _clip_length(travel, motion.length())
			remainder = motion - travel
		from = from.translated(travel)
		var normal: Vector3 = _result.get_collision_normal(0)
		var kind: int = _classify(normal)
		if kind == _WALL and may_step and _try_step(from, sweep - travel, normal, delta):
			from = _step_to
			break
		if kind == _WALL and may_step:
			# Grounded, a steep face is a vertical plane: the body slides along it
			# rather than up it.
			normal = (normal * _HORIZONTAL).normalized()
		motion = _clip(remainder, normal, previous_normal)
		if velocity.dot(normal) < 0.0:
			velocity = velocity.slide(normal)
		previous_normal = normal
	global_transform = from


## Cosine above which the step probe counts as along the motion rather than off it.
const _PARALLEL: float = 0.9999
const _FLOOR: int = 0
const _WALL: int = 1
const _CEILING: int = 2


# A step from wherever a probe along intent meets a steep face, at most `reach`
# along it. With no motion this frame, intent is the only direction there is, and
# a face it meets is the wall the body is being held against; otherwise the face
# may be off to the side, and only the slide's own sweep records a wall.
func _intent_step(from: Transform3D, probe: Vector3, reach: float, delta: float) -> bool:
	_params.from = from
	_params.motion = probe
	if not PhysicsServer3D.body_test_motion(get_rid(), _params, _result):
		return false
	var normal: Vector3 = _result.get_collision_normal(0)
	var angle: float = normal.angle_to(Vector3.UP)
	if angle <= floor_max_angle or angle >= PI - floor_max_angle:
		return false
	if is_zero_approx(reach):
		_on_wall = true
		_wall_normal = normal
	var travel: Vector3 = _clip_length(_result.get_travel(), reach)
	return _try_step(from.translated(travel), probe - travel, normal, delta)


# Records the contact and says what it is.
func _classify(normal: Vector3) -> int:
	var angle: float = normal.angle_to(Vector3.UP)
	if angle <= floor_max_angle:
		_record_floor(normal)
		return _FLOOR
	if angle >= PI - floor_max_angle:
		_on_ceiling = true
		return _CEILING
	_on_wall = true
	_wall_normal = normal
	return _WALL


# Floor state from contact `index` of the last sweep.
func _record_floor(normal: Vector3, index: int = 0) -> void:
	_on_floor = true
	_floor_normal = normal
	_floor_rid = _result.get_collider_rid(index)
	_floor_id = _result.get_collider_id(index)
	_platform_velocity = _result.get_collider_velocity(index)


# One zero-motion test after the move, for two jobs. Returns whether the body
# ended up inside something, leaving the contact state alone when it did.
#
# Floor contact. If the move did not already find floor, the contacts this test
# reports during depenetration say whether the body is resting on some. Much
# cheaper than the floor probe (1.7 us against 4.5 on Jolt, 5.5 against 8.4 on
# Godot Physics), which then only runs where contact is actually lost: edges,
# steps down, leaving a platform. Zero motion rather than the move sweep's own
# contacts, because Jolt's body_test_motion drops any contact that does not oppose
# the motion, and a floor under a horizontal move is exactly that
# (jolt_query_collectors.h, "Ignore hits that don't oppose the motion direction").
# With no motion there is no direction and nothing is filtered, on either engine.
#
# Tunnelling. That same Jolt filter lets body_test_motion report no collision and
# the FULL motion as travel when its cast actually stopped on a contact the filter
# then threw away. Measured: a cylinder moving down past a ledge edge ended 0.13 m
# inside the floor below. A resting contact recovers under one margin, so recovery
# past _EMBED_MARGINS of them means a sweep went through something. The recovery
# is not applied: that deep, depenetration picks whichever way out is shortest -
# 1.47 m down through the floor on Godot Physics, 0.5 m sideways on Jolt. The move
# is redone instead, with every sweep checked.
func _settle() -> bool:
	_contact_params.margin = safe_margin
	_contact_params.from = global_transform
	if not PhysicsServer3D.body_test_motion(get_rid(), _contact_params, _result):
		return false
	if _result.get_travel().length() > safe_margin * _EMBED_MARGINS:
		return true
	if _on_floor:
		return false
	var best: int = -1
	var best_angle: float = floor_max_angle
	for i: int in _result.get_collision_count():
		var angle: float = _result.get_collision_normal(i).angle_to(Vector3.UP)
		if angle <= best_angle:
			best = i
			best_angle = angle
	if best >= 0:
		_record_floor(_result.get_collision_normal(best), best)
	return false


# How much of `motion` from `from` the body's shapes can travel, by shape cast.
# cast_motion has no motion-direction filter, so it stops where the cast inside a
# no-collision body_test_motion stopped.
func _unblocked_fraction(from: Transform3D, motion: Vector3) -> float:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	_cast_params.motion = motion
	_cast_params.margin = safe_margin
	_cast_params.collision_mask = collision_mask
	_cast_params.exclude = [get_rid()]
	var fraction: float = 1.0
	for owner_id: int in get_shape_owners():
		if is_shape_owner_disabled(owner_id):
			continue
		var at: Transform3D = from * shape_owner_get_transform(owner_id)
		for i: int in shape_owner_get_shape_count(owner_id):
			_cast_params.shape = shape_owner_get_shape(owner_id, i)
			_cast_params.transform = at
			fraction = minf(fraction, space.cast_motion(_cast_params)[0])
	return fraction


# Remainder slid along the plane it hit, and along the crease when it also hit
# the previous plane - the Quake clip, so a corner settles in two sweeps.
func _clip(remainder: Vector3, normal: Vector3, previous_normal: Vector3) -> Vector3:
	var clipped: Vector3 = remainder.slide(normal)
	if previous_normal == Vector3.ZERO or clipped.dot(previous_normal) >= 0.0:
		return clipped
	var crease: Vector3 = previous_normal.cross(normal)
	if crease.length_squared() < 1e-8:
		return Vector3.ZERO
	crease = crease.normalized()
	return crease * crease.dot(clipped)


func _clip_length(v: Vector3, max_length: float) -> Vector3:
	var length: float = v.length()
	if length <= max_length or length == 0.0:
		return v
	return v * (max_length / length)


# The first sweep of the move doubles as the step probe, so it has to reach a
# step face even when this frame barely moves: pinned against the face by a
# standstill (intent is the stronger signal), or at a tick rate high enough that
# a frame's travel is shorter than the gap an engine leaves at a face.
func _step_probe(motion: Vector3, may_step: bool, delta: float) -> Vector3:
	if not may_step:
		return motion
	var horizontal: Vector3 = motion * _HORIZONTAL
	var intent: Vector3 = desired_velocity * _HORIZONTAL * delta
	var direction: Vector3 = horizontal
	if intent.length_squared() > horizontal.length_squared() and intent.dot(horizontal) >= 0.0:
		direction = intent
	if direction == Vector3.ZERO:
		return motion
	var reach: float = maxf(direction.length(), min_step_forward)
	if reach <= horizontal.length():
		return motion
	return motion - horizontal + direction.normalized() * reach


# Up, forward, down from where the move met a steep face. On success _step_to
# holds the landing and the floor state is set from the down sweep, so the floor
# probe does not run again this frame.
func _try_step(at: Transform3D, remainder: Vector3, wall_normal: Vector3, _delta: float) -> bool:
	var wall_rid: RID = _result.get_collider_rid(0)
	if _refused_here(at.origin, wall_normal, wall_rid):
		return false

	_params.from = at
	_params.motion = Vector3.UP * step_height
	PhysicsServer3D.body_test_motion(get_rid(), _params, _result)
	var rise: float = _result.get_travel().y
	if rise < safe_margin:
		return false
	var raised: Transform3D = at.translated(Vector3.UP * rise)

	var forward: Vector3 = remainder * _HORIZONTAL
	if forward.length() < min_step_forward:
		forward = (-wall_normal * _HORIZONTAL).normalized() * min_step_forward
	var ahead: Transform3D = _step_forward(raised, forward)
	if (ahead.origin - raised.origin).length() < safe_margin:
		# Only a leg that had room to move and was blocked says anything about the
		# wall. A leg shorter than the margin is this frame's leftover travel, and
		# the next frame's may well climb from the same spot.
		if forward.length() >= safe_margin:
			_remember_refusal(at.origin, wall_normal, wall_rid)
		return false

	_params.from = ahead
	_params.motion = Vector3.DOWN * rise
	if not PhysicsServer3D.body_test_motion(get_rid(), _params, _result):
		return false
	var landed: Transform3D = ahead.translated(_result.get_travel())
	var normal: Vector3 = _result.get_collision_normal(0)
	if normal.angle_to(Vector3.UP) > floor_max_angle:
		return false
	if landed.origin.y - at.origin.y < safe_margin:
		return false

	_record_floor(normal)
	_step_to = landed
	_step_rise = landed.origin.y - at.origin.y
	return true


func _step_forward(from: Transform3D, forward: Vector3) -> Transform3D:
	var motion: Vector3 = forward
	for _i: int in step_slide_iterations:
		_params.from = from
		_params.motion = motion
		var blocked: bool = PhysicsServer3D.body_test_motion(get_rid(), _params, _result)
		from = from.translated(_result.get_travel())
		if not blocked:
			break
		motion = _result.get_remainder().slide(_result.get_collision_normal(0)) * _HORIZONTAL
		if motion.length() < safe_margin:
			break
	return from


func _refused_here(origin: Vector3, normal: Vector3, rid: RID) -> bool:
	return (
		_refused_valid and rid == _refused_rid and step_height == _refused_height
		and origin.distance_to(_refused_at) < safe_margin * 2.0
		and normal.dot(_refused_normal) > 0.999
	)


func _remember_refusal(origin: Vector3, normal: Vector3, rid: RID) -> void:
	_refused_valid = (PhysicsServer3D.body_get_mode(rid) == PhysicsServer3D.BODY_MODE_STATIC)
	_refused_at = origin
	_refused_normal = normal
	_refused_rid = rid
	_refused_height = step_height


# One sweep down: keeps a walker on the floor, steps it down, and finds ledges.
func _probe_floor() -> void:
	_params.from = global_transform
	_params.motion = Vector3.DOWN * _step_down_reach()
	if not PhysicsServer3D.body_test_motion(get_rid(), _params, _result):
		if _unblocked_fraction(_params.from, _params.motion) < 1.0:
			# No collision, yet a shape cast is blocked: the rim is over an edge by
			# less than a margin, and Jolt dropped the edge's contact because it does
			# not oppose the probe (see _settle). The edge still holds the body up,
			# which is what Godot Physics reports there. Perch, as below, keeping last
			# frame's floor normal and collider - the body has not moved off them.
			_on_floor = true
		return
	var normal: Vector3 = _result.get_collision_normal(0)
	var travel: Vector3 = _result.get_travel()
	if normal.angle_to(Vector3.UP) > floor_max_angle:
		if not _flat_bottomed():
			# A rounded bottom meets a tread's corner before its face and reports the
			# corner's normal, so steepness says nothing here; take it as support.
			normal = Vector3.UP
		elif travel.length() < safe_margin * 2.0:
			# Already touching: the rim is resting on an edge, which still holds the
			# body up. Keep last frame's floor; the next probe clears the edge.
			_on_floor = true
			return
		else:
			return
	global_transform = global_transform.translated(travel)
	_record_floor(normal)
	if -travel.y >= _STEP_DOWN_SIGNAL_MIN:
		_accumulate_step_smoothing(travel.y)
		stepped_down.emit()
		stepped.emit()


# Whether every enabled shape on the body has a flat bottom, which is what lets a
# steep contact under it be read as steep ground rather than as a rounded bottom
# meeting a corner. Same test and reasons as StairsCharacter._flat_bottomed.
func _flat_bottomed() -> bool:
	var shapes: int = 0
	for owner_id: int in get_shape_owners():
		if is_shape_owner_disabled(owner_id):
			continue
		for i: int in shape_owner_get_shape_count(owner_id):
			var shape: Shape3D = shape_owner_get_shape(owner_id, i)
			if not (shape is CylinderShape3D or shape is BoxShape3D):
				return false
			shapes += 1
	return shapes > 0


# Processing is only ever turned on here, never off: a subclass with its own
# _process has idle processing enabled by the engine, and switching it off from
# this base would silently kill that _process.
func _init_step_smoothing() -> void:
	_smooth_offset_y = 0.0
	if smooth_node == null:
		return
	_smooth_rest_y = smooth_node.position.y
	set_process(true)


# The visual is pushed opposite the body's signed step height, so it holds its
# world height for a frame before the decay pulls it home. A move over twice the
# larger reach is a teleport or a shove rather than a step, and is not eased. The
# offset is clamped to one reach so a burst of steps cannot stack into a lurch.
func _accumulate_step_smoothing(step_delta_y: float) -> void:
	if smooth_node == null or step_smoothing <= 0.0:
		return
	var reach: float = maxf(step_height, _step_down_reach())
	if absf(step_delta_y) > reach * 2.0:
		return
	_smooth_offset_y = clampf(_smooth_offset_y - step_delta_y, -reach, reach)


# Render-frame decay of the offset: exp(-rate * dt) closes the same fraction of the
# distance per second at any frame rate. A rate of zero collapses it at once.
func _tick_step_smoothing(delta: float) -> void:
	if smooth_node == null:
		return
	if step_smoothing <= 0.0:
		_smooth_offset_y = 0.0
	else:
		_smooth_offset_y *= exp(-step_smoothing * delta)
		if absf(_smooth_offset_y) < _SMOOTH_EPSILON:
			_smooth_offset_y = 0.0
	smooth_node.position.y = _smooth_rest_y + _smooth_offset_y
