import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'device_page.dart';

/// Scans for nearby BLE devices and opens the transfer page on tap.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final Map<DeviceIdentifier, ScanResult> _results = {};
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (mounted) setState(() => _adapterState = state);
    });
  }

  @override
  void dispose() {
    _adapterSub?.cancel();
    _scanSub?.cancel();
    super.dispose();
  }

  /// Requests the runtime Bluetooth permissions the platform needs.
  Future<void> _requestPermissions() async {
    if (kIsWeb) return;
    try {
      if (Platform.isAndroid) {
        // Android 12+ needs the new Bluetooth runtime permissions; older
        // Android versions need (coarse/fine) location for scanning.
        await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
        ].request();
        await Permission.locationWhenInUse.request();
      } else if (Platform.isIOS) {
        // iOS BLE permission is granted by the OS through the
        // NSBluetoothAlwaysUsageDescription prompt, but permission_handler
        // also exposes it for completeness.
        await Permission.bluetooth.request();
      }
      // Windows / macOS / Linux: no runtime permission needed.
    } catch (e) {
      _toast('Permission request failed: $e');
    }
  }

  Future<void> _startScan() async {
    if (_scanning) return;
    if (await FlutterBluePlus.isSupported == false) {
      _toast('Bluetooth Low Energy is not supported on this device');
      return;
    }
    if (_adapterState != BluetoothAdapterState.on) {
      _toast('Bluetooth adapter is not on');
      return;
    }
    await _requestPermissions();
    if (!mounted) return;

    setState(() {
      _scanning = true;
      _results.clear();
    });

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen(
      (results) {
        if (!mounted) return;
        setState(() {
          for (final result in results) {
            _results[result.device.remoteId] = result;
          }
        });
      },
      onError: (Object e) => _toast('Scan error: $e'),
    );

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    } catch (e) {
      _toast('startScan failed: $e');
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _stopScan() async {
    await FlutterBluePlus.stopScan();
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _turnOnAdapter() async {
    try {
      if (await FlutterBluePlus.isSupported == false) return;
      await FlutterBluePlus.turnOn(timeout: 15);
    } catch (e) {
      _toast('turnOn failed: $e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _openDevice(BluetoothDevice device) {
    _scanSub?.cancel();
    unawaited(_stopScan());
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DevicePage(device: device),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = _results.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(
        title: const Text('YModem OTA — BLE scan'),
        actions: [
          if (_scanning)
            TextButton(onPressed: _stopScan, child: const Text('Stop'))
          else
            TextButton(onPressed: _startScan, child: const Text('Scan')),
        ],
      ),
      body: Column(
        children: [
          if (_adapterState != BluetoothAdapterState.on)
            ListTile(
              leading: const Icon(Icons.bluetooth_disabled),
              title: const Text('Bluetooth adapter is off'),
              subtitle: const Text('Turn it on to scan for devices'),
              trailing: FilledButton(
                onPressed: _turnOnAdapter,
                child: const Text('Turn on'),
              ),
            ),
          if (_scanning)
            const LinearProgressIndicator(),
          Expanded(
            child: results.isEmpty
                ? Center(
                    child: Text(
                      _scanning
                          ? 'Scanning for BLE devices...'
                          : 'Press "Scan" to search for devices',
                    ),
                  )
                : ListView.separated(
                    itemCount: results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final result = results[index];
                      final device = result.device;
                      final name = result.advertisementData.advName;
                      return ListTile(
                        leading: const Icon(Icons.bluetooth_searching),
                        title: Text(name.isNotEmpty
                            ? name
                            : 'Unknown device'),
                        subtitle: Text(device.remoteId.str),
                        trailing: Text(
                          '${result.rssi} dBm',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        onTap: () => _openDevice(device),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
