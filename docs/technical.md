# StairsBody: technical notes

The [README](../README.md) says what each part of the API does and how to use it.
This document says how it works, what it costs and why it is built that way. The
sections follow the README's order, and each README section links to its
counterpart here.

- [Why a move loop of its own](#why-a-move-loop-of-its-own)
- [What a move queries](#what-a-move-queries)
- [Resting bodies](#resting-bodies)
- [Intent and the step probe](#intent-and-the-step-probe)
- [Collider shape](#collider-shape)
- [Step rules](#step-rules)
- [Tick rate and `min_step_forward`](#tick-rate-and-min_step_forward)
- [Time scale](#time-scale)
- [Signals](#signals)
- [The contact list](#the-contact-list)
- [Crowd separation](#crowd-separation)
- [Walk grid](#walk-grid)
- [Physics engines](#physics-engines)
- [Tests and benchmarks](#tests-and-benchmarks)

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
`move_and_slide` with its own slide loop and makes the step check part of it. See
[What a move queries](#what-a-move-queries).

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
| Jolt, pressed into a wall | 42.0 | 19.2 |

Both GDScript classes, and the benchmarks and diagnostics written for
`StairsCharacter`, are kept at the git tag `gdscript-final`.

## What a move queries

`move_and_stair_step()` runs one slide loop of `body_test_motion` sweeps, with the
step check folded into it:

- The main sweep doubles as the step probe. When it meets a steep face, the step
  is tried from there in four phases, Andrea Jörgensen's algorithm: up by
  `step_height`, forward, down, and commit.
- One zero-motion test after the move finds floor contact and catches tunnelling.
  A grounded body on a static floor whose move met nothing keeps that test's floor
  for the next centimetre of travel (`SETTLE_REACH`), checking only that nothing
  moving touches it. Walking slowly off a ledge, it can overhang the edge by up to
  that centimetre more before it drops.
- Gravity is not swept into the floor while the body stands on it; the floor
  probe keeps it down, reaching `step_down_height`.
- A wall that refused a step is remembered, so pressing into it costs nothing
  extra.
- On the floor, a wall met within 15° of head-on stops the slide, as
  `CharacterBody3D`'s default `wall_min_slide_angle` does.

| Situation | Queries per frame |
|---|---|
| Walking on flat ground | 2 (the move sweep, the contact test; within 1 cm of the last contact test on a static floor, a shape query in its place) |
| Standing still on a static floor | 1 shape query once at rest (see [Resting bodies](#resting-bodies)) |
| Pressed into a wall | 2 (the refused step is cached) |
| Intent off the motion | +1 (a sweep along intent that only looks for a step), only standing still or against a face intent pushes into |
| Climbing a step | 5 (move, up, forward, down, contact test) |
| Leaving a floor | +1 (the floor probe, only where contact is lost) |
| On a moving platform | +1 (the carry, as its own sweep) |
| Standing on a body on `step_ignore_layers` | +1 (the contact test again, with the whole mask) |
| Pressed into a body on `step_ignore_layers` | 3 (move, a sweep past it at floor height, contact test) |

Most of what is left is the engine's own sweeps. In a crowd pressed together that
collides, every sweep also pays to push out of the neighbours the body overlaps.
With the crowd's own layer in `step_ignore_layers`, the checks that only look for
steps and floor skip that. A neighbour the move meets is not tried as a step
either, unless something stands behind it at floor height. `test/bench_pile.gd`, 96
box-shaped bodies pressed into a pile and colliding with each other, runs at about
32 µs per body under Jolt and 48 under Godot Physics. [Crowd
separation](#crowd-separation) takes that to 8.9 and 12.2.

## Resting bodies

A body at rest skips its checks. With no velocity and no `desired_velocity`, on a
static floor that carries it nowhere, it makes one cheap shape query per move in
place of them, while neither it nor its floor has moved and nothing that could
move into it touches it. The getters keep the last move's answers.

It checks again when any of these happens:

- it is given velocity or intent, or is moved;
- its floor moves or is freed;
- something that is not static touches it;
- its own collider changes: a shape resized, swapped, moved or switched off, as a
  crouch does.

Two kinds of toucher are passed over, since neither can move into it: a
`StairsBody` that collides with it, which stops at its surface, and a crowd
neighbour. So a still body in a pile of `StairsBody` nodes stays at rest while
others press on it, and does not list them.

A body that starts inside something, such as a spawn point set into the floor,
only rests once it is out. A floor that stops colliding without moving, or a
`StairsBody` teleported into the body, is not seen until the body moves or is
moved. Velocity has to be exactly zero, so snap one that decays toward zero.

The same bodies standing still apart (`bench_pile.gd -- --idle`) cost 2.4 µs each
under Jolt and 2.6 under Godot Physics, the caller's own script included, against
3.7 and 7.2 before a body at rest skipped its contact test.

## Intent and the step probe

`velocity` moves the body; `desired_velocity` only tells the step probe where the
controller wants to go. It matters in two cases:

- **Standing still against a step face.** Velocity has been clipped to zero by
  the face, so a probe along velocity finds nothing. The probe runs along intent
  instead and climbs the step.
- **Intent points at a step that this frame's motion does not.** After a move
  that ended against a steep face, a step that intent pushes into is still
  found, though this frame's motion runs elsewhere.

That second sweep along intent only runs where a step can be: standing still, or
when the last move ended against a steep face that intent pushes into. This is
Jolt's `CanWalkStairs` rule. Motion turned by anything else, such as crowd
neighbours, costs no extra sweep. The probe only looks for a step: without one,
the body moves no further than its velocity carries it.

## Collider shape

Use a `CylinderShape3D` with its margin around `0.001`. Nearly every test case
uses that shape. A rounded bottom meets a tread's corner before its face, and the
floor probe reads such a contact as support on the way down; the suites pin a
capsule walking down, but not climbing.

## Step rules

### What it will not step onto

A step is placed only onto something the physics server is not simulating: static
geometry, kinematic platforms and frozen rigid bodies. Placing the body on a loose
rigid body leaves the solver to push the two apart, and the solver moves the only
thing that can move. Measured under Jolt, a 0.45 x 0.3 x 0.45 m crate lifted the
body 1.085 m and threw it at 5.6 m/s. `StairsBody.is_step_surface(rid,
ignore_layers)` exposes the same rule.

Bodies on `step_ignore_layers` are never stepped onto, though the body still
collides with them. A floor on them holds the body up but never carries it as a
platform.

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

## Tick rate and `min_step_forward`

Every distance the step check works with comes from `velocity * delta`, so the
check shrinks as the physics tick rate rises. Without a floor, it does not degrade
gracefully: it deadlocks. A body parked just short of a step face sends a probe
that reaches the face with nothing left over, the forward leg moves that nothing,
and the step is refused, on every frame after.

`min_step_forward` is that floor, `0.02` by default: the same value, for the same
reason, as Jolt's `mWalkStairsMinStepForward`. It only lengthens the probe. The
body still moves only as far as its velocity carries it, except that a step up
under Godot Physics can carry it up to `min_step_forward` further. It matters
more under Jolt, which parks a blocked body about 4.2 mm off the face where Godot
Physics parks it flush.

## Time scale

`move_and_stair_step(time_scale)` covers `time_scale` frames' worth of time in one
move. The step probe, a moving floor's carry and the floor it keeps all follow the
stretched frame. Crowd separation reaches as far as the body walks, and a push the
crowd pass gives it on a frame it skips is kept for its next move.

Scaling `velocity` instead gets the slide right but not those: the crowd pass
reads the unscaled velocity and lists neighbours a frame late, and a moving floor
carries the body half as far.

## Signals

The heights are in metres and are how far the body actually moved, not how far it
was allowed to reach. `drop` is never more than the whole move's descent: a move
that ends higher than it started is no step down (see [Rounded
edges](#physics-engines)). A move emits at most one step, so a move that steps
emits `stepped` and exactly one of `stepped_up` and `stepped_down`. Keeping contact
with the floor while walking down a slope is not a step and emits nothing.

All three fire inside `move_and_stair_step()`, after the move is final, so a
handler must not call back into it. They only ever report a step, never a
teleport or a shove, which is why the README's step-easing recipe needs no
teleport guard.

## The contact list

The list holds contacts on the path the body took:

- each slide sweep;
- the sweeps of a step it committed;
- a moving floor's carry;
- the floor probe, when it set the body down;
- the resting contacts of the check after the move, floor included, so a body
  leaning on something without moving still lists it;
- crowd neighbours touched (see [Crowd separation](#crowd-separation)).

The check after the move skips bodies on `step_ignore_layers` unless the body is
standing on one: in a crowd pressed together, pushing out of every neighbour is
most of what it costs, and the slide already lists the neighbours the body moves
into. A step the body tried and refused lists none of its sweeps.

The list is cleared at the start of every move. A collider can appear more than
once, and the order carries no meaning. The getters are flat, one call per field
and index, so reading them allocates nothing.

## Crowd separation

In a crowd pressed together, most of each move is the engine pushing the body out
of the neighbours it touches, inside every sweep. Crowd separation takes the crowd
out of the sweeps: members keep apart by geometry, as DetourCrowd and
position-based crowds do.

**Footprint.** Each member's footprint is a capsule lying flat, measured once from
its shapes' bounds.

**Once per physics frame**, before the first member moves:

1. Every member is read once into a snapshot: footprint, layers and space, so
   nothing after this calls the engine.
2. Pairs that are crowd to each other and could touch this frame are found through
   a hash grid and kept as each member's neighbour list. Each member's reach
   includes how far it may walk this frame, at last frame's speed and time scale,
   so two closing on each other are listed before they meet.
3. Every pair that overlaps by more than the slop, 5 mm, is pushed back to
   touching, each taking half, over up to four Jacobi passes. Pairs further apart
   than both footprints reach are rejected on squared distance before the segment
   test, as DetourCrowd does.
4. A member takes its push as part of its own next move, so the push is swept
   against the world with the move and never shoves the member into a wall. A
   member not moved that frame keeps its push for its next move.

**In each move**, the member's own motion is kept out of its neighbours by
projecting it out of each in turn, so a member walking into one stops at it, as a
sweep would stop it. A member wedged between neighbours, whose move can be kept
out of one only by pushing it into another, has its own motion cut to a half, a
quarter and then none until it fits, and counts the neighbours it was wedged
against as touched. Without the cut, a long move, such as one stretched by
`time_scale`, ended inside them: at a time scale of 4 a pile of 96 overlapped by
35 mm on average, against 6.5 mm now at any time scale.

Most neighbours are nowhere near touching, and the exact capsule gap is the
costly test, so each neighbour keeps the last gap measured to it and the offset
it was measured at. Moving the body by some distance changes the gap by at most
that distance, so a known gap less the distance moved since bounds the gap now;
when that bound clears what the test asks by 0.1 mm, the exact test is skipped.
In the moving pile on the walk grid this cut the cost of a body by about a
tenth, with every position the same to the last bit.

Neighbours are read from the snapshot, which each member brings up to date after
its move, so no move asks the engine where its neighbours are. A member moved or
turned by other code during the frame, after its own move, is seen as its move
left it until the next frame.

Neighbours touched are listed as contacts, with the other member as collider and a
horizontal normal pointing back at this body, and velocity is clipped against
them.

**Cost.** `test/bench_pile.gd -- --crowd`, 96 box-shaped bodies pressed into a
pile, costs 12.2 µs per body on Godot Physics and 8.9 on Jolt, against 47 and 32
with collision. Of that, the separation itself is under 3 µs; the rest is the
sweeps against the floor. The same bodies standing apart and still cost what they
cost without it.

**Trade-offs:**

- Members never stand on each other. A pile stays one deep.
- Footprints may overlap by up to the 5 mm slop, and separation leaves that alone,
  as Box2D's contact solver does. Pushed back to touching every frame, a still pile
  was nudged forever and its members almost never rested; with the slop, about two
  thirds of still members in a pile of 96 rest.
- A box's corners stick out of the capsule, so box-shaped members can overlap
  corner to corner, by up to about 40% of their width: 8-12 mm on average and
  about 25 mm at worst in that pile of 60 mm wide bodies.
- Only members see each other this way. Anything else on the layer, and any body
  that keeps the layer in its mask, collides with members as usual.
- Moving or resizing a member's shapes after it first moves is not seen: the
  footprint is measured once.
- Main thread only.

## Walk grid

Shipped games walk their crowds on baked navigation data and hand an agent to
physics only when it is shoved or falls, as Unreal's navmesh walking mode does.
`StairsWalkGrid` does that for levels built from boxes.

**The index.** The grid bakes the `StaticBody3D` boxes under its parent that are
turned only about the vertical, on its `collision_mask`, into 2 m bins. Every other
static shape becomes a region the grid does not answer for. Exact box edges stand
in for a height grid: there is no cell quantisation, and one index serves every
body size. A level too large to index, past 16 million bins, bakes nothing, and
bodies sweep.

**A move on the grid:**

- samples the path at most half a footprint radius apart, then bisects to the last
  clear point, so no wall is passed over;
- slides along boxes taller than `step_height`, stopping `safe_margin` short, up
  to `max_slides` times, and stops against one met within 15° of head-on;
- stands on the highest box top under its footprint that is no higher than
  `step_height` up, and steps down within the step-down reach;
- with no motion of its own and a `desired_velocity`, looks for a step along
  intent at least `min_step_forward` ahead, as the sweeps' probe does, and moves
  only if the floor there is higher;
- runs crowd separation, emits the signals and fills the floor, wall and contact
  getters as a swept move does.

A move is made by sweeps instead, and the body returns to the grid once it stands
on a baked box again, when:

| The body | because |
|---|---|
| is not on a floor, or is rising | a fall or a jump is physics |
| stands on a floor the grid did not bake | a conveyor, a moving platform, another shape |
| would drop further than the step-down reach | it falls, by sweeps |
| would step up under a ceiling too low for it | the sweeps refuse that step |
| is near a static shape the grid left out | the grid cannot answer there |
| is more than 5 mm from the grid's floor | it is not standing where the grid says |

**Keeping up with the level.** A baked body that leaves the tree drops out of the
index at once: each baked body's `tree_exiting` is watched. Anything else leaves
the index stale until `bake()` runs again: a static body added under the grid's
parent, a baked body moved or given other layers, or a change to the grid's
`collision_mask`. Adding a static body and changing the mask each print a warning.
`is_stale()` catches all of them by comparing every baked body's transform and
layers with what was baked, so it costs a pass over the baked bodies.

**Differences from the sweeps:**

- The footprint is the crowd footprint, a capsule lying flat. A box-shaped body's
  corners stick out of it and can overlap a wall slightly on the grid.
- A step up under Godot Physics carries a body up to `min_step_forward` past where
  its velocity takes it; on the grid a moving body goes only as far as its
  velocity takes it.
- Nothing that moves is seen, other `StairsBody` nodes included.
- Main thread only.

**Cost.** `test/bench_frame.gd -- --grid`, in microseconds per character per
frame:

| | Grid | Godot Physics | Jolt |
|---|---|---|---|
| walking, flat ground | 0.6 | 15.6 | 6.5 |
| pressed into a tall wall | 1.3 | 41 | 19 |
| climbing a flight | 1.0 | 18.4 | 12.1 |

In the pile of 96 (`bench_pile.gd -- --crowd --grid`) a body costs 4.0 µs on Godot
Physics and 4.1 on Jolt, against 12.2 and 8.9 by sweeps; the grid's own work is
about 0.3 µs of that, and crowd separation most of the rest.

## Physics engines

Godot Physics is the project default. Jolt is a first-class target, because it is
where Godot is heading, and it is also the cheaper engine here. Two Jolt
behaviours needed handling, and a test pins each:

- **Dropped contacts.** Jolt's `body_test_motion` ignores contacts that do not
  oppose the motion. Just past a ledge edge, a sweep can then report no hit and
  full travel after passing into the floor below. `StairsBody` checks for that
  after every move, and when it finds the body embedded it redoes the move with
  every sweep verified by a shape cast.
- **Rounded edges.** Jolt rounds box edges by their margin. A flat-bottomed body
  walking down treads meets that curve with a steep normal, and it went airborne
  until the floor probe learned to shift off the curve and probe again. Climbing,
  a step can land with only the rim over the nosing; the next move follows the
  curve up and the probe sets it back down, which is why `stepped_down` never
  reports more than the move's net descent. Measured, a 0.27 m cylinder running
  up 0.25 m treads rose 30 mm and was probed down 25 mm in one move.

Jolt also rests a blocked body about 4.2 mm off the face it met, where Godot
Physics rests it flush; see [Tick rate](#tick-rate-and-min_step_forward).

## Tests and benchmarks

`test/run.sh` runs three headless suites and exits with the total number of
failures:

- `test/test_stairs.gd`, 43 checks. They began as `StairsCharacter`'s suite and
  kept its case numbers, so the gaps are cases that tested that class's own API.
- `test/test_stairs_body.gd`, 37 checks for machinery the first suite does not
  reach: the tunnel guard, the refusal cache, the loose-step rule, the Jolt edge
  handling, `step_ignore_layers`, the contact list and crowd separation.
- `test/test_walk_grid.gd`, 22 checks that run each scenario on a walk grid and by
  sweeps, and compare where the two end.

Each builds its worlds procedurally, and all pass under both Godot Physics and
Jolt.

The benchmarks:

- `bench_frame.gd` measures the per-frame cost of one character in several
  situations (`-- --grid` on a walk grid);
- `bench_pile.gd` measures a crowd pressed together (`-- --crowd`, `-- --grid`,
  `-- --idle`, `-- --every N` for bodies moved every Nth frame, and `-- --settle`
  for a pile that has stopped);
- `bench_primitive.gd` measures what each physics query costs by itself.
