# frozen_string_literal: true

require 'uri'
require_relative 'page'

module Frijolero
  # /admin: the users, for the admin only. There is no sign-up: the admin invites each
  # person. Any other user gets, on every /admin path and method, the 404 of a page that
  # does not exist. Each action redirects back to /admin with the code of its message, or
  # to the page of the person when the form says so.
  class Admin < Page
    NOTICES = {
      'invited' => 'Le mandamos la invitación. El enlace sirve 7 días.',
      'resent' => 'Le mandamos otra invitación.',
      'blocked' => 'Bloqueado: ya no puede entrar, y se cerraron todas sus sesiones.',
      'unblocked' => 'Desbloqueado: ya puede entrar otra vez.',
      'signed_out' => 'Se cerraron todas sus sesiones.',
      'cap' => 'Tope guardado.',
      'deleted' => 'Usuario borrado.',
      'ledger_deleted' => 'Ledger borrado.'
    }.freeze

    ERRORS = {
      'email' => 'Escribe un correo válido.',
      'exists' => 'Ese correo ya tiene una cuenta.',
      'mail' => 'No se pudo mandar el correo. Prueba otra vez con «Reenviar».',
      'not_invited' => 'Esa persona ya entró: solo se reenvía una invitación pendiente.',
      'self' => 'No puedes hacer eso con tu propia cuenta: te quedarías fuera.',
      'not_blocked' => 'Bloquea a esa persona antes de borrarla, para que no empiece nada nuevo.',
      'cap' => 'El tope es una cantidad en dólares, como 5 o 5.50. Vacío es el tope de siempre, 3 dólares.'
    }.freeze

    STATUS = { 'active' => %w[ok activo], 'invited' => %w[pending invitado], 'blocked' => %w[blocked bloqueado] }.freeze

    # The buttons of a row, by status: path => label. The admin's own row has none.
    ACTIONS = {
      'invited' => { 'resend' => 'Reenviar', 'block' => 'Bloquear' },
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

      def back(**message)
        page = params['from'] == 'person' ? "/admin/users/#{params['id'].to_i}" : '/admin'
        redirect("#{page}?#{Rack::Utils.build_query(message)}", 303)
      end

      # A user who can start nothing new, invited or blocked, and never the admin.
      def deletable_person
        other_person.tap { |found| back(error: 'not_blocked') unless %w[invited blocked].include?(found.status) }
      end

      def delete_user_page(person, error: nil)
        erb :delete, locals: { title: "Borrar a #{person.name || person.email}", ledgers: Ledger.owned_by(person.id),
                               person: person, word: person.email, back: "/admin/users/#{person.id}", error: error }
      end

      def mail_invitation(person, notice)
        Signin.invite(person)
        back(notice: notice)
      rescue Postmark::Error => e
        Log.puts "✗ No se pudo mandar la invitación: #{e.message}"
        back(error: 'mail')
      end
    end

    # The invitation form is closed, except after a refused invitation, which the person types again.
    get '/admin' do
      erb :admin, locals: { users: Users.all, notice: NOTICES[params['notice']], error: ERRORS[params['error']],
                            inviting: %w[email exists].include?(params['error']) }
    end

    # One person: the buttons of their row, their ledgers and their use of the model. The
    # admin's own row has no buttons, so it is Mi cuenta.
    get '/admin/users/:id' do
      redirect '/profile' if person.id == user.id
      erb :admin_user, locals: { person: person, notice: NOTICES[params['notice']], error: ERRORS[params['error']] }
    end

    # The page says what goes and what stays, and the admin types the email of the person.
    get('/admin/users/:id/delete') { delete_user_page(deletable_person) }

    # Each ledger first, then the rows. A bucket error stops it with the user and the
    # ledgers that remain, so a second click finishes.
    post '/admin/users/:id/delete' do
      found = deletable_person
      unless params['confirm'].to_s.strip.casecmp?(found.email)
        halt 422, delete_user_page(found, error: "Para borrarla, escribe su correo: #{found.email}")
      end
      ledgers = Ledger.owned_by(found.id)
      halt 409, delete_user_page(found, error: BUSY) if ledgers.any? { busy?(it) }

      ledgers.each { destroy_ledger(it) }
      Users.delete(found.id)
      back(notice: 'deleted')
    rescue S3::Error => e
      halt 502, delete_user_page(found, error: "#{BUCKET_FAILED} (#{e.message})")
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
