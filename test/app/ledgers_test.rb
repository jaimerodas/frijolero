# frozen_string_literal: true

require 'test_helper'
require 'fake_github'
require 'rack/test'
require_relative '../../app/ledgers'

# Ledgers: / and /ledgers/…, outside any ledger, in front of a fake rest of the stack.
# The fake ssh of FakeGithub serves the repos in @tmp, so a person's own repo is a local
# bare repo.
class LedgersTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers
  include LedgerRepoTestGit
  include FakeGithub

  def app = Frijolero::Ledgers.new(->(_env) { [200, {}, ['abajo']] })

  def setup
    @frijolero_head = run_git(Dir.pwd, 'rev-parse', 'HEAD').strip
    @tmp = Dir.mktmpdir
    enter_db_ledger # 'test', connected, owned by admin@example.com
    Frijolero::Ledger.current = nil # the pages outside a ledger have none
    @owner = Frijolero::Users.find_by_email('admin@example.com')
    env 'frijolero.user', @owner
  end

  def teardown
    leave_test_ledger
    FileUtils.remove_entry(@tmp)
    assert_equal @frijolero_head, run_git(Dir.pwd, 'rev-parse', 'HEAD').strip
  end

  def test_root_without_a_ledger_is_the_new_ledger_page
    env 'frijolero.user', user('nuevo@example.com')

    get '/'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'action="/ledgers"'
    assert_includes last_response.body, 'action="/ledgers/repo"'
  end

  def test_root_with_one_ledger_opens_it
    get '/'

    assert_equal 302, last_response.status
    assert_equal '/l/test/', URI(last_response.location).path
  end

  def test_root_with_several_ledgers_lists_them
    other = Frijolero::Ledger.create(owner_id: @owner.id, name: 'Negocio')
    FileUtils.mkdir_p(other.repo_dir)
    mine = Frijolero::Ledger.create(owner_id: @owner.id, name: 'Mío')

    get '/'

    body = last_response.body
    assert_equal 200, last_response.status
    assert_includes body, '<a href="/l/test/">Prueba</a>'
    assert_includes body, %(<a href="/l/#{other.id}/">Negocio</a>)
    assert_includes body, %(href="/ledgers/#{mine.id}/connect")
    assert_includes body, 'sin conectar'
    assert_includes body, 'href="/ledgers/new"'
  end

  # Its pages would break: the list says what is missing instead.
  def test_root_with_one_ledger_not_connected_lists_it
    newcomer = user('nuevo@example.com')
    mine = Frijolero::Ledger.create(owner_id: newcomer.id, name: 'Mío')
    env 'frijolero.user', newcomer

    get '/'

    assert_equal 200, last_response.status
    assert_includes last_response.body, %(href="/ledgers/#{mine.id}/connect")
  end

  def test_new_ledger_page_offers_both_choices
    get '/ledgers/new'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'action="/ledgers"'
    assert_includes last_response.body, 'action="/ledgers/repo"'
  end

  def test_a_new_empty_ledger_has_a_commit_and_opens
    post '/ledgers', name: ' Casa '

    ledger = new_ledger
    assert_equal 303, last_response.status
    assert_equal "/l/#{ledger.id}/", URI(last_response.location).path
    assert_equal 'Casa', ledger.name
    assert_equal 'main.beancount', ledger.main_file
    assert_path_exists File.join(ledger.repo_dir, 'main.beancount')
    assert_equal "Ledger nuevo\n", run_git(ledger.repo_dir, 'log', '--format=%s')
  end

  def test_a_new_ledger_needs_a_name
    %w[/ledgers /ledgers/repo].each do |path|
      post path, name: '  '

      assert_equal 422, last_response.status, path
      assert_includes last_response.body, 'class="error"', path
    end
    assert_equal ['test'], Frijolero::Ledger.owned_by(@owner.id).map(&:id)
  end

  # Each ledger holds two threads from boot, so one person cannot make them without end.
  def test_a_person_has_at_most_five_ledgers
    4.times { |i| Frijolero::Ledger.create(owner_id: @owner.id, name: "L#{i}") }

    %w[/ledgers /ledgers/repo].each do |path|
      post path, name: 'Otro'

      assert_equal 422, last_response.status, path
      assert_includes last_response.body, 'class="error"', path
    end
    assert_equal 5, Frijolero::Ledger.owned_by(@owner.id).size
  end

  def test_own_repo_makes_a_key_and_asks_for_the_url
    post '/ledgers/repo', name: 'Mío'

    ledger = new_ledger
    assert_equal 303, last_response.status
    assert_equal "/ledgers/#{ledger.id}/connect", URI(last_response.location).path

    get "/ledgers/#{ledger.id}/connect"

    assert_equal 200, last_response.status
    assert_includes last_response.body, File.read("#{ledger.deploy_key}.pub").chomp
    assert_includes last_response.body, %(action="/ledgers/#{ledger.id}/connect")
    refute_path_exists ledger.repo_dir
  end

  # Puma gives the path as a binary string, which SQLite would compare as a BLOB.
  def test_the_id_of_a_binary_path_finds_its_ledger
    ledger = Frijolero::Ledger.create(owner_id: @owner.id, name: 'Mío')
    path = "/ledgers/#{ledger.id}/connect"

    get path, {}, 'PATH_INFO' => path.b

    assert_includes last_response.body, %(action="#{path}")
  end

  # A repo just made on GitHub: the template goes up as its first commit.
  def test_connect_an_empty_repo_pushes_the_template
    run_git(@tmp, 'init', '-q', '--bare', '-b', 'main', 'vacio.git')
    ledger = Frijolero::Ledger.create(owner_id: @owner.id, name: 'Mío')

    with_fake_ssh { post "/ledgers/#{ledger.id}/connect", url: ' git@github.com:vacio.git ' }

    assert_equal 303, last_response.status
    assert_equal "/l/#{ledger.id}/", URI(last_response.location).path
    assert_equal 'Configuración de Frijolero', run_git(File.join(@tmp, 'vacio.git'), 'log', '-1', '--format=%s').strip
    assert_equal({ 'main_file' => 'main.beancount', 'remote_url' => 'git@github.com:vacio.git' }, row(ledger))
  end

  # A ledger that exists keeps its main file, and gets the config files on top.
  def test_connect_a_ledger_keeps_its_main_file
    seed_repo('ledger.git', 'ledger.beancount' => "2020-01-01 open Assets:Banco\n")
    ledger = Frijolero::Ledger.create(owner_id: @owner.id, name: 'Mío')

    with_fake_ssh { post "/ledgers/#{ledger.id}/connect", url: 'git@github.com:ledger.git' }

    assert_equal 303, last_response.status
    assert_equal 'ledger.beancount', row(ledger)['main_file']
    assert_equal "Configuración de Frijolero\nmío\n",
                 run_git(File.join(@tmp, 'ledger.git'), 'log', '--format=%s')
    assert_path_exists File.join(ledger.repo_dir, 'config', 'accounts.yaml')
  end

  # The usual failure: the deploy key is not in the repo yet. The person can try again.
  def test_a_failed_clone_shows_the_form_again
    ledger = Frijolero::Ledger.create(owner_id: @owner.id, name: 'Mío')

    with_fake_ssh { post "/ledgers/#{ledger.id}/connect", url: 'git@github.com:no-existe.git' }

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'class="error"'
    assert_includes last_response.body, 'value="git@github.com:no-existe.git"'
    refute_path_exists ledger.repo_dir
    assert_nil row(ledger)['remote_url']

    get "/ledgers/#{ledger.id}/connect"

    assert_equal 200, last_response.status
  end

  def test_a_url_that_is_not_ssh_to_a_known_host_shows_the_form_again
    ledger = Frijolero::Ledger.create(owner_id: @owner.id, name: 'Mío')
    seed_repo('ledger.git', 'main.beancount' => '')

    with_fake_ssh { post "/ledgers/#{ledger.id}/connect", url: File.join(@tmp, 'ledger.git') }

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'El remoto debe ser'
    refute_path_exists ledger.repo_dir
  end

  def test_a_connected_ledger_has_no_connect_page
    get '/ledgers/test/connect'
    assert_equal 404, last_response.status

    post '/ledgers/test/connect', url: 'git@github.com:vacio.git'
    assert_equal 404, last_response.status
  end

  # The same answer as an unknown id, so a guess learns nothing.
  def test_another_users_ledger_is_the_same_404_as_an_unknown_id
    foreign = Frijolero::Ledger.create(owner_id: user('b@example.com').id, name: 'Ajeno')

    %i[get post].each do |method|
      send(method, '/ledgers/nope0000/connect', url: 'git@github.com:vacio.git')
      unknown = [last_response.status, last_response.body]
      send(method, "/ledgers/#{foreign.id}/connect", url: 'git@github.com:vacio.git')

      assert_equal 404, unknown.first, method
      assert_equal unknown, [last_response.status, last_response.body], method
    end
    refute_path_exists foreign.deploy_key
    refute_path_exists foreign.repo_dir
  end

  private

  # The owner's one ledger besides 'test'. Both can have the same created_at.
  def new_ledger = Frijolero::Ledger.owned_by(@owner.id).find { |ledger| ledger.id != 'test' }

  def user(email)
    Frijolero::DB.insert("INSERT INTO users (email, status, created_at) VALUES (?, 'active', ?)", email,
                         Time.now.utc.iso8601)
    Frijolero::Users.find_by_email(email)
  end

  def row(ledger) = Frijolero::DB.first('SELECT main_file, remote_url FROM ledgers WHERE id = ?', ledger.id)

  # A bare repo in @tmp with one commit of `files`, as the person's own repo on GitHub.
  def seed_repo(name, files)
    seed = File.join(@tmp, 'seed')
    run_git(@tmp, 'init', '-q', '-b', 'main', 'seed')
    files.each { |file, text| File.write(File.join(seed, file), text) }
    run_git(seed, 'add', '.')
    run_git(seed, '-c', 'user.name=Yo', '-c', 'user.email=yo@localhost', 'commit', '-q', '-m', 'mío')
    run_git(@tmp, 'clone', '-q', '--bare', seed, name)
    FileUtils.rm_rf(seed)
  end
end
