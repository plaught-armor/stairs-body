#include "stairs_walk_grid.h"
#include "stairs_geometry.h"

#include <godot_cpp/classes/animatable_body3d.hpp>
#include <godot_cpp/classes/box_shape3d.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/static_body3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <cmath>

using namespace godot;

namespace {

// Tolerance on the basis test for a box turned only about the vertical.
constexpr double UPRIGHT_EPSILON = 1e-6;
// Bins past which the index is refused rather than built: 16M bins of 2 m is a
// level 8 km across.
constexpr double BINS_MAX = double(1 << 24);
// Nodes the bake visits before giving up, far past any level's tree.
constexpr int64_t NODES_MAX = int64_t(1) << 24;

// Whether `basis` turns about the vertical only, possibly with scale.
bool upright(const Basis &p_basis) {
	const Vector3 bx = p_basis.get_column(0);
	const Vector3 by = p_basis.get_column(1);
	const Vector3 bz = p_basis.get_column(2);
	const double lx = bx.length();
	const double ly = by.length();
	const double lz = bz.length();
	if (lx < UPRIGHT_EPSILON || ly < UPRIGHT_EPSILON || lz < UPRIGHT_EPSILON) {
		return false;
	}
	return std::abs(by.y) / ly > 1.0 - UPRIGHT_EPSILON && std::abs(bx.y) / lx < UPRIGHT_EPSILON &&
			std::abs(bz.y) / lz < UPRIGHT_EPSILON && std::abs(bx.dot(bz)) < UPRIGHT_EPSILON * lx * lz;
}

} // namespace

// Rebuilds the index from the static bodies under the grid's parent, or under the
// grid itself when it has none. Call again after static geometry changes.
void StairsWalkGrid::bake() {
	_boxes.clear();
	_box_sources.clear();
	_unknown.clear();
	_bodies.clear();
	_baked = false;
	_stale = false;
	std::vector<Node *> stack;
	stack.push_back(get_parent() != nullptr ? get_parent() : this);
	for (int64_t visited = 0; !stack.empty(); visited++) {
		ERR_FAIL_COND_MSG(visited >= NODES_MAX, "StairsWalkGrid: the tree is too large to bake; bodies keep their sweeps.");
		Node *node = stack.back();
		stack.pop_back();
		StaticBody3D *body = Object::cast_to<StaticBody3D>(node);
		if (body != nullptr && Object::cast_to<AnimatableBody3D>(node) == nullptr) {
			_add_body(body);
		}
		for (int i = 0; i < node->get_child_count(); i++) {
			stack.push_back(node->get_child(i));
		}
	}
	_index();
	_box_live = (uint32_t)_boxes.size();
	// A watch left from an earlier bake is kept rather than doubled; one left on a
	// body no longer baked finds nothing to drop. The engine disconnects them all
	// when the grid is freed.
	for (const auto &[id, baked] : _bodies) {
		Object *body = ObjectDB::get_instance(id);
		const Callable watch = callable_mp(this, &StairsWalkGrid::_on_body_exiting).bind(id);
		if (body != nullptr && !body->is_connected("tree_exiting", watch)) {
			body->connect("tree_exiting", watch, CONNECT_ONE_SHOT);
		}
	}
}

// A baked body left the tree, so it has left the physics space too: its boxes and
// regions stop counting at once, by clearing their layers.
void StairsWalkGrid::_on_body_exiting(uint64_t p_id) {
	const auto it = _bodies.find(p_id);
	if (it == _bodies.end()) {
		return;
	}
	const Baked &baked = it->second;
	for (uint32_t i = baked.box_first; i < baked.box_first + baked.box_count; i++) {
		_boxes[i].layer = 0;
	}
	for (uint32_t i = baked.unknown_first; i < baked.unknown_first + baked.unknown_count; i++) {
		_unknown[i].layer = 0;
	}
	_box_live -= baked.box_count;
	_bodies.erase(it);
}

void StairsWalkGrid::_on_node_added(Node *p_node) {
	if (!_baked || _stale || Object::cast_to<StaticBody3D>(p_node) == nullptr || Object::cast_to<AnimatableBody3D>(p_node) != nullptr) {
		return;
	}
	const Node *root = get_parent() != nullptr ? get_parent() : this;
	if (root->is_ancestor_of(p_node)) {
		_mark_stale("a static body was added under it");
	}
}

