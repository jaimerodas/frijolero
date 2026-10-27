# frozen_string_literal: true

require 'test_helper'
require 'fake_passkey'
require 'rack/test'
require 'rack/builder'
require 'stringio'

# Passkeys through config.ru, as production serves them: the login page, and /passkeys of
# the admin (admin@example.com), who owns the ledger 'test'.
class PasskeysPageTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  CONFIG_RU = File.expand_path('../../config.ru', __dir__)
  ENV_VARS = { 'SESSION_SECRET' => 's' * 64, 'APP_URL' => FakePasskey::ORIGIN }.freeze

  def setup
    @previous_env = ENV.to_h.slice(*ENV_VARS.keys)
    ENV.merge!(ENV_VARS)
    dir = enter_db_ledger
    Frijolero::Ledger.current = nil
    @admin = Frijolero::Users.find_by_email('admin@example.com')
    @passkey = FakePasskey.new
    Frijolero::Log.sink = @log = StringIO.new

    # config.ru calls App.jobs and App.inbox_worker for each ledger at load time.
    Frijolero::App.jobs = Frijolero::Jobs.new(log_path: File.join(dir, 'jobs.jsonl'))
    Frijolero::App.inbox = Frijolero::Inbox.new(File.join(dir, 'incoming'))
    Frijolero::App.inbox_worker = Frijolero::Inbox::Worker.new(Frijolero::App.inbox) { {} }
    @app = Rack::Builder.parse_file(CONFIG_RU)
  end

  def teardown
    ENV_VARS.each_key { |key| ENV.delete(key) }
    ENV.merge!(@previous_env)
    leave_test_ledger
    Frijolero::App.jobs = nil
    Frijolero::App.inbox = nil
    Frijolero::App.inbox_worker = nil
    Frijolero::Log.sink = nil
  end

  attr_reader :app

  # The challenge of the options that public/passkeys.js fetches.
  def challenge(path)
    post path

    assert_equal 'application/json', last_response.media_type
    JSON.parse(last_response.body)['challenge']
  end

  def sign_in_by_link = post("/login/#{Frijolero::Signin.issue(@admin, ttl: 60)}")

  def create_passkey
    sign_in_by_link
    post '/passkeys', credential: @passkey.create(challenge('/passkeys/challenge'))
  end

  def sign_in_with_passkey(passkey = @passkey)
    post '/login/passkey', credential: passkey.get(challenge('/login/challenge'))
  end

  def ids(user) = Frijolero::Passkeys.for_user(user.id).map { |row| row['id'] }

  def assert_signed_out
    get '/'

    assert_equal '/login', URI(last_response.location).path
  end

  def test_the_email_field_offers_the_passkeys
    get '/login'

    assert_includes last_response.body, 'autocomplete="email webauthn"'
  end

  def test_a_person_creates_a_passkey
    create_passkey

    assert_equal 303, last_response.status
    follow_redirect!

    assert_includes last_response.body, 'Listo'
    assert_equal [@passkey.id], ids(@admin)
  end

  def test_a_passkey_signs_in
    create_passkey
    post '/logout'

    sign_in_with_passkey

    assert_equal '/', URI(last_response.location).path
    get '/'

    assert_equal '/l/test/', URI(last_response.location).path
  end

  def test_a_failed_passkey_shows_the_login_page_and_logs_why
    sign_in_with_passkey(FakePasskey.new)

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Esa llave de acceso no sirvió'
    assert_includes @log.string, 'llave desconocida'
    assert_signed_out
  end

  # The session drops the challenge at the first answer, so a copy of an answer opens nothing.
  def test_a_challenge_takes_one_answer
    create_passkey
    post '/logout'
    pending = challenge('/login/challenge')

    post '/login/passkey', credential: FakePasskey.new.get(pending)
    post '/login/passkey', credential: @passkey.get(pending)

    assert_includes last_response.body, 'Esa llave de acceso no sirvió'
    assert_signed_out
  end

  # A cancelled prompt posts null.
  def test_a_failed_registration_says_so
    sign_in_by_link
    challenge('/passkeys/challenge')

    post '/passkeys', credential: 'null'
    follow_redirect!

    assert_includes last_response.body, 'No se creó la llave de acceso'
    assert_empty ids(@admin)
  end

  def test_the_page_lists_and_deletes_the_passkeys_of_the_user
    create_passkey
    get '/passkeys'

    assert_includes last_response.body, %(value="#{@passkey.id}")

    post '/passkeys/delete', id: @passkey.id

    assert_empty ids(@admin)
  end

  def test_a_person_cannot_delete_the_passkey_of_another
    beto = Frijolero::Users.invite(email: 'beto@example.com')
    pending = Frijolero::Passkeys.challenge
    Frijolero::Passkeys.register(beto, @passkey.create(pending.first), pending)
    sign_in_by_link

    post '/passkeys/delete', id: @passkey.id

    assert_equal [@passkey.id], ids(beto)
  end
end
