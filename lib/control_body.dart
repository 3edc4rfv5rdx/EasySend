import 'dart:async';

/// Reads a small protocol body with both inactivity and wall-clock limits.
///
/// Cancelling the source subscription is part of every failure path so the
/// caller can release transfer ownership immediately.
Future<List<int>> readBoundedControlBytes(
  Stream<List<int>> source, {
  required int limit,
  required Duration inactivityTimeout,
  required Duration totalTimeout,
  required Object Function() tooLarge,
  required Object Function() inactivityExpired,
  required Object Function() totalExpired,
}) async {
  final List<int> bytes = [];
  final Completer<void> finished = Completer<void>();
  StreamSubscription<List<int>>? subscription;

  void fail(Object error, [StackTrace? stackTrace]) {
    if (finished.isCompleted) return;
    finished.completeError(error, stackTrace ?? StackTrace.current);
    final StreamSubscription<List<int>>? active = subscription;
    if (active != null) unawaited(active.cancel());
  }

  subscription = source
      .timeout(
        inactivityTimeout,
        onTimeout: (EventSink<List<int>> sink) =>
            sink.addError(inactivityExpired()),
      )
      .listen(
        (List<int> chunk) {
          if (bytes.length + chunk.length > limit) {
            fail(tooLarge());
            return;
          }
          bytes.addAll(chunk);
        },
        onError: (Object error, StackTrace stackTrace) =>
            fail(error, stackTrace),
        onDone: () {
          if (!finished.isCompleted) finished.complete();
        },
      );
  final Timer total = Timer(totalTimeout, () => fail(totalExpired()));
  try {
    await finished.future;
    return bytes;
  } finally {
    total.cancel();
    await subscription.cancel();
  }
}
