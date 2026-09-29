#include "stairs_body.h"
#include "stairs_geometry.h"

#include <godot_cpp/classes/box_shape3d.hpp>
#include <godot_cpp/classes/capsule_shape3d.hpp>
#include <godot_cpp/classes/concave_polygon_shape3d.hpp>
#include <godot_cpp/classes/convex_polygon_shape3d.hpp>
#include <godot_cpp/classes/height_map_shape3d.hpp>
#include <godot_cpp/classes/sphere_shape3d.hpp>
#include <godot_cpp/classes/cylinder_shape3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/physics_direct_body_state3d.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <unordered_map>
#include <vector>

using namespace godot;

namespace {

PhysicsServer3D *physics() {
	return PhysicsServer3D::get_singleton();
}

// Every StairsBody in the tree, for crowd separation.
std::vector<StairsBody *> g_members;
// The physics frame the crowd snapshot was taken on.
uint64_t g_crowd_frame = UINT64_MAX;
// Grid over the snapshot's footprint centres, by cell, holding snapshot indices.
// Cells are as wide as the longest reach doubled plus the lookahead, so any two
// footprints that could touch this frame are at most one cell apart.
std::unordered_map<int64_t, std::vector<uint32_t>> g_grid;

int64_t cell_key(int64_t p_x, int64_t p_z) {
	return (p_x << 32) ^ (p_z & 0xffffffff);
}

} // namespace

std::vector<StairsBody::CrowdSnap> StairsBody::s_snap;
std::vector<std::pair<uint32_t, uint32_t>> StairsBody::s_pairs;
std::vector<uint32_t> StairsBody::s_adjacent;

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

bool StairsBody::_test_motion(const Ref<PhysicsTestMotionParameters3D> &p_params) {
	return physics()->body_test_motion(get_rid(), p_params, _result);
}

// One sweep with step_ignore_layers out of the mask. Besides not meeting those
// bodies, it skips depenetrating from them, which is most of what a sweep costs in
// a crowd pressed together: in a pile of 96 bodies, 10.3 us against 2.2 on Jolt for
// the zero-motion test, where the neighbours are all the body overlaps.
bool StairsBody::_test_motion_masked(const Ref<PhysicsTestMotionParameters3D> &p_params) {
	if (step_ignore_layers == 0) {
		return _test_motion(p_params);
	}
	const uint32_t was_mask = get_collision_mask();
	set_collision_mask(was_mask & ~step_ignore_layers);
	const bool hit = _test_motion(p_params);
	set_collision_mask(was_mask);
	return hit;
}

// Appends contact `index` of the last sweep to the contact list. The list holds
// what the body touched on the path it took: slide sweeps, the sweeps of a step it
// committed, the carry, the floor probe that set it down, and the resting contacts
// of the post-move test, floor included. The sweeps of a step that was refused
// are rolled back, since the body never went there.
void StairsBody::_record_contact(int p_index) {
	Contact contact;
	contact.collider_id = _result->get_collider_id(p_index);
	contact.normal = _result->get_collision_normal(p_index);
	contact.position = _result->get_collision_point(p_index);
	_contacts.push_back(contact);
}

void StairsBody::set_walk_grid(StairsWalkGrid *p_grid) {
	_walk_grid_id = p_grid != nullptr ? p_grid->get_instance_id() : 0;
}

StairsWalkGrid *StairsBody::get_walk_grid() const {
	return Object::cast_to<StairsWalkGrid>(ObjectDB::get_instance(_walk_grid_id));
}

// Walk mode: the move made on the walk grid's boxes, with no physics query, the
// way crowds in shipped games walk on baked navigation data and use physics only
// when they must. Taken only on the floor, on a baked box, not rising, with no
// moving floor, where the grid answers for everything the move can reach, and
// only if the body's feet are within WALK_ENTRY of the grid's floor; otherwise the
// move sweeps. A move the grid cannot finish - a drop past the step-down reach,
// a ceiling met stepping up, the body already inside a box - is undone and swept.
// Returns whether the move was made.
bool StairsBody::_walk_on_grid(double p_delta) {
	StairsWalkGrid *grid = get_walk_grid();
	_on_grid = false;
	if (grid == nullptr || !_on_floor || velocity.y > 0.0 || force_stair_step ||
			_platform_velocity != Vector3() || !UtilityFunctions::is_instance_id_valid(_floor_id)) {
		return false;
	}
	if (!grid->is_baked()) {
		grid->bake();
	}
	if (!grid->bakes(_floor_id)) {
		return false;
	}
	if (!_footprint_known) {
		_measure_footprint();
		ERR_FAIL_COND_V_MSG(!_footprint_known, false, "StairsBody has no shapes to walk the grid with.");
	}
	const Neighbour foot = _foot_world(get_global_transform());
	const Vector3 saved_velocity = velocity;
	const Vector3 saved_pending = _crowd_pending;
	_contacts.clear();
	const Vector3 motion = _crowd_solve(velocity * HORIZONTAL_MASK * p_delta) * HORIZONTAL_MASK;
	const double pad = foot.axis.length() + foot.radius + safe_margin * 4.0;
	const Vector3 from = foot.centre;
	const Vector3 to = foot.centre + motion;
	const double min_x = MIN(from.x, to.x) - pad;
	const double min_z = MIN(from.z, to.z) - pad;
	const double max_x = MAX(from.x, to.x) + pad;
	const double max_z = MAX(from.z, to.z) + pad;
	_grid_boxes.clear();
	grid->gather(min_x, min_z, max_x, max_z, _grid_boxes);

	double floor = 0.0;
	uint32_t floor_box = 0;
	Vector3 shift;
	bool hit = false;
	const bool walked = !grid->unanswered(min_x, min_z, max_x, max_z, foot.bottom - _step_down_reach() - WALK_ENTRY, foot.top + step_height, get_collision_mask()) &&
			_grid_floor(*grid, foot, Vector3(), floor, floor_box) && std::abs(foot.bottom - floor) <= WALK_ENTRY &&
			_grid_sweep(*grid, foot, motion, shift, hit) &&
			_grid_floor(*grid, foot, shift, floor, floor_box) && foot.bottom - floor <= _step_down_reach() + GRID_SLACK;
	Vector3 normal;
	Vector3 point;
	uint32_t box = 0;
	if (!walked || _grid_nearest(*grid, foot, shift, floor + GRID_SLACK, floor + (foot.top - foot.bottom), normal, box, point) < 0.0) {
		velocity = saved_velocity;
		_crowd_pending = saved_pending;
		_contacts.clear();
		return false;
	}
	_grid_commit(*grid, foot, shift, floor, floor_box, hit);
	return true;
}

