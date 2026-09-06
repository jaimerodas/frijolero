# frozen_string_literal: true

require_relative '../test_helper'

class HelpersTest < Minitest::Test
  def setup
    @app = Frijolero::App.new!
  end

  def test_money_adds_thousands_separators_and_a_sign
    assert_equal '-1,234.50', @app.money(-1234.5)
    assert_equal '+5,276.79', @app.money(5276.79)
    assert_equal '-22.00', @app.money(-22)
    assert_equal '', @app.money(nil)
  end

  def test_split_description_at_semicolon_or_before_rfc
    assert_equal ['ABTS GRUPO CAFISON', 'Fecha de cargo: 2026-08-10'],
                 @app.split_description('ABTS GRUPO CAFISON; Fecha de cargo: 2026-08-10')
    assert_equal ['*KFC 587 PUEBLITO', 'RFCPRB100802H20 /REF0000000000'],
                 @app.split_description('*KFC 587 PUEBLITO RFCPRB100802H20 /REF0000000000')
    assert_equal ['AMAZON COM INC COM'], @app.split_description('AMAZON COM INC COM')
  end
end
