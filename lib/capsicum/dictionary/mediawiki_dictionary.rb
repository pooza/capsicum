module Capsicum
  class MediawikiDictionary < Dictionary
    def uri
      @root_uri ||= Addressable::URI.parse(@config["/dictionaries/#{@name}/url"])
      return @root_uri
    rescue Ginseng::ConfigError
      @root_uri ||= Addressable::URI.parse(@config['/wikipedia/url'])
      retry
    end

    def pllimit
      @pllimit ||= @config["/dictionaries/#{@name}/pllimit"]
      return @pllimit
    rescue Ginseng::ConfigError
      @pllimit ||= @config['/wikipedia/pllimit']
      retry
    end

    def words
      return enum_for(__method__) unless block_given?
      entries.each do |entry|
        query = {prop: 'links', titles: entry, pllimit: pllimit}
        loop do
          response = fetch(query).parsed_response
          response['query']['pages'].each do |k, page|
            page['links'].each do |link|
              next if link['title'].include?(':')
              yield link['title']
            end
          end
          break if response['continue'].nil?
          query[:plcontinue] = response['continue']['plcontinue']
        end
      end
    end

    def fetch(query)
      query[:format] ||= 'json'
      query[:action] ||= 'query'
      uri = self.uri.clone
      uri.path = '/w/api.php'
      uri.query_values = query
      return HTTParty.get(uri.normalize, {
        headers: {'User-Agent' => Package.user_agent},
      })
    end
  end
end
