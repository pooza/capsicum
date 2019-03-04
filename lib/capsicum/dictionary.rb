require 'nokogiri'
require 'addressable/uri'

module Capsicum
  class Dictionary
    attr_reader :name

    def exist?
      return !@params.nil?
    end

    def id
      return @params['id'].to_i if exist?
      return nil
    end

    def type
      return @config["/dictionaries/#{@name}/type"]
    rescue Ginseng::ConfigError
      return 'web'
    end

    def words
      raise Ginseng::ImplementError, "'#{__method__}' not implemented"
    end

    def registered?(values)
      return db.execute('registered_word?', {
        word: values[:word],
        dictionary_id: id,
      }).present?
    end

    def outdated?(values)
      return db.execute('outdated_word?', {
        word: values[:word],
        dictionary_id: id,
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
        dictionary_id: id,
      })
    end

    def self.create(name)
      type = Config.instance["/dictionaries/#{name}/type"]
      return "Capsicum::#{type.camelize}Dictionary".constantize.new(name)
    end

    def self.all
      return enum_for(__method__) unless block_given?
      Config.instance['/dictionary_names'].each do |name|
        yield Dictionary.create(name)
      end
    end

    private

    def initialize(name)
      @config = Config.instance
      @name = name
      records = db.execute('lookup_dictionary', {name: name})
      @params = records.first if records.present?
      @words = []
    end

    def parse(body)
      return Nokogiri::HTML.parse(body.force_encoding('utf-8'), nil, 'utf-8')
    end

    def db
      return Postgres.instance
    end
  end
end
