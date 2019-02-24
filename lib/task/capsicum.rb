namespace :capsicum do
  desc 'crawl'
  task :crawl do
    sh File.join(Capsicum::Environment.dir, 'bin/crawl.rb')
  end
end
