extends Node3D

## Headless cases for StairsBody's walk mode on a StairsWalkGrid. Each case runs
## one scenario twice, a body on the grid and a body sweeping, each in a world
## node of its own, and checks the grid walk ends where the sweeps do, and that it
## walked on the grid where it should and swept where it must. The worlds share one
## physics space, one after another: each is freed at the end of the frame it
## finishes in, before the next scenario's first move, and a grid bakes only its
## own world.
##
##     godot --headless --path <repo root> res://test/test_walk_grid.tscn
##
## Exit code is the number of failed cases. `print` is the harness output.

const DELTA: float = 1.0 / 60.0
const BODY_RADIUS: float = 0.3
const BODY_HEIGHT: float = 1.8
const REST_Y: float = 0.9
const COLLIDER_MARGIN: float = 0.001
const GRAVITY: float = 9.8
const CROWD_LAYER: int = 32
const SETTLE_TICKS: int = 10
const RISE: float = 0.2
const TREAD: float = 0.3
const TREADS: int = 5
## How far the grid walk may end from the sweeps, in metres: past the gap Jolt
## leaves at a face (4.2 mm), and the 0.1 mm Godot Physics rests above a floor.
const TOLERANCE: float = 0.006
## Along +z, in m/s.
const CONVEYOR_SPEED: float = 1.0
## StairsBody.min_step_forward's default.
const MIN_STEP_FORWARD: float = 0.02
## Seconds before _close_door's door starts to close: it crosses the path as the
## body, walking from x = -2 at 3 m/s, comes within reach of it.
const DOOR_WAIT: float = 0.45

var _passed: int = 0
var _failed: int = 0
# Whether the box _carry_box froze was asleep when frozen, for w29.
var _carried_asleep: bool = false
# Bodies the grid still tracked a few frames after w32's free, or -1 before.
var _movers_left: int = -1


func _ready() -> void:
	call_deferred(&"_run_all")


func _run_all() -> void:
	print("--- StairsBody walk-grid run ---")
	await _case_w01_a_flat_walk_stays_on_the_grid()
	await _case_w02_a_flight_climbed_on_the_grid_matches_the_sweeps()
	await _case_w03_a_flight_descended_on_the_grid_matches_the_sweeps()
	await _case_w04_a_slide_along_a_wall_matches_the_sweeps()
	await _case_w05_a_slide_along_a_turned_wall_matches_the_sweeps()
	await _case_w06_a_drop_past_the_step_down_reach_falls_and_comes_back()
	await _case_w07_a_shape_the_grid_does_not_bake_is_swept()
	await _case_w08_a_step_under_a_low_ceiling_is_left_to_the_sweeps()
	await _case_w09_crowd_bodies_on_the_grid_stop_touching()
	await _case_w10_a_stretched_frame_on_the_grid_walks_as_far()
	await _case_w11_the_bake_keeps_upright_boxes_and_leaves_the_rest()
	await _case_w12_a_long_stretched_move_does_not_pass_a_thin_wall()
	await _case_w13_a_walk_nearly_head_on_into_a_wall_stops()
	await _case_w14_a_wall_off_the_grid_mask_is_swept()
	await _case_w15_a_conveyor_carries_a_body_that_walks_onto_it()
	await _case_w16_a_resting_body_keeps_its_contacts()
	await _case_w17_a_body_standing_at_a_wall_is_on_it()
	await _case_w18_a_level_too_large_to_index_is_swept()
	await _case_w19_a_wall_freed_after_the_bake_no_longer_blocks()
	_case_w20_the_grid_says_when_the_level_has_changed()
	await _case_w21_intent_alone_climbs_a_step_on_the_grid()
	await _case_w22_intent_alone_into_a_wall_holds_the_body_on_it()
	await _case_w23_a_moving_body_in_the_path_is_swept_against()
	await _case_w24_a_moving_body_added_after_the_bake_is_seen()
	await _case_w25_a_moving_body_off_the_mask_is_walked_past()
	await _case_w26_a_moving_body_freed_no_longer_counts()
	await _case_w27_a_door_sliding_across_the_path_stops_the_walk()
	await _case_w28_a_sleeping_loose_box_in_the_path_still_stops_the_walk()
	await _case_w29_a_sleeping_box_frozen_and_carried_into_the_path_stops_the_walk()
	await _case_w30_a_body_placed_after_it_is_added_is_seen_where_it_was_placed()
	await _case_w31_a_body_under_the_walker_is_not_in_its_way()
	await _case_w32_a_body_freed_without_an_exit_signal_no_longer_counts()
	print("--- %d passed, %d failed ---" % [_passed, _failed])
	get_tree().quit(_failed)


