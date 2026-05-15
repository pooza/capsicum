# Windows インストール手順 (MSIX 自己署名直配)

> ⚠️ 配布対象は「証明書 import を厭わない上級ユーザー」です。Microsoft Store 公開は法人化対応待ちで、当面 GitHub Releases 経由の自己署名配布のみとなります。

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

## 中期的な改善予定

[#534](https://github.com/pooza/capsicum/issues/534) (v1.26 想定) でビーショック名義の OV コード署名証明書取得を予定しています。OV 署名 MSIX への切り替え後は SmartScreen を通過するため、上記 `Import-Certificate` ステップが不要になります。
