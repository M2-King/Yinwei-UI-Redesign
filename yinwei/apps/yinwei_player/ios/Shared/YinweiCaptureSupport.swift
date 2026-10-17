import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared by Runner and BroadcastUpload. Candidate names come from each
/// executable's code signature, never a preferred product ID. The OS container
/// check is the authority for access; parsing a signature grants no permission.
enum YinweiCaptureGroup {
  static let unavailable = "Group unavailable · this signed bundle has no accessible App Group. Sign the app and broadcast extension with the same group."
  static let current: String? = resolve(in: .main)

  static func select(_ candidates: [String], canOpen: (String) -> Bool) -> String? {
    Set(candidates.filter { $0.hasPrefix("group.") && $0.count > 6 })
      .sorted().first(where: canOpen)
  }

  static func resolve(in bundle: Bundle) -> String? {
    guard let url = bundle.executableURL,
          let data = try? Data(contentsOf: url, options: .alwaysMapped),
          let groups = signedGroups(in: data) else { return nil }
    return select(groups) {
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }
  }

  /// Provisioning profiles are test inputs / signing diagnostics only. They
  /// describe allowed entitlements, not necessarily those claimed by the app.
  static func profileGroups(in data: Data) -> [String] {
    guard let start = data.range(of: Data("<?xml".utf8)),
          let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
          let plist = try? PropertyListSerialization.propertyList(
            from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil),
          let root = plist as? [String: Any],
          let entitlements = root["Entitlements"] as? [String: Any] else { return [] }
    return groups(in: entitlements)
  }

  private static func groups(in entitlements: [String: Any]) -> [String] {
    entitlements["com.apple.security.application-groups"] as? [String] ?? []
  }

  /// Bounds-checked Mach-O LC_CODE_SIGNATURE / XML entitlement slot reader.
  /// Installed iOS executables are thin little-endian 64-bit Mach-O. Unsupported
  /// formats (including DER-only signatures) fail closed with Group unavailable.
  /// No private Security APIs and no provisioning-profile fallback are used.
  static func signedGroups(in data: Data) -> [String]? {
    func word(_ offset: Int, bigEndian: Bool = false) -> UInt32? {
      guard offset >= 0, offset <= data.count - 4 else { return nil }
      let b = data.subdata(in: offset..<(offset + 4))
      return bigEndian
        ? (UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        : (UInt32(b[3]) << 24 | UInt32(b[2]) << 16 | UInt32(b[1]) << 8 | UInt32(b[0]))
    }
    guard word(0) == 0xfeedfacf, let count = word(16), let size = word(20),
          Int(size) <= data.count - 32, count <= size / 8 else { return nil }
    var cursor = 32
    let commandsEnd = 32 + Int(size)
    for _ in 0..<Int(count) {
      guard cursor <= commandsEnd - 8,
            let command = word(cursor), let length = word(cursor + 4),
            length >= 8, Int(length) <= commandsEnd - cursor else { return nil }
      if command == 0x1d { // LC_CODE_SIGNATURE, linkedit_data_command
        guard length >= 16, let offset = word(cursor + 8), let bytes = word(cursor + 12),
              Int(offset) <= data.count, Int(bytes) <= data.count - Int(offset), bytes >= 12
        else { return nil }
        let base = Int(offset), end = Int(offset) + Int(bytes)
        guard word(base, bigEndian: true) == 0xfade0cc0,
              let blobSize = word(base + 4, bigEndian: true),
              blobSize >= 12, Int(blobSize) <= end - base,
              let slots = word(base + 8, bigEndian: true), slots <= (blobSize - 12) / 8
        else { return nil }
        for slot in 0..<Int(slots) {
          let index = base + 12 + slot * 8
          guard let kind = word(index, bigEndian: true),
                let relative = word(index + 4, bigEndian: true),
                relative >= 12 + slots * 8, relative <= blobSize - 8 else { return nil }
          if kind != 5 { continue } // CSSLOT_ENTITLEMENTS
          let entry = base + Int(relative)
          guard word(entry, bigEndian: true) == 0xfade7171,
                let entrySize = word(entry + 4, bigEndian: true), entrySize >= 8,
                entrySize <= blobSize - relative,
                let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: (entry + 8)..<(entry + Int(entrySize))),
                  options: [], format: nil), let entitlements = plist as? [String: Any]
          else { return nil }
          return groups(in: entitlements)
        }
        return nil
      }
      cursor += Int(length)
    }
    return nil
  }
}

/// Playback completion is distinct from queue acceptance. All access is on the
/// main queue; stale completion callbacks after reset/stop cannot count as played.
struct YinweiReturnCounters {
  private(set) var received = 0
  private(set) var accepted = 0
  private(set) var played = 0
  private(set) var generation: UInt64 = 0
  mutating func receive() { received = min(received, Int.max - 1) + 1 }
  mutating func enqueue() { accepted = min(accepted, Int.max - 1) + 1 }
  mutating func complete(token: UInt64) {
    if token == generation { played = min(played, Int.max - 1) + 1 }
  }
  mutating func invalidate() { generation &+= 1 }
  mutating func begin() { invalidate(); received = 0; accepted = 0; played = 0 }
}

#if canImport(Darwin)
/// Pure transition policy used by the nonblocking writer and native tests.
enum YinweiConnectProgress: Equatable {
  case pending, connected, failed

  static func started(result: Int32, error: Int32) -> Self {
    if result == 0 { return .connected }
    return [EINPROGRESS, EALREADY, EINTR].contains(error) ? .pending : .failed
  }

  static func polled(result: Int32, pollError: Int32, events: Int16,
                     socketError: Int32?, elapsed: TimeInterval) -> Self {
    if elapsed >= 3 { return .failed }
    if result == 0 || (result < 0 && pollError == EINTR) { return .pending }
    guard result > 0, events & Int16(POLLNVAL | POLLHUP) == 0,
          let socketError else { return .failed }
    if socketError == EINPROGRESS || socketError == EALREADY { return .pending }
    return socketError == 0 && events & Int16(POLLOUT) != 0 ? .connected : .failed
  }
}
#endif
