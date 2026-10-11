/// Tells work that started for one session apart from work for the next one.
///
/// A `Notifier` is not replaced when the sign-in status changes: the same object runs
/// `build()` again. A request that was started for account A can therefore land after A
/// signed out and B signed in, and `ref.mounted` is still true. Whatever it carries (the
/// incident, the contacts' names, the instruction titles) would replace B's state.
///
/// Every controller that holds an account's data keeps one of these:
///
/// * [next] at the top of `build()`: that starts a new session scope (`build()` runs
///   again whenever the sign-in status changes, because it watches it);
/// * [current] when a request starts;
/// * [isCurrent] when its answer arrives: a stale one is dropped, never applied.
///
/// This is the same idea as `CheckInController`'s `_epoch`, and as the generation of
/// `SessionStore`, which guards the token refresh the same way.
final class SessionEpoch {
  int _value = 0;

  /// The token of the session scope now running.
  int get current => _value;

  /// Starts a new session scope: everything that captured an earlier token is stale.
  int next() => ++_value;

  /// Whether [token] was taken in the session scope that is running now.
  bool isCurrent(int token) => token == _value;
}
