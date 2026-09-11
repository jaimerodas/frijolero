# frozen_string_literal: true

require 'test_helper'
require 'fileutils'
require 'rack/utils'

class DashboardTest < Minitest::Test
  include TestHelpers

  def write_accounts(dir)
    File.write(File.join(dir, 'config', 'accounts.yaml'), <<~YAML)
      AMEX:
        beancount_account: "Liabilities:Amex"
        cutoff_day: 3
      BBVA TDC:
        beancount_account: "Liabilities:BBVA"
      Old Card:
        beancount_account: "Liabilities:OldCard"
        closed: true
    YAML
  end

  def test_closed_accounts_are_not_listed
    with_ledger_dir do |dir|
      write_accounts(dir)

      accounts = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5)).rows.map(&:account)

      assert_equal ['AMEX', 'BBVA TDC'], accounts
    end
  end

  def test_rows_carry_the_cutoff_day_when_configured
    with_ledger_dir do |dir|
      write_accounts(dir)

      rows = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5)).rows

      assert_equal [3, nil], rows.map(&:cutoff_day)
    end
  end

  def test_periods_end_at_the_previous_month_before_any_cutoff
    with_ledger_dir do |dir|
      write_accounts(dir)
      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5))
      assert_equal %w[2607 2608], dashboard.periods
    end
  end

  def test_periods_include_the_current_month_once_an_account_closes_in_it
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'), <<~YAML)
        AMEX:
          beancount_account: "Liabilities:Amex"
          cutoff_day: 3
        Nu:
          beancount_account: "Liabilities:Nu"
          cutoff_day: 23
      YAML

      before = Frijolero::Dashboard.new(today: Date.new(2026, 9, 22))
      after = Frijolero::Dashboard.new(today: Date.new(2026, 9, 23))

      assert_equal %w[2607 2608], before.periods
      assert_equal %w[2608 2609], after.periods
      statuses = after.rows.to_h { |row| [row.account, row.statuses['2609']] }
      assert_equal({ 'AMEX' => :pending, 'Nu' => :missing }, statuses)
    end
  end

  def test_periods_handle_the_january_edge_case
    with_ledger_dir do
      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 1, 15))
      assert_equal %w[2511 2512], dashboard.periods
    end
  end

  def test_a_cutoff_past_the_end_of_february_closes_on_its_last_day
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'), <<~YAML)
        AMEX:
          beancount_account: "Liabilities:Amex"
          cutoff_day: 30
      YAML

      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 3, 1))

      assert_equal %w[2601 2602], dashboard.periods
    end
  end

  def test_rows_follow_accounts_yaml_order_and_cover_both_accounts
    with_ledger_dir do |dir|
      write_accounts(dir)
      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5))
      assert_equal ['AMEX', 'BBVA TDC'], dashboard.rows.map(&:account)
    end
  end

  def test_status_received_and_missing
    with_ledger_dir do |dir|
      write_accounts(dir)
      path = Frijolero::Config.statement_path('BBVA TDC', '2608', 'beancount')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '')

      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5))
      rows = dashboard.rows.to_h { |r| [r.account, r.statuses] }

      assert_equal :received, rows['BBVA TDC']['2608']
      assert_equal :missing, rows['AMEX']['2608']
    end
  end

  def test_failed_status_and_received_wins_over_failed
    with_ledger_dir do |dir|
      write_accounts(dir)
      path = Frijolero::Config.statement_path('BBVA TDC', '2608', 'beancount')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '')

      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5), failed: ['AMEX 2608', 'BBVA TDC 2608'])
      rows = dashboard.rows.to_h { |r| [r.account, r.statuses] }

      assert_equal :failed, rows['AMEX']['2608']
      assert_equal :received, rows['BBVA TDC']['2608']
    end
  end

  def test_view_renders_statuses_and_escapes_account_names
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'), <<~YAML)
        AMEX:
          beancount_account: "Liabilities:Amex"
        BBVA TDC:
          beancount_account: "Liabilities:BBVA"
        <x>:
          beancount_account: "Liabilities:X"
      YAML

      path = Frijolero::Config.statement_path('BBVA TDC', '2608', 'beancount')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '')

      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5))
      html = Frijolero::App.new!.erb(:dashboard, locals: { dashboard: dashboard })

      assert_includes html, 'falta'
      assert_includes html, 'recibido'
      assert_includes html, '/accounts/BBVA%20TDC/2608'
      assert_includes html, '<th>julio 2026</th>'
      assert_includes html, '<th>agosto 2026</th>'
      assert_includes html, '&lt;x&gt;'
    end
  end
end
