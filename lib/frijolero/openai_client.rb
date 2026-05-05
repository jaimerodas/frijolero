# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "openssl"

module Frijolero
  class OpenAIClient
    BASE_URL = "https://api.openai.com/v1"

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

    def initialize(api_key = nil)
      @api_key = api_key || Config.openai_api_key
      raise ArgumentError, "OpenAI API key required" unless @api_key
    end

    # Upload a file to OpenAI
    # Returns the file_id
    def upload_file(path)
      uri = URI("#{BASE_URL}/files")

      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request.set_form(
        [
          ["purpose", "user_data"],
          ["file", File.open(path, "rb"), {filename: File.basename(path), content_type: "application/pdf"}]
        ],
        "multipart/form-data"
      )

      response = make_request(uri, request)
      data = JSON.parse(response.body)

      raise APIError.new("File upload failed: #{data}") unless data["id"]

      data["id"]
    end

    # Extract transactions from a file using the responses endpoint
    # Returns the parsed JSON response
    def extract_transactions(file_id, prompt_id)
      uri = URI("#{BASE_URL}/responses")

      body = {
        prompt: {
          id: prompt_id
        },
        input: [
          {
            role: "user",
            content: [
              {
                type: "input_file",
                file_id: file_id
              }
            ]
          }
        ],
        background: true
      }

      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)

      response = make_request(uri, request)
      data = JSON.parse(response.body)

      # Poll until the background response completes
      data = poll_response(data["id"])

      # Extract the text content from the response
      text_output = data.dig("output")&.find { |o| o["type"] == "message" }
      content = text_output&.dig("content")&.find { |c| c["type"] == "output_text" }
      json_text = content&.dig("text")

      raise APIError.new("Failed to extract transactions: #{data}") unless json_text

      JSON.parse(json_text)
    end

    # Delete a file from OpenAI
    def delete_file(file_id)
      uri = URI("#{BASE_URL}/files/#{file_id}")

      request = Net::HTTP::Delete.new(uri)
      request["Authorization"] = "Bearer #{@api_key}"

      response = make_request(uri, request)
      data = JSON.parse(response.body)

      data["deleted"] == true
    end

    private

    def poll_response(response_id)
      uri = URI("#{BASE_URL}/responses/#{response_id}")

      loop do
        sleep 2
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{@api_key}"
        response = make_request(uri, request)
        data = JSON.parse(response.body)

        case data["status"]
        when "completed"
          return data
        when "queued", "in_progress"
          next
        else
          raise APIError.new("Response failed with status: #{data["status"]}")
        end
      end
    end

    def make_request(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 120

      cert_store = OpenSSL::X509::Store.new
      cert_store.set_default_paths
      http.cert_store = cert_store

      response = begin
        http.request(request)
      rescue *NETWORK_EXCEPTIONS => e
        raise NetworkError.new("#{e.class}: #{e.message}")
      end

      return response if response.is_a?(Net::HTTPSuccess)

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
        if code == "insufficient_quota"
          raise InsufficientQuotaError.new(message, status: status, code: code)
        else
          raise RateLimitError.new(message, status: status, code: code)
        end
      else
        raise APIError.new(message, status: status, code: code)
      end
    end

    def parse_error_body(body)
      return {message: "(empty response)", code: nil} if body.nil? || body.empty?

      data = JSON.parse(body)
      err = data.is_a?(Hash) ? data["error"] : nil

      if err.is_a?(Hash)
        {message: err["message"] || body.to_s[0, 200], code: err["code"]}
      else
        {message: body.to_s[0, 200], code: nil}
      end
    rescue JSON::ParserError
      {message: body.to_s[0, 200], code: nil}
    end
  end
end
