package com.github.littlefisher666.private_domain_drive_client

import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHODS = "private_domain_drive/share_import"
        private const val EVENTS = "private_domain_drive/share_import_events"
        private const val DOWNLOAD_DIRECTORY = "private_domain_drive/download_directory_picker"
        private const val APP_UPDATE = "private_domain_drive/app_update"
        private const val DOWNLOAD_DIRECTORY_REQUEST = 702
    }

    private val pendingItems = mutableListOf<Map<String, Any>>()
    private var eventSink: EventChannel.EventSink? = null
    private var directoryResult: MethodChannel.Result? = null
    private var pendingApkInstallPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHODS)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "takePendingItems" -> {
                        result.success(pendingItems.toList())
                        pendingItems.clear()
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    eventSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOAD_DIRECTORY)
            .setMethodCallHandler { call, result ->
                if (call.method != "select") return@setMethodCallHandler result.notImplemented()
                directoryResult = result
                startActivityForResult(
                    Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse("content://com.android.externalstorage.documents/root/primary:Download"))
                    },
                    DOWNLOAD_DIRECTORY_REQUEST,
                )
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_UPDATE)
            .setMethodCallHandler { call, result ->
                if (call.method != "installApk") return@setMethodCallHandler result.notImplemented()
                val path = call.argument<String>("path")
                    ?: return@setMethodCallHandler result.error("INVALID_ARGUMENT", "缺少 APK 路径", null)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                    pendingApkInstallPath = path
                    startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                        data = Uri.parse("package:$packageName")
                    })
                    return@setMethodCallHandler result.success(false)
                }
                result.success(openApkInstaller(path))
            }
        receiveShareIntent(intent, emit = false)
    }

    override fun onResume() {
        super.onResume()
        val path = pendingApkInstallPath ?: return
        pendingApkInstallPath = null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()) {
            openApkInstaller(path)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receiveShareIntent(intent, emit = true)
    }

    @Deprecated("Deprecated in Android API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != DOWNLOAD_DIRECTORY_REQUEST) return
        val result = directoryResult ?: return
        directoryResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) return result.success(null)
        contentResolver.takePersistableUriPermission(uri, data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
        result.success(uri.toString())
    }

    private fun receiveShareIntent(intent: Intent?, emit: Boolean) {
        val imported = intent?.let(::copySharedFiles).orEmpty()
        if (imported.isEmpty()) return
        if (emit && eventSink != null) {
            eventSink?.success(imported)
        } else {
            pendingItems += imported
        }
    }

    private fun openApkInstaller(path: String): Boolean {
        val apk = File(path)
        if (!apk.isFile) return false
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
        startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
        return true
    }

    private fun copySharedFiles(intent: Intent): List<Map<String, Any>> {
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) {
            return emptyList()
        }
        val uris = linkedSetOf<Uri>()
        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) clip.getItemAt(index).uri?.let(uris::add)
        }
        @Suppress("DEPRECATION")
        if (intent.action == Intent.ACTION_SEND) {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::add)
        } else {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::addAll)
        }
        return uris.mapNotNull(::copySharedFile)
    }

    private fun copySharedFile(uri: Uri): Map<String, Any>? {
        return runCatching {
            val metadata = queryMetadata(uri)
            val sourceName = metadata.first.ifBlank { "shared-file" }
            val safeName = sourceName.replace(Regex("[^A-Za-z0-9._-]"), "_")
            val directory = File(cacheDir, "shared-import").apply { mkdirs() }
            val destination = File(directory, "${UUID.randomUUID()}_$safeName")
            val input = contentResolver.openInputStream(uri)
                ?: throw IllegalStateException("无法读取分享文件")
            input.use {
                FileOutputStream(destination).use { output -> input.copyTo(output) }
            }
            mapOf(
                "id" to destination.name,
                "name" to sourceName,
                "size" to destination.length(),
                "path" to destination.absolutePath,
            )
        }.getOrNull()
    }

    private fun queryMetadata(uri: Uri): Pair<String, Long> {
        var name = uri.lastPathSegment.orEmpty()
        var size = 0L
        var cursor: Cursor? = null
        try {
            cursor = contentResolver.query(uri, null, null, null, null)
            if (cursor?.moveToFirst() == true) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
            }
        } finally {
            cursor?.close()
        }
        return name to size
    }
}
