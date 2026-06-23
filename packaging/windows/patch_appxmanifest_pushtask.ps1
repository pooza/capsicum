# WNS push バックグラウンドタスク (#474 フェーズ C) のマニフェスト注入。
#
# msix パッケージ (3.17.0) は windows.backgroundTasks /
# windows.activatableClass.inProcessServer 拡張を msix_config から宣言できない
# ため、`dart run msix:build` で生成した AppxManifest.xml に本スクリプトで
# 拡張を注入し、その後 `dart run msix:pack` でパッケージ化する。
#
#   - Application 配下の <Extensions> に backgroundTasks (Type=pushNotification)
#     EntryPoint=CapsicumPushTask.PushBackgroundTask を追記
#   - Package 直下に activatableClass.inProcessServer (push_background_task.dll /
#     ActivatableClassId 同上) を追加
#
# ActivatableClassId / EntryPoint / DLL 名は push_background_task.cpp・
# CMakeLists.txt（OUTPUT_NAME）・runner の登録（flutter_window）と一致させること。
#
# 使い方: patch_appxmanifest_pushtask.ps1 -ManifestPath <AppxManifest.xml>
param(
  [Parameter(Mandatory = $true)][string]$ManifestPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ManifestPath)) {
  throw "AppxManifest not found: $ManifestPath (run 'dart run msix:build' first)"
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$xml = [System.IO.File]::ReadAllText($ManifestPath, $utf8)

if ($xml -match 'CapsicumPushTask\.PushBackgroundTask') {
  Write-Host "manifest already patched for push background task; skipping"
  return
}

$appExtension = @"
        <Extension Category="windows.backgroundTasks" EntryPoint="CapsicumPushTask.PushBackgroundTask">
          <BackgroundTasks>
            <Task Type="pushNotification" />
          </BackgroundTasks>
        </Extension>
"@

$packageExtensions = @"
    <Extensions>
      <Extension Category="windows.activatableClass.inProcessServer">
        <InProcessServer>
          <Path>push_background_task.dll</Path>
          <ActivatableClass ActivatableClassId="CapsicumPushTask.PushBackgroundTask" ThreadingModel="both" />
        </InProcessServer>
      </Extension>
    </Extensions>
"@

# 1) Application 配下の <Extensions> に backgroundTasks を追記する。
#    現状 Application の <Extensions>（toast activator）が唯一の </Extensions>。
$appCount = ([regex]::Matches($xml, '</Extensions>')).Count
if ($appCount -ne 1) {
  throw "expected exactly 1 </Extensions> before patch, found $appCount"
}
$xml = $xml -replace '</Extensions>', "$appExtension`r`n          </Extensions>"

# 2) Package 直下（</Applications> の後）に activatableClass.inProcessServer を追加。
if ($xml -notmatch '</Applications>') {
  throw "</Applications> not found in manifest"
}
$xml = $xml -replace '</Applications>', "</Applications>`r`n$packageExtensions"

[System.IO.File]::WriteAllText($ManifestPath, $xml, $utf8)
Write-Host "patched AppxManifest with push background task extensions: $ManifestPath"
