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

  def test_all_lists_every_user_by_id
    ids = [add_user('ana@example.com'), add_user('beto@example.com', status: 'blocked')]

    assert_equal(ids, Frijolero::Users.all.map(&:id))
    assert_equal %w[active blocked], Frijolero::Users.all.map(&:status)
  end

  def test_invite_makes_an_invited_user
    user = Frijolero::Users.invite(email: ' ana@example.com ', name: ' Ana ')

    assert_equal ['ana@example.com', 'Ana', 'user', 'invited'], [user.email, user.name, user.role, user.status]
    assert_equal user, Frijolero::Users.find(user.id)
  end

  def test_invite_without_a_name_keeps_none
    assert_nil Frijolero::Users.invite(email: 'ana@example.com', name: ' ').name
  end

  def test_invite_of_an_email_that_exists_is_nil_and_adds_no_user
    add_user('ana@example.com')

    assert_nil Frijolero::Users.invite(email: 'Ana@Example.com')
    assert_equal 1, Frijolero::Users.all.size
  end

  # Login checks both, so the cookie of every device dies at once.
  def test_block_blocks_and_signs_out_everywhere
    id = add_user('ana@example.com')

    Frijolero::Users.block(id)

    assert_equal ['blocked', 2], Frijolero::Users.find(id).to_h.values_at(:status, :session_version)
  end

  def test_unblock_makes_a_blocked_user_active
    id = add_user('ana@example.com', status: 'blocked')

    Frijolero::Users.unblock(id)

    assert_equal 'active', Frijolero::Users.find(id).status
  end

  def test_sign_out_everywhere_adds_one_to_the_session_version
    id = add_user('ana@example.com')

    2.times { Frijolero::Users.sign_out_everywhere(id) }

    assert_equal 3, Frijolero::Users.find(id).session_version
    assert_equal 'active', Frijolero::Users.find(id).status
  end

  def test_delete_removes_the_user_their_passkeys_and_links_and_keeps_the_usage
    id = add_user('ana@example.com')
    Frijolero::DB.execute("INSERT INTO passkeys (id, user_id, public_key, created_at) VALUES ('k', ?, x'00', '')", id)
    Frijolero::Signin.issue(Frijolero::Users.find(id), ttl: 60)
    Frijolero::DB.execute('INSERT INTO usage (user_id, ledger_id, prompt, model, input_tokens, output_tokens, ' \
                          "cost_micros, at) VALUES (?, 'gone', 'default', 'm', 1, 1, 5, '')", id)

    Frijolero::Users.delete(id)

    assert_nil Frijolero::Users.find(id)
    %w[passkeys signin_tokens].each do |table|
      assert_equal 0, Frijolero::DB.first("SELECT COUNT(*) AS n FROM #{table}")['n'], table
    end
    assert_equal 1, Frijolero::DB.first('SELECT COUNT(*) AS n FROM usage WHERE user_id = ?', id)['n']
  end

  # Ledger.destroy goes first: it deletes the files that the rows point to.
  def test_delete_of_a_user_who_still_has_a_ledger_is_refused
    id = add_user('ana@example.com')
    Frijolero::Ledger.create(owner_id: id, name: 'Casa')

    assert_raises(SQLite3::ConstraintException) { Frijolero::Users.delete(id) }

    assert Frijolero::Users.find(id)
  end

  def test_set_cap_stores_micros_and_nil_means_the_default
    id = add_user('ana@example.com')

    Frijolero::Users.set_cap(id, 5_500_000)
    assert_equal 5_500_000, Frijolero::Usage.cap_micros(id)

    Frijolero::Users.set_cap(id, nil)
    assert_equal Frijolero::Usage::DEFAULT_CAP_MICROS, Frijolero::Usage.cap_micros(id)
  end
end
