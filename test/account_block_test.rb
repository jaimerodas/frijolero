# frozen_string_literal: true

require 'test_helper'

class AccountBlockTest < Minitest::Test
  FIXTURE = <<~TEXT
    # Account Configuration
    # maps keys to accounts

    AMEX:
      beancount_account: "Liabilities:Amex"
      openai_prompt_type: default
    # Alpaca statements, not the advisor PDF
    Plata Investments:
      beancount_account: "Assets:Investments:Plata"
      # US tax withheld at source
      withholding_account: "Expenses:Taxes:Withholding:USA"

    Plata:
      beancount_account: "Liabilities:Plata"

  TEXT

  def test_extract_first_block
    result = Frijolero::AccountBlock.extract(FIXTURE, 'AMEX')
    expected = %(AMEX:
  beancount_account: "Liabilities:Amex"
  openai_prompt_type: default
)
    assert_equal expected, result
  end

  def test_extract_middle_block_keeps_indented_comment_and_trailing_blank
    result = Frijolero::AccountBlock.extract(FIXTURE, 'Plata Investments')
    expected = %(Plata Investments:
  beancount_account: "Assets:Investments:Plata"
  # US tax withheld at source
  withholding_account: "Expenses:Taxes:Withholding:USA"

)
    assert_equal expected, result
  end

  def test_extract_last_block
    result = Frijolero::AccountBlock.extract(FIXTURE, 'Plata')
    expected = %(Plata:
  beancount_account: "Liabilities:Plata"

)
    assert_equal expected, result
  end

  def test_extract_missing_key_returns_nil
    result = Frijolero::AccountBlock.extract(FIXTURE, 'Unknown')
    assert_nil result
  end

  def test_replace_middle_block_preserves_other_blocks_and_comments
    new_block = "Plata Investments:\n  beancount_account: \"Assets:Alpaca\""

    result = Frijolero::AccountBlock.replace(FIXTURE, 'Plata Investments', new_block)

    assert_equal <<~TEXT, result
      # Account Configuration
      # maps keys to accounts

      AMEX:
        beancount_account: "Liabilities:Amex"
        openai_prompt_type: default
      # Alpaca statements, not the advisor PDF
      Plata Investments:
        beancount_account: "Assets:Alpaca"
      Plata:
        beancount_account: "Liabilities:Plata"

    TEXT
  end

  def test_replace_without_trailing_newline_still_has_key_on_own_line
    text = "Key1:\n  value: 1\nKey2:\n  value: 2\n"
    new_block = "Key1:\n  value: 1_changed"

    result = Frijolero::AccountBlock.replace(text, 'Key1', new_block)

    # After replacement, Key2 should still start on its own line
    assert result.include?("\nKey2:")
  end

  def test_replace_missing_key_raises_key_error
    assert_raises(KeyError) do
      Frijolero::AccountBlock.replace(FIXTURE, 'Unknown', 'Block')
    end
  end
end
