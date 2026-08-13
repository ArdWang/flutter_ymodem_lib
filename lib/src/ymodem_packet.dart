import 'dart:convert';
import 'dart:typed_data';

import 'crc16.dart';

/// Utility class that encapsulates the different YModem packages.
///
/// Every package layout:
/// ```
/// +-------+-----+----------+-----------------+---------+
/// | start | seq | seq^0xFF | data (128/1024) | crc hi  | crc lo |
/// +-------+-----+----------+-----------------+---------+
/// ```
class YModemPacket {
  YModemPacket._();

  /// Start Of Header with a 128-byte data block.
  static const int soh = 0x01;

  /// Start Of Header with a 1024-byte data block.
  static const int stx = 0x02;

  /// End Of Transmission.
  static const int eot = 0x04;

  /// ACKnowledge.
  static const int ack = 0x06;

  /// Negative AcKnowledge.
  static const int nak = 0x15;

  /// CANcel character.
  static const int can = 0x18;

  /// Fill byte of the last package when it is not long enough.
  static const int cpmEof = 0x1A;

  /// The ASCII "C" the receiver sends to request a transmission.
  static const int stC = 0x43;

  /// The final empty package that terminates the transmission.
  static Uint8List createEndPackage() {
    return createDataPackage(Uint8List(128), 128, 0x00);
  }

  /// The single-byte EOT package.
  static Uint8List get eotPackage => Uint8List.fromList([eot]);

  /// Package 0: the file name package.
  ///
  /// Its 128-byte block contains `fileName\0fileByteSize\0fileMd5\0...`
  /// (NUL padded). The receiver uses it to know the name and the size of the
  /// upcoming file.
  static Uint8List createFileNamePackage(
    String fileName,
    int fileByteSize, {
    String fileMd5 = '',
  }) {
    final metadata = <int>[
      ...utf8.encode(fileName),
      0x00,
      ...utf8.encode('$fileByteSize'),
      0x00,
      ...utf8.encode(fileMd5),
    ];
    if (metadata.length > 128) {
      throw ArgumentError(
        'fileName + file size + md5 must fit into 128 bytes, '
        'got ${metadata.length} bytes',
      );
    }
    final block = Uint8List(128);
    block.setRange(0, metadata.length, metadata);
    return createDataPackage(block, 128, 0x00);
  }

  /// Encapsulates a data package.
  ///
  /// * [block] must be a 128 or 1024 bytes buffer; its header type is chosen
  ///   accordingly (SOH / STX).
  /// * Bytes from [dataLength] to the end of [block] are filled with
  ///   [cpmEof] — note that [block] is modified in place.
  /// * The CRC-16 of the whole block is appended big-endian.
  static Uint8List createDataPackage(
    Uint8List block,
    int dataLength,
    int sequence,
  ) {
    if (block.length != 128 && block.length != 1024) {
      throw ArgumentError(
        'block length must be 128 or 1024, got ${block.length}',
      );
    }
    if (dataLength < 0 || dataLength > block.length) {
      throw ArgumentError('dataLength out of range: $dataLength');
    }
    final headerType = block.length == 1024 ? stx : soh;

    // Pad the remaining data with CPMEOF if the block is not full.
    for (var i = dataLength; i < block.length; i++) {
      block[i] = cpmEof;
    }

    final crc = Crc16.calc(block);
    final header = _header(sequence, headerType);
    final builder = BytesBuilder(copy: true);
    builder.add(header);
    builder.add(block);
    builder.addByte((crc >> 8) & 0xFF);
    builder.addByte(crc & 0xFF);
    return builder.toBytes();
  }

  static Uint8List _header(int sequence, int headerType) {
    // The serial number of the package increases cyclically up to 256.
    final seq = sequence & 0xFF;
    return Uint8List.fromList([headerType, seq, (~seq) & 0xFF]);
  }
}
