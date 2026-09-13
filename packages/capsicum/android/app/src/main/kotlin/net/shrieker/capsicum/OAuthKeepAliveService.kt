package net.shrieker.capsicum

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * OAuth の loopback callback を待っているあいだ、プロセスを凍結させないための
 * foreground service (#1108)。
 *
 * Android の OAuth は loopback 方式（#276）で、`http://localhost:7099/oauth/callback`
 * を **capsicum 自身の HttpServer** で受ける。受けたあと `capsicumauth://complete` へ
 * 飛ぶ HTML を返すことでブラウザがアプリを前面に戻す、という設計になっている。
 *
 * ⚠⚠ **その HTML を返すのが capsicum 自身**なので、待っているあいだに
 * キャッシュアプリ freezer に凍結されると返せない。カーネルは TCP 接続を受けて
 * バッファに溜めるが、`accept()` も `read()` もアプリのコードなので 1 バイトも
 * 読めない。ブラウザは HTTP 応答を待ち続けて固まり、承認したのに何も起きない
 * ように見える。⚠ **裏に回ってから凍結までは実測 70 秒**（2026-09-09・Pixel 6a）で、
 * 他のアプリを開く必要すら無い。サーバーのログイン画面で ID とパスワードを打ち、
 * 2FA のコードを入れれば普通に超える。
 *
 * foreground service を持つプロセスは freezer の対象外になる（AOSP の
 * cached-apps-freezer が「active status」として foreground service を挙げている）。
 * 認可を待つあいだだけこれを上げる。
 *
 * ## ⚠⚠ `shortService` の 3 分を守らないと ANR する
 *
 * `shortService` は**型固有の権限が要らない**（`FOREGROUND_SERVICE` だけで済む）
 * 代わりに、制限時間が約 3 分ある。**超過して自分で止めないとアプリごと ANR
 * する**ので、[onTimeout] で必ず止める。⚠ **API 34 と API 35 でシグネチャが違う**
 * ので両方を override すること。片方だけだと、もう片方の API レベルで既定実装に
 * 落ちて ANR する。
 *
 * ⚠ **「Play への用途申告が要らないから」で選んだのではない**（起票時はそう考えて
 * いたが、調べて否定された）。**申告は宣言したすべての型が対象**で、機能説明と
 * 動作を示す動画の提出が要る。それでもこの型のままにしたのは、上限を受け入れる
 * 理由が「意味の正直さ」に変わったため —— OAuth の認可待ちは実際に「短く重要な
 * 処理」で、審査で説明しやすい。`dataSync` / `specialUse` なら上限は無いが、
 * 用途の説明が苦しくなる。
 *
 * 3 分を過ぎたら凍結され得るが、そのときの挙動は**この修正が入る前と同じ**
 * （手動でアプリに戻れば #1057 の経路でホームに着く）。退行はしない。
 *
 * ## API 31 未満では何もしない
 *
 * freezer は Android 12 (API 31) からなので、それ未満で service を上げても
 * 通知が出るだけで得が無い。[shouldKeepAlive] で弾く。
 */
class OAuthKeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground()
        // 再作成しない。認可待ちは画面の都合で始まるものなので、プロセスが死んだ
        // 後に OS が勝手に上げ直しても待つ相手が居ない。
        return START_NOT_STICKY
    }

    private fun startInForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // IMPORTANCE_LOW: 音も heads-up も出さない。認可のあいだだけ出る
            // 通知なので、割り込みにはしない。
            val channel = NotificationChannel(
                CHANNEL_ID,
                "ログイン",
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.description = "ブラウザでの認可が終わるのを待っているあいだ表示されます。"
            manager.createNotificationChannel(channel)
        }
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("ログインの完了を待っています")
            .setContentText("ブラウザで承認すると、自動でこのアプリに戻ります。")
            .setSmallIcon(R.drawable.ic_stat_oauth)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    // ⚠⚠ API 34 の 1 引数版。⚠ 消さないこと（下の 2 引数版だけでは API 34 で
    // 既定実装に落ちて ANR する）。
    override fun onTimeout(startId: Int) {
        handleTimeout()
    }

    // ⚠⚠ API 35 以降の 2 引数版。API 35+ ではこちらが呼ばれる。
    override fun onTimeout(startId: Int, fgsType: Int) {
        handleTimeout()
    }

    /**
     * 3 分を使い切ったとき。
     *
     * ⚠⚠ **黙って止めない。**ここから先は凍結され得るので、承認しても自動では
     * 戻らない（#1108 以前の挙動）。**ユーザーから見ると「押しても何も起きない」に
     * 戻る**ので、何をすればいいかを通知で渡してから止める。通知シェードは
     * ブラウザに居ても見えるので、いちばん見せたい相手に届く。
     */
    private fun handleTimeout() {
        // ⚠⚠ **案内で転んでも必ず止める。**`shortService` は時間内に自分で
        // 止めないと **アプリごと ANR する**。案内は「あると親切」なだけの
        // 付け足しなので、それが原因で本体を巻き込むことは許されない。
        try {
            postReturnHint()
        } catch (e: Exception) {
            Log.w(TAG, "failed to post the return hint", e)
        }
        stopSelf()
    }

    private fun postReturnHint() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // ⚠ keep-alive 本体とは別チャンネルにする。あちらは気づかれなくて
            // よい常駐通知なので IMPORTANCE_LOW だが、こちらは**気づいてもらう
            // のが仕事**。チャンネルの importance は作成後に上げられないので、
            // 同じチャンネルを使い回すと黙殺される。
            val channel = NotificationChannel(
                HINT_CHANNEL_ID,
                "ログインの案内",
                NotificationManager.IMPORTANCE_DEFAULT,
            )
            channel.description = "ブラウザでの承認に時間がかかったときに表示されます。"
            manager.createNotificationChannel(channel)
        }
        // タップでアプリを開く。⚠ **「アプリを自分で開いてください」と言うだけ
        // では、その操作自体が発見しづらい**（#1057 の「再起動すれば直る」が
        // 新規ユーザーに発見不可能だったのと同じ）。1 タップで済ませる。
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        // ⚠ **承認前にタップする人も想定する (#1111)。**当初の文面は「もう承認した
        // のに戻れない人」だけを想定していたが、実機検証では**まだ承認していない
        // 人**もタップした。その場合ログイン画面で待機に戻るだけなので、何をすれば
        // いいか分からない画面になる。⚠ **タップで前面に出れば凍結は解ける**ので、
        // ブラウザに戻って承認すればそのまま完了する——それを書いておく。
        //
        // ⚠ **BigTextStyle を付ける。**折りたたみ表示では 1 行に切られるので、
        // 2 つ目の案内（まだの人向け）が読めるのは展開したときだけになる。
        val hint = "承認が済んでいたら、ここをタップしてログインを完了してください。" +
            "まだ承認していない場合は、ブラウザに戻って承認してください。"
        val notification: Notification = Notification.Builder(this, HINT_CHANNEL_ID)
            .setContentTitle("ブラウザでの承認は終わりましたか？")
            .setContentText(hint)
            .setStyle(Notification.BigTextStyle().bigText(hint))
            .setSmallIcon(R.drawable.ic_stat_oauth)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        manager.notify(HINT_NOTIFICATION_ID, notification)
    }

    companion object {
        private const val CHANNEL_ID = "oauth_keep_alive"
        private const val NOTIFICATION_ID = 4108
        private const val HINT_CHANNEL_ID = "oauth_return_hint"
        private const val HINT_NOTIFICATION_ID = 4109
        private const val TAG = "OAuthKeepAlive"

        /**
         * この端末で keep-alive を上げる意味があるか。
         *
         * freezer は Android 12 (API 31) から。それ未満は凍結されないので、
         * 通知を出すだけ損になる。
         */
        fun shouldKeepAlive(): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

        /**
         * 認可待ちを開始する。
         *
         * ⚠ **呼び出し元がフォアグラウンドにいるあいだに呼ぶこと。**foreground
         * service はバックグラウンドからは起動できない。ブラウザを開く前
         * （＝ログイン画面が見えているあいだ）に呼ぶ前提。
         */
        fun start(context: Context) {
            if (!shouldKeepAlive()) return
            val intent = Intent(context, OAuthKeepAliveService::class.java)
            context.startForegroundService(intent)
        }

        /** 認可待ちを終える。認可完了・中断・タイムアウトのいずれでも呼ぶ。 */
        fun stop(context: Context) {
            if (!shouldKeepAlive()) return
            context.stopService(Intent(context, OAuthKeepAliveService::class.java))
            // ⚠ 3 分の打ち切りで出した案内も一緒に消す。ログインが終わった／
            // 画面を離れたあとに「承認は終わりましたか？」が残っていると、
            // タップしても何も起きない迷子の通知になる。
            context.getSystemService(NotificationManager::class.java)
                ?.cancel(HINT_NOTIFICATION_ID)
        }
    }
}
