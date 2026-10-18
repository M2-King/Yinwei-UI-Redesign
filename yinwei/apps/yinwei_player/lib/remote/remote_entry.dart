import 'dart:async';
import 'dart:io';

/// Why the Yinwei entry link could not give a laptop origin; the message is
/// shown to the user as is.
class RemoteEntryFailure implements Exception {
  const RemoteEntryFailure(this.message);
  final String message;
}

/// The laptop's current HTTPS origin for the fixed Yinwei bookmark (or a
/// quick-tunnel origin typed directly).
Future<Uri> resolveRemoteEntry(String address) async {
  final initial = Uri.tryParse(address.trim());
  if (initial == null ||
      initial.scheme != 'https' ||
      initial.host.isEmpty ||
      initial.userInfo.isNotEmpty ||
      initial.hasQuery ||
      initial.hasFragment ||
      !['', '/'].contains(initial.path)) {
    throw const RemoteEntryFailure('Use your fixed Yinwei HTTPS bookmark');
  }
  // Resolve only a known Cloudflare launcher/temporary origin. Passwords
  // are never sent to the launcher, an arbitrary redirect or an HTTP URL.
  bool quick(Uri uri) =>
      uri.scheme == 'https' &&
      uri.authority == uri.host &&
      RegExp(r'^[a-z0-9-]+\.trycloudflare\.com$').hasMatch(uri.host);
  if (quick(initial)) return initial.replace(path: '');
  if (initial.host !=
      'yinwei-remote-entry-01a12de8.yinwei-01a12de8.workers.dev') {
    throw const RemoteEntryFailure('Use the Yinwei entry link');
  }
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    // The bookmark root is a landing page, even when the laptop is online.
    // Only /open returns the current checked laptop origin.
    final request = await http.getUrl(initial.resolve('/open'));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 10));
    final location = response.headers.value('location');
    await response.drain<void>().timeout(const Duration(seconds: 10));
    if (response.statusCode == 200 && location == null) {
      throw const RemoteEntryFailure(
          'Laptop unavailable · run Start-Yinwei-Backend.bat on the laptop, '
          'wait for BACKEND READY, then sign in again.');
    }
    final next = location == null ? null : Uri.tryParse(location);
    if (![301, 302, 303, 307, 308].contains(response.statusCode) ||
        next == null ||
        !quick(next) ||
        next.userInfo.isNotEmpty ||
        next.hasQuery ||
        next.hasFragment ||
        !['', '/', '/remote/signin'].contains(next.path)) {
      throw const RemoteEntryFailure(
          'Yinwei entry could not provide a trusted laptop connection. '
          'Check the laptop connection and try again.');
    }
    return next.replace(path: '');
  } finally {
    http.close(force: true);
  }
}
