import XCTest

final class YinweiActivityPresentationTests: XCTestCase {
  func testCompactTrailingShowsLiveOrbitHeading() {
    let state = YinweiActivityViewState(
      mode: "spatial",
      playing: true,
      orbiting: true,
      azimuthDeg: 42.4,
      elevationDeg: -10,
      sourceLabel: "Point",
      title: "Preview"
    )
    XCTAssertEqual(YinweiActivityPresentation.compactTrailing(state), "42°")
    XCTAssertEqual(YinweiActivityPresentation.statusLine(state), "Orbit")
  }

  func testPausedOrbitKeepsLastHeading() {
    let playing = YinweiActivityViewState(
      mode: "spatial",
      playing: true,
      orbiting: true,
      azimuthDeg: 90,
      elevationDeg: 0,
      sourceLabel: "Point",
      title: "Preview"
    )
    let paused = YinweiActivityViewState(
      mode: "spatial",
      playing: false,
      orbiting: false,
      azimuthDeg: 90,
      elevationDeg: 0,
      sourceLabel: "Point",
      title: "Preview"
    )
    XCTAssertEqual(YinweiActivityPresentation.compactTrailing(playing), "90°")
    XCTAssertEqual(YinweiActivityPresentation.compactTrailing(paused), "90°")
    XCTAssertEqual(YinweiActivityPresentation.statusLine(paused), "Paused")
    XCTAssertEqual(YinweiActivityPresentation.orbitLabel(paused), "Frozen")
  }

  func testExpandedReadoutStaysLowDensity() {
    let state = YinweiActivityViewState(
      mode: "spatial",
      playing: true,
      orbiting: false,
      azimuthDeg: -45.2,
      elevationDeg: 12.6,
      sourceLabel: "Point",
      title: "Local file"
    )
    XCTAssertEqual(YinweiActivityPresentation.expandedBottom(state), "Az -45°  El 13°")
    XCTAssertEqual(YinweiActivityPresentation.expandedTrailing(state), "-45°")
  }

  func testClipOrbitClockMatchesDartWrap() {
    XCTAssertEqual(ClipOrbitClock.wrapAzimuth(190), -170, accuracy: 0.001)
    XCTAssertEqual(ClipOrbitClock.wrapAzimuth(-190), 170, accuracy: 0.001)
    let visual = ClipOrbitClock.visualFromOrigin(originDeg: 0, elapsed: 2.5, orbitHz: 0.1)
    XCTAssertEqual(visual, 90, accuracy: 0.001)
  }
}
