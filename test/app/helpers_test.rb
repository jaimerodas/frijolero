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

  def test_beancount_html_wraps_directives_postings_and_comments
    html = @app.beancount_html(<<~BEAN)
      ; nota <b>
      2026-08-04 * "Amazon" "AMAZON COM"
        source_desc: "AMAZON COM"
        Liabilities:AMEX  -1,234.50 MXN
        Expenses:FIXME
      2026-08-31 balance Liabilities:AMEX  -5000.00 MXN
    BEAN
    assert_includes html, '<span class="bc-comment">; nota &lt;b&gt;</span>'
    assert_includes html, '<span class="bc-date">2026-08-04</span> <span class="bc-flag">*</span> ' \
                          '&quot;Amazon&quot; &quot;AMAZON COM&quot;'
    assert_includes html, '  source_desc: &quot;AMAZON COM&quot;'
    assert_includes html, '  <span class="bc-account">Liabilities:AMEX</span>  <span class="debit">-1,234.50 MXN</span>'
    assert_includes html, '  <span class="bc-account bc-fixme">Expenses:FIXME</span>'
    assert_includes html, '<span class="bc-date">2026-08-31</span> <span class="bc-flag">balance</span> ' \
                          '<span class="bc-account">Liabilities:AMEX</span>  <span class="debit">-5000.00 MXN</span>'
  end

  def test_beancount_html_keeps_strings_plain_and_marks_flagged_transactions
    assert_equal '<span class="bc-date">2026-08-04</span> <span class="bc-flag bc-warn">!</span> ' \
                 '&quot;Pago; Assets:Cash&quot;',
                 @app.beancount_html('2026-08-04 ! "Pago; Assets:Cash"')
  end

  def test_beancount_html_leaves_unknown_lines_escaped
    assert_equal "option &quot;title&quot; &lt;x&gt;\n", @app.beancount_html(%(option "title" <x>\n))
    assert_equal '  <span class="bc-account">Assets:Cash</span>  <span class="credit">1.00 USD</span>',
                 @app.beancount_html('  Assets:Cash  1.00 USD')
  end
end
