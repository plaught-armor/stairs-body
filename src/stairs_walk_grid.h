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

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/templates/local_vector.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <unordered_set>
#include <vector>

namespace godot {

class StairsWalkGrid : public Node3D {
	GDCLASS(StairsWalkGrid, Node3D)

public:
	// A baked box: its centre and half extents on the horizontal plane along its own
	// axes u and v, and the heights of its bottom and top faces.
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
	std::vector<Box> _boxes;
	std::vector<Unknown> _unknown;
	std::unordered_set<uint64_t> _colliders;
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

	void _add_body(class StaticBody3D *p_body);
	void _add_unknown(const Ref<Shape3D> &p_shape, const Transform3D &p_at, uint32_t p_layer);
	void _index();

protected:
	static void _bind_methods();

public:
	void bake();
	bool is_baked() const { return _baked; }
	int get_box_count() const { return (int)_boxes.size(); }
	int get_unknown_count() const { return (int)_unknown.size(); }

	const Box &box(uint32_t p_index) const { return _boxes[p_index]; }
	// Appends the boxes that may overlap the given horizontal bounds.
	void gather(double p_min_x, double p_min_z, double p_max_x, double p_max_z, LocalVector<uint32_t> &r_boxes);
	// Whether a region the grid does not answer for, on a layer in `p_mask`, meets
	// the given bounds.
	bool unanswered(double p_min_x, double p_min_z, double p_max_x, double p_max_z, double p_bottom, double p_top, uint32_t p_mask) const;
	// Whether the collider with this instance id was baked.
	bool bakes(uint64_t p_collider_id) const { return _colliders.count(p_collider_id) != 0; }
	// Horizontal gap between box `p_box` and the capsule from `p_a` to `p_b` of radius
	// `p_radius`; negative or zero when they overlap. `r_normal` points from the box
	// to the capsule, and `r_point` is the nearest point of the box, at y = 0; both
	// are zero when the capsule's axis is inside the box.
	static double gap(const Box &p_box, const Vector3 &p_a, const Vector3 &p_b, double p_radius, Vector3 &r_normal, Vector3 &r_point);

	void set_collision_mask(uint32_t p_value) { collision_mask = p_value; }
	uint32_t get_collision_mask() const { return collision_mask; }
};

} // namespace godot
