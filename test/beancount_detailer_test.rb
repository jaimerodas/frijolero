# frozen_string_literal: true

require 'test_helper'

class BeancountDetailerTest < Minitest::Test
  include TestHelpers

  LEDGER = <<~BEANCOUNT
    2026-01-16 * "HIPER LUMEN DEL VALLE | Tarjeta adicional ****8549"
      Liabilities:BBVA  -800.00 MXN
      Expenses:FIXME

    2026-01-21 * "REST ALDO S GELATO | Tarjeta adicional ****8549"
      Liabilities:BBVA  -210.00 MXN
      Expenses:FIXME

    2026-01-23 * "METROBUSL1PA | Tarjeta adicional ****8549"
      Liabilities:BBVA  -6.00 MXN
      Expenses:FIXME

  BEANCOUNT

  DETAILER = {
    'start_with' => {
      'HIPER LUMEN' => { 'payee' => 'Hiper Lumen', 'account' => 'Expenses:Food:Groceries' },
      'METROBUSL1PA' => { 'payee' => 'Metrobús', 'narration' => 'Viaje', 'account' => 'Expenses:Transporte' }
    }
  }.freeze

  # Writes `ledger` and `rules` into a temp dir, runs the detailer, and yields
  # the resulting stats plus the file's contents.
  def detail(ledger: LEDGER, rules: DETAILER)
    with_temp_dir do |dir|
      ledger_path = File.join(dir, 'BBVA_2601.beancount')
      rules_path = File.join(dir, 'bbva.yaml')
      File.write(ledger_path, ledger)
      File.write(rules_path, YAML.dump(rules))

      stats = Frijolero::BeancountDetailer.new(ledger_path, rules_path).run
      return yield(stats, File.read(ledger_path, encoding: 'UTF-8'), ledger_path)
    end
  end

  def test_applies_a_rule_to_a_transaction_still_posting_to_fixme
    detail do |stats, content|
      assert_equal <<~BEANCOUNT.chomp, content.split("\n\n").first
        2026-01-16 * "Hiper Lumen" "HIPER LUMEN DEL VALLE | Tarjeta adicional ****8549"
          Liabilities:BBVA  -800.00 MXN
          Expenses:Food:Groceries
      BEANCOUNT

      assert_equal 2, stats[:detailed]
    end
  end

  def test_leaves_a_hand_edited_transaction_alone_even_when_a_rule_matches_it
    hand_edited = LEDGER.sub("  Expenses:FIXME\n\n2026-01-21", "  Expenses:Casa:Despensa\n\n2026-01-21")

    detail(ledger: hand_edited) do |stats, content|
      assert_includes content, '2026-01-16 * "HIPER LUMEN DEL VALLE | Tarjeta adicional ****8549"'
      assert_includes content, '  Expenses:Casa:Despensa'
      refute_includes content, 'Hiper Lumen'
      # Not merely "left alone": it counts as neither detailed nor remaining.
      assert_equal({ detailed: 1, remaining: 1 }, stats)
    end
  end

  def test_running_twice_leaves_the_file_byte_identical
    with_temp_dir do |dir|
      ledger_path = File.join(dir, 'BBVA_2601.beancount')
      rules_path = File.join(dir, 'bbva.yaml')
      File.write(ledger_path, LEDGER)
      File.write(rules_path, YAML.dump(DETAILER))

      Frijolero::BeancountDetailer.new(ledger_path, rules_path).run
      after_first = File.read(ledger_path, encoding: 'UTF-8')
      stats = Frijolero::BeancountDetailer.new(ledger_path, rules_path).run

      assert_equal after_first, File.read(ledger_path, encoding: 'UTF-8')
      assert_equal 0, stats[:detailed]
    end
  end

  # The previous test's ledger stops posting to FIXME after one pass, so it only
  # re-proves the FIXME guard. A rule with no `account` leaves the posting on
  # FIXME, so the transaction really is re-processed on every run — which is the
  # only case where `apply` itself has to be idempotent.
  def test_reapplying_a_rule_that_sets_no_account_is_idempotent
    rules = { 'start_with' => { 'HIPER LUMEN' => { 'payee' => 'Hiper Lumen', 'narration' => 'Despensa' } } }

    with_temp_dir do |dir|
      ledger_path = File.join(dir, 'BBVA_2601.beancount')
      rules_path = File.join(dir, 'bbva.yaml')
      File.write(ledger_path, LEDGER)
      File.write(rules_path, YAML.dump(rules))

      stats = Frijolero::BeancountDetailer.new(ledger_path, rules_path).run
      after_first = File.read(ledger_path, encoding: 'UTF-8')
      second = Frijolero::BeancountDetailer.new(ledger_path, rules_path).run

      assert_equal 1, stats[:detailed]
      assert_includes after_first, '  Expenses:FIXME'
      assert_equal 1, second[:detailed], 'still on FIXME, so it is matched again'
      assert_equal after_first, File.read(ledger_path, encoding: 'UTF-8')
    end
  end

  def test_leaves_unmatched_transactions_as_fixme_and_reports_them_as_remaining
    detail do |stats, content|
      assert_includes content, <<~BEANCOUNT
        2026-01-21 * "REST ALDO S GELATO | Tarjeta adicional ****8549"
          Liabilities:BBVA  -210.00 MXN
          Expenses:FIXME
      BEANCOUNT

      assert_equal 1, stats[:remaining]
    end
  end

  def test_records_the_original_description_when_a_rule_supplies_a_narration
    detail do |_stats, content|
      assert_includes content, <<~BEANCOUNT
        2026-01-23 * "Metrobús" "Viaje"
          source_desc: "METROBUSL1PA | Tarjeta adicional ****8549"
          Liabilities:BBVA  -6.00 MXN
          Expenses:Transporte
      BEANCOUNT
    end
  end

  def test_matches_a_when_condition_against_the_posting_amount
    rules = { 'start_with' => { 'REST ALDO' => [
      { 'when' => { 'amount' => -210 }, 'account' => 'Expenses:Food:Restaurantes' },
      { 'account' => 'Expenses:Otros' }
    ] } }

    detail(rules: rules) do |_stats, content|
      assert_includes content, '  Expenses:Food:Restaurantes'
      refute_includes content, 'Expenses:Otros'
    end
  end

  def test_preserves_hand_added_metadata_postings_and_comments
    ledger = <<~BEANCOUNT
      2026-01-16 * "HIPER LUMEN DEL VALLE"
        note: "revisar"
        ; comentario a mano
        Liabilities:BBVA  -800.00 MXN
        Expenses:FIXME
        Expenses:Otros  0.00 MXN

    BEANCOUNT

    detail(ledger: ledger) do |_stats, content|
      assert_equal <<~BEANCOUNT, content
        2026-01-16 * "Hiper Lumen" "HIPER LUMEN DEL VALLE"
          note: "revisar"
          ; comentario a mano
          Liabilities:BBVA  -800.00 MXN
          Expenses:Food:Groceries
          Expenses:Otros  0.00 MXN

      BEANCOUNT
    end
  end

  def test_skips_a_transaction_with_more_than_one_fixme_posting
    ledger = <<~BEANCOUNT
      2026-01-16 * "HIPER LUMEN DEL VALLE"
        Liabilities:BBVA  -800.00 MXN
        Expenses:FIXME  -500.00 MXN
        Expenses:FIXME  -300.00 MXN

    BEANCOUNT

    detail(ledger: ledger) do |stats, content|
      assert_equal ledger, content
      assert_equal({ detailed: 0, remaining: 0 }, stats)
    end
  end

  def test_skips_a_transaction_whose_header_cannot_be_parsed
    ledger = <<~BEANCOUNT
      2026-01-16 * "HIPER "LUMEN" DEL VALLE"
        Liabilities:BBVA  -800.00 MXN
        Expenses:FIXME

    BEANCOUNT

    detail(ledger: ledger) do |stats, content|
      assert_equal ledger, content
      assert_equal({ detailed: 0, remaining: 0 }, stats)
    end
  end

  def test_leaves_a_flagged_transaction_alone_and_out_of_the_count
    ledger = <<~BEANCOUNT
      2026-01-16 ! "HIPER LUMEN DEL VALLE | revisar"
        Liabilities:BBVA  -800.00 MXN
        Expenses:FIXME

      #{LEDGER}
    BEANCOUNT

    detail(ledger: ledger) do |stats, content|
      assert_includes content, '2026-01-16 ! "HIPER LUMEN DEL VALLE | revisar"'
      assert_equal({ detailed: 2, remaining: 1 }, stats)
    end
  end

  def test_ignores_directives_that_are_not_transactions
    ledger = <<~BEANCOUNT
      ; -*- mode: beancount -*-
      option "title" "Ledger"
      2026-01-01 open Liabilities:BBVA

      #{LEDGER}
    BEANCOUNT

    detail(ledger: ledger) do |stats, content|
      assert_includes content, 'option "title" "Ledger"'
      assert_includes content, '2026-01-01 open Liabilities:BBVA'
      assert_equal({ detailed: 2, remaining: 1 }, stats)
    end
  end

  def test_does_not_rewrite_the_file_when_nothing_matched
    with_temp_dir do |dir|
      ledger_path = File.join(dir, 'BBVA_2601.beancount')
      rules_path = File.join(dir, 'bbva.yaml')
      File.write(ledger_path, LEDGER)
      File.write(rules_path, YAML.dump('start_with' => { 'NADA' => { 'account' => 'Expenses:Nada' } }))
      before = File.mtime(ledger_path)

      Frijolero::BeancountDetailer.new(ledger_path, rules_path).run

      assert_equal before, File.mtime(ledger_path)
      assert_equal LEDGER, File.read(ledger_path)
    end
  end
end
