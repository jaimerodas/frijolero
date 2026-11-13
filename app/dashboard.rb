# frozen_string_literal: true

require 'date'

module Frijolero
  # Which statements exist for the two latest closed periods, per account.
  # Computed on each request from the filesystem; nothing is stored.
  class Dashboard
    # unclassified maps each period with a statement to the count of rows that Revisar takes.
    Row = Struct.new(:account, :statuses, :cutoff_day, :unclassified, keyword_init: true)

    # Both sides of a transfer between two statements post here, so the account is zero once
    # both statements are in the ledger (docs/rules.md).
    TRANSFERS = 'Assets:Transfers'

    # jobs maps "<account> <period>" to the newest job with that label.
    def initialize(today: Date.today, jobs: {})
      @today = today
      @jobs = jobs
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
        closed = last_closed(config['cutoff_day']).strftime('%y%m')
        unclassified = periods.to_h { |period| [period, Dashboard.unclassified(account, period)] }.compact
        statuses = periods.to_h { |period| [period, status_for(account, period, closed, unclassified[period])] }
        Row.new(account:, statuses:, cutoff_day: config['cutoff_day'], unclassified:)
      end
    end

    # The closing date of the statement of `period`, for an account that closes on `day`: the
    # closing 15 days or less after a day of that month, the rule of last_closed backwards.
    def self.closing(period, day)
      month = Date.strptime(period, '%y%m')
      [month, month.next_month].map { |m| closing_in(m, day || 31) }.find { |c| (c - 15).strftime('%y%m') == period }
    end

    # A day inside the period of the newest statement that has closed by `today`, for an
    # account that closes on `day` of each month (nil or 31 for the last day). A statement
    # closing on C holds mostly the month of C - 15, the same rule Classifier uses.
    def self.last_closed(day, today: Date.today) = last_closing(day, today:) - 15

    # The newest closing date on or before `today`.
    def self.last_closing(day, today: Date.today)
      [today, today.prev_month].map { |m| closing_in(m, day || 31) }.find { |c| c <= today }
    end

    def self.closing_in(month, day)
      Date.new(month.year, month.month, [day, Date.new(month.year, month.month, -1).day].min)
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

    # A job in progress wins, even over the file that an overwrite replaces.
    def status_for(account, period, closed, unclassified)
      job_status = job(account, period)&.status
      return :running if %w[queued running].include?(job_status)
      return unclassified.zero? ? :received : :review if unclassified
      return :failed if job_status == 'failed'

      period <= closed ? :missing : :pending
    end
  end
end
