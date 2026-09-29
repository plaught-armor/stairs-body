# Stairs Body

`StairsBody` is a character body for Godot 4 that walks up and down stairs. You
give it a velocity each physics frame, and it moves, slides along walls, climbs
steps and steps down off ledges. It checks the body's real collider shape
against the level, so a character steps onto whatever it would actually fit on.

It is a C++ GDExtension, cheap enough to run on whole crowds, not just on one
player. It also has two extras for crowds:

- **Crowd separation** keeps a crowd from walking through itself without paying
  for physics collisions between its members.
- **The walk grid** lets bodies far from the camera walk a level built from boxes
  with no physics queries at all.

Tested headless under both Godot Physics and Jolt: 102 checks, green on each.

How it all works, what it costs and why it is built this way is in
[docs/technical.md](docs/technical.md). This README sticks to what each part does
and how to use it.

- [Install](#install)
- [Quick start](#quick-start)
- [How it differs from CharacterBody3D](#how-it-differs-from-characterbody3d)
- [API reference](#api-reference)
- [Guides](#guides)
- [Known limits](#known-limits)
- [Tests](#tests)
- [Credits](#credits)

## Install

Copy `addons/stairs-body/` into your project, **keeping the folder name**. The
library and icon paths inside are absolute `res://` paths. The class is registered
as soon as the project loads. Enabling the plugin in **Project Settings > Plugins**
is optional; it only lists the addon there.

Keep `LICENSE` beside the addon. This is MIT-derived work, and the attribution has
to travel with the code.

Prebuilt binaries cover **Linux x86_64** only for now, which includes Steam Deck.
For any other platform, build them:

```sh
git clone --recursive https://github.com/plaught-armor/stairs-body
cd stairs-body
scons target=template_debug     # loaded by the editor and debug exports
scons target=template_release   # loaded by release exports
```

This needs SCons 4, Python 3.8 and a C++17 compiler. The extension is built
against the Godot 4.6 API and loads on 4.6 and newer. Godot only picks up an
extension after it has scanned the project, so open the project in the editor, or
run `godot --headless --import`, after the first build.

## Quick start

Make a script that extends `StairsBody`, give the node a `CollisionShape3D` child,
and call `move_and_stair_step()` every physics frame:

```gdscript
extends StairsBody

func _physics_process(delta: float) -> void:
    velocity.y -= gravity * delta
    velocity.x = input_direction.x * speed
    velocity.z = input_direction.z * speed
    desired_velocity = Vector3(velocity.x, 0.0, velocity.z)
    move_and_stair_step()
```

Use a `CylinderShape3D` for the collider, with its margin around `0.001`. That is
the shape the tests use. A capsule works walking down stairs, but its rounded
bottom is not tested climbing them ([why](docs/technical.md#collider-shape)).

## How it differs from CharacterBody3D

`StairsBody` is built on `AnimatableBody3D`, **not** `CharacterBody3D`, and runs
its own move loop. It keeps the familiar names where it can (`velocity`,
`is_on_floor()`, `get_wall_normal()` and so on), but:

- there is no `move_and_slide()`; call `move_and_stair_step()` instead;
- there is no `up_direction`: up is always +Y;
- there is no `floor_snap_length`: the body always follows the floor down as far
  as `step_down_height`;
- in place of the slide-collision list there is a simpler
  [contact list](#contacts).

What the getters report is where the last `move_and_stair_step()` left the body.
If you move the body any other way (setting `global_position`, reparenting it),
call `move_and_stair_step()` before reading them, or they still describe the old
spot.

A body standing still costs almost nothing: once it has no velocity and nothing
around it changes, each move is a single cheap check. Velocity has to be exactly
zero for that, so snap a velocity that decays toward zero.
[More on resting bodies](docs/technical.md#resting-bodies).

## API reference

The same descriptions are in the editor's built-in help for both classes.

### StairsBody

#### Moving

| Method | What it does |
|---|---|
| `move_and_stair_step(time_scale = 1.0)` | Moves the body by `velocity` for one physics frame: slides, climbs and steps down. Call it once per physics frame. `time_scale` moves it for that many frames at once, for a body you only move every few frames; see [Moving far bodies less often](#moving-far-bodies-less-often). |

#### What to set each frame

| Property | Default | What it does |
|---|---|---|
| `velocity` | zero | How fast the body moves, in m/s. After each move it is cut to what the body could actually do: a wall stops the part pushing into it, and the floor stops the part going down. |
| `desired_velocity` | zero | Where the player or AI wants to go this frame, ignoring what blocked it. Set it to the input direction times speed. It lets a body pressed against a step climb it even when the step has stopped its velocity. Cleared after each move. [Details](docs/technical.md#intent-and-the-step-probe). |
| `force_stair_step` | `false` | Lets the body step up this frame even though it is in the air, for things like catching a ledge. Cleared after each move. |

#### Tuning

| Property | Default | What it does |
|---|---|---|
| `step_height` | `0.33` | The tallest step the body climbs, in metres. Scale it with your character: [why 0.33](docs/technical.md#why-step_height-defaults-to-033). |
| `step_down_height` | `-1` | How far the body follows the floor down, onto a lower step or down a slope, before it counts as falling. Negative means "the same as `step_height`". |
| `min_step_forward` | `0.02` | How far ahead the body always looks for a step, however slow it walks or however high the physics tick rate. Rarely needs changing; [why it exists](docs/technical.md#tick-rate-and-min_step_forward). |
| `floor_max_angle` | 45° | The steepest slope that counts as floor. Anything steeper is a wall. |
| `max_slides` | `4` | How many times one move may slide along a wall and carry on. |
| `step_slide_iterations` | `4` | The same for the forward part of a step, so a wall beside the stairs does not block the climb. |
| `safe_margin` | `0.001` | How close the body comes to what it hits, in metres. |
| `step_ignore_layers` | none | Layers the body never steps onto, though it still bumps into them. Use it for things that are too small or move on their own, such as other characters. It also makes a crowd much cheaper: see [Crowds](#crowds). |
| `crowd_layers` | none | Layers of other `StairsBody` nodes this one keeps apart from without physics collisions. See [Crowds](#crowds). |
| `walk_grid` | none | A `StairsWalkGrid` to walk on without physics queries. Set it or clear it at any time. See [Walk grid](#walk-grid). |

#### After a move

| Method | What it tells you |
|---|---|
| `is_on_floor()` | Whether the body is standing on something. |
| `is_on_wall()` | Whether it is against something too steep to stand on. |
| `is_on_ceiling()` | Whether its head hit something. |
| `get_floor_normal()` | Which way the floor it stands on faces. |
| `get_wall_normal()` | Which way the wall it is against faces. |
| `get_platform_velocity()` | How fast the moving floor under it is going. |
| `is_on_walk_grid()` | Whether the last move was made on the walk grid rather than by physics queries. |

#### Contacts

What the last move touched, as a list you read by index:

| Method | Returns |
|---|---|
| `get_contact_count()` | How many contacts there are. |
| `get_contact_collider(index)` | The object touched. |
| `get_contact_collider_id(index)` | Its instance id, cheaper when you only compare ids. |
| `get_contact_normal(index)` | Which way the touched surface faces, toward the body. |
| `get_contact_position(index)` | Where the touch happened. |

The list is emptied at the start of every move. It lists what the body touched on
its way and where it ended up, including the floor and crowd neighbours. The same
object can appear more than once. Reading it allocates nothing.
[What goes into the list](docs/technical.md#the-contact-list).

#### Signals

| Signal | When |
|---|---|
| `stepped_up(rise)` | The body climbed onto something higher. |
| `stepped_down(drop)` | The body stepped down onto something lower. |
| `stepped(delta)` | Either of those, right after it. `delta` is positive up, negative down. |

Heights are in metres, and are how far the body actually moved. Walking down a
smooth slope is not a step and emits nothing. The signals fire inside
`move_and_stair_step()`, so a handler must not call it again. Use them to
[smooth the camera](#smoothing-the-camera-on-steps).
[Exact rules](docs/technical.md#signals).

#### Static

| Method | What it does |
|---|---|
| `StairsBody.is_step_surface(body_rid, ignore_layers = 0)` | Whether a body could be stepped onto: true for static things, moving platforms and frozen rigid bodies, false for loose rigid bodies and anything on `ignore_layers`. Stepping onto a loose crate would let physics launch the character ([why](docs/technical.md#what-it-will-not-step-onto)). |

### StairsWalkGrid

A `Node3D` that indexes the box-shaped static geometry of a level so bodies can
walk on it without physics queries. See [Walk grid](#walk-grid).

| Member | What it does |
|---|---|
| `collision_mask` | Which layers of static geometry it indexes. Changing it leaves the index out of date until the next `bake()`. |
| `bake()` | Builds the index from the level as it is now. Runs by itself on first use; call it while the level loads to keep that cost off a frame, and again after changing the level. |
| `is_baked()` | Whether it has been built. |
| `is_stale()` | Whether the level has changed since the last `bake()` in a way the index has not followed. It checks every indexed body, so call it after editing the level, not every frame. |
| `get_box_count()` | How many boxes are indexed. |
| `get_unknown_count()` | How many static shapes it left out, so bodies near them use physics instead. |
| `get_mover_count()` | How many bodies that could move it watches, so bodies near them use physics instead. |

## Guides

### Smoothing the camera on steps

A step moves the body up or down in a single frame, which looks like a pop on the
camera. The class leaves the smoothing to you, so it can suit your game (holding
while a foot is in the air, feeding foot IK, and so on).

Smooth a **child** node, never the body itself: the body has to be at the new
height straight away, or its collider sits inside the step. Put a pivot between
the body and the camera:

```
Player            (extends StairsBody)
└── StepPivot     (Node3D, step_ease.gd)
    └── Camera3D  (head bob, recoil, etc. live here)
```

When the body steps, push the pivot the other way by the same height, so the
camera holds still, then let the push fade back to zero. `test/step_ease.gd` does
that, and the test suite runs it:

```gdscript
extends Node3D

## Step easing for a StairsBody, the recipe the README quotes. The suite runs this
## file, so the recipe stays true.
##
## Attach to a Node3D that is a direct child of the StairsBody and parents the
## camera or mesh: body, then this pivot, then camera. A step moves the body in
## one physics frame; this pushes the pivot the opposite way by the same height,
## so the view holds still, and then decays the push back to zero.
##
## This script owns the pivot's local Y. Keep camera bob or recoil on a child.

## Decay rate of the push, per second. The time constant is 1 / rate, so 20
## settles in about 150 ms, 8 to 10 feels floaty, and past 30 is almost the raw snap.
@export var rate: float = 20.0

## The current push, in metres. Read it, never write it.
var offset: float = 0.0
var _rest_y: float = 0.0
var _body: StairsBody


func _ready() -> void:
	_body = get_parent() as StairsBody
	if _body == null:
		push_error("step_ease.gd must be a direct child of a StairsBody.")
		set_process(false)
		return
	_rest_y = position.y
	_body.stepped.connect(_on_stepped)


## Render rate, which is what the eye sees. exp(-rate * dt) closes the same share
## of the distance per second at any frame rate.
func _process(delta: float) -> void:
	offset *= exp(-rate * delta)
	position.y = _rest_y + offset


## Clamped to one step's reach, so a burst of steps cannot stack into a lurch.
func _on_stepped(delta: float) -> void:
	var down_reach: float = _body.step_down_height
	if down_reach < 0.0:
		down_reach = _body.step_height
	var reach: float = maxf(_body.step_height, down_reach)
	offset = clampf(offset - delta, -reach, reach)
```

`rate` sets how fast the camera catches up: `20` takes about 150 ms, lower feels
floatier, and past 30 is almost the raw pop.

### Moving far bodies less often

A body far from the camera can be moved every other frame, or every fourth, to
save its cost. Skip the call on the frames in between. On the frames it moves,
pass how many frames it covers as `time_scale`, and leave `velocity` and
`desired_velocity` at their normal values:

```gdscript
if Engine.get_physics_frames() % 2 == 0:
    velocity.y -= gravity * delta * 2.0   # your own gravity covers two frames too
    move_and_stair_step(2.0)
```

Don't double `velocity` instead: stepping, moving floors and crowd separation
would then still work frame by frame.
[Details](docs/technical.md#time-scale).

### Crowds

A crowd of `StairsBody` nodes that collide with each other is expensive, because
every physics query has to push each body out of the neighbours it touches. Crowd
separation keeps them apart by simple geometry instead. Put the crowd on its own
layer, leave that layer out of each member's `collision_mask`, and set
`crowd_layers` to it:

```gdscript
member.collision_layer = CROWD
member.collision_mask = WORLD           # not CROWD
member.crowd_layers = CROWD
member.step_ignore_layers = CROWD
```

Members then stop when they walk into each other, push apart when they overlap,
and list each other as contacts. In a pile of 96 this is three to four times
cheaper than collision.

What to expect:

- Members never stand on each other. A pile stays one deep.
- Each member is treated as a rounded shape lying flat, sized from its collider.
  Box-shaped members can overlap slightly at the corners.
- Members may overlap by up to 5 mm before they are pushed apart, so a still crowd
  can come to rest.
- Only members see each other this way. Anything else, such as a player walking
  through the crowd, collides with them as usual.
- The member's size is measured once. Changing its collider later is not seen.

[How separation works and what it costs](docs/technical.md#crowd-separation).

### Walk grid

Bodies far from the player don't need exact physics. `StairsWalkGrid` lets them
walk a level built from boxes (floors, stair treads, walls, platforms) by simple
geometry, with no physics queries at all, which is 10 to 30 times cheaper per body.
Wherever the grid can't answer, a body falls back to its normal physics moves by
itself.

**Set it up.** Add a `StairsWalkGrid` under the level's root, beside its static
geometry. It indexes the `StaticBody3D` nodes under its parent. Bake it while the
level loads:

```gdscript
@onready var _grid: StairsWalkGrid = $StairsWalkGrid

func _ready() -> void:
    _grid.bake()
```

**Things that move.** The grid watches every physics body under the same parent
that could move: `AnimatableBody3D` doors and platforms, `RigidBody3D` props,
`CharacterBody3D` characters. A body on the grid that comes near one uses its
normal physics moves until it is clear. So keep the player, doors and props under
the level's root with the grid, and bodies can stay on it everywhere.

It measures each body's shapes once; call `bake()` after changing them. It does
not watch other `StairsBody` nodes (give the crowd `crowd_layers`, below), bodies
under a `StairsBody` such as a held item, which move with it, or anything outside
the grid's parent. Take a body that has to meet something outside off the grid
near it:

```gdscript
func _physics_process(delta: float) -> void:
    var near: bool = global_position.distance_squared_to(_outsider.global_position) < 4.0 * 4.0
    walk_grid = null if near else _grid
    velocity.y -= gravity * delta
    move_and_stair_step()
```

Switching is free: set `walk_grid` at any time, even every frame.
`is_on_walk_grid()` tells you which way the last move went.

**Give a crowd on the grid `crowd_layers`.** Bodies on the grid don't collide with
each other at all, so without [crowd separation](#crowds) they walk through each
other.

**Levels it can walk.** The grid indexes only boxes that stand upright (turned
around the vertical only). Everything else static is left to physics, and bodies
use their normal moves near it:

- other shapes: trimeshes, heightmaps, cylinders, spheres, `WorldBoundaryShape3D`;
- boxes tilted off the vertical, such as a ramp;
- static bodies on layers outside the grid's `collision_mask`;
- conveyors, which carry bodies along.

So a level built from boxes walks on the grid almost everywhere. A level whose
ground is one imported mesh does not: bodies there always use physics.

**Changing the level.** Freeing a box the grid indexed removes it from the grid
straight away, and bodies that could move are watched from the moment they are
added until they are freed. Anything else (adding static bodies, moving them,
changing their layers or the grid's `collision_mask`) is not seen until you call
`bake()` again. Adding a static body and changing the mask print a warning;
`is_stale()` tells you whether a re-bake is needed.

[How the grid works and what it costs](docs/technical.md#walk-grid).

### Running under Jolt

Both Godot Physics and Jolt are supported and tested, and Jolt is the cheaper of
the two here. To run under Jolt, drop an `override.cfg` beside `project.godot`:

```ini
[physics]

3d/physics_engine="Jolt Physics"
```

[Jolt behaviours the class works around](docs/technical.md#physics-engines).

## Known limits

- Up is always +Y.
- Only tested with cylinder colliders when climbing.
- Crowd separation and the walk grid run on the main thread only.
- Crowd members never stand on each other.
- A body on the walk grid does not see other `StairsBody` nodes, except through
  crowd separation, or bodies outside the grid's parent.
- Prebuilt binaries are Linux x86_64 only.

## Tests

    test/run.sh

Runs the three headless test suites and exits with the number of failures. Build
the extension with `scons` first. If Godot is not where `run.sh` expects it, point
`GODOT` at your binary: `GODOT=/path/to/godot test/run.sh`. Nothing in `test/`
ships with the addon. [What the suites and benchmarks
cover](docs/technical.md#tests-and-benchmarks).

## Credits

This is a **hard fork** of [Andicraft/stairs-character](https://github.com/Andicraft/stairs-character).
It does not track upstream and does not send changes back. The stepping algorithm
(up, forward, down, commit) is [Andrea Jörgensen's](https://github.com/Andicraft/stairs-character),
MIT licensed, and `StairsBody` still follows it. This fork is maintained at
[plaught-armor/stairs-body](https://github.com/plaught-armor/stairs-body).

MIT either way, and Andrea's copyright notice stays in `LICENSE`. It is a
condition of the licence, not a courtesy, and it travels with any copy you make of
this code.
