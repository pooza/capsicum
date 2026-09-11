#!/usr/bin/env bash
# lock_guard.sh のセルフテスト (#1036)。
#
# なぜ要るのか:
#   pubspec.lock ガード (#970) は本番の push でしか実行されない。v1.61 の
#   リリースで「条件に合致したときだけ落ちる」逆転が見つかったとき、壊れてから
#   気付くまでに複数リリースを挟んでいた。**ガードが正しい方向に効いていること
#   自体を CI で毎回検査する**のがこのスクリプトの役目。
#
#   ⚠ ガードが間違った方向に壊れると、正しい手順を踏んだ人が「規約どおりに
#   やったのに怒られる」状態になり、規約そのものへの信頼が落ちる。だから
#   「落ちるべきときに落ちる」だけでなく「**通るべきときに通る**」も検査する。
#
# 実行: bash .github/scripts/lock_guard_selftest.sh
#
# 第 1 引数で検査対象のガードを差し替えられる。「このテストに歯があるか」を
# 確かめる用途 — 壊れた実装を食わせて**落ちることを確認する**ために使う:
#   bash .github/scripts/lock_guard_selftest.sh /tmp/壊れた版.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
guard="${1:-$here/lock_guard.sh}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

# run_case <名前> <期待する exit> <FILES> <MSGS> <PUBSPEC_LINES> <WF_LINES>
#
# ⚠ **中身をファイルに書いてからパスを渡す。**環境変数に直接入れると、下の
# `big` のような大きな入力で Linux の execve 上限 (1 つあたり 128KB) に当たり、
# `Argument list too long` でガードの起動自体が失敗する。macOS では通るので
# 手元では再現せず、CI で初めて落ちた。
run_case() {
  local name="$1" want="$2" out got
  printf '%s' "$3" > "$work/files"
  printf '%s' "$4" > "$work/msgs"
  printf '%s' "$5" > "$work/pubspec_lines"
  printf '%s' "$6" > "$work/wf_lines"

  set +e
  out="$(
    FILES_FILE="$work/files" \
    MSGS_FILE="$work/msgs" \
    PUBSPEC_LINES_FILE="$work/pubspec_lines" \
    WF_LINES_FILE="$work/wf_lines" \
      bash "$guard" 2>&1
  )"
  got=$?
  set -e

  if [ "$got" = "$want" ]; then
    printf 'ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s: want exit=%s, got exit=%s\n' "$name" "$want" "$got"
    printf '     output: %s\n' "$out"
    fail=$((fail + 1))
  fi
}

# run_unwired_case <名前> <期待する exit> <FILES_FILE に入れる値（空なら未設定）>
#
# ⚠ **入力が配線されていないときの挙動を検査する (#1063)。**run_case は 4 本を
# 必ず設定するので、**呼び出し側の変数名の打ち間違い**という現実の失敗モードを
# 再現できない。FILES_FILE が空に倒れると `pubspec.lock unchanged; ok` で
# exit 0 になり、**CI ログ上は正常な緑と区別が付かない**。
#
# ⚠ 期待値を 1 ではなく 2 にしてあるのは、「規約違反で落ちた」のではなく
# 「配線ミスで落ちた」ことまで固定するため。ここが 1 に化けたら、ガードが
# 別の理由で落ちていることになる。
run_unwired_case() {
  local name="$1" want="$2" files_value="$3" out got
  printf '%s' "$lock" > "$work/files"
  printf '%s' 'fix: 何か直す' > "$work/msgs"
  : > "$work/pubspec_lines"
  : > "$work/wf_lines"

  set +e
  if [ -n "$files_value" ]; then
    out="$(
      FILES_FILE="$files_value" \
      MSGS_FILE="$work/msgs" \
      PUBSPEC_LINES_FILE="$work/pubspec_lines" \
      WF_LINES_FILE="$work/wf_lines" \
        bash "$guard" 2>&1
    )"
  else
    # ⚠ 実際の打ち間違い（FILE_FILES）をそのまま再現する。FILES_FILE は未設定。
    out="$(
      FILE_FILES="$work/files" \
      MSGS_FILE="$work/msgs" \
      PUBSPEC_LINES_FILE="$work/pubspec_lines" \
      WF_LINES_FILE="$work/wf_lines" \
        bash "$guard" 2>&1
    )"
  fi
  got=$?
  set -e

  if [ "$got" = "$want" ]; then
    printf 'ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s: want exit=%s, got exit=%s\n' "$name" "$want" "$got"
    printf '     output: %s\n' "$out"
    fail=$((fail + 1))
  fi
}

