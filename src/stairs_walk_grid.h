#pragma once

// The static boxes of a level, indexed for StairsBody's walk mode: a body given a
// walk grid moves over these boxes analytically, with no physics query, while it
// walks on them, and falls back to its sweeps where the grid cannot answer.
//
// Baked from the StaticBody3D nodes under the grid's parent. Boxes turned only
// about the vertical, on a layer in collision_mask, are baked. Every other static
// shape there - another shape, a tilted box, a body off the mask, a conveyor - is
// kept as a region the grid does not answer for. Bodies that move
// (AnimatableBody3D, RigidBody3D, CharacterBody3D) are not baked and are not seen
// by a body walking on the grid. Main thread only.
//
// Bodies that may move - every PhysicsBody3D under the same parent except plain
// static bodies and StairsBody nodes - are tracked instead: their bounds are read
// once per physics frame, and a grid move that could reach one is swept. Another
// StairsBody is seen only through crowd separation.
//
// A baked body that leaves the tree is dropped from the index on the spot. A
// static body added under the grid's parent, a change of collision_mask, and a
// baked body moved or given other layers leave the index stale until bake() is
// called again; is_stale() says so.

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/templates/local_vector.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "stairs_geometry.h"

#include <cmath>
#include <unordered_map>
#include <vector>

namespace godot {

class StairsWalkGrid : public Node3D {
	GDCLASS(StairsWalkGrid, Node3D)

public:
	// A baked box: its centre and half extents on the horizontal plane along its own
	// axes u and v, the heights of its bottom and top faces, and its body's layers.
	// Only what the walk's gap tests read; the body it came from is in BoxSource.
	struct Box {
		double cx = 0.0;
		double cz = 0.0;
		double ux = 1.0;
		double uz = 0.0;
		double vx = 0.0;
		double vz = 1.0;
		double hx = 0.0;
		double hz = 0.0;
		double bottom = 0.0;
		double top = 0.0;
		uint32_t layer = 0;
	};

	// The body a baked box came from, read only where a walk ends on or against it.
	struct BoxSource {
		RID rid;
		uint64_t id = 0;
	};

	// A region the grid does not answer for, as world bounds.
	struct Unknown {
		double min_x = 0.0;
		double min_z = 0.0;
		double max_x = 0.0;
		double max_z = 0.0;
		double bottom = 0.0;
		double top = 0.0;
		uint32_t layer = 0;
	};

	uint32_t collision_mask = 1;

private:
	// Width of an index bin, in metres.
	static constexpr double BIN = 2.0;

	bool _baked = false;
	// Inside the tree, so the snapshot and node_added keep the tracked bodies current.
	bool _watching = false;
	// What was baked of one static body: its boxes and regions, which _add_body
	// appends contiguously, and what it was baked with.
	struct Baked {
		uint32_t box_first = 0;
		uint32_t box_count = 0;
		uint32_t unknown_first = 0;
		uint32_t unknown_count = 0;
		Transform3D xform;
		uint32_t layer = 0;
		bool walkable = false;
	};

	bool _stale = false;
	std::vector<Box> _boxes;
	// Parallel to _boxes.
	std::vector<BoxSource> _box_sources;
	std::vector<Unknown> _unknown;
	std::unordered_map<uint64_t, Baked> _bodies;
	uint32_t _box_live = 0;
	double _min_x = 0.0;
	double _min_z = 0.0;
	int64_t _bins_x = 0;
	int64_t _bins_z = 0;
	// Box indices by bin, packed: bin b's boxes are _bin_boxes[_bin_first[b]] up to
	// _bin_boxes[_bin_first[b + 1]].
	std::vector<uint32_t> _bin_first;
	std::vector<uint32_t> _bin_boxes;
	// Per box, the last query that listed it, so a box in several bins is listed once.
	std::vector<uint32_t> _stamp;
	uint32_t _query = 0;

