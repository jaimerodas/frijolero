# frozen_string_literal: true

require 'uri'
require_relative 'page'

module Frijolero
  # /admin: the users, for the admin only. There is no sign-up: the admin invites each
  # person. Any other user gets, on every /admin path and method, the 404 of a page that
  # does not exist. Each action redirects back to /admin with the code of its message.
  class Admin < Page
    NOTICES = {
      'invited' => 'Le mandamos la invitación. El enlace sirve 7 días.',
      'resent' => 'Le mandamos otra invitación.',
      'blocked' => 'Bloqueado: ya no puede entrar, y se cerraron todas sus sesiones.',
      'unblocked' => 'Desbloqueado: ya puede entrar otra vez.',
      'signed_out' => 'Se cerraron todas sus sesiones.',
      'cap' => 'Tope guardado.'
    }.freeze

    ERRORS = {
      'email' => 'Escribe un correo válido.',
      'exists' => 'Ese correo ya tiene una cuenta.',
      'mail' => 'No se pudo mandar el correo. Prueba otra vez con «Reenviar invitación».',
      'not_invited' => 'Esa persona ya entró: solo se reenvía una invitación pendiente.',
      'self' => 'No puedes hacer eso con tu propia cuenta: te quedarías fuera.',
      'cap' => 'El tope es una cantidad en dólares, como 5 o 5.50. Vacío es el tope de siempre, 3 dólares.'
    }.freeze

    STATUS = { 'active' => %w[ok activo], 'invited' => %w[pending invitado], 'blocked' => %w[blocked bloqueado] }.freeze

    # The buttons of a row, by status: path => label. The admin's own row has none.
    ACTIONS = {
      'invited' => { 'resend' => 'Reenviar invitación', 'block' => 'Bloquear' },
      'active' => { 'sign_out' => 'Cerrar sesiones', 'block' => 'Bloquear' },
      'blocked' => { 'unblock' => 'Desbloquear' }
    }.freeze

    # Dollars, with at most the 6 decimals of a micro-dollar. Empty means the default.
    CAP = /\A(\d{1,6}(\.\d{1,6})?)?\z/

    before(%r{/admin(/.*)?}) { halt(*LedgerScope.not_found) unless user.admin? }

    helpers do
      # The user of the path.
      def person = Users.find(params['id'].to_i) || halt(*LedgerScope.not_found)

      # The user of the path, never the admin: blocking or signing out your own row would
      # lock out the only admin.
      def other_person = person.tap { |found| back(error: 'self') if found.id == user.id }

      def back(**message) = redirect("/admin?#{Rack::Utils.build_query(message)}", 303)

      def mail_invitation(person, notice)
        Signin.invite(person)
        back(notice: notice)
      rescue Postmark::Error => e
        Log.puts "✗ No se pudo mandar la invitación: #{e.message}"
        back(error: 'mail')
      end
    end

    get '/admin' do
      erb :admin, locals: { users: Users.all, notice: NOTICES[params['notice']], error: ERRORS[params['error']] }
    end

    post '/admin/invite' do
      back(error: 'email') unless URI::MailTo::EMAIL_REGEXP.match?(params['email'].to_s.strip)
      invited = Users.invite(email: params['email'], name: params['name']) || back(error: 'exists')
      mail_invitation(invited, 'invited')
    end

    post '/admin/users/:id/resend' do
      invited = person
      back(error: 'not_invited') unless invited.status == 'invited'
      mail_invitation(invited, 'resent')
    end

    post '/admin/users/:id/block' do
      Users.block(other_person.id)
      back(notice: 'blocked')
    end

    post '/admin/users/:id/unblock' do
      Users.unblock(other_person.id)
      back(notice: 'unblocked')
    end

    post '/admin/users/:id/sign_out' do
      Users.sign_out_everywhere(other_person.id)
      back(notice: 'signed_out')
    end

    # Rational, never a float: '5.50' is 5_500_000 micros exactly.
    post '/admin/users/:id/cap' do
      cap = params['cap'].to_s.strip
      back(error: 'cap') unless CAP.match?(cap)
      Users.set_cap(person.id, cap.empty? ? nil : (Rational(cap) * 1_000_000).to_i)
      back(notice: 'cap')
    end
  end
end