// Slides the footprint by `motion` past the grid's boxes that stand higher than a
// step, stopping safe_margin short of each, sliding along it up to max_slides
// times, and stopping against one met closer to head-on than HEAD_ON, as a
// grounded slide does. Samples the path at most half a radius apart, so no wall is
// passed over, then bisects to the last clear point. A body already nearer a box
// than safe_margin may move but not come nearer. Returns false when the body
// starts inside such a box.
bool StairsBody::_grid_sweep(const StairsWalkGrid &p_grid, const Neighbour &p_foot, const Vector3 &p_motion, Vector3 &r_shift, bool &r_hit) {
	const double above = p_foot.bottom + step_height + GRID_SLACK;
	const double below = p_foot.top;
	Vector3 normal;
	Vector3 point;
	uint32_t box = UINT32_MAX;
	r_shift = Vector3();
	r_hit = false;
	double near = _grid_nearest(p_grid, p_foot, r_shift, above, below, normal, box, point);
	if (near < 0.0) {
		return false;
	}
	Vector3 remaining = p_motion;
	for (int slide = 0; slide < max_slides && remaining.length_squared() > 1e-12; slide++) {
		const double least = MIN(safe_margin, near) - 1e-9;
		const int samples = CLAMP((int)std::ceil(remaining.length() / MAX(p_foot.radius * 0.5, 0.01)), 1, GRID_SAMPLES_MAX);
		double clear = 0.0;
		double blocked = -1.0;
		for (int k = 1; k <= samples; k++) {
			const double t = double(k) / samples;
			if (_grid_nearest(p_grid, p_foot, r_shift + remaining * t, above, below, normal, box, point) < least) {
				blocked = t;
				break;
			}
			clear = t;
		}
		if (blocked < 0.0) {
			r_shift += remaining;
			return true;
		}
		for (int i = 0; i < GRID_BISECTIONS; i++) {
			const double mid = (clear + blocked) * 0.5;
			(_grid_nearest(p_grid, p_foot, r_shift + remaining * mid, above, below, normal, box, point) < least ? blocked : clear) = mid;
		}
		r_shift += remaining * clear;
		near = _grid_nearest(p_grid, p_foot, r_shift, above, below, normal, box, point);
		if (normal == Vector3()) {
			return true;
		}
		r_hit = true;
		const Vector3 rest = remaining * (1.0 - clear);
		if (-rest.normalized().dot(normal) > HEAD_ON) {
			return true;
		}
		remaining = rest.slide(normal);
	}
	return true;
}

// The highest top among the grid's boxes under the footprint moved by `shift`
// that the body can stand on from where it is: no higher than a step above its
// feet. Returns false when there is none.
bool StairsBody::_grid_floor(const StairsWalkGrid &p_grid, const Neighbour &p_foot, const Vector3 &p_shift, double &r_floor, uint32_t &r_box) const {
	const Vector3 a = p_foot.centre + p_shift - p_foot.axis;
	const Vector3 b = p_foot.centre + p_shift + p_foot.axis;
	const double reach_up = p_foot.bottom + step_height + GRID_SLACK;
	const uint32_t mask = get_collision_mask();
	bool found = false;
	for (const uint32_t i : _grid_boxes) {
		const StairsWalkGrid::Box &box = p_grid.box(i);
		Vector3 normal;
		Vector3 point;
		if ((box.layer & mask) == 0 || box.top > reach_up || (found && box.top <= r_floor) ||
				StairsWalkGrid::gap(box, a, b, p_foot.radius, normal, point) > 0.0) {
			continue;
		}
		r_floor = box.top;
		r_box = i;
		found = true;
	}
	return found;
}

// The smallest horizontal gap between the footprint moved by `shift` and the
// grid's boxes on the body's mask that reach above `above` and below `below`,
// with the normal from and nearest point of the nearest one, or +inf when there
// are none.
double StairsBody::_grid_nearest(const StairsWalkGrid &p_grid, const Neighbour &p_foot, const Vector3 &p_shift, double p_above, double p_below, Vector3 &r_normal, uint32_t &r_box, Vector3 &r_point) const {
	const Vector3 a = p_foot.centre + p_shift - p_foot.axis;
	const Vector3 b = p_foot.centre + p_shift + p_foot.axis;
	const uint32_t mask = get_collision_mask();
	double nearest = INFINITY;
	r_normal = Vector3();
	for (const uint32_t i : _grid_boxes) {
		const StairsWalkGrid::Box &box = p_grid.box(i);
		if ((box.layer & mask) == 0 || box.top <= p_above || box.bottom >= p_below) {
			continue;
		}
		Vector3 normal;
		Vector3 point;
		const double gap = StairsWalkGrid::gap(box, a, b, p_foot.radius, normal, point);
		if (gap < nearest) {
			nearest = gap;
			r_normal = normal;
			r_box = i;
			r_point = point;
		}
	}
	return nearest;
}

// Puts the body where the grid walk left it and records what it touched, as the
// sweeps would: the floor box, and when the walk ran into a box standing higher
// than a step, the nearest such box as a wall. A body left standing by a wall
// does not touch it, as with the sweeps, which leave it a margin or more away. A
// step up or down past STEP_DOWN_SIGNAL_MIN is announced.
void StairsBody::_grid_commit(const StairsWalkGrid &p_grid, const Neighbour &p_foot, const Vector3 &p_shift, double p_floor, uint32_t p_floor_box, bool p_hit) {
	Transform3D xform = get_global_transform();
	xform.origin += p_shift;
	xform.origin.y += p_floor - p_foot.bottom;
	set_global_transform(xform);
	_clear_contacts();
	const StairsWalkGrid::Box &floor_box = p_grid.box(p_floor_box);
	_on_floor = true;
	_floor_normal = WORLD_UP;
	_floor_rid = floor_box.rid;
	_floor_id = floor_box.id;
	_platform_velocity = Vector3();
	const Vector3 centre = p_foot.centre + p_shift;
	Contact floor_contact;
	floor_contact.collider_id = floor_box.id;
	floor_contact.normal = WORLD_UP;
	floor_contact.position = Vector3(centre.x, p_floor, centre.z);
	_contacts.push_back(floor_contact);
	Vector3 wall;
	Vector3 point;
	uint32_t wall_box = UINT32_MAX;
	const double gap = _grid_nearest(p_grid, p_foot, p_shift, p_foot.bottom + step_height + GRID_SLACK, p_foot.top, wall, wall_box, point);
	if (p_hit && gap <= safe_margin * 2.0 && wall != Vector3()) {
		_on_wall = true;
		_wall_normal = wall;
		Contact wall_contact;
		wall_contact.collider_id = p_grid.box(wall_box).id;
		wall_contact.normal = wall;
		wall_contact.position = Vector3(point.x, p_floor, point.z);
		_contacts.push_back(wall_contact);
		if (velocity.dot(wall) < 0.0) {
			velocity = velocity.slide(wall);
		}
	}
	velocity.y = 0.0;
	_last_wall = _on_wall ? _wall_normal : Vector3();
	_rest_valid = false;
	_settle_reusable = false;
	_on_grid = true;
	const double rise = p_floor - p_foot.bottom;
	if (rise >= STEP_DOWN_SIGNAL_MIN) {
		emit_signal("stepped_up", rise);
		emit_signal("stepped", rise);
	} else if (-rise >= STEP_DOWN_SIGNAL_MIN) {
		emit_signal("stepped_down", -rise);
		emit_signal("stepped", rise);
	}
	desired_velocity = Vector3();
	force_stair_step = false;
}

