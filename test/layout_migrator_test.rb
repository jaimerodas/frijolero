# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class LayoutMigratorTest < Minitest::Test
  include TestHelpers

  def setup
    @accounts_yaml = <<~YAML
      Amex:
        beancount_account: "Liabilities:Amex"
      BBVA:
        beancount_account: "Assets:BBVA"
    YAML
  end

  def with_legacy_layout
    with_temp_config_dir do |config_dir|
      File.write(File.join(config_dir, 'accounts.yaml'), @accounts_yaml)
      Frijolero::Config.reload!

      Dir.mktmpdir do |old_root|
        Dir.mktmpdir do |new_root|
          seed_legacy_layout(old_root, new_root)
          yield old_root, new_root
        end
      end
    end
  end

  def seed_legacy_layout(old_root, new_root)
    FileUtils.mkdir_p(File.join(old_root, 'beancount'))
    FileUtils.mkdir_p(File.join(old_root, 'json'))
    FileUtils.mkdir_p(File.join(old_root, 'processed'))
    FileUtils.mkdir_p(File.join(new_root, 'transactions', 'Amex'))

    File.write(File.join(old_root, 'beancount', 'Amex_2501.beancount'), beancount_body)
    File.write(File.join(new_root, 'transactions', 'Amex', 'Amex_2501.beancount'), beancount_body)
    File.write(File.join(new_root, 'transactions', 'Amex', 'Amex_2502.beancount'), beancount_body('2025-02-15'))
    File.write(File.join(old_root, 'json', 'Amex_2501.json'), '{"transactions":[]}')
    File.write(File.join(old_root, 'processed', 'Amex 2501.pdf'), 'pdf-bytes-1')

    File.write(File.join(new_root, 'main.beancount'), <<~LEDGER)
      include "transactions/Amex/Amex_2501.beancount"
      include "transactions/Amex/Amex_2502.beancount"
    LEDGER
  end

  def beancount_body(date = '2025-01-15')
    <<~BEANCOUNT
      #{date} * "Test"
        Liabilities:Amex  -100.00 MXN
        Expenses:FIXME
    BEANCOUNT
  end

  def migrator(old_root, new_root, **opts)
    Frijolero::LayoutMigrator.new(
      old_root: old_root,
      new_root: new_root,
      main_file: File.join(new_root, 'main.beancount'),
      io: opts.delete(:io) || StringIO.new,
      stdin: opts.delete(:stdin) || StringIO.new(''),
      **opts
    )
  end

  def test_dry_run_touches_nothing
    with_legacy_layout do |old_root, new_root|
      io = StringIO.new
      result = migrator(old_root, new_root, io: io).run

      assert_equal :dry_run, result
      assert File.exist?(File.join(old_root, 'beancount', 'Amex_2501.beancount'))
      refute File.exist?(File.join(new_root, 'Amex', 'Amex_2501.beancount'))
      assert_includes io.string, 'Migration plan'
    end
  end

  def test_apply_with_no_prompt_keeps_originals_and_creates_new_layout
    with_legacy_layout do |old_root, new_root|
      result = migrator(old_root, new_root, apply: true, prompt: false).run

      assert_equal :kept, result

      # New layout populated
      assert File.exist?(File.join(new_root, 'Amex', 'Amex_2501.beancount'))
      assert File.exist?(File.join(new_root, 'Amex', 'Amex_2502.beancount'))
      assert File.exist?(File.join(new_root, 'Amex', 'json', 'Amex_2501.json'))
      assert File.exist?(File.join(new_root, 'Amex', 'pdf', 'Amex_2501.pdf'))

      # Originals retained
      assert File.exist?(File.join(old_root, 'beancount', 'Amex_2501.beancount'))
      assert File.exist?(File.join(old_root, 'json', 'Amex_2501.json'))
      assert File.exist?(File.join(old_root, 'processed', 'Amex 2501.pdf'))

      # Main beancount rewritten with timestamped backup
      content = File.read(File.join(new_root, 'main.beancount'))
      assert_includes content, 'include "Amex/Amex_2501.beancount"'
      refute_includes content, 'transactions/Amex'

      backups = Dir.glob(File.join(new_root, 'main.beancount.bak.*'))
      assert_equal 1, backups.size, 'expected exactly one timestamped backup'
    end
  end

  def test_apply_with_yes_prompt_deletes_originals
    with_legacy_layout do |old_root, new_root|
      result = migrator(old_root, new_root, apply: true, prompt: true,
                                            stdin: StringIO.new("yes\n")).run

      assert_equal :deleted, result
      refute File.exist?(File.join(old_root, 'beancount', 'Amex_2501.beancount'))
      refute File.exist?(File.join(old_root, 'json', 'Amex_2501.json'))
      refute File.exist?(File.join(old_root, 'processed', 'Amex 2501.pdf'))

      # Live ledger copies are also cleaned out
      refute File.exist?(File.join(new_root, 'transactions', 'Amex', 'Amex_2501.beancount'))
      refute File.exist?(File.join(new_root, 'transactions', 'Amex', 'Amex_2502.beancount'))

      # Empty subdirs are cleaned up
      refute Dir.exist?(File.join(old_root, 'beancount'))
      refute Dir.exist?(File.join(new_root, 'transactions'))
    end
  end

  def test_apply_with_blank_prompt_keeps_originals
    with_legacy_layout do |old_root, new_root|
      result = migrator(old_root, new_root, apply: true, prompt: true,
                                            stdin: StringIO.new("\n")).run

      assert_equal :kept, result
      assert File.exist?(File.join(old_root, 'beancount', 'Amex_2501.beancount'))
    end
  end

  def test_divergent_duplicate_reported_as_conflict
    with_legacy_layout do |old_root, new_root|
      # Make beancount/ version diverge from transactions/ version
      File.write(File.join(old_root, 'beancount', 'Amex_2501.beancount'), 'DIFFERENT CONTENT')

      io = StringIO.new
      migrator(old_root, new_root, apply: true, prompt: false, io: io).run

      assert_includes io.string, 'differs from transactions/ source'
      # The transactions/ source wins
      dst = File.join(new_root, 'Amex', 'Amex_2501.beancount')
      assert_equal beancount_body, File.read(dst)
    end
  end

  def test_normalizes_capitalization_from_accounts_yaml
    with_legacy_layout do |old_root, new_root|
      # The dir matches accounts.yaml ("Amex"), but the filename screams in caps
      File.write(File.join(new_root, 'transactions', 'Amex', 'AMEX_2503.beancount'), beancount_body('2025-03-15'))

      migrator(old_root, new_root, apply: true, prompt: false).run

      # File ends up with the canonical Amex_ prefix (case-sensitive check)
      entries = Dir.entries(File.join(new_root, 'Amex'))
      assert_includes entries, 'Amex_2503.beancount'
      refute_includes entries, 'AMEX_2503.beancount'
    end
  end

  def test_renames_directory_to_canonical_when_dir_disagrees
    with_legacy_layout do |old_root, new_root|
      # Case-mismatched dir; accounts.yaml key is "BBVA"
      FileUtils.mkdir_p(File.join(new_root, 'transactions', 'bbva'))
      File.write(File.join(new_root, 'transactions', 'bbva', 'bbva_2504.beancount'), beancount_body('2025-04-15'))

      migrator(old_root, new_root, apply: true, prompt: false).run

      # Canonical dir + file (case-sensitive check via Dir.entries)
      root_entries = Dir.entries(new_root)
      assert_includes root_entries, 'BBVA'
      bbva_entries = Dir.entries(File.join(new_root, 'BBVA'))
      assert_includes bbva_entries, 'BBVA_2504.beancount'
      refute_includes bbva_entries, 'bbva_2504.beancount'
    end
  end

  def test_unknown_account_passes_through_with_warning
    with_legacy_layout do |old_root, new_root|
      FileUtils.mkdir_p(File.join(new_root, 'transactions', 'Mystery'))
      File.write(File.join(new_root, 'transactions', 'Mystery', 'Mystery_2505.beancount'), beancount_body('2025-05-15'))

      io = StringIO.new
      migrator(old_root, new_root, apply: true, prompt: false, io: io).run

      assert File.exist?(File.join(new_root, 'Mystery', 'Mystery_2505.beancount'))
      assert_includes io.string, 'Unknown accounts'
      assert_includes io.string, 'Mystery'
    end
  end

  def test_rewritten_main_includes_match_renamed_files
    with_legacy_layout do |old_root, new_root|
      File.write(File.join(new_root, 'transactions', 'Amex', 'AMEX_2506.beancount'), beancount_body('2025-06-15'))
      File.write(File.join(new_root, 'main.beancount'), <<~LEDGER)
        include "transactions/Amex/AMEX_2506.beancount"
      LEDGER

      result = migrator(old_root, new_root, apply: true, prompt: false).run

      refute_equal :aborted, result, 'include must resolve to renamed file, not abort'
      assert_includes File.read(File.join(new_root, 'main.beancount')),
                      'include "Amex/Amex_2506.beancount"'
    end
  end

  def test_hand_edited_transactions_copy_wins_over_beancount_archive
    with_legacy_layout do |old_root, new_root|
      # Simulate a hand-edit to the live ledger copy after conversion
      edited = beancount_body.sub('FIXME', 'Hand-Edited:Category')
      File.write(File.join(new_root, 'transactions', 'Amex', 'Amex_2501.beancount'), edited)

      migrator(old_root, new_root, apply: true, prompt: false).run

      dst = File.join(new_root, 'Amex', 'Amex_2501.beancount')
      assert_equal edited, File.read(dst),
                   'the hand-edited transactions/ copy must win over the unedited beancount/ archive'
    end
  end

  def test_idempotent_second_run_makes_no_new_copies
    with_legacy_layout do |old_root, new_root|
      migrator(old_root, new_root, apply: true, prompt: false).run
      mtime = File.mtime(File.join(new_root, 'Amex', 'Amex_2501.beancount'))

      migrator(old_root, new_root, apply: true, prompt: false).run
      assert_equal mtime, File.mtime(File.join(new_root, 'Amex', 'Amex_2501.beancount'))
    end
  end

  def test_unparseable_pdf_listed_as_unhandled
    with_legacy_layout do |old_root, new_root|
      File.write(File.join(old_root, 'processed', 'garbage.pdf'), 'bytes')

      io = StringIO.new
      migrator(old_root, new_root, apply: true, prompt: false, io: io).run

      assert_includes io.string, 'garbage.pdf'
      assert_includes io.string, 'unparseable PDF filename'
      refute File.exist?(File.join(new_root, 'garbage', 'pdf', 'garbage.pdf'))
    end
  end

  def test_destination_with_different_bytes_is_not_overwritten
    with_legacy_layout do |old_root, new_root|
      dst = File.join(new_root, 'Amex', 'Amex_2501.beancount')
      FileUtils.mkdir_p(File.dirname(dst))
      File.write(dst, 'PRE-EXISTING - DO NOT OVERWRITE')

      io = StringIO.new
      migrator(old_root, new_root, apply: true, prompt: false, io: io).run

      assert_equal 'PRE-EXISTING - DO NOT OVERWRITE', File.read(dst)
      assert_includes io.string, 'destination already exists with different contents'
    end
  end

  def test_dangling_include_after_rewrite_restores_backup_and_aborts
    with_legacy_layout do |old_root, new_root|
      # Add an include referencing a transactions/ file that doesn't exist
      File.write(File.join(new_root, 'main.beancount'), <<~LEDGER)
        include "transactions/Amex/Amex_2501.beancount"
        include "transactions/Amex/Amex_9999.beancount"
      LEDGER

      io = StringIO.new
      result = migrator(old_root, new_root, apply: true, prompt: false, io: io).run

      assert_equal :aborted, result
      assert_includes io.string, 'dangling include'

      # main.beancount restored to its pre-rewrite contents
      assert_includes File.read(File.join(new_root, 'main.beancount')),
                      'include "transactions/Amex/Amex_9999.beancount"'
    end
  end
end
