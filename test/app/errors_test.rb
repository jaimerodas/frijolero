# frozen_string_literal: true

require 'test_helper'

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
