# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'rack/builder'
require 'fileutils'
require 'stringio'

class AppTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  CONFIG_RU = File.expand_path('../../config.ru', __dir__)
  ENV_VARS = { 'SESSION_SECRET' => 's' * 64, 'APP_URL' => 'https://frijolero.test' }.freeze

  # Keeps each message instead of sending it.
  class FakeMailer
    attr_reader :sent

    def initialize
      @sent = []
    end

    def deliver(**message) = @sent << message
  end

  class FailingMailer
    def deliver(**) = raise(Frijolero::Postmark::Error, 'Postmark: inactive recipient')
  end

  def setup
    @previous_env = ENV.to_h.slice(*ENV_VARS.keys)
    ENV.merge!(ENV_VARS)
    @mailer = FakeMailer.new
    Frijolero::Signin.mailer = @mailer
    # A ledger in the database, as config.ru expects, but not current on this thread:
    # each request gets it from LedgerScope. Its owner is the admin, admin@example.com.
    @dir = enter_db_ledger
    Frijolero::Ledger.current = nil

    # config.ru calls App.jobs at load time; set it first so it keeps this instance
    # (no start, so no worker thread spins up under the tests).
    Frijolero::App.jobs = Frijolero::Jobs.new(log_path: File.join(@dir, 'jobs.jsonl'))
    Frijolero::App.inbox = Frijolero::Inbox.new(File.join(@dir, 'incoming'))
    Frijolero::App.inbox_worker = Frijolero::Inbox::Worker.new(Frijolero::App.inbox) { {} }
  end

  def teardown
    ENV_VARS.each_key { |key| ENV.delete(key) }
    ENV.merge!(@previous_env)
    Frijolero::Signin.mailer = nil
    leave_test_ledger
    Frijolero::App.jobs = nil
    Frijolero::App.inbox = nil
    Frijolero::App.inbox_worker = nil
  end

  def app
    @app ||= build_app(CONFIG_RU)
  end

  def admin = Frijolero::Users.find_by_email('admin@example.com')

  def link_token = Frijolero::Signin.issue(admin, ttl: 60)

  def sign_in = post("/login/#{link_token}")

  def test_up_without_session_is_ok
    get '/up'

    assert_equal 200, last_response.status
    assert_equal 'ok', last_response.body
  end

  def test_root_without_session_redirects_to_login
    get '/'

    assert_equal 302, last_response.status
    assert last_response.location.end_with?('/login')
  end

  def test_login_page_has_one_email_field
    get '/login'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'name="email"'
    refute_includes last_response.body, 'name="password"'
    assert_includes last_response.body, '<h1 class="wordmark">Frijolero</h1>'
  end

  # Login sits outside LedgerScope, so its pages run with no current ledger and read none.
  def test_login_pages_answer_with_no_current_ledger
    scope = ->(_env) { flunk 'a login page reached LedgerScope' }
    Frijolero::LedgerScope.stub(:new, ->(_app) { scope }) { app } # config.ru builds the stack once

    get '/login'
    assert_equal 200, last_response.status
    post '/login', email: 'admin@example.com'
    assert_equal 200, last_response.status
    get "/login/#{link_token}"
    assert_equal 200, last_response.status
    post '/login/nope'
    assert_equal 200, last_response.status
  end

  # LedgerScope lends the ledger to one request. Puma reuses its threads, so the next
  # request on this thread must not find the last one's ledger.
  def test_a_request_has_the_ledger_and_leaves_none_on_its_thread
    Frijolero::Ledger.update('test', name: 'Casa')
    sign_in

    get '/l/test/'

    assert_includes last_response.body, 'Casa', 'the page read the ledger'
    assert_raises(Frijolero::NoLedger) { Frijolero::Ledger.current }
  end

  def test_style_without_session_is_ok
    get '/style.css'

    assert_equal 200, last_response.status
  end

  # Login serves the static files, so its setting is the one that counts. Without it,
  # a browser keeps an old style.css after a deploy.
  def test_static_files_are_revalidated_on_each_request
    get '/style.css'

    assert_includes last_response.headers['cache-control'].to_s, 'no-cache'
  end

  def test_asking_for_a_link_mails_it
    post '/login', email: 'admin@example.com'

    assert_equal(['admin@example.com'], @mailer.sent.map { |message| message[:to] })
    assert_includes @mailer.sent.first[:text], 'https://frijolero.test/login/'
  end

  # The page must not tell which addresses have an account.
  def test_asking_for_a_link_answers_the_same_page_for_every_email
    post '/login', email: 'admin@example.com'
    known = last_response.body
    post '/login', email: 'nadie@example.com'

    assert_equal 200, last_response.status
    assert_equal known, last_response.body
    assert_includes known, 'te llega un correo con un enlace para entrar'
  end

  # bin/signin-link is the way in when mail fails; the page stays the same.
  def test_a_mail_failure_is_logged_and_shows_the_same_page
    post '/login', email: 'nadie@example.com'
    expected = last_response.body
    Frijolero::Signin.mailer = FailingMailer.new
    log = StringIO.new
    Frijolero::Log.sink = log

    post '/login', email: 'admin@example.com'

    assert_equal 200, last_response.status
    assert_equal expected, last_response.body
    assert_includes log.string, 'inactive recipient'
  ensure
    Frijolero::Log.sink = nil
  end

  # Mail scanners open the links in an email: the GET must leave the token unused.
  def test_a_link_page_has_one_button_and_keeps_the_token
    token = link_token

    get "/login/#{token}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, '<button type="submit" class="primary"'
    refute_includes last_response.body, 'name="email"'
    assert_equal 'no-referrer', last_response.headers['referrer-policy'], 'the token never leaves in a Referer'

    post "/login/#{token}"

    assert_equal 302, last_response.status
  end

  def test_a_link_signs_in
    sign_in

    assert_equal 302, last_response.status
    assert_equal '/', URI(last_response.location).path

    get '/'

    assert_equal '/l/test/', URI(last_response.location).path

    follow_redirect!

    assert_equal 200, last_response.status
  end

  def test_a_used_link_shows_the_expired_page
    token = link_token
    post "/login/#{token}"
    post '/logout'

    post "/login/#{token}"

    assert_includes last_response.body, 'Este enlace ya no sirve'

    get '/'

    assert_equal '/login', URI(last_response.location).path
  end

  def test_a_link_that_changes_the_email_signs_in_with_the_new_one
    token = Frijolero::Signin.issue(admin, ttl: 60, new_email: 'nuevo@example.com')

    post "/login/#{token}"

    assert_equal '/', URI(last_response.location).path
    assert_equal 1, Frijolero::Users.find_by_email('nuevo@example.com').id
  end

  # Another user took the email between the request and the click.
  def test_a_link_to_an_email_of_another_user_says_so_and_signs_in_nobody
    token = Frijolero::Signin.issue(admin, ttl: 60, new_email: 'beto@example.com')
    Frijolero::Users.invite(email: 'beto@example.com')

    post "/login/#{token}"

    assert_includes last_response.body, 'Ese correo ya es de otra cuenta'
    assert Frijolero::Users.find_by_email('admin@example.com')
    get '/'
    assert_equal '/login', URI(last_response.location).path
  end

  def test_an_unknown_link_shows_the_expired_page
    post '/login/nope'

    assert_includes last_response.body, 'Este enlace ya no sirve'
    assert_includes last_response.body, 'name="email"', 'the page offers a new link'
  end

  def test_sign_in_sets_cookie_flags
    sign_in

    cookie = last_response.headers['set-cookie'].to_s.downcase
    assert_includes cookie, 'httponly'
    assert_includes cookie, 'samesite=lax'
    assert_includes cookie, 'expires'
  end

  def test_logout_ends_session
    sign_in
    post '/logout'

    assert_equal 302, last_response.status
    assert_equal '/login', URI(last_response.location).path

    get '/'

    assert_equal '/login', URI(last_response.location).path
  end

  # The session is cleared too, so an unblock does not bring it back.
  def test_a_blocked_user_loses_the_session
    sign_in
    Frijolero::DB.execute("UPDATE users SET status = 'blocked' WHERE id = ?", admin.id)

    get '/'

    assert_equal 302, last_response.status
    assert last_response.location.end_with?('/login')

    Frijolero::DB.execute("UPDATE users SET status = 'active' WHERE id = ?", admin.id)
    get '/'

    assert_equal '/login', URI(last_response.location).path
  end

  # "Salir de todos lados" adds 1 to session_version.
  def test_a_new_session_version_signs_out
    sign_in
    Frijolero::DB.execute('UPDATE users SET session_version = 2 WHERE id = ?', admin.id)

    get '/'

    assert_equal 302, last_response.status
    assert last_response.location.end_with?('/login')
  end

  def test_the_app_gets_the_signed_in_user
    @app = Rack::Builder.new do
      use Frijolero::Login
      run ->(env) { [200, {}, [env['frijolero.user'].email]] }
    end.to_app

    sign_in
    get '/'

    assert_equal 'admin@example.com', last_response.body
  end

  # The iOS Shortcut has no cookie: a bearer token of api_tokens opens /api/, and only /api/.
  def test_api_with_a_token_reaches_the_app
    File.write(File.join(@dir, 'config', 'accounts.yaml'), "AMEX:\n  beancount_account: \"Liabilities:Amex\"\n")
    pdf = Rack::Test::UploadedFile.new(StringIO.new('%PDF'), 'application/pdf', original_filename: 'AMEX 2608.pdf')

    header 'Authorization', "Bearer #{Frijolero::ApiTokens.create('test', 'iPhone')}"
    post '/api/upload', pdf: pdf

    assert_equal 202, last_response.status
    assert_equal ['AMEX 2608.pdf'], Frijolero::App.inbox.items.map(&:filename)
  end

  # The token names the ledger: an upload goes to the ledger of its token.
  def test_api_runs_in_the_ledger_of_the_token
    other = Frijolero::Ledger.create(owner_id: admin.id, name: 'Otro')
    seen = []
    app_call = lambda do |env|
      seen << [env['PATH_INFO'], Frijolero::Ledger.current.id]
      [202, {}, []]
    end
    app # config.ru builds the stack once, before the stub

    header 'Authorization', "Bearer #{Frijolero::ApiTokens.create(other.id, 'iPad')}"
    Frijolero::App.stub(:call, app_call) { post '/api/upload' }

    assert_equal [['/api/upload', other.id]], seen
  end

  def test_api_without_a_token_is_a_json_401_not_a_redirect
    Frijolero::ApiTokens.create('test', 'iPhone')

    post '/api/upload'

    assert_api_unauthorized
  end

  def test_api_with_an_unknown_token_is_unauthorized
    Frijolero::ApiTokens.create('test', 'iPhone')

    header 'Authorization', 'Bearer nope'
    post '/api/upload'

    assert_api_unauthorized
  end

  def test_api_with_a_revoked_token_is_unauthorized
    raw = Frijolero::ApiTokens.create('test', 'iPhone')
    Frijolero::ApiTokens.revoke('test', Frijolero::ApiTokens.for_ledger('test').first['token_sha256'])

    header 'Authorization', "Bearer #{raw}"
    post '/api/upload'

    assert_api_unauthorized
  end

  # Before api_tokens, API_TOKEN opened /api/. Migration reads it once; Login never does.
  def test_api_token_in_env_opens_nothing
    with_env('API_TOKEN' => 'tok') do
      header 'Authorization', 'Bearer tok'
      post '/api/upload'
    end

    assert_api_unauthorized
  end

  def test_the_token_opens_nothing_outside_api
    header 'Authorization', "Bearer #{Frijolero::ApiTokens.create('test', 'iPhone')}"
    get '/'

    assert_equal 302, last_response.status
    assert last_response.location.end_with?('/login')
  end

  def test_loading_without_session_secret_raises
    ENV.delete('SESSION_SECRET')

    error = assert_raises(KeyError) { build_app(CONFIG_RU) }
    assert_includes error.message, '64'
  end

  private

  def assert_api_unauthorized
    assert_equal 401, last_response.status
    assert_equal({ 'error' => 'Token inválido' }, JSON.parse(last_response.body))
  end

  # Rack::Builder.parse_file returns just the app on Rack 3, but historically
  # returned [app, options] — handle both.
  def build_app(path)
    result = Rack::Builder.parse_file(path)
    result.is_a?(Array) ? result.first : result
  end
end
