import 'dart:io';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  final support = await getApplicationSupportDirectory();
  // ignore: avoid_print
  print('AppSupport: ${support.path}');
  final docs = await getApplicationDocumentsDirectory();
  // ignore: avoid_print
  print('Documents: ${docs.path}');
  // ignore: avoid_print
  print(Platform.environment['XDG_DATA_HOME'] ?? 'bos');
}
