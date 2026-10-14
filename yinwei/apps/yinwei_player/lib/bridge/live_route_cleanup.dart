/// Attempt every recovery step even if an earlier asynchronous step fails.
/// The owner disposes its live controller only after this future completes.
Future<void> cleanupLiveRoute({
  required Future<void> pendingRoute,
  required Future<void> Function() stop,
  required Future<void> Function() restore,
}) async {
  Object? firstError;
  StackTrace? firstStack;
  for (final step in <Future<void> Function()>[
    () => pendingRoute,
    stop,
    restore,
  ]) {
    try {
      await step();
    } catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
  }
  if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
}
