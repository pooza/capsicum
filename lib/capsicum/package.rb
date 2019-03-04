module Capsicum
  module Package
    def environment_class
      return 'Capsicum::Environment'
    end

    def package_class
      return 'Capsicum::Package'
    end

    def config_class
      return 'Capsicum::Config'
    end

    def logger_class
      return 'Capsicum::Logger'
    end

    def database_class
      return 'Capsicum::Postgres'
    end

    def query_template_class
      return 'Capsicum::QueryTemplate'
    end

    def self.name
      return 'capsicum'
    end

    def self.version
      return Config.instance['/package/version']
    end

    def self.url
      return Config.instance['/package/url']
    end

    def self.full_name
      return "#{name} #{version}"
    end

    def self.user_agent
      return "#{name}/#{version} (#{url})"
    end
  end
end
