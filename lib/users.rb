# frozen_string_literal: true

module Frijolero
  # A person with an account. status is invited, active or blocked, and only an active
  # user has a session. The cookie keeps session_version: a new value signs out every device.
  User = Data.define(:id, :email, :name, :role, :status, :session_version) do
    def admin? = role == 'admin'
  end

  # The users table. Invite and block come with the admin pages.
  module Users
    COLUMNS = User.members.join(', ')

    class << self
      def find(id) = one("SELECT #{COLUMNS} FROM users WHERE id = ?", id)

      # The column ignores case, so Ana@example.com finds ana@example.com.
      def find_by_email(email) = one("SELECT #{COLUMNS} FROM users WHERE email = ?", email.to_s.strip)

      def activate(id) = DB.execute("UPDATE users SET status = 'active' WHERE id = ? AND status = 'invited'", id)

      private

      def one(sql, *binds)
        row = DB.first(sql, *binds)
        row && User.new(**row.transform_keys(&:to_sym))
      end
    end
  end
end