	// Bodies that may move, as the physics frame's snapshot read them: world bounds
	// grown by how far each moved since the snapshot before, layers, and whether
	// each is a sleeping RigidBody3D, one array per field for the snapshot and the
	// scan in mover_near. Swap-removed; the cold rest is in _mover_sources at the
	// same index.
	std::vector<float> _mover_min_x;
	std::vector<float> _mover_min_y;
	std::vector<float> _mover_min_z;
	std::vector<float> _mover_max_x;
	std::vector<float> _mover_max_y;
	std::vector<float> _mover_max_z;
	std::vector<uint32_t> _mover_layer;
	// A sleeping RigidBody3D does not move until it wakes, so it is not read unless
	// it is frozen.
	std::vector<uint8_t> _mover_asleep;
	// A tracked body: its bounds in its own frame, from its shapes, the distance of
	// their farthest corner from its origin, and where the last snapshot found it.
	// The pointers are used only after the id is found live, and spare the
	// snapshot the binding lookup per body. `rigid` is null unless it is a
	// RigidBody3D.
	struct MoverSource {
		uint64_t id = 0;
		class PhysicsBody3D *body = nullptr;
		class RigidBody3D *rigid = nullptr;
		AABB local;
		double local_reach = 0.0;
		bool local_known = false;
		Transform3D last_xform;
	};
	std::vector<MoverSource> _mover_sources;
	// Slot by instance id, touched only when a body is added or leaves.
	std::unordered_map<uint64_t, uint32_t> _mover_slots;
	// Bodies added since the last read, by instance id. A body is added to the tree
	// before its spawner places it, so it is first read at the next query or
	// snapshot, where it has been put.
	std::vector<uint64_t> _mover_pending;
	// The union of every read body's bounds, so a move far from all of them is
	// answered with one test; min above max while there is none.
	float _union_min_x = INFINITY;
	float _union_min_y = INFINITY;
	float _union_min_z = INFINITY;
	float _union_max_x = -INFINITY;
	float _union_max_y = -INFINITY;
	float _union_max_z = -INFINITY;

	void _add_body(class StaticBody3D *p_body);
	void _add_unknown(const Ref<Shape3D> &p_shape, const Transform3D &p_at, uint32_t p_layer);
	void _track_movers();
	void _add_mover(class PhysicsBody3D *p_body);
	void _on_mover_exiting(uint64_t p_id);
	void _on_mover_sleep_changed(uint64_t p_id);
	void _read_mover(uint32_t p_slot, bool p_first);
	void _merge_union(uint32_t p_slot);
	void _read_pending();
	void _on_physics_frame();
	void _index();
	void _on_body_exiting(uint64_t p_id);
	void _on_node_added(Node *p_node);
	void _mark_stale(const char *p_why);

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	void bake();
	bool is_baked() const { return _baked; }
	bool is_stale() const;
	int get_box_count() const { return (int)_box_live; }
	int get_unknown_count() const;
	int get_mover_count() const { return (int)_mover_sources.size(); }

	const Box &box(uint32_t p_index) const { return _boxes[p_index]; }
	const BoxSource &source(uint32_t p_index) const { return _box_sources[p_index]; }
	// Appends the boxes that may overlap the given horizontal bounds.
	void gather(double p_min_x, double p_min_z, double p_max_x, double p_max_z, LocalVector<uint32_t> &r_boxes);
	// Whether a region the grid does not answer for, on a layer in `p_mask`, meets
	// the given bounds.
	bool unanswered(double p_min_x, double p_min_z, double p_max_x, double p_max_z, double p_bottom, double p_top, uint32_t p_mask) const;
	// Whether a tracked moving body on a layer in `p_mask` meets the given bounds, as
	// the physics frame's snapshot found it, or as it stands for one added since.
	bool mover_near(double p_min_x, double p_min_z, double p_max_x, double p_max_z, double p_bottom, double p_top, uint32_t p_mask);
	// Whether the collider with this instance id was baked.
	bool bakes(uint64_t p_collider_id) const {
		const auto it = _bodies.find(p_collider_id);
		return it != _bodies.end() && it->second.walkable;
	}
	// Horizontal gap between box `p_box` and the capsule from `p_a` to `p_b` of radius
	// `p_radius`; negative or zero when they overlap. `r_normal` points from the box
	// to the capsule, and `r_point` is the nearest point of the box; both are zero
	// when the capsule's axis is inside the box.
	static double gap(const Box &p_box, const Flat &p_a, const Flat &p_b, double p_radius, Flat &r_normal, Flat &r_point);

	void set_collision_mask(uint32_t p_value);
	uint32_t get_collision_mask() const { return collision_mask; }
};

} // namespace godot
