# Stairs Character

A simple to use class that enables your CharacterBody3D to handle stairs properly.

Mainly tested with the Jolt physics engine and cylinder colliders, not guaranteed to work well with anything else - but try it!

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
| `desired_velocity` | Where the controller *wants* to go this frame. Only used when actual horizontal velocity is zero, which is what makes stepping up from a standstill work. Cleared for you after each call. |
| `force_stair_step` | Runs the step check even when not grounded, for cases like a wall jump that should have caught a ledge but snagged just below it. Cleared for you after each call. |
| `grounded` / `was_grounded` | Ground state as the addon sees it, which is not always `is_on_floor()` - the step logic sometimes moves the body in ways that leave `is_on_floor()` reading false. Refreshed inside `move_and_stair_step()`, so read them after the call rather than before. |

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

Runs a headless suite that builds each world procedurally and exits with the
number of failures. `test/bench_alloc.gd` and `test/bench_sweep.gd` are the
benchmarks behind the performance choices in the addon, and their comments record
what was measured.

## Credits

Originally by [Andrea Jörgensen](https://github.com/Andicraft/stairs-character),
MIT licensed. See LICENSE.
