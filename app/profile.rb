# frozen_string_literal: true

require 'uri'
require_relative 'page'

module Frijolero
  # /profile, "Mi cuenta": the name and the email of the signed-in user, their ledgers, the
  # use of the model month by month, and the link to their passkeys. Each action redirects
  # back to /profile with the code of its message.
  class ProfilePage < Page
    NOTICES = {
      'name' => 'Nombre guardado.',
      'email' => 'Te mandamos un enlace al correo nuevo. Entra con él para usarlo. Sirve 15 minutos.',
      'ledger_deleted' => 'Ledger borrado.'
    }.freeze

    ERRORS = {
      'email' => 'Escribe un correo válido.',
      'same' => 'Ese ya es tu correo.',
      'mail' => 'No se pudo mandar el correo. Prueba otra vez.'
    }.freeze

    get '/profile' do
      erb :profile, locals: { notice: NOTICES[params['notice']], error: ERRORS[params['error']] }
    end

    post '/profile/name' do
      Users.rename(user.id, params['name'])
      redirect '/profile?notice=name', 303
    end

    # The email changes when the person enters with the link that goes to the new one.
    # Over the limit of links nothing goes, and the page says the same as when one goes,
    # because a second submit within the minute (a double tap, a password manager) is the
    # usual way to get there.
    post '/profile/email' do
      email = params['email'].to_s.strip
      redirect '/profile?error=email', 303 unless URI::MailTo::EMAIL_REGEXP.match?(email)
      redirect '/profile?error=same', 303 if email.casecmp?(user.email)

      Signin.change_email(user, email)
      redirect '/profile?notice=email', 303
    rescue Postmark::Error => e
      Log.puts "✗ No se pudo mandar el enlace del correo nuevo: #{e.message}"
      redirect '/profile?error=mail', 303
    end
  end
end
