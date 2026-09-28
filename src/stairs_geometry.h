#pragma once

// Geometry shared by StairsBody and StairsWalkGrid.

#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// Closest points between segments p1-q1 and p2-q2, all with y = 0 (Ericson,
// Real-Time Collision Detection, 5.1.9).
inline void closest_on_segments(const Vector3 &p1, const Vector3 &q1, const Vector3 &p2, const Vector3 &q2, Vector3 &r_c1, Vector3 &r_c2) {
	const Vector3 d1 = q1 - p1;
	const Vector3 d2 = q2 - p2;
	const Vector3 r = p1 - p2;
	const double a = d1.dot(d1);
	const double e = d2.dot(d2);
	const double f = d2.dot(r);
	double s = 0.0;
	double t = 0.0;
	if (a <= 1e-12 && e <= 1e-12) {
		r_c1 = p1;
		r_c2 = p2;
		return;
	}
	if (a <= 1e-12) {
		t = CLAMP(f / e, 0.0, 1.0);
	} else {
		const double c = d1.dot(r);
		if (e <= 1e-12) {
			s = CLAMP(-c / a, 0.0, 1.0);
		} else {
			const double b = d1.dot(d2);
			const double denom = a * e - b * b;
			s = denom > 1e-12 ? CLAMP((b * f - c * e) / denom, 0.0, 1.0) : 0.0;
			t = (b * s + f) / e;
			if (t < 0.0) {
				t = 0.0;
				s = CLAMP(-c / a, 0.0, 1.0);
			} else if (t > 1.0) {
				t = 1.0;
				s = CLAMP((b - c) / a, 0.0, 1.0);
			}
		}
	}
	r_c1 = p1 + d1 * s;
	r_c2 = p2 + d2 * t;
}

// A shape's bounds in its own frame, from its parameters. Returns false for a
// shape with no finite bounds.
bool shape_bounds(const Ref<Shape3D> &p_shape, AABB &r_bounds);

} // namespace godot
