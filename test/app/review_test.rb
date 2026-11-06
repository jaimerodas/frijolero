# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'digest'
require 'fileutils'

class ReviewTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  # Lines 1, 5, 15 and 19 are unclassified; line 10 is classified and never in the form.
  STATEMENT = <<~BEAN
    2026-10-04 * "PORTAL TELCEL CLARO MEXICO RFCRDI841003QJ4 /REFE580559D7FA1"
      Liabilities:Amex  -499.00 MXN
      Expenses:FIXME

    2026-10-05 * "Amazon" ""
      source_desc: "AMAZON MX*AMAZON RETAIL MEXICO CITY RFCANE140618P37 /REF3Gj2"
      Liabilities:Amex  -205.50 MXN
      Expenses:FIXME

    2026-10-06 * "Uber" "Uber Eats"
      source_desc: "UBER EATS HTTPS://HELP.UB"
      Liabilities:Amex  -100.00 MXN
      Expenses:Food:Delivery

    2026-10-10 * "UNITED AIRLINES HOUSTON Dólar U.S.A. 169.00"
      Liabilities:Amex  -3,150.00 MXN
      Expenses:FIXME

    2026-10-17 * "UNITED AIRLINES HOUSTON Dólar U.S.A. 229.80"
      Liabilities:Amex  -4,200.00 MXN
      Expenses:FIXME
  BEAN

  RULES = <<~YAML
    # Las reglas de AMEX
    start_with:
      AMAZON:
        payee: Amazon
        narration: ''
    include: {}
  YAML

  class Checker
    attr_accessor :errors
    attr_reader :checks

    def check
      @checks = @checks.to_i + 1
      errors.respond_to?(:call) ? errors.call : errors.to_a
    end
  end

  class Repo
    attr_reader :messages
    attr_accessor :failure

    def initialize
      @messages = []
    end

    def commit_and_push(message)
      @messages << message
      raise Frijolero::LedgerRepo::Error, failure if failure
    end
  end

  def setup
    @dir = enter_test_ledger
    File.write(File.join(@dir, 'config', 'accounts.yaml'), <<~YAML)
      AMEX:
        beancount_account: "Liabilities:Amex"
      CETES:
        beancount_account: "Assets:CETES"
        converter_type: cetes_directo
    YAML
    File.write(File.join(@dir, 'main.beancount'), %w[Liabilities:Amex Expenses:Food:Delivery Expenses:Utilities:Phone
                                                     Expenses:Travel:Flights Expenses:Home:Supplies Expenses:FIXME]
                                                    .map { |a| "2026-01-01 open #{a}\n" }.join)
    @path = Frijolero::Config.statement_path('AMEX', '2610', 'beancount')
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, STATEMENT)
    FileUtils.mkdir_p(File.join(@dir, 'config', 'rules'))
    @rules = Frijolero::Config.rules_path('AMEX')
    File.write(@rules, RULES)
    Frijolero::App.repo = @repo = Repo.new
    Frijolero::App.reports = @checker = Checker.new
    Frijolero::App.jobs = Frijolero::Jobs.new(log_path: File.join(@dir, 'jobs.jsonl'))
  end

  def teardown
    leave_test_ledger
    Frijolero::App.repo = nil
    Frijolero::App.reports = nil
    Frijolero::App.jobs = nil
    Frijolero::App.client = nil
  end

  # The model of "Sugerir cuentas": it answers the first row of the list.
  class Client
    def ask(_text, _spec) = { 'rows' => [{ 'row' => 1, 'accounts' => %w[Expenses:Utilities:Phone] }] }
  end

  TELCEL = '2026-10-04 PORTAL TELCEL CLARO MEXICO RFCRDI841003QJ4 /REFE580559D7FA1'

  def guesses(map)
    path = Frijolero::Suggestions.path('AMEX', '2610')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(map))
  end

  def app
    Frijolero::App
  end

  def save(choice, digest = Digest::SHA256.hexdigest(File.read(@path)))
    post '/accounts/AMEX/2610/review', digest: digest, choice: choice
  end

  def test_review_lists_the_unclassified_rows_as_one_form
    get '/accounts/AMEX/2610/review'

    assert_equal 200, last_response.status
    body = last_response.body
    assert_includes body, '<form method="post" action="/accounts/AMEX/2610/review" class="review">'
    assert_includes body, %(name="digest" value="#{Digest::SHA256.hexdigest(STATEMENT)}")
    assert_equal %w[1 5 15 19], body.scan(/name="choice\[(\d+)\]\[account\]"/).flatten
    refute_includes body, 'UBER EATS'
    assert_includes body, '<option value="Expenses:Travel:Flights">'
    # The account's payee stays, and a rule starts as the description up to the RFC or the dollars.
    assert_includes body, 'name="choice[5][payee]" value="Amazon"'
    assert_includes body, 'name="choice[1][pattern]" value="PORTAL TELCEL CLARO MEXICO"'
    assert_includes body, 'name="choice[15][pattern]" value="UNITED AIRLINES HOUSTON"'
  end

  def test_the_unclassified_status_opens_revisar
    get '/accounts/AMEX/2610'

    body = last_response.body
    assert_includes body, '<a class="status missing" href="/accounts/AMEX/2610/review">4 sin clasificar</a>'
    assert_includes body, '<a href="/accounts/AMEX/2610/review">Revisar</a>'
  end

  def test_saving_applies_each_row_and_commits_once
    save('1' => { account: 'Expenses:Utilities:Phone', payee: 'Telcel' },
         '5' => { account: 'Expenses:Home:Supplies', payee: 'Amazon', narration: 'Pilas  CR2032' },
         '15' => { account: '', payee: '', narration: '' })

    assert_equal 303, last_response.status
    assert_equal 'http://example.org/accounts/AMEX/2610/review?classified=2', last_response.location
    text = File.read(@path)
    assert_includes text, <<~BEAN
      2026-10-04 * "Telcel" "PORTAL TELCEL CLARO MEXICO RFCRDI841003QJ4 /REFE580559D7FA1"
        Liabilities:Amex  -499.00 MXN
        Expenses:Utilities:Phone
    BEAN
    assert_includes text, <<~BEAN
      2026-10-05 * "Amazon" "Pilas CR2032"
        source_desc: "AMAZON MX*AMAZON RETAIL MEXICO CITY RFCANE140618P37 /REF3Gj2"
        Liabilities:Amex  -205.50 MXN
        Expenses:Home:Supplies
    BEAN
    assert_includes text, STATEMENT.lines[9..].join # Uber and both United rows, untouched
    assert_equal ['Revisión AMEX 2610'], @repo.messages
    assert_equal 2, @checker.checks
    assert_equal RULES, File.read(@rules)
  end

  def test_a_rule_from_one_row_classifies_the_rows_like_it_in_the_same_save
    save('15' => { account: 'Expenses:Travel:Flights', payee: 'United', rule: '1',
                   pattern: 'UNITED AIRLINES HOUSTON' })

    assert_equal 'http://example.org/accounts/AMEX/2610/review?classified=2&new_rules=1', last_response.location
    text = File.read(@path)
    assert_equal 2, text.scan(%(* "United" "UNITED AIRLINES HOUSTON)).size
    assert_equal 2, text.scan('Expenses:Travel:Flights').size
    assert_equal <<~YAML, File.read(@rules)
      # Las reglas de AMEX
      start_with:
        AMAZON:
          payee: Amazon
          narration: ''
        UNITED AIRLINES HOUSTON:
          payee: United
          account: Expenses:Travel:Flights
      include: {}
    YAML
    assert_equal ['Revisión AMEX 2610'], @repo.messages
  end

  def test_an_unknown_account_is_422_keeps_what_was_typed_and_writes_nothing
    save('1' => { account: 'Expenses:Telefono' }, '5' => { account: 'Expenses:Home:Supplies' })

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'name="choice[1][account]" value="Expenses:Telefono"'
    assert_includes last_response.body, 'Cuenta desconocida: Expenses:Telefono'
    assert_equal STATEMENT, File.read(@path)
    assert_empty @repo.messages
  end

  def test_a_rule_pattern_must_start_the_description_and_be_new
    save('1' => { account: 'Expenses:Utilities:Phone', rule: '1', pattern: 'TELCEL' },
         '5' => { account: 'Expenses:Home:Supplies', rule: '1', pattern: 'AMAZON' })

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'El patrón no es el principio de la descripción'
    assert_includes last_response.body, 'Ya hay una regla «AMAZON»'
    assert_equal STATEMENT, File.read(@path)
    assert_equal RULES, File.read(@rules)
  end

  # A job or a pull changed the file after the page loaded: the lines may point elsewhere now.
  def test_a_stale_form_is_409_and_shows_the_statement_as_it_is_now
    save({ '1' => { account: 'Expenses:Utilities:Phone' } }, 'old')

    assert_equal 409, last_response.status
    assert_includes last_response.body, 'cambió'
    assert_includes last_response.body, %(name="digest" value="#{Digest::SHA256.hexdigest(STATEMENT)}")
    assert_includes last_response.body, 'name="choice[1][account]" value=""'
    assert_equal STATEMENT, File.read(@path)
    assert_empty @repo.messages
  end

  def test_a_save_that_adds_ledger_errors_puts_both_files_back
    @checker.errors = lambda {
      File.read(@path).include?('Flights') ? [{ code: 'E1001', message: 'nope', file: 'x', line: 1 }] : []
    }
    save('15' => { account: 'Expenses:Travel:Flights', rule: '1', pattern: 'UNITED AIRLINES HOUSTON' })

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'E1001 nope'
    assert_equal STATEMENT, File.read(@path)
    assert_equal RULES, File.read(@rules)
    assert_empty @repo.messages
  end

  def test_saving_the_last_rows_returns_to_the_movements
    save('1' => { account: 'Expenses:Utilities:Phone' }, '5' => { account: 'Expenses:Home:Supplies' },
         '15' => { account: 'Expenses:Travel:Flights' }, '19' => { account: 'Expenses:Travel:Flights' })

    assert_equal 'http://example.org/accounts/AMEX/2610?classified=4', last_response.location
    follow_redirect!
    assert_includes last_response.body, '4 clasificadas'
    assert_includes last_response.body, 'Todo clasificado'
  end

  def test_a_save_with_no_choices_commits_nothing
    save('1' => { account: '', payee: '' }, '5' => { payee: 'Amazon', narration: '' })

    assert_equal 'http://example.org/accounts/AMEX/2610/review?classified=0', last_response.location
    assert_equal STATEMENT, File.read(@path)
    assert_empty @repo.messages
  end

  def test_a_push_failure_keeps_the_save_and_says_so
    @repo.failure = 'rejected'
    save('1' => { account: 'Expenses:Utilities:Phone' })

    assert_includes File.read(@path), 'Expenses:Utilities:Phone'
    follow_redirect!
    assert_includes last_response.body, 'no se pudo subir: rejected'
  end

  def test_review_is_404_where_the_pipeline_has_no_rules
    path = Frijolero::Config.statement_path('CETES', '2610', 'beancount')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "2026-10-01 * \"X\"\n  Expenses:FIXME 100 MXN\n  Assets:CETES -100 MXN\n")

    get '/accounts/CETES/2610/review'
    assert_equal 404, last_response.status

    post '/accounts/CETES/2610/review', digest: Digest::SHA256.hexdigest(File.read(path))
    assert_equal 404, last_response.status
  end

  def test_the_review_page_links_inside_the_ledger
    get '/accounts/AMEX/2610/review', {}, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_includes last_response.body, %(action="#{LEDGER_ROOT}/accounts/AMEX/2610/review")
    assert_ledger_links last_response.body
  end

  def test_each_row_starts_with_its_first_guess_and_offers_the_three
    guesses(TELCEL => %w[Expenses:Utilities:Phone Expenses:Home:Supplies Expenses:Travel:Flights])

    get '/accounts/AMEX/2610/review'

    body = last_response.body
    assert_includes body, 'name="choice[1][account]" value="Expenses:Utilities:Phone"'
    assert_includes body, '<button type="button" class="guess" data-account="Expenses:Home:Supplies">'
    assert_includes body, 'name="choice[15][account]" value=""'
  end

  def test_a_refused_save_keeps_the_account_that_the_person_cleared
    guesses(TELCEL => %w[Expenses:Utilities:Phone])

    save('1' => { account: '' }, '15' => { account: 'Expenses:Nope' })

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'name="choice[1][account]" value=""'
  end

  def test_sugerir_shows_only_while_there_are_no_guesses_and_a_model
    Frijolero::App.client = Client.new
    get '/accounts/AMEX/2610/review'
    assert_includes last_response.body, 'action="/accounts/AMEX/2610/suggest"'

    guesses(TELCEL => %w[Expenses:Utilities:Phone])
    get '/accounts/AMEX/2610/review'
    refute_includes last_response.body, '/suggest"'

    Frijolero::App.client = nil
    File.delete(Frijolero::Suggestions.path('AMEX', '2610'))
    without_env('OPENAI_API_KEY') { get '/accounts/AMEX/2610/review' }
    refute_includes last_response.body, '/suggest"'
  end

  # The call runs as a corrida, never in the request; its page leads back to Revisar.
  def test_sugerir_queues_a_corrida_that_writes_the_guesses
    Frijolero::App.client = Client.new

    post '/accounts/AMEX/2610/suggest'

    assert_equal 303, last_response.status
    job = Frijolero::App.jobs.find(last_response.location[%r{/jobs/(.+)\z}, 1])
    assert_equal 'Sugerencias AMEX 2610', job.label
    get '/accounts/AMEX/2610/review'
    assert_includes last_response.body, "href=\"/jobs/#{job.id}\">Sugiriendo cuentas</a>"
    refute_includes last_response.body, '/suggest"'

    Frijolero::App.jobs.work_one

    assert_equal ['ok', "Sugerencias guardadas: 1\n"], [job.status, job.output]
    get "/jobs/#{job.id}"
    assert_includes last_response.body, 'href="/accounts/AMEX/2610/review">Revisar</a>'
    get '/accounts/AMEX/2610/review'
    assert_includes last_response.body, 'name="choice[1][account]" value="Expenses:Utilities:Phone"'
  end
end
