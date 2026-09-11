package net.shrieker.capsicum

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "net.shrieker.capsicum/share"

    /** #1108: OAuth の認可待ちのあいだ凍結されないようにする keep-alive の口。 */
    private val oauthKeepAliveChannel = "net.shrieker.capsicum/oauth_keepalive"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                if (call.method == "getSharedText") {
                    result.success(handleIntent(intent))
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            oauthKeepAliveChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // ⚠ start は **フォアグラウンドにいるあいだ**に呼ばれる前提
                // （foreground service はバックグラウンドから起動できない）。
                // Dart 側はブラウザを開く前に呼んでいる。
                "start" -> {
                    OAuthKeepAliveService.start(this)
                    result.success(OAuthKeepAliveService.shouldKeepAlive())
                }
                "stop" -> {
                    OAuthKeepAliveService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        // #276 ループバック OAuth の前面復帰用スキーム (capsicumauth://complete) は
        // 「アプリを前面に戻す」ことだけが目的。data を残したまま super に渡すと
        // Flutter の deep link 処理経由で go_router が該当ルート無しの例外
        // (GoException: no routes for location: capsicumauth://...) を投げるため、
        // data / action を中和してから委譲し、ルートとして解釈させない。
        if (intent.data?.scheme == "capsicumauth") {
            intent.data = null
            intent.action = Intent.ACTION_MAIN
        }
        super.onNewIntent(intent)
        setIntent(intent)
    }

    private fun handleIntent(intent: Intent): String? {
        if (intent.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            // Clear so the same intent is not consumed twice.
            intent.removeExtra(Intent.EXTRA_TEXT)
            return text
        }
        return null
    }
}
