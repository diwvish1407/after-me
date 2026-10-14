import 'package:afterme/app/leave_guards.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LeaveGuards', () {
    test('with nothing registered there is nothing to ask', () async {
      final guards = LeaveGuards();
      expect(guards.isGuarding, isFalse);
      expect(await guards.confirmLeave(), isTrue);
    });

    test('one that says stay stops the leaving, one that says leave lets it '
        'go', () async {
      final guards = LeaveGuards();
      final owner = Object();
      var answer = false;
      guards.register(owner, () async => answer);
      expect(guards.isGuarding, isTrue);
      expect(await guards.confirmLeave(), isFalse);
      answer = true;
      expect(await guards.confirmLeave(), isTrue);
    });

    test(
      'asks every screen in turn and stops at the first that stays',
      () async {
        final guards = LeaveGuards();
        final asked = <String>[];
        guards
          ..register('a', () async {
            asked.add('a');
            return false;
          })
          ..register('b', () async {
            asked.add('b');
            return true;
          });
        expect(await guards.confirmLeave(), isFalse);
        expect(asked, ['a']);
      },
    );

    test('waits, bounded, for a screen that is saving', () async {
      final guards = LeaveGuards();
      var saving = true;
      guards.register(Object(), () async => true, isBusy: () => saving);
      expect(guards.isBusy, isTrue);
      expect(
        await guards.whenIdle(
          maxWait: const Duration(milliseconds: 50),
          poll: const Duration(milliseconds: 10),
        ),
        isFalse,
        reason: 'gives up after the bound',
      );
      Future<void>.delayed(
        const Duration(milliseconds: 30),
        () => saving = false,
      );
      expect(
        await guards.whenIdle(
          maxWait: const Duration(seconds: 2),
          poll: const Duration(milliseconds: 10),
        ),
        isTrue,
      );
    });

    test('a screen that registers again replaces its question, and one that '
        'unregisters is not asked', () async {
      final guards = LeaveGuards();
      final owner = Object();
      guards.register(owner, () async => false);
      guards.register(owner, () async => true);
      expect(await guards.confirmLeave(), isTrue);
      guards.unregister(owner);
      expect(guards.isGuarding, isFalse);
    });
  });
}
