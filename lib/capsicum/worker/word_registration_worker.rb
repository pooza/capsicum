module Capsicum
  class WordRegistrationWorker
    include Sidekiq::Worker

    def initialize
      @logger = Logger.new
    end

    def perform(params)
      puts params.to_json
    end
  end
end
