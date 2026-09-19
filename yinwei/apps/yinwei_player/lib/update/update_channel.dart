/// Release channels. Isolated from audio / spatial authority.
enum UpdateChannel {
  stable,
  beta,
  developer,
}

extension UpdateChannelWire on UpdateChannel {
  String get wireName {
    switch (this) {
      case UpdateChannel.stable:
        return 'stable';
      case UpdateChannel.beta:
        return 'beta';
      case UpdateChannel.developer:
        return 'developer';
    }
  }

  static UpdateChannel parse(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'stable':
        return UpdateChannel.stable;
      case 'beta':
        return UpdateChannel.beta;
      case 'developer':
      case 'dev':
        return UpdateChannel.developer;
      default:
        throw FormatException('unknown update channel: $raw');
    }
  }

  /// Stable sees Stable only. Beta sees Stable+Beta. Developer sees all.
  Set<UpdateChannel> get visibleChannels {
    switch (this) {
      case UpdateChannel.stable:
        return const {UpdateChannel.stable};
      case UpdateChannel.beta:
        return const {UpdateChannel.stable, UpdateChannel.beta};
      case UpdateChannel.developer:
        return const {
          UpdateChannel.stable,
          UpdateChannel.beta,
          UpdateChannel.developer,
        };
    }
  }
}
