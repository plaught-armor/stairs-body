extends Node3D

## What does the is_on_wall pre-filter cost in frames?
##
##     godot --headless --path <repo root> res://test/diag_latency.tscn
##
## The pre-filter skips the step check on any frame where last frame's
## move_and_slide met nothing steep (test/diag_slide.gd), which saves 3.4 us per
## character per frame on flat ground - about 11% - and nothing at all against a
## wall (test/bench_frame.gd).
##
## The cost it can have is latency, and test case 28 deliberately tolerates a
## fraction of a frame: it asks only that the character never fully stalls. On
## the frame a walker first touches a step, the shipping code raises it and keeps
## going, while the pre-filter lets it stop against the face and raises it on the
## next frame. That is under case 28's threshold, so the suite passes either way,
## and it is exactly the difference this file measures instead of tolerating.
##
## A staircase multiplies it: if each step costs a frame, a flight of eight costs
## eight. Run this with and without the pre-filter and compare.
##
## Measured on 4.8.dev, deterministic - identical on every repeat run:
##
##                    first step    flight of 8    step-ups
##     pre-filter       14 frames      90 frames          8
##     baseline         14 frames      83 frames          8
##
## The first step costs nothing: walking at a step, contact is established on the
## frame before the rise, so the filter is already open when the check wants to
## run. The staircase is where it bites - the character steps up directly into
## the next riser, having had no contact with it last frame, so every step after
## the first waits a frame. Seven steps, seven frames, 8% slower.
##
## That is why the pre-filter was not taken. It buys 3.4 us per character per
## frame on flat ground (test/bench_frame.gd, 31.5 -> 28.1), which is 0.02% of a
## frame for one character and only reaches 4% at two hundred of them, and it
## pays for that by making stairs measurably slower to climb. Wrong direction for
## this library. Test case 28 guards the whole family of deferred-check ideas,
## but it tolerates a partial frame, so it passes with the pre-filter in place -
## this file is what actually caught the cost.

const STEPS: int = 8
const RISE: float = 0.2
const TREAD: float = 0.6
const WALK: float = 3.0
const RADIUS: float = 0.3
const HEIGHT: float = 1.8
const REST_Y: float = 0.9
const MARGIN: float = 0.001
const GRAVITY: float = 9.8
const DELTA: float = 1.0 / 60.0
const MAX_FRAMES: int = 600

var _steps_taken: int = 0


func _ready() -> void:
	call_deferred(&"_run")


func _box(size: Vector3, centre: Vector3) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	add_child(body)
	body.global_position = centre


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


## Frames until the character's feet clear `target_y`, or MAX_FRAMES.
func _climb(c: StairsCharacter, target_y: float) -> int:
	for i: int in MAX_FRAMES:
		await get_tree().physics_frame
		c.velocity.x = WALK
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(WALK, 0.0, 0.0)
		c.move_and_stair_step()
		if c.global_position.y >= REST_Y + target_y - 0.01:
			return i
	return MAX_FRAMES


func _run() -> void:
	# One character, one lane. An earlier version ran a single-step lane and a
	# staircase lane side by side and the second character ended up standing on
	# the first - placed 8 m apart, both reported the same position two frames
	# into the settle loop. The staircase answers both questions on its own: the
	# first step is the single-step latency, the total is the cumulative cost.
	_box(Vector3(22.0, 1.0, 6.0), Vector3(0.0, -0.5, 0.0))
	for s: int in STEPS:
		var top: float = RISE * (s + 1)
		_box(
			Vector3(TREAD * (STEPS - s), 2.0, 6.0),
			Vector3(1.0 + TREAD * s + TREAD * (STEPS - s) * 0.5, top - 1.0, 0.0),
		)
	var flight: StairsCharacter = _character(Vector3(0.0, REST_Y, 0.0))
	flight.stepped_up.connect(func() -> void:
				_steps_taken += 1)

	for _i: int in 20:
		await get_tree().physics_frame
		flight.velocity = Vector3(0.0, flight.velocity.y - GRAVITY * DELTA, 0.0)
		flight.move_and_stair_step()

	var first_frames: int = await _climb(flight, RISE)
	var first_steps: int = _steps_taken
	var all_frames: int = await _climb(flight, RISE * STEPS)

	print(
		"first step (%.2f) cleared in   %3d frames (%d step-ups)"
		% [RISE, first_frames, first_steps]
	)
	print(
		(
			"flight of %d (%.2f) cleared in  %3d further frames (%d step-ups total)"
			% [STEPS, RISE * STEPS, all_frames, _steps_taken]
		)
	)
	get_tree().quit()
