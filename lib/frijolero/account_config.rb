# frozen_string_literal: true

module Frijolero
  module AccountConfig
    class << self
      def accounts
        Config.accounts
      end

      def reload!
        Config.reload!
      end

      # Parses a filename to extract account key and period.
      #   "AMEX Aeromexico 2508.pdf" => ["AMEX Aeromexico", "2508"]
      # The period is the last word (4 digits); everything before the single
      # separating space is the account key. Underscore-separated names are
      # no longer supported and return nil.
      def parse_filename(filepath)
        filename = File.basename(filepath).sub(/\.(pdf|json|beancount)$/i, '')
        match = filename.match(/\A(.+) (\d{4})\z/)
        return unless match

        [match[1], match[2]]
      end

      # Finds account config by exact key.
      def find_config(account_key)
        return nil unless account_key

        accounts[account_key]
      end

      # Returns the rules file path for an account key.
      def rules_path(account_key)
        Config.rules_path(account_key)
      end

      # Returns a list of available account names for error messages
      def available_accounts
        accounts.keys
      end
    end
  end
end
