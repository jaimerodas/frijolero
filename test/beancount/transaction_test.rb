# frozen_string_literal: true

require 'test_helper'

class BeancountTransactionTest < Minitest::Test
  include TestHelpers

  FIXME = 'Expenses:FIXME'

  # Parses `text` the way the real pipeline does and wraps its first transaction.
  def transaction_for(text)
    with_temp_dir do |dir|
      path = File.join(dir, 'sample.beancount')
      File.write(path, text)
      block = Frijolero::Beancount::Parser.parse(path).find { |b| b[:type] == :transaction }
      return Frijolero::Beancount::Transaction.new(block)
    end
  end

  # Renders a transaction back to text, exactly as BeancountDetailer writes it.
  def render(transaction)
    transaction.block[:lines].join
  end

  def undetailed
    transaction_for(<<~BEANCOUNT)
      2026-01-16 * "HIPER LUMEN DEL VALLE | Tarjeta adicional ****8549"
        Liabilities:BBVA  -800.00 MXN
        Expenses:FIXME

    BEANCOUNT
  end

  def detailed
    transaction_for(<<~BEANCOUNT)
      2025-01-15 * "Amazon" "AWS"
        source_desc: "AMAZON WEB SERVICES"
        Liabilities:Amex  -50.00 USD
        Expenses:Subscriptions

    BEANCOUNT
  end

  # --- parsing -------------------------------------------------------------

  def test_reads_the_flag_and_keeps_a_flagged_transaction
    tx = transaction_for(<<~BEANCOUNT)
      2026-01-16 ! "Pendiente"
        Liabilities:BBVA  -800.00 MXN
        Expenses:FIXME

    BEANCOUNT

    assert_predicate tx, :parsed?
    assert_equal '!', tx.flag
    assert_equal '*', undetailed.flag
  end

  def test_postings_carry_their_currency
    postings = detailed.postings

    assert_equal 'USD', postings[0][:currency]
    assert_nil postings[1][:currency]
  end

  def test_reads_narration_from_a_single_string_header
    tx = undetailed

    assert_predicate tx, :parsed?
    assert_nil tx.payee
    assert_equal 'HIPER LUMEN DEL VALLE | Tarjeta adicional ****8549', tx.narration
  end

  def test_reads_payee_and_narration_from_a_two_string_header
    tx = detailed

    assert_equal 'Amazon', tx.payee
    assert_equal 'AWS', tx.narration
  end

  def test_reads_metadata
    assert_equal({ 'source_desc' => 'AMAZON WEB SERVICES' }, detailed.metadata)
  end

  def test_description_falls_back_to_narration_when_there_is_no_source_desc
    assert_equal 'HIPER LUMEN DEL VALLE | Tarjeta adicional ****8549', undetailed.description
  end

  def test_description_prefers_source_desc_over_narration
    assert_equal 'AMAZON WEB SERVICES', detailed.description
  end

  def test_reads_the_amount_of_the_first_posting_that_carries_one
    assert_equal BigDecimal('-800'), undetailed.amount
  end

  def test_reads_a_thousands_separated_amount
    tx = transaction_for(<<~BEANCOUNT)
      2026-01-07 * "BMOVIL.PAGO TDC"
        Liabilities:BBVA  23,961.07 MXN
        Expenses:FIXME

    BEANCOUNT

    assert_equal BigDecimal('23961.07'), tx.amount
  end

  def test_finds_postings_by_account
    indexes = undetailed.postings_to(FIXME).map { |p| p[:index] }

    assert_equal [2], indexes
    assert_empty detailed.postings_to(FIXME)
  end

  def test_unescapes_quotes_in_the_narration
    tx = transaction_for(<<~'BEANCOUNT')
      2026-01-16 * "REST \"EL FOGON\""
        Liabilities:BBVA  -800.00 MXN
        Expenses:FIXME

    BEANCOUNT

    assert_equal 'REST "EL FOGON"', tx.narration
  end

  # Beancount interprets \n \t \r \" \\ and drops the backslash on anything else
  # ("A\BB" reads as "ABB"). Round-tripping has to mean the same thing after.
  def test_round_trips_the_escapes_beancount_interprets
    { 'A\tB' => "A\tB", 'A\nB' => "A\nB", 'A\"B' => 'A"B', 'A\\\\B' => 'A\\B' }.each do |on_disk, value|
      tx = transaction_for(%(2026-01-16 * "#{on_disk}"\n  Liabilities:BBVA  -1.00 MXN\n  Expenses:FIXME\n))

      assert_equal value, tx.narration, "reading #{on_disk}"

      tx.apply(payee: 'P', posting_index: 2, account: 'Expenses:X')

      assert_includes render(tx), %("P" "#{on_disk}"), "writing #{on_disk} back"
    end
  end

  def test_normalizes_an_escape_beancount_would_have_discarded_anyway
    tx = transaction_for(%(2026-01-16 * "PAGO A\\B TIENDA"\n  Liabilities:BBVA  -1.00 MXN\n  Expenses:FIXME\n))

    assert_equal 'PAGO AB TIENDA', tx.narration
  end

  def test_reads_the_amount_of_a_posting_with_a_non_ascii_account_name
    tx = transaction_for(<<~BEANCOUNT)
      2026-01-16 * "CAFE"
        Liabilities:Café  -800.00 MXN
        Expenses:FIXME
    BEANCOUNT

    assert_equal BigDecimal('-800'), tx.amount
  end

  def test_rejects_a_header_it_cannot_parse_unambiguously
    # An unescaped quote inside the narration: the converter never escapes, so
    # this is what an ill-behaved description looks like on disk.
    tx = transaction_for(<<~BEANCOUNT)
      2026-01-16 * "REST "EL FOGON" DEL VALLE"
        Liabilities:BBVA  -800.00 MXN
        Expenses:FIXME

    BEANCOUNT

    refute_predicate tx, :parsed?
  end

  def test_keeps_tags_and_links_out_of_the_narration
    tx = transaction_for(<<~BEANCOUNT)
      2026-01-16 * "Comida" "Cena" #viaje ^recibo-1
        Liabilities:BBVA  -800.00 MXN
        Expenses:FIXME

    BEANCOUNT

    assert_predicate tx, :parsed?
    assert_equal 'Cena', tx.narration
  end

  # --- applying ------------------------------------------------------------

  def test_apply_rewrites_the_payee_and_the_targeted_posting
    tx = undetailed
    tx.apply(payee: 'Hiper Lumen', account: 'Expenses:Food:Groceries', posting_index: 2)

    assert_equal <<~BEANCOUNT, render(tx)
      2026-01-16 * "Hiper Lumen" "HIPER LUMEN DEL VALLE | Tarjeta adicional ****8549"
        Liabilities:BBVA  -800.00 MXN
        Expenses:Food:Groceries

    BEANCOUNT
  end

  def test_apply_records_the_original_description_when_a_rule_supplies_a_narration
    tx = undetailed
    tx.apply(payee: 'Hiper Lumen', narration: 'Despensa', account: 'Expenses:Food:Groceries', posting_index: 2)

    assert_equal <<~BEANCOUNT, render(tx)
      2026-01-16 * "Hiper Lumen" "Despensa"
        source_desc: "HIPER LUMEN DEL VALLE | Tarjeta adicional ****8549"
        Liabilities:BBVA  -800.00 MXN
        Expenses:Food:Groceries

    BEANCOUNT
  end

  def test_apply_output_matches_what_the_json_converter_would_have_produced
    # No trailing blank line here: Converters::Default does not emit one, so
    # this compares the rendering alone.
    tx = transaction_for(<<~BEANCOUNT)
      2026-01-16 * "HIPER LUMEN DEL VALLE | Tarjeta adicional ****8549"
        Liabilities:BBVA  -800.00 MXN
        Expenses:FIXME
    BEANCOUNT
    tx.apply(payee: 'Hiper Lumen', narration: 'Despensa', account: 'Expenses:Food:Groceries', posting_index: 2)

    from_json = convert_json(
      'date' => '2026-01-16',
      'description' => 'HIPER LUMEN DEL VALLE | Tarjeta adicional ****8549',
      'payee' => 'Hiper Lumen',
      'narration' => 'Despensa',
      'amount' => -800.0,
      'expense_account' => 'Expenses:Food:Groceries'
    )

    assert_equal from_json, render(tx)
  end

  def test_apply_does_not_duplicate_an_existing_source_desc
    tx = detailed
    tx.apply(narration: 'Amazon Web Services')

    assert_equal 1, render(tx).scan('source_desc:').size
    assert_includes render(tx), 'source_desc: "AMAZON WEB SERVICES"'
  end

  def test_apply_preserves_hand_added_metadata_postings_and_comments
    tx = transaction_for(<<~BEANCOUNT)
      2026-01-16 * "HIPER LUMEN DEL VALLE"
        note: "revisar"
        ; comentario a mano
        Liabilities:BBVA  -800.00 MXN
        Expenses:FIXME
        Expenses:Otros  -0.00 MXN

    BEANCOUNT

    tx.apply(payee: 'Hiper Lumen', account: 'Expenses:Food:Groceries', posting_index: 4)

    assert_equal <<~BEANCOUNT, render(tx)
      2026-01-16 * "Hiper Lumen" "HIPER LUMEN DEL VALLE"
        note: "revisar"
        ; comentario a mano
        Liabilities:BBVA  -800.00 MXN
        Expenses:Food:Groceries
        Expenses:Otros  -0.00 MXN

    BEANCOUNT
  end

  def test_apply_escapes_quotes_it_writes_back
    tx = undetailed
    tx.apply(payee: 'Rest "El Fogon"', posting_index: 2, account: 'Expenses:Food')

    assert_includes render(tx), '* "Rest \"El Fogon\"" "HIPER LUMEN'
    assert_equal 'Rest "El Fogon"', transaction_for(render(tx)).payee
  end

  def test_apply_leaves_the_flag_alone
    tx = undetailed
    tx.apply(account: 'Expenses:Food', posting_index: 2)

    assert_match(/\A2026-01-16 \* /, render(tx))
  end

  private

  def convert_json(transaction)
    with_temp_dir do |dir|
      input = File.join(dir, 'in.json')
      output = File.join(dir, 'out.beancount')
      File.write(input, JSON.generate('transactions' => [transaction]))
      Frijolero::Converters::Default.convert(input: input, account: 'Liabilities:BBVA', output: output)
      return File.read(output)
    end
  end
end
