import 'package:flutter/material.dart';

import 'scan_page.dart';

/// Example application for [flutter_ymodem_lib]: scans for BLE devices and
/// sends a firmware file to the selected device using the YModem protocol.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const YModemOtaApp());
}

class YModemOtaApp extends StatelessWidget {
  const YModemOtaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YModem OTA Example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const ScanPage(),
    );
  }
}
