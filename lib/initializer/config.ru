dir = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(File.join(dir, 'lib'))
ENV['BUNDLE_GEMFILE'] ||= File.join(dir, 'Gemfile')
ENV['SSL_CERT_FILE'] ||= File.join(dir, 'cert/cacert.pem')

require 'bundler/setup'
require 'sidekiq/web'
require 'sidekiq-scheduler/web'
require 'capsicum'

config = Capsicum::Config.instance
if config['/sidekiq/auth/user'].present? && config['/sidekiq/auth/password'].present?
  Sidekiq::Web.use Rack::Auth::Basic do |username, password|
    Capsicum::Environment.auth(username, password)
  end
end

run Rack::URLMap.new({
  '/' => Capsicum::Server,
  '/capsicum/sidekiq' => Sidekiq::Web,
})
