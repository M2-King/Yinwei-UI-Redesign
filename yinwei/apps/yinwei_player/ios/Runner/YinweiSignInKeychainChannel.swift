import Flutter
import Foundation
import Security

/// "Remember me on this iPad": the Listen Room's laptop sign-in (entry link,
/// owner account, password) as one Keychain item. Device only: never synced
/// to iCloud or restored from a backup to another device. Readable after the
/// first unlock, so the app can sign back in while running in the background.
enum YinweiSignInKeychainChannel {
  static let name = "dev.yinwei/sign_in_keychain"
  private static let service = "dev.yinwei.listen.sign-in"
  private static let account = "laptop-owner"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "load":
        result(load())
      case "save":
        guard let value = call.arguments as? String, let data = value.data(using: .utf8),
              data.count <= 4_096
        else { result(FlutterError(code: "bad_value", message: nil, details: nil)); return }
        let status = save(data)
        result(status == errSecSuccess ? nil
          : FlutterError(code: "keychain", message: "Keychain status \(status)", details: nil))
      case "clear":
        SecItemDelete(query() as CFDictionary)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func query() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }

  private static func load() -> String? {
    var request = query()
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func save(_ data: Data) -> OSStatus {
    SecItemDelete(query() as CFDictionary)
    var item = query()
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(item as CFDictionary, nil)
  }
}
