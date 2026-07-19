extends Node3D

## Can stair_step_up's final sweep ever land on a surface too steep to stand on?
##
##     godot --headless --path <repo root> res://test/diag_steep_landing.tscn
##
## The last thing stair_step_up does before committing is check the normal of
## whatever it dropped onto, and refuse a face steeper than floor_max_angle. A
## mutation audit deleted that check and the whole suite still passed, including
## case 04, which walks into a 70 degree ramp for exactly this reason. Case 04
## passes because the drop lands back on flat ground rather than on the ramp, so
## the check never runs on a steep normal at all.
##
## Before writing a test that pins the check, the check has to be reachable. This
## replicates the four sweeps by hand over a grid of wedge geometries and reports
## the angle of the surface each drop lands on. If nothing here clears
## floor_max_angle, the check is unreachable in ordinary geometry and the honest
## answer is to say so rather than to invent a test for it.
##
## RESULT: 188 of 192 shapes reach the check, and only 4 land on a face steeper
## than floor_max_angle. A test was written on the steepest of them and then
## thrown away: moving the lip 5 mm left, the wedge 5 mm right, or the tilt by 2
## degrees flips it from pass to fail, and the face it actually lands on is the
## LIP's side, not the wedge's - the wedge only matters because it stops the
## forward sweep clearing the region. A guard that fragile fails on geometry
## drift rather than on regressions, which is worse than no guard at all.
##
## So the landing check stays as defensive code with no test, and this file is the
## evidence for why. The structural reason it is nearly unreachable: to land on a
## steep face the body must first get forward past something, and anything steep
## enough to matter is usually tall enough to stop the forward sweep first - which
## is what the 4 remaining bail-at-phase-3 rows are.

# First pass used a 3 m tilted slab with no lip and every one of its 80
# configurations bailed at phase 3: a slab that long is a wall, blocking the
# forward sweep at every height, so the drop never ran. The body has to clear
# something LOW first and then come down on the steep face beyond it, and it
# needs a big enough remainder to travel - hence the lip and the speeds.
var _tilts: PackedFloat32Array = [50.0, 60.0, 70.0, 80.0]
var _lips: PackedFloat32Array = [0.1, 0.2, 0.3]
var _gaps: PackedFloat32Array = [0.0, 0.2, 0.4, 0.7]
var _speeds: PackedFloat32Array = [6.0, 12.0, 20.0, 30.0]

const RADIUS: float = 0.3
const HEIGHT: float = 1.8
const REST_Y: float = 0.9
const MARGIN: float = 0.001
const STEP_HEIGHT: float = 0.33
const WALK: float = 3.0
const DELTA: float = 1.0 / 60.0

var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()


func _ready() -> void:
	call_deferred(&"_run")


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


## Runs the four sweeps the way stair_step_up does and reports what the final
## one landed on: -1 if the check is never reached, else the angle in degrees.
func _probe(tilt: float, lip: float, gap: float, speed: float) -> float:
	var world: Node3D = Node3D.new()
	add_child(world)
	_box(world, Vector3(22.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	# A low lip the raised body can clear, at x = 1.0.
	_box(world, Vector3(0.2, lip, 8.0), Vector3(1.1, lip * 0.5, 0.0))
	# A short steep wedge just beyond it - short so it does not act as a wall.
	_box(world, Vector3(0.5, 0.4, 8.0), Vector3(1.3 + gap, lip, 0.0), -tilt)

	var c: CharacterBody3D = CharacterBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = HEIGHT
	cyl.margin = MARGIN
	shape_node.shape = cyl
	c.add_child(shape_node)
	world.add_child(c)
	c.global_position = Vector3(0.0, REST_Y, 0.0)

	# Walk in until something is in front, then run the four sweeps from there.
	for _i: int in 60:
		await get_tree().physics_frame
		c.velocity = Vector3(speed, -0.16, 0.0)
		c.move_and_slide()

	var rid: RID = c.get_rid()
	_params.margin = MARGIN
	var motion_transform: Transform3D = c.global_transform
	var distance: Vector3 = Vector3(speed, 0.0, 0.0) * DELTA

	# Phase 1.
	_params.from = motion_transform
	_params.motion = distance
	if not PhysicsServer3D.body_test_motion(rid, _params, _result):
		world.queue_free()
		return -1.0
	if _result.get_collision_normal(0).angle_to(Vector3.UP) <= deg_to_rad(45.0):
		world.queue_free()
		return -2.0 # walkable, bails before the rise
	var remainder: Vector3 = _result.get_remainder()
	motion_transform = motion_transform.translated(_result.get_travel())

	# Phase 2.
	_params.from = motion_transform
	_params.motion = STEP_HEIGHT * Vector3.UP
	PhysicsServer3D.body_test_motion(rid, _params, _result)
	var up_travel: Vector3 = _result.get_travel()
	motion_transform = motion_transform.translated(up_travel)
	var up_distance: float = up_travel.length()
	if up_distance < MARGIN:
		world.queue_free()
		return -3.0 # ceiling bail

	# Phase 3.
	_params.from = motion_transform
	_params.motion = remainder
	PhysicsServer3D.body_test_motion(rid, _params, _result)
	if _result.get_travel().length() < MARGIN:
		world.queue_free()
		return -4.0 # forward bail
	motion_transform = motion_transform.translated(_result.get_travel())

	# Phase 4 — the one whose normal the check reads.
	_params.from = motion_transform
	_params.motion = Vector3.DOWN * up_distance
	if not PhysicsServer3D.body_test_motion(rid, _params, _result):
		world.queue_free()
		return -5.0 # nothing to land on
	var degrees: float = rad_to_deg(_result.get_collision_normal(0).angle_to(Vector3.UP))
	world.queue_free()
	return degrees


func _run() -> void:
	var reached: int = 0
	var steep: int = 0
	var best: float = -1.0
	var best_setup: String = "none"
	var outcomes: Dictionary = { }

	for tilt: float in _tilts:
		for lip: float in _lips:
			for gap: float in _gaps:
				for speed: float in _speeds:
					var degrees: float = await _probe(tilt, lip, gap, speed)
					if degrees < 0.0:
						var key: String = "bail%.0f" % degrees
						outcomes[key] = outcomes.get(key, 0) + 1
						continue
					reached += 1
					if degrees > 45.0:
						steep += 1
						if degrees > best:
							best = degrees
							best_setup = (
								"tilt%.0f lip%.2f gap%.2f speed%.0f" % [tilt, lip, gap, speed]
							)

	print("reached the landing check: %d" % reached)
	print("landed on something STEEPER than 45 deg: %d" % steep)
	print("steepest: %.1f deg at [%s]" % [best, best_setup])
	print(
		"bail reasons (-1 no hit, -2 walkable, -3 ceiling, -4 forward, -5 nothing below): %s"
		% outcomes
	)
	get_tree().quit()
