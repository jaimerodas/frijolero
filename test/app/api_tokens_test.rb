# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'digest'

# /tokens: the API tokens of the current ledger.
class ApiTokensPageTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  Tokens = Frijolero::ApiTokens

  def setup
    enter_db_ledger
    @other = Frijolero::Ledger.create(owner_id: 1, name: 'Otro').id
  end

  def teardown = leave_test_ledger

  def app = Frijolero::App

  def in_ledger = { 'SCRIPT_NAME' => LEDGER_ROOT }

  def test_the_page_lists_only_the_tokens_of_this_ledger
    Tokens.create('test', 'iPhone de Ana')
    Tokens.create(@other, 'iPad de Beto')

    get '/tokens', {}, in_ledger

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'iPhone de Ana'
    refute_includes last_response.body, 'iPad de Beto'
    assert_includes last_response.body, 'Revocar'
    assert_ledger_links(last_response.body)
  end

  def test_an_empty_list_says_what_to_do
    get '/tokens', {}, in_ledger

    assert_includes last_response.body, 'Este ledger no tiene tokens'
  end

  # The answer to the POST is the only place the raw token ever shows.
  def test_create_shows_the_raw_token_once_and_stores_only_its_hash
    post '/tokens', { name: 'iPhone' }, in_ledger

    assert_equal 200, last_response.status
    raw = last_response.body[/value="([A-Za-z0-9_-]{43,})"/, 1]
    assert raw, 'the page shows the token'
    assert_equal 'test', Tokens.ledger_id_for(raw)
    assert_equal([Digest::SHA256.hexdigest(raw)], Tokens.for_ledger('test').map { |token| token['token_sha256'] })
    assert_includes last_response.headers['cache-control'].to_s, 'no-store'
    assert_ledger_links(last_response.body)

    get '/tokens', {}, in_ledger

    refute_includes last_response.body, raw
  end

  def test_create_needs_a_name
    post '/tokens', { name: '  ' }, in_ledger

    assert_equal 422, last_response.status
    assert_empty Tokens.for_ledger('test')
  end

  def test_revoke_removes_the_token_and_returns_to_the_list
    raw = Tokens.create('test', 'iPhone')

    post '/tokens/revoke', { token: Digest::SHA256.hexdigest(raw) }, in_ledger

    assert_equal 303, last_response.status
    assert_equal "#{LEDGER_ROOT}/tokens", URI(last_response.location).path
    assert_nil Tokens.ledger_id_for(raw)
  end

  def test_a_token_of_another_ledger_cannot_be_revoked_from_this_one
    raw = Tokens.create(@other, 'iPad')

    post '/tokens/revoke', { token: Digest::SHA256.hexdigest(raw) }, in_ledger

    assert_equal @other, Tokens.ledger_id_for(raw)
  end
end
