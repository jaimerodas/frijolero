# frozen_string_literal: true

require 'test_helper'
require 'fake_passkey'

# Ana has one passkey. Each test breaks one part of an answer and expects a refusal.
class PasskeysTest < Minitest::Test
  include TestHelpers

  T = Time.utc(2026, 10, 27, 12, 0, 0)

  def setup
    enter_test_ledger # a fresh DATA_DIR, so a fresh database
    @app_url = ENV.fetch('APP_URL', nil)
    ENV['APP_URL'] = FakePasskey::ORIGIN
    @ana = add_user('ana@example.com')
    @passkey = FakePasskey.new
    register(@ana, @passkey)
  end

  def teardown
    @app_url ? ENV['APP_URL'] = @app_url : ENV.delete('APP_URL')
    leave_test_ledger
  end

  def add_user(email)
    Frijolero::Users.find(Frijolero::DB.insert("INSERT INTO users (email, status, created_at) VALUES (?, 'active', ?)",
                                               email, T.iso8601))
  end

  def register(user, passkey, **)
    pending = Frijolero::Passkeys.challenge(T)
    Frijolero::Passkeys.register(user, passkey.create(pending.first, **), pending, now: T)
  end

  def sign_in(passkey = @passkey, pending: Frijolero::Passkeys.challenge(T), now: T + 60, **)
    Frijolero::Passkeys.authenticate(passkey.get(pending.first, **), pending, now: now)
  end

  def assert_refused(&) = assert_raises(Frijolero::Passkeys::Error, &)

  def test_a_passkey_signs_in_its_user
    assert_equal @ana, sign_in
  end

  def test_a_sign_in_records_the_last_use
    sign_in

    assert_equal (T + 60).iso8601, Frijolero::Passkeys.for_user(@ana.id).first['last_used_at']
  end

  def test_another_origin_is_refused
    assert_refused { sign_in(origin: 'https://frijolero.test.evil.test') }
  end

  def test_an_answer_to_create_does_not_sign_in
    assert_refused { sign_in(type: 'webauthn.create') }
  end

  def test_another_challenge_is_refused
    answer = @passkey.get(Frijolero::Passkeys.challenge(T).first)

    assert_refused { Frijolero::Passkeys.authenticate(answer, Frijolero::Passkeys.challenge(T), now: T) }
  end

  # The session has no challenge: the answer was sent once already. An answer with no
  # challenge either must not match.
  def test_no_challenge_is_refused
    assert_refused { Frijolero::Passkeys.authenticate(@passkey.get(nil), nil, now: T) }
  end

  def test_an_old_challenge_is_refused
    assert_refused { sign_in(now: T + Frijolero::Passkeys::CHALLENGE_TTL + 1) }
  end

  def test_a_passkey_of_another_site_is_refused
    assert_refused { sign_in(rp_id: 'evil.test') }
  end

  # The passkey replaces the email, so it needs Face ID, Touch ID or a PIN, not a tap.
  def test_a_sign_in_without_user_verification_is_refused
    assert_refused { sign_in(flags: 0x01) }
  end

  def test_an_unknown_passkey_is_refused
    assert_refused { sign_in(FakePasskey.new) }
  end

  def test_a_signature_of_another_key_is_refused
    assert_refused { sign_in(key: OpenSSL::PKey::EC.generate('prime256v1')) }
  end

  def test_a_blocked_user_is_refused
    Frijolero::Users.block(@ana.id)

    assert_refused { sign_in }
  end

  # A cancelled prompt in public/passkeys.js posts null.
  def test_an_answer_that_is_not_a_credential_is_refused
    ['nope', 'null', '[]', '{}', '{"id": 1}'].each do |answer|
      assert_refused { Frijolero::Passkeys.authenticate(answer, Frijolero::Passkeys.challenge(T), now: T) }
    end
  end

  def test_a_registration_from_another_origin_is_refused
    assert_refused { register(@ana, FakePasskey.new, origin: 'https://evil.test') }
  end

  def test_an_answer_to_get_does_not_register
    assert_refused { register(@ana, FakePasskey.new, type: 'webauthn.get') }
  end

  def test_a_registration_without_user_verification_is_refused
    assert_refused { register(@ana, FakePasskey.new, flags: 0x01) }
  end

  def test_a_public_key_that_is_not_a_key_is_refused
    assert_refused { register(@ana, FakePasskey.new, public_key: 'nope') }
  end

  def test_a_credential_id_that_is_not_base64url_is_refused
    assert_refused { register(@ana, FakePasskey.new, id: '../nope') }
  end

  # The credential id is the primary key: a second user cannot take over a passkey.
  def test_the_credential_id_of_another_user_is_refused
    beto = add_user('beto@example.com')

    assert_refused { register(beto, @passkey) }
    assert_equal @ana, sign_in
  end

  def test_the_options_name_the_host_of_app_url
    assert_equal 'frijolero.test', Frijolero::Passkeys.request_options('c')[:rpId]
    assert_equal 'frijolero.test', Frijolero::Passkeys.creation_options(@ana, 'c')[:rp][:id]
  end

  # So one device does not make a second passkey for the same person.
  def test_the_creation_options_exclude_the_passkeys_of_the_user
    excluded = Frijolero::Passkeys.creation_options(@ana, 'c')[:excludeCredentials]

    assert_equal([@passkey.id], excluded.map { |credential| credential[:id] })
  end

  def test_a_user_deletes_only_their_own_passkeys
    beto = add_user('beto@example.com')

    Frijolero::Passkeys.delete(beto.id, @passkey.id)

    assert_equal @ana, sign_in

    Frijolero::Passkeys.delete(@ana.id, @passkey.id)

    assert_refused { sign_in }
  end
end
