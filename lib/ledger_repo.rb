# frozen_string_literal: true

require 'open3'
require 'base64'

module Frijolero
  # The ledger clone on the volume. `git` as a shell command, nothing clever.
  class LedgerRepo
    class Error < StandardError; end

    def initialize(dir:, token: ENV.fetch('GIT_TOKEN', nil))
      @dir = dir
      @token = token
    end

    # A conflict would leave the clone mid-rebase and wedge every later job, so
    # abort and raise instead. The commit stays local, to untangle by hand.
    def pull
      git('pull', '--rebase')
    rescue Error
      abort_rebase
      raise
    end

    # Pulls again between commit and push: the laptop may have pushed since the
    # job's first pull, and the editors never pull at all.
    # rubocop:disable Naming/PredicateMethod -- name is part of the package's public API
    def commit_and_push(message)
      git('add', '-A')
      return false unless staged_changes?

      git('commit', '-m', message)
      pull
      git('push')
      true
    end
    # rubocop:enable Naming/PredicateMethod

    private

    # Every git subprocess must scrub GIT_* env vars: a git hook exports them
    # to children, and they override chdir:, redirecting us at the wrong repo.
    def git(*args)
      stdout, stderr, status = Open3.capture3(scrubbed_env, 'git', *config_flags, *args, chdir: @dir)
      raise Error, "git #{args.first}: #{stderr.strip}" unless status.success?

      stdout
    end

    def abort_rebase
      git('rebase', '--abort')
    rescue Error
      nil # nothing in progress: the failure was the fetch, not the rebase
    end

    def staged_changes?
      _out, _err, status = Open3.capture3(scrubbed_env, 'git', *config_flags, 'diff', '--cached', '--quiet',
                                          chdir: @dir)
      status.exitstatus == 1
    end

    def config_flags
      flags = ['-c', 'user.name=Frijolero', '-c', 'user.email=frijolero@localhost', '-c', 'commit.gpgsign=false']
      return flags unless @token

      auth = Base64.strict_encode64("x-access-token:#{@token}")
      flags + ['-c', "http.extraheader=AUTHORIZATION: basic #{auth}"]
    end

    def scrubbed_env
      ENV.keys.grep(/\AGIT_/).to_h { |k| [k, nil] }
    end
  end
end
