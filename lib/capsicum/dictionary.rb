module Capsicum
  class Dictionary
    def initialize(name)
      @config = Config.instance
      @name = name
      records = db.execute('lookup_dictionary', {name: name})
      @params = records.first if records.present?
    end

    def exist?
      return !@params.nil?
    end

    def id
      return @params['id'].to_i if exist?
      return nil
    end

    def uri
      @uri ||= Addressable::URI.parse(@config["/dictionaries/#{@name}/url"])
      return @uri
    end

    def entries
      return @config["/dictionaries/#{@name}/entries"]
    rescue Ginseng::ConfigError
      return []
    end


    #
    def require_word
      return @config["/dictionaries/#{@name}/require_word"]
    end


    private

    def create_uri(href)
      uri = Addressable::URI.parse(href)
      uri.host ||= root_url.host
      uri.port ||= root_url.port
      uri.path ||= '/'
      uri.scheme ||= 'https'
      return uri
    end

    def registered?(values)
      return db.execute('registered_word?', {
        word: values[:word],
        dictionary_id: 1,
      }).present?
    end

    def outdated?(values)
      return db.execute('outdated_word?', {
        word: values[:word],
        dictionary_id: 1,
        updated_at: (Time.now - 1.week).strftime('%F %T'),
      }).present?
    end

    def register(values)
      uri = Addressable::URI.parse(values[:link])
      r = HTTParty.get(uri.normalize)
      return unless r.code == 200
      db.execute('insert_word', {
        word: values[:word],
        updated_at: Time.now.strftime('%F %T'),
        is_noise: !r.to_s.include?(require_word),
        dictionary_id: 1,
      })
    end



    private

    def db
      return Postgres.instance
    end
  end
end
