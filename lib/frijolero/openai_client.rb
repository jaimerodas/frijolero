# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'openssl'

module Frijolero
  class OpenAIClient
    BASE_URL = 'https://api.openai.com/v1'

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

      def initialize(api_key:, base_url: BASE_URL, read_timeout: 120)
        @api_key = api_key
        @base_url = base_url
        @read_timeout = read_timeout
      end

      def post_multipart(path, parts)
        uri = uri_for(path)
        request = Net::HTTP::Post.new(uri)
        request.set_form(parts, 'multipart/form-data')
        execute(uri, request)
      end

      def post_json(path, body)
        uri = uri_for(path)
        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(body)
        execute(uri, request)
      end

      def get(path)
        uri = uri_for(path)
        execute(uri, Net::HTTP::Get.new(uri))
      end

      def delete(path)
        uri = uri_for(path)
        execute(uri, Net::HTTP::Delete.new(uri))
      end

      private

      def uri_for(path)
        URI("#{@base_url}#{path}")
      end

      def execute(uri, request)
        request['Authorization'] = "Bearer #{@api_key}"

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = @read_timeout

        cert_store = OpenSSL::X509::Store.new
        cert_store.set_default_paths
        http.cert_store = cert_store

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
        parsed = parse_error_body(response.body)
        message = parsed[:message]
        code = parsed[:code]

        case status
        when 401
          raise AuthenticationError.new(message, status: status, code: code)
        when 429
          raise InsufficientQuotaError.new(message, status: status, code: code) if code == 'insufficient_quota'

          raise RateLimitError.new(message, status: status, code: code)

        else
          raise APIError.new(message, status: status, code: code)
        end
      end

      def parse_error_body(body)
        return { message: '(empty response)', code: nil } if body.nil? || body.empty?

        data = JSON.parse(body)
        err = data.is_a?(Hash) ? data['error'] : nil

        if err.is_a?(Hash)
          { message: err['message'] || body.to_s[0, 200], code: err['code'] }
        else
          { message: body.to_s[0, 200], code: nil }
        end
      rescue JSON::ParserError
        { message: body.to_s[0, 200], code: nil }
      end
    end

    POLL_INTERVAL_SECONDS = 2
    POLL_TIMEOUT_SECONDS = 300

    def initialize(api_key = nil, transport: nil, poll_interval: POLL_INTERVAL_SECONDS,
                   poll_timeout: POLL_TIMEOUT_SECONDS)
      api_key ||= Config.openai_api_key
      raise ArgumentError, 'OpenAI API key required' unless api_key

      @transport = transport || Transport.new(api_key: api_key)
      @poll_interval = poll_interval
      @poll_timeout = poll_timeout
    end

    def upload_file(path)
      data = File.open(path, 'rb') do |io|
        @transport.post_multipart('/files', [
                                    %w[purpose user_data],
                                    ['file', io, { filename: File.basename(path), content_type: 'application/pdf' }]
                                  ])
      end

      raise APIError, "File upload failed: #{data}" unless data['id']

      data['id']
    end

    def extract_transactions(file_id, prompt_id)
      data = poll_response(start_extraction(file_id, prompt_id)['id'])
      json_text = parse_response_text(data)

      raise APIError, "Failed to extract transactions: #{data}" unless json_text

      JSON.parse(json_text)
    end

    def start_extraction(file_id, prompt_id)
      @transport.post_json('/responses', {
                             prompt: { id: prompt_id },
                             input: [{
                               role: 'user',
                               content: [{ type: 'input_file', file_id: file_id }]
                             }],
                             background: true
                           })
    end

    def parse_response_text(data)
      text_output = data['output']&.find { |o| o['type'] == 'message' }
      content = text_output&.fetch('content', nil)&.find { |c| c['type'] == 'output_text' }
      content && content['text']
    end

    def delete_file(file_id)
      @transport.delete("/files/#{file_id}")
      nil
    end

    private

    def poll_response(response_id)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @poll_timeout

      loop do
        sleep @poll_interval
        data = @transport.get("/responses/#{response_id}")

        case data['status']
        when 'completed'
          return data
        when 'queued', 'in_progress'
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            raise APIError, "Response polling timed out after #{@poll_timeout}s (still #{data['status']})"
          end

          next
        else
          raise APIError, "Response failed with status: #{data['status']}"
        end
      end
    end
  end
end
