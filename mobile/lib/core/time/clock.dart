import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Current time. Injected so countdowns and lock timeouts are testable with a fake clock.
typedef Now = DateTime Function();

final clockProvider = Provider<Now>((ref) => DateTime.now);
