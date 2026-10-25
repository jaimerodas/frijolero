# frozen_string_literal: true

require 'test_helper'

class UsersTest < Minitest::Test
  include TestHelpers

  # A fresh DATA_DIR, so a fresh database.
  def setup = enter_test_ledger

  def teardown = leave_test_ledger

  def add_user(email, status: 'active', role: 'user')
    Frijolero::DB.insert('INSERT INTO users (email, role, status, created_at) VALUES (?, ?, ?, ?)',
                         email, role, status, Time.now.utc.iso8601)
  end

  def test_find_returns_the_user
    id = add_user('ana@example.com', role: 'admin')

    user = Frijolero::Users.find(id)

    assert_equal Frijolero::User.new(id: id, email: 'ana@example.com', name: nil, role: 'admin', status: 'active',
                                     session_version: 1), user
    assert_predicate user, :admin?
  end

  def test_a_user_is_not_an_admin
    refute_predicate Frijolero::Users.find(add_user('ana@example.com')), :admin?
  end

  def test_find_of_a_missing_id_is_nil
    assert_nil Frijolero::Users.find(99)
  end

  # People type their address with capitals and stray spaces.
  def test_find_by_email_ignores_case_and_spaces
    id = add_user('ana@example.com')

    assert_equal id, Frijolero::Users.find_by_email(' Ana@Example.COM ').id
  end

  def test_find_by_email_of_an_unknown_address_is_nil
    assert_nil Frijolero::Users.find_by_email('nadie@example.com')
  end

  def test_activate_makes_an_invited_user_active
    id = add_user('ana@example.com', status: 'invited')

    Frijolero::Users.activate(id)

    assert_equal 'active', Frijolero::Users.find(id).status
  end

  def test_activate_leaves_a_blocked_user_blocked
    id = add_user('ana@example.com', status: 'blocked')

    Frijolero::Users.activate(id)

    assert_equal 'blocked', Frijolero::Users.find(id).status
  end
end
