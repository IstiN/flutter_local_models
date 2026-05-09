import 'dart:io';

import 'package:local_models_cli/local_models_cli.dart';

Future<void> main(List<String> arguments) async {
  final cli = LocalModelsCli();
  final code = await cli.run(arguments);
  if (code != 0) {
    exitCode = code;
  }
}
