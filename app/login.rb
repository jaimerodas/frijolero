# frozen_string_literal: true

require 'json'
require 'sinatra/base'

module Frijolero
  # Middleware in config.ru, outside OnlyLedger, so its pages have no current ledger.
  # Owns the sign-in routes and gates everything else behind a signed cookie session
  # that holds user_id and session_version. httponly is the rack-session default.
  # secure: production? because bin/dev is plain http. The App finds the user in
  # env['frijolero.user'].
  #
  # /api/ is for the iOS Shortcut, which has no cookie: it sends API_TOKEN as a
  # bearer token instead. Without API_TOKEN, /api/ is closed.
  class Login < Sinatra::Base
    set :views, App.views
    set :public_folder, App.public_folder # style.css before the filter
    set :static_cache_control, [:no_cache] # a deploy changes the files under the same names
    set :api_token, -> { ENV.fetch('API_TOKEN', '') }
    NO_SECRET = 'SESSION_SECRET is not set: it signs the session cookie, and rack-session needs ' \
                '64 bytes or more (openssl rand -hex 64)'
    set :session_secret, -> { ENV.fetch('SESSION_SECRET') { raise KeyError, NO_SECRET } }
    set :sessions, expire_after: 30 * 24 * 3600, same_site: :lax, secure: production?
    set :protection, except: :session_hijacking # a browser update must not log out

    # The sign-in pages, which need no session: /login and /login/<token>.
    OPEN = %r{\A/login(/[^/]+)?\z}

    before do
      if request.path_info.start_with?('/api/')
        halt 401, { 'content-type' => 'application/json' }, JSON.generate(error: 'Token inválido') unless api_token?
      elsif !OPEN.match?(request.path_info)
        env['frijolero.user'] = session_user
        sign_out unless env['frijolero.user']
      end
    end

    helpers do
      def api_token?
        token = request.get_header('HTTP_AUTHORIZATION').to_s.delete_prefix('Bearer ')
        !settings.api_token.empty? && Rack::Utils.secure_compare(token, settings.api_token)
      end

      # The user of the cookie, while that user is active and the cookie has its
      # session_version.
      def session_user
        user = Users.find(session[:user_id])
        user if user&.status == 'active' && user.session_version == session[:session_version]
      end

      def sign_out
        session.clear
        redirect '/login'
      end

      def login_page(notice: nil, error: nil, link: false) = erb(:login, locals: { notice:, error:, link: })
    end

    get('/login') { login_page }

    # ponytail: an email with an account answers later, by the time of the Postmark
    # call, so the timing tells which emails have one; send from a queue if that matters.
    post '/login' do
      begin
        Signin.request(params['email'])
      rescue Postmark::Error => e
        Log.puts "✗ No se pudo mandar el enlace: #{e.message}"
      end
      login_page(notice: 'Si esa dirección tiene una cuenta, te llega un correo con un enlace para entrar. ' \
                         'El enlace sirve 15 minutos.')
    end

    # Mail scanners open the links in an email, so the GET only shows a button.
    get('/login/:token') { login_page(link: true) }

    post '/login/:token' do
      user = Signin.redeem(params['token'])
      halt login_page(error: 'Este enlace ya no sirve: ya se usó o venció. Pide otro.') unless user

      session.clear
      session[:user_id] = user.id
      session[:session_version] = user.session_version
      redirect '/'
    end

    post('/logout') { sign_out }
  end
end
