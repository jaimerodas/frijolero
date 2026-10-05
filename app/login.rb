# frozen_string_literal: true

require 'digest'
require 'json'
require 'sinatra/base'

module Frijolero
  # Middleware in config.ru, in front of App. Owns the three auth routes and
  # gates everything else behind a signed cookie session. The cookie secret is
  # derived from APP_PASSWORD, so changing the password logs every device out.
  # httponly is the rack-session default. secure: production? because bin/dev
  # is plain http.
  #
  # /api/ is for the iOS Shortcut, which has no cookie: it sends API_TOKEN as a
  # bearer token instead. Without API_TOKEN, /api/ is closed.
  class Login < Sinatra::Base
    set :views, App.views
    set :public_folder, App.public_folder # style.css before the filter
    set :password, -> { ENV.fetch('APP_PASSWORD') }
    set :api_token, -> { ENV.fetch('API_TOKEN', '') }
    set :session_secret, -> { Digest::SHA512.hexdigest(password) }
    set :sessions, expire_after: 30 * 24 * 3600, same_site: :lax, secure: production?
    set :protection, except: :session_hijacking # a browser update must not log out

    before do
      if request.path_info.start_with?('/api/')
        halt 401, { 'content-type' => 'application/json' }, JSON.generate(error: 'Token inválido') unless api_token?
      else
        redirect '/login' unless session[:in] || request.path_info == '/login'
      end
    end

    helpers do
      def api_token?
        token = request.get_header('HTTP_AUTHORIZATION').to_s.delete_prefix('Bearer ')
        !settings.api_token.empty? && Rack::Utils.secure_compare(token, settings.api_token)
      end
    end

    get('/login') { erb :login, locals: { error: false } }

    post '/login' do
      if Rack::Utils.secure_compare(params['password'].to_s, settings.password)
        session[:in] = true
        redirect '/'
      else
        sleep 1 unless settings.test? # one guess per second per thread
        status 401
        erb :login, locals: { error: true }
      end
    end

    post '/logout' do
      session.clear
      redirect '/login'
    end
  end
end
