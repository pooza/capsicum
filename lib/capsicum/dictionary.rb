require 'nokogiri'
require 'addressable/uri'

module Capsicum
  class Dictionary
    attr_reader :name

    def initialize(name)
      @config = Config.instance
      @name = name
      records = db.execute('lookup_dictionary', {name: name})
      @params = records.first if records.present?
      @words = []
    end

    def exist?
      return !@params.nil?
    end

    def id
      return @params['id'].to_i if exist?
      return nil
    end

    def root_uri
      @root_uri ||= Addressable::URI.parse(@config["/dictionaries/#{@name}/url"])
      return @root_uri
    end

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
      return enum_for(__method__) unless block_given?
      entries.each do |entry|
        parse(fetch_entry(entry).to_s).xpath('id("mw-content-text")//a').each do |node|
          next unless node.inner_text.present?
          next unless href = node.attribute('href')
          uri = root_uri.clone

          uri.path = href.value
          next if uri.path =~ %r{/index.php$}
          next if uri.path.include?(':')
          next if uri.fragment.present?
          word = node.inner_text
          next if @words.include?(word)
          @words.push(word)
          yield word
        end
      end
    end



    #
    def registered?(values)
      return db.execute('registered_word?', {
        word: values[:word],
        dictionary_id: id,
      }).present?
    end

    #
    def outdated?(values)
      return db.execute('outdated_word?', {
        word: values[:word],
        dictionary_id: id,
        updated_at: (Time.now - 1.week).strftime('%F %T'),
      }).present?
    end

    #
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

    def self.all
      return enum_for(__method__) unless block_given?
      Config.instance['/dictionary_names'].each do |name|
        yield Dictionary.new(name)
      end
    end

    private

    def fetch_entry(entry)
      uri = root_uri.clone
      uri.path = "/wiki/#{entry}"
      return HTTParty.get(uri.normalize)
    end

    def parse(body)
      return Nokogiri::HTML.parse(body.force_encoding('utf-8'), nil, 'utf-8')
    end

    def db
      return Postgres.instance
    end
  end
end
