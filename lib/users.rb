# frozen_string_literal: true

module Frijolero
  # A person with an account. status is invited, active or blocked, and only an active
  # user has a session. The cookie keeps session_version: a new value signs out every device.
  User = Data.define(:id, :email, :name, :role, :status, :session_version) do
    def admin? = role == 'admin'
  end

  # The users table. There is no sign-up: the admin invites each user (app/admin.rb).
  module Users
    COLUMNS = User.members.join(', ')

    class << self
      def find(id) = one("SELECT #{COLUMNS} FROM users WHERE id = ?", id)

      # The column ignores case, so Ana@example.com finds ana@example.com.
      def find_by_email(email) = one("SELECT #{COLUMNS} FROM users WHERE email = ?", email.to_s.strip)

      def all = DB.execute("SELECT #{COLUMNS} FROM users ORDER BY id").map { |row| from_row(row) }

      # The new invited user, or nil when the email has a user. The UNIQUE column decides,
      # so two invitations at once make one user.
      def invite(email:, name: nil)
        name = name.to_s.strip
        one("INSERT INTO users (email, name, status, created_at) VALUES (?, ?, 'invited', ?) " \
            "ON CONFLICT DO NOTHING RETURNING #{COLUMNS}", email.to_s.strip, name.empty? ? nil : name,
            Time.now.utc.iso8601)
      end

      def activate(id) = DB.execute("UPDATE users SET status = 'active' WHERE id = ? AND status = 'invited'", id)

      # The new session_version ends the session of every device at once.
      def block(id)
        DB.execute("UPDATE users SET status = 'blocked', session_version = session_version + 1 WHERE id = ?", id)
      end

      def unblock(id) = DB.execute("UPDATE users SET status = 'active' WHERE id = ? AND status = 'blocked'", id)

      def sign_out_everywhere(id)
        DB.execute('UPDATE users SET session_version = session_version + 1 WHERE id = ?', id)
      end

      # nil means Usage::DEFAULT_CAP_MICROS.
      def set_cap(id, micros) = DB.execute('UPDATE users SET monthly_cap_micros = ? WHERE id = ?', micros, id)

      private

      def one(sql, *binds)
        row = DB.first(sql, *binds)
        row && from_row(row)
      end

      def from_row(row) = User.new(**row.transform_keys(&:to_sym))
    end
  end
end
