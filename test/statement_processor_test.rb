# frozen_string_literal: true

require "test_helper"

class StatementProcessorTest < Minitest::Test
  include TestHelpers

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

  def test_check_overwrite_no_existing_files
    with_temp_dir do |dir|
      json_path = File.join(dir, "Amex_2604.json")
      beancount_path = File.join(dir, "Amex_2604.beancount")
      assert @processor.send(:check_overwrite, json_path, beancount_path)
    end
  end

  def test_check_overwrite_existing_json_user_declines
    with_temp_dir do |dir|
      json_path = File.join(dir, "Amex_2603.json")
      beancount_path = File.join(dir, "Amex_2603.beancount")
      File.write(json_path, JSON.pretty_generate({
        "transactions" => [
          {"date" => "2026-03-01", "description" => "Test", "amount" => -100.0},
          {"date" => "2026-03-15", "description" => "Test 2", "amount" => 50.0}
        ]
      }))

      Frijolero::UI.stub(:puts, nil) do
        Frijolero::UI.stub(:confirm, false) do
          refute @processor.send(:check_overwrite, json_path, beancount_path)
        end
      end
    end
  end

  def test_check_overwrite_existing_json_user_confirms
    with_temp_dir do |dir|
      json_path = File.join(dir, "Amex_2603.json")
      beancount_path = File.join(dir, "Amex_2603.beancount")
      File.write(json_path, JSON.pretty_generate({
        "transactions" => [
          {"date" => "2026-03-01", "description" => "Test", "amount" => -100.0}
        ]
      }))

      Frijolero::UI.stub(:puts, nil) do
        Frijolero::UI.stub(:confirm, true) do
          assert @processor.send(:check_overwrite, json_path, beancount_path)
        end
      end
    end
  end

  def test_check_overwrite_existing_beancount_only
    with_temp_dir do |dir|
      json_path = File.join(dir, "Amex_2603.json")
      beancount_path = File.join(dir, "Amex_2603.beancount")
      File.write(beancount_path, "some beancount content")

      Frijolero::UI.stub(:puts, nil) do
        Frijolero::UI.stub(:confirm, false) do
          refute @processor.send(:check_overwrite, json_path, beancount_path)
        end
      end
    end
  end

  def test_check_overwrite_corrupt_json
    with_temp_dir do |dir|
      json_path = File.join(dir, "Amex_2603.json")
      beancount_path = File.join(dir, "Amex_2603.beancount")
      File.write(json_path, "not valid json{{{")

      Frijolero::UI.stub(:puts, nil) do
        Frijolero::UI.stub(:confirm, false) do
          refute @processor.send(:check_overwrite, json_path, beancount_path)
        end
      end
    end
  end

  def test_show_existing_json_info_with_movements
    with_temp_dir do |dir|
      json_path = File.join(dir, "CetesDirecto_2603.json")
      File.write(json_path, JSON.pretty_generate({
        "movements" => [
          {"type" => "cash_in", "amount" => 1000},
          {"type" => "interest_payment", "amount" => 50}
        ]
      }))

      Frijolero::UI.stub(:puts, nil) do
        Frijolero::UI.stub(:short_path, json_path) do
          @processor.send(:show_existing_json_info, json_path)
        end
      end
    end
  end
end
