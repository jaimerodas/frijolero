# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'rack/builder'

class WebAppTest < Minitest::Test
  include Rack::Test::Methods

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
  end

  def teardown
    restore_env('APP_PASSWORD', @previous_app_password)
    restore_env('RACK_ENV', @previous_rack_env)
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
