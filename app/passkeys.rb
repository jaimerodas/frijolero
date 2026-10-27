# frozen_string_literal: true

require 'json'
require_relative 'page'

module Frijolero
  # /passkeys: the passkeys of the signed-in user (lib/passkeys.rb). A passkey belongs to
  # a person and not to a ledger, so the page is outside the ledgers. Each action
  # redirects back to /passkeys with the code of its message.
  class PasskeysPage < Page
    NOTICES = {
      'created' => 'Listo: la próxima vez, entra con esta llave de acceso.',
      'deleted' => 'Borrada. Bórrala también de tu dispositivo o de tu gestor de contraseñas: ya no sirve.'
    }.freeze

    ERRORS = {
      'failed' => 'No se creó la llave de acceso. Si este dispositivo ya tiene una, no hace falta otra.'
    }.freeze

    get '/passkeys' do
      erb :passkeys, locals: { passkeys: Passkeys.for_user(user.id), notice: NOTICES[params['notice']],
                               error: ERRORS[params['error']] }
    end

    # The options that public/passkeys.js fetches. The challenge waits in the session.
    post '/passkeys/challenge' do
      pending = session[:passkey_challenge] = Passkeys.challenge
      content_type :json
      JSON.generate(Passkeys.creation_options(user, pending.first))
    end

    post '/passkeys' do
      Passkeys.register(user, params['credential'], session.delete(:passkey_challenge))
      redirect '/passkeys?notice=created', 303
    rescue Passkeys::Error => e
      Log.puts "✗ Llave de acceso nueva: #{e.message}"
      redirect '/passkeys?error=failed', 303
    end

    post '/passkeys/delete' do
      Passkeys.delete(user.id, params['id'])
      redirect '/passkeys?notice=deleted', 303
    end
  end
end
