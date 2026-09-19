import Foundation

/// Display-only orbit clock. Matches Dart `OrbitPoseMath`.
/// Not a Point store and not engine authority.
enum ClipOrbitClock {
  static func wrapAzimuth(_ deg: Double) -> Double {
    var x = deg.truncatingRemainder(dividingBy: 360)
    if x > 180 { x -= 360 }
    if x <= -180 { x += 360 }
    return x
  }

  static func phaseDeg(elapsed: TimeInterval, orbitHz: Double) -> Double {
    elapsed * orbitHz * 360
  }

  static func visualFromOrigin(originDeg: Double, elapsed: TimeInterval, orbitHz: Double) -> Double {
    wrapAzimuth(originDeg + phaseDeg(elapsed: elapsed, orbitHz: orbitHz))
  }
}
