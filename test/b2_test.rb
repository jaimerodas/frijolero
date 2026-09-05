# frozen_string_literal: true

require 'test_helper'
require 'net/http'
require 'tempfile'

class B2Test < Minitest::Test
  # The AWS SigV4 examples use virtual-host URLs
  # (https://examplebucket.s3.amazonaws.com/test.txt), so the canonical URI is the
  # key alone. Swapping the one private method that decides the URL style is the
  # smallest honest way to replay them.
  class VirtualHostB2 < Frijolero::B2
    private

    def host_and_path(key)
      ["examplebucket.#{@endpoint}", "/#{encode_path(key)}"]
    end
  end

  # Same shape as the FakeHttp in openai_client_test.rb.
  class FakeHttp
    attr_accessor :use_ssl, :read_timeout

    def initialize(response)
      @response = response
    end

    def request(_req)
      @response
    end
  end

  class FakeTransport
    attr_reader :uri, :body, :headers

    def put(uri, body, headers)
      @uri = uri
      @body = body
      @headers = headers
      :ok
    end
  end

  AWS_KEY_ID = 'AKIAIOSFODNN7EXAMPLE'
  AWS_SECRET = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
  EMPTY_SHA256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

  def aws_docs_client
    client = VirtualHostB2.new(endpoint: 's3.amazonaws.com', bucket: 'examplebucket',
                               key_id: AWS_KEY_ID, key: AWS_SECRET, region: 'us-east-1')
    client.now = -> { Time.utc(2013, 5, 24) }
    client
  end

  def b2(now: Time.utc(2026, 9, 5, 14, 30, 5))
    client = Frijolero::B2.new(endpoint: 's3.us-west-004.backblazeb2.com', bucket: 'my-bucket',
                               key_id: 'KEYID', key: 'SECRET')
    client.now = -> { now }
    client
  end

  # Vector: "Authenticating Requests: Using Query Parameters", example 1.
  def test_presigned_url_matches_aws_query_parameter_vector
    url = aws_docs_client.presigned_url('test.txt', expires_in: 86_400)

    assert_equal 'https://examplebucket.s3.amazonaws.com/test.txt?' \
                 'X-Amz-Algorithm=AWS4-HMAC-SHA256&' \
                 'X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&' \
                 'X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&' \
                 'X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404',
                 url
  end

  # Vector: "Signature Calculations for the Authorization Header", GET Object example.
  def test_header_signature_matches_aws_get_object_vector
    client = aws_docs_client
    headers = { 'host' => 'examplebucket.s3.amazonaws.com',
                'range' => 'bytes=0-9',
                'x-amz-content-sha256' => EMPTY_SHA256,
                'x-amz-date' => '20130524T000000Z' }
    request = client.send(:canonical_request, 'GET', '/test.txt', '', headers, EMPTY_SHA256)
    signature = client.send(:signature, client.send(:string_to_sign, '20130524T000000Z', request),
                            '20130524')

    assert_equal 'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41', signature
  end

  def test_space_in_key_is_encoded_as_percent_20
    url = b2.presigned_url('accounts/AMEX/AMEX 2508.pdf')

    assert_includes url, 'https://s3.us-west-004.backblazeb2.com/my-bucket/accounts/AMEX/AMEX%202508.pdf?'
    refute_includes url, '+'
  end

  # The signature in the URL must be the one a canonical request built with %20 produces:
  # if the path and the canonical URI ever disagreed, B2 would reject the download.
  def test_space_in_key_signature_is_derived_from_the_percent_20_canonical_uri
    client = b2
    url = client.presigned_url('accounts/AMEX/AMEX 2508.pdf')
    query, signature = url.split('?').last.split('&X-Amz-Signature=')
    request = client.send(:canonical_request, 'GET',
                          '/my-bucket/accounts/AMEX/AMEX%202508.pdf', query,
                          { 'host' => 's3.us-west-004.backblazeb2.com' }, 'UNSIGNED-PAYLOAD')
    expected = client.send(:signature,
                           client.send(:string_to_sign, '20260905T143005Z', request), '20260905')

    assert_equal expected, signature
  end

  def test_unreserved_characters_stay_literal_and_others_are_encoded
    client = b2

    assert_equal 'a-b_c.d~e', client.send(:uri_encode, 'a-b_c.d~e')
    assert_equal '%28x%29', client.send(:uri_encode, '(x)')
  end

  def test_put_signs_the_request_and_hands_it_to_the_transport
    client = b2(now: Time.utc(2026, 9, 5, 10, 0, 0))
    transport = FakeTransport.new
    client.transport = transport
    file = Tempfile.new(['statement', '.pdf'])
    file.binmode
    file.write("%PDF-1.4 fake\n")
    file.close

    client.put('accounts/AMEX/AMEX 2508.pdf', file.path)

    assert_equal 'https://s3.us-west-004.backblazeb2.com/my-bucket/accounts/AMEX/AMEX%202508.pdf',
                 transport.uri.to_s
    assert_equal Digest::SHA256.hexdigest(File.binread(file.path)),
                 transport.headers['x-amz-content-sha256']
    assert_equal 'application/pdf', transport.headers['content-type']
    assert_equal '20260905T100000Z', transport.headers['x-amz-date']
    prefix = 'AWS4-HMAC-SHA256 Credential=KEYID/20260905/us-west-004/s3/aws4_request, ' \
             'SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature='
    assert transport.headers['authorization'].start_with?(prefix),
           "unexpected authorization: #{transport.headers['authorization']}"
    assert_match(/\A[0-9a-f]{64}\z/, transport.headers['authorization'].split('Signature=').last)
  ensure
    file&.unlink
  end

  def test_region_is_derived_from_the_endpoint
    assert_includes b2.presigned_url('x.pdf'), '%2Fus-west-004%2Fs3%2F'
  end

  def test_explicit_region_overrides_the_endpoint
    client = Frijolero::B2.new(endpoint: 's3.us-west-004.backblazeb2.com', bucket: 'my-bucket',
                               key_id: 'KEYID', key: 'SECRET', region: 'eu-central-003')

    assert_includes client.presigned_url('x.pdf'), '%2Feu-central-003%2Fs3%2F'
  end

  def test_presigned_url_expires_in_ten_minutes_by_default
    assert_includes b2.presigned_url('x.pdf'), 'X-Amz-Expires=600&'
  end

  def test_transport_raises_error_with_status_on_failure
    response = make_response(Net::HTTPForbidden, '403', '<Error>SignatureDoesNotMatch</Error>')

    error = Net::HTTP.stub(:new, FakeHttp.new(response)) do
      assert_raises(Frijolero::B2::Error) do
        Frijolero::B2::Transport.new.put(URI('https://example.com/b/k.pdf'), 'body', {})
      end
    end

    assert_equal 403, error.status
    assert_includes error.message, 'SignatureDoesNotMatch'
  end

  def test_transport_returns_the_response_on_success
    response = make_response(Net::HTTPOK, '200', '')

    result = Net::HTTP.stub(:new, FakeHttp.new(response)) do
      Frijolero::B2::Transport.new.put(URI('https://example.com/b/k.pdf'), 'body', {})
    end

    assert_same response, result
  end

  private

  def make_response(klass, code, body)
    response = klass.new('1.1', code, '')
    response.instance_variable_set(:@body, body)
    def response.body
      @body
    end
    response
  end
end
