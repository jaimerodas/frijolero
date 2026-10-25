# frozen_string_literal: true

require 'test_helper'
require 'net/http'
require 'stringio'

class PostmarkTest < Minitest::Test
  include TestHelpers

  # Stands in for the Net::HTTP connection, and keeps the request.
  class FakeHttp
    attr_accessor :use_ssl, :read_timeout, :cert_store
    attr_reader :host, :sent

    def initialize(result)
      @result = result
    end

    def open(host)
      @host = host
      self
    end

    def request(req)
      @sent = req
      raise @result if @result.is_a?(Exception)

      @result
    end
  end

  ENV_VARS = { 'POSTMARK_API_TOKEN' => 'pm-token', 'MAIL_FROM' => 'Frijolero <frijolero@example.com>' }.freeze

  def response(klass, code, body)
    resp = klass.new('1.1', code, '')
    resp.instance_variable_set(:@body, body)
    def resp.body = @body
    resp
  end

  def deliver(http)
    with_env(ENV_VARS) do
      Net::HTTP.stub(:new, ->(host, _port) { http.open(host) }) do
        Frijolero::Postmark.deliver(to: 'ana@example.com', subject: 'Hola', text: 'Un enlace')
      end
    end
  end

  def test_deliver_posts_one_email_to_postmark
    http = FakeHttp.new(response(Net::HTTPOK, '200', '{"ErrorCode":0,"Message":"OK"}'))

    deliver(http)

    assert_equal 'api.postmarkapp.com', http.host
    assert http.use_ssl
    request = http.sent
    assert_equal 'POST', request.method
    assert_equal '/email', request.path
    assert_equal 'pm-token', request['X-Postmark-Server-Token']
    assert_equal 'application/json', request['Accept']
    assert_equal 'application/json', request['Content-Type']
    assert_equal({ 'From' => 'Frijolero <frijolero@example.com>', 'To' => 'ana@example.com', 'Subject' => 'Hola',
                   'TextBody' => 'Un enlace', 'MessageStream' => 'outbound' }, JSON.parse(request.body))
  end

  def test_a_rejected_email_raises_with_the_message_of_postmark
    body = %({"ErrorCode":300,"Message":"Invalid 'To' address: 'ana'."})
    http = FakeHttp.new(response(Net::HTTPUnprocessableEntity, '422', body))

    error = assert_raises(Frijolero::Postmark::Error) { deliver(http) }

    assert_includes error.message, "Invalid 'To' address"
  end

  # Login rescues only Postmark::Error, so a network failure must become one.
  def test_a_network_failure_raises_a_postmark_error
    assert_raises(Frijolero::Postmark::Error) { deliver(FakeHttp.new(SocketError.new('getaddrinfo failed'))) }
  end

  def test_without_a_token_the_message_goes_to_the_log
    log = StringIO.new
    Frijolero::Log.sink = log

    with_env('POSTMARK_API_TOKEN' => nil) do
      Net::HTTP.stub(:new, ->(*) { flunk 'no request without a token' }) do
        Frijolero::Postmark.deliver(to: 'ana@example.com', subject: 'Hola', text: 'https://x.test/login/abc')
      end
    end

    assert_includes log.string, 'ana@example.com'
    assert_includes log.string, 'https://x.test/login/abc'
  ensure
    Frijolero::Log.sink = nil
  end
end
