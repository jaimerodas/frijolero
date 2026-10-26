# frozen_string_literal: true

require 'test_helper'
require 'fake_github'
require 'zlib'

class BackupTest < Minitest::Test
  include TestHelpers
  include LedgerRepoTestGit

  # Two users and three ledgers: one with commits, a job log and an origin but no
  # remote_url, as the first ledger, one with a remote_url and a deploy key, and one that
  # is not connected.
  def setup
    @frijolero_head = run_git(Dir.pwd, 'rev-parse', 'HEAD').strip
    @tmp = Dir.mktmpdir
    @data_dir_before = ENV.fetch('DATA_DIR', nil)
    ENV['DATA_DIR'] = @data = File.join(@tmp, 'data')
    @out = File.join(@tmp, 'out')
    @restored = File.join(@tmp, 'restored')
    FileUtils.mkdir_p(@out)

    ana = add_user('ana@example.com')
    beto = add_user('beto@example.com')
    add_ledger('aaaa1111', ana, nil)
    add_ledger('bbbb2222', beto, 'git@github.com:beto/ledger.git')
    add_ledger('cccc3333', beto, nil)

    @a = commit_repo('aaaa1111', 'uno', 'dos')
    run_git(@a, 'remote', 'add', 'origin', 'https://x-access-token:secreto@github.com/ana/ledger.git')
    File.write(File.join(ledger_dir('aaaa1111'), 'jobs.jsonl'), %({"id":"1"}\n{"id":"2"}\n{"id":"3","st))
    @b = commit_repo('bbbb2222', 'inicial')
    run_git(@b, 'remote', 'add', 'origin', 'git@github.com:beto/ledger.git')
    run_git(@b, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
    %w[bbbb2222 cccc3333].each { |id| File.write(File.join(ledger_dir(id), 'deploy_key'), "LLAVE PRIVADA\n") }
  end

  def teardown
    FileUtils.rm_rf(@tmp)
    @data_dir_before ? ENV['DATA_DIR'] = @data_dir_before : ENV.delete('DATA_DIR')
    assert_equal @frijolero_head, run_git(Dir.pwd, 'rev-parse', 'HEAD').strip
  end

  # One round trip, because each one costs half a second of git.
  def test_restore_gives_back_the_rows_the_repos_and_the_job_log
    restore(create)
    copy = SQLite3::Database.new(File.join(@restored, 'frijolero.sqlite3'), results_as_hash: true)

    %w[users ledgers].each do |table|
      assert_equal Frijolero::DB.execute("SELECT * FROM #{table} ORDER BY id"),
                   copy.execute("SELECT * FROM #{table} ORDER BY id")
    end
    { 'aaaa1111' => @a, 'bbbb2222' => @b }.each do |id, repo|
      assert_equal run_git(repo, 'log', '--format=%H %s'), run_git(restored_repo(id), 'log', '--format=%H %s')
      assert_equal 'false', run_git(restored_repo(id), 'config', 'core.symlinks').strip
      assert_empty run_git(restored_repo(id), 'status', '--porcelain')
    end
    # The line that a job was appending stays out: the app reads the log at boot.
    assert_equal %({"id":"1"}\n{"id":"2"}\n), File.read(File.join(@restored, 'ledgers', 'aaaa1111', 'jobs.jsonl'))
  ensure
    copy&.close
  end

  # The pull of each job needs the remote and its upstream branch. The row of the first
  # ledger has no remote_url: the archive keeps the origin of its clone, without the
  # credentials that a URL can carry.
  def test_restore_sets_origin_back
    archive = create
    restore(archive)

    assert_equal 'git@github.com:beto/ledger.git', origin('bbbb2222')
    assert_equal 'origin/main', run_git(restored_repo('bbbb2222'), 'rev-parse', '--abbrev-ref', '@{upstream}').strip
    assert_equal 'https://github.com/ana/ledger.git', origin('aaaa1111')
    refute_includes Zlib::GzipReader.open(archive, &:read), 'secreto'
  end

  def test_restore_leaves_a_ledger_without_a_remote_without_one
    run_git(@a, 'remote', 'remove', 'origin')
    restore(create)

    assert_empty run_git(restored_repo('aaaa1111'), 'remote')
  end

  # An own repo that is not connected has no repo/, and a ledger can have no commit yet.
  def test_create_and_restore_name_each_ledger_without_a_repo
    add_ledger('dddd4444', 1, nil)
    run_git(@tmp, 'init', '-q', File.join(ledger_dir('dddd4444'), 'repo'))
    create

    assert_match(/cccc3333/, @stderr)
    assert_match(/dddd4444/, @stderr)

    restore(Dir.glob(File.join(@out, '*')).first)

    assert_match(/cccc3333/, @stdout)
    assert File.directory?(File.join(@restored, 'ledgers', 'cccc3333'))
    refute File.exist?(restored_repo('cccc3333'))
  end

  # The private keys stay on the volume: after a restore, the person makes a new one.
  def test_the_archive_has_no_deploy_key
    raw = Zlib::GzipReader.open(create, &:read)

    refute_includes raw, 'deploy_key'
    refute_includes raw, 'LLAVE PRIVADA'
  end

  def test_a_corrupt_repo_raises_and_leaves_no_archive
    object = Dir.glob(File.join(@b, '.git', 'objects', '??', '*')).first
    File.chmod(0o644, object)
    File.binwrite(object, 'basura')

    assert_raises(Frijolero::LedgerRepo::Error) { create }
    assert_empty Dir.children(@out)
  end

  # An index that no longer matches its table: the copy keeps the damage, and the check
  # finds it.
  def test_a_failed_integrity_check_raises_and_leaves_no_archive
    Frijolero::DB.execute('CREATE TABLE junk (a)')
    Frijolero::DB.execute('CREATE INDEX junk_a ON junk (a)')
    Frijolero::DB.execute('INSERT INTO junk VALUES (1), (2)')
    Frijolero::DB.execute('PRAGMA writable_schema = ON')
    Frijolero::DB.execute("UPDATE sqlite_schema SET sql = 'CREATE INDEX junk_a ON junk (a + 1)' WHERE name = 'junk_a'")

    assert_raises(Frijolero::Backup::Error) { create }
    assert_empty Dir.children(@out)
  end

  def test_restore_refuses_a_directory_that_is_not_empty
    archive = create
    FileUtils.mkdir_p(@restored)
    File.write(File.join(@restored, 'algo'), "x\n")

    assert_raises(Frijolero::Backup::Error) { restore(archive) }
    assert_equal ['algo'], Dir.children(@restored)
  end

  private

  def create
    archive = nil
    @stdout, @stderr = capture_io { archive = Frijolero::Backup.create(@out) }
    archive
  end

  def restore(archive)
    @stdout, @stderr = capture_io { Frijolero::Backup.restore(archive, @restored) }
  end

  def add_user(email)
    Frijolero::DB.insert("INSERT INTO users (email, role, status, created_at) VALUES (?, 'user', 'active', ?)",
                         email, Time.now.utc.iso8601)
  end

  def add_ledger(id, owner, remote_url)
    Frijolero::DB.execute('INSERT INTO ledgers (id, owner_id, name, pdf_prefix, remote_url, created_at) ' \
                          "VALUES (?, ?, ?, 'frijolero', ?, ?)", id, owner, "Ledger #{id}", remote_url,
                          Time.now.utc.iso8601)
    FileUtils.mkdir_p(ledger_dir(id))
  end

  # A repo with one commit for each message.
  def commit_repo(id, *messages)
    repo = File.join(ledger_dir(id), 'repo')
    run_git(@tmp, 'init', '-q', '-b', 'main', repo)
    messages.each do |message|
      File.write(File.join(repo, 'main.beancount'), "; #{message}\n", mode: 'a')
      run_git(repo, 'add', '-A')
      run_git(repo, '-c', 'user.name=Prueba', '-c', 'user.email=prueba@example.com', '-c', 'commit.gpgsign=false',
              'commit', '-q', '-m', message)
    end
    repo
  end

  def ledger_dir(id) = File.join(@data, 'ledgers', id)

  def restored_repo(id) = File.join(@restored, 'ledgers', id, 'repo')

  def origin(id) = run_git(restored_repo(id), 'remote', 'get-url', 'origin').strip
end
