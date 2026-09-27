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
