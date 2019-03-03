module Capsicum
  class DictionaryCrawlWorker
    include Sidekiq::Worker
    sidekiq_options retry: false

    def perform
      Dictionary.all do |dic|
        dic.words do |word|
          WordRegistrationWorker.perform_async({
            dictionary: dic.name,
            word: word,
          })
        end
      end
    end
  end
end
