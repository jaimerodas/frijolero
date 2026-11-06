# frozen_string_literal: true

require 'test_helper'
require 'fileutils'

class SuggestionsTest < Minitest::Test
  include TestHelpers

  Suggestions = Frijolero::Suggestions

  PAST = <<~BEAN
    2026-09-02 * "NEGRONI ROMA MEXICO RFCCCN1010268M6 /REF000011"
      Liabilities:Amex  -1,200.00 MXN
      Expenses:Food:Restaurants

    2026-09-03 * "STARBUCKS COYOACAN RFCCSI020226MV4 /REF000012"
      Liabilities:Amex  -95.00 MXN
      Expenses:Food:Coffee

    2026-09-04 * "PAGO RECIBIDO GRACIAS"
      Liabilities:Amex  5,000.00 MXN
      Assets:Bank
  BEAN

  # NEGRONI is the row to guess. AMAZON matches a rule with no account: the person checks it elsewhere.
  STATEMENT = <<~BEAN
    2026-10-02 * "NEGRONI MITIKAH MEXICO RFCCCN1010268M6 /REF000036"
      Liabilities:Amex  -2,980.80 MXN
      Expenses:FIXME

    2026-10-04 * "Amazon" ""
      source_desc: "AMAZON MX*AMAZON RETAIL MEXICO CITY RFCANE140618P37 /REF3Gj2"
      Liabilities:Amex  -205.50 MXN
      Expenses:FIXME

    2026-10-05 * "STARBUCKS MITIKAH"
      Liabilities:Amex  -80.00 MXN
      Expenses:Food:Coffee
  BEAN

  NEGRONI = '2026-10-02 NEGRONI MITIKAH MEXICO RFCCCN1010268M6 /REF000036'

  class Client
    attr_reader :calls

    def initialize(answer)
      @answer = answer
      @calls = []
    end

    def ask(text, spec)
      @calls << [text, spec]
      @answer
    end
  end

  def setup
    @dir = enter_test_ledger
    File.write(File.join(@dir, 'config', 'accounts.yaml'), "AMEX:\n  beancount_account: Liabilities:Amex\n")
    File.write(File.join(@dir, 'main.beancount'),
               %w[Liabilities:Amex Assets:Bank Expenses:Food:Restaurants Expenses:Food:Coffee Expenses:Shopping
                  Income:Refunds Expenses:FIXME].map { |a| "2026-01-01 open #{a}\n" }.join)
    FileUtils.mkdir_p(File.join(@dir, 'config', 'rules'))
    File.write(Frijolero::Config.rules_path('AMEX'), "start_with:\n  AMAZON:\n    payee: Amazon\n    narration: ''\n")
    write_statement('2609', PAST)
    write_statement('2610', STATEMENT)
  end

  def teardown = leave_test_ledger

  def write_statement(period, text)
    path = Frijolero::Config.statement_path('AMEX', period, 'beancount')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def answer(*rows) = { 'rows' => rows.map { |row, accounts| { 'row' => row, 'accounts' => accounts } } }

  def test_one_call_guesses_each_open_row_from_the_closest_past_ones
    client = Client.new(answer([1, %w[Expenses:Food:Restaurants Expenses:Food:Coffee Expenses:Shopping]]))

    assert_equal 1, Suggestions.new(client).write('AMEX', '2610')

    assert_equal 1, client.calls.size
    text, spec = client.calls.first
    assert_includes text, %(1. 2026-10-02 "NEGRONI MITIKAH MEXICO RFCCCN1010268M6 /REF000036" -2980.8 MXN)
    assert_includes text, %(- "NEGRONI ROMA MEXICO RFCCCN1010268M6 /REF000011" -1200.0 MXN → Expenses:Food:Restaurants)
    refute_includes text, 'AMAZON', 'a rule without an account opts the row out'
    refute_includes text, 'PAGO RECIBIDO', 'an account the model cannot answer is no example'
    assert_equal 'suggest', spec['_prompt']
    enum = spec.dig('format', 'schema', 'properties', 'rows', 'items', 'properties', 'accounts', 'items', 'enum')
    assert_equal %w[Expenses:Food:Coffee Expenses:Food:Restaurants Expenses:Shopping Income:Refunds], enum
    assert_equal({ NEGRONI => %w[Expenses:Food:Restaurants Expenses:Food:Coffee Expenses:Shopping] },
                 Suggestions.read('AMEX', '2610'))
  end

  # Strict JSON holds the enum, not the count: a row outside the list goes, and each row keeps three once.
  def test_the_answer_keeps_three_accounts_of_the_listed_rows
    client = Client.new(answer([1, %w[Expenses:Shopping Expenses:Shopping Income:Refunds Expenses:Food:Coffee
                                      Expenses:Food:Restaurants]], [7, %w[Expenses:Shopping]], [0, %w[Income:Refunds]]))

    Suggestions.new(client).write('AMEX', '2610')

    assert_equal({ NEGRONI => %w[Expenses:Shopping Income:Refunds Expenses:Food:Coffee] },
                 Suggestions.read('AMEX', '2610'))
  end

  # A long list costs the model accuracy: each call takes eight rows, numbered from 1.
  def test_a_long_statement_goes_in_calls_of_eight_rows
    rows = (1..9).map do |day|
      %(2026-10-0#{day} * "SHOP #{day}"\n  Liabilities:Amex  -1.00 MXN\n  Expenses:FIXME\n)
    end
    write_statement('2610', rows.join("\n"))
    client = Client.new(answer([1, %w[Expenses:Shopping]]))

    assert_equal 2, Suggestions.new(client).write('AMEX', '2610')

    assert_equal 2, client.calls.size
    assert_includes client.calls.last.first, '1. 2026-10-09 "SHOP 9"'
    assert_equal ['2026-10-01 SHOP 1', '2026-10-09 SHOP 9'], Suggestions.read('AMEX', '2610').keys
  end

  def test_no_row_to_guess_makes_no_call
    write_statement('2610', STATEMENT.sub('Expenses:FIXME', 'Expenses:Food:Restaurants'))
    client = Client.new(answer)

    assert_equal 0, Suggestions.new(client).write('AMEX', '2610')

    assert_empty client.calls
    assert_empty Suggestions.read('AMEX', '2610')
  end

  def test_a_statement_without_guesses_reads_empty
    assert_empty Suggestions.read('AMEX', '2610')
  end
end
