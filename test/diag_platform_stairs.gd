extends Node3D

## Do the step checks work on stairs that are themselves moving?
##
##     godot --headless --path <repo root> res://test/diag_platform_stairs.tscn
##
## Every sweep in stair_step_up is a world-space body_test_motion aimed along
## `velocity * delta`, and velocity is the character's own - the platform's motion
## reaches the body through move_and_slide's platform push, not through anything
## the step check can see. So the check probes the world as it stands *now* and
## the platform has moved by the time the frame resolves. Whether that matters is
## not something to argue about from the source.
##
## diag_platform.gd covers a flat platform. This is the case nothing covered: a
## staircase bolted to the platform, ridden and climbed at once. Three shapes:
##
##   - a staircase sliding horizontally, with and against the walk
##   - a staircase riding a lift, going up and going down
##   - a step at the edge of a moving platform, climbed from static ground
##
## The control in each family is the same geometry at zero speed, so a failure
## reads as "moving broke it" rather than "the world was wrong".
##
## Heights are reported RELATIVE to the platform, because the absolute number
## moves with the platform and says nothing about whether the character climbed.
##
## RESULT: mostly it works, and there is a speed past which it stops.
##
##     sliding staircase   0.0  climbed   2.0  climbed   5.0  STUCK   -2.0  climbed
##     staircase on a lift 0.0  climbed  +1.0  climbed  -1.0  STUCK
##     boarding a platform 0.0  climbed  -2.0  climbed  -5.0  climbed
##
## Both failures are the same shape, and it is the shape this repo already knows:
## the character parks against the first step face - relative x pins at 0.691 and
## 0.699, a hair under the 0.700 contact point - stays grounded every frame, and
## never rises. Instrumented, every frame of the stall bails at `sweep1-miss`: the
## first sweep, aimed along a healthy 0.05 m probe from 9 mm away, reports no
## collision at all.
##
## What is established:
##
##   - It is not the probe input. velocity is (3, 0, 0) and intent matches, so
##     carried_by_velocity is true and testing_velocity is the full walk - the
##     backpressure guard is not misfiring.
##   - Probe LENGTH is what clears the sliding case. Holding the platform at
##     5 m/s and raising the walk: 3 m/s stuck, 5 m/s stuck, 8 m/s climbs part of
##     the flight. So the sweep needs to span something bigger than the gap it can
##     see, and the platform's own displacement is the something.
##   - It is NOT the order the platform is moved in. Moving the platform before
##     the physics frame rather than after changes nothing, so this is not the
##     obvious one-frame staleness in the harness.
##   - The lift case does not clear at any walk speed tried, so it is not the same
##     mechanism as the slide, or not only that.
##
## What is NOT established: why the sweep misses. A sweep from 9 mm away along
## 50 mm should hit whatever the platform is doing, and it does not. Until that is
## understood there is no fix here worth writing - the candidates (folding platform
## velocity into the probe, sweeping in platform space) are guesses, and this repo
## does not ship guesses. The limitation is real, reproducible and bounded:
## stairs on a platform moving under about 2 m/s are fine, and a lift carrying
## stairs downward is not.

var _slides: PackedFloat32Array = [0.0, 2.0, 5.0, -2.0]
var _lifts: PackedFloat32Array = [0.0, 1.0, -1.0]
## Only non-positive for boarding: a platform pulling away from the ground opens
## a gap the character falls into, which is correct physics and a useless test.
var _boardings: PackedFloat32Array = [0.0, -2.0, -5.0]

const STEPS: int = 4
const STEP_RISE: float = 0.2
const STEP_RUN: float = 0.8

const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001
const GRAVITY: float = 9.8
const DELTA: float = 1.0 / 60.0
const WALK: float = 3.0
const SETTLE_FRAMES: int = 20
const WALK_FRAMES: int = 75

## Climbing all four treads gains this much on the platform.
const FULL_CLIMB: float = STEP_RISE * float(STEPS)


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	print("--- stairs that move under the character ---")
	print("a full climb gains %.2f m on the platform" % FULL_CLIMB)

	print("sliding staircase (+ is with the walk):")
	for speed: float in _slides:
		var result: PackedFloat32Array = await _ride_stairs(Vector3(speed, 0.0, 0.0))
		_report("  slide %+5.1f m/s" % speed, result, FULL_CLIMB)

	print("staircase on a lift (+ is upward):")
	for speed: float in _lifts:
		var result: PackedFloat32Array = await _ride_stairs(Vector3(0.0, speed, 0.0))
		_report("  lift  %+5.1f m/s" % speed, result, FULL_CLIMB)

	print("stepping onto a moving platform from static ground (one step, %.2f m):" % STEP_RISE)
	for speed: float in _boardings:
		var result: PackedFloat32Array = await _board(speed)
		_report("  platform %+5.1f m/s" % speed, result, STEP_RISE)

	get_tree().quit(0)


