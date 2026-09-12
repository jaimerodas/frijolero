# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'fileutils'
require 'json'

class StatementsTest < Minitest::Test
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
    @dir = Dir.mktmpdir
    @previous_ledger_dir = ENV.fetch('LEDGER_DIR', nil)
    ENV['LEDGER_DIR'] = @dir
    FileUtils.mkdir_p(File.join(@dir, 'config'))
    write_accounts_yaml
    File.write(File.join(@dir, 'transactions.beancount'), '')

    @fake_repo = FakeRepo.new
    Frijolero::App.repo = @fake_repo
  end

  def teardown
    restore_env('LEDGER_DIR', @previous_ledger_dir)
    Frijolero::App.repo = nil
    FileUtils.remove_entry(@dir)
  end

  def app
    Frijolero::App
  end

  def test_statement_page_reads_the_rows_from_the_beancount_file
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [{ 'date' => '2025-08-01', 'description' => 'DEL JSON' }] },
                    beancount: <<~BEAN)
                      2025-08-01 * "SIN CLASIFICAR"
                        Liabilities:Amex  -100.00 MXN
                        Expenses:FIXME

                      2025-08-02 * "Comida" "Tacos"
                        source_desc: "YA CLASIFICADA"
                        Liabilities:Amex  -50.00 MXN
                        Expenses:Food

                      2025-08-03 * "PAGO"
                        Liabilities:Amex  75.00 MXN
                        Assets:BBVA
                    BEAN

    get '/accounts/AMEX/2508'

    assert_equal 200, last_response.status
    refute_includes last_response.body, 'DEL JSON'
    assert_includes last_response.body, '3 movimientos'
    assert_includes last_response.body, '2 cargos</span><data class="debit" value="-150.0">-150.00 MXN'
    assert_includes last_response.body, '1 abono</span><data class="credit" value="75.0">+75.00 MXN'
    assert_includes last_response.body, '1 sin clasificar'
    assert_equal 1, last_response.body.scan('Hacer regla').size
    assert_includes last_response.body, 'value="SIN CLASIFICAR"'
    assert_includes last_response.body, 'value="-100.0"'
    assert_includes last_response.body, 'YA CLASIFICADA'
    assert_includes last_response.body, '<span>Comida</span>'
    assert_includes last_response.body, '<span class="note">Tacos</span>'
    assert_includes last_response.body, '<code>Expenses:Food</code>'
    assert_includes last_response.body, 'action="/accounts/AMEX/2508/detail"'
    assert_includes last_response.body, 'Aplicar reglas'
    assert_includes last_response.body, 'href="/accounts/AMEX/2508/pdf"'
    assert_includes last_response.body,
                    '<span class="bc-account bc-fixme">Expenses:FIXME</span>'
  end

  def test_fully_classified_statement_has_no_rules_button
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [] },
                    beancount: "2025-08-01 * \"x\"\n  Liabilities:Amex -100 MXN\n  Expenses:Food\n")

    get '/accounts/AMEX/2508'

    assert_includes last_response.body, 'Todo clasificado'
    refute_includes last_response.body, 'Aplicar reglas'
    refute_includes last_response.body, 'Hacer regla'
  end

  def test_period_links_to_the_neighbouring_statements
    %w[2507 2508 2509].each { |p| write_statement('AMEX', p, json: { 'transactions' => [] }, beancount: '') }

    get '/accounts/AMEX/2508'

    assert_includes last_response.body, '<a href="/accounts/AMEX/2507" aria-label="Anterior">'
    assert_includes last_response.body, '<a href="/accounts/AMEX/2509" aria-label="Siguiente">'

    get '/accounts/AMEX/2509'

    refute_includes last_response.body, 'aria-label="Siguiente"'
    assert_includes last_response.body, '<a href="/accounts/AMEX/2508" aria-label="Anterior">'
  end

  def test_flagged_transaction_shows_its_flag
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [] },
                    beancount: "2025-08-01 ! \"DUDA\"\n  Liabilities:Amex -100 MXN\n  Expenses:Food\n")

    get '/accounts/AMEX/2508'

    assert_includes last_response.body, 'DUDA'
    assert_includes last_response.body, '<span class="flag">!</span>'
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

    get '/accounts/AMEX/2508'

    assert_includes last_response.body, '3 sin clasificar'
  end

  def test_account_with_a_space_in_the_url
    write_accounts_yaml(extra: "BBVA TDC:\n  beancount_account: \"Assets:BBVA\"\n")
    write_statement('BBVA TDC', '2508', json: { 'transactions' => [] }, beancount: '')

    get '/accounts/BBVA%20TDC/2508'

    assert_equal 200, last_response.status
    assert_includes last_response.body, '/accounts/BBVA%20TDC/2508/pdf'
  end

  def test_non_default_pipeline_shows_summary_without_a_transactions_table
    write_statement('CETES', '2508',
                    json: { 'movements' => [{ 'date' => '2025-08-01', 'amount' => 100 }] },
                    beancount: '')

    get '/accounts/CETES/2508'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'movements'
    refute_includes last_response.body, '<table'
    refute_includes last_response.body, 'Aplicar reglas'
  end

  def test_post_detail_on_an_account_without_rules_is_404
    write_statement('CETES', '2508', json: { 'movements' => [] }, beancount: '')
    write_rules('CETES', 'start_with: {}')

    post '/accounts/CETES/2508/detail'

    assert_equal 404, last_response.status
  end

  def test_missing_beancount_file_is_404
    get '/accounts/AMEX/2508'

    assert_equal 404, last_response.status
  end

  def test_unknown_account_is_404
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: '')

    get '/accounts/HSBC/2508'

    assert_equal 404, last_response.status
  end

  def test_bad_period_is_404
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: '')

    get '/accounts/AMEX/25-08'

    assert_equal 404, last_response.status
  end

  def test_missing_json_still_shows_the_beancount_preview
    paths = { beancount: Frijolero::Config.statement_path('AMEX', '2508', 'beancount') }
    FileUtils.mkdir_p(File.dirname(paths[:beancount]))
    File.write(paths[:beancount], 'algo en beancount')

    get '/accounts/AMEX/2508'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'algo en beancount'
    refute_includes last_response.body, 'Found'
  end

  def test_hacer_regla_sends_the_statement_path_along
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [{ 'date' => '2025-08-01', 'description' => 'OXXO', 'amount' => -100 }] },
                    beancount: "2025-08-01 * \"OXXO\"\n  Expenses:FIXME 100 MXN\n  Liabilities:Amex -100 MXN\n")
    get '/accounts/AMEX/2508'

    assert_includes last_response.body, '<input type="hidden" name="back" value="/accounts/AMEX/2508">'
  end

  def test_notice_after_saving_rules_asks_to_run_them
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: '')
    get '/accounts/AMEX/2508', rules: '1'

    assert_includes last_response.body, 'Reglas guardadas. Aplica las reglas para usarlas.'
  end

  def test_notice_shows_the_detail_run_result
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: '')

    get '/accounts/AMEX/2508', detailed: '2', remaining: '1'

    assert_includes last_response.body, '2 clasificadas, 1 sin clasificar'
  end

  def test_description_with_script_tag_is_escaped
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [] },
                    beancount: "2025-08-01 * \"<script>alert(1)</script>\"\n  Liabilities:Amex -10 MXN\n  Expenses:X")

    get '/accounts/AMEX/2508'

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

    post '/accounts/AMEX/2508/detail'

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

    post '/accounts/AMEX/2508/detail'

    assert_equal 303, last_response.status
    assert last_response.location.include?('detailed=0&remaining=1')
    assert_empty @fake_repo.calls
  end

  def test_post_detail_no_rules_returns_422
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: '')

    post '/accounts/AMEX/2508/detail'

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'No hay reglas'
  end

  def test_post_detail_unknown_account_returns_404
    write_rules('AMEX', {})

    post '/accounts/HSBC/2508/detail'

    assert_equal 404, last_response.status
    assert_includes last_response.body, 'Cuenta desconocida'
  end

  def test_post_detail_missing_beancount_returns_404
    write_rules('AMEX', {})

    post '/accounts/AMEX/2508/detail'

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

    post '/accounts/AMEX/2508/detail'
    follow_redirect!

    assert_includes last_response.body, '1 clasificadas, 1 sin clasificar'
  end

  def test_fintual_statement_shows_summary_without_the_table
    write_accounts_yaml(extra: "Fintual:\n  beancount_account: \"Assets:Fintual\"\n  converter_type: fintual\n")
    write_statement('Fintual', '2608',
                    json: { 'transactions' => [{ 'trade_date' => '2026-08-04', 'transaction_type' => 'buy',
                                                 'reported_amount' => 1500.0, 'description' => 'Compra' }] },
                    beancount: "2026-08-04 * \"Compra\"\n  Assets:Fintual  1 FUND {1500.00 MXN}\n  Assets:BBVA\n")

    get '/accounts/Fintual/2608'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Found 1 transactions'
    refute_includes last_response.body, '<th>Fecha</th>'
  end

  def test_row_whose_source_posting_has_no_amount_takes_it_from_the_other_side
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [] },
                    beancount: <<~BEAN)
                      2025-08-03 * "X"
                        Liabilities:Amex
                        Expenses:FIXME  1.00 MXN

                      2025-08-04 * "Y"
                        Liabilities:Amex
                        Expenses:FIXME
                    BEAN

    get '/accounts/AMEX/2508'

    assert_equal 200, last_response.status
    assert_includes last_response.body, '-1.00 MXN'
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
