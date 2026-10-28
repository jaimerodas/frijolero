# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'time'

module Frijolero
  # Sign-in by email link. The link carries 32 random bytes, and the database keeps only
  # their SHA-256, so a copy of the database signs nobody in. A token works once. A link
  # with a new_email also changes the email of its user to that one.
  module Signin
    LOGIN_TTL = 15 * 60
    INVITE_TTL = 7 * 24 * 3600
    # Links per user: seconds => at most. So the form cannot fill an inbox.
    LIMITS = { 60 => 1, 3600 => 5 }.freeze

    # The new email of a link belongs to another user by the time of the click.
    class EmailTaken < StandardError; end

    class << self
      # Postmark, or a fake in the tests.
      attr_writer :mailer

      def mailer = @mailer || Postmark

      def issue(user, ttl:, now: Time.now, new_email: nil)
        raw = SecureRandom.urlsafe_base64(32)
        DB.execute('INSERT INTO signin_tokens (token_sha256, user_id, created_at, expires_at, new_email) ' \
                   'VALUES (?, ?, ?, ?, ?)', digest(raw), user.id, iso(now), iso(now + ttl), new_email)
        raw
      end

      # Mails a link to `new_email`: a click on it signs in and changes the email. Nothing
      # tells whether another user has that email, so nobody learns it from this form;
      # redeem refuses it then. Returns nil over the limit. A Postmark::Error goes up.
      def change_email(user, new_email, now: Time.now)
        raw = DB.transaction do
          issue(user, ttl: LOGIN_TTL, now: now, new_email: new_email) unless limited?(user, now, change: true)
        end
        return unless raw

        mailer.deliver(to: new_email, subject: 'Confirma tu correo nuevo de Frijolero', text: <<~TEXT)
          Para usar este correo en Frijolero, entra con este enlace:

          #{link(raw)}

          Funciona una sola vez, durante 15 minutos. Hasta que entres, tu cuenta usa el correo de antes.

          Si no lo pediste, ignora este correo.
        TEXT
      end

      # Mails a login link to an invited or active user. An unknown or blocked email, or
      # one over the limit, gets nothing, and the caller shows the same page in every case.
      def request(email, now: Time.now)
        user = Users.find_by_email(email)
        return unless %w[invited active].include?(user&.status)

        # The count and the insert in one transaction, so two requests at once send one link.
        raw = DB.transaction { issue(user, ttl: LOGIN_TTL, now: now) unless limited?(user, now) }
        mailer.deliver(to: user.email, subject: 'Tu enlace para entrar a Frijolero', text: message(link(raw))) if raw
      end

      # Mails an invitation that lives INVITE_TTL. Only to an invited user: every other
      # link lasts LOGIN_TTL. Returns nil for any other user. A Postmark::Error goes up.
      def invite(user, now: Time.now)
        return unless user.status == 'invited'

        raw = issue(user, ttl: INVITE_TTL, now: now)
        mailer.deliver(to: user.email, subject: 'Te invitaron a Frijolero', text: <<~TEXT)
          Te invitaron a Frijolero, la app que convierte tus estados de cuenta en un ledger de Beancount.

          Entra con este enlace:

          #{link(raw)}

          Funciona una sola vez, durante 7 días. Después, pide un enlace nuevo con tu correo.
        TEXT
      end

      # The user of an unused token that has not expired, or nil. One UPDATE marks it used,
      # so two clicks at once cannot both sign in. The first sign-in activates an invited user.
      # A token with a new_email changes the email first, and tells the old address.
      def redeem(raw, now: Time.now)
        row = DB.first('UPDATE signin_tokens SET used_at = ? WHERE token_sha256 = ? AND used_at IS NULL ' \
                       'AND expires_at > ? RETURNING user_id, new_email', iso(now), digest(raw), iso(now))
        return unless row

        Users.activate(row['user_id'])
        user = Users.find(row['user_id'])
        return unless user&.status == 'active'

        row['new_email'] ? move(user, row['new_email']) : user
      end

      # From APP_URL, never from the request: its Host header can name another site.
      def link(raw) = "#{ENV.fetch('APP_URL')}/login/#{raw}"

      private

      # The user with the new email. The change is done, so a failed notice only goes to the log.
      def move(user, new_email)
        moved = Users.change_email(user.id, new_email) || raise(EmailTaken)
        mailer.deliver(to: user.email, subject: 'Tu correo de Frijolero cambió', text: <<~TEXT)
          Tu cuenta de Frijolero ahora usa #{new_email}. Desde hoy, los enlaces para entrar llegan ahí.

          Si no fuiste tú, avísale a quien te invitó a Frijolero.
        TEXT
        moved
      rescue Postmark::Error => e
        Log.puts "✗ No se pudo avisar al correo de antes: #{e.message}"
        moved
      end

      # The sign-in links and the change links go to two inboxes, so each kind has its own count.
      def limited?(user, now, change: false)
        LIMITS.any? do |seconds, most|
          DB.first('SELECT COUNT(*) AS n FROM signin_tokens WHERE user_id = ? AND created_at > ? ' \
                   "AND new_email IS #{'NOT ' if change}NULL", user.id, iso(now - seconds))['n'] >= most
        end
      end

      def message(link)
        <<~TEXT
          Entra a Frijolero con este enlace:

          #{link}

          Funciona una sola vez, durante 15 minutos.

          Si no lo pediste, ignora este correo.
        TEXT
      end

      def digest(raw) = Digest::SHA256.hexdigest(raw.to_s)

      # getutc, because utc changes the Time that the caller passed.
      def iso(time) = time.getutc.iso8601
    end
  end
end
