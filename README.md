# Stairs Body

`StairsBody` is a character body for Godot 4 that walks up and down steps. It
sweeps the body itself with `body_test_motion` rather than raycasting, so a
character steps onto whatever its collider would actually fit on.

It is a C++ GDExtension built on `AnimatableBody3D`, with its own move loop. It
is cheap enough to run on crowds, not just on one player.

This is a **hard fork** of [Andicraft/stairs-character](https://github.com/Andicraft/stairs-character).
It does not track upstream and does not send changes back. The four-phase stepping
algorithm (up, forward, down, commit) is Andrea Jörgensen's, and `StairsBody`
still follows it.

The test suites run headless under **both** Godot Physics and Jolt, 58 cases,
green on each.

## Why a move loop of its own

This fork started as `StairsCharacter`, a GDScript `CharacterBody3D` that ran the
step check around `move_and_slide`. It was never released, and it has been
replaced by `StairsBody`. Three findings drove that.

**The frame paid twice.** `move_and_slide` sweeps the body, and the step check
swept it again to find the step. Tracy put about 50 µs per character per frame
on it under Godot Physics. Nearly all of that was engine C++: the slide and the
sweeps. The GDScript itself took about 1.4 µs, so porting that class to C++ could
not have helped much. The only way to get cheaper was to run fewer queries.

**Fewer queries need a loop of their own.** `StairsBody` replaces
`move_and_slide` with its own slide loop and makes the step check part of it:

- The main sweep doubles as the step probe.
- One zero-motion test finds floor contact and catches tunnelling.
- Gravity is not swept into the floor while the body stands on it; the floor
  probe keeps it down.
- A wall that refused a step is remembered, so pressing into it costs nothing
  extra.

| Situation | Queries per frame |
|---|---|
| Walking on flat ground | 2 (the move sweep, the contact test) |
| Pressed into a wall | 2 (the refused step is cached) |
| Intent off the motion | +1 (a sweep along intent that only looks for a step) |
| Climbing a step | 5 (move, up, forward, down, contact test) |
| Leaving a floor | +1 (the floor probe, only where contact is lost) |
| On a moving platform | +1 (the carry, as its own sweep) |

**Then C++, because it is meant for crowds.** With the slide in the class, the
class's own code became a real share of the frame: 16-34% under Tracy. The target
is crowds of characters within an 8 ms frame on Steam Deck, where every
microsecond is multiplied by the crowd size. `StairsBody` was written in GDScript
first, then ported to C++, and the port took off another 9-20%.

Measured with `test/bench_frame.gd`, 200 characters, in microseconds per character
per frame:

| | StairsCharacter | StairsBody |
|---|---|---|
| Godot Physics, flat ground | 31.6 | 14.0 |
| Godot Physics, pressed into a wall | 66.6 | 38.1 |
| Jolt, flat ground | 16.5 | 6.8 |
| Jolt, pressed into a wall | 42.0 | 19.6 |

Most of what is left is the engine's own sweeps. Both GDScript classes, and the
benchmarks and diagnostics written for `StairsCharacter`, are kept at the git tag
`gdscript-final`.

## Install

Copy `addons/stairs-character/` into your project, **keeping the folder name**:
the library and icon paths are absolute `res://` paths. The `.gdextension` file
registers `StairsBody` when the project loads. Enabling the plugin in **Project
Settings > Plugins** is optional; it only lists the addon there.

Keep `LICENSE` beside the addon. This is MIT-derived work, and the attribution has
to travel with the code.

Prebuilt binaries cover **Linux x86_64** only for now, which includes Steam Deck.
For any other platform, build them:

```sh
git clone --recursive https://github.com/plaught-armor/stairs-character
cd stairs-character
scons target=template_debug     # loaded by the editor and debug exports
scons target=template_release   # loaded by release exports
```

This needs SCons 4, Python 3.8 and a C++17 compiler. The extension is built
against the Godot 4.6 API and loads on 4.6 and newer. Godot only picks up an
extension after it has scanned the project, so open the project in the editor, or
run `godot --headless --import`, after the first build.

## Use

Extend `StairsBody`, give it a `CollisionShape3D` child, and call
`move_and_stair_step()` every physics frame:

```gdscript
extends StairsBody

func _physics_process(delta: float) -> void:
    velocity.y -= gravity * delta
    velocity.x = input_direction.x * speed
    velocity.z = input_direction.z * speed
    desired_velocity = Vector3(velocity.x, 0.0, velocity.z)
    move_and_stair_step()
```

`StairsBody` is **not** a `CharacterBody3D`. It keeps the familiar names where it
can: `velocity`, `is_on_floor()`, `is_on_wall()`, `is_on_ceiling()`,
`get_floor_normal()`, `get_wall_normal()` and `get_platform_velocity()`. There is
no `move_and_slide()` and no `up_direction`: world up is +Y. In place of the
slide-collision list there is a [contact list](#contacts). There is also no `floor_snap_length`, because the floor probe does that job,
reaching `step_down_height`.

Those getters and the contact list describe where the last `move_and_stair_step()`
left the body, and only a move updates them. After moving the body any other way
(setting `global_position`, reparenting it, carrying it without moves), call
`move_and_stair_step()` before reading them, or they still report the old spot.

`desired_velocity` is where the controller wants to go this frame. It lets the body
step up from a standstill while pressed against a step face, where velocity has
been clipped to zero, and climb a step that intent points at but this frame's
motion does not.

Use a `CylinderShape3D` with its margin around `0.001`. Every test case uses that
shape. A rounded bottom meets a tread's corner before its face, and the floor
probe reads such a contact as support on the way down, but the suites do not pin
climbing with one.

## Properties

| Property | Default | Purpose |
|---|---|---|
| `step_height` | `0.33` | Highest step the body climbs. See [below](#why-step_height-defaults-to-033). |
| `step_down_height` | `-1` | How far the floor probe reaches down to keep the body on the ground or step it down. Negative follows `step_height`. |
| `min_step_forward` | `0.02` | Shortest distance a step probe looks ahead, whatever the tick rate. See [Tick rate](#tick-rate). |
| `step_slide_iterations` | `4` | Slides for the forward leg of a step, so a wall beside the stairs does not block the climb. |
| `floor_max_angle` | 45° | Steepest surface that counts as floor. |
| `max_slides` | `4` | Slides for the main move. On the floor, a wall met within 15° of head-on stops the slide, as `CharacterBody3D`'s default `wall_min_slide_angle` does. |
| `safe_margin` | `0.001` | Collision margin for every sweep. |
| `step_ignore_layers` | none | Layers a step is never placed onto, though the body still collides with them: bodies too small or too self-driving to be a stair. A floor on them holds the body up but never carries it as a platform. |
| `velocity` | zero | Velocity in m/s. After each move it is clipped against what the body hit, and its downward part is zeroed on the floor. |
| `desired_velocity` | zero | Horizontal intent for this frame. Cleared after each move. |
| `force_stair_step` | `false` | Allow a step this frame while airborne, such as a ledge catch. Cleared after each move. |

The same descriptions are in the editor's built-in help for the class.

### Why `step_height` defaults to 0.33

The number is a compromise between two traditions. The ratio is what carries
over: scale it with your character, because the absolute value does not.

| Source | Step height | Character height | Ratio |
|---|---|---|---|
| [Quake](https://book.leveldesignbook.com/process/blockout/metrics/quake) / [Source](https://www.worldofleveldesign.com/categories/sourcesdk-authoringtools/hammer-source-player-scale-world-dimensions.php) (`sv_stepsize`) | 18 u | 72 u | 0.25 |
| [Unreal](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent) `MaxStepHeight` | 45 cm | 176 cm | 0.256 |
| [Unity](https://docs.unity3d.com/Manual/class-CharacterController.html) `stepOffset` | recommends 0.1–0.4 | "2 meter sized human" | 0.05–0.20 |
| [IRC R311.7.5.1](https://codes.iccsafe.org/s/IRC2015/chapter-3-building-planning/IRC2015-Pt03-Ch03-SecR311.7.5) (real stairs) | 19.7 cm max riser | ~180 cm | 0.11 |

The FPS lineage converges on about 0.25. That is deliberately generous, so
characters walk up crates and rubble, not only stairs. Unity and real building
codes sit near 0.11–0.15, stairs only.

For a 2 m character, `0.33` clears a code-maximum real stair (0.197) with margin,
sits inside Unity's recommended band, and stays under the 0.25 ratio at which a
character starts silently climbing crates and low walls.

## What it will not step onto

A step is placed only onto something the physics server is not simulating: static
geometry, kinematic platforms and frozen rigid bodies. Placing the body on a loose
rigid body leaves the solver to push the two apart, and the solver moves the only
thing that can move. Measured under Jolt, a 0.45 x 0.3 x 0.45 m crate lifted the
body 1.085 m and threw it at 5.6 m/s. The same rule is exposed as
`StairsBody.is_step_surface(rid, ignore_layers)` for your own checks.

## Step smoothing

A step moves the body in one physics frame, which reads as a pop on the camera.
The class does not hide that itself: the step signals carry the height moved, and
the easing is yours, so it can do what your game needs, such as holding while a
foot is in the air or feeding foot IK.

Ease a **child**, never the body. The body has to be at the stepped height the
moment the step resolves, or the collider sits inside the step. Rig it as
`body -> pivot -> camera`, and push the pivot the opposite way by each step's
height, then decay the push back to zero:

```
Player            (extends StairsBody)
└── StepPivot     (Node3D, step_ease.gd)
    └── Camera3D  (head bob, recoil, etc. live here)
```

`test/step_ease.gd` is a complete version, and the test suite runs it:

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

`rate` is an exponential decay rate: `1 / rate` is the time constant, so `20`
settles in about 150 ms. The decay runs at render rate because easing is visual.
The clamp stops a burst of steps from stacking into a lurch. There is no teleport
guard, because the signals only ever report a step, never a teleport or a shove.

## Tick rate

Every distance the step check works with comes from `velocity * delta`, so the
check shrinks as the physics tick rate rises. Without a floor, it does not degrade
gracefully: it deadlocks. A body parked just short of a step face sends a probe
that reaches the face with nothing left over, the forward leg moves that nothing,
and the step is refused, on every frame after.

`min_step_forward` is that floor, `0.02` by default: the same value, for the same
reason, as Jolt's `mWalkStairsMinStepForward`. It only lengthens the probe. The
body still moves only as far as its velocity carries it. It matters more under
Jolt, which parks a blocked body about 4.2 mm off the face where Godot Physics
parks it flush.

## Signals

| Signal | Emitted |
|---|---|
| `stepped_up(rise)` | The body was raised onto a higher surface. |
| `stepped_down(drop)` | The floor probe set the body down onto a lower surface. |
| `stepped(delta)` | Either of the above, right after the specific one. |

The heights are in metres and are how far the body actually moved, not how far it
was allowed to reach. `rise` and `drop` are positive; `delta` is signed, positive
up. A move emits at most one step, so a move that steps emits `stepped` and exactly
one of the other two. Keeping contact with the floor while walking down a slope is
not a step and emits nothing.

All three fire inside `move_and_stair_step()`, after the move is final, so a
handler must not call back into it. Build your own [step smoothing](#step-smoothing)
on them.

## Contacts

`get_contact_count()` and, per index, `get_contact_collider()`,
`get_contact_collider_id()`, `get_contact_normal()` and `get_contact_position()`
list what the last `move_and_stair_step()` touched. The getters are flat so
reading them allocates nothing, and `get_contact_collider_id()` skips the object
lookup for code that only compares ids.

The list holds contacts on the path the body took: each slide sweep, the sweeps of
a step it committed, a moving floor's carry, and the floor probe when it set the
body down. It also holds the resting contacts of the check after the move, floor
included, so a body leaning on something without moving still lists it. A step the
body tried and refused lists none of its sweeps. The list is cleared at the start
of every move. A collider can appear more than once, and the order carries no
meaning.

## Physics engines

Godot Physics is the project default. Jolt is a first-class target, because it is
where Godot is heading, and it is also the cheaper engine here: see the table
above. Two Jolt behaviours needed handling, and a test pins each:

- **Dropped contacts.** Jolt's `body_test_motion` ignores contacts that do not
  oppose the motion. Just past a ledge edge, a sweep can then report no hit and
  full travel after passing into the floor below. `StairsBody` checks for that
  after every move, and when it finds the body embedded it redoes the move with
  every sweep verified by a shape cast.
- **Rounded edges.** Jolt rounds box edges by their margin. A flat-bottomed body
  walking down treads meets that curve with a steep normal, and it went airborne
  until the floor probe learned to shift off the curve and probe again.

To run under Jolt, drop an `override.cfg` beside `project.godot`:

```ini
[physics]

3d/physics_engine="Jolt Physics"
```

## Tests

    test/run.sh

Runs two headless suites and exits with the total number of failures:

- `test/test_stairs.gd`, 43 checks. They began as `StairsCharacter`'s suite and
  kept its case numbers, so the gaps are cases that tested that class's own API.
- `test/test_stairs_body.gd`, 20 checks for machinery the first suite does not
  reach: the tunnel guard, the refusal cache, the loose-step rule, the Jolt edge
  handling and the contact list.

Each builds its worlds procedurally. Build the extension with `scons` first;
`run.sh` stops if the library is missing. Point `GODOT` at a binary if the defaults
in `run.sh` do not exist on your machine: `GODOT=/path/to/godot test/run.sh`.

Nothing in `test/` ships with the addon. `bench_frame.gd` measures the per-frame
cost above, and `bench_primitive.gd` measures what each physics query costs by
itself.

## Credits

The stepping algorithm is [Andrea Jörgensen's](https://github.com/Andicraft/stairs-character),
MIT licensed. This fork is maintained at
[plaught-armor/stairs-character](https://github.com/plaught-armor/stairs-character).

MIT either way, and Andrea's copyright notice stays in `LICENSE`. It is a
condition of the licence, not a courtesy, and it travels with any copy you make of
this code.
