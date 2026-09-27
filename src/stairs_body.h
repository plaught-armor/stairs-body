#pragma once

// Kinematic character body with stair stepping built into its own move, rather
// than wrapped around CharacterBody3D::move_and_slide, so a frame pays for one
// set of sweeps instead of two.
//
// Replaces move_and_slide entirely, so none of CharacterBody3D's API exists here.
// The getters keep its names where no native method is in the way.
//
// Queries per frame, the budget this class is built around:
//   walking on flat ground   2   (the move sweep, the contact test)
//   pressed into a wall      2   (the same two; the step attempt is cached)
//   intent off the motion   +1   (a sweep along intent, which only looks for a step)
//   climbing a step          5   (move sweep, up, forward, down, contact test)
//   leaving a floor         +1   (the floor probe, only where contact is lost)
//   on a moving platform    +1   (the carry, as its own sweep)
//
// Assumes world up is +Y.
//
// Ported from the GDScript StairsBody, kept at tag `gdscript-final`. Member
// and method names are unchanged from it, so the two read side by side. The
// user-facing reference is doc_classes/StairsBody.xml.

#include <godot_cpp/classes/animatable_body3d.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/physics_shape_query_parameters3d.hpp>
#include <godot_cpp/classes/physics_test_motion_parameters3d.hpp>
#include <godot_cpp/classes/physics_test_motion_result3d.hpp>
#include <godot_cpp/templates/local_vector.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class StairsBody : public AnimatableBody3D {
	GDCLASS(StairsBody, AnimatableBody3D)

public:
	// Exported settings; each is documented in doc_classes/StairsBody.xml.
	double step_height = 0.33;
	double step_down_height = -1.0;
	double min_step_forward = 0.02;
	int step_slide_iterations = 4;
	double floor_max_angle = Math::PI / 4.0;
	int max_slides = 4;
	double safe_margin = 0.001;
	uint32_t step_ignore_layers = 0;

	Vector3 velocity;
	Vector3 desired_velocity;
	bool force_stair_step = false;

private:
	// Class scope, so lookup finds these before namespace godot's own names:
	// godot::HORIZONTAL is an Orientation enumerator, and a file-scope HORIZONTAL
	// lost to it silently, multiplying every horizontal projection by zero.
	static constexpr Vector3 WORLD_UP = Vector3(0, 1, 0);
	static constexpr Vector3 HORIZONTAL_MASK = Vector3(1, 0, 1);
	// Smallest drop the floor probe reports as a step down rather than as keeping
	// contact with the floor it was already on.
	static constexpr double STEP_DOWN_SIGNAL_MIN = 0.01;
	// Contacts the floor-contact check reads. A wall and a floor at once is the case
	// that needs more than one; four covers a corner.
	static constexpr int CONTACT_MAX = 4;
	// Depenetration past this many margins means the body is inside something rather
	// than resting on it, and _settle pushes it back out. A resting contact recovers
	// under one margin on both engines (measured 0.75 on Jolt, 0.81 on Godot Physics).
	static constexpr double EMBED_MARGINS = 4.0;
	// Cosine above which the step probe counts as along the motion rather than off it.
	static constexpr double PARALLEL = 0.9999;
	// Cosine of 15 degrees, CharacterBody3D's default wall_min_slide_angle: a grounded
	// slide stops against a wall met closer to head-on than this.
	static constexpr double HEAD_ON = 0.9659258262890683;

	// One contact the last move met; see _record_contact for which ones count.
	struct Contact {
		uint64_t collider_id = 0;
		Vector3 normal;
		Vector3 position;
	};

	enum Kind {
		KIND_FLOOR,
		KIND_WALL,
		KIND_CEILING,
	};

	Ref<PhysicsTestMotionParameters3D> _params;
	Ref<PhysicsTestMotionResult3D> _result;
	// The floor-contact check's own parameters, so its zero motion, reported recovery
	// contacts and wider collision count never leak into the sweeps above.
	Ref<PhysicsTestMotionParameters3D> _contact_params;
	// Shape casts that check a sweep reporting no collision, in the rare re-slide.
	Ref<PhysicsShapeQueryParameters3D> _cast_params;

	// Contact state from the last move.
	bool _on_floor = false;
	bool _on_wall = false;
	bool _on_ceiling = false;
	Vector3 _floor_normal = Vector3(0, 1, 0);
	Vector3 _wall_normal;
	RID _floor_rid;
	// The floor's object, which says whether it still exists: a freed body's RID stays
	// non-zero, and the physics server reads it as static. Assumes every collider is
	// a node; a body made straight on the server has id 0 and reads as freed.
	uint64_t _floor_id = 0;
	Vector3 _platform_velocity;
	// Every contact of the last move, in the order met. Cleared, never shrunk, so a
	// warmed-up body appends without allocating.
	LocalVector<Contact> _contacts;

	// The last step attempt that a wall refused, so pressing into the same wall from
	// the same spot does not pay for the up and forward sweeps every frame. Only
	// static colliders are cached: anything that moves can turn into a step.
	bool _refused_valid = false;
	Vector3 _refused_at;
	Vector3 _refused_normal;
	RID _refused_rid;
	double _refused_height = 0.0;

	// Where a successful step left the body, and how far it rose. Written by _step_sweeps;
	// the rise is announced once the move is final, since a re-slide can redo the step.
	Transform3D _step_to;
	double _step_rise = 0.0;

	void _clear_contacts();
	double _step_down_reach() const;
	Vector3 _intended_motion(bool p_was_on_floor, double p_delta) const;
	void _refresh_platform_velocity();
	void _carry(const Vector3 &p_motion);
	void _slide(Vector3 p_motion, bool p_may_step, double p_delta, bool p_verify);
	bool _intent_step(const Transform3D &p_from, const Vector3 &p_probe, double p_reach);
	Kind _classify(const Vector3 &p_normal);
	void _record_floor(const Vector3 &p_normal, int p_index = 0);
	bool _settle();
	double _unblocked_fraction(const Transform3D &p_from, const Vector3 &p_motion);
	static Vector3 _clip(const Vector3 &p_remainder, const Vector3 &p_normal, const Vector3 &p_previous_normal);
	static Vector3 _clip_length(const Vector3 &p_v, double p_max_length);
	Vector3 _step_probe(const Vector3 &p_motion, bool p_may_step, double p_delta) const;
	bool _try_step(const Transform3D &p_at, const Vector3 &p_remainder, const Vector3 &p_wall_normal);
	bool _step_sweeps(const Transform3D &p_at, const Vector3 &p_remainder, const Vector3 &p_wall_normal);
	Transform3D _step_forward(Transform3D p_from, const Vector3 &p_forward);
	bool _refused_here(const Vector3 &p_origin, const Vector3 &p_normal, const RID &p_rid) const;
	void _remember_refusal(const Vector3 &p_origin, const Vector3 &p_normal, const RID &p_rid);
	double _probe_floor();
	double _probe_sweep();
	bool _probe_off_corner(const Vector3 &p_normal, double p_drop);
	bool _flat_bottomed();
	bool _test_motion(const Ref<PhysicsTestMotionParameters3D> &p_params);
	void _record_contact(int p_index = 0);

