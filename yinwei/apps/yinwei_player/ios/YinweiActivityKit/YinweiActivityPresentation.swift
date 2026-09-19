import Foundation

/// Read-only Live Activity / Dynamic Island presentation.
/// Matches the Dart helper in `yinwei_activity_presentation.dart`.
/// Does not write engine, SceneStore, or DSP state.
public struct YinweiActivityViewState: Equatable, Sendable {
  public var mode: String
  public var playing: Bool
  public var orbiting: Bool
  public var azimuthDeg: Double
  public var elevationDeg: Double
  public var sourceLabel: String
  public var title: String

  public init(
    mode: String,
    playing: Bool,
    orbiting: Bool,
    azimuthDeg: Double,
    elevationDeg: Double,
    sourceLabel: String,
    title: String
  ) {
    self.mode = mode
    self.playing = playing
    self.orbiting = orbiting
    self.azimuthDeg = azimuthDeg
    self.elevationDeg = elevationDeg
    self.sourceLabel = sourceLabel
    self.title = title
  }
}

public enum YinweiActivityPresentation {
  public static func formatDeg(_ deg: Double) -> String {
    "\(Int(deg.rounded()))°"
  }

  public static func compactTrailing(_ state: YinweiActivityViewState) -> String {
    formatDeg(state.azimuthDeg)
  }

  public static func expandedTrailing(_ state: YinweiActivityViewState) -> String {
    formatDeg(state.azimuthDeg)
  }

  public static func statusLine(_ state: YinweiActivityViewState) -> String {
    if state.orbiting && state.playing { return "Orbit" }
    if state.playing { return "Spatial" }
    return "Paused"
  }

  public static func orbitLabel(_ state: YinweiActivityViewState) -> String {
    if state.orbiting && state.playing { return "Orbit" }
    if !state.playing { return "Frozen" }
    return "Fixed"
  }

  public static func expandedBottom(_ state: YinweiActivityViewState) -> String {
    "Az \(formatDeg(state.azimuthDeg))  El \(formatDeg(state.elevationDeg))"
  }
}
