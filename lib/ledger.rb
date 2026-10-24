# frozen_string_literal: true

module Frijolero
  # There is no current ledger on this thread. A request outside a ledger, or a thread
  # that forgot Ledger.with, gets this instead of another ledger's data.
  class NoLedger < StandardError; end

  # One ledger: `repo_dir` is its git clone, `dir` holds the rest (the job log, the
  # uploads, the PDFs without a bucket). The rows are in DB; `from_row` puts both
  # directories under DATA_DIR, and a test can point them anywhere.
  Ledger = Data.define(:id, :owner_id, :main_file, :pdf_prefix, :dir, :repo_dir) do
    def self.all = DB.execute('SELECT * FROM ledgers ORDER BY created_at, id').map { |row| from_row(row) }

    def self.find(id)
      row = DB.first('SELECT * FROM ledgers WHERE id = ?', id)
      row && from_row(row)
    end

    def self.from_row(row)
      dir = File.join(Config.data_dir, 'ledgers', row['id'])
      new(id: row['id'], owner_id: row['owner_id'], main_file: row['main_file'], pdf_prefix: row['pdf_prefix'],
          dir: dir, repo_dir: File.join(dir, 'repo'))
    end

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
