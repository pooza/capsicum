# Microsoft Store 審査対応 — Notes for Certification（ログイン手順）

関連 Issue: [#544](https://github.com/pooza/capsicum/issues/544)（Microsoft Store 公開）

## このドキュメントの位置づけ

Microsoft Store の認定で **Policy 10.3.1 (App Is Testable - Test Account)** —
*「the test account that was provided doesn't work」* —
を繰り返し受けるため、Partner Center の
**Submission Options > Notes for Certification** に貼る確定文面を管理する。
Windows 提出のたびに再利用する現役運用ドキュメント。

## なぜ繰り返すのか（根本原因）

リジェクトは「アカウントが壊れている」のではない。デモアカウント
（`mstdn.delmulin.com`）は有効で、過去に App Store / Google Play の同種審査も
通過実績がある。原因は **審査員が OAuth フローに到達できず "動かない" と判断**
していること。capsicum は自前のアカウント体系を持たず、

- ログインは「サーバーを選択 → システムブラウザで OAuth 認可」方式
- 資格情報は **アプリでなくブラウザ認可ページに入力する**
- Windows / Linux は `flutter_web_auth_2` の server impl で
  **システムブラウザ + localhost callback (port 7099)** 経路
  （[CLAUDE.md「Linux 固有の差分」](CLAUDE.md) 参照）

という前提が審査員の手元で再現しづらい。App Store / Google Play は
ログイン手順を Notes に明示することで通過した（[archive の記録](archive/googleplay-review-notes-login.md)）。
Microsoft でも同じ対策を Notes for Certification で行う。

## Windows 固有の落とし穴

mobile（アプリ内 webview）と異なり、Windows はシステムブラウザ経由のため
認可後にブラウザ側へ `http://localhost:7099/oauth/callback` のページが残り、
**「接続できません」風の表示**になることがある。アプリは別ウィンドウで既に
ログイン完了しているが、審査員がブラウザの表示を見て「失敗」と誤認しやすい。
この点を Notes に必ず明記する。

## Notes for Certification（提出時に貼り付ける英文）

> デモアカウントの実資格情報はリポジトリに置かない。`<demo account email>` /
> `<demo account password>` を提出時に `~/.config/capsicum/secrets.env`
> 由来の審査用アカウント値に差し替える（[secrets.env の所在](CLAUDE.md)）。

```text
=== IMPORTANT: PLEASE READ BEFORE TESTING ===

capsicum is a third-party client for decentralized social networks
(Mastodon / Misskey). It has NO account system of its own. Sign-in is
performed by selecting a server and authorizing via your system web
browser (OAuth). The test credentials below are NOT entered in the app
itself — they are entered on the browser authorization page.

=== TEST ACCOUNT ===

Server   : デルムリン丼  (mstdn.delmulin.com)  — a preset server
Username : <demo account email>
Password : <demo account password>

=== HOW TO SIGN IN (step by step) ===

1. Launch capsicum. On first launch, accept the Terms of Use to proceed.
2. On the login screen, select "デルムリン丼" (mstdn.delmulin.com) from
   the preset server list.
3. Click "ログイン" (Login). Your default web browser will open an
   authorization page hosted by mstdn.delmulin.com.
4. On that browser page, enter the Username and Password listed above,
   then click "承認" (Authorize).
5. After authorizing, the browser may display a blank page or a
   "localhost" / "this site can't be reached" message. THIS IS EXPECTED
   AND DOES NOT MEAN FAILURE. The app has already received the
   authorization. Switch back to the capsicum window — you will be
   signed in and the timeline will be shown.

If the app does not appear to return automatically, simply click on the
capsicum application window; the sign-in has already completed.

=== ABOUT THIS APP (Third-Party Client) ===

capsicum is an independent, third-party client for the open-source
Mastodon and Misskey platforms. It is not affiliated with or endorsed by
those projects.
```

## 提出手順

1. デモアカウント（`mstdn.delmulin.com` の審査用アカウント）が有効か事前確認
2. Partner Center → 当該 submission → **Submission Options > Notes for
   Certification** に上記英文を貼り付け（`<demo account ...>` を実値に置換）
3. 同 submission の Store listing 等の必須欄に不足がないことを確認して提出
4. 認定結果（公開 / 差し戻し）を次回同期時に追跡。差し戻し時は理由コードを
   本ドキュメントに追記して文面を改訂する
