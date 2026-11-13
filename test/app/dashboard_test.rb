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

  def write_statement(account, period, text = '')
    path = Frijolero::Config.statement_path(account, period, 'beancount')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  # One row that Revisar takes, a transaction with one Expenses:FIXME posting, and one classified row.
  UNCLASSIFIED = <<~BEANCOUNT
    2026-08-03 * "OXXO"
      Liabilities:BBVA  -50.00 MXN
      Expenses:FIXME
    2026-08-04 * "Netflix"
      Liabilities:BBVA  -199.00 MXN
      Expenses:Subscriptions
  BEANCOUNT

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
      write_statement('BBVA TDC', '2608')

      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5))
      rows = dashboard.rows.to_h { |r| [r.account, r.statuses] }

      assert_equal :received, rows['BBVA TDC']['2608']
      assert_equal :missing, rows['AMEX']['2608']
    end
  end

  def test_a_statement_with_unclassified_rows_is_to_review_and_counts_them
    with_ledger_dir do |dir|
      write_accounts(dir)
      write_statement('BBVA TDC', '2607')
      write_statement('BBVA TDC', '2608', UNCLASSIFIED)

      row = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5)).rows.find { |r| r.account == 'BBVA TDC' }

      assert_equal({ '2607' => :received, '2608' => :review }, row.statuses)
      assert_equal({ '2607' => 0, '2608' => 1 }, row.unclassified)
    end
  end

  def test_failed_status_and_received_wins_over_failed
    with_ledger_dir do |dir|
      write_accounts(dir)
      write_statement('BBVA TDC', '2608')

      jobs = { 'AMEX 2608' => job('job1', 'failed'), 'BBVA TDC 2608' => job('job2', 'failed') }
      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5), jobs: jobs)
      rows = dashboard.rows.to_h { |r| [r.account, r.statuses] }

      assert_equal :failed, rows['AMEX']['2608']
      assert_equal :received, rows['BBVA TDC']['2608']
    end
  end

  # A statement in the queue or in a job says so, even over the file of an overwrite.
  def test_a_job_in_progress_wins_over_every_other_status
    with_ledger_dir do |dir|
      write_accounts(dir)
      write_statement('BBVA TDC', '2608')

      jobs = { 'AMEX 2608' => job('job1', 'queued'), 'BBVA TDC 2608' => job('job2', 'running') }
      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5), jobs: jobs)
      rows = dashboard.rows.to_h { |r| [r.account, r.statuses] }

      assert_equal :running, rows['AMEX']['2608']
      assert_equal :running, rows['BBVA TDC']['2608']
    end
  end

  # A key with HTML in it is not an account (Config::ACCOUNT_KEY), so there is no escape to test.
  def test_view_renders_statuses
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'), <<~YAML)
        AMEX:
          beancount_account: "Liabilities:Amex"
        BBVA TDC:
          beancount_account: "Liabilities:BBVA"
      YAML

      write_statement('BBVA TDC', '2608')

      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5))
      html = view_app.erb(:dashboard, locals: { dashboard: dashboard, waiting: 0, transfers: {} })

      assert_includes html, 'falta'
      assert_includes html, '<a class="status received" href="/accounts/BBVA%20TDC/2608">listo</a>'
      assert_includes html, '<th>julio 2026</th>'
      assert_includes html, '<th>agosto 2026</th>'
      refute_includes html, '/rules', 'the rules are on Cuentas'
    end
  end

  # A failed balance line says so in place of "listo", with the gap to look for in the PDF. The
  # investments write their own balances and keep "listo".
  def test_a_failed_balance_says_saldo_no_cuadra_with_the_gap
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'), <<~YAML)
        BBVA TDC:
          beancount_account: "Liabilities:BBVA"
        CETES:
          beancount_account: "Assets:CETES"
          converter_type: cetes_directo
      YAML
      write_statement('BBVA TDC', '2608')
      write_statement('CETES', '2608')
      errors = ['BBVA TDC', 'CETES'].map do |key|
        { code: 'E2001', file: "accounts/#{key}/#{key} 2608.beancount", line: 9,
          message: 'Balance failed for Liabilities:BBVA: expected -1000.00 MXN, got -1377.00 MXN' }
      end

      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5), errors: errors)
      html = view_app.erb(:dashboard, locals: { dashboard: dashboard, waiting: 0, transfers: {} })

      assert_equal({ 'BBVA TDC' => :unbalanced, 'CETES' => :received },
                   dashboard.rows.to_h { |r| [r.account, r.statuses['2608']] })
      assert_match %r{href="/accounts/BBVA%20TDC/2608" title="[^"]+">saldo no cuadra: 377.00 MXN</a>}, html
    end
  end

  # Revisar for an account with rules. An investment has no Revisar: its rows are fixed from the statement.
  def test_view_links_a_statement_to_review_to_revisar_or_to_the_statement
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'), <<~YAML)
        BBVA TDC:
          beancount_account: "Liabilities:BBVA"
        CETES:
          beancount_account: "Assets:CETES"
          converter_type: cetes_directo
      YAML
      write_statement('BBVA TDC', '2608', UNCLASSIFIED)
      write_statement('CETES', '2608', UNCLASSIFIED)

      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5))
      html = view_app.erb(:dashboard, locals: { dashboard: dashboard, waiting: 0, transfers: {} })

      assert_includes html, '<a class="status missing" href="/accounts/BBVA%20TDC/2608/review">1 por revisar</a>'
      assert_includes html, '<a class="status missing" href="/accounts/CETES/2608">1 por revisar</a>'
    end
  end

  def test_view_gives_a_pending_statement_its_closing_date
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'), <<~YAML)
        AMEX:
          beancount_account: "Liabilities:Amex"
          cutoff_day: 3
        Nu:
          beancount_account: "Liabilities:Nu"
          cutoff_day: 23
      YAML

      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 23))
      html = view_app.erb(:dashboard, locals: { dashboard: dashboard, waiting: 0, transfers: {} })

      assert_includes html, '<span class="status pending">cierra el 3 oct</span>'
    end
  end

  def test_missing_links_to_upload_and_a_failed_or_running_statement_to_its_job
    with_ledger_dir do |dir|
      write_accounts(dir)
      write_statement('BBVA TDC', '2608')

      jobs = { 'AMEX 2607' => job('job1', 'failed'), 'BBVA TDC 2607' => job('job2', 'running') }
      dashboard = Frijolero::Dashboard.new(today: Date.new(2026, 9, 5), jobs: jobs)
      html = view_app.erb(:dashboard, locals: { dashboard: dashboard, waiting: 0, transfers: {} })

      assert_includes html, '<a class="status missing" href="/upload">falta</a>'
      assert_includes html, '<a class="status failed" href="/jobs/job1">falló</a>'
      assert_includes html, %(<a class="status running" href="/jobs/job2">#{ORBIT}corriendo</a>)
    end
  end

  private

  def job(id, status) = Frijolero::Jobs::Job.new(id:, status:)
end
