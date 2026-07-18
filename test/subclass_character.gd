extends StairsCharacter

## The usage pattern from upstream's own README: a subclass that defines both
## `_ready` and `_physics_process`, with no `super()` call. Both parent bodies
## are replaced, which is exactly what test case 8 is checking for.

var custom_ready_ran: bool = false
var custom_physics_frames: int = 0


func _ready() -> void:
	custom_ready_ran = true


func _physics_process(_delta: float) -> void:
	custom_physics_frames += 1
