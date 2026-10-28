# frozen_string_literal: true

require_relative 'test_helper'

class LedgerTest < Minitest::Test
  include TestHelpers

  def setup
    enter_db_ledger
    @owner = Frijolero::Ledger.find('test').owner_id
  end

  def teardown = leave_test_ledger

  def test_create_gives_a_ledger_its_own_id_prefix_and_directory
    ledger = Frijolero::Ledger.create(owner_id: @owner, name: 'Casa')

    assert_match(/\A[a-z0-9]{8}\z/, ledger.id)
    assert_equal [@owner, 'Casa', 'main.beancount', "frijolero/ledgers/#{ledger.id}"],
                 [ledger.owner_id, ledger.name, ledger.main_file, ledger.pdf_prefix]
    assert_equal File.join(ENV.fetch('DATA_DIR'), 'ledgers', ledger.id), ledger.dir
    assert_path_exists ledger.dir
    refute_path_exists ledger.repo_dir, 'the caller makes the repo'
  end

  def test_update_changes_the_name_the_main_file_and_the_remote
    Frijolero::Ledger.update('test', name: 'Otra', main_file: 'moneys.beancount',
                                     remote_url: 'git@github.com:yo/ledger.git')

    assert_equal ['Otra', 'moneys.beancount', 'git@github.com:yo/ledger.git'],
                 row('test').values_at('name', 'main_file', 'remote_url')
  end

  def test_update_changes_no_other_column
    assert_raises(ArgumentError) { Frijolero::Ledger.update('test', name: 'Otra', pdf_prefix: 'otro') }

    assert_equal %w[Prueba frijolero], row('test').values_at('name', 'pdf_prefix')
  end

  # The app appends to the main file, so a path out of the ledger would write to another one.
  def test_update_keeps_the_main_file_in_the_root_of_the_ledger
    ['../otro/main.beancount', '/etc/hosts', 'notas.txt'].each do |main_file|
      assert_raises(ArgumentError, main_file) { Frijolero::Ledger.update('test', main_file: main_file) }
    end

    assert_equal 'main.beancount', row('test')['main_file']
  end

  # The ids sort the other way, so only created_at gives this order.
  def test_owned_by_lists_the_ledgers_of_one_owner_oldest_first
    other = Frijolero::DB.insert("INSERT INTO users (email, created_at) VALUES ('b@example.com', ?)", '2020-01-01')
    insert_ledger('zzzz', @owner, '2020-01-01T00:00:00Z')
    insert_ledger('aaaa', @owner, '2021-01-01T00:00:00Z')
    insert_ledger('ajeno', other, '2019-01-01T00:00:00Z')

    ledgers = Frijolero::Ledger.owned_by(@owner)

    assert_equal %w[zzzz aaaa test], ledgers.map(&:id)
    assert_equal Frijolero::Ledger.find('zzzz'), ledgers.first
  end

  # A second thread waits for the lock of the same ledger, but not for another ledger's.
  def test_lock_holds_one_ledger_at_a_time
    order = Queue.new
    inside = Queue.new
    holder = Thread.new do
      Frijolero::Ledger.lock('test') do
        inside << true
        sleep 0.2
        order << :first
      end
    end
    inside.pop
    Frijolero::Ledger.lock('otro') { order << :other }
    Frijolero::Ledger.lock('test') { order << :second }
    holder.join

    assert_equal %i[other first second], Array.new(3) { order.pop }
  end

  def test_lock_is_reentrant_and_defaults_to_the_current_ledger
    assert_equal(:ok, Frijolero::Ledger.lock { Frijolero::Ledger.lock('test') { :ok } })
  end

  def test_destroy_deletes_the_pdfs_the_directory_and_the_rows_and_keeps_the_usage
    ledger, pdfs = ledger_with_data

    Frijolero::Ledger.destroy(ledger, pdfs)

    assert_empty pdfs.list("#{ledger.pdf_prefix}/accounts/AMEX/")
    assert_equal 1, pdfs.list('frijolero/ledgers/otro/accounts/AMEX/').size, "another ledger's PDF stays"
    refute_path_exists ledger.dir
    assert_nil Frijolero::Ledger.find(ledger.id)
    assert_empty Frijolero::ApiTokens.for_ledger(ledger.id)
    assert_equal [{ 'cost_micros' => 5 }], Frijolero::DB.execute('SELECT cost_micros FROM usage WHERE ledger_id = ?',
                                                                 ledger.id)
  end

  # The adopted ledger keeps its PDFs under frijolero, which holds every other ledger's.
  def test_destroy_refuses_a_ledger_that_shares_its_prefix
    assert_raises(ArgumentError) { Frijolero::Ledger.destroy(Frijolero::Ledger.find('test'), nil) }

    assert Frijolero::Ledger.find('test')
    assert_path_exists Frijolero::Ledger.find('test').repo_dir
  end

  # The row stays, so the person can delete again.
  def test_a_bucket_failure_leaves_the_directory_and_the_row
    ledger, = ledger_with_data
    failing = Object.new
    def failing.delete_prefix(_) = raise(Frijolero::S3::Error, 'S3 DELETE failed (503)')

    assert_raises(Frijolero::S3::Error) { Frijolero::Ledger.destroy(ledger, failing) }

    assert_path_exists ledger.repo_dir
    assert Frijolero::Ledger.find(ledger.id)
  end

  private

  # A ledger of its own, with a file, an API token, a usage row and a PDF, next to the PDF
  # of another ledger. Returns [ledger, the PDF store].
  def ledger_with_data
    ledger = Frijolero::Ledger.create(owner_id: @owner, name: 'Casa')
    FileUtils.mkdir_p(ledger.repo_dir)
    File.write(File.join(ledger.repo_dir, 'main.beancount'), '')
    Frijolero::ApiTokens.create(ledger.id, 'iPhone')
    Frijolero::DB.execute('INSERT INTO usage (user_id, ledger_id, prompt, model, input_tokens, output_tokens, ' \
                          "cost_micros, at) VALUES (?, ?, 'default', 'm', 1, 1, 5, '2026-10-01T00:00:00Z')",
                          @owner, ledger.id)
    pdfs = Frijolero::LocalPdfs.new(File.join(ENV.fetch('DATA_DIR'), 'bucket'))
    pdf = File.join(ledger.dir, 'in.pdf')
    File.write(pdf, 'pdf')
    pdfs.put("#{ledger.pdf_prefix}/accounts/AMEX/AMEX 2608.pdf", pdf)
    pdfs.put('frijolero/ledgers/otro/accounts/AMEX/AMEX 2608.pdf', pdf)
    [ledger, pdfs]
  end

  def row(id) = Frijolero::DB.first('SELECT * FROM ledgers WHERE id = ?', id)

  def insert_ledger(id, owner, created_at)
    Frijolero::DB.execute('INSERT INTO ledgers (id, owner_id, name, pdf_prefix, created_at) ' \
                          "VALUES (?, ?, 'Otro', 'frijolero', ?)", id, owner, created_at)
  end
end
