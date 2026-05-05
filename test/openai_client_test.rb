# frozen_string_literal: true

require "test_helper"
require "net/http"

class OpenAIClientTest < Minitest::Test
  include TestHelpers

  class FakeHttp
    attr_accessor :use_ssl, :read_timeout, :cert_store

    def initialize(response_or_exception)
      @result = response_or_exception
    end

    def request(_req)
      raise @result if @result.is_a?(Exception)
      @result
    end
  end

  def setup
    @client = Frijolero::OpenAIClient.new("test-key")
  end

  def make_response(klass, code, body)
    resp = klass.new("1.1", code, "")
    resp.instance_variable_set(:@body, body)
    def resp.body
      @body
    end
    resp
  end

  def with_http(result)
    Net::HTTP.stub(:new, FakeHttp.new(result)) { yield }
  end

  def test_authentication_error_on_401
    body = '{"error":{"message":"Invalid API key","code":"invalid_api_key"}}'
    resp = make_response(Net::HTTPUnauthorized, "401", body)

    error = with_http(resp) do
      assert_raises(Frijolero::OpenAIClient::AuthenticationError) do
        @client.delete_file("file-123")
      end
    end

    assert_equal 401, error.status
    assert_equal "invalid_api_key", error.code
    assert_includes error.message, "Invalid API key"
  end

  def test_insufficient_quota_error_on_429_with_quota_code
    body = '{"error":{"message":"You exceeded your current quota","code":"insufficient_quota"}}'
    resp = make_response(Net::HTTPTooManyRequests, "429", body)

    error = with_http(resp) do
      assert_raises(Frijolero::OpenAIClient::InsufficientQuotaError) do
        @client.delete_file("file-123")
      end
    end

    assert_equal 429, error.status
    assert_equal "insufficient_quota", error.code
    assert_includes error.message, "exceeded your current quota"
  end

  def test_rate_limit_error_on_429_without_quota_code
    body = '{"error":{"message":"Rate limit hit","code":"rate_limit_exceeded"}}'
    resp = make_response(Net::HTTPTooManyRequests, "429", body)

    error = with_http(resp) do
      assert_raises(Frijolero::OpenAIClient::RateLimitError) do
        @client.delete_file("file-123")
      end
    end

    assert_equal 429, error.status
    assert_equal "rate_limit_exceeded", error.code
  end

  def test_api_error_on_500
    body = '{"error":{"message":"Internal server error"}}'
    resp = make_response(Net::HTTPInternalServerError, "500", body)

    error = with_http(resp) do
      assert_raises(Frijolero::OpenAIClient::APIError) do
        @client.delete_file("file-123")
      end
    end

    assert_equal 500, error.status
    assert_includes error.message, "Internal server error"
  end

  def test_network_error_on_open_timeout
    error = with_http(Net::OpenTimeout.new("connection timed out")) do
      assert_raises(Frijolero::OpenAIClient::NetworkError) do
        @client.delete_file("file-123")
      end
    end

    assert_includes error.message, "Net::OpenTimeout"
    assert_includes error.message, "connection timed out"
  end

  def test_network_error_on_socket_error
    error = with_http(SocketError.new("getaddrinfo failed")) do
      assert_raises(Frijolero::OpenAIClient::NetworkError) do
        @client.delete_file("file-123")
      end
    end

    assert_includes error.message, "SocketError"
  end

  def test_api_error_falls_back_when_body_is_not_json
    resp = make_response(Net::HTTPInternalServerError, "500", "<html>oops</html>")

    error = with_http(resp) do
      assert_raises(Frijolero::OpenAIClient::APIError) do
        @client.delete_file("file-123")
      end
    end

    assert_includes error.message, "<html>oops</html>"
  end

  def test_api_error_falls_back_when_body_is_empty
    resp = make_response(Net::HTTPInternalServerError, "500", "")

    error = with_http(resp) do
      assert_raises(Frijolero::OpenAIClient::APIError) do
        @client.delete_file("file-123")
      end
    end

    assert_equal 500, error.status
    refute_nil error.message
  end
end
