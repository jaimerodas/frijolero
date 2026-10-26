# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'open3'
require 'shellwords'

module Frijolero
  # The ledger clone on the volume. `git` as a shell command, nothing clever.
  class LedgerRepo
    class Error < StandardError; end

    # Security rule 4: git and ssh get these variables, plus the ssh command with a key,
    # and nothing else, so no secret of the app reaches them. It also drops the GIT_*
    # variables that a git hook exports: they override chdir:, and once sent a test's
    # commits to this repo.
    CLEAN_ENV = %w[PATH HOME TZ].freeze
    KNOWN_HOSTS = File.expand_path('../config/known_hosts', __dir__)
    HOSTS = File.readlines(KNOWN_HOSTS, chomp: true).reject { |line| line.empty? || line.start_with?('#') }
                .map { |line| line.split.first }.uniq.freeze
    # The trust boundary of a remote: SSH to a host in KNOWN_HOSTS, and nothing else. A
    # local path or file:// would clone another ledger from the disk, and ext:: or a
    # leading - would run a command.
    SSH_URL = %r{\A(?:git@([\w.-]+):|ssh://git@([\w.-]+)/)\w[\w./-]*\z}
    MAX_CLONE_BYTES = 100 * 1024 * 1024

    class << self
      def for(ledger) = new(dir: ledger.repo_dir, key: (ledger.deploy_key if File.exist?(ledger.deploy_key)))

      # An ed25519 key with mode 600, from ssh-keygen. It refuses to replace a key,
      # which the person has given to GitHub already. Returns the public key line.
      def keygen(path)
        _out, err, status = Open3.capture3(ENV.slice(*CLEAN_ENV), 'ssh-keygen', '-q', '-t', 'ed25519', '-N', '',
                                           '-C', 'frijolero', '-f', path, unsetenv_others: true)
        raise Error, "ssh-keygen: #{err.strip}" unless status.success?

        File.read("#{path}.pub").chomp
      end

      # A person's own repo. core.symlinks=false stays in the config of the clone, so no
      # later pull makes a symlink either.
      def clone(url, dir, key:)
        check_url(url)
        new(dir: File.dirname(dir), key: key, token: nil)
          .git('clone', '-q', '--no-checkout', '-c', 'core.symlinks=false', '--', url, File.expand_path(dir))
        new(dir: dir, key: key, token: nil).tap { |repo| checkout(repo, dir) }
      end

      def check_url(url)
        match = SSH_URL.match(url)
        return if match && HOSTS.include?(match[1] || match[2])

        raise Error, "El remoto debe ser git@<host>:<ruta> o ssh://git@<host>/<ruta>, en #{HOSTS.join(' o ')}"
      end

      private

      # Counts the files before it writes them: a small pack of one large file, repeated,
      # would fill the disk of every app on the host. An empty repo has nothing to check
      # out. ponytail: the download of the pack has no limit; a timeout if that matters.
      def checkout(repo, dir)
        return if repo.git('rev-list', '-n1', '--all').empty?

        files = repo.git('ls-tree', '-r', '-l', 'HEAD').lines.sum { |line| line.split[3].to_i }
        raise Error, 'El repo pesa más de 100 MB: Frijolero no lo clona' if files + bytes(dir) > MAX_CLONE_BYTES

        repo.git('checkout', '-q')
      rescue Error
        FileUtils.rm_rf(dir)
        raise
      end

      def bytes(dir) = Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).sum { |f| File.lstat(File.join(dir, f)).size }
    end

    # `key` is the deploy key of an SSH remote. `token` is for the HTTPS remote of the
    # first ledger, until it has a deploy key too. A ledger with a key never gets the token.
    def initialize(dir:, key: nil, token: ENV.fetch('GIT_TOKEN', nil))
      @dir = dir
      @key = key
      @token = token unless key
    end

    # A conflict would leave the clone mid-rebase and wedge every later job, so
    # abort and raise instead. The commit stays local, to untangle by hand.
    def pull
      return unless remote?

      git('pull', '--rebase')
    rescue Error
      abort_rebase
      raise
    end

    # The last commit of the clone, so a page can say how fresh the ledger is.
    def head
      date, subject = git('log', '-1', '--format=%cs%n%s').lines(chomp: true)
      { date: date, subject: subject }
    end

    # Pulls again between commit and push: the laptop may have pushed since the
    # job's first pull, and the editors never pull at all.
    # rubocop:disable-next Naming/PredicateMethod -- name is part of the package's public API
    def commit_and_push(message)
      git('add', '-A')
      return false unless staged_changes?

      git('commit', '-m', message)
      pull
      git('push') if remote?
      true
    end

    # A remote for a ledger that has none. If the push fails, the remote goes again:
    # a remote that the app cannot reach would fail the pull of every later job.
    def add_remote(url)
      self.class.check_url(url)
      git('remote', 'add', 'origin', url)
      begin
        git('push', '-u', 'origin', 'HEAD')
      rescue Error
        git('remote', 'remove', 'origin')
        raise
      end
    end

    # The URL of origin, or nil: a ledger made in the app has none until it gets one.
    # A URL has no whitespace, and `config --default` prints an empty line for no origin.
    def origin = git('config', '--default', '', '--get', 'remote.origin.url')[/\S+/]

    # The export: the files of the last commit, as a .tar.gz, without .git.
    def archive = git('archive', '--format=tar.gz', 'HEAD')

    # Every git subprocess of the app goes through here, for the clean environment.
    def git(*args)
      stdout, stderr, status = Open3.capture3(env, 'git', *config_flags, *args, chdir: @dir, unsetenv_others: true)
      raise Error, "git #{args.first}: #{stderr.strip}" unless status.success?

      stdout
    end

    private

    # A laptop-only ledger has no remote: the commits stay local.
    def remote? = !git('remote').strip.empty?

    def abort_rebase
      git('rebase', '--abort')
    rescue Error
      nil # nothing in progress: the failure was the fetch, not the rebase
    end

    def staged_changes? = !git('diff', '--cached', '--name-only').empty?

    # core.symlinks=false on every call, not only in the config of a clone: the first ledger
    # and a template ledger with a remote added later have none, and a pull from the
    # person's remote must not make a symlink there either.
    def config_flags
      flags = ['-c', 'user.name=Frijolero', '-c', 'user.email=frijolero@localhost', '-c', 'commit.gpgsign=false',
               '-c', 'core.symlinks=false']
      return flags unless @token

      auth = Base64.strict_encode64("x-access-token:#{@token}")
      flags + ['-c', "http.extraheader=AUTHORIZATION: basic #{auth}"]
    end

    def env = ENV.slice(*CLEAN_ENV).merge(@key ? { 'GIT_SSH_COMMAND' => ssh_command } : {})

    # Only the deploy key, and only a host key from KNOWN_HOSTS: an unknown or changed
    # host key fails the connection.
    def ssh_command
      ['ssh', '-i', @key, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
       '-o', "UserKnownHostsFile=#{KNOWN_HOSTS}"].shelljoin
    end
  end
end
