# frozen_string_literal: true

require 'test_helper'
require_relative '../../app/ledger_scope'

# LedgerScope around a fake App that records what it sees.
class LedgerScopeTest < Minitest::Test
  include TestHelpers

  def setup
    enter_db_ledger
    Frijolero::Ledger.current = nil # each request gets its ledger from LedgerScope
    @owner = Frijolero::Users.find_by_email('admin@example.com')
    @foreign = Frijolero::Ledger.create(owner_id: insert_user('b@example.com'), name: 'Ajeno')
    # Later than 'test', so 'test' stays the first ledger in the same second too.
    Frijolero::DB.execute("UPDATE ledgers SET created_at = '2099-01-01T00:00:00Z' WHERE id = ?", @foreign.id)
    @seen = nil
    @scope = Frijolero::LedgerScope.new(lambda do |env|
      @seen = { script_name: env['SCRIPT_NAME'], path_info: env['PATH_INFO'], ledger: Frijolero::Ledger.current.id }
      [200, {}, ['app']]
    end)
  end

  def teardown
    leave_test_ledger
    Frijolero::App.jobs = nil
    Frijolero::App.inbox = nil
  end

  def test_a_ledger_path_reaches_the_app_inside_that_ledger
    env = env_for('/l/test/accounts/AMEX?saved=1')

    status, = @scope.call(env)

    assert_equal 200, status
    assert_equal({ script_name: '/l/test', path_info: '/accounts/AMEX', ledger: 'test' }, @seen)
    assert_equal ['', '/l/test/accounts/AMEX', 'saved=1'], env.values_at('SCRIPT_NAME', 'PATH_INFO', 'QUERY_STRING'),
                 'the env that Login holds stays the same'
  end

  def test_a_ledger_without_a_rest_is_its_dashboard
    %w[/l/test /l/test/].each do |path|
      request(path)

      assert_equal({ script_name: '/l/test', path_info: '/', ledger: 'test' }, @seen, path)
    end
  end

  # Never 403: the answer must not tell an id that exists from one that does not. The
  # user is an admin, and an admin gets no exception.
  def test_an_unknown_ledger_and_another_users_ledger_get_the_same_404
    unknown = request('/l/nope0000/accounts')
    foreign = request("/l/#{@foreign.id}/accounts")

    assert_predicate @owner, :admin?
    assert_equal 404, unknown[0]
    assert_equal unknown, foreign
    assert_nil @seen
  end

  def test_an_own_repo_that_is_not_connected_goes_to_its_connect_page
    ledger = Frijolero::Ledger.create(owner_id: @owner.id, name: 'Mío')

    status, headers, = request("/l/#{ledger.id}/accounts")

    assert_equal [302, "/ledgers/#{ledger.id}/connect"], [status, headers['location']]
    assert_nil @seen
  end

  def test_any_other_l_shape_is_the_same_404
    unknown = request('/l/nope0000/')

    ['/l', '/l/', '/l//accounts'].each do |path|
      assert_equal unknown, request(path), path
    end
    assert_nil @seen
  end

  def test_root_goes_to_the_first_ledger_of_the_user
    status, headers, = request('/')

    assert_equal 302, status
    assert_equal '/l/test/', headers['location']
  end

  # A bookmark from before /l/<id>/ still opens, with its query.
  def test_an_old_path_goes_to_the_same_path_in_the_first_ledger
    %w[GET HEAD].each do |method|
      status, headers, = request('/reports/income?period=2026&mxn=0', method: method)

      assert_equal 302, status, method
      assert_equal '/l/test/reports/income?period=2026&mxn=0', headers['location'], method
    end
    assert_nil @seen
  end

  # Once a user has several ledgers, a stale form must not post to the wrong one.
  def test_a_post_to_an_old_path_is_a_404
    assert_equal request('/l/nope0000/'), request('/inbox/process', method: 'POST')
    assert_nil @seen
  end

  def test_an_old_path_without_a_ledger_is_a_404
    assert_equal 404, request('/reports', user: Frijolero::Users.find(insert_user('c@example.com')))[0]
  end

  # Login has checked the bearer token and put its ledger in env. There is no user.
  def test_api_runs_in_the_ledger_of_its_token_with_its_path
    @scope.call(api_env(@foreign.id))

    assert_equal({ script_name: '', path_info: '/api/upload', ledger: @foreign.id }, @seen)
  end

  def test_api_without_a_ledger_is_a_404
    assert_equal 404, @scope.call(api_env(nil))[0]
    assert_nil @seen
  end

  # Puma reuses its threads: the next request on this one must find no ledger.
  def test_no_ledger_stays_on_the_thread
    request('/l/test/')
    @scope.call(api_env('test'))

    assert_raises(Frijolero::NoLedger) { Frijolero::Ledger.current }
  end

  # The lead's pieces in App, with the prefix that LedgerScope gives.
  def test_a_redirect_of_app_keeps_the_prefix
    response = in_app { Rack::MockRequest.new(Frijolero::App).get('/reports', 'SCRIPT_NAME' => LEDGER_ROOT) }

    assert_equal 302, response.status
    assert_equal "#{LEDGER_ROOT}/reports/income", URI(response.location).path
  end

  def test_a_page_tells_the_javascript_its_ledger_root
    Frijolero::App.jobs = Frijolero::Jobs.new(log_path: File.join(Frijolero::Config.data_dir, 'jobs.jsonl'))
    Frijolero::App.inbox = Frijolero::Inbox.new(File.join(Frijolero::Config.data_dir, 'incoming'))

    response = in_app { Rack::MockRequest.new(Frijolero::App).get('/jobs', 'SCRIPT_NAME' => LEDGER_ROOT) }

    assert_equal 200, response.status
    assert_includes response.body, %(<meta name="ledger-root" content="#{LEDGER_ROOT}">)
  end

  private

  def env_for(path, user: @owner, method: 'GET')
    Rack::MockRequest.env_for(path, method: method).merge('SCRIPT_NAME' => '', 'frijolero.user' => user)
  end

  def request(path, **) = @scope.call(env_for(path, **))

  def api_env(ledger_id) = env_for('/api/upload', user: nil, method: 'POST').merge('frijolero.api_ledger' => ledger_id)

  def in_app(&) = Frijolero::Ledger.with(Frijolero::Ledger.find('test'), &)

  def insert_user(email)
    Frijolero::DB.insert("INSERT INTO users (email, status, created_at) VALUES (?, 'active', ?)", email,
                         Time.now.utc.iso8601)
  end
end
