# frozen_string_literal: true

require_relative '../test_helper'

class AmountsTest < Minitest::Test
  include Frijolero::Converters::Amounts

  def test_group_puts_commas_in_the_first_run_of_digits
    assert_equal '-1,234,567.89', Frijolero::Converters::Amounts.group('-1234567.89')
    assert_equal '999.50', Frijolero::Converters::Amounts.group('999.50')
    assert_equal '1,000', Frijolero::Converters::Amounts.group(1000)
  end

  def test_money_groups_thousands_and_keeps_two_decimals
    assert_equal '1,234,567.80', money('1234567.8')
    assert_equal '-15,596.89', money(-15_596.89)
    assert_equal '999.00', money(999)
    assert_equal '0.00', money(nil)
  end

  def test_number_groups_thousands_and_drops_a_whole_fraction
    assert_equal '11,042', number('11042')
    assert_equal '-4,566', number(-4566)
    assert_equal '1,234.567891', number('1234.567891')
    assert_equal '0.5', number('0.5')
  end
end
