extends Node

## Prices the allocations that the stair stepping path used to make per frame.
##
##     godot --headless --path <repo root> res://test/bench_alloc.tscn
##
## Deliberately isolated from the physics. An earlier version of this bench drove
## N characters through a real world and timed the frames, which measured nothing
## useful for two reasons: the timing spanned `await physics_frame`, so ~16.67 ms
## of idle scheduler wait swamped a single-microsecond effect, and characters
## walking past a step take the four-sweep path about once each over a whole run
## rather than every frame. Isolating the allocations answers the only question
## the hoist actually raises - what they cost - and leaves the question of what
## share of a frame that is to arithmetic against a measured per-character cost.

## Characters x frames, so the totals read as "one second of a 400 character game".
const ITERATIONS: int = 400 * 300
const RUNS: int = 7


func _ready() -> void:
	for _i: int in 10000:
		var _warm: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()

	var best_alloc: int = 1 << 62
	var best_reuse: int = 1 << 62

	for _run: int in RUNS:
		best_alloc = mini(best_alloc, _time_allocating())
		best_reuse = mini(best_reuse, _time_reusing())

	var saved_us: float = float(best_alloc - best_reuse)
	print("iterations=%d (400 characters x 300 frames)" % ITERATIONS)
	print("allocating_ms=%.1f reusing_ms=%.1f" % [best_alloc / 1000.0, best_reuse / 1000.0])
	print(
		"saved_ms=%.1f saved_us_per_character_frame=%.3f"
		% [saved_us / 1000.0, saved_us / ITERATIONS]
	)
	get_tree().quit()


## The shape upstream had: a fresh result and parameters pair in each of the two
## step functions, so four objects per character per frame.
func _time_allocating() -> int:
	var started: int = Time.get_ticks_usec()
	for _i: int in ITERATIONS:
		var up_result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
		var up_params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
		var down_result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
		var down_params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
		up_params.margin = 0.001
		down_params.margin = 0.001
		up_result.get_travel()
		down_result.get_travel()
	return Time.get_ticks_usec() - started


## The shape the addon has now: one pair held on the character, touched the same
## number of times.
func _time_reusing() -> int:
	var result: PhysicsTestMotionResult3D = PhysicsTestMotionResult3D.new()
	var params: PhysicsTestMotionParameters3D = PhysicsTestMotionParameters3D.new()
	var started: int = Time.get_ticks_usec()
	for _i: int in ITERATIONS:
		params.margin = 0.001
		params.margin = 0.001
		result.get_travel()
		result.get_travel()
	return Time.get_ticks_usec() - started
