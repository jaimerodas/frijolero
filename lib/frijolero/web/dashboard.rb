# frozen_string_literal: true

require 'date'

module Frijolero
  module Web
    # Which statements exist for the previous and the current month, per account.
    # Computed on each request from the filesystem; nothing is stored.
    class Dashboard
      Row = Struct.new(:account, :statuses, keyword_init: true)

      def initialize(today: Date.today, failed: [])
        @today = today
        @failed = failed
      end

      def periods
        [@today.prev_month, @today].map { |d| d.strftime('%y%m') }
      end

      def rows
        Config.accounts.keys.map do |account|
          statuses = periods.to_h { |period| [period, status_for(account, period)] }
          Row.new(account: account, statuses: statuses)
        end
      end

      private

      def status_for(account, period)
        return :received if File.exist?(Config.statement_path(account, period, 'beancount'))
        return :failed if @failed.include?("#{account} #{period}")

        period == periods.first ? :missing : :pending
      end
    end
  end
end
