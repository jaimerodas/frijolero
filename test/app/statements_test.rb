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
    @dir = enter_test_ledger
    write_accounts_yaml
    File.write(File.join(@dir, 'main.beancount'), '')

    @fake_repo = FakeRepo.new
    Frijolero::App.repo = @fake_repo
  end

  def teardown
    leave_test_ledger
    Frijolero::App.repo = nil
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

    write_rules('AMEX', 'start_with' => {})
    get '/accounts/AMEX/2508'

    assert_equal 200, last_response.status
    refute_includes last_response.body, 'DEL JSON'
    # The debit and credit sums close the list.
    assert_match(%r{</ol>\s*<p class="totals"><span class="count">2 cargos</span>}, last_response.body)
    assert_includes last_response.body, '2 cargos</span><data class="debit" value="-150.0">-150.00 MXN'
    assert_includes last_response.body, '1 abono</span><data class="credit" value="75.0">+75.00 MXN'
    assert_includes last_response.body, 'aria-label="Revisar, 1 sin clasificar"'
    assert_equal 1, last_response.body.scan('Hacer regla').size
    assert_includes last_response.body, 'value="SIN CLASIFICAR"'
    assert_includes last_response.body, 'value="-100.0"'
    assert_includes last_response.body, 'YA CLASIFICADA'
    assert_includes last_response.body, '<span>Comida</span>'
    assert_includes last_response.body, '<span class="note">Tacos</span>'
    assert_includes last_response.body, '<code>Expenses:Food</code>'

    get '/accounts/AMEX/2508/beancount/edit'
    assert_includes last_response.body, '<span class="bc-account bc-fixme">Expenses:FIXME</span>'
  end

  # One row: the account and the month are the title, then Revisar with its count and the toggle of the views.
  def test_the_statement_head_is_the_title_revisar_and_the_views
    write_statement('AMEX', '2508', json: {}, beancount: STATEMENT_TEXT.sub('Expenses:Food', 'Expenses:FIXME'))
    write_rules('AMEX', 'start_with' => {})

    get '/accounts/AMEX/2508'

    body = last_response.body
    head = body[/<div class="account-head">.*?(?=<section id="entries">)/m]
    assert_match(%r{<h1>AMEX</h1>\s*<form method="get" action="/accounts/AMEX/2508" class="period">}, head)
    assert_includes head, '<a class="button primary" href="/accounts/AMEX/2508/review" ' \
                          'aria-label="Revisar, 1 sin clasificar">Revisar<span class="tally">1</span></a>'
    assert_includes head, '<a href="/accounts/AMEX/2508" aria-current="true">Ver</a>'
    assert_includes head, '<a href="/accounts/AMEX/2508/beancount/edit">Editar</a>'
    assert_includes head, '<a href="/accounts/AMEX/2508/pdf" target="_blank" ' \
                          'aria-label="PDF (se abre en otra pestaña)">PDF ↗</a>'
    refute_includes body, 'class="toolbar"'
    # The rules touch only the unclassified rows, so their button is in Revisar.
    refute_includes body, 'Aplicar reglas'
  end

  # Revisar is a mode: the month is plain text, and the head offers the rules and the way out.
  def test_revisar_has_the_rules_and_cancelar_in_the_head
    write_statement('AMEX', '2508', json: {}, beancount: STATEMENT_TEXT.sub('Expenses:Food', 'Expenses:FIXME'))
    write_rules('AMEX', 'start_with' => {})

    get '/accounts/AMEX/2508/review'

    body = last_response.body
    assert_match(%r{<h1>AMEX</h1>\s*<span class="month">agosto 2025</span>}, body)
    refute_includes body, 'class="period"'
    refute_includes body, 'aria-label="Vistas"'
    assert_includes body, '<form method="post" action="/accounts/AMEX/2508/detail">' \
                          '<button type="submit">Aplicar reglas</button></form>'
    assert_includes body, '<a href="/accounts/AMEX/2508">Cancelar</a>'
  end

  def test_rules_button_needs_a_rules_file
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: <<~BEAN)
      2025-08-01 * "SIN CLASIFICAR"
        Liabilities:Amex  -100.00 MXN
        Expenses:FIXME
    BEAN

    get '/accounts/AMEX/2508/review'

    assert_includes last_response.body, '>Cancelar</a>'
    refute_includes last_response.body, 'Aplicar reglas'
  end

  def test_fully_classified_statement_has_no_rules_button
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [] },
                    beancount: "2025-08-01 * \"x\"\n  Liabilities:Amex -100 MXN\n  Expenses:Food\n")

    get '/accounts/AMEX/2508'

    refute_includes last_response.body, 'Aplicar reglas'
    refute_includes last_response.body, 'Hacer regla'
  end

  def test_the_period_menu_lists_the_statements_newest_first_then_the_arrows
    %w[2507 2508 2509].each { |p| write_statement('AMEX', p, json: { 'transactions' => [] }, beancount: '') }

    get '/accounts/AMEX/2508'

    body = last_response.body
    assert_equal %w[2509 2508 2507], body.scan(/<option value="(\d{4})"/).flatten
    assert_includes body, '<option value="2508" selected>agosto 2025</option>'
    assert_match(%r{</select></span>\s*<a href="/accounts/AMEX/2507" aria-label="Anterior">}, body)
    assert_includes body, '<a href="/accounts/AMEX/2509" aria-label="Siguiente">'

    get '/accounts/AMEX/2509'

    refute_includes last_response.body, 'aria-label="Siguiente"'
    assert_includes last_response.body, '<a href="/accounts/AMEX/2508" aria-label="Anterior">'
  end

  # The menu submits ?period= to the page it is on; the arrows and the menu keep the view.
  def test_another_period_lands_on_the_same_view_of_that_statement
    %w[2507 2508].each { |p| write_statement('AMEX', p, json: { 'transactions' => [] }, beancount: '') }

    get '/accounts/AMEX/2508/beancount/edit'

    assert_includes last_response.body,
                    '<form method="get" action="/accounts/AMEX/2508/beancount/edit" class="period">'
    assert_includes last_response.body, '<a href="/accounts/AMEX/2507/beancount/edit" aria-label="Anterior">'

    get '/accounts/AMEX/2508/beancount/edit', period: '2507'

    assert last_response.redirect?
    assert_equal '/accounts/AMEX/2507/beancount/edit', URI(last_response.location).path

    get '/accounts/AMEX/2508', period: '../x'

    assert_equal 200, last_response.status
  end

  def test_flagged_transaction_shows_its_flag
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [] },
                    beancount: "2025-08-01 ! \"DUDA\"\n  Liabilities:Amex -100 MXN\n  Expenses:Food\n")

    get '/accounts/AMEX/2508'

    assert_includes last_response.body, 'DUDA'
    assert_includes last_response.body, '<span class="flag">!</span>'
  end

  # Revisar takes a row with one FIXME posting. A split with three is a hand edit, so no Revisar.
  def test_a_split_with_several_fixme_postings_gets_no_revisar
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

    assert_equal 3, last_response.body.scan('<span class="status missing">sin clasificar</span>').size
    refute_includes last_response.body, '/review'
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

  STATEMENT_TEXT = "2025-08-01 * \"X\"\n  Liabilities:Amex  -1 MXN\n  Expenses:Food\n"

  # Each view has its own URL, so a reload or a link lands on the view it names.
  def test_ver_shows_the_movements
    write_statement('AMEX', '2508', json: {}, beancount: STATEMENT_TEXT)

    get '/accounts/AMEX/2508'

    body = last_response.body
    assert_includes body, '<a href="/accounts/AMEX/2508" aria-current="true">Ver</a>'
    assert_includes body, '<ol class="ledger">'
    refute_includes body, 'class="code-box"'
  end

  # Only an edit needed the text, so the read-only view gave way to the editor. A bookmark lands there.
  def test_the_old_beancount_view_redirects_to_the_editor
    write_statement('AMEX', '2508', json: {}, beancount: STATEMENT_TEXT)

    get '/accounts/AMEX/2508/beancount'

    assert last_response.redirect?
    assert_equal '/accounts/AMEX/2508/beancount/edit', URI(last_response.location).path
  end

  # Editar opens the editor on the file, and Cancelar and the save go back to Ver. The editor has its
  # own yellow Guardar, so Revisar waits.
  def test_editar_opens_the_editor_and_returns_to_ver
    write_statement('AMEX', '2508', json: {}, beancount: STATEMENT_TEXT.sub('Expenses:Food', 'Expenses:FIXME'))

    get '/accounts/AMEX/2508/beancount/edit'

    body = last_response.body
    assert_includes body, '<a href="/accounts/AMEX/2508/beancount/edit" aria-current="true">Editar</a>'
    assert_includes body, '<form class="code" method="post" action="/edit" data-back="/accounts/AMEX/2508">'
    assert_includes body, '<input type="hidden" name="file" value="accounts/AMEX/AMEX 2508.beancount">'
    assert_includes body, '<span class="line" id="L2">  <span class="bc-account">Liabilities:Amex</span>'
    refute_includes body, 'class="edit-file"'
    refute_includes body, '/review'
    refute_includes body, '<ol class="ledger">'
  end

  def test_after_a_save_ver_says_guardado
    write_statement('AMEX', '2508', json: {}, beancount: '')

    get '/accounts/AMEX/2508', saved: 1

    assert_includes last_response.body, '<p class="notice">Guardado</p>'
  end

  def test_the_views_of_an_unknown_statement_are_404
    get '/accounts/AMEX/2508/beancount/edit'
    assert_equal 404, last_response.status

    get '/accounts/AMEX/2508/review'
    assert_equal 404, last_response.status
  end

  # An investment statement has no movements: its Ver is the summary and the text, read only.
  def test_non_default_pipeline_shows_the_text_in_ver
    write_statement('CETES', '2508', json: { 'movements' => [] }, beancount: '')

    get '/accounts/CETES/2508'

    body = last_response.body
    assert_includes body, '<a href="/accounts/CETES/2508" aria-current="true">Ver</a>'
    assert_includes body, '<a href="/accounts/CETES/2508/beancount/edit">Editar</a>'
    assert_includes body, '<a href="/accounts/CETES/2508/pdf" target="_blank"'
    refute_includes body, 'class="edit-file"'
    assert_includes body, '<input type="hidden" name="file" value="accounts/CETES/CETES 2508.beancount">'
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

    get '/accounts/AMEX/2508/beancount/edit'

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

  # The rules editor sends the person to Revisar, where Aplicar reglas is.
  def test_notice_after_saving_rules_asks_to_run_them
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: '')
    get '/accounts/AMEX/2508/review', rules: '1'

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
    assert_equal '/accounts/AMEX/2508/review?detailed=1&remaining=1', URI(last_response.location).request_uri
    assert_equal ['detail AMEX 2508'], @fake_repo.calls
  end

  # With nothing left to classify, Revisar would be empty: the run lands on Ver.
  def test_post_detail_that_classifies_everything_returns_to_ver
    write_rules('AMEX', 'start_with' => { 'OXXO' => { 'payee' => 'Oxxo', 'account' => 'Expenses:Food' } })
    write_statement('AMEX', '2508', json: { 'transactions' => [] },
                                    beancount: "2025-08-01 * \"OXXO 1\"\n  Liabilities:Amex -1 MXN\n  Expenses:FIXME\n")

    post '/accounts/AMEX/2508/detail'

    assert_equal '/accounts/AMEX/2508?detailed=1&remaining=0', URI(last_response.location).request_uri
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

  def test_statement_page_embeds_the_ledger_accounts_for_the_autocomplete
    File.write(File.join(@dir, 'main.beancount'), "2024-01-01 open Expenses:Food\n")
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: '')

    get '/accounts/AMEX/2508/beancount/edit'

    assert_includes last_response.body, '<script type="application/json" class="accounts">["Expenses:Food"]</script>'
  end

  # The gutter fits three digits; a file past line 999 widens it for its own numbers.
  def test_the_gutter_widens_only_past_line_999
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: "; x\n" * 998)
    get '/accounts/AMEX/2508/beancount/edit'
    assert_includes last_response.body, '<div class="surface"><pre>'

    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: "; x\n" * 999)
    get '/accounts/AMEX/2508/beancount/edit'
    assert_includes last_response.body, '<div class="surface" style="--digits: 4"><pre>'
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

  def test_the_date_of_a_movement_opens_the_edit_dialog
    write_statement('AMEX', '2508',
                    json: { 'transactions' => [] },
                    beancount: "2025-08-01 * \"OXXO\"\n  Liabilities:Amex -100 MXN\n  Expenses:Food\n")

    get '/accounts/AMEX/2508'

    body = last_response.body
    assert_includes body, '<time datetime="2025-08-01"><button type="button" class="edit" ' \
                          'data-file="accounts/AMEX/AMEX 2508.beancount" data-line="1">2025-08-01</button></time>'
    refute_includes body, 'data-statement'
    assert_includes body, '<dialog id="edit">'
  end

  def test_the_editor_has_no_edit_dialog
    write_statement('AMEX', '2508', json: {}, beancount: STATEMENT_TEXT)

    get '/accounts/AMEX/2508/beancount/edit'

    refute_includes last_response.body, '<dialog id="edit">'
  end

  def test_no_revisar_when_everything_is_classified
    write_statement('AMEX', '2508', json: { 'transactions' => [] }, beancount: STATEMENT_TEXT)

    get '/accounts/AMEX/2508'

    body = last_response.body
    refute_includes body, '/review'
    refute_includes body, 'Todo clasificado'
  end

  def test_non_default_pipeline_keeps_the_plain_status_span
    write_statement('CETES', '2508', json: { 'movements' => [] }, beancount: <<~BEAN)
      2025-08-01 * "X"
        Expenses:FIXME 100 MXN
        Assets:CETES -100 MXN
    BEAN

    get '/accounts/CETES/2508'

    body = last_response.body
    assert_includes body, '<span class="status missing">1 sin clasificar</span>'
    refute_includes body, '/review'
  end

  # Under /l/<id>/ every link stays in the ledger. The hidden `back` stays plain, as back_path
  # checks it; data-back is where the editor's Cancelar goes, so it is a link.
  def test_the_statement_pages_link_inside_the_ledger
    write_rules('AMEX', 'start_with' => {})
    fixme = STATEMENT_TEXT.sub('Expenses:Food', 'Expenses:FIXME')
    %w[2507 2508 2509].each { |p| write_statement('AMEX', p, json: {}, beancount: fixme) }

    %w[/accounts/AMEX/2508 /accounts/AMEX/2508/review /accounts/AMEX/2508/beancount/edit].each do |path|
      get path, {}, 'SCRIPT_NAME' => LEDGER_ROOT

      assert_ledger_links last_response.body
    end
    assert_includes last_response.body, %(data-back="#{LEDGER_ROOT}/accounts/AMEX/2508")

    get '/accounts/AMEX/2508/review', {}, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_includes last_response.body, 'Aplicar reglas'

    get '/accounts/AMEX/2508', {}, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_includes last_response.body, '<input type="hidden" name="back" value="/accounts/AMEX/2508">'
  end

  def test_the_file_page_of_a_statement_links_inside_the_ledger
    write_statement('AMEX', '2508', json: {}, beancount: STATEMENT_TEXT)

    get '/files/accounts/AMEX/AMEX%202508.beancount', {}, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_includes last_response.body, 'Ver estado de cuenta'
    assert_ledger_links last_response.body
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
end
