module Capsicum
  class Server < Ginseng::Sinatra
    include Package


    not_found do
      @renderer.status = 404
      @renderer.message = NotFoundError.new("Resource #{request.path} not found.").to_h
      return @renderer.to_s
    end

    error do |e|
      e = Ginseng::Error.create(e)
      @renderer.status = e.status
      @renderer.message = e.to_h.delete_if{|k, v| k == :backtrace}
      Slack.broadcast(e.to_h) unless e.status == 404
      @logger.error(e.to_h)
      return @renderer.to_s
    end
  end
end
