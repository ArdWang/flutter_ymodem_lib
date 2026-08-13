import 'dart:typed_data';

/// CRC-16/XMODEM (a.k.a. CRC-16-CCITT-FALSE).
///
/// Parameters:
///  * polynomial: 0x1021 (1 + x^2 + x^15 + x^16)
///  * initial value: 0x0000
///  * no reflection, no final XOR
///
/// Check value: crc16 of ASCII "123456789" == 0x31C3.
///
/// The result is appended to every YModem package as two bytes,
/// **big-endian** (high byte first).
class Crc16 {
  Crc16._();

  static final List<int> _table = _buildTable();

  static List<int> _buildTable() {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var crc = i << 8;
      for (var j = 0; j < 8; j++) {
        crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
        crc &= 0xFFFF;
      }
      table[i] = crc;
    }
    return table;
  }

  /// Calculates the CRC-16 of [block].
  ///
  /// Set [trailingZeroBytes] to 2 to replicate the CRC variant used by the
  /// iOS library `YModemlib_iOS` (`Cccal_CRC16`), which processes two extra
  /// zero bytes after the payload. Some devices' bootloader firmware expects
  /// that variant; the standard (XModem) CRC is used when it is 0.
  static int calc(List<int> block, {int trailingZeroBytes = 0}) {
    var crc = 0x0000;
    for (var i = 0; i < block.length; i++) {
      final b = block[i] & 0xFF;
      crc = ((crc << 8) ^ _table[((crc >> 8) ^ b) & 0xFF]) & 0xFFFF;
    }
    for (var i = 0; i < trailingZeroBytes; i++) {
      crc = ((crc << 8) ^ _table[(crc >> 8) & 0xFF]) & 0xFFFF;
    }
    return crc;
  }

  /// Calculates the CRC-16 of [data] (convenience overload).
  static int calcUint8(Uint8List data, {int trailingZeroBytes = 0}) =>
      calc(data, trailingZeroBytes: trailingZeroBytes);
}
