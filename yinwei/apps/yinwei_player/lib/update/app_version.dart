/// Semver-ish app identity for update comparison. Not a spatial/audio type.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.prerelease]);

  final int major;
  final int minor;
  final int patch;
  final String? prerelease;

  static final _pattern = RegExp(
    r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$',
  );

  factory AppVersion.parse(String raw) {
    final match = _pattern.firstMatch(raw.trim());
    if (match == null) {
      throw FormatException('invalid app version: $raw');
    }
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      match.group(4),
    );
  }

  bool get isStable => prerelease == null || prerelease!.isEmpty;

  @override
  String toString() => isStable
      ? '$major.$minor.$patch'
      : '$major.$minor.$patch-$prerelease';

  @override
  int compareTo(AppVersion other) {
    final core = major != other.major
        ? major.compareTo(other.major)
        : minor != other.minor
            ? minor.compareTo(other.minor)
            : patch.compareTo(other.patch);
    if (core != 0) return core;
    if (isStable && other.isStable) return 0;
    if (isStable) return 1;
    if (other.isStable) return -1;
    return _comparePrerelease(prerelease!, other.prerelease!);
  }

  bool operator <(AppVersion other) => compareTo(other) < 0;
  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator <=(AppVersion other) => compareTo(other) <= 0;
  bool operator >=(AppVersion other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) {
    return other is AppVersion &&
        major == other.major &&
        minor == other.minor &&
        patch == other.patch &&
        prerelease == other.prerelease;
  }

  @override
  int get hashCode => Object.hash(major, minor, patch, prerelease);

  static int _comparePrerelease(String a, String b) {
    final left = a.split('.');
    final right = b.split('.');
    final n = left.length < right.length ? left.length : right.length;
    for (var i = 0; i < n; i++) {
      final l = left[i];
      final r = right[i];
      final ln = int.tryParse(l);
      final rn = int.tryParse(r);
      final cmp = ln != null && rn != null
          ? ln.compareTo(rn)
          : l.compareTo(r);
      if (cmp != 0) return cmp;
    }
    return left.length.compareTo(right.length);
  }
}

/// Shipping identity of this Windows build. Keep in sync with pubspec version.
const String kYinweiAppVersion = '0.1.0';
