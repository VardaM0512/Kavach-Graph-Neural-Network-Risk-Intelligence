import 'package:flutter_test/flutter_test.dart';
import 'package:kavach/l10n/strings.dart';

void main() {
  test('all 23 languages are registered', () {
    expect(languages.length, 23);
    expect(languages.where((l) => l.rtl).map((l) => l.code).toSet(), {'ur', 'ks', 'sd'});
  });

  test('every language translates every English key', () {
    for (final l in languages) {
      for (final key in en.keys) {
        final s = translate(l.code, key);
        expect(s.isNotEmpty, true, reason: '${l.code}.$key is empty');
      }
    }
  });

  test('placeholders are filled and unknown keys fall back', () {
    expect(translate('hi', 'ansTopRisk', {'name': 'X', 'pd': '5%'}), contains('X'));
    expect(translate('xx', 'signIn'), en['signIn']);
    expect(translate('en', 'no_such_key'), 'no_such_key');
  });
}
