#!/bin/bash
# 撮影用の @test アカウントを API で操作する（docs/screenshot-procedure.md）。
#
# ⚠⚠ 本番の Mastodon / Misskey への書き込み。token / show 以外は、着手前に
#     pooza の承認を取る（メモリ feedback_production_fedi_needs_confirmation）。
#
#   fedi.sh token   <KEY>                   トークンを取って $SHOT_DIR/tokens/<KEY> に置く
#   fedi.sh show    <KEY>                   表示名・bot・フォロー先を見る
#   fedi.sh profile <KEY> <true|false>      表示名「capsicum」・アイコン・bot の印
#   fedi.sh bot     <KEY> <true|false>      bot の印だけ
#   fedi.sh follow  <KEY> <acct>            例: test@mstdn.delmulin.com
#   fedi.sh unfollow <KEY> <acct>
#   fedi.sh post    <KEY> <public|direct> <本文ファイル>   → posted.log に記録
#   fedi.sh react   <KEY> <fav|boost> <投稿 URL>          → reacted.log に記録
#   fedi.sh cleanup                         posted.log / reacted.log を全部取り消す
#
# KEY は BSHOCKDON / DELMULINDON / CURESTA / DAISSKEY。
set -u
source "$(dirname "$0")/lib.sh"
CMD="${1:-}"
[ -n "$CMD" ] || { sed -n '2,20p' "$0"; exit 2; }

# ---- 低レベル ----
mk() { # Misskey: mk <HOST> <TOKEN> <endpoint> <json>
  curl -s -X POST "https://$1/api/$3" -H 'Content-Type: application/json' \
    -d "$(echo "$4" | jq --arg i "$2" '. + {i: $i}')"
}
md() { # Mastodon: md <HOST> <TOKEN> <method> <path> [curl args...]
  local h="$1" t="$2" m="$3" p="$4"; shift 4
  curl -s -X "$m" "https://$h$p" -H "Authorization: Bearer $t" "$@"
}

