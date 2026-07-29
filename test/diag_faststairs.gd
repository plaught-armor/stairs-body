extends Node3D

## Does splitting the move into a horizontal pass and a vertical one buy anything?
##
##     godot --headless --path <repo root> res://test/diag_faststairs.tscn
##
## dresswithpockets' write-up moves horizontally, then vertically, as two separate
## move_and_slide calls, and names the failure it fixes: "mis-steps" where the
## player falls "too fast for Jolt to determine that the player is 'on' the next
## step". This class does one combined move, so if that failure is real here it
## should show up as frames where the body is not grounded while running stairs -
## and the step check needs grounded, so those frames are frames where it is off.
##
## Running DOWN a staircase at speed is where the claim bites: gravity accumulates
## between contacts, the combined move carries the body forward and down at once,
## and a frame that ends in mid-air disables the check that would have caught the
## next tread. Running UP is the control - contacts there are head-on, so the split
## should change nothing.
##
## Reported per run: how many frames were airborne, the fastest downward velocity
## reached, and where the body ended up. A split that helps shows fewer airborne
## frames and a smaller fall speed at the same end position; a split that only
## costs shows the same numbers for two move_and_slide calls instead of one.

var _speeds: PackedFloat32Array = [3.0, 8.0, 14.0]

const STEPS: int = 8
const STEP_RISE: float = 0.2
const STEP_RUN: float = 0.6

const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001
const GRAVITY: float = 9.8
const DELTA: float = 1.0 / 60.0
const SETTLE_FRAMES: int = 20
const WALK_FRAMES: int = 90


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	print("--- running stairs, one combined move vs a split one ---")
	for descending: bool in [true, false]:
		print("%s stairs:" % ("descending" if descending else "ascending"))
		for speed: float in _speeds:
			var single: PackedFloat32Array = await _run_stairs(speed, descending, false)
			var split: PackedFloat32Array = await _run_stairs(speed, descending, true)
			print(
				(
					"  %5.1f m/s  single: airborne %3d  fastest fall %6.2f  end y %6.3f x %6.2f"
					% [speed, int(single[0]), single[1], single[2], single[3]]
				)
			)
			print(
				(
					"             split:  airborne %3d  fastest fall %6.2f  end y %6.3f x %6.2f"
					% [int(split[0]), split[1], split[2], split[3]]
				)
			)
	get_tree().quit(0)


## Returns [airborne_frames, fastest_downward_velocity, end_y, end_x].
func _run_stairs(speed: float, descending: bool, split: bool) -> PackedFloat32Array:
	var world: Node3D = Node3D.new()
	add_child(world)

	# Treads laid out so the character meets them at x = 1.0 onward. Descending
	# counts the rises down from the top, ascending counts them up from the floor.
	# Landings at both ends, long enough that a 14 m/s run cannot leave the world
	# inside the walk. Without them the fast rows measure a character falling off
	# the end of the geometry, which looks exactly like a stepping failure and is
	# not one.
	var start_y: float = STEP_RISE * float(STEPS) if descending else 0.0
	var rise: float = -STEP_RISE if descending else STEP_RISE
	var end_y: float = start_y + rise * float(STEPS)
	var stairs_end: float = 1.0 + STEP_RUN * float(STEPS)

	_box(world, Vector3(24.0, 4.0, 8.0), Vector3(-11.0, start_y - 2.0, 0.0))
	_box(world, Vector3(40.0, 4.0, 8.0), Vector3(stairs_end + 20.0, end_y - 2.0, 0.0))
	for i: int in STEPS:
		var top: float = start_y + rise * float(i + 1)
		var run_x: float = 1.0 + STEP_RUN * float(i)
		_box(world, Vector3(STEP_RUN, 4.0, 8.0), Vector3(run_x + STEP_RUN * 0.5, top - 2.0, 0.0))

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
	c.global_position = Vector3(0.0, start_y + REST_Y, 0.0)
	c.split_move = split

	for _i: int in SETTLE_FRAMES:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()

	var airborne: int = 0
	var fastest_fall: float = 0.0
	for _i: int in WALK_FRAMES:
		await get_tree().physics_frame
		c.velocity.x = speed
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(speed, 0.0, 0.0)
		c.move_and_stair_step()
		if not c.is_on_floor():
			airborne += 1
		fastest_fall = minf(fastest_fall, c.velocity.y)

	var out: PackedFloat32Array = [
		float(airborne),
		fastest_fall,
		c.global_position.y,
		c.global_position.x,
	]
	world.queue_free()
	await get_tree().physics_frame
	return out


func _box(world: Node3D, size: Vector3, centre: Vector3) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	world.add_child(body)
	body.global_position = centre
