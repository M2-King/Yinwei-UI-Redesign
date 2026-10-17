import Foundation
import Darwin

// Compile with ios/Shared/YinweiCaptureSupport.swift. These are executable tests
// of production selection, signature parsing, connect transitions and counters.
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  precondition(condition(), message)
  checks += 1
}
let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let profile = Data([0x30, 0x82, 0xff]) + fixture + Data([0, 0xff])
let candidates = YinweiCaptureGroup.profileGroups(in: profile)
check(candidates.count == 5, "Unsorted five-group profile must parse")
check(candidates.first == "group.zulu.capture", "Fixture must remain unsorted")
var checked: [String] = []
let selected = YinweiCaptureGroup.select(candidates) { group in
  checked.append(group)
  return group != "group.alpha.capture"
}
check(selected == "group.beta.capture", "First accessible sorted candidate wins")
check(checked == ["group.alpha.capture", "group.beta.capture"], "Validate containers in sorted order")
check(YinweiCaptureGroup.select(Array(candidates.reversed())) { $0 != "group.alpha.capture" } == selected,
      "Host/extension profile order must not affect selection")
check(YinweiCaptureGroup.select(candidates) { _ in true } == "group.alpha.capture",
      "Legacy product group must not receive priority")
check(YinweiCaptureGroup.select(candidates) { _ in false } == nil, "No accessible container must fail closed")
check(YinweiCaptureGroup.select([]) { _ in true } == nil, "Missing groups must fail closed")
check(YinweiCaptureGroup.profileGroups(in: Data("invalid profile".utf8)).isEmpty, "Malformed profile")

print("PASS: unsorted five-group profile, sorted container validation, denied/missing groups and host/extension ordering")

func word(_ value: UInt32, big: Bool = false) -> Data {
  var value = big ? value.bigEndian : value.littleEndian
  return withUnsafeBytes(of: &value) { Data($0) }
}
func executable(groups: [String]) throws -> Data {
  let xml = try PropertyListSerialization.data(fromPropertyList:
    ["com.apple.security.application-groups": groups], format: .xml, options: 0)
  let entry = word(0xfade7171, big: true) + word(UInt32(xml.count + 8), big: true) + xml
  let blob = word(0xfade0cc0, big: true) + word(UInt32(entry.count + 20), big: true)
    + word(1, big: true) + word(5, big: true) + word(20, big: true) + entry
  var header = Data(repeating: 0, count: 32)
  header.replaceSubrange(0..<4, with: word(0xfeedfacf))
  header.replaceSubrange(16..<20, with: word(1))
  header.replaceSubrange(20..<24, with: word(16))
  return header + word(0x1d) + word(16) + word(48) + word(UInt32(blob.count)) + blob
}
let signed = try executable(groups: candidates)
check(YinweiCaptureGroup.signedGroups(in: signed) == candidates, "Read own signed entitlement slot")
let extensionSigned = try executable(groups: Array(candidates.reversed()))
check(YinweiCaptureGroup.select(YinweiCaptureGroup.signedGroups(in: extensionSigned)!) { _ in true }
  == YinweiCaptureGroup.select(YinweiCaptureGroup.signedGroups(in: signed)!) { _ in true },
  "Differently ordered signed bundles select the same group")
let emptySigned = try executable(groups: [])
check(YinweiCaptureGroup.signedGroups(in: emptySigned) == [], "No invented fallback group")
for length in 0..<signed.count {
  check(YinweiCaptureGroup.signedGroups(in: Data(signed.prefix(length))) == nil, "Reject truncated executable")
}
var invalid = signed
invalid.replaceSubrange(44..<48, with: word(UInt32.max))
check(YinweiCaptureGroup.signedGroups(in: invalid) == nil, "Reject overflowing signature extent")
check(YinweiCaptureGroup.signedGroups(in: profile) == nil, "Profile authorization is not a code signature")

check(YinweiConnectProgress.started(result: 0, error: ECONNREFUSED) == .connected, "Success ignores stale errno")
for error in [EINPROGRESS, EALREADY, EINTR] {
  check(YinweiConnectProgress.started(result: -1, error: error) == .pending, "Retain pending descriptor")
}
check(YinweiConnectProgress.started(result: -1, error: ECONNREFUSED) == .failed, "Retry refused connection")
check(YinweiConnectProgress.polled(result: 0, pollError: 0, events: 0, socketError: nil, elapsed: 0.5) == .pending,
      "No readiness is normal while connecting")
check(YinweiConnectProgress.polled(result: 1, pollError: 0, events: Int16(POLLOUT), socketError: 0, elapsed: 0.5) == .connected,
      "Writability and SO_ERROR confirm completion")
check(YinweiConnectProgress.polled(result: 1, pollError: 0, events: Int16(POLLOUT), socketError: ECONNREFUSED, elapsed: 0.5) == .failed,
      "Writable failed socket must never send PCM")
check(YinweiConnectProgress.polled(result: 0, pollError: 0, events: 0, socketError: nil, elapsed: 3) == .failed,
      "Pending connection must time out")

print("PASS: signed entitlement parsing and nonblocking socket transitions")

var counters = YinweiReturnCounters()
counters.begin()
let token = counters.generation
counters.receive(); counters.receive(); counters.enqueue()
check(counters.received == 2 && counters.accepted == 1 && counters.played == 0, "Receipt is not playback")
counters.complete(token: token)
check(counters.played == 1, "Count native played callback")
counters.invalidate(); counters.complete(token: token)
check(counters.played == 1, "Ignore callbacks after stop/reset")
counters.begin(); counters.complete(token: token)
check(counters.received == 0 && counters.accepted == 0 && counters.played == 0, "New session resets counts and rejects stale callbacks")
print("PASS: \(checks) native capture checks")
