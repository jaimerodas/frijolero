# frozen_string_literal: true

require 'test_helper'
require 'digest'

class ApiTokensTest < Minitest::Test
  include TestHelpers

  Tokens = Frijolero::ApiTokens

  def setup
    enter_db_ledger
    @other = Frijolero::Ledger.create(owner_id: 1, name: 'Otro').id
  end

  def teardown = leave_test_ledger

  def sha(ledger_id) = Tokens.for_ledger(ledger_id).first['token_sha256']

  # A copy of the database must open nothing.
  def test_create_stores_only_the_hash
    raw = Tokens.create('test', 'iPhone')

    row = Frijolero::DB.first('SELECT * FROM api_tokens')
    assert_equal({ 'token_sha256' => Digest::SHA256.hexdigest(raw), 'ledger_id' => 'test', 'name' => 'iPhone',
                   'last_used_at' => nil }, row)
    assert_operator raw.size, :>=, 43, '32 random bytes'
  end

  def test_a_token_finds_its_ledger_and_records_the_use
    raw = Tokens.create(@other, 'iPhone')

    assert_equal @other, Tokens.ledger_id_for(raw, now: Time.utc(2026, 10, 26, 12))
    assert_equal '2026-10-26T12:00:00Z', Tokens.for_ledger(@other).first['last_used_at']
  end

  def test_an_unknown_token_finds_no_ledger
    Tokens.create('test', 'iPhone')

    assert_nil Tokens.ledger_id_for('nope')
    assert_nil Tokens.ledger_id_for('')
    assert_nil Tokens.ledger_id_for(nil)
  end

  def test_for_ledger_lists_only_that_ledger
    Tokens.create('test', 'iPhone')
    Tokens.create(@other, 'iPad')

    assert_equal(['iPhone'], Tokens.for_ledger('test').map { |token| token['name'] })
  end

  def test_revoke_works_only_within_the_ledger_of_the_token
    raw = Tokens.create('test', 'iPhone')

    Tokens.revoke(@other, sha('test'))

    assert_equal 'test', Tokens.ledger_id_for(raw)

    Tokens.revoke('test', sha('test'))

    assert_nil Tokens.ledger_id_for(raw)
    assert_empty Tokens.for_ledger('test')
  end

  # A blocked user keeps no door: an upload can cost a model call.
  def test_the_token_of_a_blocked_owner_finds_no_ledger
    raw = Tokens.create('test', 'iPhone')
    Frijolero::DB.execute("UPDATE users SET status = 'blocked' WHERE id = 1")

    assert_nil Tokens.ledger_id_for(raw)
  end
end
