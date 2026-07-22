import 'package:flutter_test/flutter_test.dart';
import 'package:trading_game/core/app_update.dart';

void main() {
  group('isNewerBuild', () {
    test('true only when boot and latest are real and differ', () {
      expect(isNewerBuild('abc1234', 'def5678'), isTrue);
    });

    test('false when unchanged', () {
      expect(isNewerBuild('abc1234', 'abc1234'), isFalse);
    });

    test('false when either id is missing (offline / 404)', () {
      expect(isNewerBuild(null, 'def5678'), isFalse);
      expect(isNewerBuild('abc1234', null), isFalse);
      expect(isNewerBuild(null, null), isFalse);
    });

    test('false when the server still serves the dev placeholder', () {
      expect(isNewerBuild('abc1234', 'dev'), isFalse);
    });
  });
}
