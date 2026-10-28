# frozen_string_literal: true

require 'json'
require 'sinatra/base'

module Frijolero
  # Middleware in config.ru, outside LedgerScope, so its pages have no current ledger.
  # Owns the sign-in routes (an email link or a passkey) and gates everything else
  # behind a signed cookie session that holds user_id and session_version. httponly is
  # the rack-session default. secure: production? because bin/dev is plain http. The
  # App finds the user in env['frijolero.user'].
  #
  # /api/ is for the iOS Shortcut, which has no cookie: it sends a token of ApiTokens as
  # a bearer token instead, and the token names the ledger.
  class Login < Sinatra::Base
    set :views, App.views
    set :public_folder, App.public_folder # style.css before the filter
    set :static_cache_control, [:no_cache] # a deploy changes the files under the same names
    NO_SECRET = 'SESSION_SECRET is not set: it signs the session cookie, and rack-session needs ' \
                '64 bytes or more (openssl rand -hex 64)'
    set :session_secret, -> { ENV.fetch('SESSION_SECRET') { raise KeyError, NO_SECRET } }
    set :sessions, expire_after: 30 * 24 * 3600, same_site: :lax, secure: production?
    set :protection, except: :session_hijacking # a browser update must not log out

    # The sign-in pages, which need no session: /login and /login/<token>.
    OPEN = %r{\A/login(/[^/]+)?\z}

    before do
      if request.path_info.start_with?('/api/')
        ledger_id = ApiTokens.ledger_id_for(bearer_token)
        halt 401, { 'content-type' => 'application/json' }, JSON.generate(error: 'Token inválido') unless ledger_id
        # LedgerScope serves /api/ in the ledger that the token names.
        env['frijolero.api_ledger'] = ledger_id
      elsif !OPEN.match?(request.path_info)
        env['frijolero.user'] = session_user
        sign_out unless env['frijolero.user']
      end
    end

    helpers do
      def bearer_token = request.get_header('HTTP_AUTHORIZATION').to_s.delete_prefix('Bearer ')

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

      # The old session can hold anything, so it goes first.
      def start_session(user)
        session.clear
        session[:user_id] = user.id
        session[:session_version] = user.session_version
        redirect '/'
      end
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

    # The passkey routes come before /login/:token, which would take their names as tokens.
    # A token has 43 characters, so it is never one of these names.
    #
    # The options of the passkey autofill on the login page. public/passkeys.js fetches
    # them, so the challenge waits in the session and never shows in the page.
    post '/login/challenge' do
      pending = session[:passkey_challenge] = Passkeys.challenge
      content_type :json
      JSON.generate(Passkeys.request_options(pending.first))
    end

    # The challenge leaves the session at the first answer, so an answer works once.
    post '/login/passkey' do
      start_session(Passkeys.authenticate(params['credential'], session.delete(:passkey_challenge)))
    rescue Passkeys::Error => e
      Log.puts "✗ Llave de acceso: #{e.message}"
      login_page(error: 'Esa llave de acceso no sirvió. Prueba otra vez o pide un enlace.')
    end

    # Mail scanners open the links in an email, so the GET only shows a button. The page
    # loads Google Fonts, and its URL holds the token: no Referer goes out with it.
    get '/login/:token' do
      headers 'Referrer-Policy' => 'no-referrer'
      login_page(link: true)
    end

    post '/login/:token' do
      user = Signin.redeem(params['token'])
      halt login_page(error: 'Este enlace ya no sirve: ya se usó o venció. Pide otro.') unless user

      start_session(user)
    rescue Signin::EmailTaken
      login_page(error: 'Ese correo ya es de otra cuenta, así que tu correo no cambió.')
    end

    post('/logout') { sign_out }
  end
end
