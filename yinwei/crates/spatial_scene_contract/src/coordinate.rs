//! CoordinateFrameV1 — right-handed Y-up, −Z forward, metres.

pub const QUAT_DEGENERATE_NORM: f64 = 1e-12;
pub const ZERO_DISTANCE_M: f64 = 1e-9;
pub const HORIZONTAL_POLE_M: f64 = 1e-8;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Vec3V1 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl Vec3V1 {
    pub const ZERO: Self = Self {
        x: 0.0,
        y: 0.0,
        z: 0.0,
    };
    pub const HRTF_FORWARD_FALLBACK: Self = Self {
        x: 0.0,
        y: 0.0,
        z: -1.0,
    };

    pub fn new(x: f64, y: f64, z: f64) -> Self {
        Self { x, y, z }
    }

    pub fn length(self) -> f64 {
        (self.x * self.x + self.y * self.y + self.z * self.z).sqrt()
    }

    pub fn add(self, o: Self) -> Self {
        Self::new(self.x + o.x, self.y + o.y, self.z + o.z)
    }

    pub fn sub(self, o: Self) -> Self {
        Self::new(self.x - o.x, self.y - o.y, self.z - o.z)
    }

    pub fn scaled(self, s: f64) -> Self {
        Self::new(self.x * s, self.y * s, self.z * s)
    }
}

fn cross(a: Vec3V1, b: Vec3V1) -> Vec3V1 {
    Vec3V1::new(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    )
}

/// Hamilton order (w, x, y, z).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct QuatV1 {
    pub w: f64,
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl QuatV1 {
    pub const IDENTITY: Self = Self {
        w: 1.0,
        x: 0.0,
        y: 0.0,
        z: 0.0,
    };

    pub fn new(w: f64, x: f64, y: f64, z: f64) -> Self {
        Self { w, x, y, z }
    }

    pub fn norm(self) -> f64 {
        (self.w * self.w + self.x * self.x + self.y * self.y + self.z * self.z).sqrt()
    }

    pub fn is_degenerate(self) -> bool {
        self.norm() < QUAT_DEGENERATE_NORM
    }

    pub fn normalized(self) -> Self {
        let n = self.norm();
        if n < QUAT_DEGENERATE_NORM {
            return Self::IDENTITY;
        }
        Self::new(self.w / n, self.x / n, self.y / n, self.z / n)
    }

    pub fn conjugate(self) -> Self {
        Self::new(self.w, -self.x, -self.y, -self.z)
    }

    pub fn inverse(self) -> Self {
        self.normalized().conjugate()
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SphericalV1 {
    pub azimuth_deg: f64,
    pub elevation_deg: f64,
    pub distance_m: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ListenerPoseV1 {
    pub world_position: Vec3V1,
    pub orientation: QuatV1,
}

pub fn rotate_vec3(q: QuatV1, v: Vec3V1) -> Vec3V1 {
    let n = q.normalized();
    let qvec = Vec3V1::new(n.x, n.y, n.z);
    let t = cross(qvec, v).scaled(2.0);
    v.add(t.scaled(n.w)).add(cross(qvec, t))
}

pub fn wrap_azimuth_deg(deg: f64) -> f64 {
    let mut az = deg;
    while az > 180.0 {
        az -= 360.0;
    }
    while az <= -180.0 {
        az += 360.0;
    }
    az
}

pub fn shortest_azimuth_delta_deg(from_deg: f64, to_deg: f64) -> f64 {
    let mut d = to_deg - from_deg;
    while d > 180.0 {
        d -= 360.0;
    }
    while d < -180.0 {
        d += 360.0;
    }
    d
}

pub fn lerp_azimuth_deg(from_deg: f64, to_deg: f64, t: f64) -> f64 {
    wrap_azimuth_deg(from_deg + shortest_azimuth_delta_deg(from_deg, to_deg) * t)
}

pub fn spherical_to_local(p: SphericalV1) -> Vec3V1 {
    let az = p.azimuth_deg.to_radians();
    let el = p.elevation_deg.to_radians();
    let d = p.distance_m;
    let ce = el.cos();
    Vec3V1::new(d * az.sin() * ce, d * el.sin(), -d * az.cos() * ce)
}

pub fn local_to_spherical(p: Vec3V1) -> SphericalV1 {
    let r = p.length();
    if r < ZERO_DISTANCE_M {
        return SphericalV1 {
            azimuth_deg: 0.0,
            elevation_deg: 0.0,
            distance_m: 0.0,
        };
    }
    let h = (p.x * p.x + p.z * p.z).sqrt();
    if h < HORIZONTAL_POLE_M {
        return SphericalV1 {
            azimuth_deg: 0.0,
            elevation_deg: if p.y >= 0.0 { 90.0 } else { -90.0 },
            distance_m: r,
        };
    }
    let el = (p.y / r).clamp(-1.0, 1.0).asin().to_degrees();
    let az = wrap_azimuth_deg(p.x.atan2(-p.z).to_degrees());
    SphericalV1 {
        azimuth_deg: az,
        elevation_deg: el,
        distance_m: r,
    }
}

pub fn hrtf_unit_from_local(local: Vec3V1) -> Vec3V1 {
    let r = local.length();
    if r < ZERO_DISTANCE_M {
        return Vec3V1::HRTF_FORWARD_FALLBACK;
    }
    local.scaled(1.0 / r)
}

pub fn world_to_listener_local(world: Vec3V1, listener: ListenerPoseV1) -> Vec3V1 {
    let rel = world.sub(listener.world_position);
    rotate_vec3(listener.orientation.inverse(), rel)
}

pub fn listener_local_to_world(local: Vec3V1, listener: ListenerPoseV1) -> Vec3V1 {
    listener
        .world_position
        .add(rotate_vec3(listener.orientation, local))
}

pub fn geometric_distance_m(local: Vec3V1) -> f64 {
    let r = local.length();
    if r < ZERO_DISTANCE_M {
        0.0
    } else {
        r
    }
}