# ---- token ----
cmd_token() {
  local key="$1" host email pass
  host="$(shot_host "$key")" || exit 2
  if shot_is_misskey "$key"; then
    # ⚠ ダイスキーはサインインに Turnstile が掛かっていて、API からは通らない。
    #   トークンは DB から読み取りで引く（接続先と手順は chubo2 の docs・private）。
    echo "$host: Turnstile のため API では取れない。トークンを $SHOT_DIR/tokens/$key に置く（docs/screenshot-procedure.md）" >&2
    exit 1
  fi
  source ~/.config/capsicum/secrets.env
  local ev="TEST_${key}_EMAIL" pv="TEST_${key}_PASSWORD"
  email="${!ev}"; pass="${!pv}"
  # ⚠ password grant は無効（unsupported_grant_type）。Web のログイン → 認可コードを辿る。
  local app cid csec jar at code loc res token
  app=$(curl -s -X POST "https://$host/api/v1/apps" -F client_name=capsicum-screenshot \
    -F redirect_uris=urn:ietf:wg:oauth:2.0:oob -F 'scopes=read write follow')
  cid=$(echo "$app" | jq -r '.client_id // empty'); csec=$(echo "$app" | jq -r '.client_secret // empty')
  [ -n "$cid" ] || { echo "$host: app 登録に失敗"; exit 1; }
  jar="$SHOT_DIR/tokens/$key.cookies"; rm -f "$jar"
  csrf() { grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"$//'; }
  at=$(curl -s -c "$jar" -b "$jar" "https://$host/auth/sign_in" | csrf)
  curl -s -o /dev/null -c "$jar" -b "$jar" -X POST "https://$host/auth/sign_in" \
    --data-urlencode "authenticity_token=$at" --data-urlencode "user[email]=$email" \
    --data-urlencode "user[password]=$pass"
  at=$(curl -s -c "$jar" -b "$jar" \
    "https://$host/oauth/authorize?client_id=$cid&response_type=code&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=read+write+follow" | csrf)
  loc=$(curl -s -o /dev/null -w '%{redirect_url}' -c "$jar" -b "$jar" -X POST "https://$host/oauth/authorize" \
    --data-urlencode "authenticity_token=$at" --data-urlencode "client_id=$cid" \
    --data-urlencode "redirect_uri=urn:ietf:wg:oauth:2.0:oob" --data-urlencode "state=" \
    --data-urlencode "response_type=code" --data-urlencode "scope=read write follow")
  rm -f "$jar"
  code=$(echo "$loc" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
  [ -n "$code" ] || { echo "$host: 認可に失敗"; exit 1; }
  res=$(curl -s -X POST "https://$host/oauth/token" -F grant_type=authorization_code \
    -F "client_id=$cid" -F "client_secret=$csec" -F "code=$code" \
    -F redirect_uri=urn:ietf:wg:oauth:2.0:oob -F 'scope=read write follow')
  token=$(echo "$res" | jq -r '.access_token // empty')
  [ -n "$token" ] || { echo "$host: token の取得に失敗"; exit 1; }
  (umask 077; printf '%s' "$token" > "$SHOT_DIR/tokens/$key")
  echo "$host: token saved"
}

# ---- 読み書き ----
resolve_mastodon_status() { # host token url → id
  md "$1" "$2" GET "/api/v2/search?q=$(jq -rn --arg u "$3" '$u|@uri')&resolve=true&type=statuses&limit=1" \
    | jq -r '.statuses[0].id // empty'
}

case "$CMD" in
  token) cmd_token "$2" ;;
  show|profile|bot|follow|unfollow|post|react)
    KEY="$2"; HOST="$(shot_host "$KEY")" || exit 2; TOKEN="$(shot_token "$KEY")" || exit 1
    if shot_is_misskey "$KEY"; then
      case "$CMD" in
        show)
          mk "$HOST" "$TOKEN" i '{}' | jq -c '{username, name, isBot, followingCount}'
          ID=$(mk "$HOST" "$TOKEN" i '{}' | jq -r .id)
          mk "$HOST" "$TOKEN" users/following "{\"userId\":\"$ID\",\"limit\":30}" \
            | jq -r '.[] | "  follows: @\(.followee.username)@\(.followee.host // "local")"' ;;
        profile)
          FILE=$(curl -s -X POST "https://$HOST/api/drive/files/create" -F "i=$TOKEN" \
            -F "file=@$SHOT_DIR/avatar.png" -F name=capsicum-avatar.png | jq -r '.id // empty')
          mk "$HOST" "$TOKEN" i/update "{\"name\":\"capsicum\",\"avatarId\":\"$FILE\",\"isBot\":$3}" | jq -c '{name, isBot}' ;;
        bot) mk "$HOST" "$TOKEN" i/update "{\"isBot\":$3}" | jq -c '{name, isBot}' ;;
        follow|unfollow)
          U="${3%%@*}"; H="${3#*@}"; [ "$H" = "$3" ] && HJ=null || HJ="\"$H\""
          UID_=$(mk "$HOST" "$TOKEN" users/show "{\"username\":\"$U\",\"host\":$HJ}" | jq -r '.id // empty')
          [ -n "$UID_" ] || UID_=$(mk "$HOST" "$TOKEN" ap/show "{\"uri\":\"https://$H/@$U\"}" | jq -r '.object.id // empty')
          [ "$CMD" = follow ] && EP=following/create || EP=following/delete
          mk "$HOST" "$TOKEN" "$EP" "{\"userId\":\"$UID_\"}" | jq -c '{username, host, error: .error.code}' ;;
        post)
          [ "$3" = direct ] && V=specified || V=public
          RES=$(mk "$HOST" "$TOKEN" notes/create "$(jq -n --rawfile t "$4" --arg v "$V" '{text: $t, visibility: $v}')")
          ID=$(echo "$RES" | jq -r '.createdNote.id // empty')
          echo "$RES" | jq -c '{id: .createdNote.id, tags: .createdNote.tags, error: .error.message}'
          [ -n "$ID" ] && echo "$KEY note $ID" >> "$SHOT_DIR/posted.log" ;;
        react)
          NID=$(mk "$HOST" "$TOKEN" ap/show "$(jq -n --arg u "$4" '{uri: $u}')" | jq -r '.object.id // empty')
          if [ "$3" = fav ]; then
            mk "$HOST" "$TOKEN" notes/reactions/create "{\"noteId\":\"$NID\",\"reaction\":\"❤️\"}" >/dev/null
            # ⚠ モロヘイヤが「リアクション ❤️ を送りました」の返信ノートを @test の名前で
            #   自動投稿する。撮影に写るので消す（cleanup でも拾う）。
            echo "  ⚠ 自動の返信ノートが出る。fedi.sh cleanup か手で消す"
          else
            RID=$(mk "$HOST" "$TOKEN" notes/create "{\"renoteId\":\"$NID\"}" | jq -r '.createdNote.id // empty')
            [ -n "$RID" ] && echo "$KEY note $RID" >> "$SHOT_DIR/posted.log"
          fi
          echo "$KEY $3 $4" >> "$SHOT_DIR/reacted.log" ;;
      esac
    else
      case "$CMD" in
        show)
          ME=$(md "$HOST" "$TOKEN" GET /api/v1/accounts/verify_credentials)
          echo "$ME" | jq -c '{acct, display_name, bot, following_count}'
          md "$HOST" "$TOKEN" GET "/api/v1/accounts/$(echo "$ME" | jq -r .id)/following?limit=40" | jq -r '.[] | "  follows: @\(.acct)"' ;;
        profile)
          md "$HOST" "$TOKEN" PATCH /api/v1/accounts/update_credentials -F display_name=capsicum \
            -F "bot=$3" -F "avatar=@$SHOT_DIR/avatar.png" | jq -c '{display_name, bot, error}' ;;
        bot) md "$HOST" "$TOKEN" PATCH /api/v1/accounts/update_credentials -F "bot=$3" | jq -c '{display_name, bot, error}' ;;
        follow)
          AID=$(md "$HOST" "$TOKEN" GET "/api/v2/search?q=@$3&resolve=true&type=accounts&limit=1" | jq -r '.accounts[0].id // empty')
          md "$HOST" "$TOKEN" POST "/api/v1/accounts/$AID/follow" | jq -c '{following, requested, error}' ;;
        unfollow)
          AID=$(md "$HOST" "$TOKEN" GET "/api/v1/accounts/lookup?acct=$3" | jq -r '.id // empty')
          md "$HOST" "$TOKEN" POST "/api/v1/accounts/$AID/unfollow" | jq -c '{following, error}' ;;
        post)
          RES=$(md "$HOST" "$TOKEN" POST /api/v1/statuses --data-urlencode "status@$4" --data-urlencode "visibility=$3")
          ID=$(echo "$RES" | jq -r '.id // empty')
          echo "$RES" | jq -c '{id, visibility, tags: [.tags[]?.name], error}'
          [ -n "$ID" ] && echo "$KEY status $ID" >> "$SHOT_DIR/posted.log" ;;
        react)
          SID=$(resolve_mastodon_status "$HOST" "$TOKEN" "$4")
          [ "$3" = fav ] && EP=favourite || EP=reblog
          md "$HOST" "$TOKEN" POST "/api/v1/statuses/$SID/$EP" | jq -c '{favourited, reblogged, error}'
          echo "$KEY $3 $4" >> "$SHOT_DIR/reacted.log" ;;
      esac
    fi ;;
  cleanup)
    # 付けたリアクションを外し、投稿を消す。済んだ行はログから外す。
    # ⚠ 失敗した行（トークンが無い・対象を引けない・削除が通らない）はログに残す。
    #    丸ごと空にすると、消し損ねた投稿やリアクションが本番に残ったまま
    #    記録から消える（PR #1325 の Codex P2・#1332）。
    if [ -s "$SHOT_DIR/reacted.log" ]; then
      : > "$SHOT_DIR/reacted.log.keep"
      while read -r KEY ACT URL; do
        HOST="$(shot_host "$KEY")"
        if ! TOKEN="$(shot_token "$KEY")"; then
          echo "$KEY $ACT $URL" >> "$SHOT_DIR/reacted.log.keep"; continue
        fi
        if shot_is_misskey "$KEY"; then
          NID=$(mk "$HOST" "$TOKEN" ap/show "$(jq -n --arg u "$URL" '{uri: $u}')" | jq -r '.object.id // empty')
          if [ -z "$NID" ]; then
            echo "failed(no note): $KEY $ACT $URL"; echo "$KEY $ACT $URL" >> "$SHOT_DIR/reacted.log.keep"; continue
          fi
          [ "$ACT" = fav ] && mk "$HOST" "$TOKEN" notes/reactions/delete "{\"noteId\":\"$NID\"}" >/dev/null
        else
          SID=$(resolve_mastodon_status "$HOST" "$TOKEN" "$URL")
          if [ -z "$SID" ]; then
            echo "failed(no status): $KEY $ACT $URL"; echo "$KEY $ACT $URL" >> "$SHOT_DIR/reacted.log.keep"; continue
          fi
          [ "$ACT" = fav ] && EP=unfavourite || EP=unreblog
          md "$HOST" "$TOKEN" POST "/api/v1/statuses/$SID/$EP" >/dev/null
        fi
        echo "undone: $KEY $ACT $URL"
      done < "$SHOT_DIR/reacted.log"
      mv "$SHOT_DIR/reacted.log.keep" "$SHOT_DIR/reacted.log"
    fi
    if [ -s "$SHOT_DIR/posted.log" ]; then
      : > "$SHOT_DIR/posted.log.keep"
      while read -r KEY KIND ID _; do
        HOST="$(shot_host "$KEY")"
        if ! TOKEN="$(shot_token "$KEY")"; then
          echo "$KEY $KIND $ID" >> "$SHOT_DIR/posted.log.keep"; continue
        fi
        if [ "$KIND" = note ]; then
          CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://$HOST/api/notes/delete" \
            -H 'Content-Type: application/json' -d "{\"i\":\"$TOKEN\",\"noteId\":\"$ID\"}")
        else
          CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "https://$HOST/api/v1/statuses/$ID" \
            -H "Authorization: Bearer $TOKEN")
        fi
        echo "deleted($CODE): $KEY $KIND $ID"
        # 2xx は消せた・404 はもう無い。それ以外（接続の失敗は 000）は残す。
        case "$CODE" in
          2??|404) ;;
          *) echo "$KEY $KIND $ID" >> "$SHOT_DIR/posted.log.keep" ;;
        esac
      done < "$SHOT_DIR/posted.log"
      mv "$SHOT_DIR/posted.log.keep" "$SHOT_DIR/posted.log"
    fi ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
