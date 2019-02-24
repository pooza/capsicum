require 'addressable/uri'
require 'httparty'
require 'nokogiri'

module Capsicum
  class Crawler
    attr_reader :name

    def initialize(name)
      @config = Config.instance
      @name = name
    end

    def crawl
      @config["/dictionaries/#{@name}/entries"].each do |entry|
        parse(fetch(entry).to_s).xpath('id("mw-content-text")//a').each do |node|
          next unless node.inner_text.present?
          #next if registered?(node.inner_text) && outdated?(node.inner_text)
pp node.inner_text
          next if registered?({word: node.inner_text, dictionary_id: 1})
pp 11
          next unless href = node.attribute('href')
          link = create_uri(href.value)
          next unless link != 'https'
          next unless link.absolute?
          next unless link.host == root_url.host
          next unless link.path =~ %r{^/wiki/}
          next if link.path.include?(':')
          register({word: node.inner_text, link: link})
        rescue => e
          Ginseng::Error.create(e)
          pp e
          next
        end
      end
    end

    def create_uri(href)
      uri = Addressable::URI.parse(href)
      uri.host ||= root_url.host
      uri.port ||= root_url.port
      uri.path ||= '/'
      uri.scheme ||= 'https'
      return uri
    end

    def parse(body)
      return Nokogiri::HTML.parse(body.force_encoding('utf-8'), nil, 'utf-8')
    end

    def registered?(values)
      rows = db.execute('registered_word?', {
        word: values[:word],
        dictionary_id: 1,
      })
      return rows.present?
    end

    def outdated?(values)
      rows = db.execute('outdated_word?', {
        word: values[:word],
        dictionary_id: 1,
        updated_at: (Time.now - 1.week).strftime('%Y%m%d'),
      })
      return rows.present?
    end

    def register(values)
      uri = Addressable::URI.parse(values[:link])
      r = HTTParty.get(uri.normalize)
      return unless r.code == 200
      db.execute('insert_word', {
        word: values[:word],
        updated_at: Time.now.strftime('%Y%m%d'),
        is_noise: !r.to_s.include?(require_word),
        dictionary_id: 1,
      })
    rescue => e
      pp e
    end

    def require_word
      return @config["/dictionaries/#{@name}/require_word"]
    end

    def fetch(word)
      uri = Addressable::URI.parse(@config['/wikipedia/url'])
      uri.path = "/wiki/#{word}"
      return HTTParty.get(uri.normalize)
    end

    def root_url
      @root_url ||= Addressable::URI.parse(@config['/wikipedia/url'])
      return @root_url
    end

    def db
      return Postgres.instance
    end
  end
end
