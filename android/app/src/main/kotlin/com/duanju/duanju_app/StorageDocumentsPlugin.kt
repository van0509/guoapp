package com.duanju.duanju_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

class StorageDocumentsPlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var binding: ActivityPluginBinding? = null
    private var pendingPicker: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "duanju/storage")
        channel.setMethodCallHandler(this)
        attached = true
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
        pendingPicker = null
        worker.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        binding?.removeActivityResultListener(this)
        binding = null
    }

    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        pendingPicker?.error("folder_picker_closed", "文件夹选择已结束，请重试", null)
        pendingPicker = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "pickExportDirectory") {
            pickDirectory(result)
            return
        }
        if (call.method != "exportFileExists" && call.method != "copyExportFile") {
            result.notImplemented()
            return
        }
        worker.execute {
            val outcome = runCatching {
                val tree = exportTree(call.argument<String>("directory"))
                val folder = documentName(call.argument<String>("folder"))
                val name = documentName(call.argument<String>("name"))
                if (call.method == "exportFileExists") {
                    val show = findChild(tree, folder)
                    if (show == null) false else {
                        require(show.second == DocumentsContract.Document.MIME_TYPE_DIR)
                        findChild(show.first, name) != null
                    }
                } else {
                    copyFile(tree, folder, name, sourceFile(call.argument<String>("source")))
                }
            }
            main.post {
                if (attached) outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { failure ->
                        val message = when (failure) {
                            is SecurityException -> "导出文件夹不可访问，请重新选择导出目录"
                            is IllegalArgumentException -> "导出路径无效，请重新选择导出目录"
                            else -> "文件导出失败，请检查目标空间与文件夹是否可写"
                        }
                        result.error("document_export_failed", message, null)
                    }
                )
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun pickDirectory(result: MethodChannel.Result) {
        val activity = binding?.activity
        if (activity == null || pendingPicker != null) {
            result.error("folder_picker_busy", "暂时无法选择文件夹，请稍后重试", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        pendingPicker = result
        try {
            activity.startActivityForResult(intent, 4713)
        } catch (_: Exception) {
            pendingPicker = null
            result.error("folder_picker_unavailable", "设备未提供系统文件夹选择器；下载仍保存在应用目录", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != 4713) return false
        val result = pendingPicker ?: return true
        pendingPicker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            require(uri.scheme == "content" && DocumentsContract.isTreeUri(uri))
            val flags = (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            require((flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION) != 0)
            require((flags and Intent.FLAG_GRANT_READ_URI_PERMISSION) != 0)
            context.contentResolver.takePersistableUriPermission(uri, flags)
            result.success(uri.toString())
        } catch (_: Exception) {
            result.error("folder_picker_unavailable", "该文件夹无法保存访问许可，请选择其他导出位置", null)
        }
        return true
    }

    private fun exportTree(value: String?): Uri {
        val tree = Uri.parse(requireNotNull(value))
        require(tree.scheme == "content" && DocumentsContract.isTreeUri(tree))
        if (context.contentResolver.persistedUriPermissions.none {
                it.uri == tree && it.isReadPermission && it.isWritePermission
            }) throw SecurityException("Directory grant is unavailable")
        return DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
    }

    private fun documentName(value: String?): String {
        val name = requireNotNull(value)
        require(name.isNotBlank() && name.length <= 255 && name != "." && name != ".." &&
            !name.contains('/') && !name.contains('\\') && !name.contains('\u0000'))
        return name
    }

    private fun findChild(parent: Uri, name: String): Pair<Uri, String>? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(parent, DocumentsContract.getDocumentId(parent))
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE)
        val cursor = context.contentResolver.query(children, columns, null, null, null)
            ?: throw IOException("Directory cannot be read")
        cursor.use {
            while (it.moveToNext()) {
                if (it.getString(1) == name) {
                    return DocumentsContract.buildDocumentUriUsingTree(parent, it.getString(0)) to it.getString(2)
                }
            }
        }
        return null
    }

    private fun sourceFile(value: String?): File {
        val file = File(requireNotNull(value)).canonicalFile
        val roots = listOf(context.filesDir, context.cacheDir, context.noBackupFilesDir) +
            context.getExternalFilesDirs(null).filterNotNull() + context.externalCacheDirs.filterNotNull()
        require(file.isFile && roots.any {
            val root = it.canonicalPath
            file.path.startsWith(root + File.separator)
        })
        return file
    }

    private fun copyFile(tree: Uri, folder: String, name: String, source: File): Boolean {
        val existingFolder = findChild(tree, folder)
        val parent = if (existingFolder == null) {
            DocumentsContract.createDocument(context.contentResolver, tree,
                DocumentsContract.Document.MIME_TYPE_DIR, folder)
                ?: throw IOException("Directory cannot be created")
        } else {
            require(existingFolder.second == DocumentsContract.Document.MIME_TYPE_DIR)
            existingFolder.first
        }
        if (findChild(parent, name) != null) return false
        val mime = when (name.substringAfterLast('.', "").lowercase()) {
            "mp4", "m4v" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "ts" -> "video/mp2t"
            "mov" -> "video/quicktime"
            else -> "application/octet-stream"
        }
        val target = DocumentsContract.createDocument(context.contentResolver, parent, mime, name)
            ?: throw IOException("Document cannot be created")
        try {
            source.inputStream().use { input ->
                val stream = context.contentResolver.openOutputStream(target, "w")
                    ?: throw IOException("Document cannot be written")
                stream.use { output -> input.copyTo(output) }
            }
        } catch (failure: Exception) {
            runCatching { DocumentsContract.deleteDocument(context.contentResolver, target) }
            throw failure
        }
        return true
    }
}
