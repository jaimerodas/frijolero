# frozen_string_literal: true

require 'fileutils'

module Frijolero
  # bin/new-ledger, for the app too: a new ledger from templates/ledger, or the missing
  # files in a ledger that exists. It never overwrites a file. The prompts belong to
  # the app (prompts/), not to the ledger.
  module NewLedger
    TEMPLATE = File.expand_path('../templates/ledger', __dir__)
    TITLE = /^[ \t]*option[ \t]+"title"[ \t].*\n?/

    class << self
      # Adds main.beancount only when `dir` has no *.beancount: an existing ledger keeps
      # its own main file, whatever its name. With `title`, the main file gets it as its
      # `option "title"`. Then git init if needed, and one commit of the paths of the
      # template and the main file, never the rest of the directory.
      # Yields the commit message when it commits. Returns the name of the main file.
      def prepare(dir, title: nil, &)
        message = File.directory?(dir) ? 'Configuración de Frijolero' : 'Ledger nuevo'
        FileUtils.mkdir_p(dir)
        main = Dir.glob('*.beancount', base: dir).first || 'main.beancount'
        template_files(main).each { |file| copy(file, dir) }
        write_title(File.join(dir, main), title) if title
        commit(dir, main, message, &)
        main
      end

      # The name of the ledger as `option "title"`, for Fava and the other tools. The app
      # writes it and never reads it: the name is the ledger's row. The line goes where the
      # first title line was, or at the top, and the other title lines go, because Beancount
      # keeps the last one.
      def write_title(path, name)
        text = File.exist?(path) ? File.read(path) : ''
        line = %(option "title" "#{name.gsub(/["\\]/) { |char| "\\#{char}" }}"\n)
        updated = text.gsub(TITLE, '').insert(text.index(TITLE) || 0, line)
        File.write(path, updated) unless updated == text
      end

      private

      def template_files(main)
        files = Dir.glob('**/*', File::FNM_DOTMATCH, base: TEMPLATE).select { |f| File.file?(File.join(TEMPLATE, f)) }
        main == 'main.beancount' ? files : files - ['main.beancount']
      end

      def copy(file, dir)
        target = File.join(dir, file)
        return if File.exist?(target)

        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(File.join(TEMPLATE, file), target)
      end

      def commit(dir, main, message)
        repo = LedgerRepo.new(dir: dir)
        repo.git('init', '-q', '-b', 'main') unless File.directory?(File.join(dir, '.git'))
        repo.git('add', '--', *(Dir.children(TEMPLATE) - ['main.beancount']), main)
        return if repo.git('diff', '--cached', '--name-only').empty?

        repo.git('commit', '-q', '-m', message)
        yield message if block_given?
      end
    end
  end
end
