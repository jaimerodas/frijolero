# frozen_string_literal: true

require "test_helper"

class AccountRenamerTest < Minitest::Test
  include TestHelpers

  def test_replaces_account_in_open_directive
    with_rename_fixtures do |dir|
      renamer = Frijolero::AccountRenamer.new(old_name: "Expenses:Food", new_name: "Expenses:Dining")
      renamer.apply!

      content = File.read(File.join(dir, "ledger", "accounts.beancount"))
      assert_includes content, "open Expenses:Dining MXN"
      refute_includes content, "open Expenses:Food MXN"
    end
  end

  def test_replaces_account_in_transaction_posting
    with_rename_fixtures do |dir|
      renamer = Frijolero::AccountRenamer.new(old_name: "Expenses:Food", new_name: "Expenses:Dining")
      renamer.apply!

      content = File.read(File.join(dir, "ledger", "transactions", "Amex", "Amex_2501.beancount"))
      assert_includes content, "  Expenses:Dining\n"
      refute_includes content, "  Expenses:Food\n"
    end
  end

  def test_does_not_match_partial_prefix
    with_rename_fixtures do |dir|
      renamer = Frijolero::AccountRenamer.new(old_name: "Expenses:Food", new_name: "Expenses:Dining")
      renamer.apply!

      content = File.read(File.join(dir, "ledger", "accounts.beancount"))
      assert_includes content, "Expenses:Food:Coffee"
    end
  end

  def test_replaces_account_in_detailer_yaml
    with_rename_fixtures do |dir|
      renamer = Frijolero::AccountRenamer.new(old_name: "Expenses:Subscriptions", new_name: "Expenses:Software")
      renamer.apply!

      content = File.read(File.join(dir, "detailers", "amex.yaml"))
      assert_includes content, "account: Expenses:Software"
      refute_includes content, "account: Expenses:Subscriptions"
    end
  end

  def test_does_not_replace_payee_or_narration_in_detailer
    with_rename_fixtures do |dir|
      renamer = Frijolero::AccountRenamer.new(old_name: "Amazon", new_name: "AWS")
      renamer.apply!

      content = File.read(File.join(dir, "detailers", "amex.yaml"))
      # payee field should remain unchanged
      assert_includes content, "payee: Amazon"
    end
  end

  def test_replaces_beancount_account_in_accounts_yaml
    with_rename_fixtures do |dir|
      renamer = Frijolero::AccountRenamer.new(old_name: "Liabilities:Amex", new_name: "Liabilities:AmericanExpress")
      renamer.apply!

      content = File.read(File.join(dir, "accounts.yaml"))
      assert_includes content, "Liabilities:AmericanExpress"
      refute_includes content, "Liabilities:Amex"
    end
  end

  def test_preview_returns_correct_counts
    with_rename_fixtures do
      renamer = Frijolero::AccountRenamer.new(old_name: "Expenses:Food", new_name: "Expenses:Dining")
      result = renamer.preview

      beancount_total = result[:beancount].sum { |c| c[:count] }
      assert beancount_total > 0, "Expected beancount occurrences"

      result[:beancount].each do |change|
        assert change[:path].is_a?(String)
        assert change[:count].is_a?(Integer)
        assert change[:count] > 0
      end
    end
  end

  def test_preview_does_not_modify_files
    with_rename_fixtures do |dir|
      accounts_before = File.read(File.join(dir, "ledger", "accounts.beancount"))

      renamer = Frijolero::AccountRenamer.new(old_name: "Expenses:Food", new_name: "Expenses:Dining")
      renamer.preview

      accounts_after = File.read(File.join(dir, "ledger", "accounts.beancount"))
      assert_equal accounts_before, accounts_after
    end
  end

  def test_no_occurrences_found
    with_rename_fixtures do
      renamer = Frijolero::AccountRenamer.new(old_name: "Expenses:Nonexistent", new_name: "Expenses:Other")
      result = renamer.preview

      assert_equal 0, result[:beancount].sum { |c| c[:count] }
      assert_equal 0, result[:detailers].sum { |c| c[:count] }
      assert_empty result[:accounts_yaml]
    end
  end

  def test_accounts_yaml_preview_shows_matching_fields
    with_rename_fixtures do
      renamer = Frijolero::AccountRenamer.new(old_name: "Liabilities:Amex", new_name: "Liabilities:AmericanExpress")
      result = renamer.preview

      assert_equal 1, result[:accounts_yaml].size
      assert_equal "Amex", result[:accounts_yaml].first[:account_key]
      assert_equal "beancount_account", result[:accounts_yaml].first[:field]
    end
  end

  def test_replaces_account_with_amount_on_same_line
    with_rename_fixtures do |dir|
      renamer = Frijolero::AccountRenamer.new(old_name: "Liabilities:Amex", new_name: "Liabilities:AmericanExpress")
      renamer.apply!

      content = File.read(File.join(dir, "ledger", "transactions", "Amex", "Amex_2501.beancount"))
      assert_includes content, "Liabilities:AmericanExpress  -50.00 MXN"
    end
  end

  def test_replaces_quoted_account_in_yaml
    with_rename_fixtures do |dir|
      renamer = Frijolero::AccountRenamer.new(old_name: "Liabilities:Amex", new_name: "Liabilities:AmericanExpress")
      renamer.apply!

      content = File.read(File.join(dir, "accounts.yaml"))
      assert_includes content, "Liabilities:AmericanExpress"
    end
  end

  private

  def with_rename_fixtures
    with_temp_config_dir do |config_dir|
      ledger_dir = File.join(config_dir, "ledger")
      transactions_dir = File.join(ledger_dir, "transactions", "Amex")
      detailers_dir = File.join(config_dir, "detailers")

      FileUtils.mkdir_p(transactions_dir)
      FileUtils.mkdir_p(detailers_dir)

      # Accounts beancount file
      File.write(File.join(ledger_dir, "accounts.beancount"), <<~BEANCOUNT)
        2020-01-01 open Liabilities:Amex MXN
        2020-01-01 open Expenses:Food MXN
        2020-01-01 open Expenses:Food:Coffee MXN
        2020-01-01 open Expenses:Subscriptions MXN
      BEANCOUNT

      # Main ledger
      File.write(File.join(ledger_dir, "main.beancount"), <<~BEANCOUNT)
        include "accounts.beancount"
        include "transactions/Amex/Amex_2501.beancount"
      BEANCOUNT

      # Transaction file
      File.write(File.join(transactions_dir, "Amex_2501.beancount"), <<~BEANCOUNT)
        2025-01-15 * "Restaurant" "Lunch"
          Liabilities:Amex  -50.00 MXN
          Expenses:Food

        2025-01-16 * "Starbucks" "Coffee"
          Liabilities:Amex  -80.00 MXN
          Expenses:Food:Coffee
      BEANCOUNT

      # Detailer yaml
      File.write(File.join(detailers_dir, "amex.yaml"), <<~YAML)
        start_with:
          AMAZON WEB SERVICES:
            payee: Amazon
            narration: AWS
            account: Expenses:Subscriptions
          STARBUCKS:
            payee: Starbucks
            account: Expenses:Food:Coffee
      YAML

      # Accounts yaml
      File.write(File.join(config_dir, "accounts.yaml"), <<~YAML)
        Amex:
          beancount_account: "Liabilities:Amex"
          openai_prompt_type: default
      YAML

      # Point config to the temp files
      config_yaml = {
        "paths" => {
          "beancount_main" => File.join(ledger_dir, "main.beancount"),
          "beancount_accounts" => File.join(ledger_dir, "accounts.beancount")
        }
      }
      File.write(File.join(config_dir, "config.yaml"), YAML.dump(config_yaml))
      Frijolero::Config.reload!

      yield config_dir
    end
  end
end
