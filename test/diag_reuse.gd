extends Node3D

## Is there anything to reuse between frames?
##
##     godot --headless --path <repo root> res://test/diag_reuse.tscn
##
## Every sweep input the step check builds is a pure function of the same four
## things: global_transform, velocity, the physics tick length, and step_height.
## Nothing else feeds `from` or `motion` - read stair_step_up top to bottom and
## the only other inputs are the results of earlier sweeps in the same frame. So
## if that tuple is unchanged from the previous frame, every sweep this frame
## poses a question identical to one already answered, and a memo could skip all
## of them.
##
## That is the whole case for a wall cache, and it is worth testing before
## writing one, because the interesting number is not "does the character stop"
## but "does it stop to the bit". A wall-pressed character is still having
## gravity applied and still being depenetrated, and either can leave the
## transform jittering in the low bits, at which case a memo keyed on exact
## equality never hits and one keyed on an epsilon is a correctness argument
## rather than a lookup.
##
## So: drive each scenario and count, per frame, whether the tuple is bitwise
## identical to the previous frame, and separately whether it is within an
## epsilon. The gap between those two columns is the answer.

const FRAMES: int = 120
const SETTLE: int = 30
const WALK: float = 3.0
const RADIUS: float = 0.3
const HEIGHT: float = 1.8
const MARGIN: float = 0.001
const EPSILON: float = 0.0001

# A member, not a local: a lambda captures locals by value (#69014), so a
# `did_step` local written from the signal handler would never be seen here.
var _did_step: bool = false


func _ready() -> void:
	call_deferred(&"_run")


func _box(size: Vector3, centre: Vector3, rotation_z: float = 0.0) -> StaticBody3D:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	add_child(body)
	body.global_position = centre
	body.rotation.z = rotation_z
	return body


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


func _drive(tag: String, c: StairsCharacter, walk: Vector3) -> void:
	var exact: int = 0
	var near: int = 0
	var frames: int = 0
	var worst_position: float = 0.0
	var worst_velocity: float = 0.0
	var last_transform: Transform3D = Transform3D()
	var last_velocity: Vector3 = Vector3.ZERO
	var first: bool = true

	for i: int in SETTLE + FRAMES:
		c.velocity = Vector3(walk.x, c.velocity.y - 0.16, walk.z)
		c.desired_velocity = walk
		c.move_and_stair_step()
		await get_tree().physics_frame

		if i < SETTLE:
			continue

		# Sampled after the call, which is where a memo would have to compare:
		# the next frame's sweeps start from this state.
		if not first:
			frames += 1
			var position_delta: float = (c.global_transform.origin - last_transform.origin).length()
			var velocity_delta: float = (c.velocity - last_velocity).length()
			worst_position = maxf(worst_position, position_delta)
			worst_velocity = maxf(worst_velocity, velocity_delta)
			if c.global_transform == last_transform and c.velocity == last_velocity:
				exact += 1
			if position_delta < EPSILON and velocity_delta < EPSILON:
				near += 1
		first = false
		last_transform = c.global_transform
		last_velocity = c.velocity

	print(
		(
			"%-24s frames %3d  bitwise-identical %3d (%4.0f%%)  within-epsilon %3d (%4.0f%%)  "
			+ "worst move %.6f m  worst velocity delta %.6f"
		)
		% [
			tag,
			frames,
			exact,
			100.0 * exact / frames,
			near,
			100.0 * near / frames,
			worst_position,
			worst_velocity,
		]
	)


# The failure the cache has to survive: the character holds still, so a memo
# keyed on its state stays valid, while the world moves under it. Here a wall
# lowers into a climbable step while the character is pressed against it.
#
# The trap is that the staleness is self-reinforcing. The cached answer is "no
# step", which stops the character moving, which keeps its state identical,
# which keeps the cache valid - so the character does not recover on the next
# frame, or ever. Any frame that reports both a cache hit and a real step is a
# frame the cache would have deadlocked on.
func _drive_moving_world(tag: String, c: StairsCharacter, wall: StaticBody3D) -> void:
	var stepped: PackedInt32Array = []
	var cache_would_hit: PackedInt32Array = []
	var last_transform: Transform3D = Transform3D()
	var last_velocity: Vector3 = Vector3.ZERO
	c.stepped_up.connect(func() -> void:
				_did_step = true)

	for i: int in SETTLE + FRAMES:
		# Two thirds of the way through, the wall drops to a 0.2 step.
		# The box is 6 m tall, so a top face at 0.2 puts its centre at -2.8.
		if i == SETTLE + 40:
			wall.global_position = Vector3(2.0, -2.8, -20.0)

		var hit: bool = c.global_transform == last_transform and c.velocity == last_velocity
		last_transform = c.global_transform
		last_velocity = c.velocity

		_did_step = false
		c.velocity = Vector3(WALK, c.velocity.y - 0.16, 0.0)
		c.desired_velocity = Vector3(WALK, 0, 0)
		c.move_and_stair_step()
		await get_tree().physics_frame

		if i < SETTLE:
			continue
		if hit:
			cache_would_hit.append(i)
		if _did_step:
			stepped.append(i)

	var deadlocked: int = 0
	for frame: int in stepped:
		if frame in cache_would_hit:
			deadlocked += 1

	print(
		"%-24s stepped on %d frames, cache would have hit on %d - %d of the steps lost"
		% [tag, stepped.size(), cache_would_hit.size(), deadlocked]
	)
	if stepped.is_empty():
		print("    (no step happened at all - scenario did not exercise the case)")
	else:
		print("    first real step at frame %d" % stepped[0])


func _run() -> void:
	_box(Vector3(60.0, 1.0, 40.0), Vector3(0.0, -0.5, 0.0))

	# The case the cache would exist for: walked into a wall and held there.
	_box(Vector3(1.0, 6.0, 6.0), Vector3(2.0, 3.0, -12.0))
	var wall: StairsCharacter = _character(Vector3(0.0, 0.9, -12.0))

	# A step too tall to climb - same "no step" answer every frame, but the
	# character is against a 0.5 face rather than a 6 m one.
	_box(Vector3(4.0, 1.0, 6.0), Vector3(4.0, 0.0, -4.0))
	var tall_step: StairsCharacter = _character(Vector3(0.0, 0.9, -4.0))

	# Standing still on flat ground - both step functions bail on entry, so this
	# is the floor for how still a character ever gets.
	var idle: StairsCharacter = _character(Vector3(0.0, 0.9, 4.0))

	# Walking flat, for contrast: genuinely different every frame.
	var flat: StairsCharacter = _character(Vector3(-20.0, 0.9, 12.0))

	await _drive("pressed into a wall", wall, Vector3(WALK, 0, 0))
	await _drive("pressed into a tall step", tall_step, Vector3(WALK, 0, 0))
	await _drive("standing still", idle, Vector3.ZERO)
	# The lane where the world moves: a 6 m wall that drops to a 0.2 step while
	# the character is pressed against it.
	var lowering: StaticBody3D = _box(Vector3(1.0, 6.0, 6.0), Vector3(2.0, 3.0, -20.0))
	var against_lowering: StairsCharacter = _character(Vector3(0.0, 0.9, -20.0))

	await _drive("walking, flat ground", flat, Vector3(WALK, 0, 0))
	await _drive_moving_world("wall lowers to a step", against_lowering, lowering)
	get_tree().quit()
