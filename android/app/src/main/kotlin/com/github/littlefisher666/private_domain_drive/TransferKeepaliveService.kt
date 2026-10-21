package com.github.littlefisher666.private_domain_drive

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle

/**
 * 传输保活前台服务（dataSync 类型）：仅承担「保活进程 + 挂进度通知」
 * 单一职责，不含任何传输业务逻辑；传输执行仍完整留在 Flutter 主
 * isolate。由 MethodChannel handler 调用 start/update/stop 控制。
 */
class TransferKeepaliveService : Service() {
    companion object {
        // v2：LOW 渠道在 ColorOS 等 ROM 上不渲染状态栏图标，升级为 DEFAULT 静音渠道；
        // 完成横幅需要 heads-up 悬浮，用 HIGH 静音渠道（AOSP 上 DEFAULT 不触发悬浮）。
        private const val CHANNEL_ID = "transfer_keepalive_v2"
        private const val LEGACY_CHANNEL_ID = "transfer_keepalive"
        private const val CHANNEL_NAME = "传输进度"
        private const val DONE_CHANNEL_ID = "transfer_keepalive_done_v2"
        private const val LEGACY_DONE_CHANNEL_ID = "transfer_keepalive_done"
        private const val DONE_CHANNEL_NAME = "传输完成提醒"
        private const val NOTIFICATION_ID = 1001
        private const val DONE_NOTIFICATION_ID = 1002
        private const val EXTRA_COMPLETED = "completed"
        private const val EXTRA_TOTAL = "total"
        private const val EXTRA_PERCENT = "percent"
        private const val TITLE = "正在传输"

        private var instance: TransferKeepaliveService? = null

        fun isRunning(): Boolean = instance != null

        fun start(context: Context, completed: Int, total: Int, percent: Int) {
            val intent = Intent(context, TransferKeepaliveService::class.java)
                .putExtra(EXTRA_COMPLETED, completed)
                .putExtra(EXTRA_TOTAL, total)
                .putExtra(EXTRA_PERCENT, percent)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** 服务运行中时直接刷新通知；未运行则忽略（队列空闲后不会残留）。 */
        fun update(completed: Int, total: Int, percent: Int) {
            instance?.showNotification(completed, total, percent)
        }

        fun stop(context: Context) {
            instance = null
            context.stopService(Intent(context, TransferKeepaliveService::class.java))
        }

        /** 队列转空闲后以完成渠道发出「传输完成」标准文字通知，点击清除并回应用。 */
        fun showCompletion(context: Context) {
            ensureChannels(context)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, DONE_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val notification = builder
                .setSmallIcon(R.drawable.ic_stat_cloud_drive)
                .setContentTitle(context.getString(R.string.notification_transfer_done_title))
                .setContentText(context.getString(R.string.notification_transfer_done_body))
                .setAutoCancel(true)
                .setContentIntent(launchIntent(context))
                .build()
            context.getSystemService(NotificationManager::class.java)
                .notify(DONE_NOTIFICATION_ID, notification)
        }

        private fun launchIntent(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            0,
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        private fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.deleteNotificationChannel(LEGACY_CHANNEL_ID)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "文件上传下载进行中的常驻通知"
                    setShowBadge(false)
                    setSound(null, null)
                },
            )
            manager.deleteNotificationChannel(LEGACY_DONE_CHANNEL_ID)
            manager.createNotificationChannel(
                NotificationChannel(
                    DONE_CHANNEL_ID,
                    DONE_CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "全部传输任务完成时的悬浮提醒"
                    setShowBadge(false)
                    setSound(null, null)
                },
            )
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        ensureChannels(this)
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val completed = intent?.getIntExtra(EXTRA_COMPLETED, 0) ?: 0
        val total = intent?.getIntExtra(EXTRA_TOTAL, 0) ?: 0
        val percent = intent?.getIntExtra(EXTRA_PERCENT, 0) ?: 0
        showNotification(completed, total, percent)
        // 进程被系统回收后不自动重建：下一次传输开始时由 Dart 侧重新启动。
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?) = null

    /** Android 15+ dataSync 服务超时上限（约 6 小时）触发的系统回调。 */
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    private fun showNotification(completed: Int, total: Int, percent: Int) {
        val notification = buildNotification(completed, total, percent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(completed: Int, total: Int, percent: Int): Notification {
        val text = "已完成 $completed/$total · $percent%"
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_cloud_drive)
            .setContentTitle(TITLE)
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(launchIntent(this))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
            // Android 16 实时更新（Live Updates）：请求系统提升展示，
            // ColorOS 16 将其渲染为刘海位置的流体云胶囊。
            builder.setExtras(
                Bundle().apply {
                    putBoolean("android.requestPromotedOngoing", true)
                },
            )
            builder.setStyle(
                Notification.ProgressStyle()
                    .setProgress(percent)
                    .setStyledByProgress(true),
            )
            builder.setShortCriticalText("$completed/$total · $percent%")
        } else {
            builder.setProgress(100, percent, false)
        }
        return builder.build()
    }
}
