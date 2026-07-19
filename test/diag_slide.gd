extends Node3D

## Does move_and_slide already know what the forward sweep is about to ask?
##
##     godot --headless --path <repo root> res://test/diag_slide.tscn
##
## The forward sweep is the one a walking character runs every frame, and every
## attempt to buy it cheaper has failed on correctness (test/diag_castmotion.gd).
## But move_and_slide runs its own body_test_motion internally and keeps what it
## found: get_slide_collision_count() and get_slide_collision(i).get_normal().
## That is the same question - "is there something in front of me, and is its
## face too steep to walk up" - already answered, for free, one frame earlier.
##
## If it is usable, the forward sweep does not get cheaper, it disappears: the
## step check would key off last frame's slide collisions and run its remaining
## three sweeps only when one of them reports a steep face.
##
## The thing that would sink it: move_and_slide collides with the FLOOR every
## frame a character walks with gravity applied. If the floor is in that list,
## every frame reports a collision and the list cannot distinguish "walked into
## a step" from "standing on the ground" without inspecting normals - and if it
## reports only the floor when a step IS in front, the trigger misses real steps.
##
## So this drives the four scenarios and prints, per frame, how many slide
## collisions there were and what their normals were, against what the shipping
## forward sweep concluded on the same frame.
##
## Measured on 4.8.dev, 40 frames per lane, 160 of 160 in agreement:
##
##     walking, flat ground   sweep miss     slide count 3 [0, 0, 0 deg]
##     into a 0.2 step        sweep steep    slide count 1 [90 deg]
##     into a tall wall       sweep steep    slide count 2 [90, 0 deg]
##     up a 20 deg ramp       sweep miss     slide count 3 [0, 0, 0 deg]
##
## The floor is in the list, as feared, but it comes in at 0 deg, so a trigger
## that asks "was any slide collision steeper than floor_max_angle" separates the
## cases exactly. No frame in any lane disagreed with the sweep.
##
## What it can and cannot buy. It cannot REPLACE the forward sweep: that sweep
## also produces the travel and remainder the raise and forward-move sweeps are
## built from, and a KinematicCollision3D from last frame's move_and_slide
## describes a different motion from a different origin. It can PRE-FILTER it -
## skip the whole step check on a frame where last frame's move_and_slide met
## nothing steep. That takes a character walking on open ground from 1.00 sweeps
## per frame to 0.00, which is the most common state in most games, and leaves
## the step and wall cases running exactly what they run today.
##
## The one case it must not swallow is force_stair_step. That flag exists for a
## character in the air next to a ledge, and an airborne character has no slide
## collisions at all, so a pre-filter would skip precisely the check the flag was
## set to force. Any implementation has to bypass the filter when it is set.

const FRAMES: int = 40
const SETTLE: int = 30
const WALK: float = 3.0
const RADIUS: float = 0.3
const HEIGHT: float = 1.8
const MARGIN: float = 0.001

var _params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
var _result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()


func _ready() -> void:
	call_deferred(&"_run")


func _box(size: Vector3, centre: Vector3, rotation_z: float = 0.0) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	add_child(body)
	body.global_position = centre
	body.rotation.z = rotation_z


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


# What the shipping forward sweep concludes this frame: does it hit, and is the
# face it hit too steep to walk on - which is what makes the step check proceed.
func _sweep_verdict(c: StairsCharacter) -> String:
	var horizontal: Vector3 = c.velocity * Vector3(1, 0, 1)
	if horizontal == Vector3.ZERO:
		return "no motion"
	_params.from = c.global_transform
	_params.motion = horizontal * c.get_physics_process_delta_time()
	if not PhysicsServer3D.body_test_motion(c.get_rid(), _params, _result):
		return "miss"
	var steep: bool = _result.get_collision_normal(0).angle_to(Vector3.UP) > c.floor_max_angle
	return "steep" if steep else "walkable"


func _drive(tag: String, c: StairsCharacter, walk: Vector3) -> void:
	var rows: PackedStringArray = []
	var agree: int = 0
	var wall_agree: int = 0
	var frames: int = 0

	for i: int in SETTLE + FRAMES:
		c.velocity = Vector3(walk.x, c.velocity.y - 0.16, walk.z)
		c.desired_velocity = walk
		var verdict: String = _sweep_verdict(c)
		c.move_and_stair_step()
		await get_tree().physics_frame

		if i < SETTLE:
			continue

		# What move_and_slide left behind, for the frame that just ran.
		var count: int = c.get_slide_collision_count()
		var steep_seen: bool = false
		var normals: PackedStringArray = []
		for k: int in count:
			var normal: Vector3 = c.get_slide_collision(k).get_normal()
			var degrees: float = rad_to_deg(normal.angle_to(Vector3.UP))
			normals.append("%.0f deg" % degrees)
			if normal.angle_to(Vector3.UP) > c.floor_max_angle:
				steep_seen = true

		frames += 1
		# The trigger a rewrite would use: last frame's slide collisions contained
		# a steep face. Compare against what the sweep said this frame.
		if steep_seen == (verdict == "steep"):
			agree += 1
		# is_on_wall() is the same question already answered: move_and_slide
		# classifies each contact as floor, wall or ceiling using floor_max_angle,
		# and a wall is exactly a face too steep to stand on. If it tracks the
		# normal scan, the trigger costs one bool read and no iteration.
		if steep_seen == c.is_on_wall():
			wall_agree += 1
		if rows.size() < 6:
			rows.append(
				(
					"      sweep %-8s slide count %d [%s] is_on_wall %s"
					% [verdict, count, ", ".join(normals), c.is_on_wall()]
				)
			)

	print(
		"%-24s trigger agrees with the sweep on %d of %d frames, is_on_wall agrees on %d"
		% [tag, agree, frames, wall_agree]
	)
	for row: String in rows:
		print(row)


func _run() -> void:
	# Set explicitly rather than left at the engine default. The comparison only
	# means anything while this sweep uses the same margin the character's own
	# sweeps use; today the default happens to equal MARGIN, so an omission here
	# would not show up as a wrong answer, just as an agreement rate that is
	# really a margin-drift artifact the day the default changes.
	_params.margin = MARGIN

	_box(Vector3(60.0, 1.0, 40.0), Vector3(0.0, -0.5, 0.0))

	var flat: StairsCharacter = _character(Vector3(-20.0, 0.9, -12.0))

	# A climbable 0.2 step.
	_box(Vector3(10.0, 1.0, 6.0), Vector3(5.0, -0.3, -4.0))
	var step: StairsCharacter = _character(Vector3(-1.0, 0.9, -4.0))

	# A wall taller than any step.
	_box(Vector3(1.0, 6.0, 6.0), Vector3(2.0, 3.0, 4.0))
	var wall: StairsCharacter = _character(Vector3(0.0, 0.9, 4.0))

	# A 20 degree ramp - walkable, so the step check must not fire.
	_box(Vector3(20.0, 1.0, 6.0), Vector3(6.0, 1.2, 12.0), -deg_to_rad(20.0))
	var ramp: StairsCharacter = _character(Vector3(-2.0, 0.9, 12.0))

	await _drive("walking, flat ground", flat, Vector3(WALK, 0, 0))
	await _drive("into a 0.2 step", step, Vector3(WALK, 0, 0))
	await _drive("into a tall wall", wall, Vector3(WALK, 0, 0))
	await _drive("up a 20 deg ramp", ramp, Vector3(WALK, 0, 0))
	get_tree().quit()
