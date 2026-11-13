# frozen_string_literal: true

require 'date'

module Frijolero
  # Which statements exist for the two latest closed periods, per account.
  # Computed on each request from the filesystem; nothing is stored.
  class Dashboard
    # unclassified maps each period with a statement to the count of rows that Revisar takes, and
    # balance_errors each period whose balance line fails to that error of `rledger check`.
    Row = Struct.new(:account, :statuses, :cutoff_day, :unclassified, :balance_errors, keyword_init: true)

    # Both sides of a transfer between two statements post here, so the account is zero once
    # both statements are in the ledger (docs/rules.md).
    TRANSFERS = 'Assets:Transfers'

    # jobs maps "<account> <period>" to the newest job with that label, and errors are
    # App.ledger_errors.
    def initialize(today: Date.today, jobs: {}, errors: [])
      @today = today
      @jobs = jobs
      @errors = errors || []
    end

    # The job behind a :running or :failed status, for the dashboard's link.
    def job(account, period) = @jobs["#{account} #{period}"]

    # The newest period that some account has closed, and the one before it.
    def periods
      @periods ||= begin
        latest = AccountConfig.active.values.map { |config| last_closed(config['cutoff_day']) }.max || @today.prev_month
        [latest.prev_month, latest].map { |d| d.strftime('%y%m') }
      end
    end

    # ponytail: no cache. Counting the rows reads every statement of the two periods: 4.6 ms for
    # the 13 statements of the real ledger (November 2026).
    def rows
      AccountConfig.active.map do |account, config|
        row = Row.new(account:, cutoff_day: config['cutoff_day'], balance_errors: balance_errors(account, config),
                      unclassified: periods.to_h { |period| [period, Dashboard.unclassified(account, period)] }.compact)
        row.statuses = periods.to_h { |period| [period, status_for(row, period)] }
        row
      end
    end

    # A day inside the period of the newest statement that has closed by `today`, for an
    # account that closes on `day` of each month (nil or 31 for the last day). A statement
    # closing on C holds mostly the month of C - 15, the same rule Classifier uses.
    def self.last_closed(day, today: Date.today) = last_closing(day, today:) - 15

    # The newest closing date on or before `today`.
    def self.last_closing(day, today: Date.today)
      [today, today.prev_month].map { |m| AccountConfig.closing_in(m, day || 31) }.find { |c| c <= today }
    end

    # The rows that Revisar takes, or nil when the statement does not exist.
    def self.unclassified(account, period)
      path = Config.statement_path(account, period, 'beancount')
      StatementReview.unclassified(Beancount::Parser.parse(path)).size if File.exist?(path)
    end

    private

    def last_closed(day)
      self.class.last_closed(day, today: @today)
    end

    # The failed balances (E2001) of the statements whose line StatementBalance writes, by period.
    def balance_errors(account, config)
      return {} unless Pipeline.for(config).is_a?(Pipeline::Default)

      periods.to_h do |period|
        file = "accounts/#{account}/#{account} #{period}.beancount"
        [period, @errors.find { |e| e[:code] == 'E2001' && e[:file] == file }]
      end.compact
    end

    # A job in progress wins, even over the file that an overwrite replaces.
    def status_for(row, period)
      job_status = job(row.account, period)&.status
      return :running if %w[queued running].include?(job_status)
      return statement_status(row, period) if row.unclassified[period]
      return :failed if job_status == 'failed'

      period <= last_closed(row.cutoff_day).strftime('%y%m') ? :missing : :pending
    end

    # A failed balance shows once nothing is left to review.
    def statement_status(row, period)
      return :review if row.unclassified[period].positive?

      row.balance_errors[period] ? :unbalanced : :received
    end
  end
end
