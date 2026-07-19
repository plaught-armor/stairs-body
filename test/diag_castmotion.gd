extends Node3D

## Can the forward sweep be rebuilt out of cheaper primitives?
##
##     godot --headless --path <repo root> res://test/diag_castmotion.tscn
##
## body_test_motion costs 4.238 us when it hits nothing and 11.341 when it hits a
## wall; cast_motion costs 0.642 and 6.052, and cast_motion followed by
## get_rest_info costs 8.635 (test/bench_primitive.gd). The forward sweep is the
## one the walking character runs every frame and it usually misses, so that
## 0.642-against-4.238 is the largest lever on this path.
##
## Two things have to hold before the swap is even a candidate, and neither is
## about speed:
##
##   1. cast_motion sweeps ONE shape RID, body_test_motion sweeps every shape on
##      the body. test/diag_multishape.gd already shows those disagree by 0.18 m
##      on a two-shape body, so any swap has to be gated on a single-shape body.
##      This file only ever tests single-shape bodies - the gated case.
##   2. body_test_motion runs a depenetration pass first (godot_space_3d.cpp:652
##      STEP 1) and folds the recovery into get_travel(). cast_motion has no such
##      pass. A character resting on the ground is routinely a little penetrated,
##      so the two can disagree on travel even with one shape.
##
## And the normal: the walkable-surface bail reads get_collision_normal(0) off
## this sweep and throws away the whole step when it is shallow. get_rest_info
## has to report the same normal or the bail changes behaviour on ramps.
##
## So this drives a real character through four scenarios and compares, on every
## frame, the answer the shipping sweep gives against the answer the two
## primitives give at the same from/motion.
##
## The answer is no, twice over. Measured on 4.8.dev, 90 frames per lane, all
## bodies single-shape - the gated case, the one that had a chance:
##
##                      hit-mismatch  steep missed  travel worst  walkable verdict
##     flat ground                 0             0      0.0000 m          0
##     into a 0.2 step             0             0      0.0000 m         15
##     into a tall wall            0             0      0.0000 m          0
##     up a 20 deg ramp            5             5      0.0499 m          1
##
## 1. The normal does not survive. get_rest_info, run at the position the cast
##    stopped at, does not report the contact the sweep reported - worst case 90
##    degrees out at the step and 160 on the ramp. At the step it evidently picks
##    up the ground underfoot rather than the step face, and UP is walkable, so
##    the bail would throw away 15 of 90 legitimate steps. A character would stop
##    climbing steps it currently climbs.
##
## 2. It fails even as a cheap rejection test - cast first, fall through to the
##    real sweep only when it reports a hit. On the ramp the real sweep reports a
##    steep face on 5 frames where the cast reports nothing at all, and every one
##    of the 5 hit-mismatches is that kind. Those are depenetration-born
##    contacts: STEP 1 recovers the body out of the surface it is resting in and
##    counts that as a collision, and no pure cast can see it. A character
##    slightly penetrated into the step it is standing against is exactly the
##    case that would lose its step.
##
## So the 6.6x on the miss path is not buyable. body_test_motion's depenetration
## is not overhead wrapped around the cast, it is part of the answer the step
## check is reading.

const FRAMES: int = 90
const SETTLE: int = 20
const WALK: float = 3.0
const RADIUS: float = 0.3
const HEIGHT: float = 1.8
const MARGIN: float = 0.001

var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
var _query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
var _space: PhysicsDirectSpaceState3D


func _ready() -> void:
	call_deferred(&"_run")


func _box(size: Vector3, centre: Vector3, rotation_z: float = 0.0) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	add_child(body)
	body.global_position = centre
	body.rotation.z = rotation_z


func _character(at: Vector3) -> StairsCharacter:
	var c: StairsCharacter = StairsCharacter.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = HEIGHT
	cyl.margin = MARGIN
	shape_node.shape = cyl
	c.add_child(shape_node)
	c.collider = shape_node
	add_child(c)
	c.global_position = at
	return c


