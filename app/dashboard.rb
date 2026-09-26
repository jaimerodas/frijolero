# frozen_string_literal: true

require 'date'

module Frijolero
  # Which statements exist for the two latest closed periods, per account.
  # Computed on each request from the filesystem; nothing is stored.
  class Dashboard
    Row = Struct.new(:account, :statuses, :cutoff_day, keyword_init: true)

    # failed maps "<account> <period>" to the id of the newest failed job with that label.
    def initialize(today: Date.today, failed: {})
      @today = today
      @failed = failed
    end

    # The job behind a :failed status, for the dashboard's link.
    def failed_job_id(account, period)
      @failed["#{account} #{period}"]
    end

    # The newest period that some account has closed, and the one before it.
    def periods
      @periods ||= begin
        latest = AccountConfig.active.values.map { |config| last_closed(config['cutoff_day']) }.max || @today.prev_month
        [latest.prev_month, latest].map { |d| d.strftime('%y%m') }
      end
    end

    def rows
      AccountConfig.active.map do |account, config|
        closed = last_closed(config['cutoff_day']).strftime('%y%m')
        statuses = periods.to_h { |period| [period, status_for(account, period, closed)] }
        Row.new(account: account, statuses: statuses, cutoff_day: config['cutoff_day'])
      end
    end

    # A day inside the period of the newest statement that has closed by `today`, for an
    # account that closes on `day` of each month (nil or 31 for the last day). A statement
    # closing on C holds mostly the month of C - 15, the same rule Classifier uses.
    def self.last_closed(day, today: Date.today)
      closing = [today, today.prev_month].map { |m| closing_in(m, day || 31) }.find { |c| c <= today }
      closing - 15
    end

    def self.closing_in(month, day)
      Date.new(month.year, month.month, [day, Date.new(month.year, month.month, -1).day].min)
    end

    private

    def last_closed(day)
      self.class.last_closed(day, today: @today)
    end

    def status_for(account, period, closed)
      return :received if File.exist?(Config.statement_path(account, period, 'beancount'))
      return :failed if @failed.key?("#{account} #{period}")

      period <= closed ? :missing : :pending
    end
  end
end
