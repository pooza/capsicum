#!/bin/sh
# PreToolUse(Bash) guard — AppImage を APPIMAGELAUNCHER_DISABLE=1 なしで起動する形を拒否する。
#
# なぜ機械で止めるのか:
#   inori（Linux 検証機・Ubuntu 26.04）には AppImageLauncher が入っていて、
#   `~/Applications` に無い AppImage を初めて起動するたびに「移すか」の確認の
#   ダイアログを出し、**押すまで起動が止まる**。新しくビルドした AppImage は毎回
#   これに当たる。inori は RustDesk 越しに見るだけなので、**止まったことに誰も
#   気付けない**（2026-11-18 に #1391 の検証で踏み、pooza がたまたま画面を見て
#   押した。押すと AppImage が `~/Applications/<名前>_<ハッシュ>.AppImage` へ
#   移され、元の場所から消える）。
#
#   `APPIMAGELAUNCHER_DISABLE=1` を付ければダイアログは出ず、ファイルも動かない
#   （同日に実測）。メモリに書いただけでは読み落とすので、機械で止める。
#
# 止めるのは「.AppImage を**コマンドとして実行する**形」だけ:
#   - `X.AppImage …` / `nohup X.AppImage &` / `env V=1 X.AppImage` 等
#   - `A=/path/X.AppImage; … "$A"` のように変数に入れてから起動する形
# 通す形:
#   - 同じ断片か、それより前に `APPIMAGELAUNCHER_DISABLE=1` がある
#   - `--appimage-extract` などランタイムの引数（アプリを起動しない）
#   - `ls` / `cp` / `appimagetool` 等の**引数**に .AppImage が出るだけ
#
# ⚠ **このスクリプトに `set -o pipefail` を足さないこと**（deny-shell-loops.sh と
#   同じ理由・#1036。`grep -q` がマッチ時点で抜けると、検出できたときに限って
#   素通りする）。

cmd=$(jq -r '.tool_input.command // ""')

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# heredoc の本文は見ない（コミットや Issue の本文でこの話を書いて誤爆しないため・
# deny-cd-then-git.sh と同じ処理）。awk 内の \047 はシングルクォート。
scrubbed=$(printf '%s\n' "$cmd" | awk '
  BEGIN { delim = "" }
  delim != "" {
    line = $0
    sub(/^[ \t]+/, "", line)
    if (line == delim) delim = ""
    next
  }
  {
    s = $0
    gsub(/<<</, "  ", s)
    if (match(s, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
      d = substr(s, RSTART, RLENGTH)
      sub(/^<<-?[ \t]*/, "", d)
      gsub(/[\047"]/, "", d)
      delim = d
    }
    print
  }
')

# 区切り（`;` / `&&` / `||` / `|` / `&` / 括弧 / 改行）で断片に分け、各断片の
# **コマンドの位置**（先頭の `VAR=値` と nohup / env / setsid / exec / timeout を
# 飛ばした最初の語）を見る。
# ⚠ `APPIMAGELAUNCHER_DISABLE=1` は、同じ断片の前置きでも、それより前の断片の
#   `export` / 単独の代入でもよい（どちらでも起動するプロセスに効く）。
hit=$(printf '%s\n' "$scrubbed" | awk '
  function unquote(w) { gsub(/[\047"]/, "", w); return w }
  BEGIN { disabled = 0; hit = 0 }
  {
    n = split($0, seg, /(&&|\|\||[;&|()])/)
    for (i = 1; i <= n; i++) {
      s = seg[i]
      sub(/^[ \t]+/, "", s)
      if (s == "") continue
      m = split(s, w, /[ \t]+/)
      local_disabled = 0
      j = 1
      if (w[1] == "export") j = 2
      # 前置きの代入と、起動を包むだけのコマンドを飛ばす。
      while (j <= m) {
        t = unquote(w[j])
        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
          name = t; sub(/=.*/, "", name)
          val = t; sub(/^[^=]*=/, "", val)
          if (name == "APPIMAGELAUNCHER_DISABLE" && val != "" && val != "0") local_disabled = 1
          if (val ~ /\.AppImage$/) appvar[name] = 1
          j++
          continue
        }
        if (t == "nohup" || t == "env" || t == "setsid" || t == "exec" || t == "stdbuf") { j++; continue }
        if (t ~ /^-/ && j > 1) { j++; continue }
        if (t == "timeout") { j++; if (j <= m && unquote(w[j]) ~ /^[0-9.]+[smhd]?$/) j++; continue }
        break
      }
      # コマンドの無い断片（代入だけ・export だけ）は、以降の断片に効く。
      if (j > m) { if (local_disabled) disabled = 1; continue }
      c = unquote(w[j])
      is_app = (c ~ /\.AppImage$/)
      if (c ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/) {
        v = c; gsub(/[${}]/, "", v)
        if (v in appvar) is_app = 1
      }
      if (!is_app) continue
      # ランタイムの引数（--appimage-extract 等）はアプリを起動しない。
      runtime_only = 0
      for (k = j + 1; k <= m; k++) if (unquote(w[k]) ~ /^--appimage-/) runtime_only = 1
      if (runtime_only) continue
      if (!disabled && !local_disabled) hit = 1
    }
  }
  END { print hit }
')

if [ "$hit" = "1" ]; then
  deny 'AppImage を APPIMAGELAUNCHER_DISABLE=1 なしで起動する形は拒否した。inori の AppImageLauncher は、~/Applications に無い AppImage を初めて起動するたびに確認のダイアログを出して起動を止める（押すまで進まず、RustDesk 越しでは誰も気付けない・2026-11-18 に踏んだ）。`APPIMAGELAUNCHER_DISABLE=1 <AppImage>` の形で起動し直すこと（nohup で背後に回すなら `APPIMAGELAUNCHER_DISABLE=1 nohup <AppImage> > log 2>&1 &`）。⚠ `timeout <AppImage>` は binfmt の都合で「No such file」で落ちるので使わない。⚠ この話を*文章として*書いていて落ちた場合は、本文を heredoc か `--body-file` / `-F` へ移すこと（本文は検査していない）。'
fi

exit 0
