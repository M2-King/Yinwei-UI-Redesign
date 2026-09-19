import ActivityKit
import Flutter
import Foundation

/// Flutter → ActivityKit sink. Presentation only — never writes engine or SceneStore.
enum YinweiLiveActivityChannel {
  static let name = "dev.yinwei/live_activity"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    let controller = YinweiLiveActivityController()
    channel.setMethodCallHandler { call, result in
      controller.handle(call: call, result: result)
    }
  }
}

final class YinweiLiveActivityController {
  private var activityId: String?

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if #available(iOS 16.2, *) {
      switch call.method {
      case "start":
        start(call.arguments, result: result)
      case "update":
        update(call.arguments, result: result)
      case "end":
        end(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    } else {
      result(
        FlutterError(
          code: "unavailable",
          message: "Live Activities require iOS 16.2",
          details: nil
        )
      )
    }
  }

  @available(iOS 16.2, *)
  private func start(_ args: Any?, result: @escaping FlutterResult) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      result(
        FlutterError(
          code: "disabled",
          message: "Live Activities are disabled on this iPhone.",
          details: nil
        )
      )
      return
    }
    guard let state = Self.contentState(from: args) else {
      result(
        FlutterError(code: "payload", message: "Invalid Live Activity payload", details: nil)
      )
      return
    }
    do {
      let activity = try Activity.request(
        attributes: YinweiActivityAttributes(sessionId: "yinwei-player"),
        content: ActivityContent(state: state, staleDate: nil),
        pushType: nil
      )
      activityId = activity.id
      result(nil)
    } catch {
      result(FlutterError(code: "start", message: String(describing: error), details: nil))
    }
  }

  @available(iOS 16.2, *)
  private func update(_ args: Any?, result: @escaping FlutterResult) {
    guard let state = Self.contentState(from: args) else {
      result(
        FlutterError(code: "payload", message: "Invalid Live Activity payload", details: nil)
      )
      return
    }
    let content = ActivityContent(state: state, staleDate: nil)
    let id = activityId
    Task {
      for activity in Activity<YinweiActivityAttributes>.activities where id == nil || activity.id == id {
        await activity.update(content)
      }
      result(nil)
    }
  }

  @available(iOS 16.2, *)
  private func end(result: @escaping FlutterResult) {
    Task {
      for activity in Activity<YinweiActivityAttributes>.activities {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
      await MainActor.run {
        self.activityId = nil
      }
      result(nil)
    }
  }

  /// Maps the Dart YinweiLivePresentation payload. No Orbit math.
  static func contentState(from args: Any?) -> YinweiActivityAttributes.ContentState? {
    guard let map = args as? [String: Any] else { return nil }
    return YinweiActivityAttributes.ContentState(
      mode: map["spatialMode"] as? String ?? "spatial",
      playing: Self.boolValue(map["playing"]),
      orbiting: Self.boolValue(map["orbiting"]),
      azimuthDeg: Self.doubleValue(map["azimuthDeg"]),
      elevationDeg: Self.doubleValue(map["elevationDeg"]),
      sourceLabel: "Point",
      title: map["title"] as? String ?? "Yinwei",
      motionMode: map["motionMode"] as? String ?? "fixed",
      distanceM: Self.doubleValue(map["distanceM"])
    )
  }

  private static func boolValue(_ raw: Any?) -> Bool {
    if let value = raw as? Bool { return value }
    if let number = raw as? NSNumber { return number.boolValue }
    return false
  }

  private static func doubleValue(_ raw: Any?) -> Double {
    if let value = raw as? Double { return value }
    if let number = raw as? NSNumber { return number.doubleValue }
    return 0
  }
}
