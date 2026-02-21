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
      assert_equal 3, stats[:detailed].size
      assert_equal 0, stats[:remaining].size
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
      assert_equal 1, stats[:detailed].size
      assert_equal 1, stats[:remaining].size
    end
  end

  # --- when clause tests ---

  def test_single_hash_with_when_matches
    with_temp_dir do |dir|
      json_content = {
        "transactions" => [
          {"date" => "2025-02-01", "description" => "NETFLIX CHARGE", "amount" => -149, "currency" => "MXN"}
        ]
      }
      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      detailer = Frijolero::Detailer.new(json_path, fixture_path("sample_detailer_with_when.yaml"))
      stats = detailer.run

      result = JSON.parse(File.read(json_path))
      tx = result["transactions"].first

      assert_equal "Netflix", tx["payee"]
      assert_equal "Subscription", tx["narration"]
      assert_equal "Expenses:Subscriptions", tx["expense_account"]
      assert_equal 1, stats[:detailed].size
    end
  end

  def test_single_hash_with_when_does_not_match
    with_temp_dir do |dir|
      json_content = {
        "transactions" => [
          {"date" => "2025-02-01", "description" => "NETFLIX CHARGE", "amount" => -199, "currency" => "MXN"}
        ]
      }
      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      detailer = Frijolero::Detailer.new(json_path, fixture_path("sample_detailer_with_when.yaml"))
      stats = detailer.run

      result = JSON.parse(File.read(json_path))
      tx = result["transactions"].first

      assert_nil tx["payee"]
      assert_nil tx["expense_account"]
      assert_equal 0, stats[:detailed].size
      assert_equal 1, stats[:remaining].size
    end
  end

  def test_array_rules_first_when_wins
    with_temp_dir do |dir|
      json_content = {
        "transactions" => [
          {"date" => "2025-02-01", "description" => "TRANSFERENCIA SPEI", "amount" => -15000, "currency" => "MXN"}
        ]
      }
      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      detailer = Frijolero::Detailer.new(json_path, fixture_path("sample_detailer_with_when.yaml"))
      stats = detailer.run

      result = JSON.parse(File.read(json_path))
      tx = result["transactions"].first

      assert_equal "Landlord", tx["payee"]
      assert_equal "Rent", tx["narration"]
      assert_equal "Expenses:Rent", tx["expense_account"]
      assert_equal 1, stats[:detailed].size
    end
  end

  def test_array_rules_second_when_matches
    with_temp_dir do |dir|
      json_content = {
        "transactions" => [
          {"date" => "2025-02-01", "description" => "TRANSFERENCIA SPEI", "amount" => -500, "currency" => "MXN"}
        ]
      }
      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      detailer = Frijolero::Detailer.new(json_path, fixture_path("sample_detailer_with_when.yaml"))
      detailer.run

      result = JSON.parse(File.read(json_path))
      tx = result["transactions"].first

      assert_equal "Gym", tx["payee"]
      assert_equal "Membership", tx["narration"]
      assert_equal "Expenses:Health", tx["expense_account"]
    end
  end

  def test_array_rules_fallback_when_no_when_matches
    with_temp_dir do |dir|
      json_content = {
        "transactions" => [
          {"date" => "2025-02-01", "description" => "TRANSFERENCIA SPEI", "amount" => -200, "currency" => "MXN"}
        ]
      }
      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      detailer = Frijolero::Detailer.new(json_path, fixture_path("sample_detailer_with_when.yaml"))
      stats = detailer.run

      result = JSON.parse(File.read(json_path))
      tx = result["transactions"].first

      assert_equal "Transfer", tx["payee"]
      assert_equal "Bank transfer", tx["narration"]
      assert_equal "Expenses:Misc", tx["expense_account"]
      assert_equal 1, stats[:detailed].size
    end
  end

  def test_array_rules_no_fallback_leaves_unmatched
    with_temp_dir do |dir|
      config_content = <<~YAML
        start_with:
          TRANSFERENCIA:
            - when:
                amount: -15000
              payee: Landlord
              account: Expenses:Rent
            - when:
                amount: -500
              payee: Gym
              account: Expenses:Health
      YAML
      config_path = File.join(dir, "config.yaml")
      File.write(config_path, config_content)

      json_content = {
        "transactions" => [
          {"date" => "2025-02-01", "description" => "TRANSFERENCIA SPEI", "amount" => -999, "currency" => "MXN"}
        ]
      }
      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      detailer = Frijolero::Detailer.new(json_path, config_path)
      stats = detailer.run

      result = JSON.parse(File.read(json_path))
      tx = result["transactions"].first

      assert_nil tx["payee"]
      assert_nil tx["expense_account"]
      assert_equal 0, stats[:detailed].size
      assert_equal 1, stats[:remaining].size
    end
  end

  def test_multiple_transactions_same_pattern_different_when
    with_temp_dir do |dir|
      json_content = {
        "transactions" => [
          {"date" => "2025-02-01", "description" => "TRANSFERENCIA SPEI", "amount" => -15000, "currency" => "MXN"},
          {"date" => "2025-02-05", "description" => "TRANSFERENCIA CLABE", "amount" => -500, "currency" => "MXN"},
          {"date" => "2025-02-10", "description" => "TRANSFERENCIA OTRO", "amount" => -200, "currency" => "MXN"}
        ]
      }
      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      detailer = Frijolero::Detailer.new(json_path, fixture_path("sample_detailer_with_when.yaml"))
      stats = detailer.run

      result = JSON.parse(File.read(json_path))
      txs = result["transactions"]

      assert_equal "Landlord", txs[0]["payee"]
      assert_equal "Gym", txs[1]["payee"]
      assert_equal "Transfer", txs[2]["payee"]
      assert_equal 3, stats[:detailed].size
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
