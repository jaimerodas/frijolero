# frozen_string_literal: true

module Frijolero
  # The files that rledger reads for the current ledger: the main file and every file that
  # it includes, recursively, as real paths. Every ledger of the volume is its owner's data,
  # so this runs before each rledger call: a path that leaves the ledger (symlinks resolved)
  # or a plugin that rledger does not have built in raises Unsafe, and rledger does not run.
  module LedgerFiles
    # `file` is relative to the ledger and `line` counts from 1; the message names both.
    class Unsafe < StandardError
      attr_reader :file, :line, :problem

      def initialize(file, line, problem)
        @file = file
        @line = line
        @problem = problem
        super("#{file}:#{line}: #{problem}")
      end
    end

    # Any blank but a newline: rledger 0.24 takes a tab, a form feed or a CR between the
    # words of a directive, and no newline (measured).
    BLANK = '[^\S\n]'
    # The directives that make rledger read a path or load code. rledger follows them at the
    # start of a line or indented (measured). It lists the files under a `documents` root,
    # and it checks that the file of a `document` exists.
    DIRECTIVES = {
      'include' => /^[ \t]*include#{BLANK}*"([^"\n]*)"/,
      'plugin' => /^[ \t]*plugin#{BLANK}*"([^"\n]*)"/,
      'documents' => /^[ \t]*option#{BLANK}*"documents"#{BLANK}*"([^"\n]*)"/,
      'document' => /^[ \t]*\S+#{BLANK}+document#{BLANK}+\S+#{BLANK}*"([^"\n]*)"/
    }.freeze
    # rledger's test for a glob, which only an include can be.
    GLOB = /[*?\[]/
    # rledger unescapes a `\`, and its glob crate has no braces and reads brackets its own way,
    # so with these Dir.glob could match other files than rledger does.
    ODD_GLOB = /[\[\]{}\\]/
    # The built-in plugins of rledger 0.24 (rustledger-plugin, src/native/mod.rs). rledger
    # finds one by the last dotted segment, so beancount.plugins.auto_accounts is one too.
    # Not document_discovery: its config names the directories that it lists.
    PLUGINS = %w[auto_accounts auto_tag box_accrual check_average_cost check_closing check_commodity check_drained
                 close_tree coherent_cost commodity_attr currency_accounts effective_date forecast gain_loss
                 generate_base_ccy_prices implicit_prices leafonly long_short noduplicates nounused onecommodity
                 pedantic rename_accounts rx_txn_plugin sellgains split_expenses unique_prices unrealized valuation
                 zerosum].freeze
    PLUGIN = /\A(?:\w+\.)*(?:#{PLUGINS.join('|')})\z/
    # The text that rledger may read. It needs about 23 MB of memory for each MB of text,
    # on top of 10 MB (measured with rledger 0.24 on 0.75 and 3 MB ledgers; the user's is
    # 0.74 MB), and Puma and its children share 256 MiB, of which Puma holds about 100.
    MAX_BYTES = 4 * 1024 * 1024

    # [] while the ledger has no main file, which rledger reports, as it reports an
    # include that matches nothing.
    # ponytail: no cache. On the real ledger (150 files, 737 KB) a walk is 8 to 9 ms, 3.4 of
    # them to read the files, against 1.1 ms for the stamp of App.ledger_errors. That stamp
    # sees only `.beancount` files, so a changed `include "x.txt"` would pass on an old
    # answer. Cache by the walked files and the globbed directories if the pages get slow.
    def self.all
      return [] unless File.file?(Config.main_file)

      Walk.new(File.realpath(Config.ledger_dir), File.realpath(Config.main_file)).files
    end

    # One pass over the include tree of a ledger whose real path is `root`.
    class Walk
      def initialize(root, main)
        @root = root
        @main = main
      end

      def files
        refuse('el archivo principal está fuera del ledger') unless inside?(@main)

        files = [@main]
        bytes = 0
        # `each` also visits what the block appends, so the walk needs no recursion. The size
        # counts before the read, so a huge file is never read either.
        files.each do |file|
          bytes += File.size?(file).to_i
          refuse('el ledger pasa de 4 MB de texto, más de lo que rledger puede leer aquí') if bytes > MAX_BYTES

          files.concat(included(file).uniq - files)
        end
        files
      end

      private

      # A problem of the whole ledger, shown at the top of its main file.
      def refuse(problem) = raise(Unsafe.new(Ledger.current.main_file, 1, problem))

      # The files that `file` includes, after a check of each of its directives.
      def included(file)
        directives(file).flat_map do |kind, value, where|
          case kind
          when 'plugin' then plugin!(value, where)
          when 'include'
            reach(value, File.dirname(file), where, glob: value.match?(GLOB)).select { |path| File.file?(path) }
          else
            # rledger reads a relative `documents` root from the main file, a document from its own file.
            reach(value, File.dirname(kind == 'documents' ? @main : file), where, glob: false)
            []
          end
        end
      end

      # [kind, value, [file, line]] for each directive of `file` that DIRECTIVES names. A file
      # that a pull took away in the meantime has none: rledger reports it.
      def directives(file)
        text = File.read(file, encoding: 'bom|utf-8').scrub
        name = file.delete_prefix("#{@root}/")
        DIRECTIVES.flat_map do |kind, pattern|
          text.to_enum(:scan, pattern).map do
            match = Regexp.last_match
            [kind, match[1], [name, text[0, match.begin(0)].count("\n") + 1]]
          end
        end
      rescue SystemCallError
        []
      end

      def plugin!(name, where)
        raise Unsafe.new(*where, %(plugin "#{name}" no es un plugin de rledger)) unless name.match?(PLUGIN)

        []
      end

      # The real paths that `path` names from `dir`, a glob or not, each one inside the ledger.
      # A path that names nothing is left to rledger. Both the glob and realpath resolve `..`
      # on the disk, as rledger does; the first check is on the text alone, so a path that
      # leaves the ledger is never listed. The message names the path as written, never what
      # it reached.
      def reach(path, dir, where, glob:)
        odd!(path, where, glob)
        outside = Unsafe.new(*where, %("#{path}" está fuera del ledger))
        raise outside unless inside?(File.absolute_path(path, dir))

        found = glob ? Dir.glob(path, File::FNM_DOTMATCH, base: dir) : [path]
        found.filter_map { |match| real(match, dir) }.each { |real| raise outside unless inside?(real) }
      end

      def odd!(path, where, glob)
        return unless path.match?(glob ? ODD_GLOB : /\\/)

        raise Unsafe.new(*where, %("#{path}" usa [ ] { } o \\, que Frijolero no revisa))
      end

      def real(path, dir)
        File.realpath(path, dir)
      rescue SystemCallError
        nil
      end

      def inside?(path) = path == @root || path.start_with?("#{@root}/")
    end
  end
end
