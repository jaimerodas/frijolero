# frozen_string_literal: true

require 'test_helper'
require 'open3'

# git for the setup of these tests. It scrubs every GIT_* env var before it shells out,
# because a git hook exports them to child processes and they override chdir:. See
# lib/ledger_repo.rb.
module LedgerRepoTestGit
  def run_git(dir, *args)
    env = ENV.keys.grep(/\AGIT_/).to_h { |k| [k, nil] }
    stdout, stderr, status = Open3.capture3(env, 'git', *args, chdir: dir)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end
end

class LedgerRepoTest < Minitest::Test
  include TestHelpers
  include LedgerRepoTestGit

  def setup
    @frijolero_head = run_git(Dir.pwd, 'rev-parse', 'HEAD').strip
    @tmp = Dir.mktmpdir
    run_git(@tmp, 'init', '--bare', 'origin.git')
    @origin = File.join(@tmp, 'origin.git')
    run_git(@origin, 'symbolic-ref', 'HEAD', 'refs/heads/main')

    run_git(@tmp, 'clone', '-q', @origin, 'seed')
    @seed = File.join(@tmp, 'seed')
    File.write(File.join(@seed, 'README'), "hello\n")
    run_git(@seed, 'add', 'README')
    seed_commit('mensaje inicial')
    run_git(@seed, 'push', '-q', 'origin', 'HEAD:refs/heads/main')

    run_git(@tmp, 'clone', '-q', @origin, 'work')
    @work = File.join(@tmp, 'work')

    remote_url = run_git(@work, 'remote', 'get-url', 'origin').strip
    raise "remote guard failed: #{remote_url}" unless remote_url.start_with?(@tmp)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
    assert_equal @frijolero_head, run_git(Dir.pwd, 'rev-parse', 'HEAD').strip
  end

  def test_commit_and_push_returns_true_and_pushes
    File.write(File.join(@work, 'AMEX_2508.beancount'), "; stmt\n")
    repo = Frijolero::LedgerRepo.new(dir: @work, token: nil)

    assert repo.commit_and_push('AMEX 2508')
    assert_equal 'AMEX 2508', run_git(@origin, 'log', '-1', '--format=%s').strip
    assert_equal 'Frijolero', run_git(@origin, 'log', '-1', '--format=%an').strip
  end

  # A ledger with no remote is the laptop-only setup: the commit stays local and
  # nothing raises, so every job and every editor save still works.
  def test_pull_and_push_are_skipped_without_a_remote
    local = File.join(@tmp, 'local')
    run_git(@tmp, 'init', '-q', '-b', 'main', 'local')
    File.write(File.join(local, 'README'), "solo\n")
    repo = Frijolero::LedgerRepo.new(dir: local, token: nil)

    assert_nil repo.pull
    assert repo.commit_and_push('sin remoto')
    assert_equal 'sin remoto', run_git(local, 'log', '-1', '--format=%s').strip
  end

  def test_head_gives_the_date_and_subject_of_the_last_commit
    repo = Frijolero::LedgerRepo.new(dir: @work, token: nil)

    assert_equal({ date: Date.today.iso8601, subject: 'mensaje inicial' }, repo.head)
  end

  def test_head_raises_outside_a_repo
    assert_raises(Frijolero::LedgerRepo::Error) { Frijolero::LedgerRepo.new(dir: @tmp, token: nil).head }
  end

  def test_commit_and_push_returns_false_when_nothing_staged
    repo = Frijolero::LedgerRepo.new(dir: @work, token: nil)
    before = run_git(@origin, 'log', '-1', '--format=%H').strip

    refute repo.commit_and_push('nada que subir')
    assert_equal before, run_git(@origin, 'log', '-1', '--format=%H').strip
  end

  def test_pull_brings_in_remote_commit
    File.write(File.join(@seed, 'NEW.txt'), "hola\n")
    run_git(@seed, 'add', 'NEW.txt')
    seed_commit('agrega NEW.txt')
    run_git(@seed, 'push', 'origin', 'HEAD:main')
    repo = Frijolero::LedgerRepo.new(dir: @work, token: nil)

    repo.pull

    assert File.exist?(File.join(@work, 'NEW.txt'))
  end

  def test_pull_raises_when_remote_missing
    FileUtils.remove_entry(@origin)
    repo = Frijolero::LedgerRepo.new(dir: @work, token: nil)

    error = assert_raises(Frijolero::LedgerRepo::Error) { repo.pull }

    assert_includes error.message, 'git pull'
  end

  def test_commit_and_push_rebases_on_remote_commit_before_pushing
    File.write(File.join(@seed, 'README'), "cambio del seed\n")
    run_git(@seed, 'add', 'README')
    seed_commit('seed cambia README')
    run_git(@seed, 'push', 'origin', 'HEAD:main')

    File.write(File.join(@work, 'rules.yaml'), "start_with: {}\n")
    repo = Frijolero::LedgerRepo.new(dir: @work, token: nil)

    assert repo.commit_and_push('work agrega rules')
    assert_equal "work agrega rules\nseed cambia README", run_git(@origin, 'log', '-2', '--format=%s').strip
    assert_equal "cambio del seed\n", File.read(File.join(@work, 'README'))
  end

  def test_commit_and_push_aborts_rebase_on_conflict
    File.write(File.join(@seed, 'README'), "cambio del seed\n")
    run_git(@seed, 'add', 'README')
    seed_commit('seed cambia README')
    run_git(@seed, 'push', 'origin', 'HEAD:main')

    File.write(File.join(@work, 'README'), "cambio del work\n")
    repo = Frijolero::LedgerRepo.new(dir: @work, token: nil)

    error = assert_raises(Frijolero::LedgerRepo::Error) { repo.commit_and_push('work cambia README') }
    assert_includes error.message, 'git pull'
    assert_equal 'work cambia README', run_git(@work, 'log', '-1', '--format=%s').strip
    assert_empty run_git(@work, 'status', '--porcelain')
    refute File.exist?(File.join(@work, '.git', 'rebase-merge'))
  end

  def test_commit_and_push_with_token_against_path_remote
    File.write(File.join(@work, 'con_token.txt'), "x\n")
    repo = Frijolero::LedgerRepo.new(dir: @work, token: 'abc')

    assert repo.commit_and_push('con token')
  end

  # The token reaches git as http.extraheader, which `git config --get` reads back.
  def test_the_token_reaches_git_without_a_deploy_key
    repo = Frijolero::LedgerRepo.new(dir: @work, token: 'abc')

    assert_includes repo.git('config', '--get', 'http.extraheader'), 'AUTHORIZATION: basic'
  end

  def test_a_ledger_with_a_deploy_key_never_gets_the_token
    repo = Frijolero::LedgerRepo.new(dir: @work, key: File.join(@tmp, 'deploy_key'), token: 'abc')

    assert_raises(Frijolero::LedgerRepo::Error) { repo.git('config', '--get', 'http.extraheader') }
  end

  def test_commit_and_push_scrubs_git_dir_env
    File.write(File.join(@work, 'scrub.txt'), "x\n")
    repo = Frijolero::LedgerRepo.new(dir: @work, token: nil)
    old_git_dir = ENV.fetch('GIT_DIR', nil)
    ENV['GIT_DIR'] = '/nonexistent/.git'

    begin
      result = repo.commit_and_push('scrub check')
    ensure
      old_git_dir ? (ENV['GIT_DIR'] = old_git_dir) : ENV.delete('GIT_DIR')
    end

    assert result
    assert_equal 'scrub check', run_git(@origin, 'log', '-1', '--format=%s').strip
  end

  private

  def seed_commit(message)
    run_git(@seed, '-c', 'user.name=Seed', '-c', 'user.email=seed@localhost', 'commit', '-m', message)
  end
