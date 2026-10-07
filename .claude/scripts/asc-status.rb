#!/usr/bin/env ruby
# frozen_string_literal: true

# App Store Connect の状態を読む（読み取り専用）。
#
# ⚠⚠ **インラインの `ruby -e` から起こした。**手順書（skills/store-release/
# github-release.md §4.4）はワンライナーで書かれていたが、
# `deny-interpreter-inline` のフックが拒否するようになったため**実行できない
# 形**になっていた（docs/dev-environment.md「コマンドの書き方」）。
#
# ⚠ **課金商品の状態はどこにも手順が無かった** —— #1124 の残りが「商品が
# 販売中になるのを待つ」なので、同期のたびに引く先が要る（2026-10-05）。
#
#   .claude/scripts/asc-status.rb versions   # iOS / macOS の審査状態
#   .claude/scripts/asc-status.rb products   # サブスク・消耗型の状態と価格
#   .claude/scripts/asc-status.rb builds     # TestFlight のビルドと審査の状態
#   .claude/scripts/asc-status.rb parts      # サブスクを審査へ出すのに要る部品
#   .claude/scripts/asc-status.rb            # versions と products
#
# 認証は fastlane と同じ ASC API Key（`~/.config/capsicum/AuthKey_<KEY_ID>.p8`）。
# ⚠ **秘密鍵は読むだけで、中身は表示しない。**

require 'json'
require 'jwt'
require 'net/http'
require 'openssl'
require 'time'
require 'uri'

BUNDLE_ID = 'jp.co.b-shock.capsicum'
CONFIG_DIR = File.expand_path('~/.config/capsicum')

# ⚠ **識別子をこのファイルに書かない。**環境変数が無ければ、鍵のファイル名
# （key_id）と fastlane の Fastfile（issuer_id）という**既にある 1 か所**から
# 取る。⚠ 複写すると、片方だけ差し替えられたときに気付けない。
def key_id
  return ENV['ASC_KEY_ID'] if ENV['ASC_KEY_ID']

  keys = Dir.glob(File.join(CONFIG_DIR, 'AuthKey_*.p8'))
  abort "⚠ 鍵が見つからない: #{CONFIG_DIR}/AuthKey_*.p8" if keys.empty?
  abort "⚠ 鍵が複数ある。ASC_KEY_ID で選ぶこと: #{keys.join(', ')}" if keys.size > 1

  return File.basename(keys.first, '.p8').delete_prefix('AuthKey_')
end

def issuer_id
  return ENV['ASC_ISSUER_ID'] if ENV['ASC_ISSUER_ID']

  fastfile = File.expand_path(
    '../../packages/capsicum/ios/fastlane/Fastfile', __dir__
  )
  found = File.read(fastfile)[/issuer_id:\s*'([^']+)'/, 1] if File.exist?(fastfile)
  abort '⚠ issuer_id が取れない。ASC_ISSUER_ID を設定すること' unless found

  return found
end

def token
  @token ||= begin
    kid = key_id
    key = OpenSSL::PKey::EC.new(File.read(File.join(CONFIG_DIR, "AuthKey_#{kid}.p8")))
    now = Time.now.to_i
    JWT.encode(
      {iss: issuer_id, iat: now, exp: now + 600, aud: 'appstoreconnect-v1'},
      key, 'ES256', {kid: kid, typ: 'JWT'}
    )
  end
end

def get(path)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{token}"
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) {|h| h.request(req)}
  abort "⚠ HTTP #{res.code} #{path}\n#{res.body[0, 500]}" unless res.code == '200'

  return JSON.parse(res.body)
end

def app_id
  @app_id ||= get("/v1/apps?filter[bundleId]=#{BUNDLE_ID}")['data'].first['id']
end

# iOS / macOS の審査状態。⚠ lookup API では Universal Purchase の同一レコードを
# 拾うので、プラットフォーム別はここでしか分からない。
def print_versions
  puts '== アプリの版 =='
  ['IOS', 'MAC_OS'].each do |platform|
    versions = get(
      "/v1/apps/#{app_id}/appStoreVersions?filter[platform]=#{platform}&limit=3",
    )
    puts "  #{platform}:"
    versions['data'].each do |version|
      attrs = version['attributes']
      puts "    #{attrs['versionString']}  #{attrs['appStoreState']}"
    end
  end
end

# サブスクと消耗型の状態。⚠ `state` が `READY_FOR_SALE`（サブスクは
# `APPROVED` + 価格の開始日）になるまで**買えない**。
def print_products
  puts '== 課金商品 =='
  get("/v1/apps/#{app_id}/subscriptionGroups")['data'].each do |group|
    puts "  group: #{group['attributes']['referenceName']}"
    subs = get("/v1/subscriptionGroups/#{group['id']}/subscriptions")
    subs['data'].each {|sub| print_subscription(sub)}
  end
  puts '  消耗型・非購読:'
  (get("/v1/apps/#{app_id}/inAppPurchasesV2?limit=50")['data'] || []).each do |iap|
    attrs = iap['attributes']
    puts "    #{attrs['productId']}  #{attrs['state']}  (#{attrs['inAppPurchaseType']})"
  end
end

