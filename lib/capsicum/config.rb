module Capsicum
  class Config < Ginseng::Config
    include Package

    def initialize
      super
      dirs.each do |dir|
        suffixes.each do |suffix|
          path = File.join(dir, "local#{suffix}")
          next unless File.exist?(path)
          self['/dictionary_names'] = YAML.load_file(path)['dictionaries'].keys
        end
      end
    end
  end
end
