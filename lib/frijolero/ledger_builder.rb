# frozen_string_literal: true

require 'yaml'
require 'fileutils'

module Frijolero
  # One-time build of the ledger git repo from the legacy ~/Documents/Beancount
  # layout. Idempotent: running it again rewrites the same target files. The
  # source directory is never modified.
  class LedgerBuilder
    Report = Struct.new(:copied, :warnings, keyword_init: true)

    STATEMENT_FILE_RE = /\A(.+)_(\d{4})\.(beancount|json)\z/
    INCLUDE_LINE_RE = /\Ainclude "([^"]+)"\s*\z/
    INCLUDE_TARGET_RE = %r{\A(.+?)/(.+)_(\d{4})\.beancount\z}
    ROOT_SKIP_RE = /\.(bak.*|backup|cache)\z/

    def initialize(source:, target:, frijolero_dir:,
                   templates_dir: File.expand_path('templates/prompts', __dir__),
                   main_file: 'transactions.beancount')
      @source = source
      @target = target
      @frijolero_dir = frijolero_dir
      @templates_dir = templates_dir
      @main_file = main_file
      @copied = 0
      @warnings = []
    end

    def run
      build_key_lookup
      copy_root_files
      copy_statement_dirs
      rewrite_main_file
      copy_config
      Report.new(copied: @copied, warnings: @warnings)
    end

    private

    def build_key_lookup
      accounts_path = File.join(@frijolero_dir, 'accounts.yaml')
      @keys = File.exist?(accounts_path) ? YAML.load_file(accounts_path).keys : []
      @normalized_keys = @keys.to_h { |key| [normalize(key), key] }
    end

    def normalize(name)
      name.tr('_', ' ').downcase
    end

    def resolve(name)
      @normalized_keys[normalize(name)]
    end

    def copy_root_files
      Dir.children(@source).sort.each do |name|
        path = File.join(@source, name)
        next unless File.file?(path)
        next if name.start_with?('.')
        next if name.match?(ROOT_SKIP_RE)

        FileUtils.mkdir_p(@target)
        FileUtils.cp(path, File.join(@target, name))
        @copied += 1
      end
    end

    def copy_statement_dirs
      copied, warnings = StatementCopier.new(source: @source, target: @target, resolve: method(:resolve)).run
      @copied += copied
      @warnings.concat(warnings)
    end

    def rewrite_main_file
      main_path = File.join(@target, @main_file)
      return unless File.exist?(main_path)

      lines = File.readlines(main_path, encoding: 'UTF-8')
      rewritten = lines.map { |line| rewrite_include_line(line) }
      File.write(main_path, rewritten.join, encoding: 'UTF-8')
    end

    def rewrite_include_line(line)
      match = line.match(INCLUDE_LINE_RE)
      return line unless match

      target_match = match[1].match(INCLUDE_TARGET_RE)
      return warn_unresolved_include(line, match[1]) unless target_match

      _dir, prefix, period = target_match.captures
      key = resolve(prefix)
      return warn_unresolved_include(line, match[1]) unless key

      %(include "accounts/#{key}/#{key} #{period}.beancount"\n)
    end

    def warn_unresolved_include(line, target)
      @warnings << "could not resolve include target: #{target}"
      line
    end

    def copy_config
      copied, warnings = ConfigCopier.new(
        frijolero_dir: @frijolero_dir, target: @target, templates_dir: @templates_dir, keys: @keys
      ).run
      @copied += copied
      @warnings.concat(warnings)
    end

    # Copies each source subdir that resolves to an account key into
    # target/accounts/<Key>/, normalizing the Account_YYMM.ext naming to
    # "Account YYMM.ext" along the way. Warns about (and skips) a subdir
    # that resolves to no key but holds .beancount files, and about any
    # statement file whose name or prefix does not match.
    class StatementCopier
      def initialize(source:, target:, resolve:)
        @source = source
        @target = target
        @resolve = resolve
        @copied = 0
        @warnings = []
      end

      def run
        Dir.children(@source).sort.each do |name|
          path = File.join(@source, name)
          next unless File.directory?(path)

          key = @resolve.call(name)
          if key
            copy_statement_dir(path, key)
          elsif Dir.glob('**/*.beancount', base: path).any?
            @warnings << "subdirectory resolves to no account key: #{name}"
          end
        end
        [@copied, @warnings]
      end

      private

      def copy_statement_dir(dir, key)
        copy_statement_files(Dir.glob('*.beancount', base: dir).sort, dir, key)
        json_dir = File.join(dir, 'json')
        return unless File.directory?(json_dir)

        copy_statement_files(Dir.glob('*.json', base: json_dir).sort, json_dir, key)
      end

      def copy_statement_files(filenames, dir, key)
        filenames.each { |filename| copy_statement_file(filename, dir, key) }
      end

      def copy_statement_file(filename, dir, key)
        match = filename.match(STATEMENT_FILE_RE)
        unless match && @resolve.call(match[1]) == key
          @warnings << "unrecognized statement file: #{File.join(dir, filename)}"
          return
        end

        write_statement_file(dir, filename, key, match[2], match[3])
      end

      def write_statement_file(dir, filename, key, period, ext)
        target_dir = File.join(@target, 'accounts', key)
        FileUtils.mkdir_p(target_dir)
        FileUtils.cp(File.join(dir, filename), File.join(target_dir, "#{key} #{period}.#{ext}"))
        @copied += 1
      end
    end

    # Rebuilds LEDGER_DIR/config from the legacy ~/.frijolero directory:
    # accounts.yaml, detailers/ -> rules/, prompts/ (with a `classify` default
    # from templates_dir when the legacy dir has none), and the .gitignore.
    class ConfigCopier
      GITIGNORE = <<~GITIGNORE
        *.bak*
        *.backup
        *.cache
        .DS_Store
        .nova/
      GITIGNORE

      def initialize(frijolero_dir:, target:, templates_dir:, keys:)
        @frijolero_dir = frijolero_dir
        @target = target
        @templates_dir = templates_dir
        @keys = keys
        @copied = 0
        @warnings = []
      end

      def run
        config_dir = File.join(@target, 'config')
        FileUtils.mkdir_p(config_dir)
        copy_accounts_yaml(config_dir)
        copy_rules(config_dir)
        copy_prompts(config_dir)
        write_gitignore
        [@copied, @warnings]
      end

      private

      def copy_accounts_yaml(config_dir)
        source_path = File.join(@frijolero_dir, 'accounts.yaml')
        return unless File.exist?(source_path)

        FileUtils.cp(source_path, File.join(config_dir, 'accounts.yaml'))
        @copied += 1
      end

      def copy_rules(config_dir)
        rules_dir = File.join(config_dir, 'rules')
        FileUtils.mkdir_p(rules_dir)
        detailers_dir = File.join(@frijolero_dir, 'detailers')
        return unless File.directory?(detailers_dir)

        Dir.glob('*.yaml', base: detailers_dir).sort.each do |filename|
          copy_rule_file(filename, detailers_dir, rules_dir)
        end
      end

      def copy_rule_file(filename, detailers_dir, rules_dir)
        basename = File.basename(filename, '.yaml')
        key = @keys.find { |k| k.downcase.gsub(' ', '_') == basename }
        unless key
          @warnings << "detailer file matches no account key: #{filename}"
          return
        end

        FileUtils.cp(File.join(detailers_dir, filename), File.join(rules_dir, "#{key}.yaml"))
        @copied += 1
      end

      def copy_prompts(config_dir)
        prompts_target = File.join(config_dir, 'prompts')
        FileUtils.mkdir_p(prompts_target)
        prompts_source = File.join(@frijolero_dir, 'prompts')
        copied_classify = copy_prompt_folders(prompts_source, prompts_target)
        copy_default_classify(prompts_target) unless copied_classify
      end

      def copy_prompt_folders(prompts_source, prompts_target)
        return false unless File.directory?(prompts_source)

        copied_classify = false
        Dir.children(prompts_source).sort.each do |name|
          folder = File.join(prompts_source, name)
          next unless File.directory?(folder)

          copy_folder(folder, File.join(prompts_target, name))
          copied_classify ||= (name == 'classify')
        end
        copied_classify
      end

      def copy_default_classify(prompts_target)
        classify_source = File.join(@templates_dir, 'classify')
        return unless File.directory?(classify_source)

        copy_folder(classify_source, File.join(prompts_target, 'classify'))
      end

      def copy_folder(source_folder, target_folder)
        FileUtils.rm_rf(target_folder)
        FileUtils.cp_r(source_folder, target_folder)
        @copied += count_files(source_folder)
      end

      def count_files(dir)
        Dir.glob('**/*', base: dir).count { |f| File.file?(File.join(dir, f)) }
      end

      def write_gitignore
        File.write(File.join(@target, '.gitignore'), GITIGNORE)
      end
    end
  end
end
