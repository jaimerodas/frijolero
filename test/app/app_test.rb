# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'rack/builder'
require 'fileutils'

class AppTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  CONFIG_RU = File.expand_path('../../config.ru', __dir__)

  def setup
    @previous_app_password = ENV.fetch('APP_PASSWORD', nil)
    ENV['APP_PASSWORD'] = 'secret'
    @dir = Dir.mktmpdir
    @previous_ledger_dir = ENV.fetch('LEDGER_DIR', nil)
    ENV['LEDGER_DIR'] = @dir
    FileUtils.mkdir_p(File.join(@dir, 'config'))

    # config.ru calls App.jobs at load time; set it first so the ||= keeps this
    # instance (no start, so no worker thread spins up under the tests).
    Frijolero::App.jobs = Frijolero::Jobs.new(log_path: File.join(@dir, 'jobs.jsonl'))
  end

  def teardown
    restore_env('APP_PASSWORD', @previous_app_password)
    restore_env('LEDGER_DIR', @previous_ledger_dir)
    Frijolero::App.jobs = nil
    FileUtils.remove_entry(@dir)
  end

  def app
    @app ||= build_app(CONFIG_RU)
  end

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

  def test_login_page_shows_password_field
    get '/login'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'name="password"'
  end

  def test_style_without_session_is_ok
    get '/style.css'

    assert_equal 200, last_response.status
  end

  def test_login_with_wrong_password_is_unauthorized_and_stays_out
    post '/login', password: 'wrong'

    assert_equal 401, last_response.status
    assert_includes last_response.body, 'Contraseña incorrecta'

    get '/'

    assert_equal 302, last_response.status
  end

  def test_login_with_right_password_starts_session
    post '/login', password: 'secret'

    assert_equal 302, last_response.status
    assert_equal '/', URI(last_response.location).path

    get '/'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Frijolero'
  end

  def test_login_sets_cookie_flags
    post '/login', password: 'secret'

    cookie = last_response.headers['set-cookie'].to_s.downcase
    assert_includes cookie, 'httponly'
    assert_includes cookie, 'samesite=lax'
    assert_includes cookie, 'expires'
  end

  def test_logout_ends_session
    post '/login', password: 'secret'
    post '/logout'

    assert_equal 302, last_response.status
    assert_equal '/login', URI(last_response.location).path

    get '/'

    assert_equal 302, last_response.status
  end

  def test_loading_without_app_password_raises
    ENV.delete('APP_PASSWORD')

    assert_raises(KeyError) { build_app(CONFIG_RU) }
  end

  private

  # Rack::Builder.parse_file returns just the app on Rack 3, but historically
  # returned [app, options] — handle both.
  def build_app(path)
    result = Rack::Builder.parse_file(path)
    result.is_a?(Array) ? result.first : result
  end

  def restore_env(key, previous_value)
    if previous_value.nil?
      ENV.delete(key)
    else
      ENV[key] = previous_value
    end
  end
end
