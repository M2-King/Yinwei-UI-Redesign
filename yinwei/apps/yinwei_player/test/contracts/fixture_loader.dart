import 'dart:convert';
import 'dart:io';

Map<String, dynamic> loadContractFixture(String fileName) {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    final candidates = [
      File('${dir.path}/contracts/v1/fixtures/$fileName'),
      File('${dir.path}/yinwei/contracts/v1/fixtures/$fileName'),
    ];
    for (final file in candidates) {
      if (file.existsSync()) {
        return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      }
    }
    dir = dir.parent;
  }
  throw StateError('contract fixture not found: $fileName (cwd=${Directory.current.path})');
}

double asF(Object? v) => (v as num).toDouble();
