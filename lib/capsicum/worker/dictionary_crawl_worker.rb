module Capsicum
  class DictionaryCrawlWorker
    include Sidekiq::Worker
    #sidekiq_options retry: false

    def perform
      words = []
      Dictionary.all do |dic|
        dic.words do |word|
          next if words.include?(word)
          dic.register(word) unless dic.registered?(word)
          WordRegistrationWorker.perform_async({
            dictionary: dic.name,
            word: word,
          })
          words.push(word)
        rescue => e
          puts Ginseng::Error.create(e).to_h.to_json
        end
      end
    end
  end
end
