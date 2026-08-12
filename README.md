# Stairs Character

A `CharacterBody3D` subclass that walks up and down steps. It sweeps the body
itself with `body_test_motion` rather than raycasting, so the character steps on
whatever its collider would actually fit on.

Replace `move_and_slide()` with `move_and_stair_step()` and that is the feature.

This is a **hard fork** of [Andicraft/stairs-character](https://github.com/Andicraft/stairs-character).
It does not track upstream and does not send changes back. The four-phase
stepping algorithm is Andrea Jörgensen's and is unchanged in substance — every
sweep it runs, it ran there first. What the fork adds is around it, and is listed
below.

Measured on `4.6-stable`, `4.7-stable` and `4.8.dev` with a `CylinderShape3D`, and
run under **both** Godot Physics and Jolt — 58 cases, green on each. The two engines
do not agree about everything, and where they differ is worth reading before you
pick one: [Physics engines](#physics-engines).

## What this fork changes

Behaviour, all of it measured and pinned by a test case:

- **The forward leg slides** along whatever it hits and sweeps again, so a
  staircase with a wall beside it can be climbed while holding a diagonal into
  that wall. Before, the wall stole the contact and the character was pinned.
- **A minimum forward probe** (`min_step_forward`), so the check does not
  deadlock at high tick rates. Same value and same reason as Jolt's
  `mWalkStairsMinStepForward`.
- **Stepping up from a standstill** pressed against a step face, which needs the
  probe to fall back on declared intent when `move_and_slide` has zeroed the
  velocity into the face every frame.
- **Stairs that ride a moving platform** — sliding, lifts in both directions, and
  the two combined. See [Moving platforms](#moving-platforms).
- **A height-gain check** before the step is committed, Jolt's last check: a step
  that ends no higher than it started is not a step.
- **Split reaches**: `step_down_height` bounds the snap down independently of how
  far the character can climb.
- **No step down onto a landing too steep to stand on**, which is the mirror of
  the check the step *up* has always made. A commit is a placement, so without it
  a character stepping off a lip onto a steep face is set down on the face. Read
  only for flat-bottomed colliders — see [Use a cylinder collider](#use-a-cylinder-collider).
- **Optional visual step smoothing** (`smooth_node`, `step_smoothing`), which
  eases a child node rather than the body, because easing the body breaks the
  physics.
- **An optional split move** (`split_move`), horizontal then vertical.

Around the behaviour:

- Ground-state bookkeeping moved into `move_and_stair_step()`, where a subclass
  defining its own `_physics_process` cannot silently switch it off. Startup work
  hangs off `_notification` for the same reason.
- The collider margin is read from the shape you assign instead of hardcoded.
- Split `stepped_up` / `stepped_down` signals alongside the combined `stepped`.
- The two query objects are allocated once and reused, not four per character per
  frame.
- Static typing throughout, and a headless test suite the original did not have —
  58 cases, plus the benchmarks and diagnostics behind every number in this file.

## Install

Copy `addons/stairs-character/` into your project, **keeping the folder name**.
That is the whole install. `StairsCharacter` registers itself because the script
carries a `class_name`, so it is available whether or not the plugin is enabled in
**Project Settings > Plugins** — enabling it only lists the addon there with its
version and author.

The folder name matters because the class icon is referenced by absolute path and
Godot has no relative form for it. Rename the folder and the node quietly falls
back to the default icon.

The `LICENSE` inside that folder is not decoration: this is MIT-derived work and
the attribution has to travel with the code, so keep it beside the scripts.

## Use

Extend `StairsCharacter` instead of `CharacterBody3D`, assign your collision shape
to the `collider` export, and call `move_and_stair_step()` where you would have
called `move_and_slide()`:

```gdscript
extends StairsCharacter

func _physics_process(delta: float) -> void:
    velocity.y -= gravity * delta
    velocity.x = input_direction.x * speed
    velocity.z = input_direction.z * speed
    desired_velocity = Vector3(velocity.x, 0.0, velocity.z)
    move_and_stair_step()
```

`desired_velocity` is where the controller *wants* to go this frame. Setting it is
what makes stepping up from a standstill work; leave it unset and you get the
original behaviour, which stalls in that one case.

You do not need to call `super()` from `_ready` or `_physics_process`. Everything
the class needs happens inside `move_and_stair_step()` and in notification
handling, neither of which a subclass can accidentally switch off.

## Use a cylinder collider

This matters more than it sounds. A capsule's rounded bottom catches the top
corner of a step as the character is set back down and reports a contact around
52 degrees, which the `floor_max_angle` check then correctly rejects — so every
step up silently fails and the character just walks into the step. Use a
`CylinderShape3D`. The addon warns at startup if you use anything else.

The same corner contact is why the steep-landing refusal on the way **down** is
read for flat-bottomed shapes only (`CylinderShape3D` and `BoxShape3D`). Applied
to a capsule it fires on ordinary stairs: measured under Jolt on an 8-tread
0.40 m flight, 6 step downs with the carve-out and 0 without, which would have
removed a working feature from every capsule character rather than fixing
anything. Case 56 pins that, and it is the shape *class* that is tested rather
than its orientation — a cylinder laid on its rim answers flat-bottomed, because
the failure direction that matters is a character placed on a wall, not one that
loses a step down.

It is read off **every shape on the body**, not off the `collider` export, since
the sweep tests the whole body: a character with a cylinder assigned and a sphere
hung below it loses every step down on the same flight, and neither the export nor
the startup warning would see it. Case 57. Disabled shape owners are skipped, so
a spare capsule kept around for a crouch and toggled off does not quietly switch
the refusal off — case 58.

Keep the shape's margin as low as you can without snagging on edges, around
`0.001`. The addon reads the margin off the shape you assign and warns if it is
above `0.01`.

## Properties

| Property | Purpose |
|---|---|
| `collider` | The character's `CollisionShape3D`. If left unassigned, a child node named `Collider` is used, which is how older scenes were set up. |
| `step_height` | How high the character can step up, and be snapped down onto. Default `0.33`, which suits a ~2 m character - the useful part is the ratio, roughly 0.15-0.25 of character height, since the absolute value does not survive rescaling your character. |
| `step_down_height` | How far the character can be snapped back *down*, when that should differ from how far it can climb. Negative - the default - follows `step_height`, which is what every existing scene expects. Split them when up and down want different generosity: a short reach down stops a character being hauled onto every ledge it walks off, a long one keeps it glued to stairs it can only just climb. |
| `min_step_forward` | Smallest distance the forward leg of the check will probe, whatever the tick rate. Default `0.02`, the same value and the same reason as Jolt's `mWalkStairsMinStepForward`. Below this floor the check does not degrade, it stalls: see [Tick rate](#tick-rate) below. `0` removes the floor and restores the old behaviour, which exists to measure against rather than to ship. |
| `step_slide_iterations` | How many times the forward leg may slide along a contact and sweep again. Default `4`; `1` is the old single sweep, which cannot climb a staircase with a wall beside it. There is nothing to gain past a handful - each slide strictly shrinks the motion, so the leg runs out of length long before it runs out of iterations. |
| `split_move` | Move horizontally and vertically as two separate passes instead of one combined move. Off by default, because it changes how every frame resolves and not only the ones near a step. What it buys, measured: a climb keeps its speed. See [Splitting the move](#splitting-the-move) below. |
| `desired_velocity` | Where the controller *wants* to go this frame. The probe follows whichever is larger, this or actual horizontal velocity - so it takes over when `move_and_slide` has zeroed the velocity into a step face and an acceleration-based controller cannot rebuild it. The exception is backpressure: when velocity opposes intent (knockback, an explosion, a shove) velocity is trusted regardless of size, so the body is not seated forward onto a step it is being pushed away from. Any vertical component is ignored, so handing over a whole movement vector with gravity already in it is fine. Cleared for you after each call. |
| `force_stair_step` | Runs the step check even when not grounded, for cases like a wall jump that should have caught a ledge but snagged just below it. Cleared for you after each call. |
| `grounded` / `was_grounded` | Ground state as the addon sees it, which is not always `is_on_floor()` - the step logic sometimes moves the body in ways that leave `is_on_floor()` reading false. Both are refreshed at the top of `move_and_stair_step()`, before it moves anything, so `grounded` is the state as of the *start* of the current frame and `was_grounded` the frame before. Neither reports this frame's post-move state; use `is_on_floor()` for that. |
| `smooth_node` | A visual child - a camera or mesh pivot - whose local Y the addon eases after each step, so the view does not pop the instant the body snaps. Leave it unassigned for the original hard snap. See [Step smoothing](#step-smoothing) below. |
| `step_smoothing` | How fast the view catches up to the snapped body, as an exponential decay rate: higher is snappier. Time constant is `1 / step_smoothing` seconds; the default `20` settles in about 150 ms. `0` turns smoothing off while keeping `smooth_node` assigned. Only used when `smooth_node` is set. |

### Why `step_height` defaults to 0.33

The number is a compromise between two traditions, and the ratio is what
travels — scale it with your character, because the absolute value does not.

| Source | Step height | Character height | Ratio |
|---|---|---|---|
| [Quake](https://book.leveldesignbook.com/process/blockout/metrics/quake) / [Source](https://www.worldofleveldesign.com/categories/sourcesdk-authoringtools/hammer-source-player-scale-world-dimensions.php) (`sv_stepsize`) | 18 u | 72 u | 0.25 |
| [Unreal](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/UCharacterMovementComponent) `MaxStepHeight` | 45 cm | 176 cm | 0.256 |
| [Unity](https://docs.unity3d.com/Manual/class-CharacterController.html) `stepOffset` | recommends 0.1–0.4 | "2 meter sized human" | 0.05–0.20 |
| [IRC R311.7.5.1](https://codes.iccsafe.org/s/IRC2015/chapter-3-building-planning/IRC2015-Pt03-Ch03-SecR311.7.5) (real stairs) | 19.7 cm max riser | ~180 cm | 0.11 |

The FPS lineage converges on ~0.25 — deliberately generous, so characters walk
up crates and rubble rather than only stairs. Unity and actual building code sit
near 0.11–0.15, stairs only.

On Godot's usual 2 m capsule, `0.33` clears a code-maximum real stair (0.197)
with margin, lands inside Unity's recommended band, and stays under the 0.25
ratio at which a character starts silently climbing crates and low walls — a
surprising default for a library called *stairs*-character.

## Step smoothing

A step moves the body in a single frame, which reads as a pop on the camera. The
addon can hide that by easing the *visual* into place while the body still snaps
instantly - the snap is what keeps the physics correct, so it is never smoothed.

The body is the collision shape. Ease the body itself and, mid-ease, the collider
sits inside the step: `move_and_slide` depenetrates it, `is_on_floor()` reads
false, and the step check re-fires the next frame. So the body has to be at the
stepped height the moment the step resolves. What eases is a **child** - your
camera or mesh - which the addon pushes the opposite way for one frame and then
decays back, so the view holds still and then glides to meet the body.

Rig it as `body -> smooth_node -> camera`:

```
Player            (extends StairsCharacter)
└── SmoothPivot   (Node3D, assigned to smooth_node)
    └── Camera3D   (your camera; head bob, recoil, etc. live here)
```

Assign the pivot to `smooth_node` and set `step_smoothing` to taste. The addon
owns the pivot's local Y, so keep camera bob or recoil on a child of it - a write
to the pivot's own Y is overwritten every frame by the decay.

`step_smoothing` is an exponential decay rate: `1 / step_smoothing` is the time
constant, so `20` settles in ~150 ms (a Source-like feel), `8-10` floats, past
`30` is almost the raw snap. It is framerate independent, so a value feels the
same at 60 and 144 Hz. Set it to `0`, or leave `smooth_node` unassigned, and the
body snaps exactly as it did before - which is what every existing scene gets.

## Tick rate

Every distance the step check works with comes from `velocity * delta`, so the
whole check shrinks as the physics tick rate rises. Left unbounded that does not
degrade gracefully - it deadlocks. Once `move_and_slide` has parked the body one
probe length short of a step, the probe reaches the step face with nothing left
over, the forward leg moves that nothing, and the check rejects it. On the next
frame nothing has moved, so it happens again, forever: the character stands at
the foot of a step it can climb, pushing.

`min_step_forward` is the floor that prevents it, defaulting to `0.02` - the same
value, for the same reason, as Jolt's `mWalkStairsMinStepForward`. Measured
before it existed, a 3 m/s walk into a 0.2 m step stalled at 240 Hz and a 0.5 m/s
walk stalled at 240 and 480; 60 Hz cleared every speed, which is why this went
unnoticed for so long. `test/diag_tickrate.gd` walks the whole rate x speed grid
if you want to see it.

The floor applies to the **first** sweep as well as the forward leg, and that half
of it was found under Jolt. Whether the probe reaches the step face at all depends
on where the engine parks a body that has walked into one: Godot Physics rests it
flush, so even a millimetre of probe touches, while Jolt leaves a gap. Measured
(`test/diag_jolt_stall.gd`) a 0.5 m/s walk at 120 Hz came to rest 4.2 mm from a
step with a 4.17 mm probe - missing by three hundredths of a millimetre, on that
frame and every frame after. Flooring the first sweep too clears the whole grid on
both engines.

It only ever lengthens a *probe*. The body still moves as far as its velocity
carries it, except on frames whose entire reach is shorter than the floor - where
the addon seats the body itself, because `move_and_slide` cannot cover ground the
probe found beyond its own reach.

## Walls beside stairs

The forward leg of the check slides along whatever it hits and sweeps again, up
to `step_slide_iterations` times. Without that, a wall running alongside a
staircase steals the first contact from the step: the leftover motion still
points into the wall, the leg travels nothing, and a player holding a diagonal
into a banister cannot climb at all while the same walk one push away from the
wall climbs fine. `test/diag_wallhug.gd` is that comparison.

Walking head-on into a wall costs nothing extra - the motion slides to zero on
the first try and the loop breaks out - so the measured per-frame cost is
unchanged from the single-sweep version.

## Moving platforms

Stairs bolted to something that moves - a lift, a ship deck, a train carriage -
work, in every direction, and nothing is asked of your controller.

They needed two fixes for two different reasons, and the shared cause is
scheduling. The step check runs *before* `move_and_slide`, and `move_and_slide` is
what re-seats a body on a moving floor: it applies the floor's displacement as a
move of its own, before it moves the character by its velocity. So at the moment
the check runs, the body is still standing where the last frame left it while the
platform has moved on.

- **Sliding sideways.** The sweeps measured from that stale position, so the gap
  to the next step face was inflated by exactly the platform's travel - 0.0919 m
  against a 0.05 m probe at 5 m/s, so the sweep missed on that frame and on every
  frame after. The check now starts its sweeps offset by the displacement
  `move_and_slide` is about to apply.
- **Lifts.** Here the sweeps were never wrong. All four succeeded and reported a
  real step, on every frame, and the character still gained nothing: 47 step-ups
  and 47 step-downs in 60 frames. The step is committed in Y alone, with the
  horizontal owed to `move_and_slide` - so on a descending lift the platform push
  dropped the body below the lip it had just been placed on before it moved
  forward at all, and the forward move then met the step face side-on and slid
  back down. The carry now covers the vertical too, and the commit nets that part
  off again, which leaves the body one carry high - exactly where the push lands
  it on the lip.

Measured across the grid in `test/diag_platform_stairs.gd`: sliding at 0, 2, 5, 10
and 20 m/s with the walk and 2 and 10 against it; lifts up and down; both
diagonals; and boarding a platform from static ground. Every row climbs the full
flight.

Two things to know. The carry is `get_platform_velocity()`, which is what the
*last* `move_and_slide` observed, so it is exact for a platform at steady state
and one frame stale on any frame where the platform's motion changes - boarding,
stopping, accelerating, reversing. Each is a single frame the next observation
corrects. Reversing is the worst of them, and it was measured rather than left as
a worry: a lift flipping between +1 and -1 m/s every 1, 2, 5 and 20 frames climbs
the full flight at all four periods, though contact suffers - the grounded
fraction falls to 0.36 when it reverses every frame or two. Under Jolt the same
grid climbs except the every-single-frame flip, which is where an approximation
built on last frame's observation is wrong on every frame by construction; two
frames a direction is enough for it.

The other is that the carry only applies while grounded, so a `force_stair_step`
ledge catch in mid-air one frame after jumping off a platform is not offset by a
displacement nothing is about to apply.

## Splitting the move

`split_move` replaces the single `move_and_slide()` with two: a horizontal pass,
then a vertical one, with velocity reassembled from what each gave back.
[dresswithpockets' write-up](https://dresswithpockets.github.io/2025/03/19/godot-stair-stepping.html)
moves this way to fix "mis-steps" - running stairs fast enough that a combined
move ends the frame in mid-air, which reads as not grounded and switches the step
check off for the frame that most needed it.

That failure does not happen here. Measured on an eight-tread staircase
(`test/diag_faststairs.gd`), running down at 3, 8 and 14 m/s produces **zero**
airborne frames on either setting - `stair_step_down` is already catching what
the split would have caught.

What the split does buy is speed. A climb costs ground with the combined move and
costs none with the split:

| Ascending | Combined | Split | Free run |
|---|---|---|---|
| 8 m/s, 1.5 s | 11.57 m | 12.00 m | 12.00 m |
| 14 m/s, 1.5 s | 20.30 m | 21.00 m | 21.00 m |

Slopes behave the same either way. The ramp bench (`test/bench_ramp.gd`) runs both
paths over a 20 degree ramp and measures the same slope to three places:

| 20 degree ramp | Grounded | Advanced | Climbed | Slope | Cost |
|---|---|---|---|---|---|
| Combined | 1.00 | 6.49 m | 2.36 m | 0.364 | 47.9-48.8 us |
| Split | 1.00 | 6.62 m | 2.41 m | 0.364 | 61.6-62.2 us |

So the split does not climb slopes differently, it climbs them slightly further
in the same frames - the same speed retention it shows on stairs. The price is
**28% more per character per frame**, which is simply the second
`move_and_slide`.

Worth having if your character runs stairs and you want the stairs to be free,
and not worth having for the reason it was originally written. Off unless you ask
for it - run the diagnostics on your own geometry first.

Two things to know before you do. `move_and_slide` applies the floor's platform
velocity itself, before it looks at your velocity, so calling it twice would ride
a moving platform twice - a rider with no input of its own drifted 7.417 m across
a platform that travelled 7.500 m. The addon suppresses the second push by
clearing the platform layers for the vertical pass, so this is handled, but the
consequence is that `platform_on_leave` does not fire for a character that leaves
a platform during that pass. And every post-move getter -
`get_slide_collision_count()`, `get_last_slide_collision()`, `get_wall_normal()` -
describes the vertical pass only, so a wall your character scraped horizontally
is invisible to a controller that reads them after the call.

`split_move` assumes the default `up_direction`. A rotated one is caught at boot
and the flag is turned back off rather than left to move the character along an
axis `move_and_slide` disagrees is horizontal.

## Signals

| Signal | Emitted |
|---|---|
| `stepped_up` | The character was raised onto a higher surface. |
| `stepped_down` | The character was snapped down onto a lower surface. |
| `stepped` | Either of the above, right after the specific one. |

All three fire only when a step actually happened, so they are safe to hang a
footstep sound or a camera smoothing routine on.

Two things to know. `stepped_up` fires *before* `move_and_slide` runs for the
frame and `stepped_down` fires *after* it, because that is where each piece of
work happens - so a handler that writes to `velocity` affects this frame from one
and the next frame from the other. And handlers run inside
`move_and_stair_step()`, so they must not call back into it.

If you are coming from the C++ port, these were called `on_stair_step`,
`on_stair_step_up` and `on_stair_step_down` there.

## Upgrading

`_step_height` is now `step_height`. Scenes that stored the old name still load -
the value is applied and you get a warning telling you to re-save. That
compatibility shim will go away in a future breaking release.

`temp_step_height` is gone. It was documented as a one-frame override but was
never read, so it never did anything; assign `step_height` directly for a frame
to get the behaviour it advertised.

## Physics engines

The suite runs under **both** engines and passes 58 of 58 on each, on `4.6-stable`,
`4.7-stable` and `4.8.dev`. Godot Physics is the project default; Jolt is a
first-class target rather than an afterthought, because it is where Godot is
heading. Jolt costs more per frame: 55.9 us per character against 47.9 for the same
combined move.

Running under both turned up two differences, and neither was cosmetic.

**Where a blocked body comes to rest.** Godot Physics parks a character flush
against a face it has walked into; Jolt leaves it a few millimetres off - measured
4.2 mm. That stalled a slow walk at a high tick rate outright, because the first
sweep was shorter than the gap and so never reached the step at all. Fixed by
flooring the first sweep; see [Tick rate](#tick-rate), pinned by case 52.

**What a ramp's leading corner is.** Where a slab emerges from the ground the
character touches a corner rather than a face, and a corner has no normal. Godot
Physics answers with the ramp face - 30.0 degrees on a 30 degree ramp, walkable -
and Jolt with 49.5, four over the default limit. It scales with tilt (25.6 degrees
on a 10 degree ramp, 47.6 on a 20, 76.4 on a 40), so every ramp past about 20
degrees is affected on one frame of the approach. Neither engine is wrong.

The consequence is not the stray `stepped_up` it looks like. Under Jolt that single
stair step is **how a character gets onto a slope at all**: a plain
`CharacterBody3D` with no stair stepping climbs this ramp to y 2.543 under Godot
Physics and never gets onto it under Jolt, stopping dead at the corner, because
Jolt's solver reads it as too steep to walk exactly as its motion query does.
Suppressing the step so the two engines would agree was tried, and it stranded a
character at the foot of a ramp.

So the walkable bail's premise - that a walkable surface is `move_and_slide`'s job
- is an engine-dependent claim, and case 19 had been written against the engine
where it holds. It now asserts what is true on both: the character climbs the ramp,
and does not stair-step its way up it. Zero steps is what Godot Physics does, one is
what an ambiguous corner costs under Jolt, and removing the walkable bail produces
77 - so a ceiling of one keeps the case's teeth.

`test/diag_jolt_ramp.gd` carries all of it, including the four mitigations that were
tried and what each turned out to be worth.

Reproduce either by dropping an `override.cfg` beside `project.godot`:

```ini
[physics]

3d/physics_engine="Jolt Physics"
```

Upstream recommended Jolt. This fork has not been tuned for it, and the gap above
is the whole of what is known.

## Tests

    test/run.sh

Runs a headless suite of 58 cases that builds each world procedurally and exits
with the number of failures. Nothing in `test/` ships with the addon; it is all
development material for this repository.

Point `GODOT` at a binary if the default in `run.sh` does not exist on your
machine: `GODOT=/path/to/godot test/run.sh`.

Alongside it are the benchmarks and diagnostics behind the addon's performance
and correctness choices. Each one records its measured numbers in its header, so
the reasoning survives without rerunning anything:

| File | Question it answers |
|---|---|
| `bench_sweep.gd`, `bench_alloc.gd` | What a sweep costs, and how many each situation runs |
| `bench_frame.gd`, `diag_state.gd` | The honest per-character-per-frame cost, driving real frames — and what state those characters are actually in |
| `bench_micro.gd` | The work *around* the sweeps — and why none of it is worth rewriting |
| `bench_primitive.gd`, `diag_castmotion.gd`, `diag_multishape.gd` | Whether a cheaper sweep primitive could replace `body_test_motion` (it cannot) |
| `bench_ramp.gd` | What the walkable-surface bail is worth, and what the split move costs on a slope |
| `diag_wallhug.gd`, `diag_tickrate.gd` | The two ways the forward leg used to stall outright - a wall beside the stairs, and a high tick rate |
| `diag_faststairs.gd`, `diag_platform.gd` | What the split move buys on stairs, and that it rides a moving platform once rather than twice |
| `diag_platform_stairs.gd`, `diag_platform_probe.gd`, `diag_lift_probe.gd` | Stairs bolted to a moving platform - the grid of speeds and directions, and the two frame-level interrogations that found why a sliding one and a descending one each failed for different reasons |
| `diag_reuse.gd`, `diag_slide.gd`, `diag_latency.gd` | Whether the check can be cached or deferred (it cannot, without costing stairs) |
| `diag_phase2.gd`, `diag_sink_robustness.gd`, `diag_steep_landing.gd` | Whether the four-phase algorithm can lose a phase (it cannot) |
| `diag_steepedge.gd` | Whether Jolt's steep-edge retry is worth carrying here (it is not - the record of a feature written, measured and removed) |
| `diag_jolt_ramp.gd`, `diag_jolt_stall.gd` | The two places the engines disagree - what each answers for the same ramp corner, and where each parks a body that has walked into a step face |

Several of these exist to record a **negative** result. If you are about to try
one of these optimisations, read the relevant header first — the measurement is
already there, and in most cases the idea is faster and wrong.

## Credits

The stepping algorithm is [Andrea Jörgensen's](https://github.com/Andicraft/stairs-character),
MIT licensed. This fork is maintained at
[plaught-armor/stairs-character](https://github.com/plaught-armor/stairs-character).

MIT either way, and Andrea's copyright notice stays in `LICENSE` — it is a
condition of the licence, not a courtesy, and it travels with any copy you make
of this code.
