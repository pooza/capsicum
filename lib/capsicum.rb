require 'active_support'
require 'active_support/core_ext'
require 'active_support/dependencies/autoload'
require 'ginseng'

module Capsicum
  extend ActiveSupport::Autoload

  autoload :Config
  autoload :Crawler
  autoload :Environment
  autoload :Logger
  autoload :Package
  autoload :Slack
end