protected:
	static void _bind_methods();

public:
	StairsBody();

	void move_and_stair_step();
	static bool is_step_surface(const RID &p_body, uint32_t p_ignore_layers = 0);

	bool is_on_floor() const { return _on_floor; }
	bool is_on_wall() const { return _on_wall; }
	bool is_on_ceiling() const { return _on_ceiling; }
	Vector3 get_floor_normal() const { return _floor_normal; }
	Vector3 get_wall_normal() const { return _wall_normal; }
	Vector3 get_platform_velocity() const { return _platform_velocity; }
	int get_contact_count() const { return (int)_contacts.size(); }
	Object *get_contact_collider(int p_index) const;
	uint64_t get_contact_collider_id(int p_index) const;
	Vector3 get_contact_normal(int p_index) const;
	Vector3 get_contact_position(int p_index) const;

	void set_step_height(double p_value) { step_height = p_value; }
	double get_step_height() const { return step_height; }
	void set_step_down_height(double p_value) { step_down_height = p_value; }
	double get_step_down_height() const { return step_down_height; }
	void set_min_step_forward(double p_value) { min_step_forward = p_value; }
	double get_min_step_forward() const { return min_step_forward; }
	void set_step_slide_iterations(int p_value) { step_slide_iterations = p_value; }
	int get_step_slide_iterations() const { return step_slide_iterations; }
	void set_floor_max_angle(double p_value) { floor_max_angle = p_value; }
	double get_floor_max_angle() const { return floor_max_angle; }
	void set_max_slides(int p_value) { max_slides = p_value; }
	int get_max_slides() const { return max_slides; }
	void set_safe_margin(double p_value) { safe_margin = p_value; }
	double get_safe_margin() const { return safe_margin; }
	void set_step_ignore_layers(uint32_t p_value) { step_ignore_layers = p_value; }
	uint32_t get_step_ignore_layers() const { return step_ignore_layers; }
	void set_velocity(const Vector3 &p_value) { velocity = p_value; }
	Vector3 get_velocity() const { return velocity; }
	void set_desired_velocity(const Vector3 &p_value) { desired_velocity = p_value; }
	Vector3 get_desired_velocity() const { return desired_velocity; }
	void set_force_stair_step(bool p_value) { force_stair_step = p_value; }
	bool get_force_stair_step() const { return force_stair_step; }
};

} // namespace godot
