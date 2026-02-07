# frozen_string_literal: true

require "test_helper"

class StatementProcessorTest < Minitest::Test
  def setup
    @processor = Frijolero::StatementProcessor.new(dry_run: true)
  end

  def test_transaction_summary_mixed
    transactions = [
      {"amount" => -100.0},
      {"amount" => -50.0},
      {"amount" => 25.0}
    ]
    result = Frijolero::UI.transaction_summary(transactions)
    assert_includes result, "2 debits (150.00)"
    assert_includes result, "1 credits (25.00)"
    assert result.start_with?(": ")
  end

  def test_transaction_summary_all_debits
    transactions = [
      {"amount" => -100.0},
      {"amount" => -200.0}
    ]
    result = Frijolero::UI.transaction_summary(transactions)
    assert_includes result, "2 debits (300.00)"
    refute_includes result, "credits"
  end

  def test_transaction_summary_all_credits
    transactions = [
      {"amount" => 50.0},
      {"amount" => 75.0}
    ]
    result = Frijolero::UI.transaction_summary(transactions)
    assert_includes result, "2 credits (125.00)"
    refute_includes result, "debits"
  end

  def test_transaction_summary_empty
    result = Frijolero::UI.transaction_summary([])
    assert_equal "", result
  end

  def test_transaction_summary_large_amounts
    transactions = [
      {"amount" => -12345.67},
      {"amount" => -890.12}
    ]
    result = Frijolero::UI.transaction_summary(transactions)
    # Sum of debits: 12345.67 + 890.12 = 13235.79
    assert_includes result, "2 debits (13,235.79)"
  end

  def test_format_elapsed_seconds
    assert_equal "5.2s", @processor.send(:format_elapsed, 5.23)
  end

  def test_format_elapsed_minutes
    assert_equal "2m 30.0s", @processor.send(:format_elapsed, 150.0)
  end

  def test_format_elapsed_under_one_second
    assert_equal "0.3s", @processor.send(:format_elapsed, 0.34)
  end
end
