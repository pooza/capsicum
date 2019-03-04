module Capsicum
  class Postgres < Ginseng::Postgres::Database
    include Package

    def default_dbname
      return 'capsicum'
    end

    def self.dsn
      return Ginseng::Postgres::DSN.parse(Config.instance['/postgres/dsn'])
    end
  end
end
