require 'active_support'
require 'active_support/core_ext'
require 'active_support/dependencies/autoload'
require 'ginseng'
require 'ginseng/postgres'
require 'sidekiq'
require 'sidekiq-scheduler'

module Capsicum
  extend ActiveSupport::Autoload

  autoload :Config
  autoload :Dictionary
  autoload :Environment
  autoload :Logger
  autoload :Package
  autoload :Postgres
  autoload :Server
  autoload :Slack

  autoload_under 'daemon' do
    autoload :SidekiqDaemon
    autoload :ThinDaemon
  end

  autoload_under 'dictionary' do
    autoload :MediawikiDictionary
    autoload :ScrapingDictionary
  end
end

Sidekiq.configure_client do |config|
  config.redis = {url: Capsicum::Config.instance['/sidekiq/redis/dsn']}
end
Sidekiq.configure_server do |config|
  config.redis = {url: Capsicum::Config.instance['/sidekiq/redis/dsn']}
end
