package a.a.easysend

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "easysend/service"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start", "update" -> {
                        val intent = Intent(this, TransferService::class.java).apply {
                            action = if (call.method == "start") {
                                TransferService.ACTION_START
                            } else {
                                TransferService.ACTION_UPDATE
                            }
                            putExtra(TransferService.EXTRA_TITLE, call.argument<String>("title"))
                            putExtra(TransferService.EXTRA_TEXT, call.argument<String>("text"))
                            putExtra(TransferService.EXTRA_PROGRESS, call.argument<Int>("progress") ?: -1)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }

                    "stop" -> {
                        val intent = Intent(this, TransferService::class.java).apply {
                            action = TransferService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
