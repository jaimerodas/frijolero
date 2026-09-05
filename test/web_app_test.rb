# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'rack/builder'
require 'fileutils'

class WebAppTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  CONFIG_RU = File.expand_path('../config.ru', __dir__)

  def setup
    @previous_app_password = ENV.fetch('APP_PASSWORD', nil)
    @previous_rack_env = ENV.fetch('RACK_ENV', nil)
    ENV['APP_PASSWORD'] = 'secret'
    # Sinatra's default host_authorization only allows localhost/IPs in
    # development; production (what Puma sets at boot) allows any host,
    # since kamal-proxy is the one that controls what Host header arrives.
    # Rack::Test's default Host header ("example.org") needs that here too.
    ENV['RACK_ENV'] = 'test'

    # Sinatra fixes its `environment` setting (and with it, host authorization)
    # the first time sinatra/base loads, from RACK_ENV at that moment — so this
    # require must happen after the line above, not at the top of the file.
    require 'frijolero/web/app'

    @dir = Dir.mktmpdir
    @previous_ledger_dir = ENV.fetch('LEDGER_DIR', nil)
    ENV['LEDGER_DIR'] = @dir
    FileUtils.mkdir_p(File.join(@dir, 'config'))
    Frijolero::Config.reload!

    # config.ru calls App.jobs at load time; set it first so the ||= keeps this
    # instance (no start, so no worker thread spins up under the tests).
    Frijolero::Web::App.jobs = Frijolero::Web::Jobs.new(log_path: File.join(@dir, 'jobs.jsonl'))
  end

  def teardown
    restore_env('APP_PASSWORD', @previous_app_password)
    restore_env('RACK_ENV', @previous_rack_env)
    restore_env('LEDGER_DIR', @previous_ledger_dir)
    Frijolero::Config.reload!
    Frijolero::Web::App.jobs = nil
    FileUtils.remove_entry(@dir)
  end

  def app
    @app ||= build_app(CONFIG_RU)
  end

  def test_up_without_credentials_is_ok
    get '/up'

    assert_equal 200, last_response.status
    assert_equal 'ok', last_response.body
  end

  def test_root_without_credentials_is_unauthorized
    get '/'

    assert_equal 401, last_response.status
    assert last_response.headers['WWW-Authenticate'].start_with?('Basic')
  end

  def test_root_with_wrong_password_is_unauthorized
    basic_authorize 'anyone', 'wrong'
    get '/'

    assert_equal 401, last_response.status
  end

  def test_root_with_right_password_is_ok
    basic_authorize 'anyone', 'secret'
    get '/'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Frijolero'
  end

  def test_static_file_without_credentials_is_unauthorized
    get '/style.css'

    assert_equal 401, last_response.status
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
