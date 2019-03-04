module Capsicum
  class WordRegistrationWorker
    include Sidekiq::Worker

    def initialize
      @logger = Logger.new
    end

    def perform(params)
    end
  end
end
