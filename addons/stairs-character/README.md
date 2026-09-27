# Stairs Character

`StairsBody` is a character body that walks up and down steps. It sweeps the body
itself with `body_test_motion` rather than raycasting, so a character steps onto
whatever its collider would actually fit on. It is a C++ GDExtension built on
`AnimatableBody3D`, with its own move loop, and is cheap enough for crowds.

## Install

Copy `addons/stairs-character/` into your project, **keeping the folder name**:
the library and icon paths are absolute `res://` paths. Enabling the plugin in
**Project Settings > Plugins** is optional; it only lists the addon there.

The library for your platform has to be in `bin/`. Prebuilt binaries cover Linux
x86_64, which includes Steam Deck. For anything else, build from the
[repository](https://github.com/plaught-armor/stairs-character) with `scons`. The
extension loads on Godot 4.6 and newer.

## Use

```gdscript
extends StairsBody

func _physics_process(delta: float) -> void:
    velocity.y -= gravity * delta
    velocity.x = input_direction.x * speed
    velocity.z = input_direction.z * speed
    desired_velocity = Vector3(velocity.x, 0.0, velocity.z)
    move_and_stair_step()
```

Give the body a `CollisionShape3D` child with a `CylinderShape3D`, margin around
`0.001`. `StairsBody` is not a `CharacterBody3D`: there is no `move_and_slide()`,
but `velocity`, `is_on_floor()`, `is_on_wall()`, `get_floor_normal()` and the
other familiar getters are there. Its properties and signals are documented in the
editor's built-in help.

Full documentation is in the [repository
README](https://github.com/plaught-armor/stairs-character).

## License and provenance

MIT — see `LICENSE` in this directory.

This addon is a hard fork of [Andicraft/stairs-character](https://github.com/Andicraft/stairs-character),
maintained at [plaught-armor/stairs-character](https://github.com/plaught-armor/stairs-character).
The stepping algorithm is Andrea Jörgensen's original work; the fork rewrote what
surrounds it. Both copyright lines in `LICENSE` are required — keep that file
beside the addon in anything you ship.
