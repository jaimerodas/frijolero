# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'time'

module Frijolero
  # Sign-in by email link. The link carries 32 random bytes, and the database keeps only
  # their SHA-256, so a copy of the database signs nobody in. A token works once.
  module Signin
    LOGIN_TTL = 15 * 60
    # Links per user: seconds => at most. So the form cannot fill an inbox.
    LIMITS = { 60 => 1, 3600 => 5 }.freeze

    class << self
      # Postmark, or a fake in the tests.
      attr_writer :mailer

      def mailer = @mailer || Postmark

      def issue(user, ttl:, now: Time.now)
        raw = SecureRandom.urlsafe_base64(32)
        DB.execute('INSERT INTO signin_tokens (token_sha256, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)',
                   digest(raw), user.id, iso(now), iso(now + ttl))
        raw
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

      # The user of an unused token that has not expired, or nil. One UPDATE marks it used,
      # so two clicks at once cannot both sign in. The first sign-in activates an invited user.
      def redeem(raw, now: Time.now)
        row = DB.first('UPDATE signin_tokens SET used_at = ? WHERE token_sha256 = ? AND used_at IS NULL ' \
                       'AND expires_at > ? RETURNING user_id', iso(now), digest(raw), iso(now))
        return unless row

        Users.activate(row['user_id'])
        user = Users.find(row['user_id'])
        user if user&.status == 'active'
      end

      # From APP_URL, never from the request: its Host header can name another site.
      def link(raw) = "#{ENV.fetch('APP_URL')}/login/#{raw}"

      private

      def limited?(user, now)
        LIMITS.any? do |seconds, most|
          DB.first('SELECT COUNT(*) AS n FROM signin_tokens WHERE user_id = ? AND created_at > ?',
                   user.id, iso(now - seconds))['n'] >= most
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
