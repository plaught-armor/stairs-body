#include "stairs_body.h"

#include <godot_cpp/classes/box_shape3d.hpp>
#include <godot_cpp/classes/cylinder_shape3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/physics_direct_body_state3d.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

namespace {

PhysicsServer3D *physics() {
	return PhysicsServer3D::get_singleton();
}

} // namespace

StairsBody::StairsBody() {
	_params.instantiate();
	_result.instantiate();
	_contact_params.instantiate();
	_cast_params.instantiate();
	// Moves are teleports of a kinematic body, the way CharacterBody3D moves.
	set_sync_to_physics(false);
	_contact_params->set_recovery_as_collision_enabled(true);
	_contact_params->set_max_collisions(CONTACT_MAX);
}

// NOTIFICATION_READY and NOTIFICATION_PROCESS reach the class whatever a script
// subclass defines, so a subclass with its own _ready or _process cannot shadow
// these the way it would shadow a method. Process delta is the render frame's:
// smoothing is visual.
//
// An extension class runs in the editor as if it were @tool, which the GDScript
// original was not. Smoothing there would own smooth_node's local Y and snap back
// every edit to it, so the editor gets none of it.
void StairsBody::_notification(int p_what) {
	if (Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	if (p_what == NOTIFICATION_READY) {
		_init_step_smoothing();
	} else if (p_what == NOTIFICATION_PROCESS) {
		_tick_step_smoothing(get_process_delta_time());
	}
}

bool StairsBody::_test_motion(const Ref<PhysicsTestMotionParameters3D> &p_params) {
	return physics()->body_test_motion(get_rid(), p_params, _result);
}

// Moves the body by velocity for one physics frame, stepping up and down stairs.
void StairsBody::move_and_stair_step() {
	_params->set_margin(safe_margin);
	const double delta = get_physics_process_delta_time();
	const bool was_on_floor = _on_floor;
	if (was_on_floor) {
		_refresh_platform_velocity();
		_carry(_platform_velocity * delta);
	}

	const Transform3D start = get_global_transform();
	const Vector3 start_velocity = velocity;
	const Vector3 motion = _intended_motion(was_on_floor, delta);
	const bool may_step = was_on_floor || force_stair_step;
	_clear_contacts();
	_slide(motion, may_step, delta, false);
	if (_settle()) {
		// A sweep went through something. Redo the move checking every sweep.
		set_global_transform(start);
		velocity = start_velocity;
		_clear_contacts();
		_slide(motion, may_step, delta, true);
		// Best effort: still embedded after this, the body is left where it is and
		// the next move's recovery works on it.
		_settle();
	}
	if (_step_rise > 0.0) {
		_accumulate_step_smoothing(_step_rise);
		emit_signal("stepped_up");
		emit_signal("stepped");
	}

	if (was_on_floor && !_on_floor && velocity.y <= 0.0) {
		_probe_floor();
	}

	if (was_on_floor && !_on_floor) {
		velocity += _platform_velocity;
		_platform_velocity = Vector3();
		_floor_rid = RID();
		_floor_id = 0;
	}
	if (_on_floor && velocity.y < 0.0) {
		velocity.y = 0.0;
	}

	desired_velocity = Vector3();
	force_stair_step = false;
}

void StairsBody::_clear_contacts() {
	_step_rise = 0.0;
	_on_floor = false;
	_on_wall = false;
	_on_ceiling = false;
}

double StairsBody::_step_down_reach() const {
	return step_down_height < 0.0 ? step_height : step_down_height;
}

// Grounded and not moving up, the move follows the floor at the horizontal speed
// and drops gravity: the floor probe keeps the body down, so sweeping gravity into
// the floor every frame buys nothing and doubles that sweep's cost.
Vector3 StairsBody::_intended_motion(bool p_was_on_floor, double p_delta) const {
	if (!p_was_on_floor || velocity.y > 0.0) {
		return velocity * p_delta;
	}
	const Vector3 horizontal = velocity * HORIZONTAL_MASK;
	if (horizontal == Vector3()) {
		return Vector3();
	}
	const Vector3 along = horizontal.slide(_floor_normal);
	return along.normalized() * horizontal.length() * p_delta;
}

// Fresh platform velocity for a moving floor. A static floor's collider velocity is
// already exact - zero, or a conveyor's constant velocity - so it is left alone.
void StairsBody::_refresh_platform_velocity() {
	if (!_floor_rid.is_valid()) {
		return;
	}
	if (!UtilityFunctions::is_instance_id_valid(_floor_id)) {
		_platform_velocity = Vector3();
		_floor_rid = RID();
		_floor_id = 0;
		return;
	}
	if (physics()->body_get_mode(_floor_rid) == PhysicsServer3D::BODY_MODE_STATIC) {
		return;
	}
	PhysicsDirectBodyState3D *state = physics()->body_get_direct_state(_floor_rid);
	if (state == nullptr) {
		_platform_velocity = Vector3();
		_floor_rid = RID();
		_floor_id = 0;
		return;
	}
	_platform_velocity = state->get_velocity_at_local_position(
			get_global_position() - state->get_transform().origin);
}

// The floor's displacement as its own sweep, with the floor excluded so the body
// is carried rather than blocked by what carries it. Only runs on a moving floor.
void StairsBody::_carry(const Vector3 &p_motion) {
	if (p_motion == Vector3()) {
		return;
	}
	TypedArray<RID> exclude;
	exclude.push_back(_floor_rid);
	_params->set_from(get_global_transform());
	_params->set_motion(p_motion);
	_params->set_exclude_bodies(exclude);
	_test_motion(_params);
	_params->set_exclude_bodies(TypedArray<RID>());
	set_global_transform(get_global_transform().translated(_result->get_travel()));
}

// `verify` checks each sweep that reports no collision against a shape cast, and
// stops it where the cast does - see _settle for why a sweep can need that.
void StairsBody::_slide(Vector3 p_motion, bool p_may_step, double p_delta, bool p_verify) {
	Transform3D from = get_global_transform();
	Vector3 probe = p_verify ? p_motion : _step_probe(p_motion, p_may_step, p_delta);
	if (probe != p_motion && probe.normalized().dot(p_motion.normalized()) < PARALLEL) {
		// Intent points away from this frame's motion, so the probe's sweep says
		// nothing about where the body can go. It only looks for a step.
		if (_intent_step(from, probe, p_motion.length())) {
			set_global_transform(_step_to);
			return;
		}
		probe = p_motion;
	}
	Vector3 previous_normal;
	for (int i = 0; i < max_slides; i++) {
		const Vector3 sweep = i == 0 ? probe : p_motion;
		// A clipped remainder under a margin is not worth a sweep, but the frame's
		// own move is: a slow walk at a high tick rate moves less than a margin a
		// frame, and dropping it leaves the body standing still.
		if (sweep == Vector3() || (i > 0 && sweep.length() < safe_margin)) {
			break;
		}
		_params->set_from(from);
		_params->set_motion(sweep);
		if (!_test_motion(_params)) {
			const double reach = p_verify ? _unblocked_fraction(from, sweep) : 1.0;
			if (reach >= 1.0) {
				from = from.translated(p_motion);
				break;
			}
			from = from.translated(sweep * reach);
			p_motion = sweep * (1.0 - reach);
			continue;
		}
		Vector3 travel = _result->get_travel();
		Vector3 remainder = _result->get_remainder();
		if (i == 0 && sweep != p_motion) {
			// The probe looked further along the same line than this frame moves. Its
			// hit only matters to the step below; the body travels no further than
			// motion.
			travel = _clip_length(travel, p_motion.length());
			remainder = p_motion - travel;
		}
		from = from.translated(travel);
		Vector3 normal = _result->get_collision_normal(0);
		const Kind kind = _classify(normal);
		if (kind == KIND_WALL && p_may_step && _try_step(from, sweep - travel, normal)) {
			from = _step_to;
			break;
		}
		if (kind == KIND_WALL && p_may_step) {
			// Grounded, a steep face is a vertical plane: the body slides along it
			// rather than up it.
			normal = (normal * HORIZONTAL_MASK).normalized();
		}
		p_motion = _clip(remainder, normal, previous_normal);
		if (velocity.dot(normal) < 0.0) {
			velocity = velocity.slide(normal);
		}
		previous_normal = normal;
	}
	set_global_transform(from);
}

// A step from wherever a probe along intent meets a steep face, at most `reach`
// along it. With no motion this frame, intent is the only direction there is, and
// a face it meets is the wall the body is being held against; otherwise the face
// may be off to the side, and only the slide's own sweep records a wall.
bool StairsBody::_intent_step(const Transform3D &p_from, const Vector3 &p_probe, double p_reach) {
	_params->set_from(p_from);
	_params->set_motion(p_probe);
	if (!_test_motion(_params)) {
		return false;
	}
	const Vector3 normal = _result->get_collision_normal(0);
	const double angle = normal.angle_to(WORLD_UP);
	if (angle <= floor_max_angle || angle >= Math::PI - floor_max_angle) {
		return false;
	}
	if (Math::is_zero_approx(p_reach)) {
		_on_wall = true;
		_wall_normal = normal;
	}
	const Vector3 travel = _clip_length(_result->get_travel(), p_reach);
	return _try_step(p_from.translated(travel), p_probe - travel, normal);
}

// Records the contact and says what it is.
StairsBody::Kind StairsBody::_classify(const Vector3 &p_normal) {
	const double angle = p_normal.angle_to(WORLD_UP);
	if (angle <= floor_max_angle) {
		_record_floor(p_normal);
		return KIND_FLOOR;
	}
	if (angle >= Math::PI - floor_max_angle) {
		_on_ceiling = true;
		return KIND_CEILING;
	}
	_on_wall = true;
	_wall_normal = p_normal;
	return KIND_WALL;
}

// Floor state from contact `index` of the last sweep.
void StairsBody::_record_floor(const Vector3 &p_normal, int p_index) {
	_on_floor = true;
	_floor_normal = p_normal;
	_floor_rid = _result->get_collider_rid(p_index);
	_floor_id = _result->get_collider_id(p_index);
	_platform_velocity = _result->get_collider_velocity(p_index);
}

// One zero-motion test after the move, for two jobs. Returns whether the body
// ended up inside something, leaving the contact state alone when it did.
//
// Floor contact. If the move did not already find floor, the contacts this test
// reports during depenetration say whether the body is resting on some. Much
// cheaper than the floor probe (1.7 us against 4.5 on Jolt, 5.5 against 8.4 on
// Godot Physics), which then only runs where contact is actually lost: edges,
// steps down, leaving a platform. Zero motion rather than the move sweep's own
// contacts, because Jolt's body_test_motion drops any contact that does not oppose
// the motion, and a floor under a horizontal move is exactly that
// (jolt_query_collectors.h, "Ignore hits that don't oppose the motion direction").
// With no motion there is no direction and nothing is filtered, on either engine.
//
// Tunnelling. That same Jolt filter lets body_test_motion report no collision and
// the FULL motion as travel when its cast actually stopped on a contact the filter
// then threw away. Measured: a cylinder moving down past a ledge edge ended 0.13 m
// inside the floor below. A resting contact recovers under one margin, so recovery
// past EMBED_MARGINS of them means a sweep went through something. The recovery
// is not applied: that deep, depenetration picks whichever way out is shortest -
// 1.47 m down through the floor on Godot Physics, 0.5 m sideways on Jolt. The move
// is redone instead, with every sweep checked.
bool StairsBody::_settle() {
	_contact_params->set_margin(safe_margin);
	_contact_params->set_from(get_global_transform());
	if (!_test_motion(_contact_params)) {
		return false;
	}
	if (_result->get_travel().length() > safe_margin * EMBED_MARGINS) {
		return true;
	}
	if (_on_floor) {
		return false;
	}
	int best = -1;
	double best_angle = floor_max_angle;
	const int count = _result->get_collision_count();
	for (int i = 0; i < count; i++) {
		const double angle = _result->get_collision_normal(i).angle_to(WORLD_UP);
		if (angle <= best_angle) {
			best = i;
			best_angle = angle;
		}
	}
	if (best >= 0) {
		_record_floor(_result->get_collision_normal(best), best);
	}
	return false;
}

// How much of `motion` from `from` the body's shapes can travel, by shape cast.
// cast_motion has no motion-direction filter, so it stops where the cast inside a
// no-collision body_test_motion stopped.
double StairsBody::_unblocked_fraction(const Transform3D &p_from, const Vector3 &p_motion) {
	// Out of the tree there is no world, and a locked or threaded space hands back
	// no state. Nothing can be cast then, so the sweep's own answer stands.
	const Ref<World3D> world = get_world_3d();
	if (world.is_null()) {
		return 1.0;
	}
	PhysicsDirectSpaceState3D *space = world->get_direct_space_state();
	ERR_FAIL_NULL_V_MSG(space, 1.0, "Space state is inaccessible; this move's sweeps go unverified.");
	TypedArray<RID> exclude;
	exclude.push_back(get_rid());
	_cast_params->set_motion(p_motion);
	_cast_params->set_margin(safe_margin);
	_cast_params->set_collision_mask(get_collision_mask());
	_cast_params->set_exclude(exclude);
	double fraction = 1.0;
	const PackedInt32Array owners = get_shape_owners();
	for (int64_t k = 0; k < owners.size(); k++) {
		const uint32_t owner_id = owners[k];
		if (is_shape_owner_disabled(owner_id)) {
			continue;
		}
		const Transform3D at = p_from * shape_owner_get_transform(owner_id);
		const int shape_count = shape_owner_get_shape_count(owner_id);
		for (int i = 0; i < shape_count; i++) {
			_cast_params->set_shape(shape_owner_get_shape(owner_id, i));
			_cast_params->set_transform(at);
			// Empty when the cast itself fails, such as for a shape the engine cannot cast.
			const PackedFloat32Array safe_unsafe = space->cast_motion(_cast_params);
			if (safe_unsafe.size() > 0) {
				fraction = MIN(fraction, (double)safe_unsafe[0]);
			}
		}
	}
	return fraction;
}

// Remainder slid along the plane it hit, and along the crease when it also hit
// the previous plane - the Quake clip, so a corner settles in two sweeps.
Vector3 StairsBody::_clip(const Vector3 &p_remainder, const Vector3 &p_normal, const Vector3 &p_previous_normal) {
	const Vector3 clipped = p_remainder.slide(p_normal);
	if (p_previous_normal == Vector3() || clipped.dot(p_previous_normal) >= 0.0) {
		return clipped;
	}
	Vector3 crease = p_previous_normal.cross(p_normal);
	if (crease.length_squared() < 1e-8) {
		return Vector3();
	}
	crease = crease.normalized();
	return crease * crease.dot(clipped);
}

Vector3 StairsBody::_clip_length(const Vector3 &p_v, double p_max_length) {
	const double length = p_v.length();
	if (length <= p_max_length || length == 0.0) {
		return p_v;
	}
	return p_v * (p_max_length / length);
}

// The first sweep of the move doubles as the step probe, so it has to reach a
// step face even when this frame barely moves: pinned against the face by a
// standstill (intent is the stronger signal), or at a tick rate high enough that
// a frame's travel is shorter than the gap an engine leaves at a face.
Vector3 StairsBody::_step_probe(const Vector3 &p_motion, bool p_may_step, double p_delta) const {
	if (!p_may_step) {
		return p_motion;
	}
	const Vector3 horizontal = p_motion * HORIZONTAL_MASK;
	const Vector3 intent = desired_velocity * HORIZONTAL_MASK * p_delta;
	Vector3 direction = horizontal;
	if (intent.length_squared() > horizontal.length_squared() && intent.dot(horizontal) >= 0.0) {
		direction = intent;
	}
	if (direction == Vector3()) {
		return p_motion;
	}
	const double reach = MAX((double)direction.length(), min_step_forward);
	if (reach <= horizontal.length()) {
		return p_motion;
	}
	return p_motion - horizontal + direction.normalized() * reach;
}

// Whether a step may be committed onto `body`: anything the physics server is not
// simulating - static geometry, kinematic platforms, frozen rigid bodies - and not
// on `ignore_layers`. A step is a teleport rather than a solve, so setting the body
// down on a simulating one leaves the solver to separate them by moving the only
// thing that can move, which raises the surface and offers the next frame a fresh
// step. Measured under Jolt: a loose 0.45 x 0.3 x 0.45 m crate lifted the body
// 1.085 m and left at 5.6 m/s, the same at 10 kg and 30 kg.
bool StairsBody::is_step_surface(const RID &p_body, uint32_t p_ignore_layers) {
	if (p_ignore_layers != 0 && (physics()->body_get_collision_layer(p_body) & p_ignore_layers) != 0) {
		return false;
	}
	const PhysicsServer3D::BodyMode mode = physics()->body_get_mode(p_body);
	return mode != PhysicsServer3D::BODY_MODE_RIGID && mode != PhysicsServer3D::BODY_MODE_RIGID_LINEAR;
}

// The step with step_ignore_layers out of the mask. body_test_motion takes no mask
// of its own and reads the body's, so this is the only way to ask it early.
bool StairsBody::_try_step(const Transform3D &p_at, const Vector3 &p_remainder, const Vector3 &p_wall_normal) {
	if (step_ignore_layers == 0) {
		return _step_sweeps(p_at, p_remainder, p_wall_normal);
	}
	const uint32_t was_mask = get_collision_mask();
	set_collision_mask(was_mask & ~step_ignore_layers);
	const bool stepped_ok = _step_sweeps(p_at, p_remainder, p_wall_normal);
	set_collision_mask(was_mask);
	return stepped_ok;
}

// Up, forward, down from where the move met a steep face. On success _step_to
// holds the landing and the floor state is set from the down sweep, so the floor
// probe does not run again this frame.
bool StairsBody::_step_sweeps(const Transform3D &p_at, const Vector3 &p_remainder, const Vector3 &p_wall_normal) {
	const RID wall_rid = _result->get_collider_rid(0);
	if (_refused_here(p_at.origin, p_wall_normal, wall_rid)) {
		return false;
	}

	_params->set_from(p_at);
	_params->set_motion(WORLD_UP * step_height);
	_test_motion(_params);
	const double rise = _result->get_travel().y;
	if (rise < safe_margin) {
		return false;
	}
	const Transform3D raised = p_at.translated(WORLD_UP * rise);

	Vector3 forward = p_remainder * HORIZONTAL_MASK;
	if (forward.length() < min_step_forward) {
		forward = (-p_wall_normal * HORIZONTAL_MASK).normalized() * min_step_forward;
	}
	const Transform3D ahead = _step_forward(raised, forward);
	if ((ahead.origin - raised.origin).length() < safe_margin) {
		// Only a leg that had room to move and was blocked says anything about the
		// wall. A leg shorter than the margin is this frame's leftover travel, and
		// the next frame's may well climb from the same spot.
		if (forward.length() >= safe_margin) {
			_remember_refusal(p_at.origin, p_wall_normal, wall_rid);
		}
		return false;
	}

	_params->set_from(ahead);
	_params->set_motion(-WORLD_UP * rise);
	if (!_test_motion(_params)) {
		return false;
	}
	const Transform3D landed = ahead.translated(_result->get_travel());
	const Vector3 normal = _result->get_collision_normal(0);
	if (normal.angle_to(WORLD_UP) > floor_max_angle) {
		return false;
	}
	if (landed.origin.y - p_at.origin.y < safe_margin) {
		return false;
	}
	// Asked of the placement, not of the face first hit: a loose object leaning on a
	// kerb must not stop the body climbing the kerb.
	if (!is_step_surface(_result->get_collider_rid(0), step_ignore_layers)) {
		return false;
	}

	_record_floor(normal);
	_step_to = landed;
	_step_rise = landed.origin.y - p_at.origin.y;
	return true;
}

Transform3D StairsBody::_step_forward(Transform3D p_from, const Vector3 &p_forward) {
	Vector3 motion = p_forward;
	for (int i = 0; i < step_slide_iterations; i++) {
		_params->set_from(p_from);
		_params->set_motion(motion);
		const bool blocked = _test_motion(_params);
		p_from = p_from.translated(_result->get_travel());
		if (!blocked) {
			break;
		}
		motion = _result->get_remainder().slide(_result->get_collision_normal(0)) * HORIZONTAL_MASK;
		if (motion.length() < safe_margin) {
			break;
		}
	}
	return p_from;
}

bool StairsBody::_refused_here(const Vector3 &p_origin, const Vector3 &p_normal, const RID &p_rid) const {
	return _refused_valid && p_rid == _refused_rid && step_height == _refused_height &&
			p_origin.distance_to(_refused_at) < safe_margin * 2.0 &&
			p_normal.dot(_refused_normal) > 0.999;
}

void StairsBody::_remember_refusal(const Vector3 &p_origin, const Vector3 &p_normal, const RID &p_rid) {
	_refused_valid = physics()->body_get_mode(p_rid) == PhysicsServer3D::BODY_MODE_STATIC;
	_refused_at = p_origin;
	_refused_normal = p_normal;
	_refused_rid = p_rid;
	_refused_height = step_height;
}

// One sweep down: keeps a walker on the floor, steps it down, and finds ledges.
// Masked the same way and for the same reason as _try_step. The step-down is
// announced after the mask is back, so a handler sees the body's own mask.
void StairsBody::_probe_floor() {
	double drop = 0.0;
	if (step_ignore_layers == 0) {
		drop = _probe_sweep();
	} else {
		const uint32_t was_mask = get_collision_mask();
		set_collision_mask(was_mask & ~step_ignore_layers);
		drop = _probe_sweep();
		set_collision_mask(was_mask);
	}
	if (drop < 0.0) {
		_accumulate_step_smoothing(drop);
		emit_signal("stepped_down");
		emit_signal("stepped");
	}
}

// Returns the height change when it stepped the body down, a negative number, and
// 0.0 when it did not.
double StairsBody::_probe_sweep() {
	_params->set_from(get_global_transform());
	_params->set_motion(-WORLD_UP * _step_down_reach());
	if (!_test_motion(_params)) {
		if (_unblocked_fraction(_params->get_from(), _params->get_motion()) < 1.0) {
			// No collision, yet a shape cast is blocked: the rim is over an edge by
			// less than a margin, and Jolt dropped the edge's contact because it does
			// not oppose the probe (see _settle). The edge still holds the body up,
			// which is what Godot Physics reports there. Perch, as below, keeping last
			// frame's floor normal and collider - the body has not moved off them.
			_on_floor = true;
		}
		return 0.0;
	}
	Vector3 normal = _result->get_collision_normal(0);
	if (normal.angle_to(WORLD_UP) > floor_max_angle) {
		if (!_flat_bottomed()) {
			// A rounded bottom meets a tread's corner before its face and reports the
			// corner's normal, so steepness says nothing here; take it as support.
			normal = WORLD_UP;
		} else if (_result->get_travel().length() < safe_margin * 2.0) {
			// Already touching: the rim is resting on an edge, which still holds the
			// body up. Keep last frame's floor; the next probe clears the edge.
			_on_floor = true;
			return 0.0;
		} else if (!_probe_off_corner(normal, _result->get_travel().length())) {
			return 0.0;
		} else {
			normal = _result->get_collision_normal(0);
		}
	}
	// From where the probe started, which _probe_off_corner may have moved.
	const Vector3 travel = _params->get_from().origin + _result->get_travel() - get_global_position();
	const bool step_down = -travel.y >= STEP_DOWN_SIGNAL_MIN;
	// A step down is a placement too; see is_step_surface. Keeping contact with a
	// loose body already underfoot is not, and stays allowed. Defensive and untested,
	// as it was in the GDScript version: a probe walked off a kerb finds the floor
	// beside a loose object, not the object.
	if (step_down && !is_step_surface(_result->get_collider_rid(0), step_ignore_layers)) {
		return 0.0;
	}
	set_global_transform(get_global_transform().translated(travel));
	_record_floor(normal);
	return step_down ? travel.y : 0.0;
}

// A flat bottom that drops onto a steep contact from above the edge it is walking
// off has met the edge's rounded top: Jolt gives a box's edges its margin as a
// convex radius, and a bottom level with the top of that curve meets it partway
// down, on the curve's side. Nothing up there holds the body - measured, a 0.27 m
// cylinder walking down 0.25 m treads at 1.9 m/s met it on 3 treads in 16 and fell
// instead of stepping. Shift off the curve, away from it and level, then probe
// again. For a curve of radius r met at angle a from up after a drop d, the contact
// is r sin(a) = d / tan(a / 2) in from the curve's top, which is what the shift
// clears, plus a margin. The shift grows without bound as the angle nears zero,
// which only a floor_max_angle near zero lets through, so it is capped at the
// probe's reach. Returns whether _result holds a walkable floor, probed from
// _params's from.
bool StairsBody::_probe_off_corner(const Vector3 &p_normal, double p_drop) {
	const double clear = p_drop / Math::tan(p_normal.angle_to(WORLD_UP) * 0.5) + safe_margin;
	const Vector3 shift = (p_normal * HORIZONTAL_MASK).normalized() * MIN(clear, _step_down_reach());
	const Transform3D from = _params->get_from();
	_params->set_motion(shift);
	if (_test_motion(_params)) {
		return false;
	}
	_params->set_from(from.translated(shift));
	_params->set_motion(-WORLD_UP * _step_down_reach());
	if (!_test_motion(_params)) {
		return false;
	}
	return _result->get_collision_normal(0).angle_to(WORLD_UP) <= floor_max_angle;
}

// Whether every enabled shape on the body has a flat bottom, which is what lets a
// steep contact under it be read as steep ground rather than as a rounded bottom
// meeting a corner. A capsule, sphere or convex hull answers false.
bool StairsBody::_flat_bottomed() {
	int shapes = 0;
	const PackedInt32Array owners = get_shape_owners();
	for (int64_t k = 0; k < owners.size(); k++) {
		const uint32_t owner_id = owners[k];
		if (is_shape_owner_disabled(owner_id)) {
			continue;
		}
		const int shape_count = shape_owner_get_shape_count(owner_id);
		for (int i = 0; i < shape_count; i++) {
			const Ref<Shape3D> shape = shape_owner_get_shape(owner_id, i);
			if (Object::cast_to<CylinderShape3D>(shape.ptr()) == nullptr &&
					Object::cast_to<BoxShape3D>(shape.ptr()) == nullptr) {
				return false;
			}
			shapes += 1;
		}
	}
	return shapes > 0;
}

Node3D *StairsBody::_smooth_node() const {
	return Object::cast_to<Node3D>(ObjectDB::get_instance(smooth_node_id));
}

void StairsBody::set_smooth_node(Object *p_node) {
	// The binding passes any Object through; a typed GDScript export would refuse
	// one that is not a Node3D, so this does too.
	ERR_FAIL_COND_MSG(p_node != nullptr && Object::cast_to<Node3D>(p_node) == nullptr, "smooth_node must be a Node3D.");
	smooth_node_id = p_node == nullptr ? ObjectID() : p_node->get_instance_id();
}

// Processing is only ever turned on here, never off: a subclass with its own
// _process has idle processing enabled by the engine, and switching it off from
// this base would silently kill that _process.
void StairsBody::_init_step_smoothing() {
	_smooth_offset_y = 0.0;
	Node3D *node = _smooth_node();
	if (node == nullptr) {
		return;
	}
	_smooth_rest_y = node->get_position().y;
	set_process(true);
}

// The visual is pushed opposite the body's signed step height, so it holds its
// world height for a frame before the decay pulls it home. A move over twice the
// larger reach is a teleport or a shove rather than a step, and is not eased. The
// offset is clamped to one reach so a burst of steps cannot stack into a lurch.
void StairsBody::_accumulate_step_smoothing(double p_step_delta_y) {
	if (_smooth_node() == nullptr || step_smoothing <= 0.0) {
		return;
	}
	const double reach = MAX(step_height, _step_down_reach());
	if (Math::abs(p_step_delta_y) > reach * 2.0) {
		return;
	}
	_smooth_offset_y = CLAMP(_smooth_offset_y - p_step_delta_y, -reach, reach);
}

// Render-frame decay of the offset: exp(-rate * dt) closes the same fraction of the
// distance per second at any frame rate. A rate of zero collapses it at once.
void StairsBody::_tick_step_smoothing(double p_delta) {
	Node3D *node = _smooth_node();
	if (node == nullptr) {
		return;
	}
	if (step_smoothing <= 0.0) {
		_smooth_offset_y = 0.0;
	} else {
		_smooth_offset_y *= Math::exp(-step_smoothing * p_delta);
		if (Math::abs(_smooth_offset_y) < SMOOTH_EPSILON) {
			_smooth_offset_y = 0.0;
		}
	}
	Vector3 position = node->get_position();
	position.y = _smooth_rest_y + _smooth_offset_y;
	node->set_position(position);
}

void StairsBody::_bind_methods() {
	ClassDB::bind_method(D_METHOD("move_and_stair_step"), &StairsBody::move_and_stair_step);
	ClassDB::bind_static_method("StairsBody", D_METHOD("is_step_surface", "body", "ignore_layers"), &StairsBody::is_step_surface, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("is_on_floor"), &StairsBody::is_on_floor);
	ClassDB::bind_method(D_METHOD("is_on_wall"), &StairsBody::is_on_wall);
	ClassDB::bind_method(D_METHOD("is_on_ceiling"), &StairsBody::is_on_ceiling);
	ClassDB::bind_method(D_METHOD("get_floor_normal"), &StairsBody::get_floor_normal);
	ClassDB::bind_method(D_METHOD("get_wall_normal"), &StairsBody::get_wall_normal);
	ClassDB::bind_method(D_METHOD("get_platform_velocity"), &StairsBody::get_platform_velocity);

	ClassDB::bind_method(D_METHOD("_init_step_smoothing"), &StairsBody::_init_step_smoothing);
	ClassDB::bind_method(D_METHOD("_accumulate_step_smoothing", "step_delta_y"), &StairsBody::_accumulate_step_smoothing);
	ClassDB::bind_method(D_METHOD("_tick_step_smoothing", "delta"), &StairsBody::_tick_step_smoothing);
	ClassDB::bind_method(D_METHOD("_get_smooth_offset_y"), &StairsBody::_get_smooth_offset_y);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "_smooth_offset_y", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "", "_get_smooth_offset_y");

#define STAIRS_BIND(m_name, m_type, m_hint, m_hint_string)                                                     \
	ClassDB::bind_method(D_METHOD("set_" #m_name, "value"), &StairsBody::set_##m_name);             \
	ClassDB::bind_method(D_METHOD("get_" #m_name), &StairsBody::get_##m_name);                     \
	ADD_PROPERTY(PropertyInfo(m_type, #m_name, m_hint, m_hint_string), "set_" #m_name, "get_" #m_name)

	STAIRS_BIND(step_height, Variant::FLOAT, PROPERTY_HINT_NONE, "");
	STAIRS_BIND(step_down_height, Variant::FLOAT, PROPERTY_HINT_NONE, "");
	STAIRS_BIND(min_step_forward, Variant::FLOAT, PROPERTY_HINT_RANGE, "0.0,0.2,0.001");
	STAIRS_BIND(step_slide_iterations, Variant::INT, PROPERTY_HINT_RANGE, "1,8");
	STAIRS_BIND(floor_max_angle, Variant::FLOAT, PROPERTY_HINT_RANGE, "0.0,180.0,0.1,radians_as_degrees");
	STAIRS_BIND(max_slides, Variant::INT, PROPERTY_HINT_RANGE, "1,8");
	STAIRS_BIND(safe_margin, Variant::FLOAT, PROPERTY_HINT_RANGE, "0.001,0.1,0.001");
	STAIRS_BIND(step_ignore_layers, Variant::INT, PROPERTY_HINT_LAYERS_3D_PHYSICS, "");
	ADD_GROUP("Step Smoothing", "");
	STAIRS_BIND(smooth_node, Variant::OBJECT, PROPERTY_HINT_NODE_TYPE, "Node3D");
	STAIRS_BIND(step_smoothing, Variant::FLOAT, PROPERTY_HINT_RANGE, "0.0,60.0,0.5");
	ADD_GROUP("", "");

#undef STAIRS_BIND

	ClassDB::bind_method(D_METHOD("set_velocity", "value"), &StairsBody::set_velocity);
	ClassDB::bind_method(D_METHOD("get_velocity"), &StairsBody::get_velocity);
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "velocity", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_velocity", "get_velocity");
	ClassDB::bind_method(D_METHOD("set_desired_velocity", "value"), &StairsBody::set_desired_velocity);
	ClassDB::bind_method(D_METHOD("get_desired_velocity"), &StairsBody::get_desired_velocity);
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "desired_velocity", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_desired_velocity", "get_desired_velocity");
	ClassDB::bind_method(D_METHOD("set_force_stair_step", "value"), &StairsBody::set_force_stair_step);
	ClassDB::bind_method(D_METHOD("get_force_stair_step"), &StairsBody::get_force_stair_step);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "force_stair_step", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_force_stair_step", "get_force_stair_step");

	ADD_SIGNAL(MethodInfo("stepped"));
	ADD_SIGNAL(MethodInfo("stepped_up"));
	ADD_SIGNAL(MethodInfo("stepped_down"));
}