end

# The SSH side: deploy keys, clones and new remotes. A fake ssh, first on PATH, serves
# the repos in @tmp as GitHub would, so no test uses the network. @source is the repo
# that it serves as git@github.com:source.git: a plain repo with one commit and no
# remote, so a test commits there with no push.
class LedgerRepoSshTest < Minitest::Test
  include TestHelpers
  include LedgerRepoTestGit

  KNOWN_HOSTS = File.expand_path('../config/known_hosts', __dir__)
  URL = 'git@github.com:source.git'

  # It notes its arguments and its environment, then runs the git command that it gets.
  # An ssh:// URL sends an absolute path, so the leading slash goes.
  FAKE_SSH = <<~'SH'
    #!/bin/sh
    here=$(dirname "$0")
    printf '%s\n' "$@" > "$here/args"
    env > "$here/env"
    for last; do :; done
    cd "$here/.." && eval "git $(printf '%s' "${last#git-}" | sed "s|'/|'|")"
  SH

  def setup
    @frijolero_head = run_git(Dir.pwd, 'rev-parse', 'HEAD').strip
    @tmp = Dir.mktmpdir
    run_git(@tmp, 'init', '-q', '-b', 'main', 'source.git')
    @source = File.join(@tmp, 'source.git')
    File.write(File.join(@source, 'README'), "hello\n")
    commit_to_source('mensaje inicial', 'README')
  end

  def teardown
    FileUtils.remove_entry(@tmp)
    assert_equal @frijolero_head, run_git(Dir.pwd, 'rev-parse', 'HEAD').strip
  end

  def test_no_secret_of_the_app_reaches_git_or_ssh
    repo = Frijolero::LedgerRepo.new(dir: clone_of_source, key: key, token: nil)
    secrets = %w[OPENAI_API_KEY ANTHROPIC_API_KEY S3_KEY GIT_TOKEN SESSION_SECRET].to_h { |k| [k, 'secreto-123'] }

    with_env(secrets) { with_fake_ssh { repo.pull } }

    env = File.read(File.join(@tmp, 'bin', 'env'))
    assert_includes env, 'GIT_SSH_COMMAND=', 'the environment of the ssh that git ran'
    refute_includes env, 'secreto-123'
  end

  def test_for_a_ledger_uses_its_deploy_key
    ledger = ledger_at(clone_of_source)
    File.write(ledger.deploy_key, "llave\n")

    with_fake_ssh { Frijolero::LedgerRepo.for(ledger).pull }

    assert_equal ['-i', ledger.deploy_key], ssh_args.first(2)
  end

  def test_for_a_ledger_without_a_deploy_key_runs_plain_ssh
    ledger = ledger_at(clone_of_source)

    with_fake_ssh { Frijolero::LedgerRepo.for(ledger).pull }

    refute_includes ssh_args, '-i'
  end

  def test_keygen_makes_a_key_that_only_the_app_can_read
    public_key = Frijolero::LedgerRepo.keygen(key)

    assert_equal 0o600, File.stat(key).mode & 0o777
    assert_match(/\Assh-ed25519 \S+ frijolero\z/, public_key)
    assert_equal "#{public_key}\n", File.read("#{key}.pub")
  end

  # The person gave the public key to GitHub: a new key would lock the ledger out.
  def test_keygen_never_replaces_a_key
    Frijolero::LedgerRepo.keygen(key)
    before = File.read(key)

    assert_raises(Frijolero::LedgerRepo::Error) { Frijolero::LedgerRepo.keygen(key) }
    assert_equal before, File.read(key)
  end

  def test_clone_uses_the_deploy_key_and_the_known_hosts_of_the_app
    repo = with_fake_ssh { Frijolero::LedgerRepo.clone(URL, dest, key: key) }

    assert_equal 'mensaje inicial', repo.head[:subject]
    assert_path_exists File.join(dest, 'README')
    assert_equal ['-i', key, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
                  '-o', "UserKnownHostsFile=#{KNOWN_HOSTS}"], ssh_args.first(8)
    assert_includes ssh_args, 'git@github.com'
  end

  def test_clone_takes_an_ssh_url
    with_fake_ssh { Frijolero::LedgerRepo.clone('ssh://git@gitlab.com/source.git', dest, key: key) }

    assert_path_exists File.join(dest, 'README')
  end

  # A person can start a ledger from a repo that they just made on GitHub.
  def test_clone_takes_an_empty_repo
    run_git(@tmp, 'init', '-q', '--bare', '-b', 'main', 'vacio.git')

    with_fake_ssh { Frijolero::LedgerRepo.clone('git@github.com:vacio.git', dest, key: key) }

    assert_equal %w[.git], Dir.children(dest)
  end

  # A symlink in a person's repo would let the app read or write outside the ledger.
  def test_a_clone_never_checks_out_a_symlink
    File.symlink('/etc/hosts', File.join(@source, 'hosts'))
    commit_to_source('enlace en el clon', 'hosts')
    repo = with_fake_ssh { Frijolero::LedgerRepo.clone(URL, dest, key: key) }
    File.symlink('/etc/passwd', File.join(@source, 'passwd'))
    commit_to_source('enlace en un pull', 'passwd')

    with_fake_ssh { repo.pull }

    refute File.symlink?(File.join(dest, 'hosts')), 'the clone'
    refute File.symlink?(File.join(dest, 'passwd')), 'a later pull'
  end

  # 51 paths of one 2 MiB blob: a small pack, but 102 MiB on disk after a checkout.
  def test_clone_refuses_a_repo_larger_than_100_mb
    big = File.join(@tmp, 'big')
    File.write(big, "\0" * (2 * 1024 * 1024))
    blob = run_git(@source, 'hash-object', '-w', big).strip
    run_git(@source, 'update-index', '--add', *(1..51).flat_map { |n| ['--cacheinfo', "100644,#{blob},f#{n}"] })
    commit_to_source('grande')

    error = assert_raises(Frijolero::LedgerRepo::Error) do
      with_fake_ssh { Frijolero::LedgerRepo.clone(URL, dest, key: key) }
    end

    assert_match(/100 MB/, error.message)
    refute_path_exists dest
  end

  def test_clone_refuses_any_url_but_ssh_to_a_known_host
    with_fake_ssh do
      bad_urls.each do |url|
        assert_raises(Frijolero::LedgerRepo::Error, url) { Frijolero::LedgerRepo.clone(url, dest, key: key) }
      end
    end

    refute_path_exists dest
    refute_path_exists File.join(@tmp, 'pwned')
  end

  def test_add_remote_pushes_the_ledger_and_tracks_it
    run_git(@tmp, 'init', '-q', '--bare', '-b', 'main', 'nuevo.git')
    repo = Frijolero::LedgerRepo.new(dir: @source, key: key, token: nil)

    with_fake_ssh { repo.add_remote('git@github.com:nuevo.git') }

    assert_equal 'mensaje inicial', run_git(File.join(@tmp, 'nuevo.git'), 'log', '-1', '--format=%s').strip
    assert_equal 'origin/main', run_git(@source, 'rev-parse', '--abbrev-ref', '@{u}').strip
  end

  # A remote that the push cannot reach would fail the pull of every later job.
  def test_add_remote_leaves_no_remote_when_the_push_fails
    repo = Frijolero::LedgerRepo.new(dir: @source, key: key, token: nil)

    with_fake_ssh do
      assert_raises(Frijolero::LedgerRepo::Error) { repo.add_remote('git@github.com:no-existe.git') }
    end

    assert_empty run_git(@source, 'remote')
  end

  def test_add_remote_refuses_any_url_but_ssh_to_a_known_host
    repo = Frijolero::LedgerRepo.new(dir: @source, key: key, token: nil)

    with_fake_ssh do
      bad_urls.each { |url| assert_raises(Frijolero::LedgerRepo::Error, url) { repo.add_remote(url) } }
    end

    assert_empty run_git(@source, 'remote')
    refute_path_exists File.join(@tmp, 'pwned')
  end

  private

  def with_fake_ssh(&)
    bin = File.join(@tmp, 'bin')
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, 'ssh'), FAKE_SSH)
    File.chmod(0o755, File.join(bin, 'ssh'))
    with_env('PATH' => "#{bin}:#{ENV.fetch('PATH')}", &)
  end

  def ssh_args = File.readlines(File.join(@tmp, 'bin', 'args'), chomp: true)

  # The fake ssh never reads it.
  def key = File.join(@tmp, 'deploy_key')

  def dest = File.join(@tmp, 'clon')

  # A local path or file:// would clone another ledger from the disk; ext:: and a
  # leading - would run a command.
  def bad_urls
    [@source, "file://#{@source}", "ext::sh -c touch% #{@tmp}/pwned", "--upload-pack=touch #{@tmp}/pwned",
     'git@evil.example:source.git', 'https://github.com/source.git', 'ssh://git@github.com:22/source.git']
  end

  def commit_to_source(message, *paths)
    run_git(@source, 'add', *paths) unless paths.empty?
    run_git(@source, '-c', 'user.name=Origen', '-c', 'user.email=origen@localhost', 'commit', '-q', '-m', message)
  end

  # A clone with its origin on GitHub, which the fake ssh serves.
  def clone_of_source
    run_git(@tmp, 'clone', '-q', @source, 'work')
    work = File.join(@tmp, 'work')
    run_git(work, 'remote', 'set-url', 'origin', URL)
    work
  end

  def ledger_at(repo_dir)
    dir = File.join(@tmp, 'ledger')
    FileUtils.mkdir_p(dir)
    Frijolero::Ledger.new(id: 'abc', owner_id: 1, main_file: 'main.beancount', pdf_prefix: 'frijolero/ledgers/abc',
                          dir: dir, repo_dir: repo_dir)
  end
end
