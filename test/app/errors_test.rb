# frozen_string_literal: true

require 'test_helper'
require 'rack/test'

# App.ledger_errors: the check behind the badge, the error page and the red lines.
class LedgerErrorsTest < Minitest::Test
  include TestHelpers

  ERROR = { code: 'E1001', message: 'Account Expenses:Nope was never opened',
            file: 'main.beancount', line: 2, end_line: 3 }.freeze

  class CountingReports
    attr_accessor :errors, :failure
    attr_reader :calls

    def initialize
      @calls = 0
      @errors = []
    end

    def check
      @calls += 1
      raise Frijolero::Reports::Error, failure if failure

      errors
    end
  end

  def setup
    @reports = CountingReports.new
    Frijolero::App.reports = @reports
  end

  def teardown
    Frijolero::App.reports = nil
  end

  def with_main
    with_ledger_dir do |dir|
      path = File.join(dir, 'main.beancount')
      File.write(path, "2026-01-01 open Assets:Bank\n")
      yield path
    end
  end

  def test_the_check_runs_again_only_when_a_ledger_file_changes
    with_main do |path|
      @reports.errors = [ERROR]

      assert_equal [ERROR], Frijolero::App.ledger_errors
      assert_equal [ERROR], Frijolero::App.ledger_errors
      assert_equal 1, @reports.calls

      File.utime(Time.now + 5, Time.now + 5, path)
      Frijolero::App.ledger_errors
      assert_equal 2, @reports.calls
    end
  end

  def test_a_new_ledger_file_runs_the_check_again
    with_main do |path|
      Frijolero::App.ledger_errors
      File.write(File.join(File.dirname(path), 'prices.beancount'), '')
      Frijolero::App.ledger_errors

      assert_equal 2, @reports.calls
    end
  end

  def test_a_check_that_fails_is_nil
    with_main do
      @reports.failure = 'rustledger no está instalado'

      assert_nil Frijolero::App.ledger_errors
    end
  end
end

