import SwiftUI
import UIKit

struct ClipRootView: View {
  @StateObject private var live = ClipLiveActivityController()
  @State private var preview = ClipPreviewState()
  let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

  var body: some View {
    ZStack {
      Color(red: 0.043, green: 0.043, blue: 0.051).ignoresSafeArea()
      VStack(alignment: .leading, spacing: 18) {
        header
        statusCard
        spatialCard
        controls
        if let err = live.lastError {
          Text(err)
            .font(.footnote)
            .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.58))
        }
        Spacer()
      }
      .padding(22)
    }
    .preferredColorScheme(.dark)
    .onReceive(timer) { _ in
      if preview.playing && preview.orbiting {
        live.update(state: preview)
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("音围 Yinwei")
        .font(.system(size: 28, weight: .semibold, design: .default))
        .foregroundStyle(Color(red: 0.96, green: 0.96, blue: 0.97))
      Text("Clip · spatial preview")
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.58))
    }
  }

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(preview.title)
        .font(.system(size: 16, weight: .medium))
      Text(statusText)
        .font(.system(size: 13))
        .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.58))
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(red: 0.071, green: 0.071, blue: 0.078), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var spatialCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("Point", systemImage: "dot.radiowaves.left.and.right")
        Spacer()
        Text("Az \(YinweiActivityPresentation.formatDeg(preview.displayAzimuthDeg))")
          .monospacedDigit()
      }
      .foregroundStyle(Color(red: 0.96, green: 0.96, blue: 0.97))

      HStack {
        Text("El \(YinweiActivityPresentation.formatDeg(preview.elevationDeg))")
        Spacer()
        Text(preview.playing && preview.orbiting ? "Orbit live" : (preview.playing ? "Fixed" : "Frozen"))
          .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.58))
      }
      .font(.system(size: 13))

      Slider(value: azimuthBinding, in: -180...180)
        .tint(Color(red: 0.04, green: 0.52, blue: 1))
      Slider(value: $preview.elevationDeg, in: -40...80)
        .tint(Color(red: 0.04, green: 0.52, blue: 1))
    }
    .padding(16)
    .background(Color(red: 0.071, green: 0.071, blue: 0.078), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var controls: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        clipButton(preview.playing ? "Pause" : "Play") {
          preview.togglePlay()
          live.update(state: preview)
        }
        clipButton(preview.orbiting ? "Orbit on" : "Orbit off") {
          preview.setOrbiting(!preview.orbiting)
          live.update(state: preview)
        }
      }
      clipButton(live.isActive ? "Update Live Activity" : "Start Live Activity") {
        if live.isActive {
          live.update(state: preview)
        } else {
          live.start(state: preview)
        }
      }
      if live.isActive {
        clipButton("End Live Activity") {
          live.end()
        }
      }
      Button {
        if let url = URL(string: "yinwei://open") {
          UIApplication.shared.open(url)
        }
      } label: {
        Text("Open full Yinwei")
          .font(.system(size: 15, weight: .medium))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
      }
      .buttonStyle(.bordered)
      .tint(.white)
    }
  }

  private var statusText: String {
    let line = YinweiActivityPresentation.statusLine(preview.activityState.viewState)
    return "Spatial · \(line)"
  }

  private var azimuthBinding: Binding<Double> {
    Binding(
      get: { preview.displayAzimuthDeg },
      set: { next in
        preview.originAzimuthDeg = next
        preview.frozenAzimuthDeg = next
        if preview.playing && preview.orbiting {
          preview.playStartedAt = Date()
        }
        live.update(state: preview)
      }
    )
  }

  private func clipButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 15, weight: .medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
    .buttonStyle(.borderedProminent)
    .tint(Color(red: 0.04, green: 0.52, blue: 1))
  }
}
