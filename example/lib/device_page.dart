import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ymodem_lib/flutter_ymodem_lib.dart';
import 'package:path/path.dart' as p;

import 'ymodem_ble_transmitter.dart';

/// The YModem service / characteristic UUIDs used by many OTA receivers
/// (e.g. HM-10 style modules). Change them to match your hardware.
const String kDefaultServiceUuid16 = 'ffe0';
const String kDefaultWriteUuid16 = 'ffe1';
const String kDefaultNotifyUuid16 = 'ffe1';

/// Connects to a BLE device, lets the user pick a firmware file and sends it
/// with the YModem protocol over the selected characteristics.
class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.device});

  final BluetoothDevice device;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  BluetoothConnectionState _connectionState =
      BluetoothConnectionState.disconnected;
  List<BluetoothService> _services = [];
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  int _mtu = 23;

  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;

  String? _filePath;
  int _fileSize = 0;

  bool _enableHello = true;
  final TextEditingController _helloCtrl =
      TextEditingController(text: 'Customized Data');
  final TextEditingController _md5Ctrl = TextEditingController();
  int _sendSize = 1024;

  YModem? _ymodem;
  YModemBleTransmitter? _transmitter;
  bool _transferring = false;
  double _progress = 0;
  String _status = 'Idle';
  final List<String> _logs = [];
  final ScrollController _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _connSub = widget.device.connectionState.listen((state) {
      if (mounted) setState(() => _connectionState = state);
      if (state == BluetoothConnectionState.disconnected && _transferring) {
        _finishWithStatus('Connection lost');
      }
    });
    unawaited(_connect());
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _notifySub?.cancel();
    if (_ymodem != null) {
      unawaited(_ymodem!.stop());
    }
    if (widget.device.isConnected) {
      unawaited(_setNotifyEnabled(false));
      unawaited(widget.device.disconnect());
    }
    _helloCtrl.dispose();
    _md5Ctrl.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // BLE connection
  // -------------------------------------------------------------------------

  Future<void> _connect() async {
    _log('Connecting to ${widget.device.remoteId.str} ...');
    setState(() => _status = 'Connecting...');
    try {
      // Note: FlutterBluePlus 2.3.x requires a license parameter.
      // License.nonprofit covers personal / educational use; commercial
      // products must use License.commercial (see the flutter_blue_plus
      // LICENSE file).
      await widget.device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 20),
      );
      // Ask for a bigger MTU: larger packages = faster YModem transfers.
      try {
        _mtu = await widget.device.requestMtu(247, predelay: 0.35);
      } catch (e) {
        _log('requestMtu failed, keeping the negotiated MTU ($e)');
      }
      _mtu = widget.device.mtuNow;
      _log('Connected, MTU = $_mtu');

      final services =
          await widget.device.discoverServices(subscribeToServicesChanged: true);
      setState(() {
        _services = services;
        _status = 'Connected';
      });
      _autoSelectCharacteristics();
      _log(
        'Discovered ${services.length} service(s), '
        '${services.fold<int>(0, (n, s) => n + s.characteristics.length)} characteristic(s)',
      );
    } catch (e) {
      _log('Connection failed: $e');
      _finishWithStatus('Connection failed: $e');
    }
  }

  /// Preselects the default YModem characteristics (FFE0 / FFE1) when the
  /// device exposes them, otherwise the first usable ones.
  void _autoSelectCharacteristics() {
    BluetoothCharacteristic? write;
    BluetoothCharacteristic? notify;
    for (final service in _services) {
      for (final c in service.characteristics) {
        final writable = c.properties.write || c.properties.writeWithoutResponse;
        final notifiable = c.properties.notify || c.properties.indicate;
        if (writable) {
          // Prefer the default FFE1 characteristic when present, otherwise
          // keep the first writable one.
          write ??= c;
          if (_uuidIs16(c.uuid, kDefaultWriteUuid16)) write = c;
        }
        if (notifiable) {
          notify ??= c;
          if (_uuidIs16(c.uuid, kDefaultNotifyUuid16)) notify = c;
        }
      }
    }
    setState(() {
      _writeChar = write;
      _notifyChar = notify ?? write;
    });
  }

  Future<void> _setNotifyEnabled(bool enabled) async {
    final c = _notifyChar;
    if (c == null || !widget.device.isConnected) return;
    try {
      await c.setNotifyValue(enabled, timeout: 10);
      _log('Notifications ${enabled ? 'enabled' : 'disabled'} on '
          '${c.uuid.str}');
    } catch (e) {
      _log('setNotifyValue($enabled) failed: $e');
    }
  }

  // -------------------------------------------------------------------------
  // File picking
  // -------------------------------------------------------------------------

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Pick the firmware file to send',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) {
      _log('File not found: $path');
      return;
    }
    setState(() {
      _filePath = path;
      _fileSize = file.lengthSync();
      _status = 'File ready';
    });
    _log('Picked file: $path (${_fmtBytes(_fileSize)})');
  }

  // -------------------------------------------------------------------------
  // YModem transfer
  // -------------------------------------------------------------------------

  Future<void> _startTransfer() async {
    final path = _filePath;
    if (path == null) {
      _toast('Pick a firmware file first');
      return;
    }
    final writeChar = _writeChar;
    final notifyChar = _notifyChar;
    if (writeChar == null || notifyChar == null) {
      _toast('No suitable characteristics found');
      return;
    }
    if (!widget.device.isConnected) {
      _toast('Device is not connected');
      return;
    }

    setState(() {
      _transferring = true;
      _progress = 0;
      _status = 'Starting...';
    });

    await _setNotifyEnabled(true);
    _notifySub?.cancel();
    _notifySub = notifyChar.lastValueStream.listen(_onNotify);

    _transmitter = YModemBleTransmitter(
      device: widget.device,
      characteristic: writeChar,
      chunkDelay: const Duration(milliseconds: 8),
      onLog: _log,
    );

    _ymodem = YModem(
      fileName: p.basename(path),
      source: YModemFileSource(path),
      fileMd5: _md5Ctrl.text.trim(),
      sendSize: _sendSize,
      onDataReady: (package) {
        // Hand the package to the BLE chunk writer (queued internally).
        unawaited(_transmitter!.send(package));
      },
      onProgress: (sent, total) {
        if (mounted && total > 0) {
          setState(() {
            _progress = sent / total;
            _status =
                'Sending ${_fmtBytes(sent)} / ${_fmtBytes(total)} ...';
          });
        }
      },
      onSuccess: () => _finishWithStatus('Transfer complete ✔'),
      onFailed: (reason) => _finishWithStatus('Transfer failed: $reason'),
      onLog: _log,
    );

    _log(
      'Starting YModem: ${p.basename(path)} (${_fmtBytes(_fileSize)}, '
      'blocks of $_sendSize bytes'
      '${_enableHello ? ', hello="${_helloCtrl.text}"' : ''})',
    );
    // Fire and forget: the callbacks above drive the UI.
    unawaited(_ymodem!.start(_enableHello ? _helloCtrl.text : null));
  }

  Future<void> _stopTransfer() async {
    await _ymodem?.stop();
    _finishWithStatus('Stopped by user');
  }

  void _onNotify(List<int> data) {
    _log('<<< ${_hex(data)} (${data.length} bytes)');
    _ymodem?.onReceiveData(data);
  }

  void _finishWithStatus(String status) {
    if (!mounted) return;
    setState(() {
      _transferring = false;
      _status = status;
    });
    _log(status);
  }

  // -------------------------------------------------------------------------
  // UI helpers
  // -------------------------------------------------------------------------

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _log(String message) {
    final line =
        '[${DateTime.now().toIso8601String().substring(11, 19)}] $message';
    if (mounted) setState(() => _logs.add(line));
    if (_logs.length > 500) _logs.removeAt(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  static String _hex(List<int> data) {
    const printable = '0123456789abcdef';
    final buffer = StringBuffer();
    for (final b in data) {
      buffer
        ..write(printable[(b >> 4) & 0xF])
        ..write(printable[b & 0xF])
        ..write(' ');
    }
    return buffer.toString().trim();
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  /// A dropdown with an outlined label, keeping the selected value fully
  /// controlled so programmatic changes (auto selection) are reflected.
  Widget _charDropdown({
    required String label,
    required String? selectedId,
    required List<DropdownMenuItem<String>> options,
    required ValueChanged<String?> onChanged,
  }) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButton<String>(
        value: selectedId,
        isExpanded: true,
        isDense: true,
        underline: const SizedBox.shrink(),
        items: options,
        onChanged: onChanged,
      ),
    );
  }

  /// Checks whether a 128-bit UUID equals the 16-bit UUID [short16]
  /// (e.g. FFE1 == 0000FFE1-0000-1000-8000-00805F9B34FB).
  static bool _uuidIs16(Guid uuid, String short16) {
    final str = uuid.str128.replaceAll('-', '').toLowerCase();
    return str.substring(4, 8) == short16.toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final writeOptions = <DropdownMenuItem<String>>[];
    final notifyOptions = <DropdownMenuItem<String>>[];
    final charById = <String, BluetoothCharacteristic>{};
    for (final service in _services) {
      for (final c in service.characteristics) {
        final id = '${service.uuid.str128}|${c.uuid.str128}';
        final props = <String>[
          if (c.properties.read) 'read',
          if (c.properties.write) 'write',
          if (c.properties.writeWithoutResponse) 'writeNoResp',
          if (c.properties.notify) 'notify',
          if (c.properties.indicate) 'indicate',
        ].join(',');
        charById[id] = c;
        final label = '${c.uuid.str} ($props)';
        if (c.properties.write || c.properties.writeWithoutResponse) {
          writeOptions.add(DropdownMenuItem(value: id, child: Text(label)));
        }
        if (c.properties.notify || c.properties.indicate) {
          notifyOptions.add(DropdownMenuItem(value: id, child: Text(label)));
        }
      }
    }

    String charId(BluetoothCharacteristic c) =>
        '${c.serviceUuid.str128}|${c.uuid.str128}';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.platformName.isNotEmpty
            ? widget.device.platformName
            : widget.device.remoteId.str),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _infoCard(),
            const SizedBox(height: 12),
            _characteristicsCard(writeOptions, notifyOptions, charById, charId),
            const SizedBox(height: 12),
            _fileCard(),
            const SizedBox(height: 12),
            _optionsCard(),
            const SizedBox(height: 12),
            _transferCard(),
            const SizedBox(height: 12),
            _logCard(),
          ],
        ),
      ),
    );
  }

  Widget _infoCard() {
    final connected = _connectionState == BluetoothConnectionState.connected;
    return Card(
      child: ListTile(
        leading: Icon(
          connected ? Icons.bluetooth_connected : Icons.bluetooth,
          color: connected ? Colors.green : null,
        ),
        title: Text(widget.device.remoteId.str),
        subtitle: Text('MTU: $_mtu bytes · Status: $_status'),
        trailing: connected
            ? TextButton(
                onPressed: () => unawaited(widget.device.disconnect()),
                child: const Text('Disconnect'),
              )
            : FilledButton(
                onPressed: () => unawaited(_connect()),
                child: const Text('Connect'),
              ),
      ),
    );
  }

  Widget _characteristicsCard(
    List<DropdownMenuItem<String>> writeOptions,
    List<DropdownMenuItem<String>> notifyOptions,
    Map<String, BluetoothCharacteristic> charById,
    String Function(BluetoothCharacteristic) charId,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('BLE characteristics',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_services.isEmpty)
              const Text('No services discovered yet.')
            else ...[
              _charDropdown(
                label: 'Write characteristic (TX)',
                selectedId: _writeChar == null ? null : charId(_writeChar!),
                options: writeOptions,
                onChanged: (id) => setState(
                  () => _writeChar = id == null ? null : charById[id],
                ),
              ),
              const SizedBox(height: 12),
              _charDropdown(
                label: 'Notify characteristic (RX)',
                selectedId: _notifyChar == null ? null : charId(_notifyChar!),
                options: notifyOptions,
                onChanged: (id) => setState(
                  () => _notifyChar = id == null ? null : charById[id],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Defaults are service FFE0 and characteristic FFE1 '
                '(adjust $kDefaultServiceUuid16/$kDefaultWriteUuid16 '
                'constants for your hardware).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fileCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Firmware file',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _filePath == null
                        ? 'No file selected'
                        : '${p.basename(_filePath!)} (${_fmtBytes(_fileSize)})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () => unawaited(_pickFile()),
                  child: const Text('Pick file'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _optionsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('YModem options',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Send hello/handshake data first'),
              subtitle: const Text(
                'Some bootloaders expect a custom start signal and answer '
                'with "C" before package 0',
              ),
              value: _enableHello,
              onChanged: (v) => setState(() => _enableHello = v ?? true),
            ),
            TextField(
              controller: _helloCtrl,
              enabled: _enableHello,
              decoration: const InputDecoration(
                labelText: 'Hello data (UTF-8)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _md5Ctrl,
              decoration: const InputDecoration(
                labelText: 'MD5 (optional, sent in package 0)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Data block size',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              ),
              child: DropdownButton<int>(
                value: _sendSize,
                isExpanded: true,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 1024, child: Text('1024 bytes (STX)')),
                  DropdownMenuItem(value: 128, child: Text('128 bytes (SOH)')),
                ],
                onChanged: (v) => setState(() => _sendSize = v ?? 1024),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _transferCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Transfer',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (_transferring)
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                    ),
                    onPressed: () => unawaited(_stopTransfer()),
                    child: const Text('Stop'),
                  )
                else
                  FilledButton.icon(
                    onPressed: _writeChar == null
                        ? null
                        : () => unawaited(_startTransfer()),
                    icon: const Icon(Icons.upload),
                    label: const Text('Start YModem'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _transferring ? _progress : 0,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 8),
            Text(
              _transferring
                  ? '${(_progress * 100).toStringAsFixed(1)}% — $_status'
                  : _status,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _logCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Log', style: Theme.of(context).textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: () => setState(_logs.clear),
                  child: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.builder(
                controller: _logScroll,
                shrinkWrap: true,
                itemCount: _logs.length,
                itemBuilder: (context, index) => Text(
                  _logs[index],
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