def print_subscription(sub)
  attrs = sub['attributes']
  puts "    #{attrs['productId']}  #{attrs['state']}  " \
    "(#{attrs['subscriptionPeriod']})  #{attrs['name']}"
  prices = get(
    "/v1/subscriptions/#{sub['id']}/prices?include=subscriptionPricePoint,territory&limit=200",
  )
  points = {}
  (prices['included'] || []).each do |inc|
    points[inc['id']] = inc if inc['type'] == 'subscriptionPricePoints'
  end
  jp = (prices['data'] || []).find do |price|
    price['relationships']&.dig('territory', 'data', 'id') == 'JPN'
  end
  # ⚠ `puts ... and return` と書くと、`puts` が nil を返すので **return が
  # 実行されない**（次の行で nil を引いて落ちる）。素直に分岐する。
  unless jp
    puts '      価格（日本）: 設定なし'
    return
  end

  point = points[jp['relationships']&.dig('subscriptionPricePoint', 'data', 'id')]
  puts "      価格（日本）: #{point&.dig('attributes', 'customerPrice')} " \
    "（手取り #{point&.dig('attributes', 'proceeds')}）  " \
    "全 #{(prices['data'] || []).size} 地域"
end

# サブスクを審査へ出すのに要る部品の状態。⚠ **商品が `READY_TO_SUBMIT` でも、
# バージョンのページに「App 内課金とサブスクリプション」の欄が出ないことがある**
# （2026-10-08）。どの部品が欠けているかを、画面を開かずに見るための口。
def print_subscription_parts
  puts '== サブスクの部品 =='
  get("/v1/apps/#{app_id}/subscriptionGroups")['data'].each do |group|
    puts "  group: #{group['attributes']['referenceName']}"
    locs = get("/v1/subscriptionGroups/#{group['id']}/subscriptionGroupLocalizations")
    locs['data'].each do |loc|
      attrs = loc['attributes']
      puts "    グループの表示名 #{attrs['locale']}: #{attrs['state']}  #{attrs['name']}"
    end
    puts '    グループの表示名: なし' if locs['data'].empty?
    get("/v1/subscriptionGroups/#{group['id']}/subscriptions")['data'].each do |sub|
      print_subscription_part(sub)
    end
  end
end

def print_subscription_part(sub)
  attrs = sub['attributes']
  puts "    #{attrs['productId']}  #{attrs['state']}  " \
    "familySharable=#{attrs['familySharable']}  groupLevel=#{attrs['groupLevel']}"
  locs = get("/v1/subscriptions/#{sub['id']}/subscriptionLocalizations")
  locs['data'].each do |loc|
    la = loc['attributes']
    puts "      表示名 #{la['locale']}: #{la['state']}  #{la['name']}"
  end
  puts '      表示名: なし' if locs['data'].empty?
  shot = get("/v1/subscriptions/#{sub['id']}/appStoreReviewScreenshot")['data']
  puts "      審査用の画像: #{shot ? shot.dig('attributes', 'assetDeliveryState', 'state') : 'なし'}"
  puts "      審査メモ: #{attrs['reviewNote'].to_s.empty? ? 'なし' : "#{attrs['reviewNote'].length} 文字"}"
end

# TestFlight のビルドごとの状態。⚠ 外部テスター向けは「ベータ版 App Review」が
# 入るので、アップロードの処理が終わっても配られない。内部と外部は別に出る。
def print_builds
  puts '== TestFlight のビルド（新しい順） =='
  builds = get(
    "/v1/builds?filter[app]=#{app_id}&sort=-uploadedDate&limit=5" \
    '&include=buildBetaDetail,betaAppReviewSubmission,preReleaseVersion',
  )
  included = {}
  (builds['included'] || []).each {|inc| included[[inc['type'], inc['id']]] = inc}
  builds['data'].each do |build|
    rel = build['relationships'] || {}
    lookup = lambda do |name|
      ref = rel.dig(name, 'data')
      ref && included[[ref['type'], ref['id']]]&.dig('attributes')
    end
    detail = lookup.call('buildBetaDetail') || {}
    review = lookup.call('betaAppReviewSubmission') || {}
    version = lookup.call('preReleaseVersion') || {}
    attrs = build['attributes']
    uploaded = Time.parse(attrs['uploadedDate']).getlocal.strftime('%m-%d %H:%M')
    puts "  #{version['version']} (#{attrs['version']})  #{version['platform']}  上=#{uploaded}  " \
      "処理=#{attrs['processingState']}  内部=#{detail['internalBuildState']}  " \
      "外部=#{detail['externalBuildState']}  審査=#{review['betaReviewState'] || '未提出'}"
    # ⚠ **審査待ちは「いつから待っているか」を出す。**状態だけだと、数時間なのか
    # 数日なのかが分からず、待つべきか問い合わせるべきかを決められない。
    submitted = review['submittedDate']
    next unless submitted && review['betaReviewState'] == 'WAITING_FOR_REVIEW'

    hours = ((Time.now - Time.parse(submitted)) / 3600).round(1)
    puts "      提出=#{Time.parse(submitted).getlocal.strftime('%m-%d %H:%M')}  " \
      "待ち=#{hours} 時間"
  end
end

case ARGV[0]
when 'versions' then print_versions
when 'products' then print_products
when 'builds' then print_builds
when 'parts' then print_subscription_parts
when nil then (print_versions; print_products)
else abort "使い方: #{File.basename($PROGRAM_NAME)} [versions|products|builds|parts]"
end
