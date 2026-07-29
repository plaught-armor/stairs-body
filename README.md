# Stairs Character

A simple to use class that enables your CharacterBody3D to handle stairs properly.

Mainly tested with the Jolt physics engine and cylinder colliders, not guaranteed to work well with anything else - but try it!

## Install

Copy `addons/stairs-character/` into your project. That is the whole install.
`StairsCharacter` registers itself because the script carries a `class_name`, so
it is available whether or not the plugin is enabled in **Project Settings >
Plugins** — enabling it only lists the addon there with its version and author.

The `LICENSE` inside that folder is not decoration: this is MIT-derived work and
the attribution has to travel with the code, so keep it beside the scripts.

## Usage instructions:

1. Make your character controller extend `StairsCharacter` instead of `CharacterBody3D`.
2. Assign your character's collision shape to the `collider` property.
3. Every frame, set `desired_velocity` to the desired direction of movement.
4. Call `move_and_stair_step()` instead of calling `move_and_slide()`.
5. Done!

You do not need to call `super()` from `_ready` or `_physics_process`. Everything
the class needs to do happens inside `move_and_stair_step()` and in notification
handling, both of which a subclass cannot accidentally switch off by defining its
own version.

## Use a cylinder collider

This matters more than it sounds. A capsule's rounded bottom catches the top
corner of a step as the character is set back down and reports a contact around
52 degrees, which the `floor_max_angle` check then correctly rejects - so every
step up silently fails and the character just walks into the step. Use a
`CylinderShape3D`. The addon warns at startup if you use anything else.

Keep the shape's margin as low as you can without snagging on edges. The addon
reads the margin off the shape you assign and warns if it is above 0.01.

## Properties

| Property | Purpose |
|---|---|
| `collider` | The character's `CollisionShape3D`. If left unassigned, a child node named `Collider` is used, which is how older scenes were set up. |
| `step_height` | How high the character can step up, and be snapped down onto. Default `0.33`, which suits a ~2 m character - the useful part is the ratio, roughly 0.15-0.25 of character height, since the absolute value does not survive rescaling your character. |
| `step_down_height` | How far the character can be snapped back *down*, when that should differ from how far it can climb. Negative - the default - follows `step_height`, which is what every existing scene expects. Split them when up and down want different generosity: a short reach down stops a character being hauled onto every ledge it walks off, a long one keeps it glued to stairs it can only just climb. |
| `min_step_forward` | Smallest distance the forward leg of the check will probe, whatever the tick rate. Default `0.02`, the same value and the same reason as Jolt's `mWalkStairsMinStepForward`. Below this floor the check does not degrade, it stalls: see [Tick rate](#tick-rate) below. `0` removes the floor and restores the old behaviour, which exists to measure against rather than to ship. |
| `step_slide_iterations` | How many times the forward leg may slide along a contact and sweep again. Default `4`; `1` is the old single sweep, which cannot climb a staircase with a wall beside it. There is nothing to gain past a handful - each slide strictly shrinks the motion, so the leg runs out of length long before it runs out of iterations. |
| `split_move` | Move horizontally and vertically as two separate passes instead of one combined move. Off by default, because it changes how every frame resolves and not only the ones near a step. What it buys, measured: a climb keeps its speed. See [Splitting the move](#splitting-the-move) below. |
| `desired_velocity` | Where the controller *wants* to go this frame. Only used when actual horizontal velocity is zero, which is what makes stepping up from a standstill work. Any vertical component is ignored, so handing over a whole movement vector with gravity already in it is fine. Cleared for you after each call. |
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

Slopes behave the same either way. The ramp bench (`test/bench_ramp.gd`) now runs
both paths over a 20 degree ramp and measures the same slope to three places:

| 20 degree ramp | Grounded | Advanced | Climbed | Slope | Cost |
|---|---|---|---|---|---|
| Combined | 1.00 | 6.49 m | 2.36 m | 0.364 | 48.2-48.8 us |
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

## Tests

    test/run.sh

Runs a headless suite of 47 cases that builds each world procedurally and exits
with the number of failures. Nothing in `test/` ships with the addon; it is all
development material for this repository.

Point `GODOT` at a binary if the default in `run.sh` does not exist on your
machine: `GODOT=/path/to/godot test/run.sh`. The suite passes identically on
`4.6-stable`, `4.7-stable` and `4.8.dev`.

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
| `diag_reuse.gd`, `diag_slide.gd`, `diag_latency.gd` | Whether the check can be cached or deferred (it cannot, without costing stairs) |
| `diag_phase2.gd`, `diag_sink_robustness.gd`, `diag_steep_landing.gd` | Whether the four-phase algorithm can lose a phase (it cannot) |
| `diag_steepedge.gd` | Whether Jolt's steep-edge retry is worth carrying here (it is not - the record of a feature written, measured and removed) |

Several of these exist to record a **negative** result. If you are about to try
one of these optimisations, read the relevant header first — the measurement is
already there, and in most cases the idea is faster and wrong.

## Credits

This is a **hard fork**, maintained by [plaught-armor](https://github.com/plaught-armor/stairs-character).
It does not track upstream and does not send changes back.

The four-phase stepping algorithm is [Andrea Jörgensen's](https://github.com/Andicraft/stairs-character),
MIT licensed, and is unchanged in substance — every sweep it runs, it ran there
first. What the fork adds is around it: bookkeeping moved somewhere a subclass
cannot switch off, the collider margin read from the shape instead of hardcoded,
split step signals, optional visual step smoothing, reused query objects, static
typing throughout, and a headless test suite the original did not have.

MIT either way, and Andrea's copyright notice stays in LICENSE — it is a
condition of the licence, not a courtesy, and it travels with any copy you make
of this code.
