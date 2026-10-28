# frozen_string_literal: true

require 'test_helper'
require 'digest'

class SigninTest < Minitest::Test
  include TestHelpers

  # Keeps each message instead of sending it.
  class FakeMailer
    attr_reader :sent

    def initialize
      @sent = []
    end

    def deliver(**message) = @sent << message
  end

  T = Time.utc(2026, 10, 24, 12, 0, 0)

  def setup
    enter_test_ledger # a fresh DATA_DIR, so a fresh database
    @mailer = FakeMailer.new
    Frijolero::Signin.mailer = @mailer
    @app_url = ENV.fetch('APP_URL', nil)
    ENV['APP_URL'] = 'https://frijolero.test'
  end

  def teardown
    Frijolero::Signin.mailer = nil
    @app_url ? ENV['APP_URL'] = @app_url : ENV.delete('APP_URL')
    leave_test_ledger
  end

  def add_user(email = 'ana@example.com', status: 'active')
    id = Frijolero::DB.insert("INSERT INTO users (email, role, status, created_at) VALUES (?, 'user', ?, ?)",
                              email, status, T.iso8601)
    Frijolero::Users.find(id)
  end

  # The raw token of the last link that the fake mailer got.
  def last_token = @mailer.sent.last[:text][%r{/login/(\S+)}, 1]

  def test_issue_returns_a_url_safe_token_and_the_database_keeps_only_its_sha256
    raw = Frijolero::Signin.issue(add_user, ttl: 60)

    assert_match(/\A[A-Za-z0-9_-]{43}\z/, raw) # 32 bytes
    rows = Frijolero::DB.execute('SELECT * FROM signin_tokens')
    assert_equal([Digest::SHA256.hexdigest(raw)], rows.map { |row| row['token_sha256'] })
    refute_includes rows.first.values, raw
  end

  def test_redeem_returns_the_user_once
    user = add_user
    raw = Frijolero::Signin.issue(user, ttl: 60)

    assert_equal user, Frijolero::Signin.redeem(raw)
    assert_nil Frijolero::Signin.redeem(raw)
  end

  def test_redeem_of_an_unknown_token_is_nil
    add_user

    assert_nil Frijolero::Signin.redeem('nope')
  end

  def test_redeem_after_the_ttl_is_nil
    raw = Frijolero::Signin.issue(add_user, ttl: 60, now: T)

    assert_nil Frijolero::Signin.redeem(raw, now: T + 60)
  end

  def test_redeem_activates_an_invited_user
    user = add_user(status: 'invited')

    redeemed = Frijolero::Signin.redeem(Frijolero::Signin.issue(user, ttl: 60))

    assert_equal 'active', redeemed.status
    assert_equal 'active', Frijolero::Users.find(user.id).status
  end

  def test_redeem_for_a_blocked_user_is_nil
    raw = Frijolero::Signin.issue(add_user(status: 'blocked'), ttl: 60)

    assert_nil Frijolero::Signin.redeem(raw)
  end

  # The email stays until the click, which proves that the person reads the new inbox.
  def test_change_email_mails_a_link_to_the_new_address
    user = add_user

    Frijolero::Signin.change_email(user, 'nueva@example.com', now: T)

    assert_equal([['nueva@example.com', 'Confirma tu correo nuevo de Frijolero']],
                 @mailer.sent.map { it.values_at(:to, :subject) })
    assert_includes @mailer.sent.first[:text], 'https://frijolero.test/login/'
    assert_equal 'ana@example.com', Frijolero::Users.find(user.id).email
  end

  def test_the_link_changes_the_email_and_tells_the_old_address
    user = add_user
    Frijolero::Signin.change_email(user, 'nueva@example.com')

    moved = Frijolero::Signin.redeem(last_token)

    assert_equal [user.id, 'nueva@example.com'], [moved.id, moved.email]
    assert_equal user.id, Frijolero::Users.find_by_email('nueva@example.com').id
    assert_equal ['ana@example.com', 'Tu correo de Frijolero cambió'], @mailer.sent.last.values_at(:to, :subject)
  end

  # Nothing told the person that the email had a user, so the click is where it fails.
  def test_the_link_to_an_email_that_another_user_has_changes_nothing
    user = add_user
    Frijolero::Signin.change_email(user, 'beto@example.com')
    add_user('Beto@example.com')

    assert_raises(Frijolero::Signin::EmailTaken) { Frijolero::Signin.redeem(last_token) }

    assert_equal 'ana@example.com', Frijolero::Users.find(user.id).email
  end

  # The two kinds go to two inboxes, so each has its own count: a person who just entered
  # with a link can change the email at once, but not ask for two changes in a minute.
  def test_change_links_have_their_own_limit
    user = add_user
    Frijolero::Signin.request(user.email, now: T)

    assert Frijolero::Signin.change_email(user, 'nueva@example.com', now: T + 10)
    assert_nil Frijolero::Signin.change_email(user, 'nueva@example.com', now: T + 30)
    Frijolero::Signin.request(user.email, now: T + 70)

    assert_equal(%w[ana@example.com nueva@example.com ana@example.com], @mailer.sent.map { it[:to] })
  end

  def test_link_comes_from_app_url
    assert_equal 'https://frijolero.test/login/abc', Frijolero::Signin.link('abc')
  end

  def test_request_mails_a_link_to_an_active_user
    add_user

    Frijolero::Signin.request('ana@example.com')

    assert_equal 1, @mailer.sent.size
    message = @mailer.sent.first
    assert_equal 'ana@example.com', message[:to]
    assert_equal 'Tu enlace para entrar a Frijolero', message[:subject]
    assert_includes message[:text], "https://frijolero.test/login/#{last_token}"
    assert_includes message[:text], 'una sola vez, durante 15 minutos'
    assert_includes message[:text], 'Si no lo pediste, ignora este correo'
  end

  def test_the_link_of_a_request_lasts_15_minutes
    user = add_user
    Frijolero::Signin.request(user.email, now: T)

    assert_nil Frijolero::Signin.redeem(last_token, now: T + (15 * 60))
    assert_equal user, Frijolero::Signin.redeem(last_token, now: T + (15 * 60) - 1)
  end

  def test_request_mails_an_invited_user
    add_user(status: 'invited')

    Frijolero::Signin.request('ana@example.com')

    assert_equal 1, @mailer.sent.size
  end

  def test_request_for_an_unknown_email_does_nothing
    add_user

    Frijolero::Signin.request('nadie@example.com')

    assert_empty @mailer.sent
    assert_empty Frijolero::DB.execute('SELECT * FROM signin_tokens')
  end

  def test_request_for_a_blocked_user_does_nothing
    add_user(status: 'blocked')

    Frijolero::Signin.request('ana@example.com')

    assert_empty @mailer.sent
    assert_empty Frijolero::DB.execute('SELECT * FROM signin_tokens')
  end

  def test_request_sends_one_link_a_minute
    add_user

    [0, 59, 60].each { |s| Frijolero::Signin.request('ana@example.com', now: T + s) }

    assert_equal 2, @mailer.sent.size
  end

  def test_invite_mails_a_link_that_signs_in_once_and_activates
    user = add_user(status: 'invited')

    Frijolero::Signin.invite(user)

    assert_equal 1, @mailer.sent.size
    message = @mailer.sent.first
    assert_equal ['ana@example.com', 'Te invitaron a Frijolero'], message.values_at(:to, :subject)
    assert_includes message[:text], "https://frijolero.test/login/#{last_token}"
    assert_includes message[:text], '7 días'
    assert_equal 'active', Frijolero::Signin.redeem(last_token).status
    assert_nil Frijolero::Signin.redeem(last_token)
  end

  def test_the_link_of_an_invitation_lasts_7_days
    user = add_user(status: 'invited')
    Frijolero::Signin.invite(user, now: T)

    assert_nil Frijolero::Signin.redeem(last_token, now: T + Frijolero::Signin::INVITE_TTL)
    assert_equal user.id, Frijolero::Signin.redeem(last_token, now: T + Frijolero::Signin::INVITE_TTL - 1).id
    assert_equal 7 * 24 * 3600, Frijolero::Signin::INVITE_TTL
  end

  # A link that lives 7 days is for an invitation only: the others last 15 minutes.
  def test_invite_of_a_user_who_is_not_invited_sends_nothing
    %w[active blocked].each { |status| Frijolero::Signin.invite(add_user("#{status}@example.com", status: status)) }

    assert_empty @mailer.sent
    assert_empty Frijolero::DB.execute('SELECT * FROM signin_tokens')
  end

  def test_request_sends_five_links_an_hour
    add_user

    (0..5).each { |m| Frijolero::Signin.request('ana@example.com', now: T + (m * 60)) }
    assert_equal 5, @mailer.sent.size

    Frijolero::Signin.request('ana@example.com', now: T + 3600)
    assert_equal 6, @mailer.sent.size
  end
end
