import 'package:flutter/material.dart';
import 'package:local_models_flutter/local_models_flutter.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  NativeRuntimeSummary? _summary;
  final _localModelsFlutterPlugin = LocalModelsFlutter();

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    final summary = await _localModelsFlutterPlugin.getRuntimeSummary();

    if (!mounted) return;

    setState(() {
      _summary = summary;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Plugin example app')),
        body: Center(
          child: Text(
            _summary == null
                ? 'Loading runtime summary...'
                : 'Bridge: ${_summary!.bridgeVersion}\nMetal: ${_summary!.metalAvailable}\nPlatform: ${_summary!.platform}',
          ),
        ),
      ),
    );
  }
}
