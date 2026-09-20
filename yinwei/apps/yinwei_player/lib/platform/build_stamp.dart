/// Build metadata injected by the experimental Codemagic workflow.
/// Local/Xcode 16.4 builds keep the not-injected defaults.
class YinweiBuildStamp {
  const YinweiBuildStamp();

  static const gitSha = String.fromEnvironment(
    'YINWEI_GIT_SHA',
    defaultValue: 'unknown',
  );
  static const buildNumber = String.fromEnvironment(
    'YINWEI_BUILD_NUMBER',
    defaultValue: 'unknown',
  );
  static const buildTimestamp = String.fromEnvironment(
    'YINWEI_BUILD_TIMESTAMP',
    defaultValue: 'unknown',
  );
  static const flutterVersion = String.fromEnvironment(
    'YINWEI_FLUTTER_VERSION',
    defaultValue: 'unknown',
  );
  static const xcodeVersion = String.fromEnvironment(
    'YINWEI_XCODE_VERSION',
    defaultValue: 'not-injected',
  );
  static const iosSdkVersion = String.fromEnvironment(
    'YINWEI_IOS_SDK_VERSION',
    defaultValue: 'not-injected',
  );
  static const workflow = String.fromEnvironment(
    'YINWEI_WORKFLOW',
    defaultValue: 'local',
  );
  static const phase = String.fromEnvironment(
    'YINWEI_PHASE',
    defaultValue: '7D1',
  );
}
