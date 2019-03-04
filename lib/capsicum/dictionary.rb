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
    end

    def uri
      return Addressable::URI.parse(@config["/dictionaries/#{@name}/url"])
    end

    alias url uri

    def entries
      return @config["/dictionaries/#{@name}/entries"]
    rescue Ginseng::ConfigError
      return []
    end

    def required_words
      return @config["/dictionaries/#{@name}/required_words"]
    rescue Ginseng::ConfigError
      return []
    end

    def words
      raise Ginseng::ImplementError, "'#{__method__}' not implemented"
    end

    def registered?(word)
      return db.execute('lookup_word', {
        word: word,
        dictionary_name: name,
      }).present?
    end

    def outdated?(word)
      rows = db.execute('lookup_word', {
        word: word,
        dictionary_name: name,
      })
      return false unless rows.present?
      return (Time.now - 1.week) < Time.parse(rows.first['updated_at'])
    end

    def register(word)
      db.execute('insert_word', {
        word: word,
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
      raise Ginseng::DatabaseError, "invalid dictionary '#{name}'" unless records.present?
      @params = records.first
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
