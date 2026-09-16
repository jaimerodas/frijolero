# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'openssl'
require 'digest'
require 'time'
require 'cgi'

module Frijolero
  # Any S3-compatible object store (Backblaze B2, AWS, Cloudflare R2, Hetzner,
  # DigitalOcean Spaces, MinIO), signed with SigV4 by hand. No aws-sdk: the
  # signature is sixty lines and the droplet has 1 GB of RAM.
  #
  # Virtual-hosted URLs (bucket.endpoint/key) by default, which every provider
  # accepts; path-style (endpoint/bucket/key) is for MinIO on localhost and any
  # bucket with a dot in its name, which breaks the TLS wildcard.
  class S3
    class Error < StandardError
      attr_reader :status

      def initialize(message, status: nil)
        super(message)
        @status = status
      end
    end

    ENV_KEYS = %w[S3_ENDPOINT S3_BUCKET S3_KEY_ID S3_KEY].freeze

    ALGORITHM = 'AWS4-HMAC-SHA256'
    SERVICE = 's3'
    UNSIGNED_PAYLOAD = 'UNSIGNED-PAYLOAD'
    # RFC 3986 unreserved characters stay literal; everything else is percent-encoded.
    RESERVED = /[^A-Za-z0-9\-_.~]/

    # Regex parsing of the ListBucketResult XML: there is no XML gem in the bundle.
    # A nested collaborator, same as Transport, keeps this off S3 itself.
    class ListParser
      CONTENTS = %r{<Contents>(.*?)</Contents>}m

      def self.parse(body)
        body.scan(CONTENTS).flatten.map { |xml| entry(xml) }
      end

      def self.entry(xml)
        { key: CGI.unescapeHTML(xml[%r{<Key>(.*?)</Key>}m, 1]), size: xml[/<Size>(\d+)</, 1].to_i,
          last_modified: Time.iso8601(xml[%r{<LastModified>(.*?)</LastModified>}, 1]) }
      end
    end

    class Transport
      def initialize(read_timeout: 120)
        @read_timeout = read_timeout
      end

      def put(uri, body, headers)
        request = Net::HTTP::Put.new(uri, headers)
        request.body = body
        request_and_raise(request, uri, 'PUT')
      end

      def get(uri, headers)
        request_and_raise(Net::HTTP::Get.new(uri, headers), uri, 'GET').body
      end

      private

      def request_and_raise(request, uri, verb)
        response = client(uri).request(request)
        return response if response.is_a?(Net::HTTPSuccess)

        raise Error.new("S3 #{verb} #{uri.path} failed (#{response.code}): #{response.body}",
                        status: response.code.to_i)
      end

      def client(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.read_timeout = @read_timeout
        http
      end
    end

    # transport and now are test seams; path_style is set by from_env. They are
    # writers rather than constructor keywords because six trips Metrics/ParameterLists.
    attr_writer :transport, :now, :path_style

    def initialize(endpoint:, bucket:, key_id:, key:, region: nil)
      @endpoint = endpoint
      @bucket = bucket
      @key_id = key_id
      @key = key
      # B2 and AWS name the region in the host (s3.us-west-000.backblazeb2.com);
      # R2 wants "auto", Hetzner its location, DigitalOcean and MinIO us-east-1.
      @region = region || endpoint.split('.')[1]
    end

    # Credentials never contain whitespace, but a password manager field can: a stray
    # space in S3_KEY once produced "Signature validation failed" and, for large
    # bodies, "IncompleteBody" from B2. Strip it here rather than debug it again.
    # S3_KEY_ID becomes key_id:, and so on. Names the missing variables when some are set.
    # S3_REGION and S3_PATH_STYLE are optional.
    def self.from_env
      missing = ENV_KEYS - ENV.keys
      raise Error, "S3 no está configurado: faltan #{missing.join(', ')}" unless missing.empty?

      new(**ENV_KEYS.to_h { |k| [k.delete_prefix('S3_').downcase.to_sym, ENV[k].gsub(/\s/, '')] },
          region: ENV.fetch('S3_REGION', nil)).tap { |s3| s3.path_style = ENV['S3_PATH_STYLE'] == '1' }
    end

    # PUT the local file at `path` under `key`, signed with header authentication.
    def put(key, path, content_type: 'application/pdf')
      body = File.binread(path)
      host, uri_path = host_and_path(key)
      headers = { 'content-type' => content_type, 'host' => host,
                  'x-amz-content-sha256' => hex(body), 'x-amz-date' => amz_date }
      headers['authorization'] = authorization('PUT', uri_path, '', headers)
      transport.put(URI("https://#{host}#{uri_path}"), body, headers)
    end

    # List objects whose key starts with `prefix`, header-signed.
    # ponytail: first page only (1000 keys); add ContinuationToken if an account ever passes that
    def list(prefix)
      host, bucket_path = bucket_host_and_path
      query = canonical_query('list-type' => '2', 'prefix' => prefix)
      headers = { 'host' => host, 'x-amz-content-sha256' => hex(''), 'x-amz-date' => amz_date }
      headers['authorization'] = authorization('GET', bucket_path, query, headers)
      ListParser.parse(transport.get(URI("https://#{host}#{bucket_path}?#{query}"), headers))
    end

    # A GET URL signed with query parameters, valid for `expires_in` seconds.
    def presigned_url(key, expires_in: 600)
      host, uri_path = host_and_path(key)
      date = amz_date
      query = canonical_query(presign_params(date, expires_in))
      request = canonical_request('GET', uri_path, query, { 'host' => host }, UNSIGNED_PAYLOAD)
      signature = signature(string_to_sign(date, request), date[0, 8])
      "https://#{host}#{uri_path}?#{query}&X-Amz-Signature=#{signature}"
    end

    private

    def transport
      @transport ||= Transport.new
    end

    def now
      @now ||= -> { Time.now.utc }
    end

    def amz_date
      now.call.strftime('%Y%m%dT%H%M%SZ')
    end

    def host = @path_style ? @endpoint : "#{@bucket}.#{@endpoint}"

    def host_and_path(key) = [host, "/#{encode_path(@path_style ? "#{@bucket}/#{key}" : key)}"]

    def bucket_host_and_path = [host, @path_style ? "/#{uri_encode(@bucket)}" : '/']

    def presign_params(date, expires_in)
      { 'X-Amz-Algorithm' => ALGORITHM,
        'X-Amz-Credential' => "#{@key_id}/#{scope(date)}",
        'X-Amz-Date' => date,
        'X-Amz-Expires' => expires_in.to_s,
        'X-Amz-SignedHeaders' => 'host' }
    end

    def authorization(method, uri_path, query, headers)
      date = headers['x-amz-date']
      request = canonical_request(method, uri_path, query, headers, headers['x-amz-content-sha256'])
      "#{ALGORITHM} Credential=#{@key_id}/#{scope(date)}, " \
        "SignedHeaders=#{signed_headers(headers)}, " \
        "Signature=#{signature(string_to_sign(date, request), date[0, 8])}"
    end

    def canonical_request(method, uri_path, query, headers, payload_hash)
      canonical_headers = headers.sort.map { |name, value| "#{name}:#{value.to_s.strip}\n" }.join
      [method, uri_path, query, canonical_headers, signed_headers(headers), payload_hash].join("\n")
    end

    def signed_headers(headers) = headers.keys.sort.join(';')

    def canonical_query(params)
      params.sort.map { |name, value| "#{uri_encode(name)}=#{uri_encode(value)}" }.join('&')
    end

    def string_to_sign(date, request)
      [ALGORITHM, date, scope(date), hex(request)].join("\n")
    end

    def scope(date) = "#{date[0, 8]}/#{@region}/#{SERVICE}/aws4_request"

    def signature(string_to_sign, date)
      key = ["AWS4#{@key}", date, @region, SERVICE, 'aws4_request'].inject do |acc, part|
        hmac(acc, part)
      end
      hmac(key, string_to_sign).unpack1('H*')
    end

    def hmac(key, data)
      OpenSSL::HMAC.digest('sha256', key, data)
    end

    def hex(data) = Digest::SHA256.hexdigest(data)

    def encode_path(path)
      path.split('/', -1).map { |segment| uri_encode(segment) }.join('/')
    end

    def uri_encode(string)
      string.to_s.b.gsub(RESERVED) { |char| "%#{char.unpack1('H*').upcase}" }
    end
  end
end
