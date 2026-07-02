# Windows インストール手順 (MSIX 自己署名直配・非公式)

> ⚠️ **この直配ルートは公式配布としては廃止しました（#760）。Windows の公式配布は [Microsoft Store](https://apps.microsoft.com/detail/9np2gr7m2w6p) 単独です**（証明書 import 不要、v1.27 で公開）。自己署名 MSIX の直接インストールは**非公式・サポート外**で、証明書 import を厭わない上級者が自己責任で行う場合の参考情報としてのみ残しています（README / 公式サイトからは案内していません）。

## インストール手順

1. 本 Release のアセットから以下をダウンロード:
   - `capsicum.msix` — アプリケーション本体
   - `capsicum-signing.cer` — 自己署名証明書 (信頼ストア import 用)

2. PowerShell を **管理者として実行** で開き、ダウンロードフォルダに `cd`

3. 証明書を Trusted People (LocalMachine) に import:

   ```powershell
   Import-Certificate -FilePath .\capsicum-signing.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople
   ```

4. MSIX をインストール:

   ```powershell
   Add-AppxPackage -Path .\capsicum.msix
   ```

5. スタートメニューから `capsicum` を起動

## アンインストール手順

設定 → アプリ → インストールされているアプリ → `capsicum` → アンインストール。

証明書も削除する場合は `Cert:\LocalMachine\TrustedPeople` から該当エントリを削除してください。

## 動作要件

- Windows 10 (1809+) / Windows 11 x64
- 管理者権限 (証明書 import + MSIX install のため、初回のみ)

## コード署名証明書について

OV コード署名証明書の取得（[#534](https://github.com/pooza/capsicum/issues/534)）は、Microsoft Store 公開達成（v1.27、2026-05-20 審査通過）により当面不要となっています。Store 経由のインストールでは Microsoft 側で再署名されるため SmartScreen を通過し、証明書 import も発生しません。本ページの自己署名 MSIX 直配は、その Store 配信を補完する上級者向けルートです。
