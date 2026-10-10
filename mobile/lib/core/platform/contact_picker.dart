import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A contact chosen in the system picker.
@immutable
class PickedContact {
  const PickedContact({required this.name, required this.email});

  final String name;
  final String email;
}

/// Why nothing was picked.
enum ContactPickError {
  /// No app on this device can pick contacts.
  unavailable,
}

/// The system contact picker (USER_FLOWS.md §3 step 4).
///
/// It uses Android's `ACTION_PICK`, which grants read access to the one chosen contact
/// only, so the app needs **no `READ_CONTACTS` permission** (SECURITY.md §11).
abstract interface class ContactPicker {
  /// The chosen contact, or null when the person cancelled. Throws
  /// [ContactPickException] when no picker is available.
  Future<PickedContact?> pick();
}

class ContactPickException implements Exception {
  const ContactPickException(this.error);

  final ContactPickError error;
}

class PlatformContactPicker implements ContactPicker {
  const PlatformContactPicker();

  static const MethodChannel _channel = MethodChannel(
    'app.afterme/contact_picker',
  );

  @override
  Future<PickedContact?> pick() async {
    try {
      final result = await _channel.invokeMapMethod<String, String>('pick');
      if (result == null) {
        return null;
      }
      final email = (result['email'] ?? '').trim();
      if (email.isEmpty) {
        return null;
      }
      return PickedContact(name: (result['name'] ?? '').trim(), email: email);
    } on MissingPluginException {
      throw const ContactPickException(ContactPickError.unavailable);
    } on PlatformException {
      throw const ContactPickException(ContactPickError.unavailable);
    }
  }
}

final contactPickerProvider = Provider<ContactPicker>(
  (ref) => const PlatformContactPicker(),
);
