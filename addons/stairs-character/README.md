# Stairs Character

A `CharacterBody3D` that walks up and down steps. It sweeps the body itself with
`body_test_motion` rather than raycasting, so it steps on whatever the collider
would actually fit on.

## Install

Copy `addons/stairs-character/` into your project, **keeping the folder name**.
That is the whole install — the `StairsCharacter` class registers itself because
it has a `class_name`, whether or not the plugin is enabled in **Project Settings
> Plugins**. Enabling it only makes the addon show up in that list.

The folder name matters because the class icon is referenced by absolute path
(`@icon("res://addons/stairs-character/...")`) and Godot has no relative form for
it. Rename the folder and the node quietly falls back to the default icon —
harmless, but confusing, and nothing warns you.

## Use

Extend `StairsCharacter` instead of `CharacterBody3D`, assign the `collider`
export to your `CollisionShape3D`, and call `move_and_stair_step()` where you
would have called `move_and_slide()`:

```gdscript
extends StairsCharacter

func _physics_process(delta: float) -> void:
    velocity.y -= gravity * delta
    velocity.x = input_direction.x * speed
    velocity.z = input_direction.z * speed
    desired_velocity = Vector3(velocity.x, 0.0, velocity.z)
    move_and_stair_step()
```

Two things that are not optional:

- **Use a `CylinderShape3D`.** A capsule's rounded bottom catches the top corner
  of a step and reports a steep contact normal, which `floor_max_angle` then
  rejects — every step-up silently fails. The addon warns at startup if the shape
  is anything else.
- **Keep the collider's margin low**, around `0.001`. The addon warns above
  `0.01`. A large margin snags on step edges.

Full property, signal and upgrade documentation is in the [repository
README](https://github.com/plaught-armor/stairs-character).

## License and provenance

MIT — see `LICENSE` in this directory.

This addon is a hard fork of [Andicraft/stairs-character](https://github.com/Andicraft/stairs-character),
maintained at [plaught-armor/stairs-character](https://github.com/plaught-armor/stairs-character).
The stepping algorithm is Andrea Jörgensen's original work; the fork rewrote what
surrounds it. Both copyright lines in `LICENSE` are required — keep that file
beside these scripts in anything you ship.
