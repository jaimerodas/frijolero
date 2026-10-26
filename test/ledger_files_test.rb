# frozen_string_literal: true

require 'test_helper'

class LedgerFilesTest < Minitest::Test
  include TestHelpers

  LedgerFiles = Frijolero::LedgerFiles
  Reports = Frijolero::Reports

  # A temp ledger as the current ledger, with `main` as its main file. Yields the repo
  # directory as a real path, the way LedgerFiles answers.
  def with_main(main)
    with_ledger_dir do |dir|
      File.write(File.join(dir, 'main.beancount'), main)
      yield File.realpath(dir)
    end
  end

  def write(dir, name, text = '')
    FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
    File.write(File.join(dir, name), text)
  end

  # Another ledger on the same volume: DATA_DIR/ledgers/other/repo.
  def other_ledger(dir)
    other = File.join(dir, '..', '..', 'other', 'repo')
    write(other, 'main.beancount', "2020-01-01 open Assets:Other\n")
    File.realpath(other)
  end

  # The attack fails at every door: LedgerFiles names it, a query raises the same message,
  # and the check is one error. rledger never runs.
  def assert_refused(message)
    error = assert_raises(LedgerFiles::Unsafe) { LedgerFiles.all }
    assert_includes error.message, message
    Reports.stub(:capture, ->(*) { flunk 'rledger ran' }) do
      assert_equal error.message, assert_raises(Reports::Error) { Reports.first_date }.message
      assert_equal(['UNSAFE'], Reports.check.map { |e| e[:code] })
    end
  end

  def test_all_is_the_main_file_and_every_file_it_includes_recursively_as_real_paths
    with_main(%(include "opens.beancount"\ninclude "accounts/*/*.beancount"\n)) do |dir|
      write(dir, 'opens.beancount', %(include "sub/deeper.beancount"\n))
      write(dir, 'sub/deeper.beancount')
      write(dir, 'accounts/AMEX/AMEX 2607.beancount')

      assert_equal ['main.beancount', 'opens.beancount', 'accounts/AMEX/AMEX 2607.beancount', 'sub/deeper.beancount']
        .map { |name| File.join(dir, name) }, LedgerFiles.all
    end
  end

  # rledger's glob matches a file whose name starts with a dot, so its directives count too.
  def test_a_glob_matches_dotfiles_as_rledger_does
    with_main(%(include "*.beancount"\n)) do |dir|
      write(dir, '.hidden.beancount', %(plugin "/tmp/x.wasm"\n))

      assert_raises(LedgerFiles::Unsafe) { LedgerFiles.all }
    end
  end

  def test_an_include_that_matches_nothing_is_left_to_rledger
    with_main(%(include "missing.beancount"\ninclude "none/*.beancount"\n)) do |dir|
      assert_equal [File.join(dir, 'main.beancount')], LedgerFiles.all
    end
  end

  def test_an_include_cycle_lists_each_file_once
    with_main(%(include "a.beancount"\n)) do |dir|
      write(dir, 'a.beancount', %(include "main.beancount"\ninclude "a.beancount"\n))

      assert_equal [File.join(dir, 'main.beancount'), File.join(dir, 'a.beancount')], LedgerFiles.all
    end
  end

  def test_a_ledger_without_a_main_file_has_no_files
    with_ledger_dir { assert_empty LedgerFiles.all }
  end

  # Measured attack 1: rledger returned the transactions of the other ledger.
  def test_an_include_of_another_ledger_is_refused
    with_main(%(; prices\ninclude "../../other/repo/main.beancount"\n)) do |dir|
      other_ledger(dir)

      assert_refused 'main.beancount:2: "../../other/repo/main.beancount" está fuera del ledger'
    end
  end

  # Measured attack 2: rledger opened the file.
  def test_an_include_of_an_absolute_path_outside_the_ledger_is_refused
    with_main(%(include "/etc/hosts"\n)) { assert_refused '"/etc/hosts" está fuera del ledger' }
  end

  # Measured attack 3: rledger followed the symlink.
  def test_an_include_of_a_symlink_to_a_file_outside_the_ledger_is_refused
    with_main(%(include "prices.beancount"\n)) do |dir|
      File.symlink(File.join(other_ledger(dir), 'main.beancount'), File.join(dir, 'prices.beancount'))

      assert_refused 'main.beancount:1: "prices.beancount" está fuera del ledger'
    end
  end

  # Measured attack 4: rledger tried to load the file.
  def test_a_plugin_that_is_a_file_is_refused
    with_main(%(plugin "/tmp/x.wasm"\n)) { assert_refused 'plugin "/tmp/x.wasm" no es un plugin de rledger' }
  end

  def test_a_main_file_that_is_a_symlink_outside_the_ledger_is_refused
    with_ledger_dir do |dir|
      File.symlink(File.join(other_ledger(dir), 'main.beancount'), File.join(dir, 'main.beancount'))

      assert_refused 'main.beancount:1: el archivo principal está fuera del ledger'
    end
  end

  def test_an_unsafe_include_in_an_included_file_names_that_file_and_line
    with_main(%(include "sub/opens.beancount"\n)) do |dir|
      write(dir, 'sub/opens.beancount', %(2020-01-01 open Assets:A\ninclude "../../x.beancount"\n))

      assert_refused 'sub/opens.beancount:2:'
    end
  end

  # rledger follows an indented include, and reports only a parse error (measured).
  def test_an_indented_include_is_checked
    with_main(%(2020-01-01 open Assets:A\n  include\t"/etc/hosts"\n)) { assert_refused 'main.beancount:2:' }
  end

  def test_a_glob_that_leaves_the_ledger_is_refused
    with_main(%(include "../../*/repo/main.beancount"\n)) do |dir|
      other_ledger(dir)

      assert_refused '"../../*/repo/main.beancount" está fuera del ledger'
    end
  end

  # rledger and Ruby read these differently, so the files that the walk reads could be others.
  def test_a_path_with_brackets_braces_or_a_backslash_is_refused
    ['{a,b}*.beancount', '[ab].beancount', 'a\\/b.beancount'].each do |pattern|
      with_main(%(include "#{pattern}"\n)) { assert_refused 'Frijolero no revisa' }
    end
  end

  # Only a glob reads brackets and braces, and rledger globs only an include.
  def test_brackets_and_braces_pass_where_nothing_globs
    with_main(%(include "{a}.beancount"\n2020-01-02 document Assets:A "docs/[ene] estado.pdf"\n)) do |dir|
      write(dir, '{a}.beancount')

      assert_equal [File.join(dir, 'main.beancount'), File.join(dir, '{a}.beancount')], LedgerFiles.all
    end
  end

  def test_built_in_plugins_pass_by_name_or_by_module_path
    with_main(%(plugin "auto_accounts"\nplugin "beancount.plugins.implicit_prices" "{}"\n)) do |dir|
      assert_equal [File.join(dir, 'main.beancount')], LedgerFiles.all
    end
  end

  # Built in, but its config names the directories that it lists.
  def test_document_discovery_is_refused_as_a_plugin
    with_main(%(plugin "document_discovery" "{\\"directories\\": [\\"/data\\"]}"\n)) do
      assert_refused 'plugin "document_discovery" no es un plugin de rledger'
    end
  end

  # rledger lists the files under a documents root.
  def test_a_documents_root_outside_the_ledger_is_refused
    with_main(%(option "documents" "../../other"\n)) { assert_refused '"../../other" está fuera del ledger' }
  end

  # rledger needs memory in proportion to the text, and the container is small.
  def test_a_ledger_with_more_text_than_rledger_can_hold_is_refused
    with_main(%(include "big.beancount"\n)) do |dir|
      write(dir, 'big.beancount', ';' * LedgerFiles::MAX_BYTES)

      error = assert_raises(LedgerFiles::Unsafe) { LedgerFiles.all }
      assert_equal ['main.beancount', 1], [error.file, error.line]
      assert_includes error.problem, '4 MB'
    end
  end

  def test_a_documents_root_inside_the_ledger_passes
    with_main(%(option "documents" "docs"\n)) { |dir| assert_equal [File.join(dir, 'main.beancount')], LedgerFiles.all }
  end

  # rledger checks that the file of a document exists, which tells whether a path exists.
  def test_a_document_outside_the_ledger_is_refused
    with_main(%(2020-01-01 open Assets:A\n2020-01-02 document Assets:A "/etc/hosts"\n)) do
      assert_refused 'main.beancount:2: "/etc/hosts" está fuera del ledger'
    end
  end
end
