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

      # Parses a filename to extract account name and date
      # Supports formats:
      #   "Amex 2501.pdf" => ["Amex", "2501"]
      #   "amex_2501.json" => ["amex", "2501"]
      #   "BBVA_TDC_2501.json" => ["BBVA_TDC", "2501"]
      #   "Amex_2501.json" => ["Amex", "2501"]
      def parse_filename(filepath)
        filename = File.basename(filepath).sub(/\.(pdf|json|beancount)$/i, '')
        match = filename.match(/^(.+?)[\s_](\d{4})$/)
        return unless match

        [match[1], match[2]]
      end

      # Finds account config by name (case-insensitive, handles underscores as spaces)
      def find_config(account_name)
        return nil unless account_name

        # Try exact match first
        return accounts[account_name] if accounts[account_name]

        # Normalize: replace underscores with spaces for comparison
        normalized = account_name.gsub('_', ' ')

        # Try case-insensitive match with underscore normalization
        accounts.find do |key, _|
          key.downcase == normalized.downcase || key.downcase == account_name.downcase
        end&.last
      end

      # Returns the detailer config path for an account name
      def detailer_config_path(account_name)
        Config.detailer_config_path(account_name)
      end

      # Returns the beancount account for a given filepath
      # Parses the filename, looks up the config, and returns the beancount_account
      def beancount_account_for_file(filepath)
        parsed = parse_filename(filepath)
        return nil unless parsed

        account_name, = parsed
        config = find_config(account_name)
        config && config['beancount_account']
      end

      # Returns the detailer config path for a given filepath
      # Parses the filename and returns the config path if it exists
      def detailer_config_for_file(filepath)
        parsed = parse_filename(filepath)
        return nil unless parsed

        account_name, = parsed
        canonical = canonical_account_name(account_name) || account_name
        path = detailer_config_path(canonical)
        path && File.exist?(path) ? path : nil
      end

      def canonical_account_name(account_name)
        return nil unless find_config(account_name)

        normalized = account_name.gsub('_', ' ').downcase
        accounts.find { |key, _| key.downcase == normalized || key.downcase == account_name.downcase }&.first
      end

      # Returns a list of available account names for error messages
      def available_accounts
        accounts.keys
      end
    end
  end
end
