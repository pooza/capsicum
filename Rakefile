dir = File.expand_path(__dir__)
$LOAD_PATH.unshift(File.join(dir, 'lib'))
ENV['BUNDLE_GEMFILE'] ||= File.join(dir, 'Gemfile')
ENV['SSL_CERT_FILE'] ||= File.join(dir, 'cert/cacert.pem')
ENV['RAKE_MODULE'] = 'Capsicum'

require 'bundler/setup'
require 'capsicum'

desc 'test all'
task test: ['capsicum:test']

[:start, :stop, :restart].each do |action|
  desc "#{action} all"
  task action => ["capsicum:sidekiq:#{action}", "capsicum:thin:#{action}"]
end

['Ginseng', ENV['RAKE_MODULE']].each do |prefix|
  Dir.glob(File.join("#{prefix}::Environment".constantize.dir, 'lib/task/*.rb')).each do |f|
    require f
  end
end
