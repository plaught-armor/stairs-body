extends Node3D

## A crowd pressed together: a pile of bodies, the case where every sweep pays
## to push out of the neighbours the body overlaps.
##
##     godot --headless --path <repo root> res://test/bench_pile.tscn
##
## 96 box-shaped bodies on their own layer, which they collide with and ignore for
## steps, press toward one point at walk pace and barely move, as a game measured
## its pile: 2.2 m/s wished, about 0.3 m/s moved. Only the move calls of the last
## half are timed, once the pile has formed.
##
##     godot --headless --path <repo root> res://test/bench_pile.tscn -- --idle
##
## runs the same bodies with nothing wished, standing still where they spawned, apart:
## a crowd waiting, the case a resting body skips its checks for.
##
##     godot --headless --path <repo root> res://test/bench_pile.tscn -- --crowd
##
## keeps the bodies apart by crowd separation instead: their own layer leaves their
## masks and goes in crowd_layers. Besides the time, a run prints the mean speed,
## the mean distance from the centre, which says how tight the pile packed, and how
## deep bodies sit inside each other, by the physics server's own depenetration.
##
##     godot --headless --path <repo root> res://test/bench_pile.tscn -- --crowd --grid
##
## walks the crowd on a StairsWalkGrid over the ground as well, and prints the share
## of timed moves made on it.
##
##     godot --headless --path <repo root> res://test/bench_pile.tscn -- --crowd --every 2
##
## moves each body every second frame, at time scale 2, the bodies' turns spread
## over the frames, and prints the overlap a second time after one more frame in
## which every body moves with no velocity and so takes any crowd push it still
## owes.
##
## `--turn-after` turns each body toward its wish after its move rather than before,
## and `--seed N` jitters where the bodies spawn, for sweeps over several piles.

const BODIES: int = 96
const PER_RING: int = 24
const FRAMES: int = 300
const TIMED_FROM: int = 150
const WISH: float = 2.2
# Share of the gap to the wished velocity closed per tick.
const ACCEL: float = 0.15
const GRAVITY_STEP: float = 0.16
const WORLD_LAYER: int = 1
const CROWD_LAYER: int = 32

var _bodies: Array[StairsBody] = []
var _wish_speed: float = 0.0 if OS.get_cmdline_user_args().has("--idle") else WISH
var _crowd: bool = OS.get_cmdline_user_args().has("--crowd")
# Bodies on a walk grid keep apart only by crowd separation, so --grid needs --crowd.
var _grid_asked: bool = OS.get_cmdline_user_args().has("--grid")
# Built in _run, once the flags are vetted, so a run refused in _ready leaks nothing.
var _grid: StairsWalkGrid = null
var _grid_moves: int = 0
var _timed_moves: int = 0
var _every: int = _flag_int("--every", 1)
# Share of the gap to the wished velocity closed per move, over `_every` frames.
var _accel: float = 1.0 - pow(1.0 - ACCEL, float(_every))
var _turn_after: bool = OS.get_cmdline_user_args().has("--turn-after")
var _seed: int = _flag_int("--seed", -1)


func _ready() -> void:
	var bad: String = _bad_flag()
	if not bad.is_empty():
		push_error(bad)
		get_tree().quit(1)
		return
	if _grid_asked and not _crowd:
		push_error(
			"--grid needs --crowd: bodies on a walk grid pass through each other without crowd separation"
		)
		get_tree().quit(1)
		return
	call_deferred(&"_run")


