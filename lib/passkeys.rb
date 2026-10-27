# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'openssl'
require 'securerandom'
require 'time'
require 'uri'

module Frijolero
  # Passkeys (WebAuthn): sign-in with Face ID, Touch ID or a PIN, and no email. The site
  # is the host of APP_URL and the origin is APP_URL, never the request's Host header.
  #
  # The server asks for no attestation, so it parses no CBOR: the browser gives the public
  # key as SubjectPublicKeyInfo DER (getPublicKey), and OpenSSL reads that. A sign-in
  # checks the challenge, the origin, the site, the flags and the signature. It skips the
  # sign count, because a synced passkey (iCloud, Google, 1Password) always sends 0.
  #
  # An answer is the JSON that public/passkeys.js puts in the form: id, clientDataJSON,
  # authenticatorData, and publicKey (create) or signature (get), each in base64url. A
  # challenge is [base64url, unix time], and the session keeps it until its answer.
  module Passkeys
    CHALLENGE_TTL = 5 * 60
    # ES256 and RS256. Every authenticator has one of them, and OpenSSL checks both with SHA-256.
    ALGORITHMS = [-7, -257].freeze
    # User present and user verified: the passkey replaces the email, so a tap is not enough.
    FLAGS = 0x05
    # A credential id is at most 1023 bytes.
    ID = /\A[A-Za-z0-9_-]{1,1364}\z/

    class Error < StandardError; end

    class << self
      def challenge(now = Time.now) = [SecureRandom.urlsafe_base64(32), now.to_i]

      # For navigator.credentials.get on the login page. With no allowCredentials, the
      # browser offers every passkey that it has for the site.
      def request_options(challenge) = { challenge: challenge, rpId: rp_id, userVerification: 'required' }

      # For navigator.credentials.create on the passkeys page. The user handle is the id
      # of the user, so the authenticator keeps no email in it.
      def creation_options(user, challenge)
        {
          challenge: challenge,
          rp: { id: rp_id, name: 'Frijolero' },
          user: { id: b64(user.id.to_s), name: user.email, displayName: user.name || user.email },
          pubKeyCredParams: ALGORITHMS.map { |alg| { type: 'public-key', alg: alg } },
          authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
          excludeCredentials: for_user(user.id).map { |row| { type: 'public-key', id: row['id'] } }
        }
      end

      # Adds the passkey of an answer to create, or raises Error. The id is the primary
      # key, so nobody can register a passkey that another user has.
      def register(user, json, pending, now: Time.now)
        credential = answer(json)
        check_client(credential, 'webauthn.create', pending, now)
        check_authenticator(credential)
        # A password, so OpenSSL never asks for one on the terminal of bin/dev.
        key = OpenSSL::PKey.read(bytes(credential['publicKey']), '')
        DB.first('INSERT INTO passkeys (id, user_id, public_key, created_at) VALUES (?, ?, ?, ?) ' \
                 'ON CONFLICT DO NOTHING RETURNING id', credential['id'], user.id, key.public_to_der, iso(now)) ||
          raise(Error, 'esa llave ya está registrada')
      rescue OpenSSL::PKey::PKeyError => e
        raise Error, e.message
      end

      # The active user of an answer to get, or raises Error.
      def authenticate(json, pending, now: Time.now)
        credential = answer(json)
        client = check_client(credential, 'webauthn.get', pending, now)
        row = signed_by(credential, client, check_authenticator(credential))
        user = Users.find(row['user_id'])
        raise Error, 'usuario inactivo' unless user&.status == 'active'

        DB.execute('UPDATE passkeys SET last_used_at = ? WHERE id = ?', iso(now), credential['id'])
        user
      rescue OpenSSL::PKey::PKeyError => e
        raise Error, e.message
      end

      # id, created_at and last_used_at of each passkey of the user, oldest first.
      def for_user(user_id)
        DB.execute('SELECT id, created_at, last_used_at FROM passkeys WHERE user_id = ? ORDER BY created_at', user_id)
      end

      # The user in the WHERE, so a person cannot delete the passkey of another.
      def delete(user_id, id) = DB.execute('DELETE FROM passkeys WHERE user_id = ? AND id = ?', user_id, id)

      private

      def rp_id = URI(ENV.fetch('APP_URL')).host

      def origin = URI(ENV.fetch('APP_URL')).origin

      def answer(json)
        credential = object(json)
        raise Error, 'id inválido' unless ID.match?(credential['id'].to_s)

        credential
      end

      # clientDataJSON as signed, after its checks: the type, the challenge of the session
      # before it expires, and APP_URL as the origin.
      def check_client(credential, type, pending, now)
        json = bytes(credential['clientDataJSON'])
        client = object(json)
        raise Error, 'otro reto' unless client['challenge'] == fresh(pending, now)
        raise Error, "tipo #{client['type'].inspect}" unless client['type'] == type
        raise Error, "origen #{client['origin'].inspect}" unless client['origin'] == origin

        json
      end

      # The challenge of the session, before it expires. A session with none raises, so an
      # answer with no challenge never matches it.
      def fresh(pending, now)
        challenge, issued = pending
        return challenge if issued.to_i > now.to_i - CHALLENGE_TTL

        raise Error, 'sin reto o vencido'
      end

      # The row of the passkey whose key signed authenticatorData and the hash of clientDataJSON.
      def signed_by(credential, client, data)
        row = DB.first('SELECT user_id, public_key FROM passkeys WHERE id = ?', credential['id']) ||
              raise(Error, 'llave desconocida')
        signed = data + Digest::SHA256.digest(client)
        return row if OpenSSL::PKey.read(row['public_key']).verify('SHA256', bytes(credential['signature']), signed)

        raise Error, 'firma inválida'
      end

      # authenticatorData, after its checks: the hash of the site, and the flags.
      def check_authenticator(credential)
        data = bytes(credential['authenticatorData'])
        raise Error, 'otro sitio' unless data.byteslice(0, 32) == Digest::SHA256.digest(rp_id)
        raise Error, 'sin verificación del usuario' unless data.getbyte(32).to_i.allbits?(FLAGS)

        data
      end

      def object(json)
        value = JSON.parse(json.to_s)
        value.is_a?(Hash) ? value : raise(Error, 'no es un objeto JSON')
      rescue JSON::ParserError => e
        raise Error, e.message
      end

      def bytes(text)
        Base64.urlsafe_decode64(text.to_s)
      rescue ArgumentError
        raise Error, 'no es base64url'
      end

      def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

      def iso(time) = time.getutc.iso8601
    end
  end
end
