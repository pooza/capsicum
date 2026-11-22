# リリースの道具の Ruby の gem (#1376)。
#
# iOS / macOS / Android の fastlane と、iOS / macOS の CocoaPods、リリースの確認の
# スクリプト（.claude/scripts/asc-status.rb / play-status.rb）が使う。版は
# Gemfile.lock で固定し、Ruby を上げたら `bundle install` を 1 回流せば戻る。
#
# - fastlane は `bundle exec fastlane ...` で呼ぶ（fastlane の推奨）
# - CocoaPods は flutter が `pod` をそのまま呼ぶので、`bundle install` で
#   .ruby-version の Ruby に入っていればよい
# - Ruby の版は .ruby-version（rbenv は `4.0` のような粗い指定を受けないので、
#   パッチまで書く。上げ方は docs/dev-environment.md の「Ruby の版」）
source 'https://rubygems.org'

# ⚠ 版は #1376 の移行の時点で使っていたものに合わせた（置き場を変えただけで、
# 道具は上げていない）。CocoaPods を上げると Podfile.lock の `COCOAPODS:` が
# 書き換わるので、上げるときは `bundle update cocoapods` で意図して上げる。
gem 'cocoapods', '~> 1.16.2'
gem 'fastlane', '~> 2.241.2'
gem 'jwt', '~> 3.2'
