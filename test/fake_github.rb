# frozen_string_literal: true

require 'fileutils'
require 'open3'

# git for the setup of the tests that run it. It scrubs every GIT_* env var before it
# shells out, because a git hook exports them to child processes and they override
# chdir:. See lib/ledger_repo.rb.
module LedgerRepoTestGit
  def run_git(dir, *args)
    env = ENV.keys.grep(/\AGIT_/).to_h { |k| [k, nil] }
    stdout, stderr, status = Open3.capture3(env, 'git', *args, chdir: dir)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end
end

# A fake ssh, first on PATH, that serves the repos in @tmp as GitHub would, so no test
# uses the network: git@github.com:source.git is @tmp/source.git. The test includes
# TestHelpers, for with_env.
module FakeGithub
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

  def with_fake_ssh(&)
    bin = File.join(@tmp, 'bin')
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, 'ssh'), FAKE_SSH)
    File.chmod(0o755, File.join(bin, 'ssh'))
    with_env('PATH' => "#{bin}:#{ENV.fetch('PATH')}", &)
  end
end
