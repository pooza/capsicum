module Capsicum
  class Postgres < Ginseng::Postgres::Database
    include Singleton
    include Package

    def default_dbname
      return 'capsicum'
    end

    def self.dsn
      config = Config.instance
      return Ginseng::Postgres::DSN.parse(config['/postgres/dsn'])
    end
  end
end
