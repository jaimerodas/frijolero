# frozen_string_literal: true

require 'date'

module Frijolero
  module AccountConfig
    class << self
      def accounts
        Config.accounts
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

      # {key => description} for the classifier. Falls back to the key itself
      # so an account without a description still appears in the list.
      # Accounts that still receive statements. A closed account keeps its key so
      # its history (pages, rules, PDFs) still resolves, but it leaves the
      # dashboard and the classifier's choices.
      def active
        accounts.reject { |_key, config| config['closed'] }
      end

      def descriptions
        active.to_h { |key, config| [key, config['description'] || key] }
      end

      # Remembers the day of the month on which an account's statements close, the
      # first time the app sees a printed period end for it. 31 stands for the last
      # day of the month. A value already in the file is never replaced, so a hand
      # edit wins.
      def record_cutoff(account_key, period_end)
        config = find_config(account_key)
        return if config.nil? || config.key?('cutoff_day')

        last_day = Date.new(period_end.year, period_end.month, -1)
        day = period_end == last_day ? 31 : period_end.day
        text = File.read(Config.accounts_file)
        block = AccountBlock.extract(text, account_key)
        block = "#{block}\n" unless block.end_with?("\n")
        File.write(Config.accounts_file, AccountBlock.replace(text, account_key, "#{block}  cutoff_day: #{day}\n"))
      end
    end
  end
end