func _run() -> void:
	var ground: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(60.0, 1.0, 60.0)
	shape_node.shape = box
	ground.add_child(shape_node)
	add_child(ground)
	ground.global_position = Vector3(0.0, -0.5, 0.0)
	ground.collision_layer = WORLD_LAYER
	if _crowd and _grid_asked:
		_grid = StairsWalkGrid.new()
		add_child(_grid)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = maxi(_seed, 0)
	for i: int in BODIES:
		var jitter: float = rng.randf_range(-0.1, 0.1) if _seed >= 0 else 0.0
		var angle: float = TAU * float(i) / float(PER_RING) + jitter
		var radius: float = 1.0 + 0.25 * float(i / PER_RING)
		_bodies.append(_spawn(Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)))

	var total: int = 0
	for f: int in FRAMES:
		await get_tree().physics_frame
		var started: int = Time.get_ticks_usec()
		for i: int in _bodies.size():
			if (f + i) % _every == 0:
				_step(_bodies[i])
		if f >= TIMED_FROM:
			total += Time.get_ticks_usec() - started
			for i: int in _bodies.size():
				if (f + i) % _every == 0:
					_timed_moves += 1
					_grid_moves += int(_bodies[i].is_on_walk_grid())
	var speed: float = 0.0
	var spread: float = 0.0
	for body: StairsBody in _bodies:
		speed += Vector2(body.velocity.x, body.velocity.z).length()
		spread += Vector2(body.global_position.x, body.global_position.z).length()
	var overlap: Vector2 = _overlap()
	var owed: String = ""
	if _every > 1:
		await get_tree().physics_frame
		for body: StairsBody in _bodies:
			body.velocity = Vector3.ZERO
			body.move_and_stair_step()
		var taken: Vector2 = _overlap()
		owed = ", once pushes are taken mean %.1f mm max %.1f mm" % [
			taken.x * 1000.0,
			taken.y * 1000.0,
		]
	print(
		(
			"piled %.2f us per body per frame, mean speed %.2f m/s, mean distance from centre %.3f m,"
			+ " overlap mean %.1f mm max %.1f mm, %.0f%% of moves on the grid"
		)
		% [
			float(total) / float((FRAMES - TIMED_FROM) * BODIES),
			speed / float(BODIES),
			spread / float(BODIES),
			overlap.x * 1000.0,
			overlap.y * 1000.0,
			100.0 * float(_grid_moves) / float(_timed_moves),
		]
		+ owed
	)
	get_tree().quit()


## How deep each body sits inside the others, by the physics server's own
## depenetration: mean and max, in metres. Outside the timed region.
func _overlap() -> Vector2:
	var params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
	params.recovery_as_collision = true
	params.margin = 0.001
	var result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
	var total: float = 0.0
	var deepest: float = 0.0
	for body: StairsBody in _bodies:
		var mask: int = body.collision_mask
		body.collision_mask = CROWD_LAYER
		params.from = body.global_transform
		var depth: float = 0.0
		if PhysicsServer3D.body_test_motion(body.get_rid(), params, result):
			depth = result.get_travel().length()
		body.collision_mask = mask
		total += depth
		deepest = maxf(deepest, depth)
	return Vector2(total / float(BODIES), deepest)


func _spawn(at: Vector3) -> StairsBody:
	var body: StairsBody = StairsBody.new()
	body.collision_layer = CROWD_LAYER
	body.collision_mask = WORLD_LAYER if _crowd else WORLD_LAYER | CROWD_LAYER
	if _crowd:
		body.crowd_layers = CROWD_LAYER
	body.step_ignore_layers = CROWD_LAYER
	body.step_height = 0.06
	body.step_down_height = 0.06
	body.walk_grid = _grid
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(0.06, 0.07, 0.18)
	box.margin = 0.004
	shape_node.shape = box
	shape_node.position = Vector3(0.0, 0.035, -0.005)
	body.add_child(shape_node)
	add_child(body)
	body.global_position = at
	return body


## Why the numeric flags cannot be used, or empty when they can.
func _bad_flag() -> String:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	for flag: String in ["--every", "--seed"]:
		var at: int = args.find(flag)
		if at >= 0 and (at + 1 >= args.size() or not args[at + 1].is_valid_int()):
			return "%s needs a whole number after it" % flag
	if _every < 1 or _every > FRAMES - TIMED_FROM:
		return "--every needs 1 to %d, so every body moves while timed" % (FRAMES - TIMED_FROM)
	if args.has("--seed") and _seed < 0:
		return "--seed needs 0 or more"
	return ""


## The integer after `flag` on the command line, or `fallback` when it is absent.
## Runs as the members initialise; a malformed value reads as 0 there, and
## _bad_flag() refuses the run in _ready before any value is used.
func _flag_int(flag: String, fallback: int) -> int:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var at: int = args.find(flag)
	return int(args[at + 1]) if at >= 0 and at + 1 < args.size() else fallback


func _step(body: StairsBody) -> void:
	var to_centre: Vector3 = -body.global_position * Vector3(1.0, 0.0, 1.0)
	var distance: float = to_centre.length()
	var wish: Vector3 = Vector3.ZERO
	if distance > 0.05:
		wish = to_centre * (_wish_speed / distance)
	var walk: Vector3 = (body.velocity * Vector3(1.0, 0.0, 1.0)).lerp(wish, _accel)
	body.velocity = Vector3(walk.x, body.velocity.y - GRAVITY_STEP * float(_every), walk.z)
	body.desired_velocity = wish
	if wish != Vector3.ZERO and not _turn_after:
		body.look_at(body.global_position + wish, Vector3.UP)
	body.move_and_stair_step(float(_every))
	if wish != Vector3.ZERO and _turn_after:
		body.look_at(body.global_position + wish, Vector3.UP)
