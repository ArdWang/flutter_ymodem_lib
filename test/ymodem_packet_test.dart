import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ymodem_lib/flutter_ymodem_lib.dart';

void main() {
  group('YModemPacket', () {
    test('EOT package is a single 0x04 byte', () {
      expect(YModemPacket.eotPackage, [0x04]);
    });

    test('file name package has the expected layout', () {
      final package =
          YModemPacket.createFileNamePackage('foo.bin', 1234, fileMd5: 'ab');

      expect(package.length, 3 + 128 + 2);
      // Header: SOH 00 FF.
      expect(package.sublist(0, 3), [0x01, 0x00, 0xFF]);
      // Payload: "foo.bin\0" + "1234\0" + "ab", NUL padded to 128 bytes.
      final payload = package.sublist(3, 3 + 128);
      expect(payload.sublist(0, 8), 'foo.bin'.codeUnits + [0x00]);
      expect(payload.sublist(8, 13), '1234'.codeUnits + [0x00]);
      expect(payload.sublist(13, 15), 'ab'.codeUnits);
      expect(payload.sublist(15), everyElement(0x00));
      // CRC-16 of the whole 128-byte block, big-endian.
      final crc = Crc16.calc(payload);
      expect(package[131], (crc >> 8) & 0xFF);
      expect(package[132], crc & 0xFF);
    });

    test('file name package throws when the metadata is too long', () {
      expect(
        () => YModemPacket.createFileNamePackage(
          'x' * 130,
          1,
        ),
        throwsArgumentError,
      );
    });

    test('1024-byte data package: STX header, 0x1A padding and CRC', () {
      final block = Uint8List(1024);
      block.setRange(0, 10, List<int>.filled(10, 0xAA));
      final package = YModemPacket.createDataPackage(block, 10, 1);

      expect(package.length, 3 + 1024 + 2);
      // Header: STX 01 FE.
      expect(package.sublist(0, 3), [0x02, 0x01, 0xFE]);
      // First 10 bytes are the data, the rest is 0x1A padding.
      expect(package.sublist(3, 13), everyElement(0xAA));
      expect(package.sublist(13, 3 + 1024), everyElement(0x1A));
      // CRC-16 of the (now padded) block, big-endian.
      final crc = Crc16.calc(block);
      expect(package[3 + 1024], (crc >> 8) & 0xFF);
      expect(package[3 + 1024 + 1], crc & 0xFF);
    });

    test('128-byte data package uses the SOH header', () {
      final block = Uint8List(128);
      block.setRange(0, 5, const [1, 2, 3, 4, 5]);
      final package = YModemPacket.createDataPackage(block, 5, 255);

      expect(package.sublist(0, 3), [0x01, 0xFF, 0x00]); // seq wraps to 255.
      expect(package.sublist(3, 8), [1, 2, 3, 4, 5]);
      expect(package.sublist(8, 3 + 128), everyElement(0x1A));
    });

    test('sequence wraps around 256 with the complement', () {
      final block = Uint8List(128);
      final package = YModemPacket.createDataPackage(block, 0, 256);
      expect(package.sublist(0, 3), [0x01, 0x00, 0xFF]);
    });

    test('end package is SOH 00 FF + 128 NULs + CRC', () {
      final package = YModemPacket.createEndPackage();
      expect(package.length, 3 + 128 + 2);
      expect(package.sublist(0, 3), [0x01, 0x00, 0xFF]);
      expect(package.sublist(3, 3 + 128), everyElement(0x00));
      final crc = Crc16.calc(Uint8List(128)); // CRC of 128 zero bytes.
      expect(package[131], (crc >> 8) & 0xFF);
      expect(package[132], crc & 0xFF);
    });

    test('block length must be 128 or 1024', () {
      expect(
        () => YModemPacket.createDataPackage(Uint8List(64), 0, 0),
        throwsArgumentError,
      );
    });
  });
}
