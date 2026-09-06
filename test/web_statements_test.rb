# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'fileutils'
require 'json'

class WebStatementsTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  class FakeRepo
    attr_reader :calls

    def initialize
      @calls = []
    end

    def commit_and_push(message)
      @calls << message
    end
  end

  def setup
    @previous_rack_env = ENV.fetch('RACK_ENV', nil)
    ENV['RACK_ENV'] = 'test'
    require 'frijolero/web/app'

    @dir = Dir.mktmpdir
    @previous_ledger_dir = ENV.fetch('LEDGER_DIR', nil)
    ENV['LEDGER_DIR'] = @dir
    FileUtils.mkdir_p(File.join(@dir, 'config'))
    write_accounts_yaml
    File.write(File.join(@dir, 'transactions.beancount'), '')

    @fake_repo = FakeRepo.new
    Frijolero::Web::App.repo = @fake_repo
  end

  def teardown
    restore_env('RACK_ENV', @previous_rack_env)
    restore_env('LEDGER_DIR', @previous_ledger_dir)
    Frijolero::Web::App.repo = nil
    FileUtils.remove_entry(@dir)
  end

  def app
    Frijolero::Web::App
  end

  def test_statement_page_shows_summary_transactions_and_fixme_count
    transactions = [
      { 'date' => '2025-08-01', 'description' => 'SIN CLASIFICAR', 'amount' => -100.0,
        'currency' => 'MXN', 'expense_account' => 'Expenses:FIXME' },
      { 'date' => '2025-08-02', 'description' => 'YA CLASIFICADA', 'amount' => -50.0,
        'currency' => 'MXN', 'expense_account' => 'Expenses:Food' }
    ]
    write_statement('AMEX', '2508',
                    json: { 'transactions' => transactions },
                    beancount: "2025-08-01 * \"x\"\n  Expenses:FIXME 100 MXN\n  Liabilities:Amex -100 MXN\n")

    get '/statements/AMEX/2508'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Found 2 transactions'
    assert_includes last_response.body, 'SIN CLASIFICAR'
    assert_includes last_response.body, 'YA CLASIFICADA'
    assert_includes last_response.body, '1 por clasificar'
    assert_equal 1, last_response.body.scan('Hacer regla').size
    assert_includes last_response.body, 'value="SIN CLASIFICAR"'
    assert_includes last_response.body, 'action="/statements/AMEX/2508/detail"'
    assert_includes last_response.body, 'Volver a correr las reglas'
    assert_includes last_response.body, 'href="/statements/AMEX/2508/pdf"'
    assert_includes last_response.body, 'Expenses:FIXME 100 MXN'
  end

  def test_fixme_count_comes_from_the_beancount_file
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [] },
                    beancount: <<~BEAN)
                      2025-08-01 * "x"
                        Expenses:FIXME 100 MXN
                        Expenses:FIXME 50 MXN
                        Expenses:FIXME 25 MXN
                        Liabilities:Amex -175 MXN
                    BEAN

    get '/statements/AMEX/2508'

    assert_includes last_response.body, '3 por clasificar'
  end

  def test_account_with_a_space_in_the_url
    write_accounts_yaml(extra: "BBVA TDC:\n  beancount_account: \"Assets:BBVA\"\n")
    write_statement('BBVA TDC', '2508', json: { 'transactions' => [] }, beancount: '')

    get '/statements/BBVA%20TDC/2508'

    assert_equal 200, last_response.status
    assert_includes last_response.body, '/statements/BBVA%20TDC/2508/pdf'
  end

  def test_non_default_pipeline_shows_summary_without_a_transactions_table
    write_statement('CETES', '2508',
                    json: { 'movements' => [{ 'date' => '2025-08-01', 'amount' => 100 }] },
                    beancount: '')

    get '/statements/CETES/2508'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'movements'
    refute_includes last_response.body, '<table'
  end

  def test_missing_beancount_file_is_404
    get '/statements/AMEX/2508'

    assert_equal 404, last_response.status
  end

  def test_unknown_account_is_404
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: '')

    get '/statements/HSBC/2508'

    assert_equal 404, last_response.status
  end

  def test_bad_period_is_404
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: '')

    get '/statements/AMEX/25-08'

    assert_equal 404, last_response.status
  end

  def test_missing_json_still_shows_the_beancount_preview
    paths = { beancount: Frijolero::Config.statement_path('AMEX', '2508', 'beancount') }
    FileUtils.mkdir_p(File.dirname(paths[:beancount]))
    File.write(paths[:beancount], 'algo en beancount')

    get '/statements/AMEX/2508'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'algo en beancount'
    refute_includes last_response.body, 'Found'
  end

  def test_notice_shows_the_detail_run_result
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: '')

    get '/statements/AMEX/2508', detailed: '2', remaining: '1'

    assert_includes last_response.body, '2 detalladas, 1 pendientes'
  end

  def test_description_with_script_tag_is_escaped
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [
                      { 'date' => '2025-08-01', 'description' => '<script>alert(1)</script>',
                        'amount' => -10.0, 'currency' => 'MXN', 'expense_account' => 'Expenses:FIXME' }
                    ] },
                    beancount: '')

    get '/statements/AMEX/2508'

    refute_includes last_response.body, '<script>alert(1)</script>'
    assert_includes last_response.body, '&lt;script&gt;alert(1)&lt;/script&gt;'
  end

  def test_post_detail_applies_rules_and_commits
    write_rules('AMEX', 'start_with' => { 'OXXO' => { 'payee' => 'Oxxo', 'account' => 'Expenses:Food' } })
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [] },
                    beancount: <<~BEAN)
                      2025-08-01 * "OXXO 123"
                        Liabilities:Amex -100 MXN
                        Expenses:FIXME

                      2025-08-02 * "UBER"
                        Liabilities:Amex -50 MXN
                        Expenses:FIXME
                    BEAN

    post '/statements/AMEX/2508/detail'

    assert_equal 303, last_response.status
    assert last_response.location.include?('detailed=1&remaining=1')
    assert_equal ['detail AMEX 2508'], @fake_repo.calls
  end

  def test_post_detail_with_nothing_to_detail_does_not_commit
    write_rules('AMEX', 'start_with' => { 'OXXO' => { 'payee' => 'Oxxo', 'account' => 'Expenses:Food' } })
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [] },
                    beancount: <<~BEAN)
                      2025-08-01 * "OXXO 123"
                        Expenses:Food -100 MXN
                        Liabilities:Amex

                      2025-08-02 * "UBER"
                        Liabilities:Amex -50 MXN
                        Expenses:FIXME
                    BEAN

    post '/statements/AMEX/2508/detail'

    assert_equal 303, last_response.status
    assert last_response.location.include?('detailed=0&remaining=1')
    assert_empty @fake_repo.calls
  end

  def test_post_detail_no_rules_returns_422
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: '')

    post '/statements/AMEX/2508/detail'

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'No hay reglas'
  end

  def test_post_detail_unknown_account_returns_404
    write_rules('AMEX', {})

    post '/statements/HSBC/2508/detail'

    assert_equal 404, last_response.status
    assert_includes last_response.body, 'Cuenta desconocida'
  end

  def test_post_detail_missing_beancount_returns_404
    write_rules('AMEX', {})

    post '/statements/AMEX/2508/detail'

    assert_equal 404, last_response.status
    assert_includes last_response.body, 'No existe ese estado'
  end

  def test_post_detail_redirect_shows_notice
    write_rules('AMEX', 'start_with' => { 'OXXO' => { 'payee' => 'Oxxo', 'account' => 'Expenses:Food' } })
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [] },
                    beancount: <<~BEAN)
                      2025-08-01 * "OXXO 123"
                        Liabilities:Amex -100 MXN
                        Expenses:FIXME

                      2025-08-02 * "UBER"
                        Liabilities:Amex -50 MXN
                        Expenses:FIXME
                    BEAN

    post '/statements/AMEX/2508/detail'
    follow_redirect!

    assert_includes last_response.body, '1 detalladas, 1 pendientes'
  end

  def test_fintual_statement_shows_summary_without_the_table
    write_accounts_yaml(extra: "Fintual:\n  beancount_account: \"Assets:Fintual\"\n  converter_type: fintual\n")
    write_statement('Fintual', '2608',
                    json: { 'transactions' => [{ 'trade_date' => '2026-08-04', 'transaction_type' => 'buy',
                                                 'reported_amount' => 1500.0, 'description' => 'Compra' }] },
                    beancount: "2026-08-04 * \"Compra\"\n  Assets:Fintual  1 FUND {1500.00 MXN}\n  Assets:BBVA\n")

    get '/statements/Fintual/2608'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Found 1 transactions'
    refute_includes last_response.body, '<th>Fecha</th>'
  end

  def test_default_row_without_amount_does_not_crash
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [{ 'date' => '2025-08-03', 'description' => 'X', 'amount' => nil }] },
                    beancount: "2025-08-03 * \"X\"\n  Liabilities:Amex  -1.00 MXN\n  Expenses:FIXME\n")

    get '/statements/AMEX/2508'

    assert_equal 200, last_response.status
  end

  private

  def write_accounts_yaml(extra: '')
    File.write(File.join(@dir, 'config', 'accounts.yaml'), <<~YAML)
      AMEX:
        beancount_account: "Liabilities:Amex"
      CETES:
        beancount_account: "Assets:CETES"
        converter_type: cetes_directo
      #{extra}
    YAML
  end

  def write_statement(account, period, json:, beancount:)
    paths = { json: Frijolero::Config.statement_path(account, period, 'json'),
              beancount: Frijolero::Config.statement_path(account, period, 'beancount') }
    FileUtils.mkdir_p(File.dirname(paths[:beancount]))
    File.write(paths[:json], JSON.generate(json))
    File.write(paths[:beancount], beancount)
  end

  def write_rules(account, rules)
    rules_dir = File.join(@dir, 'config', 'rules')
    FileUtils.mkdir_p(rules_dir)
    File.write(File.join(rules_dir, "#{account}.yaml"), YAML.dump(rules))
  end

  def restore_env(key, previous_value)
    if previous_value.nil?
      ENV.delete(key)
    else
      ENV[key] = previous_value
    end
  end
end
