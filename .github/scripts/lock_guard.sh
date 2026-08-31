#!/usr/bin/env bash
# pubspec.lock churn ガード (#970) の判定本体。
#
# なぜワークフローから切り出したか (#1036):
#   このガードは v1.61 のリリースで「条件に合致したときだけ落ちる」逆転を
#   起こしていた。`printf ... | grep -q` + pipefail が原因で、しかも入力が
#   小さいと再現しないため、**本番の push でしか実行されない限り、壊れていても
#   次のリリースまで分からない**。判定を呼び出し側から切り離してここへ置き、
#   lock_guard_selftest.sh から表駆動で検査できるようにした。
#
#   git に依存する部分 (どのコミット範囲を見るか、force-push / ブランチ作成の
#   スキップ) は環境が無いと再現できないので、workflow 側に残してある。ここは
#   「差分とメッセージを渡されたら通すか落とすか」だけを担当する。
#
# 入力 (環境変数。いずれも改行区切りの文字列。未設定は空として扱う):
#   FILES          この push / PR で変わったファイルパスの一覧
#   MSGS           範囲内のコミットメッセージ (subject + body)
#   PUBSPEC_LINES  pubspec.yaml 群の変更行 (git diff -U0 から +++/--- を除いたもの)
#   WF_LINES       .github/workflows 配下の変更行 (同上)
#
# 出力: 判定理由を stdout へ。exit 0 = 通過 / exit 1 = 違反。
#
# ⚠⚠ **`... | grep -q` の形を書かないこと (#1036)。** `grep -q` はマッチした
#   時点で終了するので、パイプの書き手が SIGPIPE で落ち、pipefail がパイプライン
#   全体を失敗にする。すると「合致したときだけ判定が false になる」逆転が起きる。
#   判定への入力は必ず herestring (`<<<`) で渡す。
set -euo pipefail

FILES="${FILES:-}"
MSGS="${MSGS:-}"
PUBSPEC_LINES="${PUBSPEC_LINES:-}"
WF_LINES="${WF_LINES:-}"

lock_changed=false
while IFS= read -r f; do
  case "$f" in
    pubspec.lock|*/pubspec.lock) lock_changed=true ;;
  esac
done <<< "$FILES"

if [ "$lock_changed" != true ]; then
  echo "pubspec.lock unchanged; ok"
  exit 0
fi

# 随伴の判定は**ファイル名一致ではなく実変更の中身**で行う (#976)。
# 「pubspec.yaml か workflow のどれかが変わっていれば随伴」だと、バージョン
# だけの bump や無関係な CI ジョブ編集でも lock の単独更新を通してしまい、
# このガードが素通りする (PR #973 の Codex P2)。
companion_changed=false

# pubspec.yaml: `version:` 行**だけ**の変更はバンプであって依存の変更ではない。
# それ以外の行が動いていれば依存セクションが触られたと見なす (dependencies /
# dev_dependencies / dependency_overrides / SDK 制約はすべてここに落ちる)。
if [ -n "$PUBSPEC_LINES" ]; then
  non_version="$(grep -vE '^[+-]version:' <<< "$PUBSPEC_LINES" || true)"
  if [ -n "$non_version" ]; then
    companion_changed=true
    echo "pubspec.yaml dependency lines changed"
  else
    echo "pubspec.yaml changed but only the version bump line"
  fi
fi

# workflow: 実際に `flutter-version:` の行が動いたときだけ随伴と見なす。
if [ "$companion_changed" != true ]; then
  if grep -qE '^[+-][[:space:]]*flutter-version:' <<< "$WF_LINES"; then
    companion_changed=true
    echo "workflow flutter-version pin changed"
  fi
fi

if [ "$companion_changed" = true ]; then
  echo "pubspec.lock changed together with a real dependency / pin change; ok"
  exit 0
fi

# 抜け道: リリース前の `flutter pub upgrade` (store-release-guide §4.1) は
# lock だけが動く正当な操作。コミットメッセージで明示されていれば通す。
if grep -qiE 'chore\(deps\)|\[pubspec-lock\]' <<< "$MSGS"; then
  echo "lock-only change is an explicit deps/upgrade commit; ok"
  exit 0
fi

echo "::error::pubspec.lock が pubspec.yaml / Flutter pin (workflow) の変更を伴わず単独で変わっています (#970)。依存を足す/上げるなら pubspec.yaml を、Flutter 版追従なら workflow の pin を同じ変更に含めてください。リリース前の pub upgrade（意図的な lock 単独更新）はコミットメッセージを chore(deps) にするか本文に [pubspec-lock] を付けてください。"
exit 1
