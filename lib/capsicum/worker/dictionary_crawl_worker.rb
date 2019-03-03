module Capsicum
  class DictionaryCrawlWorker
    include Sidekiq::Worker
    sidekiq_options retry: false

    def perform
      Dictionary.all do |dic|
        dic.words do |word|
          puts word
        end
      end
    end
  end
end
