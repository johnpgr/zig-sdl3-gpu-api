const std = @import("std");

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn magnitude(self: Vec3) f32 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    pub fn normalize(self: Vec3) Vec3 {
        const mag = self.magnitude();
        if (mag == 0) {
            return Vec3.init(0, 0, 0);
        } else if (mag == 1) {
            return self;
        }
        return Vec3.init(self.x / mag, self.y / mag, self.z / mag);
    }

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return Vec3.init(self.x + other.x, self.y + other.y, self.z + other.z);
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return Vec3.init(self.x - other.x, self.y - other.y, self.z - other.z);
    }

    pub fn scale(self: Vec3, val: f32) Vec3 {
        return Vec3.init(self.x * val, self.y * val, self.z * val);
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub fn cross(self: Vec3, other: Vec3) Vec3 {
        return Vec3.init(
            self.y * other.z - self.z * other.y,
            self.z * other.x - self.x * other.z,
            self.x * other.y - self.y * other.x,
        );
    }
};

pub const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

pub const Mat4x4 = struct {
    data: [4][4]f32,

    pub fn init(
        m00: f32, m10: f32, m20: f32, m30: f32,
        m01: f32, m11: f32, m21: f32, m31: f32,
        m02: f32, m12: f32, m22: f32, m32: f32,
        m03: f32, m13: f32, m23: f32, m33: f32,
    ) Mat4x4 {
        return .{
            .data = .{
                .{ m00, m01, m02, m03 },
                .{ m10, m11, m12, m13 },
                .{ m20, m21, m22, m23 },
                .{ m30, m31, m32, m33 },
            },
        };
    }

    pub fn identity() Mat4x4 {
        return Mat4x4.init(
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        );
    }

    pub fn transpose(self: Mat4x4) Mat4x4 {
        var result = Mat4x4.identity();
        for (0..4) |i| {
            for (0..4) |j| {
                result.data[i][j] = self.data[j][i];
            }
        }
        return result;
    }

    pub fn multiply(self: Mat4x4, other: Mat4x4) Mat4x4 {
        var result = Mat4x4.identity();
        for (0..4) |i| {
            for (0..4) |j| {
                var sum: f32 = 0;
                for (0..4) |k| {
                    sum += self.data[k][j] * other.data[i][k];
                }
                result.data[i][j] = sum;
            }
        }
        return result;
    }

    pub fn scaling(scale: Vec3) Mat4x4 {
        return Mat4x4.init(
            scale.x, 0, 0, 0,
            0, scale.y, 0, 0,
            0, 0, scale.z, 0,
            0, 0, 0, 1,
        );
    }

    pub fn translation(offset: Vec3) Mat4x4 {
        return Mat4x4.init(
            1, 0, 0, offset.x,
            0, 1, 0, offset.y,
            0, 0, 1, offset.z,
            0, 0, 0, 1,
        );
    }

    pub fn rotationX(angle: f32) Mat4x4 {
        const cos = @cos(angle);
        const sin = @sin(angle);
        return Mat4x4.init(
            1, 0, 0, 0,
            0, cos, -sin, 0,
            0, sin, cos, 0,
            0, 0, 0, 1,
        );
    }

    pub fn rotationY(angle: f32) Mat4x4 {
        const cos = @cos(angle);
        const sin = @sin(angle);
        return Mat4x4.init(
            cos, 0, sin, 0,
            0, 1, 0, 0,
            -sin, 0, cos, 0,
            0, 0, 0, 1,
        );
    }

    pub fn rotationZ(angle: f32) Mat4x4 {
        const cos = @cos(angle);
        const sin = @sin(angle);
        return Mat4x4.init(
            cos, -sin, 0, 0,
            sin, cos, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        );
    }

    pub fn ortho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4x4 {
        const dx = -(right + left) / (right - left);
        const dy = -(top + bottom) / (top - bottom);
        const dz = -(far + near) / (far - near);

        return Mat4x4.init(
            2 / (right - left), 0, 0, dx,
            0, 2 / (top - bottom), 0, dy,
            0, 0, 2 / (far - near), dz,
            0, 0, 0, 1,
        );
    }

    pub fn perspective(fovy: f32, aspect_ratio: f32, near: f32, far: f32) Mat4x4 {
        const t = @tan(fovy / 2.0) * near;
        const r = t * aspect_ratio;

        return Mat4x4.init(
            (2 * near) / (2 * r), 0, 0, 0,
            0, (2 * near) / (2 * t), 0, 0,
            0, 0, -(far + near) / (far - near), -(2 * near * far) / (far - near),
            0, 0, -1, 0,
        );
    }

    pub fn lookAt(pos: Vec3, target: Vec3, up: Vec3) Mat4x4 {
        const d = target.sub(pos).normalize();
        const r = up.normalize().cross(d).normalize();
        const u = r.cross(d);

        return Mat4x4.init(
            r.x, r.y, r.z, -r.dot(pos),
            u.x, u.y, u.z, -u.dot(pos),
            -d.x, -d.y, -d.z, d.dot(pos),
            0, 0, 0, 1,
        );
    }
};
