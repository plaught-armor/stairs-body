extends Node3D

## Does split_move ride a moving platform twice?
##
##     godot --headless --path <repo root> res://test/diag_platform.tscn
##
## move_and_slide applies the floor's platform velocity itself, before it touches
## the character's own velocity - `character_body_3d.cpp` moves the body by
## `current_platform_velocity * delta` at the top of every call. So a frame that
## calls it twice applies the platform push twice, and a character standing still
## on a platform travels at double its speed.
##
## The character holds no input velocity at all here, so every metre it covers
## came from the platform. Riding correctly means keeping the offset it started
## with; riding twice means drifting forward off the front.

const PLATFORM_SPEED: float = 5.0
const FRAMES: int = 90
const SETTLE_FRAMES: int = 20
const GRAVITY: float = 9.8
const DELTA: float = 1.0 / 60.0

const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const PLATFORM_TOP: float = 0.0
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001

var _platform: AnimatableBody3D
var _rider: StairsCharacter


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	print("--- riding a %.1f m/s platform ---" % PLATFORM_SPEED)
	var single: float = await _ride(false)
	var split: float = await _ride(true)
	print("platform travels %.3f m over the run" % (PLATFORM_SPEED * float(FRAMES) * DELTA))
	print("single move: rider drifted %+.3f m relative to the platform" % single)
	print("split move:  rider drifted %+.3f m relative to the platform" % split)
	get_tree().quit(0)


## Stands a character on a platform for the run and returns how far it slid
## relative to that platform. Zero means it rode correctly.
func _ride(split: bool) -> float:
	var world: Node3D = Node3D.new()
	add_child(world)

	_platform = AnimatableBody3D.new()
	var platform_shape: CollisionShape3D = CollisionShape3D.new()
	var platform_box: BoxShape3D = BoxShape3D.new()
	platform_box.size = Vector3(40.0, 1.0, 8.0)
	platform_shape.shape = platform_box
	_platform.add_child(platform_shape)
	world.add_child(_platform)
	_platform.global_position = Vector3(0.0, PLATFORM_TOP - 0.5, 0.0)

	_rider = StairsCharacter.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = BODY_RADIUS
	cyl.height = BODY_HEIGHT
	cyl.margin = COLLIDER_MARGIN
	shape_node.shape = cyl
	_rider.add_child(shape_node)
	_rider.collider = shape_node
	world.add_child(_rider)
	_rider.global_position = Vector3(0.0, REST_Y, 0.0)
	_rider.split_move = split

	for _i: int in SETTLE_FRAMES:
		await get_tree().physics_frame
		_rider.velocity.y -= GRAVITY * DELTA
		_rider.move_and_stair_step()

	var offset_at_start: float = _rider.global_position.x - _platform.global_position.x
	for _i: int in FRAMES:
		await get_tree().physics_frame
		# The platform moves first, the way an AnimationPlayer or a tween would
		# drive it, so the rider sees a floor that has already advanced.
		_platform.global_position.x += PLATFORM_SPEED * DELTA
		# No input at all - everything the rider covers came from the floor.
		_rider.velocity.y -= GRAVITY * DELTA
		_rider.move_and_stair_step()

	var drift: float = (_rider.global_position.x - _platform.global_position.x) - offset_at_start
	world.queue_free()
	await get_tree().process_frame
	return drift
