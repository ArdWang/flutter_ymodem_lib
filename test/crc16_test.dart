import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ymodem_lib/flutter_ymodem_lib.dart';

void main() {
  group('Crc16', () {
    test('known check value for "123456789" is 0x31C3', () {
      // Check value of CRC-16/XMODEM.
      expect(Crc16.calc(utf8.encode('123456789')), 0x31C3);
    });

    test('empty input gives 0x0000', () {
      expect(Crc16.calc(const []), 0x0000);
    });

    test('table values match the reference implementation', () {
      // Hand-computed against the 256-entry table of the reference
      // Android library (com.bw.yml.CRC16):
      //   0x00 -> crc 0x0000
      //   0x01 -> crc 0x1021            (table[0x01])
      //   0x02 -> crc 0x101373 & 0xFFFF = 0x1373  (table[0x12] = 0x3273)
      //   0x03 -> crc 0x136131 & 0xFFFF = 0x6131  (table[0x10] = 0x1231)
      final data = Uint8List.fromList([0x00, 0x01, 0x02, 0x03]);
      expect(Crc16.calc(data), 0x6131);
    });

    test('0xFF byte checks against the last table entry (0x1EF0)', () {
      expect(Crc16.calc(const [0xFF]), 0x1EF0);
    });

    test('calcUint8 overload behaves like calc', () {
      final bytes = Uint8List.fromList(List<int>.generate(256, (i) => i));
      expect(Crc16.calcUint8(bytes), Crc16.calc(bytes));
    });

    test('trailingZeroBytes replicates the iOS YModemlib_iOS variant', () {
      final data = utf8.encode('123456789');
      // Two extra zero-byte iterations, like Cccal_CRC16 in YModem.c.
      final expected = Crc16.calc([...data, 0x00, 0x00]);
      final variant = Crc16.calc(data, trailingZeroBytes: 2);
      expect(variant, expected);
      // And it must differ from the standard XModem CRC.
      expect(variant, isNot(Crc16.calc(data)));
    });
  });
}
