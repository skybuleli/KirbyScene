import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ci gate probe', () {
    expect(1, 2, reason: '故意失败，反证 test 门禁会红');
  });
}
