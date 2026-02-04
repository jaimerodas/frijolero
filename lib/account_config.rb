# frozen_string_literal: true

require "yaml"

module AccountConfig
  CONFIG_DIR = File.expand_path("../../config", __FILE__)
  ACCOUNTS_FILE = File.join(CONFIG_DIR, "accounts.yaml")

  class << self
    def accounts
      @accounts ||= YAML.load_file(ACCOUNTS_FILE)
    end

    def reload!
      @accounts = nil
    end

    # Parses a filename to extract account name and date
    # Supports formats:
    #   "Amex 2501.pdf" => ["Amex", "2501"]
    #   "amex_2501.json" => ["amex", "2501"]
    #   "BBVA_TDC_2501.json" => ["BBVA_TDC", "2501"]
    #   "Amex_2501.json" => ["Amex", "2501"]
    def parse_filename(filepath)
      filename = File.basename(filepath).sub(/\.(pdf|json|beancount)$/i, "")

      # Try space-separated format first: "Account Name YYMM"
      if (match = filename.match(/^(.+?)\s+(\d{4})$/))
        return [match[1], match[2]]
      end

      # Try underscore-separated format: "account_name_YYMM"
      if (match = filename.match(/^(.+?)_(\d{4})$/))
        return [match[1], match[2]]
      end

      nil
    end

    # Finds account config by name (case-insensitive, handles underscores as spaces)
    def find_config(account_name)
      return nil unless account_name

      # Normalize: replace underscores with spaces for comparison
      normalized = account_name.gsub("_", " ")

      # Try exact match first
      return accounts[account_name] if accounts[account_name]

      # Try case-insensitive match with underscore normalization
      accounts.find do |key, _|
        key.downcase == normalized.downcase ||
          key.downcase == account_name.downcase
      end&.last
    end

    # Returns the detailer config path for an account name
    def detailer_config_path(account_name)
      return nil unless account_name

      config_name = account_name.downcase.gsub(" ", "_")
      File.join(CONFIG_DIR, "#{config_name}.yaml")
    end

    # Returns the beancount account for a given filepath
    # Parses the filename, looks up the config, and returns the beancount_account
    def beancount_account_for_file(filepath)
      parsed = parse_filename(filepath)
      return nil unless parsed

      account_name, = parsed
      config = find_config(account_name)
      config&.dig("beancount_account")
    end

    # Returns the detailer config path for a given filepath
    # Parses the filename and returns the config path if it exists
    def detailer_config_for_file(filepath)
      parsed = parse_filename(filepath)
      return nil unless parsed

      account_name, = parsed

      # Try to find the account in accounts.yaml to get the canonical name
      config = find_config(account_name)
      if config
        # Find the canonical key name from accounts.yaml
        canonical_name = accounts.find do |key, _|
          normalized = account_name.gsub("_", " ")
          key.downcase == normalized.downcase ||
            key.downcase == account_name.downcase
        end&.first

        account_name = canonical_name if canonical_name
      end

      path = detailer_config_path(account_name)
      File.exist?(path) ? path : nil
    end

    # Returns a list of available account names for error messages
    def available_accounts
      accounts.keys
    end
  end
end