void StairsWalkGrid::_mark_stale(const char *p_why) {
	if (_baked && !_stale) {
		_stale = true;
		UtilityFunctions::push_warning(vformat("StairsWalkGrid: %s; call bake() to include it.", p_why));
	}
}

// Whether the level has changed since the bake in a way the index does not
// follow. Checks every baked body's transform and layers, so it costs a pass over
// them: call it after editing the level, not every frame.
bool StairsWalkGrid::is_stale() const {
	if (_stale) {
		return true;
	}
	for (const auto &[id, baked] : _bodies) {
		const StaticBody3D *body = Object::cast_to<StaticBody3D>(ObjectDB::get_instance(id));
		if (body == nullptr || !body->is_inside_tree() || body->get_collision_layer() != baked.layer ||
				!body->get_global_transform().is_equal_approx(baked.xform)) {
			return true;
		}
	}
	return false;
}

int StairsWalkGrid::get_unknown_count() const {
	int count = 0;
	for (const Unknown &unknown : _unknown) {
		count += unknown.layer != 0 ? 1 : 0;
	}
	return count;
}

void StairsWalkGrid::set_collision_mask(uint32_t p_value) {
	if (p_value != collision_mask) {
		collision_mask = p_value;
		_mark_stale("collision_mask changed");
	}
}

void StairsWalkGrid::_notification(int p_what) {
	const Callable watch = callable_mp(this, &StairsWalkGrid::_on_node_added);
	if (p_what == NOTIFICATION_ENTER_TREE) {
		get_tree()->connect("node_added", watch);
	} else if (p_what == NOTIFICATION_EXIT_TREE) {
		get_tree()->disconnect("node_added", watch);
	}
}

// A static body's boxes, when it is on the mask and carries nothing; everything
// else about it is a region the grid does not answer for, on its own layers, so
// a body that collides with it sweeps there.
void StairsWalkGrid::_add_body(StaticBody3D *p_body) {
	const uint32_t layer = p_body->get_collision_layer();
	if (layer == 0) {
		return;
	}
	const bool carries = p_body->get_constant_linear_velocity() != Vector3() || p_body->get_constant_angular_velocity() != Vector3();
	const bool baked = (layer & collision_mask) != 0 && !carries;
	const Transform3D xform = p_body->get_global_transform();
	Baked record;
	record.box_first = (uint32_t)_boxes.size();
	record.unknown_first = (uint32_t)_unknown.size();
	record.xform = xform;
	record.layer = layer;
	record.walkable = baked;
	const PackedInt32Array owners = p_body->get_shape_owners();
	for (int64_t k = 0; k < owners.size(); k++) {
		const uint32_t owner_id = owners[k];
		if (p_body->is_shape_owner_disabled(owner_id)) {
			continue;
		}
		const Transform3D at = xform * p_body->shape_owner_get_transform(owner_id);
		for (int i = 0; i < p_body->shape_owner_get_shape_count(owner_id); i++) {
			const Ref<Shape3D> shape = p_body->shape_owner_get_shape(owner_id, i);
			const BoxShape3D *box_shape = Object::cast_to<BoxShape3D>(shape.ptr());
			if (baked && box_shape != nullptr && upright(at.basis)) {
				const Vector3 half = box_shape->get_size() * 0.5;
				const Vector3 bx = at.basis.get_column(0);
				const Vector3 by = at.basis.get_column(1);
				const Vector3 bz = at.basis.get_column(2);
				Box box;
				box.cx = at.origin.x;
				box.cz = at.origin.z;
				box.ux = bx.x / bx.length();
				box.uz = bx.z / bx.length();
				box.vx = bz.x / bz.length();
				box.vz = bz.z / bz.length();
				box.hx = half.x * bx.length();
				box.hz = half.z * bz.length();
				box.bottom = at.origin.y - half.y * by.length();
				box.top = at.origin.y + half.y * by.length();
				box.layer = layer;
				_boxes.push_back(box);
				_box_sources.push_back({ p_body->get_rid(), p_body->get_instance_id() });
				continue;
			}
			_add_unknown(shape, at, layer);
		}
	}
	record.box_count = (uint32_t)_boxes.size() - record.box_first;
	record.unknown_count = (uint32_t)_unknown.size() - record.unknown_first;
	_bodies[p_body->get_instance_id()] = record;
}

