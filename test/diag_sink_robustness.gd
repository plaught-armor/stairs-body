extends Node3D

## Is test case 29 knife-edge?
##
##     godot --headless --path <repo root> res://test/diag_sink_robustness.tscn
##
## Case 29 guards phase 2's clamp in stair_step_up: it fails when that sweep is
## replaced by an unconditional raise, because phase 4 then drops further than
## the body rose and can land on ground below the character's start. It was found
## by adversarial search, and one sibling finding from that same search was
## thrown out for being solver noise - a 12.6 mm gap that vanished under a 1 cm
## spawn nudge and reversed sign under another. So the same question has to be
## asked of this one before it is trusted as a permanent guard.
##
## Two things have to hold, and they are different questions:
##
##   1. On shipping code the character must NEVER sink, anywhere in the
##      neighbourhood of case 29's geometry. If shipping only just avoids sinking
##      at the exact numbers case 29 uses, the case passes by luck and will flake.
##   2. With phase 2 removed the sink must appear across that whole neighbourhood,
##      not only at one spawn position. A defect that needs millimetre-perfect
##      setup is a curiosity; one that survives perturbation is a real hazard.
##
## Run it once as shipped, then with phase 2's sweep removed, and compare the two
## summary lines.

var _spawn_offsets: PackedFloat32Array = [-0.05, -0.02, -0.01, 0.0, 0.01, 0.02, 0.05]
var _speeds: PackedFloat32Array = [20.0, 40.0, 60.0, 80.0]
var _lips: PackedFloat32Array = [0.01, 0.02, 0.04]
var _lower_grounds: PackedFloat32Array = [-0.05, -0.10, -0.20]

const RADIUS: float = 0.3
const HEIGHT: float = 1.8
const REST_Y: float = 0.9
const MARGIN: float = 0.001
const GRAVITY: float = 9.8
const DELTA: float = 1.0 / 60.0
const EPS: float = 0.05

# Members, not locals: a lambda captures locals by value (#69014).
var _lowest: float = INF
var _ups: int = 0
var _last_ups: int = 0


func _ready() -> void:
	call_deferred(&"_run")


func _box(world: Node3D, size: Vector3, centre: Vector3) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	world.add_child(body)
	body.global_position = centre


## Returns how far below its start height the step check drove the body, or 0.0.
func _trial(spawn_offset: float, speed: float, lip: float, lower: float) -> float:
	var world: Node3D = Node3D.new()
	add_child(world)

	_box(world, Vector3(15.6, 1.0, 8.0), Vector3(-5.2, -0.5, 0.0))
	_box(world, Vector3(0.1, lip, 8.0), Vector3(2.65, lip * 0.5, 0.0))
	_box(world, Vector3(20.0, 1.0, 8.0), Vector3(12.7, lower - 0.5, 0.0))
	_box(world, Vector3(30.0, 1.0, 8.0), Vector3(2.0, REST_Y + HEIGHT * 0.5 + 0.05 + 0.5, 0.0))

	var c: StairsCharacter = StairsCharacter.new()
	c.step_height = 0.3
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = HEIGHT
	cyl.margin = MARGIN
	shape_node.shape = cyl
	c.add_child(shape_node)
	c.collider = shape_node
	world.add_child(c)
	c.global_position = Vector3(2.0 + spawn_offset, REST_Y, 0.0)

	for _i: int in 2:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()

	var start_y: float = c.global_position.y
	_lowest = INF
	_ups = 0
	c \
			.stepped_up \
			.connect(
		func() -> void:
			_lowest = minf(_lowest, c.global_position.y)
			_ups += 1
	)

	for _i: int in 40:
		await get_tree().physics_frame
		c.velocity.x = speed
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(speed, 0.0, 0.0)
		c.move_and_stair_step()

	world.queue_free()
	_last_ups = _ups
	if _lowest == INF:
		return 0.0
	return maxf(0.0, start_y - _lowest)


func _run() -> void:
	var trials: int = 0
	var sank: int = 0
	# A trial that never stepped cannot sink either, so counting only sinks would
	# report a clamp as working when nothing exercised it. "0 sank" means the
	# clamp held only across the trials that actually took a step.
	var stepped: int = 0
	var worst: float = 0.0
	var worst_setup: String = "none"

	for spawn_offset: float in _spawn_offsets:
		for speed: float in _speeds:
			for lip: float in _lips:
				for lower: float in _lower_grounds:
					var depth: float = await _trial(spawn_offset, speed, lip, lower)
					trials += 1
					if _last_ups > 0:
						stepped += 1
					if depth > EPS:
						sank += 1
						if depth > worst:
							worst = depth
							worst_setup = (
								"spawn%+.2f speed%.0f lip%.2f lower%.2f"
								% [spawn_offset, speed, lip, lower]
							)

	print(
		(
			"%d trials, %d stepped up, %d sank (%.0f%%), worst %.4f m at [%s]"
			% [trials, stepped, sank, 100.0 * sank / trials, worst, worst_setup]
		)
	)
	get_tree().quit()
