module Capsicum
  class DictionaryCrawlWorker
    include Sidekiq::Worker
    sidekiq_options retry: false

    def inilialize
      @logger = Logger.new
    end

    def perform
      Dictionary.all do |dic|
        dic.words do |word|
          WordRegistrationWorker.perform_async({
            dictionary: dic.name,
            word: word,
          })
        rescue => e
          @logger.error(Ginseng::Error.create(e).to_h)
        end
      end
    end
  end
end
