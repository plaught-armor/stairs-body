extends Node3D

## Does case 25's geometry actually discriminate? The case asserts a second
## collision shape blocks the step, and it passes under both the shipping code
## and a variant that swaps the raise sweep to cast_motion - which sweeps one
## shape and would not see the second one. Either the variant is safe here or
## the case is passing for an unrelated reason, and those need telling apart.
##
##     godot --headless --path <repo root> res://test/diag_multishape.tscn
##
## So: put the body where the raise sweep starts and ask both primitives the
## same question directly.

const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const REST_Y: float = 0.9
const MARGIN: float = 0.001
const STEP_HEIGHT: float = 0.33

var _body: CharacterBody3D
var _cyl: CylinderShape3D


func _ready() -> void:
	call_deferred(&"_run")


func _box(size: Vector3, centre: Vector3) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var b: BoxShape3D = BoxShape3D.new()
	b.size = size
	shape_node.shape = b
	body.add_child(shape_node)
	add_child(body)
	body.global_position = centre


func _run() -> void:
	# Case 25's world: ground, a 0.2 step, and a ceiling underside at y = 2.45.
	_box(Vector3(11.0, 1.0, 8.0), Vector3(-4.5, -0.5, 0.0))
	_box(Vector3(4.0, 2.0, 8.0), Vector3(3.0, -0.8, 0.0))
	_box(Vector3(4.0, 1.0, 8.0), Vector3(2.0, 2.95, 0.0))

	# Case 25's character: cylinder plus a box on top of the head.
	_body = CharacterBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	_cyl = CylinderShape3D.new()
	_cyl.radius = BODY_RADIUS
	_cyl.height = BODY_HEIGHT
	_cyl.margin = MARGIN
	shape_node.shape = _cyl
	_body.add_child(shape_node)

	var extra: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(0.4, 0.5, 0.4)
	extra.shape = box
	_body.add_child(extra)
	extra.position = Vector3(0.0, BODY_HEIGHT * 0.5 + 0.25, 0.0)

	add_child(_body)
	_body.global_position = Vector3(0.7, REST_Y, 0.0)
	for _i: int in 10:
		await get_tree().physics_frame

	# The raise sweep starts from the body at the foot of the step and tries to
	# rise by step_height. That is the sweep the variant swaps.
	var from: Transform3D = _body.global_transform
	var motion: Vector3 = Vector3.UP * STEP_HEIGHT

	var params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
	var result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
	params.margin = MARGIN
	params.from = from
	params.motion = motion
	var body_hit: bool = PhysicsServer3D.body_test_motion(_body.get_rid(), params, result)
	var body_travel: float = result.get_travel().length()

	var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	query.shape_rid = _cyl.get_rid()
	query.margin = MARGIN
	query.collision_mask = _body.collision_mask
	query.exclude = [_body.get_rid()]
	query.transform = from
	query.motion = motion
	var fraction: PackedFloat32Array = get_world_3d().direct_space_state.cast_motion(query)
	var cast_travel: float = STEP_HEIGHT * fraction[0]

	print("body at y=%.3f, raising by %.3f" % [from.origin.y, STEP_HEIGHT])
	print("  body_test_motion (all shapes): hit=%s travel=%.4f" % [body_hit, body_travel])
	print("  cast_motion (collider only):   hit=%s travel=%.4f" % [fraction[0] < 1.0, cast_travel])
	if absf(body_travel - cast_travel) > 0.01:
		print("  DISCRIMINATES: the two primitives disagree by %.4f" % absf(body_travel - cast_travel))
	else:
		print("  does NOT discriminate: both report the same clearance")
	get_tree().quit()
