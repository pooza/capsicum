#!/usr/bin/env ruby
# frozen_string_literal: true

# Registers the `CapsicumNotificationService` Notification Service Extension
# (NSE) target in `Runner.xcodeproj`. Mirrors how `ShareExtension` is wired up
# so that iOS Automatic code signing can provision it alongside Runner.
#
# Idempotent: if the target already exists, the script exits without changes.
# Re-running is safe if `pod install` or Xcode has regenerated the project
# file and you need to re-apply the NSE wiring.
#
# Usage (from `packages/capsicum/ios`):
#   ruby scripts/add_notification_service_target.rb

require 'xcodeproj'
require 'pathname'

PROJECT_PATH = File.expand_path('../Runner.xcodeproj', __dir__)
NSE_NAME = 'CapsicumNotificationService'
NSE_DIR = NSE_NAME
NSE_XCCONFIG = 'Flutter/NotificationService.xcconfig'
BUNDLE_ID_RELEASE = 'jp.co.b-shock.capsicum.NotificationService'
BUNDLE_ID_DEBUG = 'jp.co.b-shock.capsicum.debug.NotificationService'
TEAM_ID = 'Y27AK8VF85'
DEPLOYMENT_TARGET = '14.0'
SWIFT_VERSION = '5.0'

SOURCE_FILES = %w[
  NotificationService.swift
  WebPushDecryptor.swift
  PushKeyReader.swift
  NotificationTypeLabel.swift
].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)

if project.targets.any? { |t| t.name == NSE_NAME }
  puts "Target #{NSE_NAME} already exists. Nothing to do."
  exit 0
end

runner_target = project.targets.find { |t| t.name == 'Runner' }
raise 'Runner target not found' unless runner_target

# 1. Create the extension target.
nse_target = project.new_target(
  :app_extension,
  NSE_NAME,
  :ios,
  DEPLOYMENT_TARGET
)

# 2. Wire build settings to mirror ShareExtension conventions so that
#    Automatic signing keeps working across Debug/Release/Profile.
xcconfig_ref = project.main_group.find_file_by_path(NSE_XCCONFIG) ||
               project.main_group['Flutter'].new_file(NSE_XCCONFIG)

nse_target.build_configurations.each do |config|
  config.base_configuration_reference = xcconfig_ref
  settings = config.build_settings
  settings['CLANG_ENABLE_OBJC_WEAK'] = 'NO'
  settings['CODE_SIGN_ENTITLEMENTS'] = "#{NSE_DIR}/#{NSE_NAME}.entitlements"
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
  settings['DEVELOPMENT_TEAM'] = TEAM_ID
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = "#{NSE_DIR}/Info.plist"
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  settings['MARKETING_VERSION'] = '$(FLUTTER_BUILD_NAME)'
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['SDKROOT'] = 'iphoneos'
  settings['SKIP_INSTALL'] = 'YES'
  settings['SWIFT_VERSION'] = SWIFT_VERSION
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'

  settings['PRODUCT_BUNDLE_IDENTIFIER'] =
    config.name == 'Debug' ? BUNDLE_ID_DEBUG : BUNDLE_ID_RELEASE
  settings['VALIDATE_PRODUCT'] = 'YES' if config.name == 'Release'
end

# 3. Add source files + plist + entitlements to the project tree under
#    a new group mirroring the directory layout.
nse_group = project.main_group.find_subpath(NSE_DIR, true)
nse_group.set_source_tree('<group>')
nse_group.set_path(NSE_DIR)

SOURCE_FILES.each do |filename|
  file_ref = nse_group.find_file_by_path(filename) || nse_group.new_reference(filename)
  nse_target.add_file_references([file_ref])
end

nse_group.find_file_by_path('Info.plist') || nse_group.new_reference('Info.plist')
nse_group.find_file_by_path("#{NSE_NAME}.entitlements") ||
  nse_group.new_reference("#{NSE_NAME}.entitlements")

# 4. Make Runner embed the .appex so the extension is packaged with the app.
embed_phase = runner_target.copy_files_build_phases.find do |phase|
  phase.name == 'Embed App Extensions' ||
    phase.symbol_dst_subfolder_spec == :plug_ins
end

if embed_phase.nil?
  embed_phase = runner_target.new_copy_files_build_phase('Embed App Extensions')
  embed_phase.symbol_dst_subfolder_spec = :plug_ins
  embed_phase.run_only_for_deployment_postprocessing = '0'
end

product_ref = nse_target.product_reference
unless embed_phase.files_references.include?(product_ref)
  build_file = embed_phase.add_file_reference(product_ref)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

# 5. Add the NSE as a target dependency of Runner.
unless runner_target.dependencies.any? { |d| d.target == nse_target }
  runner_target.add_dependency(nse_target)
end

project.save

puts "Added #{NSE_NAME} target and wired it into Runner."
