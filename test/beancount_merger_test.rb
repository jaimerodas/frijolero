# frozen_string_literal: true

require "test_helper"

class BeancountMergerTest < Minitest::Test
  include TestHelpers

  def test_merges_single_file
    with_temp_dir do |dir|
      input_path = File.join(dir, "Amex_2501.beancount")
      output_path = File.join(dir, "main.beancount")

      File.write(input_path, <<~BEANCOUNT)
        2025-01-15 * "Test Transaction"
          Liabilities:Amex  -50.00 MXN
          Expenses:FIXME
      BEANCOUNT

      File.write(output_path, "; Main ledger\n")

      merger = Frijolero::BeancountMerger.new(
        files: [input_path],
        output: output_path
      )
      merger.run

      # File was copied to transactions/Amex/
      copied = File.join(dir, "transactions", "Amex", "Amex_2501.beancount")
      assert File.exist?(copied), "Expected copied file at #{copied}"
      assert_equal File.read(input_path), File.read(copied)

      # Include directive was added
      content = File.read(output_path)
      assert_includes content, 'include "transactions/Amex/Amex_2501.beancount"'

      # Old markers should NOT be present
      refute_includes content, "; === Start:"
    end
  end

  def test_merges_multiple_files
    with_temp_dir do |dir|
      input1 = File.join(dir, "Amex_2501.beancount")
      input2 = File.join(dir, "BBVA_2501.beancount")
      output_path = File.join(dir, "main.beancount")

      File.write(input1, "2025-01-15 * \"Transaction 1\"\n  Account  100 MXN\n  Other")
      File.write(input2, "2025-01-16 * \"Transaction 2\"\n  Account  200 MXN\n  Other")
      File.write(output_path, "")

      merger = Frijolero::BeancountMerger.new(
        files: [input1, input2],
        output: output_path
      )
      merger.run

      content = File.read(output_path)
      assert_includes content, 'include "transactions/Amex/Amex_2501.beancount"'
      assert_includes content, 'include "transactions/BBVA/BBVA_2501.beancount"'

      assert File.exist?(File.join(dir, "transactions", "Amex", "Amex_2501.beancount"))
      assert File.exist?(File.join(dir, "transactions", "BBVA", "BBVA_2501.beancount"))
    end
  end

  def test_dry_run_does_not_modify_output
    with_temp_dir do |dir|
      input_path = File.join(dir, "Amex_2501.beancount")
      output_path = File.join(dir, "main.beancount")

      File.write(input_path, "2025-01-15 * \"Test\"\n  A  100 MXN\n  B")
      File.write(output_path, "original content")

      merger = Frijolero::BeancountMerger.new(
        files: [input_path],
        output: output_path,
        dry_run: true
      )
      merger.run

      assert_equal "original content", File.read(output_path)
      refute Dir.exist?(File.join(dir, "transactions"))
    end
  end

  def test_skips_duplicate_include
    with_temp_dir do |dir|
      input_path = File.join(dir, "Amex_2501.beancount")
      output_path = File.join(dir, "main.beancount")

      File.write(input_path, "2025-01-15 * \"Test\"\n  A  100 MXN\n  B")
      File.write(output_path, "include \"transactions/Amex/Amex_2501.beancount\"\n")

      FileUtils.mkdir_p(File.join(dir, "transactions", "Amex"))
      FileUtils.cp(input_path, File.join(dir, "transactions", "Amex", "Amex_2501.beancount"))

      merger = Frijolero::BeancountMerger.new(
        files: [input_path],
        output: output_path
      )
      merger.run

      lines = File.readlines(output_path).select { |l| l.include?("include") }
      assert_equal 1, lines.size
    end
  end

  def test_fallback_prefix_for_unparseable_filename
    with_temp_dir do |dir|
      input_path = File.join(dir, "custom.beancount")
      output_path = File.join(dir, "main.beancount")

      File.write(input_path, "2025-01-15 * \"Test\"\n  A  100 MXN\n  B")
      File.write(output_path, "")

      Frijolero::BeancountMerger.new(files: [input_path], output: output_path).run

      assert File.exist?(File.join(dir, "transactions", "custom", "custom.beancount"))
      assert_includes File.read(output_path), 'include "transactions/custom/custom.beancount"'
    end
  end

  def test_raises_when_no_files_provided
    with_temp_dir do |dir|
      assert_raises ArgumentError do
        merger = Frijolero::BeancountMerger.new(
          files: [],
          output: File.join(dir, "main.beancount")
        )
        merger.run
      end
    end
  end

  def test_raises_when_file_not_found
    with_temp_dir do |dir|
      assert_raises ArgumentError do
        merger = Frijolero::BeancountMerger.new(
          files: [File.join(dir, "nonexistent.beancount")],
          output: File.join(dir, "main.beancount")
        )
        merger.run
      end
    end
  end

  def test_counts_entries_correctly
    with_temp_dir do |dir|
      input_path = File.join(dir, "Amex_2501.beancount")
      output_path = File.join(dir, "main.beancount")

      File.write(input_path, <<~BEANCOUNT)
        2025-01-15 * "Transaction 1"
          Account  100 MXN
          Other

        2025-01-16 * "Transaction 2"
          Account  200 MXN
          Other

        ; This is a comment, not a transaction
      BEANCOUNT

      File.write(output_path, "")

      output = capture_io do
        merger = Frijolero::BeancountMerger.new(
          files: [input_path],
          output: output_path
        )
        merger.run
      end

      assert_includes output[0], "2 entries"
    end
  end
end
