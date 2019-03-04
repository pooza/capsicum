module Capsicum
  class WordRegistrationWorker
    include Sidekiq::Worker

    def perform(params)
      pp params
    end
  end
end
