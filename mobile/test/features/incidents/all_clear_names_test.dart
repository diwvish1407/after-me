import 'package:afterme/features/incidents/data/models/incident_models.dart';
import 'package:afterme/features/incidents/presentation/incident_labels.dart';
import 'package:flutter_test/flutter_test.dart';

AllClearTarget _t(String id, String name) =>
    AllClearTarget(contactId: id, displayName: name);

void main() {
  group('allClearNames', () {
    final mom = _t('c1', 'Mom');
    final brother = _t('c2', 'Brother');
    final sam = _t('c3', 'Sam');

    test('first notified first, in whatever order the server lists them', () {
      const order = ['c1', 'c2', 'c3'];
      for (final list in [
        [mom, brother, sam],
        [brother, mom, sam],
        [sam, brother, mom],
        [sam, mom, brother],
      ]) {
        expect(allClearNames(list, notifiedOrder: order), [
          'Mom',
          'Brother',
          'Sam',
        ]);
      }
    });

    test('without an order (or for people it does not know) alphabetical, '
        'ignoring case, the id breaking a tie', () {
      expect(allClearNames([sam, mom, brother]), ['Brother', 'Mom', 'Sam']);
      expect(allClearNames([_t('x', 'zed'), _t('y', 'Amy'), _t('z', 'bob')]), [
        'Amy',
        'bob',
        'zed',
      ]);
      expect(allClearNames([_t('b', 'Sam'), _t('a', 'Sam')]), ['Sam', 'Sam']);
      expect(allClearNames([sam, brother, mom], notifiedOrder: ['c1']), [
        'Mom',
        'Brother',
        'Sam',
      ], reason: 'the known one first, the rest alphabetical');
    });

    test('a target without a name is left out; nobody is nobody', () {
      expect(allClearNames([_t('c1', ''), mom]), ['Mom']);
      expect(allClearNames(const []), isEmpty);
    });

    test('does not change the list it was given', () {
      final list = [sam, mom];
      allClearNames(list);
      expect(list, [sam, mom]);
    });
  });
}
