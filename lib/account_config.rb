# frozen_string_literal: true

require 'date'

module Frijolero
  module AccountConfig
    class << self
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

      # Accounts that still receive statements. A closed account keeps its key so
      # its history (pages, rules, PDFs) still resolves, but it leaves the
      # dashboard and the classifier's choices.
      def active
        Config.accounts.reject { |_key, config| config['closed'] }
      end

      # {key => description} for the classifier. Falls back to the key itself
      # so an account without a description still appears in the list.
      def descriptions
        active.to_h { |key, config| [key, config['description'] || key] }
      end

      # The closing date of the statement of `period`, for an account that closes on `day`
      # (nil or 31 for the last day): the closing 15 days or less after a day of that month.
      # A statement closing on C holds mostly the month of C - 15, the same rule Classifier uses.
      def closing(period, day)
        month = Date.strptime(period, '%y%m')
        [month, month.next_month].map { |m| closing_in(m, day || 31) }.find { |c| (c - 15).strftime('%y%m') == period }
      end

      def closing_in(month, day)
        Date.new(month.year, month.month, [day, Date.new(month.year, month.month, -1).day].min)
      end

      # Remembers the day of the month on which an account's statements close, the
      # first time the app sees a printed period end for it. 31 stands for the last
      # day of the month. A value already in the file is never replaced, so a hand
      # edit wins.
      def record_cutoff(account_key, period_end)
        config = Config.accounts[account_key]
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
