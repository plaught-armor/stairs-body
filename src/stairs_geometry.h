#pragma once

// Geometry shared by StairsBody and StairsWalkGrid.

#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// A point or direction on the horizontal plane. Every horizontal quantity the
// crowd and the walk grid work with has y = 0, so it is kept as x and z only, in
// Vector3's precision and with its arithmetic, term for term: a result rounds
// exactly as the Vector3 computation it replaces did.
struct Flat {
	real_t x = 0;
	real_t z = 0;

	constexpr Flat() = default;
	constexpr Flat(real_t p_x, real_t p_z) :
			x(p_x), z(p_z) {}
	constexpr explicit Flat(const Vector3 &p_v) :
			x(p_v.x), z(p_v.z) {}

	constexpr Vector3 xyz(real_t p_y = 0) const { return Vector3(x, p_y, z); }
	constexpr Flat operator+(const Flat &p_v) const { return Flat(x + p_v.x, z + p_v.z); }
	constexpr Flat operator-(const Flat &p_v) const { return Flat(x - p_v.x, z - p_v.z); }
	constexpr Flat operator-() const { return Flat(-x, -z); }
	constexpr Flat operator*(real_t p_s) const { return Flat(x * p_s, z * p_s); }
	constexpr Flat operator/(real_t p_s) const { return Flat(x / p_s, z / p_s); }
	constexpr Flat &operator+=(const Flat &p_v) {
		x += p_v.x;
		z += p_v.z;
		return *this;
	}
	constexpr Flat &operator-=(const Flat &p_v) {
		x -= p_v.x;
		z -= p_v.z;
		return *this;
	}
	constexpr bool operator==(const Flat &p_v) const { return x == p_v.x && z == p_v.z; }
	constexpr bool operator!=(const Flat &p_v) const { return !(*this == p_v); }
	constexpr real_t dot(const Flat &p_v) const { return x * p_v.x + z * p_v.z; }
	constexpr real_t length_squared() const { return x * x + z * z; }
	// Along a plane of unit normal `p_normal`, as Vector3::slide, less its debug
	// check that the normal is unit length.
	constexpr Flat slide(const Flat &p_normal) const { return *this - p_normal * dot(p_normal); }
	real_t length() const { return Math::sqrt(x * x + z * z); }
	// Unit length, or zero for a zero or non-finite vector, as Vector3::normalized.
	Flat normalized() const {
		if (!Math::is_finite(x) || !Math::is_finite(z)) {
			return Flat();
		}
		const real_t l = length_squared();
		if (l == 0) {
			return Flat();
		}
		const real_t root = Math::sqrt(l);
		return Flat(x / root, z / root);
	}
};

// Closest points between segments p1-q1 and p2-q2 (Ericson, Real-Time Collision
// Detection, 5.1.9).
inline void closest_on_segments(const Flat &p1, const Flat &q1, const Flat &p2, const Flat &q2, Flat &r_c1, Flat &r_c2) {
	const Flat d1 = q1 - p1;
	const Flat d2 = q2 - p2;
	const Flat r = p1 - p2;
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
