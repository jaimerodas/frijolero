# frozen_string_literal: true

require "test_helper"

class TransactionSplitterTest < Minitest::Test
  include TestHelpers

  SAMPLE_BEANCOUNT = <<~BEANCOUNT
    2025-01-15 * "Steelcase" "SPEI Enviado"
      Assets:BBVA  -5248.60 MXN
      Expenses:Home:Furnishings

    2025-01-20 * "Amazon" "Compra en línea"
      Liabilities:Amex-Aeromexico  -139.50 MXN
      Expenses:Subscriptions

    2025-02-01 * "Renta Febrero"
      Assets:BBVA  -38200 MXN
      Expenses:Home:Rent

    2025-02-05 * "Starbucks"
      Liabilities:Amex-Aeromexico  -85.00 MXN
      Expenses:Food:Coffee

    2025-02-10 * "Saldo Inicial"
      Assets:Prius  310000 MXN
      Equity:Opening-Balances

  BEANCOUNT

  def write_beancount(dir, content = SAMPLE_BEANCOUNT)
    path = File.join(dir, "transactions.beancount")
    File.write(path, content)
    path
  end

  def write_accounts_yaml(config_dir)
    File.write(File.join(config_dir, "accounts.yaml"), <<~YAML)
      BBVA:
        beancount_account: "Assets:BBVA"
      Amex Aeromexico:
        beancount_account: "Liabilities:Amex-Aeromexico"
    YAML
  end

  def test_summary_groups_transactions_by_account
    with_temp_config_dir do |config_dir|
      write_accounts_yaml(config_dir)

      with_temp_dir do |dir|
        path = write_beancount(dir)
        splitter = Frijolero::TransactionSplitter.new(beancount_file: path)
        summary = splitter.summary

        assert_equal 2, summary["BBVA"]
        assert_equal 2, summary["Amex Aeromexico"]
      end
    end
  end

  def test_summary_labels_unknown_accounts_as_other
    with_temp_config_dir do |config_dir|
      write_accounts_yaml(config_dir)

      with_temp_dir do |dir|
        path = write_beancount(dir)
        splitter = Frijolero::TransactionSplitter.new(beancount_file: path)
        summary = splitter.summary

        assert_equal 1, summary["Other"]
      end
    end
  end

  def test_split_extracts_transactions_to_monthly_files
    with_temp_config_dir do |config_dir|
      write_accounts_yaml(config_dir)

      with_temp_dir do |dir|
        path = write_beancount(dir)
        splitter = Frijolero::TransactionSplitter.new(beancount_file: path)
        result = splitter.split(account_key: "BBVA")

        assert_equal 2, result[:extracted]
        assert_equal 2, result[:files]

        jan_file = File.join(dir, "transactions", "BBVA", "BBVA_2501.beancount")
        feb_file = File.join(dir, "transactions", "BBVA", "BBVA_2502.beancount")

        assert File.exist?(jan_file)
        assert File.exist?(feb_file)

        jan_content = File.read(jan_file)
        assert_includes jan_content, "Steelcase"
        assert_includes jan_content, "Assets:BBVA"

        feb_content = File.read(feb_file)
        assert_includes feb_content, "Renta Febrero"
      end
    end
  end

  def test_split_replaces_transactions_with_includes
    with_temp_config_dir do |config_dir|
      write_accounts_yaml(config_dir)

      with_temp_dir do |dir|
        path = write_beancount(dir)
        splitter = Frijolero::TransactionSplitter.new(beancount_file: path)
        splitter.split(account_key: "BBVA")

        content = File.read(path)
        assert_includes content, 'include "transactions/BBVA/BBVA_2501.beancount"'
        assert_includes content, 'include "transactions/BBVA/BBVA_2502.beancount"'
        refute_includes content, "Steelcase"
        refute_includes content, "Renta Febrero"

        # Non-BBVA transactions should remain
        assert_includes content, "Amazon"
        assert_includes content, "Starbucks"
        assert_includes content, "Saldo Inicial"
      end
    end
  end

  def test_split_skips_existing_files
    with_temp_config_dir do |config_dir|
      write_accounts_yaml(config_dir)

      with_temp_dir do |dir|
        path = write_beancount(dir)

        # Pre-create the January file
        existing_dir = File.join(dir, "transactions", "BBVA")
        FileUtils.mkdir_p(existing_dir)
        File.write(File.join(existing_dir, "BBVA_2501.beancount"), "existing content")

        splitter = Frijolero::TransactionSplitter.new(beancount_file: path)
        result = splitter.split(account_key: "BBVA")

        assert_equal 2, result[:matched]
        assert_equal 1, result[:extracted]
        assert_equal 1, result[:files]
        assert_includes result[:existing], "2501"

        # Existing file should not be overwritten
        assert_equal "existing content", File.read(File.join(existing_dir, "BBVA_2501.beancount"))

        # February should be extracted
        assert File.exist?(File.join(existing_dir, "BBVA_2502.beancount"))
      end
    end
  end

  def test_split_removes_start_end_markers
    with_temp_config_dir do |config_dir|
      write_accounts_yaml(config_dir)

      with_temp_dir do |dir|
        content = <<~BEANCOUNT
          ; === Start: BBVA_2501.beancount ===
          2025-01-15 * "Test"
            Assets:BBVA  -100 MXN
            Expenses:Other

          ; === End: BBVA_2501.beancount ===
        BEANCOUNT

        path = File.join(dir, "transactions.beancount")
        File.write(path, content)

        splitter = Frijolero::TransactionSplitter.new(beancount_file: path)
        splitter.split(account_key: "BBVA")

        result = File.read(path)
        refute_includes result, "; === Start:"
        refute_includes result, "; === End:"
      end
    end
  end

  def test_split_dry_run_does_not_modify_files
    with_temp_config_dir do |config_dir|
      write_accounts_yaml(config_dir)

      with_temp_dir do |dir|
        path = write_beancount(dir)
        original_content = File.read(path)

        splitter = Frijolero::TransactionSplitter.new(beancount_file: path)
        result = splitter.split(account_key: "BBVA", dry_run: true)

        assert_equal 2, result[:matched]
        assert_equal 0, result[:extracted]
        assert_equal 0, result[:files]

        # File should not be modified
        assert_equal original_content, File.read(path)

        # No transaction files should be created
        refute Dir.exist?(File.join(dir, "transactions"))
      end
    end
  end

  def test_split_creates_backup
    with_temp_config_dir do |config_dir|
      write_accounts_yaml(config_dir)

      with_temp_dir do |dir|
        path = write_beancount(dir)
        original_content = File.read(path)

        splitter = Frijolero::TransactionSplitter.new(beancount_file: path)
        splitter.split(account_key: "BBVA")

        backup = path + ".bak"
        assert File.exist?(backup)
        assert_equal original_content, File.read(backup)
      end
    end
  end

  def test_split_no_matching_transactions
    with_temp_config_dir do |config_dir|
      write_accounts_yaml(config_dir)

      with_temp_dir do |dir|
        content = <<~BEANCOUNT
          2025-01-15 * "Saldo Inicial"
            Assets:Prius  310000 MXN
            Equity:Opening-Balances

        BEANCOUNT

        path = File.join(dir, "transactions.beancount")
        File.write(path, content)

        splitter = Frijolero::TransactionSplitter.new(beancount_file: path)
        result = splitter.split(account_key: "BBVA")

        assert_equal 0, result[:matched]
        refute Dir.exist?(File.join(dir, "transactions"))
      end
    end
  end

  def test_split_raises_for_unknown_account
    with_temp_config_dir do |config_dir|
      write_accounts_yaml(config_dir)

      with_temp_dir do |dir|
        path = write_beancount(dir)
        splitter = Frijolero::TransactionSplitter.new(beancount_file: path)

        assert_raises ArgumentError do
          splitter.split(account_key: "NonExistent")
        end
      end
    end
  end
end
