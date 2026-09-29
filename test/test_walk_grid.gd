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

var _passed: int = 0
var _failed: int = 0


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
