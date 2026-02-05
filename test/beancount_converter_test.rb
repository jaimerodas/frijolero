# frozen_string_literal: true

require "test_helper"

class BeancountConverterTest < Minitest::Test
  include TestHelpers

  def test_converts_transactions_to_beancount
    with_temp_dir do |dir|
      output_path = File.join(dir, "output.beancount")

      Frijolero::BeancountConverter.convert(
        input: fixture_path("sample_transactions.json"),
        account: "Liabilities:Amex",
        output: output_path
      )

      content = File.read(output_path)

      # Check first transaction
      assert_includes content, '2025-01-15 * "AMAZON WEB SERVICES"'
      assert_includes content, "Liabilities:Amex  -50.00 MXN"
      assert_includes content, "Expenses:FIXME"
    end
  end

  def test_uses_custom_expense_account
    with_temp_dir do |dir|
      output_path = File.join(dir, "output.beancount")

      Frijolero::BeancountConverter.convert(
        input: fixture_path("sample_transactions.json"),
        account: "Liabilities:Amex",
        output: output_path,
        expense_account: "Expenses:Uncategorized"
      )

      content = File.read(output_path)
      assert_includes content, "Expenses:Uncategorized"
    end
  end

  def test_uses_transaction_expense_account_when_provided
    with_temp_dir do |dir|
      json_content = {
        "transactions" => [
          {
            "date" => "2025-01-15",
            "description" => "COFFEE",
            "amount" => -5.0,
            "currency" => "MXN",
            "expense_account" => "Expenses:Food:Coffee"
          }
        ]
      }

      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      output_path = File.join(dir, "output.beancount")
      Frijolero::BeancountConverter.convert(
        input: json_path,
        account: "Liabilities:Amex",
        output: output_path
      )

      content = File.read(output_path)
      assert_includes content, "Expenses:Food:Coffee"
      refute_includes content, "Expenses:FIXME"
    end
  end

  def test_formats_payee_and_narration
    with_temp_dir do |dir|
      json_content = {
        "transactions" => [
          {
            "date" => "2025-01-15",
            "description" => "STARBUCKS REFORMA",
            "payee" => "Starbucks",
            "narration" => "Coffee",
            "amount" => -85.0,
            "currency" => "MXN"
          }
        ]
      }

      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      output_path = File.join(dir, "output.beancount")
      Frijolero::BeancountConverter.convert(
        input: json_path,
        account: "Liabilities:Amex",
        output: output_path
      )

      content = File.read(output_path)
      assert_includes content, '2025-01-15 * "Starbucks" "Coffee"'
      assert_includes content, 'source_desc: "STARBUCKS REFORMA"'
    end
  end

  def test_raises_without_input
    assert_raises ArgumentError do
      Frijolero::BeancountConverter.convert(input: nil, account: "Test")
    end
  end

  def test_raises_without_account
    assert_raises ArgumentError do
      Frijolero::BeancountConverter.convert(input: "test.json", account: nil)
    end
  end
end