// Moves the body by velocity for one physics frame, stepping up and down stairs.
// `time_scale` stretches the frame, for a caller that moves the body less often
// than every frame: 2 moves it for two frames' worth of time, once.
void StairsBody::move_and_stair_step(double p_time_scale) {
	ERR_FAIL_COND_MSG(!(p_time_scale > 0.0), "time_scale must be positive.");
	_move(p_time_scale);
	_crowd_publish();
}

// Where this member now stands, plus any push it still owes, into this frame's
// snapshot, which is where the members that move after it read it.
void StairsBody::_crowd_publish() {
	if (crowd_layers == 0 || _snap_index >= s_snap.size() || s_snap[_snap_index].body != this ||
			g_crowd_frame != Engine::get_singleton()->get_physics_frames()) {
		return;
	}
	Neighbour &foot = s_snap[_snap_index].foot;
	foot = _foot_world(get_global_transform());
	foot.centre += _crowd_pending;
}

void StairsBody::_move(double p_time_scale) {
	_time_scale = p_time_scale;
	const double delta = get_physics_process_delta_time() * p_time_scale;
	const bool overlapping = _crowd_gather();
	if (!overlapping && _resting()) {
		velocity.y = 0.0;
		return;
	}
	if (_walk_on_grid(delta)) {
		return;
	}
	const bool still = _still() && !overlapping;
	_params->set_margin(safe_margin);
	const bool was_on_floor = _on_floor;
	_contacts.clear();
	if (was_on_floor) {
		_refresh_platform_velocity();
		_carry(_platform_velocity * delta);
	}

	const Transform3D start = get_global_transform();
	const Vector3 motion = _crowd_solve(_intended_motion(was_on_floor, delta));
	const Vector3 start_velocity = velocity;
	// A redo keeps what came before the slide: the carry's contact and the crowd
	// neighbours touched.
	const uint32_t carried_contacts = _contacts.size();
	const bool may_step = was_on_floor || force_stair_step;
	_last_wall = _on_wall ? _wall_normal : Vector3();
	_clear_contacts();
	_slide(motion, may_step, delta, false);
	if (!_settle_reused(motion, carried_contacts) && _settle()) {
		// A sweep went through something. Redo the move checking every sweep.
		_settle_reusable = false;
		set_global_transform(start);
		velocity = start_velocity;
		_contacts.resize(carried_contacts);
		_clear_contacts();
		_slide(motion, may_step, delta, true);
		// Best effort: still embedded after this, the body is left where it is and
		// the next move's recovery works on it.
		_settle();
	}
	if (_step_rise > 0.0) {
		emit_signal("stepped_up", _step_rise);
		emit_signal("stepped", _step_rise);
	}

	if (was_on_floor && !_on_floor && velocity.y <= 0.0) {
		// Announced as no more than the move's net descent. Jolt rounds a box's edges
		// by its margin, and a flat bottom that steps up with only its rim over the
		// nosing sits on the curve and reads its tilted normal. The next move follows
		// that normal as a slope, rises past the few millimetres of curve, and the
		// probe sets it back down: measured, a 0.27 m cylinder running up 0.25 m
		// treads rose 30 mm and was probed down 25 mm in one move. That move went up,
		// and is no step down.
		const double probe_drop = -_probe_floor();
		const double drop = MIN(probe_drop, start.origin.y - get_global_position().y);
		if (drop >= STEP_DOWN_SIGNAL_MIN) {
			emit_signal("stepped_down", drop);
			emit_signal("stepped", -drop);
		}
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
	_mark_rest(still);

	desired_velocity = Vector3();
	force_stair_step = false;
}

void StairsBody::_notification(int p_what) {
	if (p_what == NOTIFICATION_ENTER_TREE) {
		g_members.push_back(this);
		_space = get_world_3d()->get_space();
	} else if (p_what == NOTIFICATION_EXIT_TREE) {
		for (size_t i = 0; i < g_members.size(); i++) {
			if (g_members[i] == this) {
				g_members[i] = g_members.back();
				g_members.pop_back();
				break;
			}
		}
		// Out of this frame's snapshot too, which others read until the next one.
		if (_snap_index < s_snap.size() && s_snap[_snap_index].body == this) {
			s_snap[_snap_index].body = nullptr;
		}
		_snap_index = UINT32_MAX;
		_crowd_pending = Vector3();
	}
}

// A shape's bounds in its own frame, from its parameters. Not from get_debug_mesh:
// that builds a mesh through the RenderingServer, and a body's first move then
// waited on the GPU, 0.5-3.6 ms a body while a wave of them spawned. Returns false
// for a shape with no finite bounds, which the footprint leaves out.
bool godot::shape_bounds(const Ref<Shape3D> &p_shape, AABB &r_bounds) {
	if (const BoxShape3D *box = Object::cast_to<BoxShape3D>(p_shape.ptr())) {
		r_bounds = AABB(-box->get_size() * 0.5, box->get_size());
		return true;
	}
	if (const SphereShape3D *sphere = Object::cast_to<SphereShape3D>(p_shape.ptr())) {
		const double r = sphere->get_radius();
		r_bounds = AABB(Vector3(-r, -r, -r), Vector3(r, r, r) * 2.0);
		return true;
	}
	if (const CapsuleShape3D *capsule = Object::cast_to<CapsuleShape3D>(p_shape.ptr())) {
		const double r = capsule->get_radius();
		const double h = MAX((double)capsule->get_height(), r * 2.0);
		r_bounds = AABB(Vector3(-r, -h * 0.5, -r), Vector3(r * 2.0, h, r * 2.0));
		return true;
	}
	if (const CylinderShape3D *cylinder = Object::cast_to<CylinderShape3D>(p_shape.ptr())) {
		const double r = cylinder->get_radius();
		const double h = cylinder->get_height();
		r_bounds = AABB(Vector3(-r, -h * 0.5, -r), Vector3(r * 2.0, h, r * 2.0));
		return true;
	}
	PackedVector3Array points;
	if (const ConvexPolygonShape3D *convex = Object::cast_to<ConvexPolygonShape3D>(p_shape.ptr())) {
		points = convex->get_points();
	} else if (const ConcavePolygonShape3D *concave = Object::cast_to<ConcavePolygonShape3D>(p_shape.ptr())) {
		points = concave->get_faces();
	} else if (const HeightMapShape3D *height_map = Object::cast_to<HeightMapShape3D>(p_shape.ptr())) {
		const Vector3 size(height_map->get_map_width() - 1, 0.0, height_map->get_map_depth() - 1);
		r_bounds = AABB(Vector3(-size.x * 0.5, height_map->get_min_height(), -size.z * 0.5),
				Vector3(size.x, height_map->get_max_height() - height_map->get_min_height(), size.z));
		return true;
	}
	if (points.is_empty()) {
		return false;
	}
	r_bounds = AABB(points[0], Vector3());
	for (int64_t i = 1; i < points.size(); i++) {
		r_bounds.expand_to(points[i]);
	}
	return true;
}

// The body's shapes' combined bounds, in its own frame, as a capsule lying in the
// horizontal plane along the longer of x and z. Measured once, from the first move
// that finds shapes on the body.
void StairsBody::_measure_footprint() {
	AABB bounds;
	bool any = false;
	const PackedInt32Array owners = get_shape_owners();
	for (int64_t k = 0; k < owners.size(); k++) {
		const uint32_t owner_id = owners[k];
		if (is_shape_owner_disabled(owner_id)) {
			continue;
		}
		const Transform3D at = shape_owner_get_transform(owner_id);
		for (int i = 0; i < shape_owner_get_shape_count(owner_id); i++) {
			AABB local;
			if (!shape_bounds(shape_owner_get_shape(owner_id, i), local)) {
				continue;
			}
			const AABB box = at.xform(local);
			bounds = any ? bounds.merge(box) : box;
			any = true;
		}
	}
	// No shapes yet: measured again at the next move.
	if (!any) {
		return;
	}
	_footprint_known = true;
	const Vector3 half = bounds.size * 0.5;
	_foot_centre = bounds.get_center() * HORIZONTAL_MASK;
	_foot_bottom = bounds.position.y;
	_foot_top = bounds.position.y + bounds.size.y;
	_foot_radius = MIN(half.x, half.z);
	_foot_half_length = MAX(half.x, half.z) - _foot_radius;
	_foot_axis = half.x > half.z ? Vector3(1, 0, 0) : Vector3(0, 0, 1);
}

// This body's footprint where `xform` puts it, in the form a neighbour is kept.
StairsBody::Neighbour StairsBody::_foot_world(const Transform3D &p_xform) const {
	Neighbour n;
	n.id = get_instance_id();
	n.axis = (p_xform.basis.xform(_foot_axis) * HORIZONTAL_MASK).normalized() * _foot_half_length;
	n.centre = p_xform.xform(_foot_centre) * HORIZONTAL_MASK;
	n.radius = _foot_radius;
	n.extent = _foot_half_length + _foot_radius;
	n.bottom = p_xform.origin.y + _foot_bottom;
	n.top = p_xform.origin.y + _foot_top;
	return n;
}

// Gap between footprints `a` and `b` shifted by `a_shift` and `b_shift`, negative
// when they overlap, or +inf when they are stacked rather than side by side.
// `r_normal` points from b to a.
double StairsBody::_foot_gap(const Neighbour &p_a, const Vector3 &p_a_shift, const Neighbour &p_b, const Vector3 &p_b_shift, Vector3 &r_normal) {
	const double overlap_y = MIN(p_a.top, p_b.top) - MAX(p_a.bottom, p_b.bottom);
	if (overlap_y <= 0.5 * MIN(p_a.top - p_a.bottom, p_b.top - p_b.bottom)) {
		return INFINITY;
	}
	const Vector3 a = p_a.centre + p_a_shift;
	const Vector3 b = p_b.centre + p_b_shift;
	Vector3 on_a;
	Vector3 on_b;
	closest_on_segments(a - p_a.axis, a + p_a.axis, b - p_b.axis, b + p_b.axis, on_a, on_b);
	const Vector3 apart = on_a - on_b;
	const double distance = apart.length();
	if (distance > 1e-9) {
		r_normal = apart / distance;
	} else {
		r_normal = (a - b).length() > 1e-9 ? (a - b).normalized() : Vector3(1, 0, 0);
	}
	return distance - p_a.radius - p_b.radius;
}

// Whether footprints `a` and `b`, shifted, are surely more than `gap` apart: their
// centres are further apart than both extents and `gap` together. Answers without
// the segment test, as DetourCrowd rejects on squared distance before its square
// root.
bool StairsBody::_feet_apart(const Neighbour &p_a, const Vector3 &p_a_shift, const Neighbour &p_b, const Vector3 &p_b_shift, double p_gap) {
	const double reach = p_a.extent + p_b.extent + p_gap;
	return reach >= 0.0 && (p_a.centre + p_a_shift - p_b.centre - p_b_shift).length_squared() > reach * reach;
}

// Once per physics frame, before the first member moves. Every member is read once
// into a snapshot: footprint, layers and space, so nothing below calls the engine.
// Pairs of members that are crowd to each other and could touch this frame are found
// once through a grid, and kept as each member's neighbour list.
// Every pair that overlaps past CROWD_SLOP is then pushed back to touching, each
// taking half, over a few Jacobi passes - the separation step of DetourCrowd and of
// position-based crowds, with Box2D's slop so a still pile settles. Each
// member's push is not applied here but added to its own next move, so the move's
// sweeps carry it and it never goes into a wall.
void StairsBody::_crowd_frame() {
	const uint32_t count = g_members.size();
	const double frame_time = count > 0 ? g_members[0]->get_physics_process_delta_time() : 0.0;
	s_snap.resize(count);
	double reach = 0.0;
	for (uint32_t i = 0; i < count; i++) {
		StairsBody *member = g_members[i];
		if (!member->_footprint_known) {
			member->_measure_footprint();
		}
		CrowdSnap &snap = s_snap[i];
		snap.body = member;
		snap.foot = member->_foot_world(member->get_global_transform());
		// A push the member has not yet taken, because it skipped its move, is still
		// owed: count it as taken, and keep it for the member's next move.
		snap.foot.centre += member->_crowd_pending;
		snap.layer = member->get_collision_layer();
		snap.crowd = member->crowd_layers;
		snap.space = member->_space;
		// Reach grows by how far the member may walk this frame, at last frame's
		// speed and time scale, so two closing on each other are listed before they
		// meet.
		snap.reach = member->_foot_radius + member->_foot_half_length +
				(member->velocity * HORIZONTAL_MASK).length() * frame_time * member->_time_scale;
		snap.first = 0;
		snap.count = 0;
		member->_snap_index = i;
		reach = MAX(reach, snap.reach);
	}
	const double cell = MAX(reach * 2.0 + CROWD_LOOKAHEAD, 0.01);
	g_grid.clear();
	for (uint32_t i = 0; i < count; i++) {
		if (s_snap[i].crowd == 0) {
			continue;
		}
		const Vector3 &at = s_snap[i].foot.centre;
		g_grid[cell_key((int64_t)std::floor(at.x / cell), (int64_t)std::floor(at.z / cell))].push_back(i);
	}

	// Neighbour lists, both ways round, packed one member after another.
	s_pairs.clear();
	s_adjacent.clear();
	for (uint32_t i = 0; i < count; i++) {
		const CrowdSnap &a = s_snap[i];
		s_snap[i].first = s_adjacent.size();
		if (a.crowd == 0) {
			continue;
		}
		const int64_t cx = (int64_t)std::floor(a.foot.centre.x / cell);
		const int64_t cz = (int64_t)std::floor(a.foot.centre.z / cell);
		for (int64_t dx = -1; dx <= 1; dx++) {
			for (int64_t dz = -1; dz <= 1; dz++) {
				const auto found = g_grid.find(cell_key(cx + dx, cz + dz));
				if (found == g_grid.end()) {
					continue;
				}
				for (const uint32_t j : found->second) {
					const CrowdSnap &b = s_snap[j];
					if (j == i || a.space != b.space || (a.crowd & b.layer) == 0 || (b.crowd & a.layer) == 0) {
						continue;
					}
					const double near = a.reach + b.reach + CROWD_LOOKAHEAD;
					if ((a.foot.centre - b.foot.centre).length_squared() > near * near) {
						continue;
					}
					s_adjacent.push_back(j);
					if (j > i) {
						s_pairs.push_back({ i, j });
					}
				}
			}
		}
		s_snap[i].count = s_adjacent.size() - s_snap[i].first;
	}

	static std::vector<Vector3> shift;
	static std::vector<Vector3> delta;
	shift.assign(count, Vector3());
	for (int pass = 0; pass < CROWD_PASSES; pass++) {
		delta.assign(count, Vector3());
		bool overlapped = false;
		for (const std::pair<uint32_t, uint32_t> &pair : s_pairs) {
			if (_feet_apart(s_snap[pair.first].foot, shift[pair.first], s_snap[pair.second].foot, shift[pair.second], -CROWD_SLOP)) {
				continue;
			}
			Vector3 normal;
			const double gap = _foot_gap(s_snap[pair.first].foot, shift[pair.first], s_snap[pair.second].foot, shift[pair.second], normal);
			if (gap >= -CROWD_SLOP) {
				continue;
			}
			delta[pair.first] += normal * (-gap * 0.5);
			delta[pair.second] -= normal * (-gap * 0.5);
			overlapped = true;
		}
		if (!overlapped) {
			break;
		}
		for (uint32_t i = 0; i < count; i++) {
			shift[i] += delta[i];
		}
	}
	for (uint32_t i = 0; i < count; i++) {
		g_members[i]->_crowd_pending += shift[i];
		s_snap[i].foot.centre += shift[i];
	}
}

// This move's crowd neighbours, where they stand now plus any push they have not
// yet taken, and whether the body overlaps any of them past the slop. Brings the snapshot up to
// this physics frame first. Neighbours are read from the snapshot, which each
// member updates as it moves, so a member moved by other code during the frame is
// seen where it stood when the frame began.
bool StairsBody::_crowd_gather() {
	_neighbours.clear();
	if (crowd_layers == 0) {
		return false;
	}
	const uint64_t frame = Engine::get_singleton()->get_physics_frames();
	if (frame != g_crowd_frame) {
		g_crowd_frame = frame;
		_crowd_frame();
	}
	if (_snap_index >= s_snap.size()) {
		// Entered the tree since the snapshot: kept apart from the next frame on.
		return false;
	}
	_me = _foot_world(get_global_transform());
	const CrowdSnap &mine = s_snap[_snap_index];
	bool overlapping = false;
	for (uint32_t k = mine.first; k < mine.first + mine.count; k++) {
		const CrowdSnap &other = s_snap[s_adjacent[k]];
		if (other.body == nullptr) {
			continue;
		}
		Neighbour n = other.foot;
		Vector3 normal;
		const double gap = _foot_gap(_me, _crowd_pending, n, Vector3(), normal);
		// Stacked, not side by side. Anything nearer the pair list already bounds, by
		// how far both may walk this frame.
		if (std::isinf(gap)) {
			continue;
		}
		n.floor_y = MAX(_me.bottom, n.bottom);
		n.least_gap = gap >= -CROWD_SLOP ? MIN(gap, 0.0) : 0.0;
		overlapping = overlapping || gap < -CROWD_SLOP;
		_neighbours.push_back(n);
	}
	return overlapping || _crowd_pending != Vector3();
}

// The horizontal part of `motion`, plus the push the crowd pass left this body,
// projected out of every gathered neighbour. That stops the body walking into one,
// and never lets it go deeper into one it already overlaps within the slop, and pushes
// it out of one it overlaps past the slop:
// the position step of position-based dynamics, against neighbours held still.
// Lists the neighbours touched where the body ends, and clips velocity against them.
Vector3 StairsBody::_crowd_solve(const Vector3 &p_motion) {
	// Wedged between neighbours, a long move can be projected out of one only into
	// another, and the passes end with it still inside them. Its own motion is then
	// cut, down to none, until the passes settle; the push it owes is kept whole.
	// With no motion of its own left it takes what the passes give, settled or not,
	// as a move with none always did. The neighbours within reach of the motion it
	// gave up are the ones it is wedged against, and count as touched.
	static constexpr double SHARES[] = { 1.0, 0.5, 0.25, 0.0 };
	const Vector3 walk = p_motion * HORIZONTAL_MASK;
	Vector3 offset;
	double share = 0.0;
	for (const double tried : SHARES) {
		share = tried;
		offset = walk * share + _crowd_pending;
		if (_crowd_project(offset)) {
			break;
		}
	}
	_crowd_pending = Vector3();
	const double touch = safe_margin + walk.length() * (1.0 - share);
	for (const Neighbour &n : _neighbours) {
		if (_feet_apart(_me, offset, n, Vector3(), touch)) {
			continue;
		}
		Vector3 normal;
		const double gap = _foot_gap(_me, offset, n, Vector3(), normal);
		if (gap > touch) {
			continue;
		}
		Contact contact;
		contact.collider_id = n.id;
		contact.normal = normal;
		contact.position = _me.centre + offset - normal * (_foot_radius + MAX(gap, 0.0)) + Vector3(0, n.floor_y, 0);
		_contacts.push_back(contact);
		if (velocity.dot(normal) < 0.0) {
			velocity = velocity.slide(normal);
		}
	}
	return offset + Vector3(0, p_motion.y, 0);
}

// Projects `offset` out of the gathered neighbours, a few passes over them in turn.
// Returns whether a pass found nothing left to correct.
bool StairsBody::_crowd_project(Vector3 &r_offset) const {
	for (int pass = 0; pass < CROWD_PASSES && !_neighbours.is_empty(); pass++) {
		bool moved = false;
		for (const Neighbour &n : _neighbours) {
			if (_feet_apart(_me, r_offset, n, Vector3(), n.least_gap)) {
				continue;
			}
			Vector3 normal;
			const double gap = _foot_gap(_me, r_offset, n, Vector3(), normal);
			if (gap < n.least_gap - CROWD_SETTLED) {
				r_offset += normal * (n.least_gap - gap);
				moved = true;
			}
		}
		if (!moved) {
			return true;
		}
	}
	return _neighbours.is_empty();
}

// No motion of its own this frame: nothing horizontal, not rising, no intent and no
// forced step. Exact, as _intended_motion's test for no motion is, so a velocity
// that decays toward zero has to be snapped to it before the body can rest.
bool StairsBody::_still() const {
	return velocity * HORIZONTAL_MASK == Vector3() && velocity.y <= 0.0 &&
			desired_velocity == Vector3() && !force_stair_step;
}

// Whether this move can be skipped. Still, from where the last move left it, on
// the same static floor, unmoved, and touched by nothing but static bodies, the
// move would redo that move's checks and find what they found. The getters keep
// the last move's answers, so a floor that stops colliding without moving is not
// seen until the body moves or is moved.
bool StairsBody::_resting() {
	if (!_rest_valid || !_still()) {
		return false;
	}
	_rest_valid = get_global_transform() == _rest_transform && _shapes_unchanged() &&
			UtilityFunctions::is_instance_id_valid(_floor_id) &&
			Transform3D(physics()->body_get_state(_floor_rid, PhysicsServer3D::BODY_STATE_TRANSFORM)) == _rest_floor_transform &&
			!_touched_by_mover();
	return _rest_valid;
}

// Whether anything that could have moved into the body overlaps or touches it, by
// a shape query: cheaper than the contact test it guards, since it collects no
// contacts and does no depenetration. Something moved into a resting body, such as
// a walker that leaves the body's layer out of its own mask, has to reach the
// contact list, where the body's owner reads it: a game may shove its crowd that
// way. Static bodies, StairsBody nodes that collide with this one and its crowd
// neighbours are passed over; a StairsBody teleported into it by its owner is too.
bool StairsBody::_touched_by_mover() {
	const Ref<World3D> world = get_world_3d();
	if (world.is_null()) {
		return false;
	}
	PhysicsDirectSpaceState3D *space = world->get_direct_space_state();
	ERR_FAIL_NULL_V_MSG(space, true, "Space state is inaccessible; a still body keeps checking.");
	TypedArray<RID> exclude;
	exclude.push_back(get_rid());
	_cast_params->set_motion(Vector3());
	_cast_params->set_margin(safe_margin);
	_cast_params->set_collision_mask(get_collision_mask());
	_cast_params->set_exclude(exclude);
	const Transform3D xform = get_global_transform();
	const PackedInt32Array owners = get_shape_owners();
	for (int64_t k = 0; k < owners.size(); k++) {
		const uint32_t owner_id = owners[k];
		if (is_shape_owner_disabled(owner_id)) {
			continue;
		}
		const Transform3D at = xform * shape_owner_get_transform(owner_id);
		const int shape_count = shape_owner_get_shape_count(owner_id);
		for (int i = 0; i < shape_count; i++) {
			_cast_params->set_shape(shape_owner_get_shape(owner_id, i));
			_cast_params->set_transform(at);
			const TypedArray<Dictionary> hits = space->intersect_shape(_cast_params, REST_QUERY_MAX);
			for (int64_t h = 0; h < hits.size(); h++) {
				const Dictionary hit = hits[h];
				if (physics()->body_get_mode(RID(hit["rid"])) == PhysicsServer3D::BODY_MODE_STATIC) {
					continue;
				}
				// A StairsBody that collides with this one sweeps against it and stops at
				// its surface, and a crowd neighbour is kept out by crowd separation: neither
				// can move into it. In a pile, still bodies always touch moving neighbours,
				// and waking for those cost more than resting saved.
				const StairsBody *other = Object::cast_to<StairsBody>(Object::cast_to<Object>(hit["collider"]));
				if (other != nullptr && ((other->get_collision_mask() & get_collision_layer()) != 0 ||
												((crowd_layers & other->get_collision_layer()) != 0 && (other->crowd_layers & get_collision_layer()) != 0))) {
					continue;
				}
				return true;
			}
		}
	}
	return false;
}

// After a full move: a still body on a static floor that carries it nowhere, and
// touched by nothing that moves, may skip the next one. A conveyor is static and does carry, and a floor on
// step_ignore_layers has no RID kept, since it may move under the body.
void StairsBody::_mark_rest(bool p_still) {
	_rest_valid = p_still && _on_floor && _settle_depth <= safe_margin * EMBED_MARGINS && _floor_rid.is_valid() && _platform_velocity == Vector3() &&
			physics()->body_get_mode(_floor_rid) == PhysicsServer3D::BODY_MODE_STATIC && !_touched_by_mover();
	if (!_rest_valid) {
		return;
	}
	_rest_transform = get_global_transform();
	_rest_floor_transform = physics()->body_get_state(_floor_rid, PhysicsServer3D::BODY_STATE_TRANSFORM);
	_record_shapes();
}

// The body's shapes as the physics server has them, for _shapes_unchanged.
void StairsBody::_record_shapes() {
	const RID rid = get_rid();
	const int count = physics()->body_get_shape_count(rid);
	_rest_shapes.resize(count);
	for (int i = 0; i < count; i++) {
		_rest_shapes[i].shape = physics()->body_get_shape(rid, i);
		_rest_shapes[i].transform = physics()->body_get_shape_transform(rid, i);
	}
	_rest_disabled_owners = _disabled_owners();
	_watch_shapes();
}

// Whether the collider is as it was when the body came to rest: the same shapes,
// in the same places, on or off alike. A crouch that swaps or moves a shape shows
// here; one that resizes a shape in place is caught by _on_shape_changed.
bool StairsBody::_shapes_unchanged() {
	const RID rid = get_rid();
	const uint32_t count = physics()->body_get_shape_count(rid);
	if (count != _rest_shapes.size()) {
		return false;
	}
	for (uint32_t i = 0; i < count; i++) {
		if (physics()->body_get_shape(rid, i) != _rest_shapes[i].shape ||
				physics()->body_get_shape_transform(rid, i) != _rest_shapes[i].transform) {
			return false;
		}
	}
	return _disabled_owners() == _rest_disabled_owners;
}

// One bit per shape owner, in owner order, set when that owner is disabled. The
// server keeps no getter for a shape's disabled flag. Owners past 64 are not seen.
uint64_t StairsBody::_disabled_owners() {
	uint64_t bits = 0;
	const PackedInt32Array owners = get_shape_owners();
	for (int64_t k = 0; k < owners.size() && k < 64; k++) {
		if (is_shape_owner_disabled(owners[k])) {
			bits |= uint64_t(1) << k;
		}
	}
	return bits;
}

// Connects each of the body's shapes to _on_shape_changed, once. A shape resized in
// place keeps its RID and its place, so only its own signal says it changed.
void StairsBody::_watch_shapes() {
	const Callable on_changed = callable_mp(this, &StairsBody::_on_shape_changed);
	const PackedInt32Array owners = get_shape_owners();
	for (int64_t k = 0; k < owners.size(); k++) {
		const uint32_t owner_id = owners[k];
		for (int i = 0; i < shape_owner_get_shape_count(owner_id); i++) {
			const Ref<Shape3D> shape = shape_owner_get_shape(owner_id, i);
			if (shape.is_valid() && !shape->is_connected("changed", on_changed)) {
				shape->connect("changed", on_changed);
			}
		}
	}
}

// One of the body's shapes changed in place, such as a crouch resizing a capsule:
// the next move runs its checks.
void StairsBody::_on_shape_changed() {
	_rest_valid = false;
	_settle_reusable = false;
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
	if (_test_motion(_params)) {
		_record_contact();
	}
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
		// nothing about where the body can go. It only looks for a step, and only
		// where one can be: standing still, or against a face that intent pushes
		// into. Otherwise the motion was turned by something that is no step - a
		// crowd neighbour, or a face already slid off - and the slide's own sweep
		// meets any face along the motion. Jolt's CanWalkStairs gates its step the
		// same way, on a steep contact the body pushes into.
		const bool may_meet_step = p_motion * HORIZONTAL_MASK == Vector3() || _last_wall.dot(probe) < 0.0;
		if (may_meet_step && _intent_step(from, probe, p_motion.length())) {
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
		_record_contact();
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
		if (velocity.dot(normal) < 0.0) {
			velocity = velocity.slide(normal);
		}
		if (kind == KIND_WALL && p_may_step && (sweep * HORIZONTAL_MASK).normalized().dot(-normal) > HEAD_ON) {
			// Met nearly head-on, the slide along the face is a small fraction of the
			// remainder, and each further sweep in a crowd pressed together meets the
			// next neighbour and pays to push out of it. Stop, as CharacterBody3D does
			// under wall_min_slide_angle.
			break;
		}
		p_motion = _clip(remainder, normal, previous_normal);
		previous_normal = normal;
	}
	set_global_transform(from);
}

// A step from wherever a probe along intent meets a steep face, at most `reach`
// along it. With no motion this frame, intent is the only direction there is, and
// a face it meets is the wall the body is being held against; otherwise the face
// may be off to the side, and only the slide's own sweep records a wall. Masked
// like the step sweeps: a body on step_ignore_layers is never the step, and a step
// behind one is found through it, so a body held still against one of those does
// not list it.
bool StairsBody::_intent_step(const Transform3D &p_from, const Vector3 &p_probe, double p_reach) {
	_params->set_from(p_from);
	_params->set_motion(p_probe);
	if (!_test_motion_masked(_params)) {
		return false;
	}
	const Vector3 normal = _result->get_collision_normal(0);
	const double angle = normal.angle_to(WORLD_UP);
	if (angle <= floor_max_angle || angle >= Math::PI - floor_max_angle) {
		return false;
	}
	// Kept either way when the body is held against the face: that is a contact.
	// Otherwise it is only the step's, and goes if the step does.
	const uint32_t mark = _contacts.size();
	_record_contact();
	const bool held = Math::is_zero_approx(p_reach);
	if (held) {
		_on_wall = true;
		_wall_normal = normal;
	}
	const Vector3 travel = _clip_length(_result->get_travel(), p_reach);
	if (_try_step(p_from.translated(travel), p_probe - travel, normal)) {
		return true;
	}
	if (!held) {
		_contacts.resize(mark);
	}
	return false;
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
//
// A floor on step_ignore_layers holds the body up but never carries it. Such
// bodies are the self-driving kind, and a kinematic one that is teleported (a
// StairsBody set into place, say) reports the jump as velocity: measured, one
// moved 0.2 m in a tick read as a 12 m/s platform to the body standing on it, on
// both engines, which the carry then applied and leaving the floor kept.
void StairsBody::_record_floor(const Vector3 &p_normal, int p_index) {
	_on_floor = true;
	_floor_normal = p_normal;
	const RID rid = _result->get_collider_rid(p_index);
	if (_ignored_for_steps(rid)) {
		_floor_rid = RID();
		_floor_id = 0;
		_platform_velocity = Vector3();
		return;
	}
	_floor_rid = rid;
	_floor_id = _result->get_collider_id(p_index);
	_platform_velocity = _result->get_collider_velocity(p_index);
}

// Stands in for the post-move test where it cannot find anything new: grounded on
// a static floor, a move whose sweeps met nothing, within SETTLE_REACH of where
// the test last ran and found that floor and the body resting on it. The test's
// floor and contacts are kept, the contacts moved with the body. Unreal's
// FindFloor reuses the last floor the same way, off a static base, though only
// for a body that has not moved; Jolt's CharacterVirtual goes further and keeps
// the contacts of a query made before the move. Within the reach, a floor edge
// can come under the body unseen, so walking slowly off a ledge it overhangs the
// edge by up to SETTLE_REACH more before it drops. Past it, the test runs again.
bool StairsBody::_settle_reused(const Vector3 &p_motion, uint32_t p_slide_contacts) {
	const Vector3 origin = get_global_position();
	const Vector3 moved = origin - _settle_origin;
	if (!_settle_reusable || p_motion.y != 0.0 || moved.y != 0.0 || _step_rise > 0.0 ||
			_contacts.size() != p_slide_contacts || moved.length() > SETTLE_REACH ||
			_platform_velocity != Vector3()) {
		return false;
	}
	// What the rest skip checks too: neither the body's collider nor its floor has
	// changed, and nothing that moves touches it.
	if (!_shapes_unchanged() || !UtilityFunctions::is_instance_id_valid(_floor_id) ||
			Transform3D(physics()->body_get_state(_floor_rid, PhysicsServer3D::BODY_STATE_TRANSFORM)) != _settle_floor_transform ||
			_touched_by_mover()) {
		return false;
	}
	_on_floor = true;
	for (Contact contact : _settle_contacts) {
		contact.position += moved;
		_contacts.push_back(contact);
	}
	return true;
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
//
// Run first with step_ignore_layers out of the mask, which in a crowd pressed
// together skips depenetrating from every neighbour: see _test_motion_masked. A
// body standing on one of those finds no floor that way, and only then is the test
// run again with the whole mask. Masked, a body resting against a neighbour does not
// list it; the slide lists the neighbours it moves into. Nor does sinking into one
// redo the move: the guard is for the static geometry Jolt's filter lets a sweep
// pass through, and a body overlapping a neighbour is pushed out by the recovery
// of its next unmasked sweep, which in a crowd pressed together is every move.
//
// Keeps what it found for _settle_reused while the body rests on a static floor.
bool StairsBody::_settle() {
	const uint32_t first = _contacts.size();
	const bool embedded = _settle_masked();
	_settle_reusable = !embedded && _on_floor && _floor_rid.is_valid() && _platform_velocity == Vector3() &&
			_settle_depth <= safe_margin * EMBED_MARGINS &&
			physics()->body_get_mode(_floor_rid) == PhysicsServer3D::BODY_MODE_STATIC;
	if (_settle_reusable) {
		_settle_origin = get_global_position();
		_settle_floor_transform = physics()->body_get_state(_floor_rid, PhysicsServer3D::BODY_STATE_TRANSFORM);
		if (!_shapes_unchanged()) {
			// A new set of shapes: watched, so resizing one in place ends the reuse too.
			_record_shapes();
			_watch_shapes();
		}
		_settle_contacts.clear();
		for (uint32_t i = first; i < _contacts.size(); i++) {
			_settle_contacts.push_back(_contacts[i]);
		}
	}
	return embedded;
}

// The test itself, masked first as described above _settle.
bool StairsBody::_settle_masked() {
	if (step_ignore_layers == 0) {
		return _settle_test();
	}
	const uint32_t mark = _contacts.size();
	const uint32_t was_mask = get_collision_mask();
	set_collision_mask(was_mask & ~step_ignore_layers);
	const bool embedded = _settle_test();
	set_collision_mask(was_mask);
	if (embedded || _on_floor) {
		return embedded;
	}
	_contacts.resize(mark);
	return _settle_test();
}

// The zero-motion test itself, with whatever mask the body has now.
bool StairsBody::_settle_test() {
	_contact_params->set_margin(safe_margin);
	_contact_params->set_from(get_global_transform());
	if (!_test_motion(_contact_params)) {
		_settle_depth = 0.0;
		return false;
	}
	_settle_depth = _result->get_travel().length();
	// A redo rolls these back with the rest of the move's contacts.
	const int count = _result->get_collision_count();
	for (int i = 0; i < count; i++) {
		_record_contact(i);
	}
	if (_result->get_travel().length() > safe_margin * EMBED_MARGINS) {
		return true;
	}
	if (_on_floor) {
		return false;
	}
	int best = -1;
	double best_angle = floor_max_angle;
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
	const uint32_t mark = _contacts.size();
	bool stepped_ok = false;
	if (step_ignore_layers == 0) {
		stepped_ok = _step_sweeps(p_at, p_remainder, p_wall_normal);
	} else {
		const uint32_t was_mask = get_collision_mask();
		set_collision_mask(was_mask & ~step_ignore_layers);
		stepped_ok = _step_sweeps(p_at, p_remainder, p_wall_normal);
		set_collision_mask(was_mask);
	}
	if (!stepped_ok) {
		_contacts.resize(mark);
	}
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
	Vector3 forward = p_remainder * HORIZONTAL_MASK;
	if (forward.length() < min_step_forward) {
		forward = (-p_wall_normal * HORIZONTAL_MASK).normalized() * min_step_forward;
	}
	if (_ignored_for_steps(wall_rid) && !_blocked_behind(p_at, forward)) {
		return false;
	}

	_params->set_from(p_at);
	_params->set_motion(WORLD_UP * step_height);
	if (_test_motion(_params)) {
		_record_contact();
	}
	const double rise = _result->get_travel().y;
	if (rise < safe_margin) {
		return false;
	}
	const Transform3D raised = p_at.translated(WORLD_UP * rise);
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
	_record_contact();
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

// Whether `body` is on step_ignore_layers.
bool StairsBody::_ignored_for_steps(const RID &p_body) const {
	return step_ignore_layers != 0 && (physics()->body_get_collision_layer(p_body) & step_ignore_layers) != 0;
}

// Whether anything the step sweeps see blocks the step's forward leg at floor
// height, from where the move met a face on step_ignore_layers. Nothing there means
// nothing behind that body to climb, and the three step sweeps would land level and
// be refused: in a pile of 96 bodies, 47k of them on Godot Physics, none landing. A
// face behind it, such as a kerb under a slab lying flush with its edge, still gets
// the step. Called with those layers masked out, as the step sweeps are.
bool StairsBody::_blocked_behind(const Transform3D &p_at, const Vector3 &p_forward) {
	_params->set_from(p_at);
	_params->set_motion(p_forward);
	return _test_motion(_params);
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
		_record_contact();
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
// Masked the same way and for the same reason as _try_step. Returns the height
// change when it stepped the body down, a negative number, and 0.0 when it did
// not; the caller announces it once the mask is back.
double StairsBody::_probe_floor() {
	double drop = 0.0;
	if (step_ignore_layers == 0) {
		drop = _probe_sweep();
	} else {
		const uint32_t was_mask = get_collision_mask();
		set_collision_mask(was_mask & ~step_ignore_layers);
		drop = _probe_sweep();
		set_collision_mask(was_mask);
	}
	return drop;
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
	_record_contact();
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

Object *StairsBody::get_contact_collider(int p_index) const {
	ERR_FAIL_INDEX_V(p_index, (int)_contacts.size(), nullptr);
	return ObjectDB::get_instance(ObjectID(_contacts[p_index].collider_id));
}

uint64_t StairsBody::get_contact_collider_id(int p_index) const {
	ERR_FAIL_INDEX_V(p_index, (int)_contacts.size(), 0);
	return _contacts[p_index].collider_id;
}

Vector3 StairsBody::get_contact_normal(int p_index) const {
	ERR_FAIL_INDEX_V(p_index, (int)_contacts.size(), Vector3());
	return _contacts[p_index].normal;
}

Vector3 StairsBody::get_contact_position(int p_index) const {
	ERR_FAIL_INDEX_V(p_index, (int)_contacts.size(), Vector3());
	return _contacts[p_index].position;
}

void StairsBody::_bind_methods() {
	ClassDB::bind_method(D_METHOD("move_and_stair_step", "time_scale"), &StairsBody::move_and_stair_step, DEFVAL(1.0));
	ClassDB::bind_static_method("StairsBody", D_METHOD("is_step_surface", "body", "ignore_layers"), &StairsBody::is_step_surface, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("is_on_walk_grid"), &StairsBody::is_on_walk_grid);
	ClassDB::bind_method(D_METHOD("set_walk_grid", "grid"), &StairsBody::set_walk_grid);
	ClassDB::bind_method(D_METHOD("get_walk_grid"), &StairsBody::get_walk_grid);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "walk_grid", PROPERTY_HINT_NODE_TYPE, "StairsWalkGrid"), "set_walk_grid", "get_walk_grid");
	ClassDB::bind_method(D_METHOD("is_on_floor"), &StairsBody::is_on_floor);
	ClassDB::bind_method(D_METHOD("is_on_wall"), &StairsBody::is_on_wall);
	ClassDB::bind_method(D_METHOD("is_on_ceiling"), &StairsBody::is_on_ceiling);
	ClassDB::bind_method(D_METHOD("get_floor_normal"), &StairsBody::get_floor_normal);
	ClassDB::bind_method(D_METHOD("get_wall_normal"), &StairsBody::get_wall_normal);
	ClassDB::bind_method(D_METHOD("get_platform_velocity"), &StairsBody::get_platform_velocity);
	ClassDB::bind_method(D_METHOD("get_contact_count"), &StairsBody::get_contact_count);
	ClassDB::bind_method(D_METHOD("get_contact_collider", "index"), &StairsBody::get_contact_collider);
	ClassDB::bind_method(D_METHOD("get_contact_collider_id", "index"), &StairsBody::get_contact_collider_id);
	ClassDB::bind_method(D_METHOD("get_contact_normal", "index"), &StairsBody::get_contact_normal);
	ClassDB::bind_method(D_METHOD("get_contact_position", "index"), &StairsBody::get_contact_position);


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
	STAIRS_BIND(crowd_layers, Variant::INT, PROPERTY_HINT_LAYERS_3D_PHYSICS, "");

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

	ADD_SIGNAL(MethodInfo("stepped", PropertyInfo(Variant::FLOAT, "delta")));
	ADD_SIGNAL(MethodInfo("stepped_up", PropertyInfo(Variant::FLOAT, "rise")));
	ADD_SIGNAL(MethodInfo("stepped_down", PropertyInfo(Variant::FLOAT, "drop")));
}
