import ActivityKit
import Combine
import Foundation

/// Starts and updates the Yinwei Live Activity from the App Clip.
/// Read-only presentation: never writes engine / SceneStore.
@MainActor
final class ClipLiveActivityController: ObservableObject {
  @Published private(set) var activityId: String?
  @Published private(set) var lastError: String?

  var isActive: Bool { activityId != nil }

  func start(state: ClipPreviewState) {
    lastError = nil
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      lastError = "Live Activities are disabled on this iPhone."
      return
    }
    let attributes = YinweiActivityAttributes(sessionId: "yinwei-clip")
    let content = ActivityContent(state: state.activityState, staleDate: nil)
    do {
      let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
      activityId = activity.id
    } catch {
      lastError = String(describing: error)
    }
  }

  func update(state: ClipPreviewState) {
    guard let activityId else { return }
    let content = ActivityContent(state: state.activityState, staleDate: nil)
    Task {
      for activity in Activity<YinweiActivityAttributes>.activities where activity.id == activityId {
        await activity.update(content)
      }
    }
  }

  func end() {
    let content = ActivityContent(
      state: YinweiActivityAttributes.ContentState(
        mode: "spatial",
        playing: false,
        orbiting: false,
        azimuthDeg: 0,
        elevationDeg: 0,
        sourceLabel: "Point",
        title: "Ended"
      ),
      staleDate: nil
    )
    Task {
      for activity in Activity<YinweiActivityAttributes>.activities {
        await activity.end(content, dismissalPolicy: .immediate)
      }
      await MainActor.run {
        activityId = nil
      }
    }
  }
}