# The sweep stairs_character.gd runs first: from the body's transform, along the
# horizontal velocity for one physics tick.
func _compare(c: StairsCharacter, tally: Dictionary) -> void:
	var horizontal: Vector3 = c.velocity * Vector3(1, 0, 1)
	if horizontal == Vector3.ZERO:
		return
	var from: Transform3D = c.global_transform
	var motion: Vector3 = horizontal * c.get_physics_process_delta_time()

	_params.from = from
	_params.motion = motion
	var body_hit: bool = PhysicsServer3D.body_test_motion(c.get_rid(), _params, _result)
	var body_travel: float = _result.get_travel().length()
	var body_normal: Vector3 = _result.get_collision_normal(0) if body_hit else Vector3.ZERO

	_query.transform = from
	_query.motion = motion
	_query.exclude = [c.get_rid()]
	var fraction: PackedFloat32Array = _space.cast_motion(_query)
	var cast_hit: bool = fraction[0] < 1.0
	var cast_travel: float = motion.length() * fraction[0]
	var cast_normal: Vector3 = Vector3.ZERO
	if cast_hit:
		_query.transform = from.translated(motion * fraction[0])
		_query.motion = Vector3.ZERO
		var rest: Dictionary = _space.get_rest_info(_query)
		if not rest.is_empty():
			cast_normal = rest["normal"]
		_query.motion = motion

	tally["frames"] += 1
	if body_hit != cast_hit:
		tally["hit_mismatch"] += 1
		# The only mismatch that can cost a step: the real sweep found a face too
		# steep to walk on - a step or a wall - and the cheap test saw nothing, so
		# a rejection test built on it would return before the step check ran.
		if body_hit and body_normal.angle_to(Vector3.UP) > c.floor_max_angle:
			tally["missed_steep"] += 1
	if absf(body_travel - cast_travel) > MARGIN:
		tally["travel_mismatch"] += 1
		tally["travel_worst"] = maxf(tally["travel_worst"], absf(body_travel - cast_travel))
	if body_hit and cast_hit:
		if cast_normal == Vector3.ZERO:
			tally["no_rest_info"] += 1
		else:
			var degrees: float = rad_to_deg(body_normal.angle_to(cast_normal))
			tally["normal_worst"] = maxf(tally["normal_worst"], degrees)
			# The bail only cares which side of floor_max_angle the normal lands.
			var body_walkable: bool = body_normal.angle_to(Vector3.UP) <= c.floor_max_angle
			var cast_walkable: bool = cast_normal.angle_to(Vector3.UP) <= c.floor_max_angle
			if body_walkable != cast_walkable:
				tally["verdict_mismatch"] += 1


func _drive(tag: String, c: StairsCharacter, walk: Vector3) -> void:
	var tally: Dictionary = {
		"frames": 0,
		"hit_mismatch": 0,
		"missed_steep": 0,
		"travel_mismatch": 0,
		"travel_worst": 0.0,
		"normal_worst": 0.0,
		"verdict_mismatch": 0,
		"no_rest_info": 0,
	}
	for i: int in SETTLE + FRAMES:
		c.velocity = Vector3(walk.x, c.velocity.y - 0.16, walk.z)
		c.desired_velocity = walk
		if i >= SETTLE:
			_compare(c, tally)
		c.move_and_stair_step()
		await get_tree().physics_frame

	print(
		(
			"%-24s frames %3d  hit-mismatch %2d (steep missed %d)  travel-mismatch %2d (worst %.4f m)  "
			+ "normal worst %.2f deg  walkable-verdict mismatch %d  rest-info missing %d"
		)
		% [
			tag,
			tally["frames"],
			tally["hit_mismatch"],
			tally["missed_steep"],
			tally["travel_mismatch"],
			tally["travel_worst"],
			tally["normal_worst"],
			tally["verdict_mismatch"],
			tally["no_rest_info"],
		]
	)


func _run() -> void:
	_space = get_world_3d().direct_space_state
	_params.margin = MARGIN
	_query.margin = MARGIN

	# Four lanes, 8 m apart in z, so the scenarios cannot see each other.
	_box(Vector3(60.0, 1.0, 40.0), Vector3(0.0, -0.5, 0.0))

	# Lane 0: flat ground - the sweep misses every frame. The common case.
	var flat: StairsCharacter = _character(Vector3(-20.0, 0.9, -12.0))

	# Lane 1: a 0.2 step, walked into and climbed.
	_box(Vector3(10.0, 1.0, 6.0), Vector3(5.0, -0.3, -4.0))
	var step: StairsCharacter = _character(Vector3(-2.0, 0.9, -4.0))

	# Lane 2: a wall taller than any step - the sweep hits a vertical face.
	_box(Vector3(1.0, 6.0, 6.0), Vector3(2.0, 3.0, 4.0))
	var wall: StairsCharacter = _character(Vector3(-2.0, 0.9, 4.0))

	# Lane 3: a 20 degree ramp - the sweep hits a walkable face and the bail
	# fires. This is the one where the normal has to agree.
	_box(Vector3(20.0, 1.0, 6.0), Vector3(6.0, 1.2, 12.0), -deg_to_rad(20.0))
	var ramp: StairsCharacter = _character(Vector3(-2.0, 0.9, 12.0))

	# get_rid() is on Shape3D, so no cast: an `as CylinderShape3D` here would
	# return null the day _character builds a different shape kind, and the
	# failure would land on get_rid() rather than on the change that caused it.
	_query.shape_rid = flat.collider.shape.get_rid()

	await _drive("flat ground", flat, Vector3(WALK, 0, 0))
	await _drive("into a 0.2 step", step, Vector3(WALK, 0, 0))
	await _drive("into a tall wall", wall, Vector3(WALK, 0, 0))
	await _drive("up a 20 deg ramp", ramp, Vector3(WALK, 0, 0))
	get_tree().quit()
