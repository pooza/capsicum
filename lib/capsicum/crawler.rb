require 'addressable/uri'
require 'httparty'
require 'nokogiri'

module Capsicum
  class Crawler
    attr_accessor :uri

    def initialize(uri)
      @config = Config.instance
      @uri = Addressable::URI.parse(uri.to_s)
    end

    def source
      @source ||= Nokogiri::HTML.parse(
        HTTParty.get(@uri.normalize).to_s.force_encoding('utf-8'),
        nil,
        'utf-8',
      )
      return @source
    end

    def words
      source.xpath('id("mw-content-text")//a').each do |node|
        next unless node.inner_text.present?
        link = Addressable::URI.parse(node.attribute('href').value)
        link.host ||= @uri.host
        link.port ||= @uri.port
        link.path ||= '/'
        link.scheme ||= 'https'
        next unless link != 'https'
        next unless link.absolute?
        next unless link.host == @uri.host
        next unless link.path =~ %r{^/wiki/}
        next if link.path.include?(':')
        v = {word: node.inner_text, link: link}
        yield v
      rescue
        next
      end
    end

    def self.crawl_all
      result = {}
      config = Config.instance
      config['/entries'].each do |entry|
        uri = Addressable::URI.parse(config['/root_url'])
        uri.path = "/wiki/#{entry}"
        crawler = Crawler.new(uri)
        crawler.words do |word|
          next if result[word[:word]]
          uri = Addressable::URI.parse(word[:link])
          next unless HTTParty.get(uri.normalize).to_s.include?(config['/require_word'])
          result[word[:word]] = word
        end
      end
      result = result.sort_by{|k, v| k}
      return result
    end
  end
end
