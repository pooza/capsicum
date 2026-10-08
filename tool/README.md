# tool/

開発用のスクリプトです。

| スクリプト | 用途 |
| --- | --- |
| [`dev-run.sh`](dev-run.sh) | debug で capsicum を動かす（macOS / Linux） |
| [`dev-run.ps1`](dev-run.ps1) | 同上の Windows 版 |

## dev-run（debug で動かす）

コード生成から `flutter run` までを 1 本で回します（[#1179](https://github.com/pooza/capsicum/issues/1179)）。中でやっていることは次の 3 つです。

1. `secrets.env` を読む（無くても止まりません。後述）。
2. `build_runner` でコードを生成する。
3. `packages/capsicum` に移って `flutter run` する。`RELAY_SECRET` があれば `--dart-define` で渡します。

自前のオプション以外の引数（`-d` など）は、すべて `flutter run` へそのまま渡ります。

### 使用例

```sh
tool/dev-run.sh -d macos          # コード生成から
tool/dev-run.sh -s -d macos       # コード生成を飛ばす
tool/dev-run.sh -n -d 'iPhone 17' # 流すコマンドを表示するだけ
```

```powershell
powershell -ExecutionPolicy Bypass -File tool\dev-run.ps1 -d windows
powershell -ExecutionPolicy Bypass -File tool\dev-run.ps1 -SkipBuildRunner -d windows
powershell -ExecutionPolicy Bypass -File tool\dev-run.ps1 -DryRun -d windows
```

### オプション

| sh | ps1 | 働き |
| --- | --- | --- |
| `-s` / `--skip-build-runner` | `-SkipBuildRunner` | コード生成を飛ばす。生成物が最新なら起動が速くなります。 |
| `-n` / `--dry-run` | `-DryRun` | 実行せず、流すコマンドを表示する。秘密は `<RELAY_SECRET>` に伏せ、空白を含む引数は 1 引数と分かる形で表示します（そのまま貼って実行できます）。 |
| `-h` / `--help` | （なし） | 使い方を表示する。 |
| `--` | （なし） | 以降の引数を、自前のオプションと同じ名前でも `flutter run` へ渡す。 |

- ⚠ ps1 のオプションは**完全一致**だけを受け付けます。省略形（`-Dry` など）は `flutter run` へ渡ります。PowerShell の省略形の解釈で `-d windows` が `-DryRun` に吸われるのを防ぐためです。
- sh 版は `melos run build_runner` を、ps1 版は `build_runner` に依存する各パッケージで `dart run build_runner build` を流します。Windows では melos が PATH の都合で失敗することがあるためです。

### 環境変数

| 変数 | 働き |
| --- | --- |
| `CAPSICUM_SECRETS` | 読む `secrets.env` の場所を差し替える。既定は `~/.config/capsicum/secrets.env`（Windows は `%USERPROFILE%\.config\capsicum\secrets.env`）。 |

### 秘密が無いとき

`secrets.env` が無くても、`RELAY_SECRET` が空でも起動します。警告を出し、`--dart-define` を付けずに `flutter run` します。使えなくなるのはプッシュ通知だけです。

`secrets.env` の書式と、置かなかったときに何が使えなくなるかは [docs/dev-environment.md の「`flutter run` の実行手順」](../docs/dev-environment.md#flutter-run-の実行手順)にあります。

`SENTRY_DSN` は `secrets.env` にあっても渡しません。渡すと、開発中の例外が本番の Sentry へ送られるためです。
