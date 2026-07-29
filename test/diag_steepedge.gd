extends Node3D

## Does the steep-edge retry ever change an outcome?
##
##     godot --headless --path <repo root> res://test/diag_steepedge.tscn
##
## Jolt runs a second, longer forward probe when a landing comes back too steep,
## on the reasoning that "delta time may be very small, so it may be that we hit
## the edge of a step and the normal is too horizontal" - a real step rejected for
## the shape of its own lip. step_forward_test is that retry.
##
## The reason to doubt it is worth carrying here: the condition Jolt names is a
## very short forward leg, and min_step_forward already puts a floor under exactly
## that. So the retry may be answering a question this class no longer asks.
##
## This drives the real class over the wedge grid from diag_steep_landing.gd - the
## geometry that was measured actually reaching the landing check - and runs each
## shape with the retry off and on. A row prints only when the two disagree.
##
## The floor is swept too, because the retry is meant to matter most where the
## legs are shortest: with the floor removed, the short-leg regime Jolt describes
## is reachable again, and if the retry ever rescues anything it should be there.
##
## RESULT: 7 of 432 shapes disagreed, and every one of them had the floor set to
## zero. At the shipped floor of 0.02 - all 216 shapes of it, both tick rates -
## the retry changed nothing at all. So it answers exactly the question
## min_step_forward already answers, and only in the configuration the docs on
## that export tell you not to ship.
##
## The retry was written, measured against this, and taken out again. Two things
## it would have to survive before coming back: a shape that disagrees at a real
## floor value, and an explanation of the seven rows themselves, where the retry
## did not merely rescue a step but left the body 0.3-0.5 m higher on a 50 degree
## wedge - climbing something floor_max_angle is meant to refuse. This file stays
## as the record of why the export is not there.
##
## To re-run it the export has to come back; the numbers above are what it did
## when it existed. `step_forward_test` was: a second, longer forward probe from
## the raised position, taken only when the landing normal came back steeper than
## floor_max_angle, accepted only if it travelled further than the ordinary leg
## and landed on something walkable within the same rise.

var _tilts: PackedFloat32Array = [50.0, 60.0, 70.0, 80.0]
var _lips: PackedFloat32Array = [0.1, 0.2, 0.3]
var _gaps: PackedFloat32Array = [0.0, 0.2, 0.4]
var _speeds: PackedFloat32Array = [3.0, 6.0, 12.0]
var _floors: PackedFloat32Array = [0.0, 0.02]
var _rates: PackedInt32Array = [60, 240]

const RETRY: float = 0.15

const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001
const GRAVITY: float = 9.8
const SETTLE_SECONDS: float = 0.25
const WALK_SECONDS: float = 0.6

## Two runs of one shape are "the same outcome" while their resting heights agree
## to this. Well under a lip, well over solver noise.
const SAME: float = 0.02


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	print("--- does step_forward_test change any outcome? ---")

	# Checked once, not once per walk: the grid runs 216 retry-on rows and an error
	# inside the loop would print all 216 of them.
	var probe: StairsCharacter = StairsCharacter.new()
	var has_export: bool = &"step_forward_test" in probe
	probe.free()
	if not has_export:
		print("step_forward_test is not on the class - see the RESULT note in this file")
		get_tree().quit(0)
		return

	var original_rate: int = Engine.physics_ticks_per_second
	var shapes: int = 0
	var differences: int = 0

	for rate: int in _rates:
		Engine.physics_ticks_per_second = rate
		for floor_value: float in _floors:
			for tilt: float in _tilts:
				for lip: float in _lips:
					for gap: float in _gaps:
						for speed: float in _speeds:
							var off: float = await _walk(
								rate,
								floor_value,
								0.0,
								tilt,
								lip,
								gap,
								speed,
							)
							var on: float = await _walk(
								rate,
								floor_value,
								RETRY,
								tilt,
								lip,
								gap,
								speed,
							)
							shapes += 1
							if absf(on - off) <= SAME:
								continue
							differences += 1
							print(
								(
									"%d Hz floor%.2f tilt%.0f lip%.2f gap%.2f speed%.0f: off y=%.3f on y=%.3f"
									% [rate, floor_value, tilt, lip, gap, speed, off, on]
								)
							)

	Engine.physics_ticks_per_second = original_rate
	print("--- %d shapes, %d disagreed ---" % [shapes, differences])
	get_tree().quit(0)


## Walks one character into one wedge shape and returns the height it ends at.
func _walk(
	rate: int,
	floor_value: float,
	retry: float,
	tilt: float,
	lip: float,
	gap: float,
	speed: float,
) -> float:
	var delta: float = 1.0 / float(rate)
	var world: Node3D = Node3D.new()
	add_child(world)
	_box(world, Vector3(22.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	# A low lip the raised body can clear, at x = 1.0.
	_box(world, Vector3(0.2, lip, 8.0), Vector3(1.1, lip * 0.5, 0.0))
	# A short steep wedge just beyond it - short so it does not act as a wall.
	_box(world, Vector3(0.5, 0.4, 8.0), Vector3(1.3 + gap, lip, 0.0), -tilt)

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
	c.min_step_forward = floor_value

	for _i: int in int(SETTLE_SECONDS * float(rate)):
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * delta
		c.move_and_stair_step()

	for _i: int in int(WALK_SECONDS * float(rate)):
		await get_tree().physics_frame
		c.velocity.x = speed
		c.velocity.y -= GRAVITY * delta
		c.desired_velocity = Vector3(speed, 0.0, 0.0)
		c.move_and_stair_step()

	var where: float = c.global_position.y
	world.queue_free()
	await get_tree().physics_frame
	return where


func _box(world: Node3D, size: Vector3, centre: Vector3, tilt_deg: float = 0.0) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	world.add_child(body)
	body.global_position = centre
	body.rotation.z = deg_to_rad(tilt_deg)