# The topbar badge and the /errors page: web tests over the routes.
class ErrorsPageTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  def app = Frijolero::App

  def setup
    @dir = enter_test_ledger
    File.write(File.join(@dir, 'main.beancount'), "2026-01-01 open Assets:BBVA\n")
    @reports = LedgerErrorsTest::CountingReports.new
    Frijolero::App.reports = @reports
  end

  def teardown
    leave_test_ledger
    Frijolero::App.reports = nil
  end

  def test_badge_shows_the_count_and_links_to_errors
    @reports.errors = [LedgerErrorsTest::ERROR]

    get '/'

    link = last_response.body[%r{<a class="errors".*?</a>}m]
    refute_nil link
    assert_includes link, 'href="/errors"'
    assert_includes link, 'aria-label="1 error"'
    assert_includes link, '<span>1</span>'
    refute_includes link, 'aria-current'
  end

  def test_badge_is_plural_for_more_than_one_error
    @reports.errors = [LedgerErrorsTest::ERROR, LedgerErrorsTest::ERROR.merge(line: 9)]

    get '/'

    assert_includes last_response.body[%r{<a class="errors".*?</a>}m], 'aria-label="2 errores"'
  end

  def test_badge_is_hidden_when_the_ledger_is_clean
    @reports.errors = []

    get '/'

    refute_includes last_response.body, 'class="errors"'
  end

  def test_badge_is_hidden_when_the_check_failed
    @reports.failure = 'rustledger no está instalado'

    get '/'

    refute_includes last_response.body, 'class="errors"'
  end

  def test_errors_page_marks_its_own_badge_as_current
    @reports.errors = [LedgerErrorsTest::ERROR]

    get '/errors'

    assert_includes last_response.body, 'title="1 error" aria-current="page"><span>1</span></a>'
  end

  def test_errors_page_says_when_the_ledger_could_not_be_checked
    @reports.failure = 'rustledger no está instalado'

    get '/errors'

    assert_equal 200, last_response.status
    assert_includes last_response.body, '<h1>Errores del ledger</h1>'
    assert_includes last_response.body, 'No se pudo revisar el ledger'
  end

  def test_errors_page_says_when_the_ledger_is_clean
    @reports.errors = []

    get '/errors'

    assert_includes last_response.body, 'Sin errores.'
    refute_includes last_response.body, '<section class="ledger-errors">'
  end

  def test_errors_page_groups_by_file_with_line_and_statement_links
    statement_beancount = Frijolero::Config.statement_path('AMEX', '2508', 'beancount')
    FileUtils.mkdir_p(File.dirname(statement_beancount))
    File.write(statement_beancount, '')
    @reports.errors = [
      { code: 'E1001', message: 'Account Expenses:Nope was never opened', file: 'main.beancount', line: 2,
        end_line: 3 },
      { code: 'E1003', message: 'Unbalanced', file: 'accounts/AMEX/AMEX 2508.beancount', line: 4, end_line: 5 }
    ]

    get '/errors'

    body = last_response.body
    assert_includes body, '<a class="path" href="/files/main.beancount">main.beancount</a>'
    assert_includes body, '<a href="/files/main.beancount#L2">línea 2</a>'
    assert_includes body, '<a class="path" href="/files/accounts/AMEX/AMEX%202508.beancount">' \
                          'accounts/AMEX/AMEX 2508.beancount</a>'
    assert_includes body, '<a href="/files/accounts/AMEX/AMEX%202508.beancount#L4">línea 4</a>'
    assert_includes body, '<a href="/accounts/AMEX/2508">Ver estado de cuenta</a>'
    assert_includes body, '<code>E1001</code> Account Expenses:Nope was never opened'
  end

  def test_a_failed_balance_links_into_the_journal
    File.write(File.join(@dir, 'main.beancount'), <<~BEAN)
      2026-01-01 open Assets:BBVA
      2027-01-01 balance Assets:BBVA  74819.37 MXN
    BEAN
    @reports.errors = [{ code: 'E2001',
                         message: 'Balance failed for Assets:BBVA: expected 74819.37 MXN, got 74719.36 MXN',
                         file: 'main.beancount', line: 2, end_line: 3 }]

    get '/errors'

    assert_includes last_response.body, '<a href="/journal?account=Assets%3ABBVA&period=2026">Ver en el diario</a>'
    assert_includes last_response.body, 'Saldo de Assets:BBVA: el ledger suma 74,719.36 MXN, ' \
                                        '100.01 menos que el saldo de 74,819.37.'
  end

  # Served under /l/<id>: the file, statement and journal links stay in that ledger.
  def test_errors_page_links_inside_the_ledger
    File.write(File.join(@dir, 'main.beancount'), <<~BEAN)
      2026-01-01 open Assets:BBVA
      2027-01-01 balance Assets:BBVA  74819.37 MXN
    BEAN
    @reports.errors = [{ code: 'E2001',
                         message: 'Balance failed for Assets:BBVA: expected 74819.37 MXN, got 74719.36 MXN',
                         file: 'main.beancount', line: 2, end_line: 3 },
                       { code: 'E1003', message: 'Unbalanced', file: 'accounts/AMEX/AMEX 2508.beancount', line: 4,
                         end_line: 5 }]

    get '/errors', {}, 'SCRIPT_NAME' => LEDGER_ROOT

    body = last_response.body
    assert_includes body, %(<a href="#{LEDGER_ROOT}/journal?account=Assets%3ABBVA&period=2026">Ver en el diario</a>)
    assert_includes body, %(<a href="#{LEDGER_ROOT}/accounts/AMEX/2508">Ver estado de cuenta</a>)
    assert_ledger_links body
  end

  def test_a_non_balance_error_has_no_journal_link
    @reports.errors = [LedgerErrorsTest::ERROR]

    get '/errors'

    refute_includes last_response.body, 'Ver en el diario'
  end
end

