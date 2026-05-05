# frozen_string_literal: true

require 'test_helper'
require 'net/http'
require 'tempfile'

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
    @client = Frijolero::OpenAIClient.new('test-key')
  end

  def make_response(klass, code, body)
    resp = klass.new('1.1', code, '')
    resp.instance_variable_set(:@body, body)
    def resp.body
      @body
    end
    resp
  end

  def with_http(result, &block)
    Net::HTTP.stub(:new, FakeHttp.new(result), &block)
  end

  def test_authentication_error_on_401
    body = '{"error":{"message":"Invalid API key","code":"invalid_api_key"}}'
    resp = make_response(Net::HTTPUnauthorized, '401', body)

    error = with_http(resp) do
      assert_raises(Frijolero::OpenAIClient::AuthenticationError) do
        @client.delete_file('file-123')
      end
    end

    assert_equal 401, error.status
    assert_equal 'invalid_api_key', error.code
    assert_includes error.message, 'Invalid API key'
  end

  def test_insufficient_quota_error_on_429_with_quota_code
    body = '{"error":{"message":"You exceeded your current quota","code":"insufficient_quota"}}'
    resp = make_response(Net::HTTPTooManyRequests, '429', body)

    error = with_http(resp) do
      assert_raises(Frijolero::OpenAIClient::InsufficientQuotaError) do
        @client.delete_file('file-123')
      end
    end

    assert_equal 429, error.status
    assert_equal 'insufficient_quota', error.code
    assert_includes error.message, 'exceeded your current quota'
  end

  def test_rate_limit_error_on_429_without_quota_code
    body = '{"error":{"message":"Rate limit hit","code":"rate_limit_exceeded"}}'
    resp = make_response(Net::HTTPTooManyRequests, '429', body)

    error = with_http(resp) do
      assert_raises(Frijolero::OpenAIClient::RateLimitError) do
        @client.delete_file('file-123')
      end
    end

    assert_equal 429, error.status
    assert_equal 'rate_limit_exceeded', error.code
  end

  def test_api_error_on_500
    body = '{"error":{"message":"Internal server error"}}'
    resp = make_response(Net::HTTPInternalServerError, '500', body)

    error = with_http(resp) do
      assert_raises(Frijolero::OpenAIClient::APIError) do
        @client.delete_file('file-123')
      end
    end

    assert_equal 500, error.status
    assert_includes error.message, 'Internal server error'
  end

  def test_network_error_on_open_timeout
    error = with_http(Net::OpenTimeout.new('connection timed out')) do
      assert_raises(Frijolero::OpenAIClient::NetworkError) do
        @client.delete_file('file-123')
      end
    end

    assert_includes error.message, 'Net::OpenTimeout'
    assert_includes error.message, 'connection timed out'
  end

  def test_network_error_on_socket_error
    error = with_http(SocketError.new('getaddrinfo failed')) do
      assert_raises(Frijolero::OpenAIClient::NetworkError) do
        @client.delete_file('file-123')
      end
    end

    assert_includes error.message, 'SocketError'
  end

  def test_api_error_falls_back_when_body_is_not_json
    resp = make_response(Net::HTTPInternalServerError, '500', '<html>oops</html>')

    error = with_http(resp) do
      assert_raises(Frijolero::OpenAIClient::APIError) do
        @client.delete_file('file-123')
      end
    end

    assert_includes error.message, '<html>oops</html>'
  end

  def test_api_error_falls_back_when_body_is_empty
    resp = make_response(Net::HTTPInternalServerError, '500', '')

    error = with_http(resp) do
      assert_raises(Frijolero::OpenAIClient::APIError) do
        @client.delete_file('file-123')
      end
    end

    assert_equal 500, error.status
    refute_nil error.message
  end

  class FakeTransport
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def delete(path)
      @calls << [:delete, path]
      @responses.fetch(:delete)
    end

    def post_multipart(path, parts)
      @calls << [:post_multipart, path, parts]
      @responses.fetch(:post_multipart)
    end
  end

  def test_accepts_injected_transport_for_delete
    transport = FakeTransport.new(delete: { 'deleted' => true })
    client = Frijolero::OpenAIClient.new('test-key', transport: transport)

    assert_equal true, client.delete_file('file-123')
    assert_equal [[:delete, '/files/file-123']], transport.calls
  end

  def test_upload_file_returns_id_from_transport
    transport = FakeTransport.new(post_multipart: { 'id' => 'file-abc' })
    client = Frijolero::OpenAIClient.new('test-key', transport: transport)

    Tempfile.create(['statement', '.pdf']) do |f|
      f.write('%PDF-1.4')
      f.flush
      assert_equal 'file-abc', client.upload_file(f.path)
    end

    method, path, parts = transport.calls.first
    assert_equal :post_multipart, method
    assert_equal '/files', path
    assert_equal 'user_data', parts.first[1]
  end

  def test_upload_file_raises_api_error_when_id_missing
    transport = FakeTransport.new(post_multipart: { 'error' => 'something' })
    client = Frijolero::OpenAIClient.new('test-key', transport: transport)

    Tempfile.create(['statement', '.pdf']) do |f|
      f.write('%PDF-1.4')
      f.flush
      assert_raises(Frijolero::OpenAIClient::APIError) do
        client.upload_file(f.path)
      end
    end
  end

  class StuckTransport
    def get(_path) = { 'status' => 'queued' }
  end

  def test_poll_response_times_out_when_status_never_completes
    client = Frijolero::OpenAIClient.new(
      'test-key',
      transport: StuckTransport.new,
      poll_interval: 0,
      poll_timeout: 0.001
    )

    error = assert_raises(Frijolero::OpenAIClient::APIError) do
      client.send(:poll_response, 'resp-123')
    end
    assert_includes error.message, 'timed out'
    assert_includes error.message, 'queued'
  end
end