# #1036 の再現に要る「マッチの後ろに続く大量のデータ」。パイプバッファ (64KB)
# を超えないと SIGPIPE が起きないので、余裕を見て 300KB 取る。
big="$(head -c 300000 /dev/zero | tr '\0' 'x')"

lock='packages/capsicum/pubspec.lock'

# --- lock が動いていない場合 ---------------------------------------------
run_case 'lock 無変更なら通す' 0 \
  'packages/capsicum/lib/main.dart' 'fix: 何か直す' '' ''

# --- lock 単独 (随伴なし・印なし) は落とす -------------------------------
run_case 'lock 単独で印が無ければ落とす' 1 \
  "$lock" 'fix: 何か直す' '' ''

run_case 'lock 単独 + 大量のメッセージでも、印が無ければ落とす' 1 \
  "$lock" "fix: 何か直す
$big" '' ''

# --- 抜け道の印 (#970) ---------------------------------------------------
run_case 'chore(deps) の印があれば通す' 0 \
  "$lock" 'chore(deps): 推移的依存を上げる' '' ''

run_case '[pubspec-lock] の印があれば通す' 0 \
  "$lock" 'chore: lock を更新

[pubspec-lock]' '' ''

# ⚠ これが #1036 の回帰テスト。印が範囲の先頭近くにあり、後ろにデータが続く形。
# `git log` は新しい順に出すので、「リリース直前に chore(deps) を積んでから
# まとめて大きな push をする」という、このガードがまさに想定している使い方が
# この形になる。旧実装 (`printf ... | grep -q` + pipefail) はここで落ちた。
run_case '#1036: 印が先頭 + 後ろに大量のコミットでも通す' 0 \
  "$lock" "chore(deps): 推移的依存をリリース時点の最新互換版へ上げる
$big" '' ''

# --- 随伴の判定 (#976) ---------------------------------------------------
run_case 'pubspec.yaml の依存行が動いていれば通す' 0 \
  "$lock
packages/capsicum/pubspec.yaml" 'feat: 何か足す' \
  '+  dio: ^5.9.0' ''

run_case 'pubspec.yaml が version 行だけなら随伴と見なさず落とす' 1 \
  "$lock
packages/capsicum/pubspec.yaml" 'chore: バンプ' \
  '-version: 1.61.0+174
+version: 1.62.0+175' ''

run_case 'workflow の flutter-version pin が動いていれば通す' 0 \
  "$lock
.github/workflows/analyze.yml" 'chore: Flutter 追従' '' \
  '-          flutter-version: 3.44.5
+          flutter-version: 3.44.6'

# ⚠ こちらも #1036 と同型。pin の行が差分の先頭近くにあり、後ろに無関係な
# workflow の変更が続く形。旧実装はここでも逆転していた。
run_case '#1036: pin が先頭 + 後ろに大量の workflow 差分でも通す' 0 \
  "$lock
.github/workflows/analyze.yml" 'chore: Flutter 追従' '' \
  "+          flutter-version: 3.44.6
$big"

run_case 'workflow が pin 以外だけなら随伴と見なさず落とす' 1 \
  "$lock
.github/workflows/analyze.yml" 'ci: ジョブ名を変える' '' \
  '-      - name: Analyze
+      - name: Static analysis'

# --- 入力が未配線のとき (#1063) ------------------------------------------
# ⚠ どちらのケースも「lock が単独で変わっている」＝**本来は落ちるべき**入力を
# 用意したうえで、FILES_FILE だけを壊している。旧実装はここで
# `pubspec.lock unchanged; ok` と言って **exit 0** を返していた。
run_unwired_case 'FILES_FILE が未設定なら、素通りせず落ちる' 2 ''
run_unwired_case 'FILES_FILE が不在パスなら、素通りせず落ちる' 2 "$work/nonexistent"

# -------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
