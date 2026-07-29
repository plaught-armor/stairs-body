extends Node3D

## Does the walkable-surface bail actually fire, and what does it save?
##
##     godot --headless --path <repo root> res://test/bench_ramp.tscn
##
## The source comment on that bail says a character walking up a ramp would
## otherwise "run the full check and succeed on nearly every frame, stair
## stepping its way up a slope", and the bench_sweep header prices the ramp at
## 1.00 sweeps against 4.00 before the bail. Neither had been reproduced.
##
## An earlier attempt at this scenario placed the character at a hand-computed
## height that turned out to be *inside* the ramp, so every sweep missed and the
## bail never got the chance to fire. This one drops the character from above the
## surface and lets gravity settle it, then asserts it is genuinely on the slope -
## grounded, climbing, and moving - before believing any count taken from it.
##
## Both claims hold. Counted on 4.8.dev by temporarily adding static counters to
## stairs_character.gd and a switch that skips the bail, 100 characters over 150
## frames on a 20 degree slope:
##
##                          sweeps  steps/frame  advanced  us/character/frame
##     bail on (shipping)     1.00         0.00    6.49 m               50.50
##     bail off               3.86         0.87    7.35 m               63.86
##
## The bail fires on 0.953 of frames - the other 0.047 are frames where the
## forward sweep finds nothing at all - and 0.954 x 4 + 0.046 x 1 = 3.86 is
## where the header's 4.00 comes from. It is worth 21% of the frame cost here.
##
## The behavioural half matters more than the cost half. Without the bail the
## character covers 7.35 m of ground where walking covers 6.49 m in the same
## frames, at an identical measured slope: it is stair stepping up the ramp
## rather than walking up it, and arrives 13% early. A character that climbs
## slopes faster than it crosses flat ground is the bug the bail prevents.
##
## The bench now runs twice, once per move path, because split_move's docs claimed
## a slope cost nobody had measured. Three runs, identical to the centimetre:
##
##                grounded  advanced  climbed  slope  us/char/frame
##     combined       1.00    6.49 m   2.36 m  0.364      48.2-48.8
##     split          1.00    6.62 m   2.41 m  0.364      61.6-62.2
##
## The slope is the same number to three places, so the split does not climb
## differently - it climbs the same ramp slightly further in the same frames, the
## same 2% speed retention it shows on stairs, and stays grounded throughout. What
## it costs is 28%, and that is per character per frame on a slope rather than
## anything about slopes specifically: it is the second move_and_slide.

const CHARACTERS: int = 100
const FRAMES: int = 150
const SETTLE: int = 90
const WALK: float = 3.0
const LANE: float = 3.0
const GRAVITY: float = 9.8
const DELTA: float = 1.0 / 60.0

## Shallower than the default floor_max_angle of 45 degrees, so the slope is
## walkable and move_and_slide is expected to carry the character up it.
const RAMP_DEGREES: float = 20.0
const RAMP_LENGTH: float = 40.0
const RAMP_THICKNESS: float = 1.0

var _ramp: Array[StairsCharacter] = []
var _world: Node3D


func _ready() -> void:
	call_deferred(&"_run")


func _box(size: Vector3, centre: Vector3, tilt_deg: float = 0.0) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	_world.add_child(body)
	body.global_position = centre
	body.rotation.z = deg_to_rad(tilt_deg)


func _character(at: Vector3) -> StairsCharacter:
	var c: StairsCharacter = StairsCharacter.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var cyl: CylinderShape3D = CylinderShape3D.new()
	cyl.radius = 0.3
	cyl.height = 1.8
	cyl.margin = 0.001
	shape_node.shape = cyl
	c.add_child(shape_node)
	c.collider = shape_node
	_world.add_child(c)
	c.global_position = at
	return c


func _drive(group: Array[StairsCharacter], walk: Vector3) -> void:
	for c: StairsCharacter in group:
		c.velocity.x = walk.x
		c.velocity.z = walk.z
		c.velocity.y -= GRAVITY * DELTA
		c.desired_velocity = walk
		c.move_and_stair_step()


func _run() -> void:
	print("ramp %.0f degrees, tan = %.3f" % [RAMP_DEGREES, tan(deg_to_rad(RAMP_DEGREES))])
	await _measure(false)
	await _measure(true)
	get_tree().quit()


## One full run of the bench. `split` picks which move path the characters use,
## so the two rows are the same slope, the same settle and the same frame count -
## only the move differs.
func _measure(split: bool) -> void:
	_world = Node3D.new()
	add_child(_world)
	_ramp.clear()

	var span: float = CHARACTERS * LANE + 20.0
	# A shallow ramp rising in +x. Positive rotation about z lifts the +x end.
	_box(Vector3(RAMP_LENGTH, RAMP_THICKNESS, span), Vector3(0.0, 0.0, 0.0), RAMP_DEGREES)

	# Drop each character from well above the slope and let it settle onto it,
	# rather than trusting a hand-computed surface height.
	var start_x: float = -RAMP_LENGTH * 0.35
	var drop_y: float = start_x * tan(deg_to_rad(RAMP_DEGREES)) + 3.0
	for i: int in CHARACTERS:
		var c: StairsCharacter = _character(Vector3(start_x, drop_y, (i - CHARACTERS * 0.5) * LANE))
		c.split_move = split
		_ramp.append(c)

	var walk: Vector3 = Vector3(WALK, 0.0, 0.0)
	for _i: int in SETTLE:
		_drive(_ramp, walk)
		await get_tree().physics_frame

	# Prove the characters are on the slope before trusting anything measured.
	var probe: StairsCharacter = _ramp[CHARACTERS / 2]
	var y_before: float = probe.global_position.y
	var x_before: float = probe.global_position.x
	var grounded_frames: int = 0
	var total: int = 0

	var elapsed: int = 0
	for _i: int in FRAMES:
		var started: int = Time.get_ticks_usec()
		_drive(_ramp, walk)
		elapsed += Time.get_ticks_usec() - started
		for c: StairsCharacter in _ramp:
			total += 1
			if c.grounded:
				grounded_frames += 1
		await get_tree().physics_frame

	var climbed: float = probe.global_position.y - y_before
	var advanced: float = probe.global_position.x - x_before
	var slope: float = climbed / advanced if absf(advanced) > 0.001 else 0.0
	print(
		(
			"%-8s grounded %.2f  advanced %.2f m  climbed %.2f m  slope %.3f  %.2f us/char/frame"
			% [
				"split" if split else "combined",
				float(grounded_frames) / total,
				advanced,
				climbed,
				slope,
				float(elapsed) / (FRAMES * CHARACTERS),
			]
		)
	)

	_world.queue_free()
	await get_tree().process_frame
