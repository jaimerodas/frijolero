# frozen_string_literal: true

require 'test_helper'
require 'net/http'
require 'stringio'

# The shared transport (typed errors from both providers' error bodies), the
# provider switch and the error policy.
class LLMTest < Minitest::Test
  include TestHelpers

  class FakeHttp
    attr_accessor :use_ssl, :read_timeout, :cert_store

    def initialize(response_or_exception)
      @result = response_or_exception
    end

    def request(req)
      @request = req
      raise @result if @result.is_a?(Exception)

      @result
    end
  end

  def make_response(klass, code, body)
    resp = klass.new('1.1', code, '')
    resp.instance_variable_set(:@body, body)
    def resp.body
      @body
    end
    resp
  end

  def transport
    Frijolero::LLM::Transport.new(base_url: 'https://api.example/v1', headers: { 'x-key' => 'k' })
  end

  def request(result, &)
    Net::HTTP.stub(:new, FakeHttp.new(result)) { transport.get('/x') }
  end

  def test_authentication_error_on_401
    body = '{"error":{"message":"Invalid API key","code":"invalid_api_key"}}'

    error = assert_raises(Frijolero::LLM::AuthenticationError) { request(make_response(Net::HTTPUnauthorized, '401', body)) }

    assert_equal 401, error.status
    assert_equal 'invalid_api_key', error.code
    assert_includes error.message, 'Invalid API key'
  end

  def test_insufficient_quota_error_on_429_with_the_openai_code
    body = '{"error":{"message":"You exceeded your current quota","code":"insufficient_quota"}}'

    error = assert_raises(Frijolero::LLM::InsufficientQuotaError) do
      request(make_response(Net::HTTPTooManyRequests, '429', body))
    end

    assert_equal 'insufficient_quota', error.code
  end

  def test_rate_limit_error_on_429_without_the_quota_code
    body = '{"error":{"message":"Rate limit hit","code":"rate_limit_exceeded"}}'

    error = assert_raises(Frijolero::LLM::RateLimitError) { request(make_response(Net::HTTPTooManyRequests, '429', body)) }

    assert_equal 'rate_limit_exceeded', error.code
  end

  # Anthropic: 402 is billing, 529 is overloaded, and the error's name is in `type`.
  def test_insufficient_quota_error_on_402
    body = '{"type":"error","error":{"type":"billing_error","message":"Your credit balance is too low"}}'

    error = assert_raises(Frijolero::LLM::InsufficientQuotaError) do
      request(make_response(Net::HTTPPaymentRequired, '402', body))
    end

    assert_equal 'billing_error', error.code
    assert_includes error.message, 'credit balance'
  end

  def test_rate_limit_error_on_529
    body = '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'
    resp = make_response(Net::HTTPServerError, '529', body)

    error = assert_raises(Frijolero::LLM::RateLimitError) { request(resp) }

    assert_equal 'overloaded_error', error.code
  end

  def test_api_error_on_500
    body = '{"error":{"message":"Internal server error"}}'

    error = assert_raises(Frijolero::LLM::APIError) { request(make_response(Net::HTTPInternalServerError, '500', body)) }

    assert_equal 500, error.status
    assert_includes error.message, 'Internal server error'
  end

  def test_network_error_on_open_timeout
    error = assert_raises(Frijolero::LLM::NetworkError) { request(Net::OpenTimeout.new('connection timed out')) }

    assert_includes error.message, 'Net::OpenTimeout'
    assert_includes error.message, 'connection timed out'
  end

  def test_api_error_falls_back_when_body_is_not_json
    error = assert_raises(Frijolero::LLM::APIError) { request(make_response(Net::HTTPInternalServerError, '500', '<html>')) }

    assert_includes error.message, '<html>'
  end

  def test_api_error_falls_back_when_body_is_empty
    error = assert_raises(Frijolero::LLM::APIError) { request(make_response(Net::HTTPInternalServerError, '500', '')) }

    assert_equal 500, error.status
    refute_nil error.message
  end

  def test_get_parses_the_json_body_and_sends_the_headers
    http = FakeHttp.new(make_response(Net::HTTPOK, '200', '{"ok":true}'))

    data = Net::HTTP.stub(:new, http) { transport.get('/x') }

    assert_equal({ 'ok' => true }, data)
    assert_equal 'k', http.instance_variable_get(:@request)['x-key']
  end

  # --- provider switch --------------------------------------------------

  def test_openai_is_the_default_provider
    client = with_env('LLM_PROVIDER' => nil, 'OPENAI_API_KEY' => 'k') { Frijolero::LLM.client }

    assert_kind_of Frijolero::OpenAIClient, client
    assert_equal 'OPENAI_API_KEY', with_env('LLM_PROVIDER' => nil) { Frijolero::LLM.key_var }
  end

  def test_anthropic_reads_its_own_key
    with_env('LLM_PROVIDER' => 'anthropic', 'ANTHROPIC_API_KEY' => nil, 'OPENAI_API_KEY' => 'k') do
      assert_nil Frijolero::LLM.client
      assert_equal 'ANTHROPIC_API_KEY', Frijolero::LLM.key_var
    end
    client = with_env('LLM_PROVIDER' => 'anthropic', 'ANTHROPIC_API_KEY' => 'k') { Frijolero::LLM.client }

    assert_kind_of Frijolero::AnthropicClient, client
  end

  def test_unknown_provider_raises
    error = with_env('LLM_PROVIDER' => 'gemini') { assert_raises(Frijolero::LLM::Error) { Frijolero::LLM.client } }

    assert_includes error.message, 'gemini'
  end

  # --- error policy -----------------------------------------------------

  def report(error)
    sink = StringIO.new
    Frijolero::Log.sink = sink
    Frijolero::LLM.report(error)
    sink.string
  ensure
    Frijolero::Log.sink = $stdout
  end

  def test_a_recoverable_error_is_logged_with_the_provider_name
    out = with_env('LLM_PROVIDER' => 'anthropic') { report(Frijolero::LLM::APIError.new('boom', status: 500)) }

    assert_includes out, 'Anthropic returned an error (HTTP 500): boom'
  end

  def test_a_bad_key_is_logged_and_raised
    error = Frijolero::LLM::AuthenticationError.new('nope')

    raised = with_env('LLM_PROVIDER' => nil) { assert_raises(Frijolero::LLM::AuthenticationError) { report(error) } }

    assert_same error, raised
  end
end
