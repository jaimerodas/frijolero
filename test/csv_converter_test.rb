# frozen_string_literal: true

require "test_helper"

class CsvConverterTest < Minitest::Test
  include TestHelpers

  def test_converts_json_to_csv
    with_temp_dir do |dir|
      output_path = File.join(dir, "output.csv")

      Frijolero::CsvConverter.convert(
        input: fixture_path("sample_transactions.json"),
        output: output_path
      )

      content = File.read(output_path)
      lines = content.lines

      # Check header
      assert_equal "Date,Description,Amount\n", lines[0]

      # Check data rows
      assert_includes content, "2025-01-15,AMAZON WEB SERVICES,-50.0"
      assert_includes content, "2025-01-16,STARBUCKS REFORMA,-85.0"
      assert_includes content, "2025-01-17,UBER TRIP,-120.5"
    end
  end

  def test_uses_default_output_name
    with_temp_dir do |dir|
      json_path = File.join(dir, "transactions.json")
      FileUtils.cp(fixture_path("sample_transactions.json"), json_path)

      result = Frijolero::CsvConverter.convert(input: json_path)

      assert_equal File.join(dir, "transactions.csv"), result
      assert File.exist?(result)
    end
  end

  def test_raises_without_input
    assert_raises ArgumentError do
      Frijolero::CsvConverter.convert(input: nil)
    end
  end

  def test_normalizes_whitespace_in_descriptions
    with_temp_dir do |dir|
      json_content = {
        "transactions" => [
          {
            "date" => "2025-01-15",
            "description" => "MULTIPLE   SPACES   HERE",
            "amount" => -100.0
          }
        ]
      }

      json_path = File.join(dir, "test.json")
      File.write(json_path, JSON.generate(json_content))

      output_path = File.join(dir, "output.csv")
      Frijolero::CsvConverter.convert(input: json_path, output: output_path)

      content = File.read(output_path)
      assert_includes content, "MULTIPLE SPACES HERE"
    end
  end
end