// A shape's world bounds as a region the grid does not answer for; everywhere,
// for a shape with no finite bounds such as WorldBoundaryShape3D.
void StairsWalkGrid::_add_unknown(const Ref<Shape3D> &p_shape, const Transform3D &p_at, uint32_t p_layer) {
	Unknown unknown = { -INFINITY, -INFINITY, INFINITY, INFINITY, -INFINITY, INFINITY, p_layer };
	AABB local;
	if (shape_bounds(p_shape, local)) {
		const AABB world = p_at.xform(local);
		unknown = { world.position.x, world.position.z, world.position.x + world.size.x,
			world.position.z + world.size.z, world.position.y, world.position.y + world.size.y, p_layer };
	}
	_unknown.push_back(unknown);
}

// Bins every box by the horizontal bounds it covers.
void StairsWalkGrid::_index() {
	_bin_first.clear();
	_bin_boxes.clear();
	_stamp.assign(_boxes.size(), 0);
	_query = 0;
	if (_boxes.empty()) {
		_bins_x = 0;
		_bins_z = 0;
		_baked = true;
		return;
	}
	double max_x = -INFINITY;
	double max_z = -INFINITY;
	_min_x = INFINITY;
	_min_z = INFINITY;
	for (const Box &box : _boxes) {
		const double ex = std::abs(box.ux) * box.hx + std::abs(box.vx) * box.hz;
		const double ez = std::abs(box.uz) * box.hx + std::abs(box.vz) * box.hz;
		_min_x = MIN(_min_x, box.cx - ex);
		_min_z = MIN(_min_z, box.cz - ez);
		max_x = MAX(max_x, box.cx + ex);
		max_z = MAX(max_z, box.cz + ez);
	}
	const double bins_x = std::floor((max_x - _min_x) / BIN) + 1.0;
	const double bins_z = std::floor((max_z - _min_z) / BIN) + 1.0;
	if (!(bins_x * bins_z <= BINS_MAX)) {
		// Refused, not half built: nothing is baked, so bodies keep their sweeps.
		_boxes.clear();
		_box_sources.clear();
		_bodies.clear();
		_bins_x = 0;
		_bins_z = 0;
		_baked = true;
		ERR_FAIL_MSG("StairsWalkGrid: the baked area is too large to index; bodies keep their sweeps.");
	}
	_bins_x = (int64_t)bins_x;
	_bins_z = (int64_t)bins_z;

	std::vector<uint32_t> count(_bins_x * _bins_z + 1, 0);
	auto each_bin = [&](const Box &p_box, auto &&p_visit) {
		const double ex = std::abs(p_box.ux) * p_box.hx + std::abs(p_box.vx) * p_box.hz;
		const double ez = std::abs(p_box.uz) * p_box.hx + std::abs(p_box.vz) * p_box.hz;
		const int64_t x0 = CLAMP((int64_t)std::floor((p_box.cx - ex - _min_x) / BIN), int64_t(0), _bins_x - 1);
		const int64_t x1 = CLAMP((int64_t)std::floor((p_box.cx + ex - _min_x) / BIN), int64_t(0), _bins_x - 1);
		const int64_t z0 = CLAMP((int64_t)std::floor((p_box.cz - ez - _min_z) / BIN), int64_t(0), _bins_z - 1);
		const int64_t z1 = CLAMP((int64_t)std::floor((p_box.cz + ez - _min_z) / BIN), int64_t(0), _bins_z - 1);
		for (int64_t z = z0; z <= z1; z++) {
			for (int64_t x = x0; x <= x1; x++) {
				p_visit(z * _bins_x + x);
			}
		}
	};
	for (const Box &box : _boxes) {
		each_bin(box, [&](int64_t p_bin) { count[p_bin + 1]++; });
	}
	for (size_t b = 1; b < count.size(); b++) {
		count[b] += count[b - 1];
	}
	_bin_first = count;
	_bin_boxes.resize(count.back());
	for (uint32_t i = 0; i < _boxes.size(); i++) {
		each_bin(_boxes[i], [&](int64_t p_bin) { _bin_boxes[count[p_bin]++] = i; });
	}
	_baked = true;
}

