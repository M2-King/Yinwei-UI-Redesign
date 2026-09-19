import Foundation

/// Local App Clip preview clock. Display-only — not a Point store and not engine authority.
struct ClipPreviewState: Equatable {
  var title: String = "Point preview"
  var sourceLabel: String = "Point"
  var playing: Bool = false
  var orbiting: Bool = false
  var originAzimuthDeg: Double = 32
  var elevationDeg: Double = -8
  var orbitHz: Double = 0.08
  var playStartedAt: Date?
  var frozenAzimuthDeg: Double = 32

  var displayAzimuthDeg: Double {
    guard playing, orbiting, let started = playStartedAt else {
      return frozenAzimuthDeg
    }
    return ClipOrbitClock.visualFromOrigin(
      originDeg: originAzimuthDeg,
      elapsed: Date().timeIntervalSince(started),
      orbitHz: orbitHz
    )
  }

  var activityState: YinweiActivityAttributes.ContentState {
    let az = displayAzimuthDeg
    return YinweiActivityAttributes.ContentState(
      mode: "spatial",
      playing: playing,
      orbiting: playing && orbiting,
      azimuthDeg: az,
      elevationDeg: elevationDeg,
      sourceLabel: sourceLabel,
      title: title
    )
  }

  mutating func togglePlay() {
    if playing {
      frozenAzimuthDeg = displayAzimuthDeg
      playing = false
      playStartedAt = nil
    } else {
      playing = true
      playStartedAt = Date()
      if !orbiting {
        frozenAzimuthDeg = originAzimuthDeg
      }
    }
  }

  mutating func setOrbiting(_ on: Bool) {
    if playing {
      frozenAzimuthDeg = displayAzimuthDeg
      originAzimuthDeg = frozenAzimuthDeg
      playStartedAt = Date()
    }
    orbiting = on
    if !on {
      frozenAzimuthDeg = originAzimuthDeg
    }
  }
}
