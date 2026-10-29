# frozen_string_literal: true

require 'test_helper'
require 'fake_github'
require 'rack/test'

# /ledger: the settings of the current ledger, as LedgerScope serves them under LEDGER_ROOT.
# The fake ssh of FakeGithub serves the repos in @tmp, so a new remote is a local bare repo.
class LedgerSettingsTest < Minitest::Test
  include Rack::Test::Methods
  include TestHelpers
  include LedgerRepoTestGit
  include FakeGithub

  class NoErrors
    def check = []
  end

  def app = Frijolero::App

  def setup
    @frijolero_head = run_git(Dir.pwd, 'rev-parse', 'HEAD').strip
    @tmp = Dir.mktmpdir
    @dir = enter_db_ledger
    Frijolero::NewLedger.prepare(@dir) # a ledger made in the app: a repo with no remote
    @ledger = Frijolero::Ledger.current
    Frijolero::App.reports = NoErrors.new
  end

  def teardown
    Frijolero::App.reports = nil
    leave_test_ledger
    FileUtils.remove_entry(@tmp)
    assert_equal @frijolero_head, run_git(Dir.pwd, 'rev-parse', 'HEAD').strip
  end

  def test_the_page_has_the_name_the_export_and_the_tokens
    page

    body = last_response.body
    assert_equal 200, last_response.status
    assert_includes body, 'value="Prueba"'
    assert_includes body, %(action="#{LEDGER_ROOT}/ledger/name")
    assert_includes body, %(href="#{LEDGER_ROOT}/ledger/export")
    assert_includes body, %(href="#{LEDGER_ROOT}/tokens")
    assert_ledger_links(body)
  end

  def test_rename
    post '/ledger/name', { name: ' Casa ' }, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_equal 303, last_response.status
    assert_equal "#{LEDGER_ROOT}/ledger", URI(last_response.location).path
    assert_equal 'Casa', Frijolero::Ledger.find('test').name
  end

  # For Fava and the other tools, which read the main file.
  def test_a_rename_commits_the_title_option
    post '/ledger/name', { name: 'Casa' }, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_includes File.read(File.join(@dir, 'main.beancount')), %(option "title" "Casa"\n)
    assert_equal 'Nombre del ledger', run_git(@dir, 'log', '-1', '--format=%s').strip
    assert_empty run_git(@dir, 'status', '--porcelain')
  end

  # A line break would start a directive in the main file.
  def test_a_name_is_one_line
    post '/ledger/name', { name: "Casa\ninclude \"x\"\t " }, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_equal 'Casa include "x"', Frijolero::Ledger.find('test').name
    assert_includes File.read(File.join(@dir, 'main.beancount')), %(option "title" "Casa include \\"x\\""\n)
  end

  # The row is the name: it stays, and the commit goes up with the next push.
  def test_a_failed_push_keeps_the_name_and_the_commit
    run_git(@dir, 'remote', 'add', 'origin', File.join(@tmp, 'no-existe.git'))

    post '/ledger/name', { name: 'Casa' }, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_equal 502, last_response.status
    assert_includes last_response.body, 'class="error"'
    assert_includes last_response.body, 'value="Casa"'
    assert_equal 'Casa', Frijolero::Ledger.find('test').name
    assert_equal 'Nombre del ledger', run_git(@dir, 'log', '-1', '--format=%s').strip
  end

  def test_a_rename_needs_a_name
    post '/ledger/name', { name: ' ' }, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'class="error"'
    assert_equal 'Prueba', Frijolero::Ledger.find('test').name
  end

  # Only the root: the app appends to the main file, and Ledger.update refuses any other.
  def test_the_page_offers_the_beancount_files_at_the_root
    File.write(File.join(@dir, 'otro.beancount'), '')
    FileUtils.mkdir_p(File.join(@dir, 'accounts', 'A'))
    File.write(File.join(@dir, 'accounts', 'A', 'A 2601.beancount'), '')

    page

    body = last_response.body
    assert_includes body, %(action="#{LEDGER_ROOT}/ledger/main")
    assert_includes body, '<option value="main.beancount" selected>main.beancount</option>'
    assert_includes body, '<option value="otro.beancount">otro.beancount</option>'
    refute_includes body, 'A 2601.beancount'
  end

  def test_change_the_main_file
    File.write(File.join(@dir, 'otro.beancount'), '')

    post '/ledger/main', { main_file: 'otro.beancount' }, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_equal 303, last_response.status
    assert_equal "#{LEDGER_ROOT}/ledger", URI(last_response.location).path
    assert_equal 'otro.beancount', Frijolero::Ledger.find('test').main_file
    assert_equal %(option "title" "Prueba"\n), File.read(File.join(@dir, 'otro.beancount'))
    assert_empty run_git(@dir, 'status', '--porcelain')
  end

  def test_the_main_file_is_one_of_the_files_at_the_root
    FileUtils.mkdir_p(File.join(@dir, 'accounts', 'A', 'dir.beancount'))
    File.write(File.join(@dir, 'accounts', 'A', 'A 2601.beancount'), '')
    FileUtils.mkdir_p(File.join(@dir, 'dir.beancount'))

    ['nope.beancount', 'accounts/A/A 2601.beancount', '../main.beancount', 'dir.beancount', ''].each do |file|
      post '/ledger/main', { main_file: file }, 'SCRIPT_NAME' => LEDGER_ROOT

      assert_equal 422, last_response.status, file
      assert_includes last_response.body, 'class="error"', file
    end
    assert_equal 'main.beancount', Frijolero::Ledger.find('test').main_file
  end

  def test_a_ledger_without_a_remote_offers_one
    page

    assert_includes last_response.body, %(action="#{LEDGER_ROOT}/ledger/key")
    refute_includes last_response.body, %(action="#{LEDGER_ROOT}/ledger/remote")
  end

  def test_the_key_then_the_url_add_the_remote
    run_git(@tmp, 'init', '-q', '--bare', '-b', 'main', 'nuevo.git')

    post '/ledger/key', {}, 'SCRIPT_NAME' => LEDGER_ROOT
    assert_equal 303, last_response.status
    page
    assert_includes last_response.body, File.read("#{@ledger.deploy_key}.pub").chomp
    assert_includes last_response.body, %(action="#{LEDGER_ROOT}/ledger/remote")
    assert_ledger_links(last_response.body)

    with_fake_ssh { post '/ledger/remote', { url: 'git@github.com:nuevo.git' }, 'SCRIPT_NAME' => LEDGER_ROOT }

    assert_equal 303, last_response.status
    assert_equal 'Configuración de Frijolero', run_git(File.join(@tmp, 'nuevo.git'), 'log', '-1', '--format=%s').strip
    assert_equal 'git@github.com:nuevo.git', remote_url
    page
    assert_includes last_response.body, '<code>git@github.com:nuevo.git</code>'
  end

  def test_a_failed_push_shows_the_error_and_leaves_no_remote
    post '/ledger/key', {}, 'SCRIPT_NAME' => LEDGER_ROOT

    with_fake_ssh { post '/ledger/remote', { url: 'git@github.com:no-existe.git' }, 'SCRIPT_NAME' => LEDGER_ROOT }

    assert_equal 422, last_response.status
    assert_includes last_response.body, 'class="error"'
    assert_includes last_response.body, 'value="git@github.com:no-existe.git"'
    assert_empty run_git(@dir, 'remote')
    assert_nil remote_url
  end

  # A ledger with a remote already has its key: a new one would replace it.
  def test_a_ledger_with_an_origin_gets_no_key_and_no_new_remote
    run_git(@dir, 'remote', 'add', 'origin', 'https://github.com/yo/ledger.git')

    page
    assert_includes last_response.body, '<code>https://github.com/yo/ledger.git</code>'
    refute_includes last_response.body, '/ledger/key'

    post '/ledger/key', {}, 'SCRIPT_NAME' => LEDGER_ROOT
    assert_equal 409, last_response.status
    refute_path_exists @ledger.deploy_key

    post '/ledger/remote', { url: 'git@github.com:nuevo.git' }, 'SCRIPT_NAME' => LEDGER_ROOT
    assert_equal 409, last_response.status
    assert_equal "https://github.com/yo/ledger.git\n", run_git(@dir, 'remote', 'get-url', 'origin')
  end

  def test_the_page_never_shows_the_credentials_of_the_origin
    run_git(@dir, 'remote', 'add', 'origin', 'https://x-access-token:secreto@github.com/yo/ledger.git')

    page

    refute_includes last_response.body, 'secreto'
    assert_includes last_response.body, '<code>https://github.com/yo/ledger.git</code>'
  end

  # Without the key, the push would go out with whatever ssh finds.
  def test_a_remote_needs_the_key_first
    post '/ledger/remote', { url: 'git@github.com:nuevo.git' }, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_equal 409, last_response.status
    assert_empty run_git(@dir, 'remote')
  end

  def test_the_export_is_a_tar_gz_of_head
    File.write(File.join(@dir, 'sin_commit.beancount'), '')

    get '/ledger/export', {}, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_equal 200, last_response.status
    assert_equal 'application/gzip', last_response.content_type
    assert_equal 'attachment; filename="Prueba.tar.gz"', last_response['content-disposition']
    tgz = File.join(@tmp, 'export.tar.gz')
    File.binwrite(tgz, last_response.body)
    files = IO.popen(['tar', '-tzf', tgz], &:read).lines(chomp: true)
    assert_includes files, 'main.beancount'
    assert_includes files, 'config/accounts.yaml'
    refute_includes files, 'sin_commit.beancount'
  end

  # The name of the file keeps to letters, numbers, dots and dashes.
  def test_the_export_file_name_is_plain_ascii
    Frijolero::Ledger.update('test', name: 'Mis "finanzas"/Ñoño')
    Frijolero::Ledger.current = Frijolero::Ledger.find('test')

    get '/ledger/export', {}, 'SCRIPT_NAME' => LEDGER_ROOT

    assert_equal 'attachment; filename="Mis-finanzas-Nono.tar.gz"', last_response['content-disposition']
  end

  private

  def page = get('/ledger', {}, 'SCRIPT_NAME' => LEDGER_ROOT)

  def remote_url = Frijolero::DB.first('SELECT remote_url FROM ledgers WHERE id = ?', 'test')['remote_url']
end
