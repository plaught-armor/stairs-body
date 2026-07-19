extends Node3D

## Is phase 2's sweep redundant?
##
##     godot --headless --path <repo root> res://test/diag_phase2.tscn
##
## stair_step_up runs four body_test_motion sweeps: forward to find the
## obstacle, up to clamp the rise against a ceiling, forward again at the raised
## height, and down onto the step. The sweeps are the whole cost of the check
## (17-45 us against ~99 ns of everything around them, test/bench_micro.gd), so
## removing one is worth 25% of the check - far more than any micro-rewrite.
##
## Phase 2 is the candidate because its two jobs might both fall out of what the
## other sweeps already do: clamping the rise to available headroom, and bailing
## when a ceiling leaves no room at all. Raise the body unconditionally instead
## and phase 3's depenetration has to push it back out of any ceiling it was
## raised into, which may reach the same answer with one fewer sweep.
##
## The whole 28-case suite passes with phase 2's sweep deleted, including the
## three ceiling cases written to guard exactly that clamp. That is not evidence
## of equivalence - it is the same trap as test/diag_multishape.gd, where a
## variant passed case 25 without the case discriminating. A pass-fail suite
## answers "did anything break", not "do these two agree everywhere".
##
## So this sweeps a grid instead: every combination of ceiling clearance and step
## height, printing the height the character ends at. Run it against the shipping
## four-phase code, then against the variant, and diff the two outputs. Any row
## that differs is a case the suite does not cover.
##
## VERDICT: the variant is dead, and this file did not kill it. All 81 rows here
## agree - final height, peak height and ceiling overlap alike - which is why it
## looked shippable. An adversarial search found the divergence this grid cannot
## reach, and the reason is one missing ingredient: every world here puts the
## ceiling directly over the step with nothing beyond it, so phase 4 never has
## anywhere BELOW the start height to land. Add ground beyond the obstacle that
## sits lower than the character's feet and the variant sinks the body by up to
## 0.2 m (test/diag_sink_robustness.gd: 70 of 252 perturbed trials, against 0 of
## 252 on shipping). Pinned by test case 29.
##
## Keep this file as the cautionary half of that story. A grid that varies the
## parameters you thought of is not coverage; it is a confident-looking way to
## miss the case you did not think of.

var _step_heights: PackedFloat32Array = [0.1, 0.2, 0.3]
# Headroom above the character's head, from none to more than a step.
var _clearances: PackedFloat32Array = [0.0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.6]
var _speeds: PackedFloat32Array = [1.0, 3.0, 8.0]

const RADIUS: float = 0.3
const HEIGHT: float = 1.8
const REST_Y: float = 0.9
const MARGIN: float = 0.001
const GRAVITY: float = 9.8
const DELTA: float = 1.0 / 60.0
const SETTLE: int = 15

var _last_peak: float = 0.0
var _last_overlap: float = 0.0
const WALK: int = 45


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


func _run() -> void:
	print("step  clear  speed   final_y  peak_y   overlap  climbed")
	for step_height: float in _step_heights:
		for clearance: float in _clearances:
			for speed: float in _speeds:
				var final_y: float = await _trial(step_height, clearance, speed)
				print(
					(
						"%.2f  %.2f   %.1f    %7.4f  %7.4f  %7.4f  %s"
						% [
							step_height,
							clearance,
							speed,
							final_y,
							_last_peak,
							_last_overlap,
							"yes" if final_y > REST_Y + 0.02 else "no",
						]
					)
				)
	get_tree().quit()


## One world: ground, a step of `step_height`, and a ceiling leaving `clearance`
## above the character's head. Returns the height it ends at.
func _trial(step_height: float, clearance: float, speed: float) -> float:
	var world: Node3D = Node3D.new()
	add_child(world)

	_box(world, Vector3(20.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	_box(world, Vector3(4.0, 2.0, 8.0), Vector3(3.0, step_height - 1.0, 0.0))
	# Head is at REST_Y + HEIGHT/2 = 1.8. The ceiling's underside sits `clearance`
	# above that, over the step only, so the approach is unobstructed.
	var ceiling_bottom: float = REST_Y + HEIGHT * 0.5 + clearance
	_box(world, Vector3(4.0, 1.0, 8.0), Vector3(3.0, ceiling_bottom + 0.5, 0.0))

	var c: StairsCharacter = StairsCharacter.new()
	c.step_height = step_height
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = RADIUS
	cyl.height = HEIGHT
	cyl.margin = MARGIN
	shape_node.shape = cyl
	c.add_child(shape_node)
	c.collider = shape_node
	world.add_child(c)
	c.global_position = Vector3(0.0, REST_Y, 0.0)

	for _i: int in SETTLE:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()

	# Peak as well as final. Final height cannot see a transient: without phase
	# 2's clamp the body is placed inside the ceiling for part of the check, and
	# if that ever survives to the end of the frame it is a one-frame pop through
	# geometry that a resting-height comparison reports as identical.
	var peak: float = -INF
	for _i: int in WALK:
		await get_tree().physics_frame
		c.velocity.x = speed
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = Vector3(speed, 0.0, 0.0)
		c.move_and_stair_step()
		peak = maxf(peak, c.global_position.y)

	# How far the head got past the ceiling's underside, if at all.
	var overlap: float = maxf(0.0, peak + HEIGHT * 0.5 - ceiling_bottom)
	_last_peak = peak
	_last_overlap = overlap
	var final_y: float = c.global_position.y
	world.queue_free()
	return final_y
