require 'addressable/uri'
require 'uri'
require 'httparty'
require 'nokogiri'

module Capsicum
  class Crawler
    attr_reader :name

    def initialize(name)
      @config = Config.instance
      @name = name
      @words = []
    end

    def dictionary
      @dictionary ||= Dictionary.new(name)
      return @dictionary
    end

    def words
      return enum_for(__method__) unless block_given?
      dictionary.entries.each do |entry|
        parse(fetch_entry(entry).to_s).xpath('id("mw-content-text")//a').each do |node|
          next unless node.inner_text.present?
          next unless href = node.attribute('href')
          uri = dictionary.uri.clone
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

    def fetch_entry(entry)
      uri = Addressable::URI.parse(dictionary.uri)
      uri.path = "/wiki/#{entry}"
      return HTTParty.get(uri.normalize)
    end

    def parse(body)
      return Nokogiri::HTML.parse(body.force_encoding('utf-8'), nil, 'utf-8')
    end

    def self.all
      return enum_for(__method__) unless block_given?
      Config.instance['/dictionary_names'].each do |name|
        yield Crawler.new(name)
      end
    end

    private

    def db
      return Postgres.instance
    end
  end
end
