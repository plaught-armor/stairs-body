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

#include <utility>
#include <vector>

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
	uint32_t crowd_layers = 0;

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
	// that needs more than one, but a body pressed into a crowd touches several
	// neighbours too, and at four they crowded the floor out of the list: in a pile
	// of 96 box-shaped bodies the floor probe then ran on 91% of moves, against 28%.
	static constexpr int CONTACT_MAX = 16;
	// Depenetration past this many margins means the body is inside something rather
	// than resting on it, and _settle pushes it back out. A resting contact recovers
	// under one margin on both engines (measured 0.75 on Jolt, 0.81 on Godot Physics).
	static constexpr double EMBED_MARGINS = 4.0;
	// How far a grounded body may move on a static floor, sweeping into nothing,
	// before the post-move test runs again; see _settle_reused.
	static constexpr double SETTLE_REACH = 0.01;
	// Cosine above which the step probe counts as along the motion rather than off it.
	static constexpr double PARALLEL = 0.9999;
	// Cosine of 15 degrees, CharacterBody3D's default wall_min_slide_angle: a grounded
	// slide stops against a wall met closer to head-on than this.
	static constexpr double HEAD_ON = 0.9659258262890683;
	// Bodies the resting check's shape query lists before giving up. A resting body
	// touches its floor and perhaps a wall or two; a mover among more than this many
	// static contacts goes unseen until the body moves.
	static constexpr int REST_QUERY_MAX = 8;
	// Slack, beyond touching and beyond how far both may walk this frame, within which
	// crowd members are listed as neighbours at the start of the frame. Covers a speed
	// change of 3 m/s at 60 Hz since last frame.
	static constexpr double CROWD_LOOKAHEAD = 0.05;
	// Projection passes against the gathered neighbours.
	static constexpr int CROWD_PASSES = 4;
	// Overlap between crowd footprints that separation leaves alone, in metres; deeper
	// overlap is still pushed all the way back to touching. Box2D's b2_linearSlop, 5 mm,
	// for the same reason: resolved to touching every frame, a still pile was nudged
	// forever and its bodies almost never rested (4-7% of still samples in a
	// pile of 96, 63-69% with the slop). Pushing deep overlap only back to the slop
	// instead held pairs 5 mm in for many frames and rested only 17-27%.
	static constexpr double CROWD_SLOP = 0.005;

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
	// The steep face the last move ended against, or zero; see _slide.
	Vector3 _last_wall;
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

	// Crowd separation: other StairsBody nodes on crowd_layers are pushed out of
	// analytically rather than swept against. The footprint is a capsule in the
	// horizontal plane, in the body's own frame, measured from its shapes once.
	bool _footprint_known = false;
	double _foot_radius = 0.0;
	double _foot_half_length = 0.0;
	Vector3 _foot_axis;
	Vector3 _foot_centre;
	double _foot_bottom = 0.0;
	double _foot_top = 0.0;
	RID _space;
	// This move's crowd neighbours, frozen where they stood when it began.
	struct Neighbour {
		uint64_t id = 0;
		Vector3 centre;
		Vector3 axis;
		double radius = 0.0;
		double floor_y = 0.0;
		double bottom = 0.0;
		double top = 0.0;
		// The gap this move may not go below: where the neighbour was met if that is
		// within the slop, else touching. See _crowd_solve.
		double least_gap = 0.0;
	};
	LocalVector<Neighbour> _neighbours;
	// This body's own footprint in world space, as of the start of the move.
	Neighbour _me;
	// The crowd pass's push for this body, taken by its next move.
	Vector3 _crowd_pending;
	// This body's place in the crowd snapshot, or UINT32_MAX when not in it.
	uint32_t _snap_index = UINT32_MAX;
	// One member as the crowd pass read it at the start of the physics frame, and
	// where its neighbours start in s_adjacent.
	struct CrowdSnap {
		StairsBody *body = nullptr;
		Neighbour foot;
		uint32_t layer = 0;
		uint32_t crowd = 0;
		RID space;
		double reach = 0.0;
		uint32_t first = 0;
		uint32_t count = 0;
	};
	static std::vector<CrowdSnap> s_snap;
	static std::vector<std::pair<uint32_t, uint32_t>> s_pairs;
	static std::vector<uint32_t> s_adjacent;

	// A still body on a still, static floor skips its checks until something about it
	// changes; see _resting. Where it came to rest, and where its floor was then.
	bool _rest_valid = false;
	Transform3D _rest_transform;
	Transform3D _rest_floor_transform;
	// The collider as the body came to rest: each shape on the server and where it
	// sits, and which shape owners were off. A shape changed in place announces itself
	// instead, through its changed signal; see _watch_shapes.
	struct RestShape {
		RID shape;
		Transform3D transform;
	};
	LocalVector<RestShape> _rest_shapes;
	uint64_t _rest_disabled_owners = 0;
	// How far the last settle test's recovery moved the body. Past EMBED_MARGINS of
	// them the body is inside something, not resting on it, and does not rest.
	double _settle_depth = 0.0;
	// What the last post-move test found, while it may stand in for the next ones:
	// where the body was, and the contacts it listed. See _settle_reused.
	bool _settle_reusable = false;
	Vector3 _settle_origin;
	Transform3D _settle_floor_transform;
	LocalVector<Contact> _settle_contacts;

	// Where a successful step left the body, and how far it rose. Written by _step_sweeps;
	// the rise is announced once the move is final, since a re-slide can redo the step.
	Transform3D _step_to;
	double _step_rise = 0.0;

	void _clear_contacts();
	void _measure_footprint();
	static void _crowd_frame();
	static double _foot_gap(const Neighbour &p_a, const Vector3 &p_a_shift, const Neighbour &p_b, const Vector3 &p_b_shift, Vector3 &r_normal);
	Neighbour _foot_world(const Transform3D &p_xform) const;
	bool _crowd_gather();
	Vector3 _crowd_solve(const Vector3 &p_motion);
	bool _still() const;
	bool _resting();
	bool _touched_by_mover();
	void _mark_rest(bool p_still);
	bool _shapes_unchanged();
	uint64_t _disabled_owners();
	void _watch_shapes();
	void _on_shape_changed();
	double _step_down_reach() const;
	Vector3 _intended_motion(bool p_was_on_floor, double p_delta) const;
	void _refresh_platform_velocity();
	void _carry(const Vector3 &p_motion);
	void _slide(Vector3 p_motion, bool p_may_step, double p_delta, bool p_verify);
	bool _intent_step(const Transform3D &p_from, const Vector3 &p_probe, double p_reach);
	Kind _classify(const Vector3 &p_normal);
	void _record_floor(const Vector3 &p_normal, int p_index = 0);
	bool _settle_reused(const Vector3 &p_motion, uint32_t p_slide_contacts);
	bool _settle();
	bool _settle_masked();
	void _record_shapes();
	bool _settle_test();
	double _unblocked_fraction(const Transform3D &p_from, const Vector3 &p_motion);
	static Vector3 _clip(const Vector3 &p_remainder, const Vector3 &p_normal, const Vector3 &p_previous_normal);
	static Vector3 _clip_length(const Vector3 &p_v, double p_max_length);
	Vector3 _step_probe(const Vector3 &p_motion, bool p_may_step, double p_delta) const;
	bool _try_step(const Transform3D &p_at, const Vector3 &p_remainder, const Vector3 &p_wall_normal);
	bool _step_sweeps(const Transform3D &p_at, const Vector3 &p_remainder, const Vector3 &p_wall_normal);
	Transform3D _step_forward(Transform3D p_from, const Vector3 &p_forward);
	bool _ignored_for_steps(const RID &p_body) const;
	bool _blocked_behind(const Transform3D &p_at, const Vector3 &p_forward);
	bool _refused_here(const Vector3 &p_origin, const Vector3 &p_normal, const RID &p_rid) const;
	void _remember_refusal(const Vector3 &p_origin, const Vector3 &p_normal, const RID &p_rid);
	double _probe_floor();
	double _probe_sweep();
	bool _probe_off_corner(const Vector3 &p_normal, double p_drop);
	bool _flat_bottomed();
	bool _test_motion(const Ref<PhysicsTestMotionParameters3D> &p_params);
	bool _test_motion_masked(const Ref<PhysicsTestMotionParameters3D> &p_params);
	void _record_contact(int p_index = 0);

protected:
	static void _bind_methods();
	void _notification(int p_what);

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
	void set_crowd_layers(uint32_t p_value) { crowd_layers = p_value; }
	uint32_t get_crowd_layers() const { return crowd_layers; }
	void set_velocity(const Vector3 &p_value) { velocity = p_value; }
	Vector3 get_velocity() const { return velocity; }
	void set_desired_velocity(const Vector3 &p_value) { desired_velocity = p_value; }
	Vector3 get_desired_velocity() const { return desired_velocity; }
	void set_force_stair_step(bool p_value) { force_stair_step = p_value; }
	bool get_force_stair_step() const { return force_stair_step; }
};

} // namespace godot