## `expected` differs per family - a flight of four treads is 0.80 m, boarding a
## platform is one 0.20 m step - so the verdict is measured against what that
## scenario could gain rather than against one number for all of them.
func _report(label: String, result: PackedFloat32Array, expected: float) -> void:
	var gained: float = result[0]
	var verdict: String = "climbed"
	if gained < expected - 0.05:
		verdict = "SHORT" if gained > 0.05 else "STUCK"
	print(
		(
			"%s  gained %5.2f m on the platform  grounded %.2f  %s"
			% [label, gained, result[1], verdict]
		)
	)


## Builds the staircase as children of one moving body, so the whole flight moves
## together the way a lift or a ship deck would. Returns [gained, grounded].
func _ride_stairs(platform_velocity: Vector3) -> PackedFloat32Array:
	var world: Node3D = Node3D.new()
	add_child(world)

	var platform: AnimatableBody3D = AnimatableBody3D.new()
	_shape(platform, Vector3(30.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	for i: int in STEPS:
		var top: float = STEP_RISE * float(i + 1)
		# Each tread runs to the end of the flight, so the stack forms a staircase
		# rather than a row of separate blocks.
		var length: float = STEP_RUN * float(STEPS - i) + 6.0
		var centre_x: float = 1.0 + STEP_RUN * float(i) + length * 0.5
		_shape(platform, Vector3(length, 2.0, 8.0), Vector3(centre_x, top - 1.0, 0.0))
	world.add_child(platform)
	platform.global_position = Vector3.ZERO

	var c: StairsCharacter = _character(world, Vector3(0.0, REST_Y, 0.0))

	for _i: int in SETTLE_FRAMES:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()

	var start_gap: float = c.global_position.y - platform.global_position.y
	var grounded_frames: int = 0
	for _i: int in WALK_FRAMES:
		await get_tree().physics_frame
		platform.global_position += platform_velocity * DELTA
		c.velocity.x = WALK
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(WALK, 0.0, 0.0)
		c.move_and_stair_step()
		if c.is_on_floor():
			grounded_frames += 1

	var gained: float = (c.global_position.y - platform.global_position.y) - start_gap
	var out: PackedFloat32Array = [gained, float(grounded_frames) / float(WALK_FRAMES)]
	world.queue_free()
	await get_tree().process_frame
	return out


## A single step at the leading edge of a moving platform, climbed from ground
## that is not moving. Returns [gained, grounded].
func _board(speed: float) -> PackedFloat32Array:
	var world: Node3D = Node3D.new()
	add_child(world)

	# Static ground the character starts on, ending at x = 1.0.
	var ground: StaticBody3D = StaticBody3D.new()
	_shape(ground, Vector3(22.0, 1.0, 8.0), Vector3(-10.0, -0.5, 0.0))
	world.add_child(ground)
	ground.global_position = Vector3.ZERO

	# The platform, its deck one step up, starting flush with the ground's end.
	var platform: AnimatableBody3D = AnimatableBody3D.new()
	_shape(platform, Vector3(30.0, 2.0, 8.0), Vector3(16.0, STEP_RISE - 1.0, 0.0))
	world.add_child(platform)
	platform.global_position = Vector3.ZERO

	var c: StairsCharacter = _character(world, Vector3(0.0, REST_Y, 0.0))

	for _i: int in SETTLE_FRAMES:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()

	var start_gap: float = c.global_position.y - platform.global_position.y
	var grounded_frames: int = 0
	for _i: int in WALK_FRAMES:
		await get_tree().physics_frame
		platform.global_position.x += speed * DELTA
		c.velocity.x = WALK
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(WALK, 0.0, 0.0)
		c.move_and_stair_step()
		if c.is_on_floor():
			grounded_frames += 1

	var gained: float = (c.global_position.y - platform.global_position.y) - start_gap
	var out: PackedFloat32Array = [gained, float(grounded_frames) / float(WALK_FRAMES)]
	world.queue_free()
	await get_tree().process_frame
	return out


func _shape(body: PhysicsBody3D, size: Vector3, centre: Vector3) -> void:
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	shape_node.position = centre
	body.add_child(shape_node)


func _character(world: Node3D, at: Vector3) -> StairsCharacter:
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
	c.global_position = at
	return c
