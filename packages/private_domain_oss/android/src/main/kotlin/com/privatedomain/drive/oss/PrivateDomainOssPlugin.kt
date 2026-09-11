package com.privatedomain.drive.oss

import android.content.Context
import android.content.ContentValues
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import com.alibaba.sdk.android.oss.ClientException
import com.alibaba.sdk.android.oss.OSSClient
import com.alibaba.sdk.android.oss.ServiceException
import com.alibaba.sdk.android.oss.callback.OSSCompletedCallback
import com.alibaba.sdk.android.oss.common.auth.OSSStsTokenCredentialProvider
import com.alibaba.sdk.android.oss.internal.OSSAsyncTask
import com.alibaba.sdk.android.oss.model.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap

class PrivateDomainOssPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private lateinit var applicationContext: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    @Volatile private var client: OSSClient? = null
    @Volatile private var bucket: String? = null
    private val transfers = ConcurrentHashMap<String, NativeTransfer>()

    private data class NativeTransfer(
        @Volatile var task: OSSAsyncTask<*>? = null,
        @Volatile var stream: InputStream? = null,
        @Volatile var canceled: Boolean = false,
    ) {
        fun cancel() {
            canceled = true
            task?.cancel()
            runCatching { stream?.close() }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "private_domain_oss/methods")
        events = EventChannel(binding.binaryMessenger, "private_domain_oss/transfers")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        clearState()
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "configure" -> configure(call, result)
                "clearConfiguration" -> { clearState(); result.success(null) }
                "listObjects" -> listObjects(call, result)
                "putEmptyObject" -> putEmptyObject(call, result)
                "deleteObject" -> deleteObject(call, result)
                "deleteObjects" -> deleteObjects(call, result)
                "copyObject" -> copyObject(call, result)
                "uploadFile" -> uploadFile(call, result)
                "downloadFile" -> downloadFile(call, result)
                "getObjectBytes" -> getObjectBytes(call, result)
                "cancelTransfer" -> cancelTransfer(call, result)
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            fail(result, error)
        }
    }

    private fun configure(call: MethodCall, result: MethodChannel.Result) {
        val endpoint = call.requiredString("endpoint")
        val newBucket = call.requiredString("bucket")
        val provider = OSSStsTokenCredentialProvider(
            call.requiredString("accessKeyId"),
            call.requiredString("accessKeySecret"),
            call.requiredString("securityToken"),
        )
        client = OSSClient(applicationContext, endpoint, provider)
        bucket = newBucket
        result.success(null)
    }

    private fun clearState() {
        transfers.values.forEach { it.cancel() }
        transfers.clear()
        client = null
        bucket = null
    }

    private fun listObjects(call: MethodCall, result: MethodChannel.Result) {
        val (oss, bucketName) = requireSession()
        val request = ListObjectsRequest(
            bucketName,
            call.argument<String>("prefix") ?: "",
            call.argument<String>("marker"),
            call.argument<String>("delimiter"),
            call.argument<Int>("maxKeys") ?: 1000,
        )
        oss.asyncListObjects(request, object : OSSCompletedCallback<ListObjectsRequest, ListObjectsResult> {
            override fun onSuccess(request: ListObjectsRequest, response: ListObjectsResult) {
                succeed(result, mapOf(
                    "objects" to response.objectSummaries.map { summary -> mapOf(
                        "key" to summary.key,
                        "size" to summary.size,
                        "lastModifiedMilliseconds" to summary.lastModified?.time,
                        "etag" to summary.eTag,
                        "storageClass" to summary.storageClass,
                    ) },
                    "commonPrefixes" to response.commonPrefixes,
                    "isTruncated" to response.isTruncated,
                    "nextMarker" to response.nextMarker,
                ))
            }
            override fun onFailure(request: ListObjectsRequest, clientError: ClientException?, serviceError: ServiceException?) =
                fail(result, serviceError ?: clientError ?: IllegalStateException("OSS list failed"))
        })
    }

    private fun putEmptyObject(call: MethodCall, result: MethodChannel.Result) {
        val (oss, bucketName) = requireSession()
        val request = PutObjectRequest(bucketName, call.requiredString("key"), ByteArray(0))
        oss.asyncPutObject(request, completion(result))
    }

    private fun deleteObject(call: MethodCall, result: MethodChannel.Result) {
        val (oss, bucketName) = requireSession()
        val request = DeleteObjectRequest(bucketName, call.requiredString("key"))
        oss.asyncDeleteObject(request, completion(result))
    }

    private fun deleteObjects(call: MethodCall, result: MethodChannel.Result) {
        val (oss, bucketName) = requireSession()
        val keys = call.argument<List<String>>("keys") ?: emptyList()
        val request = DeleteMultipleObjectRequest(bucketName, keys, false)
        oss.asyncDeleteMultipleObject(request,
            object : OSSCompletedCallback<DeleteMultipleObjectRequest, DeleteMultipleObjectResult> {
                override fun onSuccess(request: DeleteMultipleObjectRequest, response: DeleteMultipleObjectResult) {
                    succeed(result, mapOf(
                        "deletedKeys" to (response.deletedObjects ?: emptyList<String>()),
                        "failedKeys" to (response.failedObjects ?: emptyList<String>()),
                    ))
                }
                override fun onFailure(request: DeleteMultipleObjectRequest, clientError: ClientException?, serviceError: ServiceException?) =
                    fail(result, serviceError ?: clientError ?: IllegalStateException("OSS delete failed"))
            })
    }

    private fun copyObject(call: MethodCall, result: MethodChannel.Result) {
        val (oss, bucketName) = requireSession()
        val request = CopyObjectRequest(
            bucketName, call.requiredString("from"), bucketName, call.requiredString("to"),
        )
        oss.asyncCopyObject(request, completion(result))
    }

    private fun uploadFile(call: MethodCall, result: MethodChannel.Result) {
        val (oss, bucketName) = requireSession()
        val taskId = call.requiredString("taskId")
        val key = call.requiredString("key")
        val path = call.requiredString("localPath")
        val file = File(path)
        require(file.isFile && file.canRead()) { "Local upload file is not readable" }
        val configuredThreshold = call.argument<Number>("multipartThresholdBytes")?.toLong() ?: 16L * 1024 * 1024
        // 小分片完成时可稳定得到真实进度，避免 SDK 单次上传只回调完成状态。
        val threshold = minOf(configuredThreshold, 1L * 1024 * 1024)
        val transfer = NativeTransfer()
        transfers.put(taskId, transfer)?.cancel()

        if (file.length() >= threshold) {
            val request = ResumableUploadRequest(bucketName, key, path, applicationContext.cacheDir.absolutePath)
            request.progressCallback = com.alibaba.sdk.android.oss.callback.OSSProgressCallback<ResumableUploadRequest> { _, current, total ->
                emitProgress(taskId, "upload", current, total)
            }
            transfer.task = oss.asyncResumableUpload(request,
                object : OSSCompletedCallback<ResumableUploadRequest, ResumableUploadResult> {
                    override fun onSuccess(request: ResumableUploadRequest, response: ResumableUploadResult) =
                        finishTransfer(taskId, result, null)
                    override fun onFailure(request: ResumableUploadRequest, clientError: ClientException?, serviceError: ServiceException?) =
                        finishTransfer(taskId, result, serviceError ?: clientError ?: IllegalStateException("OSS upload failed"))
                })
        } else {
            val request = PutObjectRequest(bucketName, key, path)
            request.progressCallback = com.alibaba.sdk.android.oss.callback.OSSProgressCallback<PutObjectRequest> { _, current, total ->
                emitProgress(taskId, "upload", current, total)
            }
            transfer.task = oss.asyncPutObject(request,
                object : OSSCompletedCallback<PutObjectRequest, PutObjectResult> {
                    override fun onSuccess(request: PutObjectRequest, response: PutObjectResult) =
                        finishTransfer(taskId, result, null)
                    override fun onFailure(request: PutObjectRequest, clientError: ClientException?, serviceError: ServiceException?) =
                        finishTransfer(taskId, result, serviceError ?: clientError ?: IllegalStateException("OSS upload failed"))
                })
        }
    }

    private fun downloadFile(call: MethodCall, result: MethodChannel.Result) {
        val (oss, bucketName) = requireSession()
        val taskId = call.requiredString("taskId")
        val mediaCollection = call.argument<String>("mediaStoreCollection")
        val directoryUri = call.argument<String>("directoryUri")
        val target: File? = if (mediaCollection == null && directoryUri == null) {
            File(call.requiredString("localPath"))
        } else {
            null
        }
        target?.parentFile?.mkdirs()
        val transfer = NativeTransfer()
        transfers.put(taskId, transfer)?.cancel()
        val request = GetObjectRequest(bucketName, call.requiredString("key"))
        transfer.task = oss.asyncGetObject(request,
            object : OSSCompletedCallback<GetObjectRequest, GetObjectResult> {
                override fun onSuccess(request: GetObjectRequest, response: GetObjectResult) {
                    transfer.stream = response.objectContent
                    try {
                        val total = response.contentLength.coerceAtLeast(0)
                        emitProgress(taskId, "download", 0, total)
                        val mediaUri = mediaCollection?.let {
                            createMediaStoreEntry(
                                collection = it,
                                displayName = call.argument<String>("displayName") ?: "download",
                            )
                        }
                        val documentUri = directoryUri?.let {
                            DocumentsContract.createDocument(
                                applicationContext.contentResolver,
                                android.net.Uri.parse(it),
                                MimeTypeMap.getSingleton().getMimeTypeFromExtension(
                                    (call.argument<String>("displayName") ?: "").substringAfterLast('.', "").lowercase(),
                                ) ?: "application/octet-stream",
                                call.argument<String>("displayName") ?: "download",
                            ) ?: throw IllegalStateException("无法在所选目录创建文件")
                        }
                        val output: OutputStream = if (mediaUri != null || documentUri != null) {
                            applicationContext.contentResolver.openOutputStream(mediaUri ?: documentUri!!)
                                ?: throw IllegalStateException("无法写入系统媒体库")
                        } else {
                            FileOutputStream(requireNotNull(target))
                        }
                        output.use {
                            response.objectContent.use { input ->
                                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                                var written = 0L
                                while (true) {
                                    if (transfer.canceled) throw TransferCanceledException()
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    output.write(buffer, 0, count)
                                    written += count
                                    emitProgress(taskId, "download", written, total)
                                }
                            }
                        }
                        if (mediaUri != null) {
                            applicationContext.contentResolver.update(
                                mediaUri,
                                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                                null,
                                null,
                            )
                        }
                        finishTransfer(taskId, result, null)
                    } catch (error: Throwable) {
                        target?.delete()
                        finishTransfer(taskId, result, error)
                    }
                }
                override fun onFailure(request: GetObjectRequest, clientError: ClientException?, serviceError: ServiceException?) =
                    finishTransfer(taskId, result, serviceError ?: clientError ?: IllegalStateException("OSS download failed"))
            })
    }

    private fun getObjectBytes(call: MethodCall, result: MethodChannel.Result) {
        val (oss, bucketName) = requireSession()
        val maxBytes = call.argument<Number>("maxBytes")?.toLong() ?: 0L
        require(maxBytes > 0 && maxBytes <= Int.MAX_VALUE) { "maxBytes is invalid" }
        val request = GetObjectRequest(bucketName, call.requiredString("key"))
        call.argument<String>("range")?.let { range ->
            Regex("^bytes=(\\d+)-(\\d+)$").matchEntire(range)?.let { match ->
                request.setRange(
                    Range(
                        match.groupValues[1].toLong(),
                        match.groupValues[2].toLong(),
                    ),
                )
            }
        }
        call.argument<String>("process")?.takeIf { it.isNotBlank() }?.let { request.setxOssProcess(it) }
        oss.asyncGetObject(request, object : OSSCompletedCallback<GetObjectRequest, GetObjectResult> {
            override fun onSuccess(request: GetObjectRequest, response: GetObjectResult) {
                try {
                    if (response.contentLength > maxBytes) throw ContentTooLargeException()
                    val output = ByteArrayOutputStream()
                    response.objectContent.use { input ->
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (output.size().toLong() + count > maxBytes) throw ContentTooLargeException()
                            output.write(buffer, 0, count)
                        }
                    }
                    succeed(result, output.toByteArray())
                } catch (error: Throwable) {
                    fail(result, error)
                }
            }
            override fun onFailure(request: GetObjectRequest, clientError: ClientException?, serviceError: ServiceException?) =
                fail(result, serviceError ?: clientError ?: IllegalStateException("OSS read failed"))
        })
    }

    private fun createMediaStoreEntry(collection: String, displayName: String): android.net.Uri {
        val extension = displayName.substringAfterLast('.', "").lowercase()
        val mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: if (collection == "images") "image/*" else "video/*"
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH,
                if (collection == "images") "Pictures/私域网盘" else "Movies/私域网盘")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = if (collection == "images") {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        return applicationContext.contentResolver.insert(uri, values)
            ?: throw IllegalStateException("无法创建系统媒体文件")
    }

    private fun cancelTransfer(call: MethodCall, result: MethodChannel.Result) {
        transfers[call.requiredString("taskId")]?.cancel()
        result.success(null)
    }

    private fun <Q : OSSRequest, R : OSSResult> completion(result: MethodChannel.Result) =
        object : OSSCompletedCallback<Q, R> {
            override fun onSuccess(request: Q, response: R) = succeed(result, null)
            override fun onFailure(request: Q, clientError: ClientException?, serviceError: ServiceException?) =
                fail(result, serviceError ?: clientError ?: IllegalStateException("OSS operation failed"))
        }

    private fun finishTransfer(taskId: String, result: MethodChannel.Result, error: Throwable?) {
        val transfer = transfers.remove(taskId)
        val actualError = if (transfer?.canceled == true) TransferCanceledException() else error
        if (actualError == null) succeed(result, null) else fail(result, actualError)
    }

    private fun emitProgress(taskId: String, direction: String, current: Long, total: Long) {
        mainHandler.post { eventSink?.success(mapOf(
            "taskId" to taskId,
            "direction" to direction,
            "transferredBytes" to current.coerceAtLeast(0),
            "totalBytes" to total.coerceAtLeast(0),
        )) }
    }

    private fun succeed(result: MethodChannel.Result, value: Any?) = mainHandler.post { result.success(value) }.let { Unit }

    private fun fail(result: MethodChannel.Result, error: Throwable) {
        val mapped = mapError(error)
        mainHandler.post { result.error(mapped.first, mapped.second, mapped.third) }
    }

    private fun mapError(error: Throwable): Triple<String, String, Map<String, Any?>> {
        if (error is TransferCanceledException || (error is ClientException && error.isCanceledException)) {
            return Triple("canceled", "传输已取消", emptyMap())
        }
        if (error is ContentTooLargeException) return Triple("invalidRequest", "对象内容超过允许上限", emptyMap())
        if (error is ServiceException) {
            val code = when (error.errorCode) {
                "SecurityTokenExpired", "InvalidAccessKeyId", "InvalidSecurityToken" -> "credentialExpired"
                "AccessDenied", "SignatureDoesNotMatch" -> "accessDenied"
                "NoSuchKey", "NoSuchBucket" -> "notFound"
                "InvalidArgument", "InvalidRequest" -> "invalidRequest"
                else -> "serviceError"
            }
            return Triple(code, "OSS 请求失败", mapOf(
                "statusCode" to error.statusCode,
                "ossCode" to error.errorCode,
                "requestId" to error.requestId,
            ))
        }
        if (error is ClientException) return Triple("networkUnavailable", "网络连接不可用", emptyMap())
        if (error is IllegalArgumentException || error is IllegalStateException) {
            return Triple("invalidRequest", error.message ?: "请求参数无效", emptyMap())
        }
        return Triple("unknown", "OSS 操作失败", emptyMap())
    }

    private fun requireSession(): Pair<OSSClient, String> = Pair(
        client ?: throw IllegalStateException("OSS is not configured"),
        bucket ?: throw IllegalStateException("OSS is not configured"),
    )

    private fun MethodCall.requiredString(name: String): String =
        argument<String>(name)?.takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("Missing $name")

    private class TransferCanceledException : Exception()
    private class ContentTooLargeException : Exception()
}
