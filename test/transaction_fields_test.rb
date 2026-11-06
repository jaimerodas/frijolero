# frozen_string_literal: true

require 'test_helper'

class TransactionFieldsTest < Minitest::Test
  TransactionFields = Frijolero::TransactionFields

  PASE = <<~BEANCOUNT
    2026-08-01 * "PASE" "PASE ENT S JERONIMO"
      Liabilities:Amex-Platinum  -44.51 MXN
      Expenses:Transportation:Tolls
  BEANCOUNT

  UBER = <<~BEANCOUNT
    2026-08-01 ! "Uber" "Uber Eats"
      source_desc: "UBER EATS HTTPS://HELP.UB"
      Liabilities:Amex-Platinum  -500.58 MXN
      Expenses:Food:Delivery
  BEANCOUNT

  def test_of_a_transaction_gives_its_header_and_each_posting_by_line
    assert_equal({ flag: '!', payee: 'Uber', narration: 'Uber Eats', description: 'UBER EATS HTTPS://HELP.UB',
                   source_desc: true,
                   postings: [{ index: 2, account: 'Liabilities:Amex-Platinum', rest: '-500.58 MXN' },
                              { index: 3, account: 'Expenses:Food:Delivery', rest: '' }] }, TransactionFields.of(UBER))
    refute TransactionFields.of(PASE)[:source_desc]
  end

  def test_of_is_nil_for_a_directive_that_is_not_a_transaction
    ['2026-08-02 balance Liabilities:Amex-Platinum  -545.09 MXN', '2026-08-02 event "location" "CDMX"',
     '2026-08-02 query "cash" "SELECT 1"', '2026-08-02 * "a" "b" "c"'].each do |line|
      assert_nil TransactionFields.of("#{line}\n"), line
    end
  end

  def test_apply_keeps_the_narration_it_replaces_in_source_desc_and_changes_the_account_by_line
    text = TransactionFields.apply(PASE, payee: 'Pase', narration: 'Caseta',
                                         accounts: { '2' => 'Expenses:Transportation:Casetas' })

    assert_equal <<~BEANCOUNT, text
      2026-08-01 * "Pase" "Caseta"
        source_desc: "PASE ENT S JERONIMO"
        Liabilities:Amex-Platinum  -44.51 MXN
        Expenses:Transportation:Casetas
    BEANCOUNT
  end

  def test_apply_keeps_the_first_source_desc
    text = TransactionFields.apply(UBER, payee: 'Uber', narration: 'Cena', accounts: {})

    assert_equal [%(2026-08-01 ! "Uber" "Cena"\n), %(  source_desc: "UBER EATS HTTPS://HELP.UB"\n)], text.lines[0..1]
  end

  def test_apply_of_the_fields_as_they_were_or_an_empty_account_leaves_the_text_alone
    accounts = { '1' => 'Liabilities:Amex-Platinum', '2' => ' ' }
    text = TransactionFields.apply(PASE.gsub("\n", "\r\n"), payee: 'PASE', narration: 'PASE ENT S JERONIMO',
                                                            accounts: accounts)

    assert_equal PASE, text
  end

  def test_apply_removes_a_cleared_payee
    text = TransactionFields.apply(PASE, payee: '', narration: 'PASE ENT S JERONIMO', accounts: {})

    assert_equal %(2026-08-01 * "PASE ENT S JERONIMO"\n), text.lines.first
  end
end
