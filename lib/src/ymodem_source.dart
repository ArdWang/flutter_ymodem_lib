import 'dart:io';
import 'dart:typed_data';

/// Abstract source of the file data that will be transmitted.
///
/// The [YModem] engine reads the source sequentially in blocks of
/// [YModem.sendSize] bytes, so the implementation does not need to load the
/// whole file into memory at once (firmware files can be large).
abstract class YModemSource {
  /// Total size of the data in bytes. Sent inside package 0.
  int get length;

  /// Opens the source. Called once before the transmission starts.
  Future<void> open();

  /// Reads up to [count] bytes into [buffer] starting at [start].
  ///
  /// Returns the number of bytes actually read, or `0` when the end of the
  /// data has been reached.
  Future<int> read(Uint8List buffer, int start, int count);

  /// Closes the source and releases every underlying resource.
  /// Must be safe to call multiple times.
  Future<void> close();
}

/// A [YModemSource] that reads from a file on disk.
///
/// ```dart
/// final source = YModemFileSource('/path/to/firmware.bin');
/// ```
class YModemFileSource implements YModemSource {
  YModemFileSource(this.path);

  /// Absolute path (or any path that `dart:io` can open) of the file.
  final String path;

  RandomAccessFile? _file;
  int _length = 0;

  @override
  int get length => _length;

  @override
  Future<void> open() async {
    _file = await File(path).open();
    _length = await _file!.length();
  }

  @override
  Future<int> read(Uint8List buffer, int start, int count) async {
    final file = _file;
    if (file == null) return 0;
    return file.readInto(buffer, start, count);
  }

  @override
  Future<void> close() async {
    await _file?.close();
    _file = null;
  }
}

/// A [YModemSource] that reads from an in-memory byte buffer.
///
/// ```dart
/// final source = YModemBytesSource(Uint8List.fromList(bytes));
/// ```
class YModemBytesSource implements YModemSource {
  YModemBytesSource(Uint8List bytes) : _bytes = bytes;

  final Uint8List _bytes;
  int _position = 0;

  @override
  int get length => _bytes.length;

  @override
  Future<void> open() async {
    _position = 0;
  }

  @override
  Future<int> read(Uint8List buffer, int start, int count) async {
    final remaining = _bytes.length - _position;
    if (remaining <= 0) return 0;
    final n = remaining < count ? remaining : count;
    buffer.setRange(start, start + n, _bytes, _position);
    _position += n;
    return n;
  }

  @override
  Future<void> close() async {}
}
