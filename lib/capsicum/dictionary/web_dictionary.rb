module Capsicum
  class WebDictionary < Dictionary
    def words
      return enum_for(__method__) unless block_given?
      entries.each do |entry|
        parse(fetch_entry(entry).to_s).xpath('id("mw-content-text")//a').each do |node|
          next unless node.inner_text.present?
          next unless href = node.attribute('href')
          uri = self.uri.clone

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

    private

    def fetch_entry(entry)
      uri = self.uri.clone
      uri.path = "/wiki/#{entry}"
      return HTTParty.get(uri.normalize)
    end
  end
end