func _check(case_name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
		print("PASS  %s" % case_name)
	else:
		_failed += 1
		print("FAIL  %s — %s" % [case_name, detail])


func _new_world() -> Node3D:
	var world: Node3D = Node3D.new()
	add_child(world)
	return world


func _add_box(world: Node3D, size: Vector3, centre: Vector3, yaw: float = 0.0) -> StaticBody3D:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	world.add_child(body)
	body.global_position = centre
	body.rotation.y = yaw
	return body


func _add_body(world: Node3D, at: Vector3, c: StairsBody = StairsBody.new()) -> StairsBody:
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cylinder: CylinderShape3D = CylinderShape3D.new()
	cylinder.radius = BODY_RADIUS
	cylinder.height = BODY_HEIGHT
	cylinder.margin = COLLIDER_MARGIN
	shape_node.shape = cylinder
	c.add_child(shape_node)
	world.add_child(c)
	c.global_position = at
	return c


## A grid over `world`, given to `c` when `on_grid`.
func _use_grid(world: Node3D, c: StairsBody, on_grid: bool) -> void:
	if not on_grid:
		return
	var grid: StairsWalkGrid = StairsWalkGrid.new()
	world.add_child(grid)
	c.walk_grid = grid


## A floor from x = -5 to 3, and a flight of TREADS steps up along +x from x = 0.
func _flight_world() -> Node3D:
	var world: Node3D = _new_world()
	_add_box(world, Vector3(8.0, 1.0, 8.0), Vector3(-1.0, -0.5, 0.0))
	for i: int in TREADS:
		var top: float = RISE * float(i + 1)
		_add_box(world, Vector3(TREAD, top, 8.0), Vector3(TREAD * (float(i) + 0.5), top * 0.5, 0.0))
	var landing: float = RISE * float(TREADS)
	_add_box(
		world,
		Vector3(4.0, landing, 8.0),
		Vector3(TREAD * float(TREADS) + 2.0, landing * 0.5, 0.0),
	)
	return world


## Settles a body at `start` in the world `build` makes, then walks it at `walk`
## for `ticks`, moving it every `every` frames at that time scale, colliding with
## `mask`, with `intent` as desired_velocity. `settled` is called with the world
## between the two.
func _run(
	build: Callable,
	start: Vector3,
	walk: Vector3,
	ticks: int,
	on_grid: bool,
	every: int = 1,
	mask: int = 1,
	settled: Callable = Callable(),
	intent: Vector3 = Vector3.ZERO,
) -> Run:
	var world: Node3D = build.call()
	var c: StairsBody = _add_body(world, start)
	c.collision_mask = mask
	_use_grid(world, c, on_grid)
	var run: Run = Run.new()
	c.stepped_up.connect(
		func(_rise: float) -> void:
			run.ups += 1,
	)
	c.stepped_down.connect(
		func(_drop: float) -> void:
			run.downs += 1,
	)
	for _i: int in SETTLE_TICKS:
		await get_tree().physics_frame
		c.velocity.y -= GRAVITY * DELTA
		c.move_and_stair_step()
	if settled.is_valid():
		settled.call(world)
	for i: int in ticks:
		await get_tree().physics_frame
		if i % every != 0:
			continue
		c.velocity = Vector3(walk.x, c.velocity.y - GRAVITY * DELTA * every, walk.z)
		c.desired_velocity = intent
		c.move_and_stair_step(float(every))
		run.grid_ticks += 1 if c.is_on_walk_grid() else 0
	run.position = c.global_position
	run.on_wall = c.is_on_wall()
	run.wall_normal = c.get_wall_normal()
	run.on_floor = c.is_on_floor()
	run.last_on_grid = c.is_on_walk_grid()
	world.queue_free()
	return run


## Whether the grid run ended where the swept run did, on and against the same,
## within TOLERANCE plus `slack`.
func _same(grid: Run, swept: Run, slack: float = 0.0) -> bool:
	return (
		grid.position.distance_to(swept.position) < TOLERANCE + slack
		and grid.on_wall == swept.on_wall and grid.on_floor == swept.on_floor
		and (not grid.on_wall or grid.wall_normal.distance_to(swept.wall_normal) < 0.01)
	)


## Both runs for a failure message; `other` names the second.
func _describe(grid: Run, swept: Run, other: String = "swept") -> String:
	return "grid %s wall %s %s floor %s up %d down %d on grid %d/%s; %s %s wall %s %s floor %s up %d down %d" % [
		grid.position,
		grid.on_wall,
		grid.wall_normal,
		grid.on_floor,
		grid.ups,
		grid.downs,
		grid.grid_ticks,
		grid.last_on_grid,
		other,
		swept.position,
		swept.on_wall,
		swept.wall_normal,
		swept.on_floor,
		swept.ups,
		swept.downs,
	]


func _flat_world() -> Node3D:
	var world: Node3D = _new_world()
	_add_box(world, Vector3(20.0, 1.0, 8.0), Vector3(0.0, -0.5, 0.0))
	return world


func _case_w01_a_flat_walk_stays_on_the_grid() -> void:
	const TICKS: int = 60
	var grid: Run = await _run(
		_flat_world,
		Vector3(-3.0, REST_Y, 0.0),
		Vector3(3.0, 0.0, 1.0),
		TICKS,
		true,
	)
	var swept: Run = await _run(
		_flat_world,
		Vector3(-3.0, REST_Y, 0.0),
		Vector3(3.0, 0.0, 1.0),
		TICKS,
		false,
	)
	_check(
		"w01 a flat walk stays on the grid",
		_same(grid, swept) and grid.grid_ticks == TICKS and swept.grid_ticks == 0,
		_describe(grid, swept),
	)


## The flight's treads and risers are separate boxes; the grid walk climbs each
## as the step sweeps do, announcing each rise once. A step up under Godot Physics
## carries the body up to min_step_forward past where its velocity takes it,
## measured 2 cm over the flight; the grid walk moves it by velocity alone.
func _case_w02_a_flight_climbed_on_the_grid_matches_the_sweeps() -> void:
	const TICKS: int = 150
	var grid: Run = await _run(
		_flight_world,
		Vector3(-1.0, REST_Y, 0.0),
		Vector3(1.5, 0.0, 0.0),
		TICKS,
		true,
	)
	var swept: Run = await _run(
		_flight_world,
		Vector3(-1.0, REST_Y, 0.0),
		Vector3(1.5, 0.0, 0.0),
		TICKS,
		false,
	)
	_check(
		"w02 a flight climbed on the grid matches the sweeps",
		_same(grid, swept, MIN_STEP_FORWARD) and grid.ups == TREADS
		and swept.ups == TREADS and grid.grid_ticks == TICKS,
		_describe(grid, swept),
	)


func _case_w03_a_flight_descended_on_the_grid_matches_the_sweeps() -> void:
	const TICKS: int = 150
	var top: Vector3 = Vector3(TREAD * float(TREADS) + 1.0, REST_Y + RISE * float(TREADS), 0.0)
	var grid: Run = await _run(_flight_world, top, Vector3(-1.5, 0.0, 0.0), TICKS, true)
	var swept: Run = await _run(_flight_world, top, Vector3(-1.5, 0.0, 0.0), TICKS, false)
	_check(
		"w03 a flight descended on the grid matches the sweeps",
		_same(grid, swept) and grid.downs == TREADS
		and swept.downs == TREADS and grid.grid_ticks == TICKS,
		_describe(grid, swept),
	)


func _walled_world(yaw: float) -> Node3D:
	var world: Node3D = _flat_world()
	_add_box(world, Vector3(0.4, 3.0, 12.0), Vector3(1.0, 1.5, 0.0), yaw)
	return world


## Walking at a slant into a wall, both stop at its face and slide along it.
func _case_w04_a_slide_along_a_wall_matches_the_sweeps() -> void:
	const TICKS: int = 90
	var build: Callable = _walled_world.bind(0.0)
	var grid: Run = await _run(
		build,
		Vector3(-2.0, REST_Y, 0.0),
		Vector3(3.0, 0.0, 1.0),
		TICKS,
		true,
	)
	var swept: Run = await _run(
		build,
		Vector3(-2.0, REST_Y, 0.0),
		Vector3(3.0, 0.0, 1.0),
		TICKS,
		false,
	)
	_check(
		"w04 a slide along a wall matches the sweeps",
		_same(grid, swept) and grid.on_wall and grid.grid_ticks == TICKS,
		_describe(grid, swept),
	)


func _case_w05_a_slide_along_a_turned_wall_matches_the_sweeps() -> void:
	const TICKS: int = 90
	var build: Callable = _walled_world.bind(deg_to_rad(20.0))
	var grid: Run = await _run(
		build,
		Vector3(-2.0, REST_Y, 0.0),
		Vector3(3.0, 0.0, 1.0),
		TICKS,
		true,
	)
	var swept: Run = await _run(
		build,
		Vector3(-2.0, REST_Y, 0.0),
		Vector3(3.0, 0.0, 1.0),
		TICKS,
		false,
	)
	_check(
		"w05 a slide along a turned wall matches the sweeps",
		_same(grid, swept) and grid.on_wall and grid.grid_ticks == TICKS,
		_describe(grid, swept),
	)


## A 1 m ledge: the grid hands the fall to the sweeps, and takes the body back
## once it lands.
func _ledge_world() -> Node3D:
	var world: Node3D = _new_world()
	_add_box(world, Vector3(4.0, 2.0, 8.0), Vector3(-2.0, 0.0, 0.0))
	_add_box(world, Vector3(8.0, 1.0, 8.0), Vector3(4.0, -0.5, 0.0))
	return world


func _case_w06_a_drop_past_the_step_down_reach_falls_and_comes_back() -> void:
	const TICKS: int = 120
	var start: Vector3 = Vector3(-1.5, REST_Y + 1.0, 0.0)
	var grid: Run = await _run(_ledge_world, start, Vector3(1.5, 0.0, 0.0), TICKS, true)
	var swept: Run = await _run(_ledge_world, start, Vector3(1.5, 0.0, 0.0), TICKS, false)
	_check(
		"w06 a drop past the step-down reach falls and comes back",
		_same(grid, swept) and grid.last_on_grid and grid.grid_ticks < TICKS - 10,
		_describe(grid, swept),
	)


## A cylinder the grid leaves out: near it, the body sweeps.
func _pillar_world() -> Node3D:
	var world: Node3D = _flat_world()
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var pillar: CylinderShape3D = CylinderShape3D.new()
	pillar.radius = 0.3
	pillar.height = 3.0
	shape_node.shape = pillar
	body.add_child(shape_node)
	world.add_child(body)
	body.global_position = Vector3(1.0, 1.5, 0.0)
	return world


func _case_w07_a_shape_the_grid_does_not_bake_is_swept() -> void:
	const TICKS: int = 60
	var grid: Run = await _run(
		_pillar_world,
		Vector3(-2.0, REST_Y, 0.0),
		Vector3(3.0, 0.0, 0.0),
		TICKS,
		true,
	)
	var swept: Run = await _run(
		_pillar_world,
		Vector3(-2.0, REST_Y, 0.0),
		Vector3(3.0, 0.0, 0.0),
		TICKS,
		false,
	)
	_check(
		"w07 a shape the grid does not bake is swept",
		_same(grid, swept) and grid.on_wall and not grid.last_on_grid and grid.grid_ticks > 0,
		_describe(grid, swept),
	)


## A step whose top leaves less headroom than the body is tall: the sweeps decide.
func _low_ceiling_world() -> Node3D:
	var world: Node3D = _flat_world()
	_add_box(world, Vector3(4.0, RISE, 8.0), Vector3(3.0, RISE * 0.5, 0.0))
	_add_box(world, Vector3(4.0, 0.5, 8.0), Vector3(3.0, BODY_HEIGHT + 0.1 + 0.25, 0.0))
	return world


func _case_w08_a_step_under_a_low_ceiling_is_left_to_the_sweeps() -> void:
	const TICKS: int = 60
	var grid: Run = await _run(
		_low_ceiling_world,
		Vector3(-1.0, REST_Y, 0.0),
		Vector3(3.0, 0.0, 0.0),
		TICKS,
		true,
	)
	var swept: Run = await _run(
		_low_ceiling_world,
		Vector3(-1.0, REST_Y, 0.0),
		Vector3(3.0, 0.0, 0.0),
		TICKS,
		false,
	)
	_check(
		"w08 a step under a low ceiling is left to the sweeps",
		_same(grid, swept) and grid.position.x < 1.0 and grid.grid_ticks > 0,
		_describe(grid, swept),
	)


func _add_crowd_body(world: Node3D, at: Vector3, grid: StairsWalkGrid) -> StairsBody:
	var c: StairsBody = StairsBody.new()
	c.collision_layer = CROWD_LAYER
	c.collision_mask = 1
	c.crowd_layers = CROWD_LAYER
	c.walk_grid = grid
	return _add_body(world, at, c)


## Crowd separation runs on the grid as it does sweeping: head on, two stop with
## their footprints touching.
func _case_w09_crowd_bodies_on_the_grid_stop_touching() -> void:
	const SPEED: float = 3.0
	const TICKS: int = 60
	var world: Node3D = _flat_world()
	var grid: StairsWalkGrid = StairsWalkGrid.new()
	world.add_child(grid)
	var a: StairsBody = _add_crowd_body(world, Vector3(-1.0, REST_Y, 0.0), grid)
	var b: StairsBody = _add_crowd_body(world, Vector3(1.07, REST_Y, 0.0), grid)
	var closest: float = INF
	var grid_moves: int = 0
	for i: int in TICKS + SETTLE_TICKS:
		await get_tree().physics_frame
		var walk: float = SPEED if i >= SETTLE_TICKS else 0.0
		a.velocity = Vector3(walk, a.velocity.y - GRAVITY * DELTA, 0.0)
		b.velocity = Vector3(-walk, b.velocity.y - GRAVITY * DELTA, 0.0)
		a.move_and_stair_step()
		b.move_and_stair_step()
		grid_moves += int(a.is_on_walk_grid()) + int(b.is_on_walk_grid())
		closest = minf(closest, b.global_position.x - a.global_position.x)
	var apart: float = b.global_position.x - a.global_position.x
	_check(
		"w09 crowd bodies on the grid stop touching",
		absf(apart - 2.0 * BODY_RADIUS) < TOLERANCE
		and closest > 2.0 * BODY_RADIUS - TOLERANCE and grid_moves >= 2 * TICKS,
		"%.4f m apart, closest %.4f, %d moves on the grid" % [apart, closest, grid_moves],
	)
	world.queue_free()


func _case_w10_a_stretched_frame_on_the_grid_walks_as_far() -> void:
	const TICKS: int = 60
	var grid: Run = await _run(
		_flight_world,
		Vector3(-1.0, REST_Y, 0.0),
		Vector3(1.5, 0.0, 0.0),
		TICKS,
		true,
		4,
	)
	var every: Run = await _run(
		_flight_world,
		Vector3(-1.0, REST_Y, 0.0),
		Vector3(1.5, 0.0, 0.0),
		TICKS,
		true,
	)
	_check(
		"w10 a stretched frame on the grid walks as far",
		_same(grid, every) and grid.grid_ticks == TICKS / 4,
		_describe(grid, every, "every frame"),
	)


func _case_w11_the_bake_keeps_upright_boxes_and_leaves_the_rest() -> void:
	var world: Node3D = _pillar_world()
	_add_box(world, Vector3(1.0, 1.0, 1.0), Vector3(5.0, 0.5, 0.0), deg_to_rad(30.0))
	var tilted: StaticBody3D = _add_box(world, Vector3(1.0, 1.0, 1.0), Vector3(-5.0, 0.5, 0.0))
	tilted.rotation.x = deg_to_rad(10.0)
	var off_mask: StaticBody3D = _add_box(world, Vector3(1.0, 1.0, 1.0), Vector3(0.0, 0.5, 3.0))
	off_mask.collision_layer = 2
	var conveyor: StaticBody3D = _add_box(world, Vector3(1.0, 1.0, 1.0), Vector3(0.0, 0.5, -3.0))
	conveyor.constant_linear_velocity = Vector3(1.0, 0.0, 0.0)
	var grid: StairsWalkGrid = StairsWalkGrid.new()
	world.add_child(grid)
	grid.bake()
	_check(
		"w11 the bake keeps upright boxes and leaves the rest",
		grid.is_baked() and grid.get_box_count() == 2 and grid.get_unknown_count() == 4,
		(
			"%d boxes expected 2 (floor, turned box), %d left out expected 4"
			+ " (pillar, tilted box, box off the mask, conveyor)"
		)
		% [grid.get_box_count(), grid.get_unknown_count()],
	)
	world.queue_free()


func _thin_wall_world() -> Node3D:
	var world: Node3D = _flat_world()
	_add_box(world, Vector3(0.05, 3.0, 8.0), Vector3(1.0, 1.5, 0.0))
	return world


## Moved every eighth frame at 6 m/s, one move covers 0.8 m, more than the
## footprint and a 5 cm wall together: the grid walk still stops at the wall.
func _case_w12_a_long_stretched_move_does_not_pass_a_thin_wall() -> void:
	const TICKS: int = 64
	var start: Vector3 = Vector3(-2.0, REST_Y, 0.0)
	var grid: Run = await _run(_thin_wall_world, start, Vector3(6.0, 0.0, 0.0), TICKS, true, 8)
	var swept: Run = await _run(_thin_wall_world, start, Vector3(6.0, 0.0, 0.0), TICKS, false, 8)
	_check(
		"w12 a long stretched move does not pass a thin wall",
		_same(grid, swept) and grid.on_wall and grid.grid_ticks == TICKS / 8,
		_describe(grid, swept),
	)


## Walked into a wall 10 degrees off head-on, inside HEAD_ON's 15, both stop at
## the face rather than creeping along it.
func _case_w13_a_walk_nearly_head_on_into_a_wall_stops() -> void:
	const TICKS: int = 90
	var build: Callable = _walled_world.bind(0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0).rotated(Vector3.UP, deg_to_rad(10.0))
	var grid: Run = await _run(build, Vector3(-2.0, REST_Y, 0.0), walk, TICKS, true)
	var swept: Run = await _run(build, Vector3(-2.0, REST_Y, 0.0), walk, TICKS, false)
	_check(
		"w13 a walk nearly head on into a wall stops",
		_same(grid, swept) and grid.on_wall and grid.grid_ticks == TICKS,
		_describe(grid, swept),
	)


## A wall on a layer the grid does not bake, but the body collides with: the body
## sweeps near it and stops at it, rather than walking through.
func _off_mask_wall_world() -> Node3D:
	var world: Node3D = _flat_world()
	var wall: StaticBody3D = _add_box(world, Vector3(0.2, 3.0, 8.0), Vector3(1.0, 1.5, 0.0))
	wall.collision_layer = 2
	return world


func _case_w14_a_wall_off_the_grid_mask_is_swept() -> void:
	const TICKS: int = 60
	var start: Vector3 = Vector3(-2.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0)
	var grid: Run = await _run(_off_mask_wall_world, start, walk, TICKS, true, 1, 3)
	var swept: Run = await _run(_off_mask_wall_world, start, walk, TICKS, false, 1, 3)
	_check(
		"w14 a wall off the grid mask is swept",
		_same(grid, swept) and grid.on_wall and not grid.last_on_grid and grid.grid_ticks > 0,
		_describe(grid, swept),
	)


## A floor, then a conveyor carrying along +z: a body that walks onto the conveyor
## is carried by it, as with sweeps, since the grid leaves conveyors out. The hand
## over can land a frame apart, one frame's carry.
func _conveyor_world() -> Node3D:
	var world: Node3D = _new_world()
	_add_box(world, Vector3(4.0, 1.0, 8.0), Vector3(-2.0, -0.5, 0.0))
	var conveyor: StaticBody3D = _add_box(world, Vector3(4.0, 1.0, 8.0), Vector3(2.0, -0.5, 0.0))
	conveyor.constant_linear_velocity = Vector3(0.0, 0.0, CONVEYOR_SPEED)
	return world


func _case_w15_a_conveyor_carries_a_body_that_walks_onto_it() -> void:
	const TICKS: int = 60
	var start: Vector3 = Vector3(-1.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(1.5, 0.0, 0.0)
	var grid: Run = await _run(_conveyor_world, start, walk, TICKS, true)
	var swept: Run = await _run(_conveyor_world, start, walk, TICKS, false)
	_check(
		"w15 a conveyor carries a body that walks onto it",
		_same(grid, swept, CONVEYOR_SPEED * DELTA)
		and grid.position.z > 0.3 and not grid.last_on_grid,
		_describe(grid, swept),
	)


## A body resting beside a shape the grid leaves out keeps the contacts its last
## move listed, as a resting body does with sweeps: a grid move tried and given up
## on emptied the list. The two counts differ by one on Godot Physics, whose
## resting contact test lists a varying number.
func _case_w16_a_resting_body_keeps_its_contacts() -> void:
	var counts: PackedInt32Array = []
	for on_grid: bool in [true, false]:
		var world: Node3D = _pillar_world()
		var c: StairsBody = _add_body(world, Vector3(1.0 - 0.3 - BODY_RADIUS, REST_Y, 0.0))
		_use_grid(world, c, on_grid)
		for _i: int in SETTLE_TICKS * 3:
			await get_tree().physics_frame
			c.velocity = Vector3(0.0, c.velocity.y - GRAVITY * DELTA, 0.0)
			c.move_and_stair_step()
		counts.append(c.get_contact_count())
		world.queue_free()
	_check(
		"w16 a resting body keeps its contacts",
		counts[0] >= 2 and counts[1] >= 2,
		"%d contacts on the grid, %d swept, expected at least floor and pillar each"
		% [counts[0], counts[1]],
	)


## Walked into a wall and then left standing, the grid reports the wall as the
## sweeps do: both leave the body a margin or more from the face, not touching it.
func _case_w17_a_body_standing_at_a_wall_is_on_it() -> void:
	var on_wall: Array[bool] = []
	for on_grid: bool in [true, false]:
		var world: Node3D = _walled_world(0.0)
		var c: StairsBody = _add_body(world, Vector3(-1.0, REST_Y, 0.0))
		_use_grid(world, c, on_grid)
		for i: int in 60:
			await get_tree().physics_frame
			var walk: float = 3.0 if i < 30 else 0.0
			c.velocity = Vector3(walk, c.velocity.y - GRAVITY * DELTA, 0.0)
			c.move_and_stair_step()
		on_wall.append(c.is_on_wall())
		world.queue_free()
	_check(
		"w17 a body standing at a wall is on it",
		on_wall[0] == on_wall[1],
		"on the wall: grid %s, swept %s" % [on_wall[0], on_wall[1]],
	)


## A floor 40 km square is past what the grid indexes: it bakes nothing, and the
## body sweeps.
func _huge_world() -> Node3D:
	var world: Node3D = _new_world()
	_add_box(world, Vector3(40000.0, 1.0, 40000.0), Vector3(0.0, -0.5, 0.0))
	return world


func _case_w18_a_level_too_large_to_index_is_swept() -> void:
	const TICKS: int = 30
	var start: Vector3 = Vector3(0.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0)
	var grid: Run = await _run(_huge_world, start, walk, TICKS, true)
	var swept: Run = await _run(_huge_world, start, walk, TICKS, false)
	_check(
		"w18 a level too large to index is swept",
		_same(grid, swept) and grid.grid_ticks == 0,
		_describe(grid, swept),
	)


## Bakes any grid in `world`, since a body at rest has not yet, then frees the
## wall `_walled_world` adds, its second child.
func _free_wall(world: Node3D) -> void:
	for child: Node in world.get_children():
		var grid: StairsWalkGrid = child as StairsWalkGrid
		if grid != null:
			grid.bake()
	var wall: StaticBody3D = world.get_child(1) as StaticBody3D
	if wall == null or not is_equal_approx(wall.position.x, 1.0):
		push_error("_free_wall: the second child is not the wall")
		return
	wall.free()


## A wall freed once the grid has baked leaves the index at once: the grid walk
## passes where it stood, as the sweeps do, ending 3 m on at x = 1, past its
## near face at 0.8.
func _case_w19_a_wall_freed_after_the_bake_no_longer_blocks() -> void:
	const TICKS: int = 60
	var build: Callable = _walled_world.bind(0.0)
	var start: Vector3 = Vector3(-2.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0)
	var grid: Run = await _run(build, start, walk, TICKS, true, 1, 1, _free_wall)
	var swept: Run = await _run(build, start, walk, TICKS, false, 1, 1, _free_wall)
	_check(
		"w19 a wall freed after the bake no longer blocks",
		_same(grid, swept) and grid.position.x > 0.9 and grid.grid_ticks == TICKS,
		_describe(grid, swept),
	)


## Adding a static body, moving a baked one and changing the mask each leave the
## grid stale until it bakes again. Prints two expected warnings.
func _case_w20_the_grid_says_when_the_level_has_changed() -> void:
	var world: Node3D = _flat_world()
	var grid: StairsWalkGrid = StairsWalkGrid.new()
	world.add_child(grid)
	grid.bake()
	var fresh: bool = not grid.is_stale()
	var box: StaticBody3D = _add_box(world, Vector3(1.0, 1.0, 1.0), Vector3(2.0, 0.5, 0.0))
	var added: bool = grid.is_stale()
	grid.bake()
	var rebaked: bool = not grid.is_stale() and grid.get_box_count() == 2
	grid.bake()
	var watches: int = box.get_signal_connection_list(&"tree_exiting").size()
	box.position.x += 0.5
	var moved: bool = grid.is_stale()
	grid.bake()
	grid.collision_mask = 3
	var masked: bool = grid.is_stale()
	grid.free()
	world.free()
	_check(
		"w20 the grid says when the level has changed",
		fresh and added and rebaked and watches == 1 and moved and masked,
		(
			"fresh %s, added %s, rebaked %s, %d exit watches after two bakes expected 1,"
			+ " moved %s, masked %s"
		)
		% [fresh, added, rebaked, watches, moved, masked],
	)


## A body standing still 15 mm short of the flight's first riser, with
## desired_velocity pointing up the flight and no velocity, as a controller whose
## velocity was clipped to zero against the face leaves it. Intent carries 10 mm a
## frame, short of the riser, so the step is found only by reaching
## min_step_forward. The sweeps step it onto the first tread; the grid walk has to
## as well.
func _case_w21_intent_alone_climbs_a_step_on_the_grid() -> void:
	const TICKS: int = 30
	var start: Vector3 = Vector3(-BODY_RADIUS - 0.015, REST_Y, 0.0)
	var intent: Vector3 = Vector3(0.6, 0.0, 0.0)
	var grid: Run = await _run(
		_flight_world,
		start,
		Vector3.ZERO,
		TICKS,
		true,
		1,
		1,
		Callable(),
		intent,
	)
	var swept: Run = await _run(
		_flight_world,
		start,
		Vector3.ZERO,
		TICKS,
		false,
		1,
		1,
		Callable(),
		intent,
	)
	_check(
		"w21 intent alone climbs a step on the grid",
		_same(grid, swept, MIN_STEP_FORWARD) and grid.ups == 1
		and swept.ups == 1 and grid.grid_ticks == TICKS,
		_describe(grid, swept),
	)


## A body standing still a centimetre short of a wall too tall to step, with
## desired_velocity pointing into it: the sweeps leave it where it is, held on the
## wall, and so does the grid walk, climbing nothing.
func _case_w22_intent_alone_into_a_wall_holds_the_body_on_it() -> void:
	const TICKS: int = 30
	var start: Vector3 = Vector3(0.8 - BODY_RADIUS - 0.01, REST_Y, 0.0)
	var intent: Vector3 = Vector3(1.5, 0.0, 0.0)
	var build: Callable = _walled_world.bind(0.0)
	var grid: Run = await _run(build, start, Vector3.ZERO, TICKS, true, 1, 1, Callable(), intent)
	var swept: Run = await _run(build, start, Vector3.ZERO, TICKS, false, 1, 1, Callable(), intent)
	_check(
		"w22 intent alone into a wall holds the body on it",
		_same(grid, swept) and grid.ups == 0 and swept.ups == 0 and grid.grid_ticks == TICKS,
		_describe(grid, swept),
	)


## A frozen RigidBody3D wall, 0.4 m thick, across the path at x = 1, on `layer`.
## Frozen, it holds still, but it is still a body that may move, which the grid
## does not bake.
func _add_mover_wall(world: Node3D, layer: int = 1) -> RigidBody3D:
	var body: RigidBody3D = RigidBody3D.new()
	body.freeze = true
	body.collision_layer = layer
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(0.4, 2.0, 8.0)
	shape_node.shape = box
	body.add_child(shape_node)
	world.add_child(body)
	body.global_position = Vector3(1.0, 1.0, 0.0)
	return body


func _mover_world() -> Node3D:
	var world: Node3D = _flat_world()
	_add_mover_wall(world)
	return world


## Bakes any grid in `world`, since a body at rest has not yet.
func _bake_grids(world: Node3D) -> void:
	for child: Node in world.get_children():
		var grid: StairsWalkGrid = child as StairsWalkGrid
		if grid != null:
			grid.bake()


## A body that may move stands in the path: the grid walk sweeps near it, and
## stops at it as the sweeps do, rather than walking through a body it never baked.
func _case_w23_a_moving_body_in_the_path_is_swept_against() -> void:
	const TICKS: int = 60
	var start: Vector3 = Vector3(-2.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0)
	var grid: Run = await _run(_mover_world, start, walk, TICKS, true)
	var swept: Run = await _run(_mover_world, start, walk, TICKS, false)
	_check(
		"w23 a moving body in the path is swept against",
		_same(grid, swept) and grid.on_wall and not grid.last_on_grid and grid.grid_ticks > 0,
		_describe(grid, swept),
	)


## Bakes, then adds the moving wall: the grid picks it up as it enters the tree.
func _add_mover_after_bake(world: Node3D) -> void:
	_bake_grids(world)
	_add_mover_wall(world)


func _case_w24_a_moving_body_added_after_the_bake_is_seen() -> void:
	const TICKS: int = 60
	var start: Vector3 = Vector3(-2.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0)
	var grid: Run = await _run(_flat_world, start, walk, TICKS, true, 1, 1, _add_mover_after_bake)
	var swept: Run = await _run(_flat_world, start, walk, TICKS, false, 1, 1, _add_mover_after_bake)
	_check(
		"w24 a moving body added after the bake is seen",
		_same(grid, swept) and grid.on_wall and not grid.last_on_grid and grid.grid_ticks > 0,
		_describe(grid, swept),
	)


func _off_mask_mover_world() -> Node3D:
	var world: Node3D = _flat_world()
	_add_mover_wall(world, 2)
	return world


## A moving body on a layer the walker does not collide with changes nothing: the
## grid walk passes it on the grid, as the sweeps pass through it.
func _case_w25_a_moving_body_off_the_mask_is_walked_past() -> void:
	const TICKS: int = 60
	var start: Vector3 = Vector3(-2.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0)
	var grid: Run = await _run(_off_mask_mover_world, start, walk, TICKS, true)
	var swept: Run = await _run(_off_mask_mover_world, start, walk, TICKS, false)
	_check(
		"w25 a moving body off the mask is walked past",
		_same(grid, swept) and grid.position.x > 0.9 and grid.grid_ticks == TICKS,
		_describe(grid, swept),
	)


## Bakes, then frees the moving wall `_mover_world` adds.
func _free_mover(world: Node3D) -> void:
	_bake_grids(world)
	var mover: RigidBody3D = null
	for child: Node in world.get_children():
		if child is RigidBody3D:
			mover = child as RigidBody3D
	if mover == null:
		push_error("_free_mover: the world has no moving wall")
		return
	mover.free()


## A moving body freed stops counting at once: the walk stays on the grid.
func _case_w26_a_moving_body_freed_no_longer_counts() -> void:
	const TICKS: int = 60
	var start: Vector3 = Vector3(-2.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0)
	var grid: Run = await _run(_mover_world, start, walk, TICKS, true, 1, 1, _free_mover)
	var swept: Run = await _run(_mover_world, start, walk, TICKS, false, 1, 1, _free_mover)
	_check(
		"w26 a moving body freed no longer counts",
		_same(grid, swept) and grid.position.x > 0.9 and grid.grid_ticks == TICKS,
		_describe(grid, swept),
	)


## Bakes, then adds an AnimatableBody3D wall 4 m to the side of the path at x = 1
## and, after DOOR_WAIT, slides it across over a third of a second, as a door
## closing just as the body reaches it.
func _close_door(world: Node3D) -> void:
	_bake_grids(world)
	var door: AnimatableBody3D = AnimatableBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(0.4, 2.0, 3.0)
	shape_node.shape = box
	door.add_child(shape_node)
	world.add_child(door)
	door.global_position = Vector3(1.0, 1.0, 4.0)
	var tween: Tween = world.create_tween()
	tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tween.tween_interval(DOOR_WAIT)
	tween.tween_property(door, ^"position:z", 0.0, 0.33)


## A door slides shut across the path while the body walks at it: the grid walk
## sees it as it comes and stops at it where the sweeps do.
func _case_w27_a_door_sliding_across_the_path_stops_the_walk() -> void:
	const TICKS: int = 60
	var start: Vector3 = Vector3(-2.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0)
	var grid: Run = await _run(_flat_world, start, walk, TICKS, true, 1, 1, _close_door)
	var swept: Run = await _run(_flat_world, start, walk, TICKS, false, 1, 1, _close_door)
	_check(
		"w27 a door sliding across the path stops the walk",
		_same(grid, swept) and grid.on_wall and grid.position.x < 0.6 and grid.grid_ticks > 0,
		_describe(grid, swept),
	)


## A loose RigidBody3D box, 0.6 m, dropped just above the floor in the path at
## x = 1, so it lands and falls asleep before the body reaches it.
func _loose_box_world() -> Node3D:
	var world: Node3D = _flat_world()
	var box_body: RigidBody3D = RigidBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(0.6, 0.6, 0.6)
	shape_node.shape = box
	box_body.add_child(shape_node)
	world.add_child(box_body)
	box_body.global_position = Vector3(1.0, 0.31, 0.0)
	return world


## A sleeping body is not read each frame, but it still counts where it lies: the
## walk stops at it as the sweeps do.
func _case_w28_a_sleeping_loose_box_in_the_path_still_stops_the_walk() -> void:
	const TICKS: int = 90
	var start: Vector3 = Vector3(-3.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0)
	var grid: Run = await _run(_loose_box_world, start, walk, TICKS, true)
	var swept: Run = await _run(_loose_box_world, start, walk, TICKS, false)
	_check(
		"w28 a sleeping loose box in the path still stops the walk",
		_same(grid, swept) and grid.on_wall and grid.position.x < 0.45 and grid.grid_ticks > 0,
		_describe(grid, swept),
	)


## Bakes, then waits for the loose box 3 m to the side of the path to fall asleep,
## freezes it static, and carries it across the path by its position, as a held
## prop is carried. A static-frozen body moved this way stays asleep under both
## engines.
func _carry_box(world: Node3D) -> void:
	_bake_grids(world)
	var box_body: RigidBody3D = null
	for child: Node in world.get_children():
		if child is RigidBody3D:
			box_body = child as RigidBody3D
	if box_body == null:
		push_error("_carry_box: the world has no loose box")
		return
	box_body.global_position = Vector3(1.0, 0.31, 3.0)
	var tween: Tween = world.create_tween()
	tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tween.tween_interval(0.8)
	tween.tween_callback(
		func() -> void:
			_carried_asleep = box_body.sleeping
			box_body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
			box_body.freeze = true,
	)
	tween.tween_property(box_body, ^"position:z", 0.0, 0.3)


## A frozen body carried while it sleeps is still read each frame: the walk stops
## at the box where it was carried to, as the sweeps do.
func _case_w29_a_sleeping_box_frozen_and_carried_into_the_path_stops_the_walk() -> void:
	const TICKS: int = 150
	var start: Vector3 = Vector3(-5.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0)
	_carried_asleep = false
	var grid: Run = await _run(_loose_box_world, start, walk, TICKS, true, 1, 1, _carry_box)
	var asleep: bool = _carried_asleep
	var swept: Run = await _run(_loose_box_world, start, walk, TICKS, false, 1, 1, _carry_box)
	_check(
		"w29 a sleeping box frozen and carried into the path stops the walk",
		asleep and _same(grid, swept) and grid.on_wall
		and grid.position.x < 0.45 and grid.grid_ticks > 0,
		"asleep when frozen %s; %s" % [asleep, _describe(grid, swept)],
	)


## Bakes, then adds the moving wall and only then places it 9 m ahead, as a
## spawner does.
func _place_mover_far(world: Node3D) -> void:
	_bake_grids(world)
	var wall: RigidBody3D = _add_mover_wall(world)
	wall.global_position = Vector3(9.0, 1.0, 0.0)


## A body is read where it was placed, not where it was added, and not grown by
## the distance between, which would reach back past the origin: the walk from
## beside the origin, away from it, stays on the grid throughout.
func _case_w30_a_body_placed_after_it_is_added_is_seen_where_it_was_placed() -> void:
	const TICKS: int = 60
	var start: Vector3 = Vector3(0.5, REST_Y, 0.0)
	var walk: Vector3 = Vector3(-3.0, 0.0, 0.0)
	var grid: Run = await _run(_flat_world, start, walk, TICKS, true, 1, 1, _place_mover_far)
	var swept: Run = await _run(_flat_world, start, walk, TICKS, false, 1, 1, _place_mover_far)
	_check(
		"w30 a body placed after it is added is seen where it was placed",
		_same(grid, swept) and grid.grid_ticks == TICKS,
		_describe(grid, swept),
	)


## Bakes, then gives the walker a frozen box of its own, as a held item, on the
## layer it collides with but excepted from its collisions.
func _hold_box(world: Node3D) -> void:
	_bake_grids(world)
	var walker: StairsBody = null
	for child: Node in world.get_children():
		if child is StairsBody:
			walker = child as StairsBody
	if walker == null:
		push_error("_hold_box: the world has no walker")
		return
	var held: RigidBody3D = RigidBody3D.new()
	held.freeze = true
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(0.2, 0.2, 0.2)
	shape_node.shape = box
	held.add_child(shape_node)
	walker.add_child(held)
	held.position = Vector3(0.0, 0.2, -0.4)
	held.add_collision_exception_with(walker)
	walker.add_collision_exception_with(held)


## A body under the walker moves with it, so it does not take the walker off the
## grid.
func _case_w31_a_body_under_the_walker_is_not_in_its_way() -> void:
	const TICKS: int = 60
	var start: Vector3 = Vector3(-3.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0)
	var grid: Run = await _run(_flat_world, start, walk, TICKS, true, 1, 1, _hold_box)
	_check(
		"w31 a body under the walker is not in its way",
		grid.grid_ticks == TICKS and grid.position.x > -0.1,
		"grid %s on grid %d/%d" % [grid.position, grid.grid_ticks, TICKS],
	)


## Bakes, then frees the moving wall `_mover_world` adds with its signals blocked,
## so it leaves without an exit signal, and a few frames on records how many
## bodies each grid still tracks in `_movers_left`.
func _free_mover_silently(world: Node3D) -> void:
	_bake_grids(world)
	_movers_left = -1
	var mover: RigidBody3D = null
	for child: Node in world.get_children():
		if child is RigidBody3D:
			mover = child as RigidBody3D
	if mover == null:
		push_error("_free_mover_silently: the world has no moving wall")
		return
	mover.set_block_signals(true)
	mover.free()
	var tween: Tween = world.create_tween()
	tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tween.tween_interval(0.1)
	tween.tween_callback(
		func() -> void:
			_movers_left = 0
			for child: Node in world.get_children():
				var grid: StairsWalkGrid = child as StairsWalkGrid
				if grid != null:
					_movers_left += grid.get_mover_count(),
	)


## A tracked body freed without an exit signal is found gone, and dropped: the
## walk stays on the grid, as it does for one freed the usual way.
func _case_w32_a_body_freed_without_an_exit_signal_no_longer_counts() -> void:
	const TICKS: int = 60
	var start: Vector3 = Vector3(-2.0, REST_Y, 0.0)
	var walk: Vector3 = Vector3(3.0, 0.0, 0.0)
	var grid: Run = await _run(_mover_world, start, walk, TICKS, true, 1, 1, _free_mover_silently)
	var left: int = _movers_left
	var swept: Run = await _run(_mover_world, start, walk, TICKS, false, 1, 1, _free_mover_silently)
	_check(
		"w32 a body freed without an exit signal no longer counts",
		left == 0 and _same(grid, swept) and grid.position.x > 0.9 and grid.grid_ticks == TICKS,
		"tracked after the free %d; %s" % [left, _describe(grid, swept)],
	)


## What one run of a scenario ended with.
class Run:
	var position: Vector3
	var on_wall: bool
	var wall_normal: Vector3
	var on_floor: bool
	var grid_ticks: int
	var ups: int
	var downs: int
	var last_on_grid: bool
