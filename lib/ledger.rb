# frozen_string_literal: true

require 'fileutils'
require 'monitor'
require 'securerandom'
require 'time'

module Frijolero
  # There is no current ledger on this thread. A request outside a ledger, or a thread
  # that forgot Ledger.with, gets this instead of another ledger's data.
  class NoLedger < StandardError; end

  # One ledger: `repo_dir` is its git clone, `dir` holds the rest (the job log, the
  # uploads, the PDFs without a bucket, the deploy key). The rows are in DB; `from_row`
  # puts both directories under DATA_DIR, and a test can point them anywhere.
  Ledger = Data.define(:id, :owner_id, :name, :main_file, :pdf_prefix, :dir, :repo_dir) do
    @locks = {}
    @locks_mutex = Mutex.new

    # One lock per ledger, around git and the writes to its files: a job's pull and its
    # writes, an editor save, a pull, a report's check of the includes and its rledger run.
    # Never around a model call, which can take minutes. A Monitor, so a locked block can
    # call code that locks again.
    def self.lock(id = current.id, &)
      @locks_mutex.synchronize { @locks[id] ||= Monitor.new }.synchronize(&)
    end

    def self.all = DB.execute('SELECT * FROM ledgers ORDER BY created_at, id').map { |row| from_row(row) }

    def self.owned_by(user_id)
      DB.execute('SELECT * FROM ledgers WHERE owner_id = ? ORDER BY created_at, id', user_id)
        .map { |row| from_row(row) }
    end

    def self.find(id)
      row = DB.first('SELECT * FROM ledgers WHERE id = ?', id)
      row && from_row(row)
    end

    def self.from_row(row)
      dir = File.join(Config.data_dir, 'ledgers', row['id'])
      new(id: row['id'], owner_id: row['owner_id'], name: row['name'], main_file: row['main_file'],
          pdf_prefix: row['pdf_prefix'], dir: dir, repo_dir: File.join(dir, 'repo'))
    end

    # 8 characters from [a-z0-9]. The primary key refuses a repeat, which 36^8 makes rare.
    def self.new_id = SecureRandom.alphanumeric(8, chars: [*'a'..'z', *'0'..'9'])

    # The row and the directory. The caller makes repo/ with NewLedger.prepare or
    # LedgerRepo.clone.
    def self.create(owner_id:, name:)
      id = new_id
      DB.execute('INSERT INTO ledgers (id, owner_id, name, main_file, pdf_prefix, created_at) ' \
                 "VALUES (?, ?, ?, 'main.beancount', ?, ?)", id, owner_id, name, "frijolero/ledgers/#{id}",
                 Time.now.utc.iso8601)
      find(id).tap { |ledger| FileUtils.mkdir_p(ledger.dir) }
    end

    # The column names come from this list, never from the caller. The app appends to
    # the main file, so it must be a .beancount in the root: a path out of the ledger
    # would write to another one.
    def self.update(id, **fields)
      unknown = fields.keys - %i[name main_file remote_url]
      raise ArgumentError, "Ledger.update no cambia #{unknown.join(', ')}" if unknown.any?

      main = fields[:main_file]
      if main && !(File.basename(main) == main && main.end_with?('.beancount'))
        raise ArgumentError, "El archivo principal es un .beancount en la raíz del ledger, no #{main}"
      end

      DB.execute("UPDATE ledgers SET #{fields.keys.map { |key| "#{key} = ?" }.join(', ')} WHERE id = ?",
                 *fields.values, id)
    end

    def deploy_key = File.join(dir, 'deploy_key')

    # The ledger of this request or job. Thread.current[] is fiber-local and nothing
    # inherits it. Fiber[] storage would be inherited by a thread that a request starts.
    def self.current = Thread.current[:frijolero_ledger] || raise(NoLedger, 'No hay un ledger en curso')

    def self.current=(ledger)
      Thread.current[:frijolero_ledger] = ledger
    end

    # Runs the block with `ledger` as the current ledger, and puts the previous one back.
    def self.with(ledger)
      before = Thread.current[:frijolero_ledger]
      self.current = ledger
      yield
    ensure
      self.current = before
    end
  end
end
