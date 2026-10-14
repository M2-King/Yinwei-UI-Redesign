import 'dart:io';

/// OS file lock: an abandoned process releases it automatically. The caller
/// holds the handle until process exit; never deletes another host's marker.
class RemoteHostLock {
  RemoteHostLock._(this._handle);
  final RandomAccessFile _handle;
  static Future<RemoteHostLock> acquire(Directory privateDirectory) async {
    await privateDirectory.create(recursive: true);
    final handle =
        await File('${privateDirectory.path}${Platform.pathSeparator}host.lock')
            .open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      return RemoteHostLock._(handle);
    } catch (_) {
      await handle.close();
      throw StateError('Another Yinwei host owns this session');
    }
  }

  Future<void> release() async {
    await _handle.unlock();
    await _handle.close();
  }
}