# The read mode of a Beancount file: the error line marked, and the list under it.
class ReadModeErrorsTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  def app = Frijolero::App

  def setup
    @dir = enter_test_ledger
    File.write(File.join(@dir, 'config', 'accounts.yaml'), "AMEX:\n  beancount_account: \"Liabilities:Amex\"\n")
    File.write(File.join(@dir, 'main.beancount'), '')
    @reports = LedgerErrorsTest::CountingReports.new
    Frijolero::App.reports = @reports
  end

  def teardown
    leave_test_ledger
    Frijolero::App.reports = nil
  end

  def write_statement(account, period, beancount)
    path = Frijolero::Config.statement_path(account, period, 'beancount')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, beancount)
    File.write(Frijolero::Config.statement_path(account, period, 'json'), '{"transactions":[]}')
  end

  # The whole directive is marked, its postings too, where the culprit often is; the next one is not.
  def test_statement_page_marks_the_directive_in_error_and_lists_it
    write_statement('AMEX', '2508', "2025-08-01 * \"X\"\n  Liabilities:Amex -1 MXN\n  Expenses:Food\n" \
                                    "2025-08-02 * \"Y\"\n  Liabilities:Amex -2 MXN\n  Expenses:Food\n")
    @reports.errors = [{ code: 'E1001', message: 'No abierta', file: 'accounts/AMEX/AMEX 2508.beancount', line: 1,
                         end_line: 4 }]

    get '/accounts/AMEX/2508/beancount'

    body = last_response.body
    assert_includes body, '<span class="line err" id="L1" title="E1001 No abierta">'
    assert_includes body, '<span class="line err" id="L3" title="E1001 No abierta">'
    assert_includes body, '<span class="line" id="L4">'
    assert_includes body, '<li>E1001 No abierta <a href="#L1">accounts/AMEX/AMEX 2508.beancount:1</a></li>'
  end

  def test_a_file_with_no_errors_has_a_hidden_empty_list
    write_statement('AMEX', '2508', "2025-08-01 * \"X\"\n  Liabilities:Amex -1 MXN\n  Expenses:Food\n")
    @reports.errors = []

    get '/accounts/AMEX/2508/beancount'

    assert_includes last_response.body, '<ul class="errors error" role="alert" hidden></ul>'
  end
end

# A ledger that LedgerFiles refuses, with the real Reports: every page says why, none is a 500,
# and rledger never runs on it.
class UnsafeLedgerPagesTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  MAIN = %(2026-01-01 open Assets:BBVA\ninclude "/etc/hosts"\n)

  class FakeRepo
    attr_reader :messages

    def initialize = @messages = []
    def commit_and_push(message) = @messages << message
    def head = nil
  end

  def app = Frijolero::App

  def setup
    @dir = enter_test_ledger
    File.write(File.join(@dir, 'main.beancount'), MAIN)
    @repo = FakeRepo.new
    Frijolero::App.repo = @repo
  end

  def teardown
    leave_test_ledger
    Frijolero::App.repo = nil
  end

  def without_rledger(&) = Frijolero::Reports.stub(:capture, ->(*) { flunk 'rledger ran' }, &)

  def test_a_report_page_shows_the_message
    without_rledger { get '/reports/income' }

    assert_equal 502, last_response.status
    assert_includes last_response.body, 'main.beancount:2: &quot;/etc/hosts&quot; está fuera del ledger'
  end

  def test_the_badge_counts_it_and_the_error_page_links_its_line
    without_rledger { get '/errors' }

    assert_includes last_response.body, 'aria-label="1 error"'
    assert_includes last_response.body, '<code>UNSAFE</code> &quot;/etc/hosts&quot; está fuera del ledger'
    assert_includes last_response.body, '<a href="/files/main.beancount#L2">línea 2</a>'
  end

  def test_the_file_editor_marks_the_line
    without_rledger { get '/files/main.beancount' }

    assert_equal 200, last_response.status
    assert_includes last_response.body,
                    '<span class="line err" id="L2" title="UNSAFE &quot;/etc/hosts&quot; está fuera del ledger">'
  end

  # The check before the save names the include, the one after runs rledger on the safe ledger.
  def test_an_edit_that_removes_the_include_is_saved
    rledger('--version')

    post '/edit', file: 'main.beancount', original: MAIN, content: "2026-01-01 open Assets:BBVA\n"

    assert_equal 204, last_response.status
    assert_equal "2026-01-01 open Assets:BBVA\n", File.read(File.join(@dir, 'main.beancount'))
    assert_equal ['Edición main.beancount'], @repo.messages
  end

  def test_an_edit_that_adds_an_unsafe_include_is_refused
    File.write(File.join(@dir, 'main.beancount'), "2026-01-01 open Assets:BBVA\n")
    rledger('--version')

    post '/edit', file: 'main.beancount', original: "2026-01-01 open Assets:BBVA\n", content: MAIN

    assert_equal 422, last_response.status
    assert_equal 'UNSAFE', JSON.parse(last_response.body)['errors'].first['code']
    assert_equal "2026-01-01 open Assets:BBVA\n", File.read(File.join(@dir, 'main.beancount'))
  end
end
