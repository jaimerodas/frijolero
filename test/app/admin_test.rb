# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'rack/builder'
require 'stringio'

# /admin through config.ru, as production serves it. The admin (admin@example.com) owns
# the ledger 'test'. Beto is a user with a ledger of his own and a session of his own.
class AdminTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  CONFIG_RU = File.expand_path('../../config.ru', __dir__)
  ENV_VARS = { 'SESSION_SECRET' => 's' * 64, 'APP_URL' => 'https://frijolero.test' }.freeze

  # Keeps each message instead of sending it.
  class FakeMailer
    attr_reader :sent

    def initialize
      @sent = []
    end

    def deliver(**message) = @sent << message
  end

  class FailingMailer
    def deliver(**) = raise(Frijolero::Postmark::Error, 'Postmark: inactive recipient')
  end

  def setup
    @previous_env = ENV.to_h.slice(*ENV_VARS.keys)
    ENV.merge!(ENV_VARS)
    @mailer = FakeMailer.new
    Frijolero::Signin.mailer = @mailer
    dir = enter_db_ledger
    Frijolero::Ledger.current = nil
    @admin = Frijolero::Users.find_by_email('admin@example.com')
    beto = Frijolero::DB.insert("INSERT INTO users (email, name, status, created_at) VALUES ('beto@example.com', " \
                                "'Beto', 'active', ?)", Time.now.utc.iso8601)
    @beto = Frijolero::Users.find(beto)
    @beto_ledger = Frijolero::Ledger.create(owner_id: @beto.id, name: 'Casa de Beto')

    # config.ru calls App.jobs and App.inbox_worker for each ledger at load time.
    Frijolero::App.jobs = Frijolero::Jobs.new(log_path: File.join(dir, 'jobs.jsonl'))
    Frijolero::App.inbox = Frijolero::Inbox.new(File.join(dir, 'incoming'))
    Frijolero::App.inbox_worker = Frijolero::Inbox::Worker.new(Frijolero::App.inbox) { {} }
    Frijolero::App.s3 = Frijolero::LocalPdfs.new(File.join(dir, 'bucket'))
    @app = Rack::Builder.parse_file(CONFIG_RU)
    sign_in(@admin)
  end

  def teardown
    ENV_VARS.each_key { |key| ENV.delete(key) }
    ENV.merge!(@previous_env)
    Frijolero::Signin.mailer = nil
    leave_test_ledger
    Frijolero::App.jobs = nil
    Frijolero::App.inbox = nil
    Frijolero::App.inbox_worker = nil
    Frijolero::App.s3 = nil
  end

  attr_reader :app

  def sign_in(user) = post("/login/#{Frijolero::Signin.issue(user, ttl: 60)}")

  def beto = Frijolero::Users.find(@beto.id)

  # Beto's own browser, apart from the admin's.
  def as_beto(&) = with_session(:beto, &)

  # The notice or the error that the redirect leads to.
  def notice
    assert_equal 303, last_response.status
    assert_equal '/admin', URI(last_response.location).path
    follow_redirect!
    last_response.body[%r{<p class="(?:notice|error)"[^>]*>(.*?)</p>}m, 1]
  end

  def add_usage(user, at:, micros:)
    Frijolero::DB.execute('INSERT INTO usage (user_id, ledger_id, prompt, model, input_tokens, output_tokens, ' \
                          "cost_micros, at) VALUES (?, ?, 'default', 'gpt-6-sol', 1, 1, ?, ?)",
                          user.id, @beto_ledger.id, micros, at.utc.iso8601)
  end

  # Like a page that does not exist: the same answer as an unknown ledger.
  def test_a_user_who_is_not_the_admin_gets_404_on_every_admin_path
    as_beto do
      sign_in(@beto)
      get '/l/nope0000/'
      missing = [last_response.status, last_response.content_type, last_response.body]

      [[:get, '/admin'], [:get, '/admin/'], [:get, '/admin/nope'], [:post, '/admin/invite'],
       [:get, "/admin/users/#{@admin.id}"], [:get, "/admin/users/#{@admin.id}/delete"],
       *%w[resend block unblock sign_out cap delete].map { |action| [:post, "/admin/users/#{@admin.id}/#{action}"] }]
        .each do |verb, path|
          send(verb, path, email: 'nuevo@example.com', cap: '1')

          assert_equal missing, [last_response.status, last_response.content_type, last_response.body],
                       "#{verb} #{path}"
        end
    end

    assert_nil Frijolero::Users.find_by_email('nuevo@example.com')
    assert_equal @admin, Frijolero::Users.find(@admin.id)
  end

  def test_the_admin_sees_each_user_with_ledgers_cap_and_two_monthly_costs
    Frijolero::Users.set_cap(@beto.id, 5_500_000)
    add_usage(@beto, at: Time.now, micros: 1_250_000)
    add_usage(@beto, at: Date.today.prev_month.to_time, micros: 500_000)

    get '/admin'

    assert_equal 200, last_response.status
    assert_includes last_response.body, '<a href="/admin" aria-current="page">Usuarios</a>', 'the header names the page'
    name = %(<a href="/admin/users/#{@beto.id}">Beto <span class="note">beto@example.com</span></a>)
    row = last_response.body[%r{<tr>\s*<th scope="row">#{name}</th>.*?</tr>}m]
    assert row, 'a row for Beto, the name over the email, with a link to his page'
    ['Casa de Beto', 'activo', 'value="5.50"', '1.25', '0.50'].each { |text| assert_includes row, text }
    assert_includes last_response.body, %(<a href="/admin/users/#{@admin.id}">admin@example.com</a></th>),
                    'no name: the email alone'
    assert_includes last_response.body, 'name="email"', 'the invitation form'
  end

  # Inviting is rare, so the form waits behind its button. A refused invitation opens it again.
  def test_the_invitation_form_is_closed_until_an_invitation_is_refused
    get '/admin'

    assert_includes last_response.body, '<details class="invite">'

    post '/admin/invite', email: 'Beto@Example.com'
    follow_redirect!

    assert_includes last_response.body, '<details class="invite" open>'
  end

  def test_invite_makes_an_invited_user_and_mails_the_link
    post '/admin/invite', email: 'carla@example.com', name: 'Carla'

    assert_includes notice, 'invitación'
    carla = Frijolero::Users.find_by_email('carla@example.com')
    assert_equal %w[Carla invited], [carla.name, carla.status]
    assert_equal([['carla@example.com', 'Te invitaron a Frijolero']], @mailer.sent.map { it.values_at(:to, :subject) })
    assert_includes last_response.body, 'invitado'
  end

  def test_inviting_an_email_that_exists_is_refused
    post '/admin/invite', email: 'Beto@Example.com'

    assert_includes notice, 'ya tiene una cuenta'
    assert_equal 2, Frijolero::Users.all.size
    assert_empty @mailer.sent
  end

  def test_inviting_without_a_valid_email_is_refused
    post '/admin/invite', email: 'carla'

    assert_includes notice, 'correo'
    assert_equal 2, Frijolero::Users.all.size
  end

  # The user and the link exist, so Reenviar can try again.
  def test_a_mail_failure_on_invite_says_so
    Frijolero::Signin.mailer = FailingMailer.new
    Frijolero::Log.sink = StringIO.new

    post '/admin/invite', email: 'carla@example.com'

    assert_includes notice, 'No se pudo mandar'
    assert_equal 'invited', Frijolero::Users.find_by_email('carla@example.com').status
  ensure
    Frijolero::Log.sink = nil
  end

  def test_resend_mails_a_new_invitation
    carla = Frijolero::Users.invite(email: 'carla@example.com')

    post "/admin/users/#{carla.id}/resend"

    assert_includes notice, 'otra invitación'
    assert_equal(['carla@example.com'], @mailer.sent.map { it[:to] })
  end

  def test_resend_to_a_user_who_is_not_invited_sends_nothing
    post "/admin/users/#{@beto.id}/resend"

    assert notice
    assert_empty @mailer.sent
  end

  def test_block_sends_the_users_session_back_to_login
    as_beto do
      sign_in(@beto)
      get '/admin'
      assert_equal 404, last_response.status, 'signed in'
    end

    post "/admin/users/#{@beto.id}/block"

    assert_includes notice, 'Bloqueado'
    assert_equal 'blocked', beto.status
    assert_includes last_response.body, 'bloqueado'
    as_beto do
      get '/admin'
      assert_equal '/login', URI(last_response.location).path
    end
  end

  def test_sign_out_everywhere_sends_the_users_session_back_to_login
    as_beto { sign_in(@beto) }

    post "/admin/users/#{@beto.id}/sign_out"

    assert notice
    assert_equal 'active', beto.status
    as_beto do
      get '/admin'
      assert_equal '/login', URI(last_response.location).path
    end
  end

  def test_unblock_makes_the_user_active
    Frijolero::Users.block(@beto.id)

    post "/admin/users/#{@beto.id}/unblock"

    assert notice
    assert_equal 'active', beto.status
  end

  def test_the_cap_is_set_in_usd_and_cleared_to_the_default
    post "/admin/users/#{@beto.id}/cap", cap: '5.50'

    assert notice
    assert_equal 5_500_000, Frijolero::Usage.cap_micros(@beto.id)

    post "/admin/users/#{@beto.id}/cap", cap: ' '

    assert notice
    assert_nil Frijolero::DB.first('SELECT monthly_cap_micros FROM users WHERE id = ?', @beto.id)['monthly_cap_micros']
  end

  def test_a_cap_that_is_not_an_amount_in_usd_is_refused
    Frijolero::Users.set_cap(@beto.id, 4_000_000)

    ['-1', 'abc', '1e3', '1/3', '5,50'].each do |cap|
      post "/admin/users/#{@beto.id}/cap", cap: cap

      assert_includes notice, 'dólares', cap
      assert_equal 4_000_000, Frijolero::Usage.cap_micros(@beto.id), cap
    end
  end

  def test_the_page_of_a_person_shows_their_buttons_ledgers_and_usage
    add_usage(@beto, at: Time.now, micros: 1_250_000)

    get "/admin/users/#{@beto.id}"

    body = last_response.body
    assert_equal 200, last_response.status
    assert_includes body, '<h1>Beto</h1>'
    assert_includes body, %(action="/admin/users/#{@beto.id}/block")
    assert_includes body, '<input type="hidden" name="from" value="person">'
    assert_includes body, 'primero bloquéala'
    refute_includes body, %(href="/admin/users/#{@beto.id}/delete"), 'an active user is blocked first'
    assert_includes body, %(href="/ledgers/#{@beto_ledger.id}/delete")
    refute_includes body, %(href="/l/#{@beto_ledger.id}/"), 'the admin cannot open the ledger of another user'
    assert_includes body, 'Este mes: 1.25 de 3.00 USD.'
  end

  def test_an_action_from_the_page_of_a_person_goes_back_there
    post "/admin/users/#{@beto.id}/block", from: 'person'

    assert_equal ["/admin/users/#{@beto.id}", 'notice=blocked'],
                 [URI(last_response.location).path, URI(last_response.location).query]
    follow_redirect!
    assert_includes last_response.body, 'Bloqueado'
    assert_includes last_response.body, %(href="/admin/users/#{@beto.id}/delete")
  end

  def test_the_page_of_an_unknown_user_is_a_404
    get '/admin/users/999'

    assert_equal 404, last_response.status
  end

  # Their ledgers go with their files, then the rows. The usage stays, without a name.
  def test_deleting_a_blocked_user_deletes_their_ledgers_and_rows
    as_beto { sign_in(@beto) }
    Frijolero::Users.block(@beto.id)
    add_usage(@beto, at: Time.now, micros: 500_000)

    get "/admin/users/#{@beto.id}/delete"
    assert_includes last_response.body, 'Casa de Beto'
    assert_includes last_response.body, 'beto@example.com'

    post "/admin/users/#{@beto.id}/delete", confirm: ' BETO@example.com '

    assert_includes notice, 'Usuario borrado'
    assert_nil Frijolero::Users.find(@beto.id)
    assert_nil Frijolero::Ledger.find(@beto_ledger.id)
    refute_path_exists @beto_ledger.dir
    assert_equal 1, Frijolero::DB.first('SELECT COUNT(*) AS n FROM usage WHERE user_id = ?', @beto.id)['n']
    as_beto do
      get '/admin'
      assert_equal '/login', URI(last_response.location).path
    end
  end

  # The email is free again, for a new invitation.
  def test_deleting_an_invited_user_frees_the_email
    carla = Frijolero::Users.invite(email: 'carla@example.com')

    post "/admin/users/#{carla.id}/delete", confirm: 'carla@example.com'

    assert_includes notice, 'Usuario borrado'
    assert Frijolero::Users.invite(email: 'carla@example.com')
  end

  def test_an_active_user_is_blocked_before_the_delete
    %i[get post].each do |method|
      send(method, "/admin/users/#{@beto.id}/delete", confirm: 'beto@example.com')

      assert_includes notice, 'Bloquea a esa persona', method
    end
    assert Frijolero::Users.find(@beto.id)
  end

  def test_delete_without_the_email_deletes_nothing
    Frijolero::Users.block(@beto.id)

    post "/admin/users/#{@beto.id}/delete", confirm: 'Beto'

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'escribe su correo: beto@example.com'
    assert Frijolero::Users.find(@beto.id)
    assert Frijolero::Ledger.find(@beto_ledger.id)
  end

  def test_delete_waits_for_a_job_in_progress
    Frijolero::Users.block(@beto.id)
    Frijolero::App.jobs.push(label: 'AMEX 2610') { nil }

    post "/admin/users/#{@beto.id}/delete", confirm: 'beto@example.com'

    assert_equal 409, last_response.status
    assert Frijolero::Users.find(@beto.id)
  end

  def test_the_admin_cannot_delete_their_own_user
    post "/admin/users/#{@admin.id}/delete", confirm: 'admin@example.com'

    assert_includes notice, 'tu propia cuenta'
    assert Frijolero::Users.find(@admin.id)
  end

  # That would lock the only admin out.
  def test_the_admin_cannot_block_unblock_or_sign_out_their_own_row
    %w[block unblock sign_out].each do |action|
      post "/admin/users/#{@admin.id}/#{action}"

      assert_includes notice, 'tu propia cuenta', action
    end
    assert_equal @admin, Frijolero::Users.find(@admin.id)
    get '/admin'
    assert_equal 200, last_response.status
  end
end
