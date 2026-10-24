# frozen_string_literal: true

require_relative 'test_helper'

# The single-user layout (DATA_DIR/ledger with jobs.jsonl, incoming/ and pdfs/ next to
# it) becomes a row and DATA_DIR/ledgers/<id>/ at the first boot.
class MigrationTest < Minitest::Test
  include TestHelpers

  ENV_KEYS = %w[DATA_DIR LEDGER_DIR LEDGER_MAIN_FILE ADMIN_EMAIL API_TOKEN].freeze

  def setup
    @data = Dir.mktmpdir
    @env_before = ENV.to_h.slice(*ENV_KEYS)
    ENV_KEYS.each { |key| ENV.delete(key) }
    ENV['DATA_DIR'] = @data
    ENV['ADMIN_EMAIL'] = 'yo@example.com'
  end

  def teardown
    ENV_KEYS.each { |key| ENV.delete(key) }
    ENV.merge!(@env_before)
    FileUtils.rm_rf(@data)
  end

  def test_adopts_the_single_user_layout
    write_old_layout
    ENV['LEDGER_MAIN_FILE'] = 'moneys.beancount'
    ENV['API_TOKEN'] = 'shortcut-token'

    logging_moves { Frijolero::Migration.run }

    ledgers = Frijolero::Ledger.all
    assert_equal 1, ledgers.size
    ledger = ledgers.first
    admin = Frijolero::DB.first('SELECT * FROM users')
    assert_equal ['yo@example.com', 'admin', 'active'], admin.values_at('email', 'role', 'status')
    assert_equal admin['id'], ledger.owner_id
    assert_equal ['moneys.beancount', 'frijolero'], [ledger.main_file, ledger.pdf_prefix]
    assert_equal 'Casa', Frijolero::DB.first('SELECT name FROM ledgers')['name']
    assert_equal File.join(@data, 'ledgers', ledger.id), ledger.dir
    assert_path_exists File.join(ledger.repo_dir, 'moneys.beancount')
    assert_path_exists File.join(ledger.dir, 'jobs.jsonl')
    assert_path_exists File.join(ledger.dir, 'incoming', 'abc', 'x.pdf')
    assert_path_exists File.join(ledger.dir, 'pdfs', 'frijolero', 'accounts', 'AMEX', 'AMEX 2608.pdf')
    %w[ledger jobs.jsonl incoming pdfs].each { |name| refute_path_exists File.join(@data, name) }
    token = Frijolero::DB.first('SELECT * FROM api_tokens')
    assert_equal [Digest::SHA256.hexdigest('shortcut-token'), ledger.id], token.values_at('token_sha256', 'ledger_id')
  end

  def test_a_second_run_changes_nothing
    write_old_layout
    ENV['LEDGER_MAIN_FILE'] = 'moneys.beancount'
    logging_moves { Frijolero::Migration.run }
    write_old_layout

    assert_output('') { Frijolero::Migration.run }

    assert_equal 1, Frijolero::Ledger.all.size
    assert_equal 1, Frijolero::DB.first('SELECT COUNT(*) AS n FROM users')['n']
    assert_path_exists File.join(@data, 'ledger'), 'a ledger exists already, so nothing is adopted'
  end

  def test_ledger_dir_names_the_old_ledger
    FileUtils.mkdir_p(File.join(@data, 'elsewhere'))
    File.write(File.join(@data, 'elsewhere', 'main.beancount'), '')
    ENV['LEDGER_DIR'] = File.join(@data, 'elsewhere')

    logging_moves { Frijolero::Migration.run }

    assert_path_exists File.join(Frijolero::Ledger.all.first.repo_dir, 'main.beancount')
  end

  def test_without_an_old_ledger_only_the_admin_is_made
    Frijolero::Migration.run

    assert_empty Frijolero::Ledger.all
    assert_equal 'yo@example.com', Frijolero::DB.first('SELECT email FROM users')['email']
  end

  def test_the_first_admin_needs_admin_email
    ENV.delete('ADMIN_EMAIL')

    error = assert_raises(RuntimeError) { Frijolero::Migration.run }
    assert_match(/ADMIN_EMAIL/, error.message)
  end

  def test_a_missing_main_file_stops_before_any_move
    write_old_layout

    error = assert_raises(RuntimeError) { Frijolero::Migration.run }

    assert_match(/main\.beancount.*LEDGER_MAIN_FILE.*moneys\.beancount/, error.message)
    assert_path_exists File.join(@data, 'ledger', 'moneys.beancount')
    assert_empty Frijolero::Ledger.all
  end

  private

  def write_old_layout
    FileUtils.mkdir_p(File.join(@data, 'ledger'))
    File.write(File.join(@data, 'ledger', 'moneys.beancount'), %(option "title" "Casa"\n))
    File.write(File.join(@data, 'jobs.jsonl'), '')
    FileUtils.mkdir_p(File.join(@data, 'incoming', 'abc'))
    File.write(File.join(@data, 'incoming', 'abc', 'x.pdf'), '')
    FileUtils.mkdir_p(File.join(@data, 'pdfs', 'frijolero', 'accounts', 'AMEX'))
    File.write(File.join(@data, 'pdfs', 'frijolero', 'accounts', 'AMEX', 'AMEX 2608.pdf'), '')
  end

  def logging_moves(&) = assert_output(%r{Migración: .* → .*/ledgers/[a-z0-9]{8}/repo$}, &)
end
