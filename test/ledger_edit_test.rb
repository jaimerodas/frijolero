# frozen_string_literal: true

require 'test_helper'

class LedgerEditTest < Minitest::Test
  include TestHelpers

  LedgerEdit = Frijolero::LedgerEdit

  LEDGER = <<~BEANCOUNT
    2026-08-01 * "PASE" "PASE ENT S JERONIMO"
      Liabilities:Amex-Platinum  -44.51 MXN
      Expenses:Transportation:Tolls
    2026-08-01 ! "Uber" "Uber Eats"
      source_desc: "UBER EATS HTTPS://HELP.UB"
      Liabilities:Amex-Platinum  -500.58 MXN
      Expenses:Food:Delivery

    2026-08-02 balance Liabilities:Amex-Platinum  -545.09 MXN
  BEANCOUNT

  # A checker that answers with a fixed list and remembers whether it ran.
  class Checker
    attr_reader :calls

    def initialize(errors = [])
      @errors = errors
      @calls = 0
    end

    def check
      @calls += 1
      @errors
    end
  end

  def with_ledger
    with_ledger_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'accounts', 'AMEX'))
      File.write(File.join(dir, 'accounts', 'AMEX', 'AMEX 2607.beancount'), LEDGER)
      yield dir
    end
  end

  def statement_path(dir)
    File.join(dir, 'accounts', 'AMEX', 'AMEX 2607.beancount')
  end

  def edit(line, file: 'accounts/AMEX/AMEX 2607.beancount', checker: Checker.new)
    LedgerEdit.new(file: file, line: line, checker: checker)
  end

  def test_block_from_a_posting_line_walks_back_to_the_header
    with_ledger do
      block = edit(3).block

      assert_equal({ first: 1, last: 3, text: LEDGER.lines[0..2].join }, block)
    end
  end

  def test_block_from_the_header_line_itself
    with_ledger { assert_equal 1, edit(1).block[:first] }
  end

  def test_block_stops_at_a_blank_line_and_finds_a_flagged_transaction
    with_ledger do
      block = edit(6).block

      assert_equal 4, block[:first]
      assert_equal 7, block[:last]
      assert_equal LEDGER.lines[3..6].join, block[:text]
    end
  end

  def test_block_of_a_lone_directive_is_one_line
    with_ledger { assert_equal({ first: 9, last: 9, text: LEDGER.lines[8] }, edit(9).block) }
  end

  def test_block_raises_when_the_line_is_past_the_end_or_has_no_header
    with_ledger do
      assert_raises(LedgerEdit::NotFound) { edit(40).block }
      assert_raises(LedgerEdit::NotFound) { edit(0).block }
      File.write(statement_path(Frijolero::Config.ledger_dir), "; only\n")
      assert_raises(LedgerEdit::NotFound) { edit(1).block }
    end
  end

  def test_file_must_be_a_beancount_file_inside_the_ledger
    with_ledger do |dir|
      File.write(File.join(dir, 'config', 'accounts.yaml'), "2026-01-01 x\n")
      File.write(File.join(File.dirname(dir), 'outside.beancount'), "2026-01-01 x\n")
      ['config/accounts.yaml', '../outside.beancount', "#{File.dirname(dir)}/outside.beancount",
       'accounts/AMEX/../../../outside.beancount', 'accounts/AMEX/nope.beancount'].each do |file|
        assert_raises(LedgerEdit::NotFound, file) { edit(1, file: file).block }
      end
    ensure
      FileUtils.rm_f(File.join(File.dirname(dir), 'outside.beancount'))
    end
  end

  def test_save_replaces_the_block_and_keeps_the_rest
    with_ledger do |dir|
      original = LEDGER.lines[0..2].join
      expected = original.sub('PASE ENT S JERONIMO', 'Caseta')
      edited = "#{expected.gsub("\n", "\r\n")}\r\n"

      text = edit(2).save(original: original, edited: edited)

      assert_equal expected, text
      assert_equal expected + LEDGER.lines[3..].join, File.read(statement_path(dir))
    end
  end

  def test_save_refuses_when_the_original_no_longer_matches
    with_ledger do |dir|
      checker = Checker.new
      assert_raises(LedgerEdit::Stale) do
        edit(2, checker: checker).save(original: "2026-08-01 * \"other\"\n", edited: 'x')
      end

      assert_equal 0, checker.calls
      assert_equal LEDGER, File.read(statement_path(dir))
    end
  end

  def test_save_restores_the_file_when_the_check_fails
    with_ledger do |dir|
      checker = Checker.new(['E1001 Account Expenses:Nope was never opened (accounts/AMEX/AMEX 2607.beancount:1)'])
      error = assert_raises(LedgerEdit::Invalid) do
        edit(2, checker: checker).save(original: LEDGER.lines[0..2].join,
                                       edited: "2026-08-01 * \"x\"\n  Expenses:Nope  1 MXN\n")
      end

      assert_equal 1, checker.calls
      assert_equal checker.check.join("\n"), error.message
      assert_equal LEDGER, File.read(statement_path(dir))
    end
  end

  def test_save_restores_the_file_when_the_checker_raises
    with_ledger do |dir|
      checker = Object.new
      def checker.check = raise(Frijolero::Reports::Error, 'sin rledger')
      assert_raises(Frijolero::Reports::Error) do
        edit(2, checker: checker).save(original: LEDGER.lines[0..2].join, edited: "2026-08-01 * \"x\"\n")
      end

      assert_equal LEDGER, File.read(statement_path(dir))
    end
  end

  def test_commit_message_names_the_statement_and_the_transaction_with_before_and_after
    with_ledger do
      original = LEDGER.lines[0..2].join
      edited = original.sub('Tolls', 'Casetas')

      message = edit(2).commit_message(original: original, edited: edited)

      assert_equal "Edición AMEX 2607: 2026-08-01 PASE\n\nAntes:\n#{original}\nDespués:\n#{edited}", message
    end
  end

  def test_commit_message_falls_back_to_the_file_and_the_narration
    with_ledger do
      original = "2026-07-20 ! \"Nómina\"\n  Assets:BBVA  1 MXN\n"

      message = edit(1, file: 'transactions.beancount').commit_message(original: original, edited: original)

      assert_equal 'Edición transactions.beancount: 2026-07-20 Nómina', message.lines.first.chomp
    end
  end
end
