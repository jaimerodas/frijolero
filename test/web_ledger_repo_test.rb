# frozen_string_literal: true

require 'test_helper'
require 'frijolero/web/ledger_repo'
require 'open3'

class WebLedgerRepoTest < Minitest::Test
  include TestHelpers

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
    repo = Frijolero::Web::LedgerRepo.new(dir: @work, token: nil)

    assert repo.commit_and_push('AMEX 2508')
    assert_equal 'AMEX 2508', run_git(@origin, 'log', '-1', '--format=%s').strip
    assert_equal 'Frijolero', run_git(@origin, 'log', '-1', '--format=%an').strip
  end

  def test_commit_and_push_returns_false_when_nothing_staged
    repo = Frijolero::Web::LedgerRepo.new(dir: @work, token: nil)
    before = run_git(@origin, 'log', '-1', '--format=%H').strip

    refute repo.commit_and_push('nada que subir')
    assert_equal before, run_git(@origin, 'log', '-1', '--format=%H').strip
  end

  def test_pull_brings_in_remote_commit
    File.write(File.join(@seed, 'NEW.txt'), "hola\n")
    run_git(@seed, 'add', 'NEW.txt')
    seed_commit('agrega NEW.txt')
    run_git(@seed, 'push', 'origin', 'HEAD:main')
    repo = Frijolero::Web::LedgerRepo.new(dir: @work, token: nil)

    repo.pull

    assert File.exist?(File.join(@work, 'NEW.txt'))
  end

  def test_pull_raises_when_remote_missing
    FileUtils.remove_entry(@origin)
    repo = Frijolero::Web::LedgerRepo.new(dir: @work, token: nil)

    error = assert_raises(Frijolero::Web::LedgerRepo::Error) { repo.pull }

    assert_includes error.message, 'git pull'
  end

  def test_commit_and_push_raises_on_rejected_push
    File.write(File.join(@seed, 'README'), "cambio del seed\n")
    run_git(@seed, 'add', 'README')
    seed_commit('seed cambia README')
    run_git(@seed, 'push', 'origin', 'HEAD:main')

    File.write(File.join(@work, 'README'), "cambio del work\n")
    repo = Frijolero::Web::LedgerRepo.new(dir: @work, token: nil)

    assert_raises(Frijolero::Web::LedgerRepo::Error) { repo.commit_and_push('work cambia README') }
    assert_equal 'work cambia README', run_git(@work, 'log', '-1', '--format=%s').strip
  end

  def test_commit_and_push_with_token_against_path_remote
    File.write(File.join(@work, 'con_token.txt'), "x\n")
    repo = Frijolero::Web::LedgerRepo.new(dir: @work, token: 'abc')

    assert repo.commit_and_push('con token')
  end

  def test_commit_and_push_scrubs_git_dir_env
    File.write(File.join(@work, 'scrub.txt'), "x\n")
    repo = Frijolero::Web::LedgerRepo.new(dir: @work, token: nil)
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

  # Scrubs every GIT_* env var before shelling out, because a git hook exports
  # them to child processes and they override chdir:. See lib/frijolero/web/ledger_repo.rb.
  def run_git(dir, *args)
    env = ENV.keys.grep(/\AGIT_/).to_h { |k| [k, nil] }
    stdout, stderr, status = Open3.capture3(env, 'git', *args, chdir: dir)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end
end
