# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'sqlite3'
require 'tmpdir'

module Frijolero
  # One .tar.gz with what only the volume holds. The PDFs are in the bucket, an upload in
  # the Bandeja can be uploaded again, and the private deploy keys never leave the volume.
  #
  #   frijolero.sqlite3          a copy of the live database, checked
  #   ledgers/<id>.bundle        every ref of the clone, verified
  #   ledgers/<id>/origin        the URL of origin, without the credentials a URL can carry
  #   ledgers/<id>/jobs.jsonl    the job log
  module Backup
    class Error < StandardError; end

    DB_FILE = 'frijolero.sqlite3'

    class << self
      # Every check runs before the archive exists, so a failure leaves nothing behind.
      # Returns the path of the archive. A ledger without repo/ or without a commit goes
      # without its repo, and stderr names it.
      def create(out_dir)
        Dir.mktmpdir('frijolero-backup') do |tmp|
          copy_database(File.join(tmp, DB_FILE)).each { |ledger| add_ledger(ledger, File.join(tmp, 'ledgers')) }
          archive = File.join(File.expand_path(out_dir), "frijolero-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.tar.gz")
          tar('-czf', archive, '-C', tmp, '.')
          archive
        rescue Error
          FileUtils.rm_f(archive) if archive
          raise
        end
      end

      # Into an empty directory only, so a restore never mixes with data. Prints one line
      # per ledger: its last commit and its remote, or that it has no repo.
      def restore(archive, data_dir)
        raise Error, "#{data_dir} no está vacío: restaura en un directorio vacío" unless empty_dir?(data_dir)

        Dir.mktmpdir('frijolero-restore') do |tmp|
          tar('-xzf', File.expand_path(archive), '-C', tmp)
          FileUtils.mkdir_p(data_dir)
          FileUtils.cp(File.join(tmp, DB_FILE), data_dir)
          ledger_rows(File.join(tmp, DB_FILE)).each do |row|
            restore_ledger(row, File.join(tmp, 'ledgers'), File.join(data_dir, 'ledgers', row['id']))
          end
        end
      end

      private

      # The online backup API copies the live database in one consistent read, WAL
      # included. Returns the ledgers of the copy, so the bundles match its rows.
      def copy_database(path)
        raise Error, "No existe #{DB.path}" unless File.exist?(DB.path)

        source = SQLite3::Database.new(DB.path, readonly: true)
        copy = SQLite3::Database.new(path, results_as_hash: true)
        copy_pages(source, copy)
        check = copy.get_first_value('PRAGMA integrity_check')
        raise Error, "La copia de la base de datos no pasa integrity_check: #{check}" unless check == 'ok'

        copy.execute('SELECT * FROM ledgers ORDER BY created_at, id').map { |row| Ledger.from_row(row) }
      ensure
        copy&.close
        source&.close
      end

      def copy_pages(source, copy)
        backup = SQLite3::Backup.new(copy, 'main', source, 'main')
        done = backup.step(-1) == SQLite3::Constants::ErrorCode::DONE
        backup.finish
        raise Error, 'La copia de la base de datos no terminó' unless done
      end

      # No Ledger.lock: bin/backup is a process of its own, and Puma's lock lives in Puma.
      # git writes the objects before it moves a ref, and moves it in one step, so a bundle
      # made during a job's push is whole, with or without that push.
      def add_ledger(ledger, dir)
        copy_jobs(ledger, File.join(dir, ledger.id))
        return skipped(ledger, 'no tiene repo/') unless File.directory?(ledger.repo_dir)

        repo = LedgerRepo.new(dir: ledger.repo_dir, token: nil)
        return skipped(ledger, 'no tiene commits') if repo.git('rev-list', '-n1', '--all').empty?

        bundle(repo, dir, ledger.id)
      end

      def bundle(repo, dir, id)
        file = File.join(dir, "#{id}.bundle")
        repo.git('bundle', 'create', '-q', file, '--all')
        repo.git('bundle', 'verify', '-q', file)
        origin = repo.origin
        File.write(File.join(dir, id, 'origin'), origin.sub(%r{//[^/@]*@}, '//')) if origin
      end

      # Whole lines only: a job may be appending one right now, and a torn line would stop
      # the restored app at boot.
      def copy_jobs(ledger, dir)
        FileUtils.mkdir_p(dir)
        log = File.join(ledger.dir, 'jobs.jsonl')
        File.write(File.join(dir, 'jobs.jsonl'), File.read(log)[/.*\n/m].to_s) if File.exist?(log)
      end

      def skipped(ledger, why) = warn("#{ledger.id} (#{ledger.name}) #{why}: el respaldo va sin su repo")

      def restore_ledger(row, from, dir)
        FileUtils.mkdir_p(dir)
        own = File.join(from, row['id'])
        FileUtils.cp(File.join(own, 'jobs.jsonl'), dir) if File.exist?(File.join(own, 'jobs.jsonl'))
        bundle = "#{own}.bundle"
        status = File.exist?(bundle) ? clone(bundle, dir, row['remote_url'] || read(File.join(own, 'origin'))) : nil
        puts "#{row['id']} (#{row['name']}): #{status || 'sin repo en el respaldo'}"
      end

      # The origin is the one of the row, or else the one the clone had: the first ledger
      # pulls over HTTPS and its row has no remote_url. Without either, the clone keeps no
      # remote, which would point at the bundle. Returns the last commit and the remote.
      def clone(bundle, dir, url)
        LedgerRepo.new(dir: dir, token: nil).git('clone', '-q', '-c', 'core.symlinks=false', '--', bundle, 'repo')
        repo = LedgerRepo.new(dir: File.join(dir, 'repo'), token: nil)
        url ? repo.git('remote', 'set-url', 'origin', url) : repo.git('remote', 'remove', 'origin')
        "#{repo.head.values.join(' ')}, #{url || 'sin remoto'}"
      end

      def ledger_rows(path)
        db = SQLite3::Database.new(path, readonly: true, results_as_hash: true)
        db.execute('SELECT id, name, remote_url FROM ledgers ORDER BY created_at, id')
      ensure
        db&.close
      end

      def read(path) = (File.read(path) if File.exist?(path))

      def empty_dir?(dir) = !File.exist?(dir) || (File.directory?(dir) && Dir.empty?(dir))

      def tar(*)
        _out, err, status = Open3.capture3(ENV.slice(*LedgerRepo::CLEAN_ENV), 'tar', *, unsetenv_others: true)
        raise Error, "tar: #{err.strip}" unless status.success?
      end
    end
  end
end
