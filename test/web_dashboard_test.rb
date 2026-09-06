# frozen_string_literal: true

require 'test_helper'
require 'frijolero/web/dashboard'
require 'erb'
require 'fileutils'
require 'rack/utils'

class WebDashboardTest < Minitest::Test
  include TestHelpers

  VIEW_PATH = File.expand_path('../lib/frijolero/web/views/dashboard.erb', __dir__)

  def teardown; end

  def write_accounts(dir)
    File.write(File.join(dir, 'config', 'accounts.yaml'), <<~YAML)
      AMEX:
        beancount_account: "Liabilities:Amex"
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

      accounts = Frijolero::Web::Dashboard.new(today: Date.new(2026, 9, 5)).rows.map(&:account)

      assert_equal ['AMEX', 'BBVA TDC'], accounts
    end
  end

  def test_periods_returns_previous_and_current_month
    with_ledger_dir do
      dashboard = Frijolero::Web::Dashboard.new(today: Date.new(2026, 9, 5))
      assert_equal %w[2608 2609], dashboard.periods
    end
  end

  def test_periods_handles_january_edge_case
    with_ledger_dir do
      dashboard = Frijolero::Web::Dashboard.new(today: Date.new(2026, 1, 15))
      assert_equal %w[2512 2601], dashboard.periods
    end
  end

  def test_rows_follow_accounts_yaml_order_and_cover_both_accounts
    with_ledger_dir do |dir|
      write_accounts(dir)
      dashboard = Frijolero::Web::Dashboard.new(today: Date.new(2026, 9, 5))
      assert_equal ['AMEX', 'BBVA TDC'], dashboard.rows.map(&:account)
    end
  end

  def test_status_received_missing_and_pending
    with_ledger_dir do |dir|
      write_accounts(dir)
      path = Frijolero::Config.statement_path('BBVA TDC', '2608', 'beancount')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '')

      dashboard = Frijolero::Web::Dashboard.new(today: Date.new(2026, 9, 5))
      rows = dashboard.rows.to_h { |r| [r.account, r.statuses] }

      assert_equal :received, rows['BBVA TDC']['2608']
      assert_equal :missing, rows['AMEX']['2608']
      assert_equal :pending, rows['AMEX']['2609']
    end
  end

  def test_failed_status_and_received_wins_over_failed
    with_ledger_dir do |dir|
      write_accounts(dir)
      path = Frijolero::Config.statement_path('BBVA TDC', '2608', 'beancount')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '')

      dashboard = Frijolero::Web::Dashboard.new(today: Date.new(2026, 9, 5), failed: ['AMEX 2608', 'BBVA TDC 2608'])
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

      dashboard = Frijolero::Web::Dashboard.new(today: Date.new(2026, 9, 5))
      html = ERB.new(File.read(VIEW_PATH)).result_with_hash(dashboard: dashboard)

      assert_includes html, 'falta'
      assert_includes html, 'recibido'
      assert_includes html, '/statements/BBVA%20TDC/2608'
      assert_includes html, '&lt;x&gt;'
    end
  end
end
