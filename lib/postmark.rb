# frozen_string_literal: true

module Frijolero
  # Email through the HTTP API of Postmark, because DigitalOcean blocks SMTP from its
  # droplets. Without POSTMARK_API_TOKEN (development), the message goes to the log.
  module Postmark
    class Error < StandardError; end

    URL = 'https://api.postmarkapp.com'

    def self.deliver(to:, subject:, text:)
      token = ENV.fetch('POSTMARK_API_TOKEN', '')
      return Log.puts("Correo para #{to}: #{subject}\n\n#{text}") if token.empty?

      # A request waits for this answer, so the timeout is short.
      transport = LLM::Transport.new(base_url: URL, read_timeout: 15,
                                     headers: { 'X-Postmark-Server-Token' => token, 'Accept' => 'application/json' })
      transport.post_json('/email', { From: ENV.fetch('MAIL_FROM'), To: to, Subject: subject, TextBody: text,
                                      MessageStream: 'outbound' })
    rescue LLM::Error => e
      # The message is the body of the answer, with Postmark's ErrorCode and Message.
      raise Error, "Postmark: #{e.message}"
    end
  end
end