void StairsWalkGrid::gather(double p_min_x, double p_min_z, double p_max_x, double p_max_z, LocalVector<uint32_t> &r_boxes) {
	if (_bins_x == 0) {
		return;
	}
	_query++;
	if (_query == 0) {
		std::fill(_stamp.begin(), _stamp.end(), 0);
		_query = 1;
	}
	const int64_t x0 = CLAMP((int64_t)std::floor((p_min_x - _min_x) / BIN), int64_t(0), _bins_x - 1);
	const int64_t x1 = CLAMP((int64_t)std::floor((p_max_x - _min_x) / BIN), int64_t(0), _bins_x - 1);
	const int64_t z0 = CLAMP((int64_t)std::floor((p_min_z - _min_z) / BIN), int64_t(0), _bins_z - 1);
	const int64_t z1 = CLAMP((int64_t)std::floor((p_max_z - _min_z) / BIN), int64_t(0), _bins_z - 1);
	for (int64_t z = z0; z <= z1; z++) {
		for (int64_t x = x0; x <= x1; x++) {
			const int64_t bin = z * _bins_x + x;
			for (uint32_t k = _bin_first[bin]; k < _bin_first[bin + 1]; k++) {
				const uint32_t i = _bin_boxes[k];
				if (_stamp[i] != _query) {
					_stamp[i] = _query;
					r_boxes.push_back(i);
				}
			}
		}
	}
}

bool StairsWalkGrid::unanswered(double p_min_x, double p_min_z, double p_max_x, double p_max_z, double p_bottom, double p_top, uint32_t p_mask) const {
	for (const Unknown &u : _unknown) {
		if ((u.layer & p_mask) != 0 && u.min_x <= p_max_x && u.max_x >= p_min_x && u.min_z <= p_max_z && u.max_z >= p_min_z &&
				u.bottom < p_top && u.top > p_bottom) {
			return true;
		}
	}
	return false;
}

double StairsWalkGrid::gap(const Box &p_box, const Flat &p_a, const Flat &p_b, double p_radius, Flat &r_normal, Flat &r_point) {
	auto local = [&](const Flat &p_point) {
		const double dx = p_point.x - p_box.cx;
		const double dz = p_point.z - p_box.cz;
		return Flat(dx * p_box.ux + dz * p_box.uz, dx * p_box.vx + dz * p_box.vz);
	};
	const Flat a = local(p_a);
	const Flat b = local(p_b);
	r_normal = Flat();
	r_point = Flat();
	if ((std::abs(a.x) <= p_box.hx && std::abs(a.z) <= p_box.hz) || (std::abs(b.x) <= p_box.hx && std::abs(b.z) <= p_box.hz)) {
		return -p_radius;
	}
	const Flat corners[4] = {
		Flat(-p_box.hx, -p_box.hz),
		Flat(p_box.hx, -p_box.hz),
		Flat(p_box.hx, p_box.hz),
		Flat(-p_box.hx, p_box.hz),
	};
	double best = INFINITY;
	Flat apart;
	Flat nearest;
	for (int e = 0; e < 4; e++) {
		Flat on_axis;
		Flat on_edge;
		closest_on_segments(a, b, corners[e], corners[(e + 1) % 4], on_axis, on_edge);
		const double distance = (on_axis - on_edge).length();
		if (distance < best) {
			best = distance;
			apart = on_axis - on_edge;
			nearest = on_edge;
		}
	}
	if (best > 1e-9) {
		const Flat n = apart / best;
		r_normal = Flat(p_box.ux * n.x + p_box.vx * n.z, p_box.uz * n.x + p_box.vz * n.z);
		r_point = Flat(p_box.cx + p_box.ux * nearest.x + p_box.vx * nearest.z,
				p_box.cz + p_box.uz * nearest.x + p_box.vz * nearest.z);
	}
	return best - p_radius;
}

void StairsWalkGrid::_bind_methods() {
	ClassDB::bind_method(D_METHOD("bake"), &StairsWalkGrid::bake);
	ClassDB::bind_method(D_METHOD("is_baked"), &StairsWalkGrid::is_baked);
	ClassDB::bind_method(D_METHOD("is_stale"), &StairsWalkGrid::is_stale);
	ClassDB::bind_method(D_METHOD("get_box_count"), &StairsWalkGrid::get_box_count);
	ClassDB::bind_method(D_METHOD("get_unknown_count"), &StairsWalkGrid::get_unknown_count);
	ClassDB::bind_method(D_METHOD("set_collision_mask", "value"), &StairsWalkGrid::set_collision_mask);
	ClassDB::bind_method(D_METHOD("get_collision_mask"), &StairsWalkGrid::get_collision_mask);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_mask", "get_collision_mask");
}
