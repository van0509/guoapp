import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

const _storageChannel = MethodChannel('duanju/storage');

class ExportDirectoryFailure implements Exception {
  const ExportDirectoryFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<T?> _storageRequest<T>(
  String method, [
  Map<String, String>? arguments,
]) async {
  try {
    return await _storageChannel.invokeMethod<T>(method, arguments);
  } on PlatformException catch (error) {
    throw ExportDirectoryFailure(error.message ?? '导出文件夹不可用，请重新选择');
  } on MissingPluginException {
    throw const ExportDirectoryFailure('此设备暂不支持通过系统文件夹导出');
  }
}

Future<bool> _storageResult(
  String method,
  Map<String, String> arguments,
) async {
  final result = await _storageRequest<bool>(method, arguments);
  if (result == null) {
    throw const ExportDirectoryFailure('未能确认文件导出结果，请检查目标文件夹');
  }
  return result;
}

bool isDocumentExportDirectory(String directory) =>
    Platform.isAndroid && Uri.tryParse(directory)?.scheme == 'content';

bool needsExportDirectorySelection(String directory) =>
    directory.isEmpty ||
    (Platform.isAndroid && !isDocumentExportDirectory(directory));

Future<String?> pickExportDirectory() async {
  if (Platform.isAndroid) {
    return _storageRequest<String>('pickExportDirectory');
  }
  return FilePicker.getDirectoryPath(dialogTitle: '选择导出目录');
}

String exportDirectoryLabel(String directory) {
  if (needsExportDirectorySelection(directory)) return '未设置 · 导出时选择文件夹';
  if (!isDocumentExportDirectory(directory)) return directory;
  final segments = Uri.parse(directory).pathSegments;
  final index = segments.indexOf('tree');
  if (index < 0 || index + 1 >= segments.length) return '已选择的导出文件夹';
  final name = segments[index + 1];
  return name.startsWith('primary:')
      ? '设备存储/${name.substring('primary:'.length)}'
      : name;
}

Future<bool> exportDocumentExists({
  required String directory,
  required String folder,
  required String name,
}) => _storageResult('exportFileExists', {
  'directory': directory,
  'folder': folder,
  'name': name,
});

Future<bool> copyExportDocument({
  required String directory,
  required String folder,
  required String name,
  required String source,
}) => _storageResult('copyExportFile', {
  'directory': directory,
  'folder': folder,
  'name': name,
  'source': source,
});
