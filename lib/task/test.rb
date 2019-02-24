namespace :capsicum do
  task :test do
    ENV['TEST'] = Capsicum::Package.name
    require 'test/unit'
    Dir.glob(File.join(Capsicum::Environment.dir, 'test/*')).each do |t|
      require t
    end
  end
end
