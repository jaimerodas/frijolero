# frozen_string_literal: true

module Frijolero
  module OpenAIErrorReporter
    POLICIES = {
      OpenAIClient::InsufficientQuotaError => {
        recoverable: false,
        report: lambda do |e|
          UI.puts '{{x}} OpenAI rejected the request: out of credits.'
          UI.puts '    Add credits at https://platform.openai.com/account/billing'
          UI.puts "    Detail: #{e.message}"
        end
      },
      OpenAIClient::AuthenticationError => {
        recoverable: false,
        report: lambda do |e|
          UI.puts '{{x}} OpenAI rejected the API key. Check ~/.frijolero/config.yaml.'
          UI.puts "    Detail: #{e.message}"
        end
      },
      OpenAIClient::RateLimitError => {
        recoverable: true,
        report: lambda do |e|
          UI.puts '{{x}} OpenAI rate limit hit, try again in a few seconds.'
          UI.puts "    Detail: #{e.message}"
        end
      },
      OpenAIClient::NetworkError => {
        recoverable: true,
        report: lambda do |e|
          UI.puts "{{x}} Network error calling OpenAI: #{e.message}"
          UI.puts '    Check your internet connection.'
        end
      },
      OpenAIClient::APIError => {
        recoverable: true,
        report: lambda do |e|
          status = e.status ? " (HTTP #{e.status})" : ''
          UI.puts "{{x}} OpenAI returned an error#{status}: #{e.message}"
        end
      }
    }.freeze

    HANDLED = POLICIES.keys.freeze

    def self.handle(error, client:, file_id: nil)
      policy = POLICIES.fetch(error.class)
      policy[:report].call(error)
      cleanup(client, file_id)
      raise error unless policy[:recoverable]
    end

    def self.cleanup(client, file_id)
      return unless file_id && client

      client.delete_file(file_id)
    rescue StandardError
      nil
    end
  end
end
