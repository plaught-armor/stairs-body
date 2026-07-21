extends StairsCharacter

## The usage pattern from upstream's own README: a subclass that defines both
## `_ready` and `_physics_process`, with no `super()` call. Both parent bodies
## are replaced, which is exactly what test case 8 is checking for.
##
## It also overrides `_notification` without calling super, which is the hostile
## case for the margin resolution: the addon hooks NOTIFICATION_READY precisely
## because Godot dispatches `_notification` to every script in the inheritance
## chain rather than letting the most-derived one replace it. If that ever stops
## being true, case 12 fails and the margin silently goes back to 0.0.

var custom_ready_ran: bool = false
var custom_physics_frames: int = 0
var custom_notifications: int = 0
var custom_process_frames: int = 0


func _ready() -> void:
	custom_ready_ran = true


func _physics_process(_delta: float) -> void:
	custom_physics_frames += 1


# Defining _process auto-enables idle processing on this subclass. Case 36 checks
# the base's smoothing setup does not switch it back off when smooth_node is
# unassigned - the same shadowing trap the _notification hooks avoid.
func _process(_delta: float) -> void:
	custom_process_frames += 1


func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		custom_notifications += 1
