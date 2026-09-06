# frozen_string_literal: true

require 'date'

module Frijolero
  # Which statements exist for the two latest closed periods, per account.
  # Computed on each request from the filesystem; nothing is stored.
  class Dashboard
    Row = Struct.new(:account, :statuses, :cutoff_day, keyword_init: true)

    def initialize(today: Date.today, failed: [])
      @today = today
      @failed = failed
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

    private

    # A day inside the period of the newest statement that has closed by today, for an
    # account that closes on `day` of each month (nil or 31 for the last day). A statement
    # closing on C holds mostly the month of C - 15, the same rule Classifier uses.
    def last_closed(day)
      closing = [@today, @today.prev_month].map { |m| closing_in(m, day || 31) }.find { |c| c <= @today }
      closing - 15
    end

    def closing_in(month, day)
      Date.new(month.year, month.month, [day, Date.new(month.year, month.month, -1).day].min)
    end

    def status_for(account, period, closed)
      return :received if File.exist?(Config.statement_path(account, period, 'beancount'))
      return :failed if @failed.include?("#{account} #{period}")

      period <= closed ? :missing : :pending
    end
  end
end
