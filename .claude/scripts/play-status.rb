#!/usr/bin/env ruby
# frozen_string_literal: true

# Google Play のトラックの状態を読む（読み取り専用）。
#
# ⚠ **`fastlane release` が意図したビルドを昇格したかを、実測で確かめる**
# （versionCode の衝突で別のビルドが製品版に出た事故がある・
# skills/store-release/submit-promote.md）。
#
#   .claude/scripts/play-status.rb                    # production / alpha / internal
#   .claude/scripts/play-status.rb production         # トラックを指定
#
# ⚠⚠ **インラインの `ruby -e` から起こした。**手順書（skills/store-release/
# github-release.md §4.4）はワンライナーで書かれていたが、
# `deny-interpreter-inline` のフックが拒否するので実行できない形だった
# （2026-10-08 の v2.0.1 のリリースで踏んだ）。
#
# 認証は fastlane と同じサービスアカウント
# （`~/.config/capsicum/google-play-service-account.json`）。
# ⚠ **鍵は読むだけで、中身は表示しない。**
# ⚠ edits を開くだけで commit しないので、Play 側に副作用は無い。
# ⚠ darwin では rbenv shims を PATH の先頭に置いてから呼ぶ（`jwt` gem が要る）。

require 'json'
require 'jwt'
require 'net/http'
require 'openssl'
require 'uri'

PACKAGE = 'net.shrieker.capsicum'
sa = JSON.parse(File.read(File.expand_path('~/.config/capsicum/google-play-service-account.json')))
key = OpenSSL::PKey::RSA.new(sa['private_key'])
now = Time.now.to_i
jwt = JWT.encode(
  {
    iss: sa['client_email'],
    scope: 'https://www.googleapis.com/auth/androidpublisher',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  },
  key,
  'RS256',
)
res = Net::HTTP.post_form(
  URI('https://oauth2.googleapis.com/token'),
  { 'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'assertion' => jwt },
)
token = JSON.parse(res.body)['access_token']
abort '⚠ トークンを取得できなかった' unless token

call = lambda do |klass, path|
  uri = URI("https://androidpublisher.googleapis.com/androidpublisher/v3/applications/#{PACKAGE}/#{path}")
  req = klass.new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Content-Length'] = '0' if klass == Net::HTTP::Post
  JSON.parse(Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }.body)
end

edit_id = call.call(Net::HTTP::Post, 'edits')['id']
abort '⚠ edit を開けなかった' unless edit_id

# テスターの配り先（Google グループ）とリリースの生の設定を出す。
# ⚠ **メールアドレスのリストは API に出ない**（Play Console の画面でしか見られない）。
if ARGV.first == 'testers'
  %w[alpha internal].each do |track|
    testers = call.call(Net::HTTP::Get, "edits/#{edit_id}/testers/#{track}")
    puts "#{track}: googleGroups=#{testers['googleGroups'].inspect} #{testers['error']&.dig('message')}"
    body = call.call(Net::HTTP::Get, "edits/#{edit_id}/tracks/#{track}")
    (body['releases'] || []).each do |r|
      puts "#{track}: #{r.reject { |k, _| k == 'releaseNotes' }.to_json}"
    end
  end
  exit
end

(ARGV.empty? ? %w[production alpha internal] : ARGV).each do |track|
  body = call.call(Net::HTTP::Get, "edits/#{edit_id}/tracks/#{track}")
  (body['releases'] || []).each do |r|
    puts "#{track}: versionCodes=#{r['versionCodes']} status=#{r['status']} name=#{r['name']}"
  end
  puts "#{track}: (リリースなし) #{body['error']&.dig('message')}" if (body['releases'] || []).empty?
end
