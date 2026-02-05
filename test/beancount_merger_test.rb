# frozen_string_literal: true

require "test_helper"

class BeancountMergerTest < Minitest::Test
  include TestHelpers

  def test_merges_single_file
    with_temp_dir do |dir|
      input_path = File.join(dir, "input.beancount")
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

      content = File.read(output_path)
      assert_includes content, "; === Start: input.beancount ==="
      assert_includes content, "2025-01-15 * \"Test Transaction\""
      assert_includes content, "; === End: input.beancount ==="
    end
  end

  def test_merges_multiple_files
    with_temp_dir do |dir|
      input1 = File.join(dir, "file1.beancount")
      input2 = File.join(dir, "file2.beancount")
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
      assert_includes content, "Transaction 1"
      assert_includes content, "Transaction 2"
      assert_includes content, "; === Start: file1.beancount ==="
      assert_includes content, "; === Start: file2.beancount ==="
    end
  end

  def test_dry_run_does_not_modify_output
    with_temp_dir do |dir|
      input_path = File.join(dir, "input.beancount")
      output_path = File.join(dir, "main.beancount")

      File.write(input_path, "2025-01-15 * \"Test\"\n  A  100 MXN\n  B")
      File.write(output_path, "original content")

      merger = Frijolero::BeancountMerger.new(
        files: [input_path],
        output: output_path,
        dry_run: true
      )
      merger.run

      content = File.read(output_path)
      assert_equal "original content", content
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
      input_path = File.join(dir, "input.beancount")
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

      # Capture output
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
