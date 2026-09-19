import ActivityKit
import SwiftUI
import WidgetKit

struct YinweiLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: YinweiActivityAttributes.self) { context in
      lockScreen(context.state.viewState)
    } dynamicIsland: { context in
      let state = context.state.viewState
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Yinwei")
              .font(.caption.weight(.semibold))
            Text(YinweiActivityPresentation.statusLine(state))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        DynamicIslandExpandedRegion(.center) {
          Text(state.title)
            .font(.caption)
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(YinweiActivityPresentation.expandedTrailing(state))
            .font(.caption.monospacedDigit().weight(.medium))
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack {
            Text(YinweiActivityPresentation.expandedBottom(state))
            Spacer()
            Text(state.playing ? "Playing" : "Paused")
            Text(YinweiActivityPresentation.orbitLabel(state))
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      } compactLeading: {
        Image(systemName: "waveform")
      } compactTrailing: {
        Text(YinweiActivityPresentation.compactTrailing(state))
          .font(.caption.monospacedDigit())
      } minimal: {
        Image(systemName: "dot.radiowaves.left.and.right")
      }
      .keylineTint(Color(red: 0.04, green: 0.52, blue: 1))
    }
  }

  private func lockScreen(_ state: YinweiActivityViewState) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "waveform")
      VStack(alignment: .leading, spacing: 2) {
        Text("Yinwei")
          .font(.headline)
        Text(state.title)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text(YinweiActivityPresentation.compactTrailing(state))
          .font(.title3.monospacedDigit())
        Text(YinweiActivityPresentation.statusLine(state))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .activityBackgroundTint(Color.black.opacity(0.72))
  }
}

#if DEBUG
#Preview("Island Compact", as: .dynamicIsland(.compact), using: YinweiActivityAttributes(sessionId: "preview")) {
  YinweiLiveActivity()
} contentStates: {
  YinweiActivityAttributes.ContentState(
    mode: "spatial",
    playing: true,
    orbiting: true,
    azimuthDeg: 42,
    elevationDeg: -8,
    sourceLabel: "Point",
    title: "Preview"
  )
}

#Preview("Island Expanded", as: .dynamicIsland(.expanded), using: YinweiActivityAttributes(sessionId: "preview")) {
  YinweiLiveActivity()
} contentStates: {
  YinweiActivityAttributes.ContentState(
    mode: "spatial",
    playing: false,
    orbiting: false,
    azimuthDeg: 90,
    elevationDeg: 0,
    sourceLabel: "Point",
    title: "Preview"
  )
}

#Preview("Lock Screen", as: .content, using: YinweiActivityAttributes(sessionId: "preview")) {
  YinweiLiveActivity()
} contentStates: {
  YinweiActivityAttributes.ContentState(
    mode: "spatial",
    playing: true,
    orbiting: false,
    azimuthDeg: -45,
    elevationDeg: 12,
    sourceLabel: "Point",
    title: "Local file"
  )
}
#endif
