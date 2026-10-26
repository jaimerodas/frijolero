# frozen_string_literal: true

require 'test_helper'
require 'rack/test'
require 'rack/builder'

# Through config.ru, as production serves it: a user reaches only the ledgers that
# user owns. Each route of App is tried, so a route added later is covered too.
class IsolationTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers

  CONFIG_RU = File.expand_path('../../config.ru', __dir__)
  ENV_VARS = { 'SESSION_SECRET' => 's' * 64, 'APP_URL' => 'https://frijolero.test' }.freeze

  def setup
    @previous_env = ENV.to_h.slice(*ENV_VARS.keys)
    ENV.merge!(ENV_VARS)
    # User A (the admin) owns 'test'. User B owns another ledger, with its own directory.
    dir = enter_db_ledger
    Frijolero::Ledger.current = nil
    @user_a = Frijolero::Users.find_by_email('admin@example.com')
    user_b = Frijolero::DB.insert("INSERT INTO users (email, status, created_at) VALUES ('b@example.com', 'active', ?)",
                                  Time.now.utc.iso8601)
    @ledger_b = Frijolero::Ledger.create(owner_id: user_b, name: 'De B')
    FileUtils.mkdir_p(File.join(@ledger_b.repo_dir, 'config'))

    # config.ru calls App.jobs and App.inbox_worker for each ledger at load time.
    Frijolero::App.jobs = Frijolero::Jobs.new(log_path: File.join(dir, 'jobs.jsonl'))
    Frijolero::App.inbox = Frijolero::Inbox.new(File.join(dir, 'incoming'))
    Frijolero::App.inbox_worker = Frijolero::Inbox::Worker.new(Frijolero::App.inbox) { {} }
    @app = Rack::Builder.parse_file(CONFIG_RU)
    post "/login/#{Frijolero::Signin.issue(@user_a, ttl: 60)}"
  end

  def teardown
    ENV_VARS.each_key { |key| ENV.delete(key) }
    ENV.merge!(@previous_env)
    leave_test_ledger
    Frijolero::App.jobs = nil
    Frijolero::App.inbox = nil
    Frijolero::App.inbox_worker = nil
  end

  attr_reader :app

  def test_no_route_of_app_opens_another_users_ledger
    tried = 0
    Frijolero::App.stub(:call, ->(env) { flunk "App got #{env['PATH_INFO']} of another user's ledger" }) do
      app_routes.each do |verb, path|
        request("/l/#{@ledger_b.id}#{path}", method: verb)
        tried += 1

        assert_equal 404, last_response.status, "#{verb} #{path}"
      end
    end
    assert_operator tried, :>, 30, 'every route was tried'
  end

  # The cookie gets a new expiry on each answer, so the headers are compared without it.
  def test_an_unknown_ledger_gets_the_same_404
    get "/l/#{@ledger_b.id}/accounts"
    foreign = answer
    get '/l/nope0000/accounts'

    assert_equal foreign, answer
  end

  def test_the_users_own_ledger_reaches_app
    seen = []
    app_call = lambda do |env|
      seen << [env['PATH_INFO'], Frijolero::Ledger.current.id]
      [200, {}, []]
    end
    Frijolero::App.stub(:call, app_call) { get '/l/test/accounts' }

    assert_equal [['/accounts', 'test']], seen
  end

  private

  # [verb, path] for each route of App, HEAD aside (Sinatra adds it to each GET). Each
  # :name and * becomes a sample segment, and each optional group is kept.
  def app_routes
    Frijolero::App.routes.except('HEAD').flat_map do |verb, routes|
      routes.map { |pattern, *| [verb, pattern.to_s.gsub(/:\w+|\*/, '2608').delete('()?')] }
    end
  end

  def answer
    headers = last_response.headers.to_h.except('set-cookie')
    [last_response.status, headers, last_response.body]
  end
end
