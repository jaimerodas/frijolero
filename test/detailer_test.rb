# frozen_string_literal: true

require "test_helper"

class DetailerTest < Minitest::Test
  include TestHelpers

  def test_enriches_transactions_with_start_with_rules
    with_temp_dir do |dir|
      json_path = File.join(dir, "test.json")
      FileUtils.cp(fixture_path("sample_transactions.json"), json_path)

      detailer = Frijolero::Detailer.new(json_path, fixture_path("sample_detailer.yaml"))
      detailer.run

      result = JSON.parse(File.read(json_path))
      transactions = result["transactions"]

      # Check AWS transaction
      aws_tx = transactions.find { |t| t["description"] == "AMAZON WEB SERVICES" }
      assert_equal "Amazon", aws_tx["payee"]
      assert_equal "AWS", aws_tx["narration"]
      assert_equal "Expenses:Subscriptions", aws_tx["expense_account"]

      # Check Starbucks transaction
      sbux_tx = transactions.find { |t| t["description"] == "STARBUCKS REFORMA" }
      assert_equal "Starbucks", sbux_tx["payee"]
      assert_equal "Expenses:Food:Coffee", sbux_tx["expense_account"]
    end
  end

  def test_enriches_transactions_with_include_rules
    with_temp_dir do |dir|
      json_path = File.join(dir, "test.json")
      FileUtils.cp(fixture_path("sample_transactions.json"), json_path)

      detailer = Frijolero::Detailer.new(json_path, fixture_path("sample_detailer.yaml"))
      detailer.run

      result = JSON.parse(File.read(json_path))
      transactions = result["transactions"]

      # Check Uber transaction (matched by include rule)
      uber_tx = transactions.find { |t| t["description"] == "UBER TRIP" }
      assert_equal "Uber", uber_tx["payee"]
      assert_equal "Expenses:Transportation", uber_tx["expense_account"]
    end
  end

  def test_preserves_unmatched_transactions
    with_temp_dir do |dir|
      json_content = {
        "transactions" => [
          {"date" => "2025-01-15", "description" => "UNMATCHED VENDOR", "amount" => -100.0}
        ]
      }

      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      detailer = Frijolero::Detailer.new(json_path, fixture_path("sample_detailer.yaml"))
      detailer.run

      result = JSON.parse(File.read(json_path))
      tx = result["transactions"].first

      assert_equal "UNMATCHED VENDOR", tx["description"]
      assert_nil tx["payee"]
      assert_nil tx["expense_account"]
    end
  end

  def test_run_returns_match_statistics
    with_temp_dir do |dir|
      json_path = File.join(dir, "test.json")
      FileUtils.cp(fixture_path("sample_transactions.json"), json_path)

      detailer = Frijolero::Detailer.new(json_path, fixture_path("sample_detailer.yaml"))
      stats = detailer.run

      assert_equal 3, stats[:total]
      assert_equal 3, stats[:detailed]
      assert_equal 0, stats[:remaining]
    end
  end

  def test_run_returns_correct_stats_with_unmatched
    with_temp_dir do |dir|
      json_content = {
        "transactions" => [
          {"date" => "2025-01-15", "description" => "AMAZON WEB SERVICES", "amount" => -50.0},
          {"date" => "2025-01-16", "description" => "UNMATCHED VENDOR", "amount" => -100.0}
        ]
      }

      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      detailer = Frijolero::Detailer.new(json_path, fixture_path("sample_detailer.yaml"))
      stats = detailer.run

      assert_equal 2, stats[:total]
      assert_equal 1, stats[:detailed]
      assert_equal 1, stats[:remaining]
    end
  end

  def test_does_not_overwrite_existing_fields_when_rule_field_is_nil
    with_temp_dir do |dir|
      json_content = {
        "transactions" => [
          {
            "date" => "2025-01-15",
            "description" => "STARBUCKS REFORMA",
            "amount" => -85.0,
            "narration" => "Existing narration"
          }
        ]
      }

      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      detailer = Frijolero::Detailer.new(json_path, fixture_path("sample_detailer.yaml"))
      detailer.run

      result = JSON.parse(File.read(json_path))
      tx = result["transactions"].first

      # Starbucks rule doesn't set narration, so existing should remain
      assert_equal "Existing narration", tx["narration"]
      # But payee and account should be set
      assert_equal "Starbucks", tx["payee"]
      assert_equal "Expenses:Food:Coffee", tx["expense_account"]
    end
  end
end
