#Requires -Version 5.1
<#
.SYNOPSIS
  Windows 内部ベータ検証 (#797): CI (windows-release.yml) が出した署名済み MSIX を
  取得し、署名証明書を信頼ストアへ import してインストールする。他 OS の
  TestFlight / Play 内部トラックに相当する、軽量な release ビルド検証経路。

.DESCRIPTION
  gh CLI で windows-release ワークフローの capsicum-msix artifact を download し、
  同梱の .cer を LocalMachine\TrustedPeople へ import、capsicum.msix を
  Add-AppxPackage でインストールする。cert import とインストールには管理者権限が
  要るため、非 elevated で起動された場合は自動で昇格して再実行する。

  ⚠️ 自己署名 MSIX のため #599 投げ銭 (Microsoft Store IAP) は動作しない
     (Store-install 版でのみ有効)。IAP を検証したい場合は Partner Center の
     package flight を使う。手順は docs/store-release-guide.md §4.6
     「Windows 内部ベータ提出」を参照。

.PARAMETER Run
  windows-release.yml の run id。省略時は -Branch の最新成功 run を自動選択する。

.PARAMETER Branch
  run を探索するブランチ (既定 develop)。-Run 指定時は無視される。

.PARAMETER KeepDownload
  ダウンロードした一時ディレクトリを消さずに残す (MSIX を手元に確保したいとき)。

.EXAMPLE
  # develop の最新成功ビルドを取得してインストール
  powershell -ExecutionPolicy Bypass -File distribution/windows/install-internal-beta.ps1

.EXAMPLE
  # 特定の run を指定 (artifact 保持は 14 日)
  powershell -ExecutionPolicy Bypass -File distribution/windows/install-internal-beta.ps1 -Run 28830297101
#>
[CmdletBinding()]
param(
  [string]$Run,
  [string]$Branch = 'develop',
  [switch]$KeepDownload
)

$ErrorActionPreference = 'Stop'
$repo = 'pooza/capsicum'
$packageName = '9AFBB08E.capsicum'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw 'gh (GitHub CLI) が見つかりません。https://cli.github.com/ から導入し `gh auth login` してください。'
}

# cert import (LocalMachine\TrustedPeople) と Add-AppxPackage には管理者権限が要る。
# 非 elevated で起動された場合は同じ引数で昇格して再実行する。
$principal = New-Object Security.Principal.WindowsPrincipal(
  [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host '管理者権限が必要です。昇格して再実行します (別ウィンドウが開きます)...' -ForegroundColor Yellow
  $argList = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
  if ($Run)          { $argList += @('-Run', $Run) }
  if ($Branch)       { $argList += @('-Branch', $Branch) }
  if ($KeepDownload) { $argList += '-KeepDownload' }
  Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs
  return
}

# 1. run id を解決する。
if (-not $Run) {
  Write-Host "ブランチ '$Branch' の最新成功 windows-release run を探索中..."
  $Run = gh run list --repo $repo --workflow windows-release.yml --branch $Branch `
           --status success --limit 1 --json databaseId --jq '.[0].databaseId'
  if (-not $Run) {
    throw "ブランチ '$Branch' に成功した windows-release run が見つかりません。-Run で明示してください。"
  }
}
Write-Host "対象 run: $Run"

# 2. capsicum-msix artifact を download する。
$work = Join-Path $env:TEMP ("capsicum-beta-" + $Run)
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Path $work | Out-Null
Write-Host 'capsicum-msix artifact をダウンロード中...'
gh run download $Run --repo $repo -n capsicum-msix -D $work
if ($LASTEXITCODE -ne 0) {
  throw @'
gh run download に失敗しました。考えられる原因:
  - artifact 失効 (保持期間 14 日) → 新しい run を -Run で指定する
  - Actions ストレージの一時障害で blob が 404 (メタデータは見えるのに取得だけ失敗)
    → workflow_dispatch で windows-release.yml を回し直すのが確実 (develop HEAD を直接ビルド)
'@
}

# 3. MSIX と .cer を artifact 内から探す (upload 時のパスがネストしているため再帰)。
$msix = Get-ChildItem -Path $work -Recurse -Filter *.msix | Select-Object -First 1
$cer  = Get-ChildItem -Path $work -Recurse -Filter *.cer  | Select-Object -First 1
if (-not $msix) { throw 'MSIX が artifact に見つかりません。' }
if (-not $cer) {
  throw '.cer が artifact に見つかりません。PFX secret 未投入の ephemeral cert build (エンドユーザーは import 不可) の可能性があります。'
}
Write-Host "MSIX: $($msix.FullName)"
Write-Host "CER : $($cer.FullName)"

# 4. 署名証明書を信頼ストアへ import する。appx の署名検証は LocalMachine の
#    TrustedPeople / Root を参照するため CurrentUser では不足 (= 管理者権限が要る)。
Write-Host '署名証明書を LocalMachine\TrustedPeople へ import 中...'
Import-Certificate -FilePath $cer.FullName -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null

# 5. 既存インストールを撤去してから入れる。同一 identity (9AFBB08E.capsicum) で
#    同一 MSIX パッケージバージョンを再インストールすると 0x80073CFB
#    (same identity・内容差分) で弾かれる (msix package は #798 の CI 以外では
#    pubspec の +build を捨てて 4 桁に丸めるため、build 違いでもパッケージ
#    バージョンが同じになりうる)。Store 版からの切替も含め、まず Remove してから
#    Add するのが唯一確実な手順。アカウントは Roaming のコンテナ外 secure storage
#    に残るので再ログイン不要、push 鍵セットは起動時に自動再同期される。
$existing = Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue
if ($existing) {
  Write-Host ("既存インストール ({0}, {1}) を撤去中..." -f $existing.Version, $existing.SignatureKind)
  $existing | Remove-AppxPackage
}
Write-Host 'capsicum.msix を Add-AppxPackage でインストール中...'
Add-AppxPackage -Path $msix.FullName

$pkg = Get-AppxPackage -Name $packageName
if ($pkg) {
  Write-Host ("インストール完了: {0} version {1}" -f $pkg.Name, $pkg.Version) -ForegroundColor Green
} else {
  Write-Warning "Add-AppxPackage 後に $packageName が見つかりません。手動で確認してください。"
}

if (-not $KeepDownload) { Remove-Item -Recurse -Force $work }

Write-Host ''
Write-Host '⚠️ この自己署名版では #599 投げ銭 (Microsoft Store IAP) は動作しません。' -ForegroundColor Yellow
Write-Host '   IAP を検証する場合は Partner Center の package flight を使ってください' -ForegroundColor Yellow
Write-Host '   (docs/store-release-guide.md §4.6「Windows 内部ベータ提出」参照)。' -ForegroundColor Yellow
