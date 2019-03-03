module Capsicum
  class WordRegistrationWorker
    include Sidekiq::Worker
    sidekiq_options retry: false

    def perform(params)

    end
  end
end
