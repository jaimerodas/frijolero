# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'openssl'
require 'base64'

module Frijolero
  # What the app needs from a model: a PDF and a prompt spec in, JSON out. Each
  # provider is one class with `extract(pdf_path, spec)`. LLM_PROVIDER picks it and
  # the key comes from that provider's own variable. The spec is the ledger's
  # config/prompts/<type> (PromptSpec): model, instructions, format (the JSON
  # schema) and any other key, which each client forwards to its API as-is.
  module LLM
    class Error < StandardError
      attr_reader :status, :code

      def initialize(message, status: nil, code: nil)
        super(message)
        @status = status
        @code = code
      end
    end

    class AuthenticationError < Error; end
    class InsufficientQuotaError < Error; end
    class RateLimitError < Error; end
    class APIError < Error; end
    class NetworkError < Error; end

    Provider = Struct.new(:name, :key_var, :build)
    PROVIDERS = {
      'openai' => Provider.new('OpenAI', 'OPENAI_API_KEY', ->(key) { OpenAIClient.new(key) }),
      'anthropic' => Provider.new('Anthropic', 'ANTHROPIC_API_KEY', ->(key) { AnthropicClient.new(key) })
    }.freeze

    def self.provider
      name = ENV.fetch('LLM_PROVIDER', 'openai')
      PROVIDERS.fetch(name) { raise Error, "LLM_PROVIDER desconocido: #{name}" }
    end

    def self.key_var = provider.key_var

    # nil without the key: the upload routes then name the missing variable.
    def self.client
      key = ENV.fetch(key_var, nil)
      provider.build.call(key) if key
    end

    def self.pdf_base64(path) = Base64.strict_encode64(File.binread(path))

    # One HTTPS client for both providers: JSON in, JSON out, typed errors. Both nest
    # the error under "error"; OpenAI names it in "code", Anthropic in "type".
    class Transport
      NETWORK_EXCEPTIONS = [
        Net::OpenTimeout,
        Net::ReadTimeout,
        SocketError,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::EHOSTUNREACH,
        Errno::ENETUNREACH,
        OpenSSL::SSL::SSLError
      ].freeze

      def initialize(base_url:, headers:, read_timeout: 120)
        @base_url = base_url
        @headers = headers
        @read_timeout = read_timeout
      end

      def post_json(path, body)
        request = Net::HTTP::Post.new(uri_for(path), @headers)
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(body)
        execute(request)
      end

      def get(path)
        execute(Net::HTTP::Get.new(uri_for(path), @headers))
      end

      private

      def uri_for(path) = URI("#{@base_url}#{path}")

      def execute(request)
        http = Net::HTTP.new(request.uri.host, request.uri.port)
        http.use_ssl = true
        http.read_timeout = @read_timeout
        http.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)

        response = begin
          http.request(request)
        rescue *NETWORK_EXCEPTIONS => e
          raise NetworkError, "#{e.class}: #{e.message}"
        end

        return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

        raise_error_for(response)
      end

      def raise_error_for(response)
        status = response.code.to_i
        message, code = parse_error_body(response.body)
        klass = case status
                when 401 then AuthenticationError
                when 402 then InsufficientQuotaError
                when 429 then code == 'insufficient_quota' ? InsufficientQuotaError : RateLimitError
                when 529 then RateLimitError
                else APIError
                end
        raise klass.new(message, status: status, code: code)
      end

      def parse_error_body(body)
        return ['(empty response)', nil] if body.nil? || body.empty?

        err = JSON.parse(body)['error']
        return [body.to_s[0, 200], nil] unless err.is_a?(Hash)

        [err['message'] || body.to_s[0, 200], err['code'] || err['type']]
      rescue JSON::ParserError, TypeError
        [body.to_s[0, 200], nil]
      end
    end

    # One entry per error class: what to log, and whether the statement ends with
    # ERROR (recoverable: upload again) or the job raises (fix the key or the credit).
    POLICIES = {
      InsufficientQuotaError => [false, lambda { |e|
        ["✗ #{provider.name} rejected the request: out of credits.", "    Detail: #{e.message}"]
      }],
      AuthenticationError => [false, lambda { |e|
        ["✗ #{provider.name} rejected the API key. Check #{key_var}.", "    Detail: #{e.message}"]
      }],
      RateLimitError => [true, lambda { |e|
        ["✗ #{provider.name} rate limit hit, try again in a few seconds.", "    Detail: #{e.message}"]
      }],
      NetworkError => [true, lambda { |e|
        ["✗ Network error calling #{provider.name}: #{e.message}", '    Check your internet connection.']
      }],
      APIError => [true, lambda { |e|
        status = e.status ? " (HTTP #{e.status})" : ''
        ["✗ #{provider.name} returned an error#{status}: #{e.message}"]
      }]
    }.freeze

    HANDLED = POLICIES.keys.freeze

    def self.report(error)
      recoverable, lines = POLICIES.fetch(error.class)
      lines.call(error).each { |line| Log.puts line }
      raise error unless recoverable
    end
  end
end
