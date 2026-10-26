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
    assert_equal [@owner, 'main.beancount', "frijolero/ledgers/#{ledger.id}"],
                 [ledger.owner_id, ledger.main_file, ledger.pdf_prefix]
    assert_equal 'Casa', row(ledger.id)['name']
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

  private

  def row(id) = Frijolero::DB.first('SELECT * FROM ledgers WHERE id = ?', id)

  def insert_ledger(id, owner, created_at)
    Frijolero::DB.execute('INSERT INTO ledgers (id, owner_id, name, pdf_prefix, created_at) ' \
                          "VALUES (?, ?, 'Otro', 'frijolero', ?)", id, owner, created_at)
  end
end
