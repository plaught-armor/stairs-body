extends Node3D

## Does the step check survive a high physics tick rate?
##
##     godot --headless --path <repo root> res://test/diag_tickrate.tscn
##
## Every distance in stair_step_up is derived from `testing_velocity * delta`, so
## the whole check shrinks with the tick rate: at 240 Hz a 3 m/s walk probes
## 12.5 mm, and the forward sweep after the rise gets whatever is left of that.
## Both the walkable bail and the forward bail compare against the collider
## margin, so there is a rate at which the probe stops clearing them.
##
## Jolt's WalkStairs clamps this explicitly - mWalkStairsMinStepForward, default
## 0.02 m - with the comment that "at very high frame rates the delta time may be
## very small, causing a very small step forward". This asks whether the same
## floor is missing here, and where it starts to bite.
##
## The grid is tick rate x walk speed, and the answer per cell is simply whether
## the character got on top of a single 0.2 m step.

# Never const on a Packed*Array (C1) - it reports the byte count as its size.
var _rates: PackedInt32Array = [60, 120, 144, 240, 480]
var _speeds: PackedFloat32Array = [0.5, 1.0, 3.0, 6.0]

const STEP_TOP: float = 0.2
const SECONDS: float = 2.0
const SETTLE_SECONDS: float = 0.25
const GRAVITY: float = 9.8

const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001

## Body centre once it stands on the step, minus a tolerance for the solver
## leaving it a fraction above the surface.
const CLIMBED_Y: float = REST_Y + STEP_TOP - 0.05


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	print("--- tick rate x walk speed, climbing a %.2f m step ---" % STEP_TOP)
	var original_rate: int = Engine.physics_ticks_per_second

	var header: String = "  Hz  "
	for speed: float in _speeds:
		header += "%9.1f m/s" % speed
	print(header)

	for rate: int in _rates:
		Engine.physics_ticks_per_second = rate
		var row: String = "%4d  " % rate
		for speed: float in _speeds:
			var reached: float = await _walk(rate, speed)
			var verdict: String = "climbed" if reached >= CLIMBED_Y else "STUCK"
			row += "%9s  " % ("%s %.2f" % [verdict, reached])
		print(row)

	Engine.physics_ticks_per_second = original_rate
	get_tree().quit(0)


## Walks one character into the step and returns the highest y it reached.
func _walk(rate: int, speed: float) -> float:
	var delta: float = 1.0 / float(rate)
	var world: Node3D = Node3D.new()
	add_child(world)
	_add_box(world, Vector3(20.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	_add_box(world, Vector3(8.0, 2.0, 8.0), Vector3(5.0, STEP_TOP - 1.0, 0.0))

	var c: StairsCharacter = StairsCharacter.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var body_shape: CylinderShape3D = CylinderShape3D.new()
	body_shape.radius = BODY_RADIUS
	body_shape.height = BODY_HEIGHT
	body_shape.margin = COLLIDER_MARGIN
	shape_node.shape = body_shape
	c.add_child(shape_node)
	c.collider = shape_node
	world.add_child(c)
	# Close enough that even the slowest speed reaches the face inside the run.
	c.global_position = Vector3(0.4, REST_Y, 0.0)

	var settle: int = int(SETTLE_SECONDS * float(rate))
	for _i: int in settle:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * delta
		c.move_and_stair_step()

	var peak: float = -INF
	var frames: int = int(SECONDS * float(rate))
	for _i: int in frames:
		await get_tree().physics_frame
		c.velocity.x = speed
		c.velocity.y -= GRAVITY * delta
		c.desired_velocity = Vector3(speed, 0.0, 0.0)
		c.move_and_stair_step()
		peak = maxf(peak, c.global_position.y)

	world.queue_free()
	await get_tree().physics_frame
	return peak


func _add_box(world: Node3D, size: Vector3, centre: Vector3) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	world.add_child(body)
	body.global_position = centre
