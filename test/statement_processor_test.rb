# frozen_string_literal: true

require "test_helper"

class StatementProcessorTest < Minitest::Test
  def test_format_amount_adds_thousands_separators_and_two_decimals
    processor = Frijolero::StatementProcessor.allocate

    assert_equal "1,234.50", processor.send(:format_amount, 1234.5)
    assert_equal "123,456,789.99", processor.send(:format_amount, 123_456_789.987)
  end

  def test_format_amount_preserves_negative_sign
    processor = Frijolero::StatementProcessor.allocate

    assert_equal "-9,876,543,210.50", processor.send(:format_amount, -9_876_543_210.5)
  end
end
