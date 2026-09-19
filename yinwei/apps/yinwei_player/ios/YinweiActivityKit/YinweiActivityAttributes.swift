import ActivityKit
import Foundation

/// Live Activity attributes. Keep this small — no spatial scenes, no DSP objects.
public struct YinweiActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable, Sendable {
    public var mode: String
    public var playing: Bool
    public var orbiting: Bool
    public var azimuthDeg: Double
    public var elevationDeg: Double
    public var sourceLabel: String
    public var title: String
    public var motionMode: String
    public var distanceM: Double

    public init(
      mode: String,
      playing: Bool,
      orbiting: Bool,
      azimuthDeg: Double,
      elevationDeg: Double,
      sourceLabel: String,
      title: String,
      motionMode: String = "fixed",
      distanceM: Double = 0
    ) {
      self.mode = mode
      self.playing = playing
      self.orbiting = orbiting
      self.azimuthDeg = azimuthDeg
      self.elevationDeg = elevationDeg
      self.sourceLabel = sourceLabel
      self.title = title
      self.motionMode = motionMode
      self.distanceM = distanceM
    }

    public var viewState: YinweiActivityViewState {
      YinweiActivityViewState(
        mode: mode,
        playing: playing,
        orbiting: orbiting,
        azimuthDeg: azimuthDeg,
        elevationDeg: elevationDeg,
        sourceLabel: sourceLabel,
        title: title
      )
    }
  }

  public var sessionId: String

  public init(sessionId: String) {
    self.sessionId = sessionId
  }
}
