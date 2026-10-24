# frozen_string_literal: true

require 'fileutils'
require 'monitor'
require 'sqlite3'

module Frijolero
  # The app's own SQLite file, DATA_DIR/frijolero.sqlite3: users, ledgers, tokens and
  # usage. The ledgers themselves stay in git. Rows come back as hashes with string keys.
  #
  # One connection behind a Monitor, which is reentrant, so a transaction block can call
  # execute. ponytail: one process, as Puma runs today; a connection per thread if it
  # ever runs workers.
  module DB
    MIGRATIONS = Dir[File.expand_path('../db/*.sql', __dir__)].sort_by { |file| File.basename(file).to_i }
    @lock = Monitor.new

    class << self
      def path = File.join(Config.data_dir, 'frijolero.sqlite3')

      def execute(sql, *binds) = @lock.synchronize { connection.execute(sql, binds) }

      def first(sql, *binds) = execute(sql, *binds).first

      # The id of the new row.
      def insert(sql, *binds)
        @lock.synchronize do
          connection.execute(sql, binds)
          connection.last_insert_row_id
        end
      end

      def transaction(&) = @lock.synchronize { connection.transaction(&) }

      private

      # Opened on first use, and again when DATA_DIR changes, which only a test does.
      def connection
        return @db if @db && @db_path == path

        @db&.close
        FileUtils.mkdir_p(File.dirname(path))
        @db = SQLite3::Database.new(path, results_as_hash: true)
        @db_path = path
        @db.busy_timeout = 5000
        @db.execute('PRAGMA journal_mode = WAL')
        @db.execute('PRAGMA foreign_keys = ON')
        migrate(@db)
        @db
      end

      # Each db/<n>_*.sql above PRAGMA user_version, in order, each in its own transaction.
      def migrate(db)
        version = db.get_first_value('PRAGMA user_version')
        MIGRATIONS.each do |file|
          number = File.basename(file).to_i
          next if number <= version

          db.transaction do
            db.execute_batch(File.read(file))
            db.execute("PRAGMA user_version = #{number}")
          end
        end
      end
    end
  end
end
