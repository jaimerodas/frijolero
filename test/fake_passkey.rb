# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'openssl'
require 'securerandom'

# An authenticator in a test: an ES256 key and its credential id. It answers a challenge
# as public/passkeys.js does, with the JSON of the credential field: create on the
# passkeys page, get on the login page. Each keyword breaks one part of the answer, so a
# test can fail one check at a time. The site is APP_URL https://frijolero.test.
class FakePasskey
  ORIGIN = 'https://frijolero.test'
  RP_ID = 'frijolero.test'
  # User present and user verified.
  FLAGS = 0x05

  attr_reader :id

  def initialize
    @key = OpenSSL::PKey::EC.generate('prime256v1')
    @id = SecureRandom.urlsafe_base64(16)
  end

  def create(challenge, type: 'webauthn.create', public_key: @key.public_to_der, id: @id, **)
    client = client_data(challenge, type, **)
    JSON.generate(id: id, clientDataJSON: b64(client), authenticatorData: b64(authenticator_data(**)),
                  publicKey: b64(public_key))
  end

  def get(challenge, type: 'webauthn.get', key: @key, id: @id, **)
    client = client_data(challenge, type, **)
    data = authenticator_data(**)
    JSON.generate(id: id, clientDataJSON: b64(client), authenticatorData: b64(data),
                  signature: b64(key.sign('SHA256', data + Digest::SHA256.digest(client))))
  end

  private

  def client_data(challenge, type, origin: ORIGIN, **) = JSON.generate(type: type, challenge: challenge, origin: origin)

  # The hash of the RP ID, the flags and a sign count of 0, as a synced passkey sends.
  def authenticator_data(rp_id: RP_ID, flags: FLAGS, **) = Digest::SHA256.digest(rp_id) + [flags, 0].pack('CN')

  def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)
end
