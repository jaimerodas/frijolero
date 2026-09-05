# frozen_string_literal: true

require_relative 'test_helper'

class LedgerBuilderTest < Minitest::Test
  include TestHelpers

  TEMPLATES_DIR = File.expand_path('../lib/frijolero/templates/prompts', __dir__)

  def setup
    @source = Dir.mktmpdir
    @frijolero_dir = Dir.mktmpdir
    @target = File.join(Dir.mktmpdir, 'ledger')
    build_synthetic_source
    build_synthetic_frijolero_dir
  end

  def teardown
    FileUtils.remove_entry(@source)
    FileUtils.remove_entry(@frijolero_dir)
    FileUtils.remove_entry(File.dirname(@target))
  end

  def test_statement_files_land_under_accounts_with_fixed_case_and_no_pdfs
    run_builder

    assert File.exist?(File.join(@target, 'accounts', 'AMEX Aeromexico', 'AMEX Aeromexico 2412.beancount'))
    assert File.exist?(File.join(@target, 'accounts', 'AMEX', 'AMEX 2512.json'))
    refute Dir.glob('**/*.pdf', base: @target).any?
  end

  def test_main_file_include_lines_are_rewritten_and_inline_transactions_kept
    report = run_builder
    content = File.read(File.join(@target, 'transactions.beancount'))
    lines = content.lines

    assert_includes lines, %(include "accounts/AMEX Aeromexico/AMEX Aeromexico 2412.beancount"\n)
    assert_includes lines, %(include "accounts/AMEX/AMEX 2512.beancount"\n)
    assert_includes lines, %(include "accounts/BBVA TDC/BBVA TDC 2601.beancount"\n)
    assert_includes lines, %(2024-01-01 * "Opening" "Balance"\n)
    assert_includes lines, %(2024-01-02 * "Coffee" "Narration"\n)
    assert_includes lines, %(include "Mystery/Mystery_2601.beancount"\n)
    assert(report.warnings.any? { |w| w.include?('Mystery') })
  end

  def test_root_files_copied_without_backups_cache_or_pending_statements
    run_builder

    assert File.exist?(File.join(@target, 'moneys.beancount'))
    assert File.exist?(File.join(@target, 'balances.beancount'))
    refute Dir.glob('**/*.bak*', base: @target).any?
    refute Dir.glob('**/*.cache', base: @target).any?
    refute Dir.glob('**/.DS_Store', base: @target, flags: File::FNM_DOTMATCH).any?
    refute File.exist?(File.join(@target, 'Pending Statements'))
  end

  def test_config_accounts_and_rules_are_copied_and_orphans_warned
    report = run_builder

    assert_equal(
      File.read(File.join(@frijolero_dir, 'accounts.yaml')),
      File.read(File.join(@target, 'config', 'accounts.yaml'))
    )
    assert File.exist?(File.join(@target, 'config', 'rules', 'AMEX Aeromexico.yaml'))
    assert File.exist?(File.join(@target, 'config', 'rules', 'AMEX.yaml'))
    assert File.exist?(File.join(@target, 'config', 'rules', 'BBVA TDC.yaml'))
    refute File.exist?(File.join(@target, 'config', 'rules', 'orphan.yaml'))
    assert(report.warnings.any? { |w| w.include?('orphan.yaml') })
    refute File.exist?(File.join(@target, 'config', 'config.yaml'))
  end

  def test_prompts_are_copied_and_classify_defaults_from_templates
    run_builder

    assert File.exist?(File.join(@target, 'config', 'prompts', 'bbva', 'spec.json'))
    assert File.exist?(File.join(@target, 'config', 'prompts', 'classify', 'schema.json'))
  end

  def test_legacy_classify_prompt_wins_over_template_default
    FileUtils.mkdir_p(File.join(@frijolero_dir, 'prompts', 'classify'))
    File.write(File.join(@frijolero_dir, 'prompts', 'classify', 'spec.json'), '{"marker":true}')

    run_builder

    content = File.read(File.join(@target, 'config', 'prompts', 'classify', 'spec.json'))
    assert_equal '{"marker":true}', content
  end

  def test_gitignore_content
    run_builder

    assert_equal(
      "*.bak*\n*.backup\n*.cache\n.DS_Store\n.nova/\n",
      File.read(File.join(@target, '.gitignore'))
    )
  end

  def test_running_twice_is_idempotent
    run_builder
    paths_first = target_paths
    main_first = File.read(File.join(@target, 'transactions.beancount'))

    run_builder
    paths_second = target_paths
    main_second = File.read(File.join(@target, 'transactions.beancount'))

    assert_equal paths_first, paths_second
    assert_equal main_first, main_second
  end

  def test_source_directory_is_never_modified
    before = snapshot(@source)
    run_builder
    assert_equal before, snapshot(@source)
  end

  def test_report_counts_copied_files_and_lists_warnings
    report = run_builder

    assert_operator report.copied, :>, 0
    assert_kind_of Array, report.warnings
  end

  private

  def run_builder
    Frijolero::LedgerBuilder.new(
      source: @source,
      target: @target,
      frijolero_dir: @frijolero_dir,
      templates_dir: TEMPLATES_DIR
    ).run
  end

  def target_paths
    Dir.glob('**/*', base: @target, flags: File::FNM_DOTMATCH).sort
  end

  def snapshot(dir)
    Dir.glob('**/*', base: dir, flags: File::FNM_DOTMATCH).sort.to_h do |path|
      full = File.join(dir, path)
      [path, File.file?(full) ? File.binread(full) : :dir]
    end
  end

  def build_synthetic_source
    File.write(File.join(@source, 'accounts.yaml'), accounts_yaml)

    write_dir(File.join(@source, 'AMEX'), {
                'AMEX_2512.beancount' => "2024-01-05 * \"AMEX\" \"\"\n",
                'json/AMEX_2512.json' => '{"transactions":[]}',
                'pdf/AMEX_2512.pdf' => 'not a real pdf'
              })
    write_dir(File.join(@source, 'AMEX_Aeromexico'), {
                'AMEX_Aeromexico_2412.beancount' => "2024-01-06 * \"Aero\" \"\"\n"
              })
    write_dir(File.join(@source, 'BBVA_TDC'), {
                'BBVA_TDC_2601.beancount' => "2024-01-07 * \"BBVA\" \"\"\n",
                'notes.txt' => 'stray file'
              })
    write_dir(File.join(@source, 'Mystery'), {
                'Mystery_2601.beancount' => "2024-01-08 * \"Mystery\" \"\"\n"
              })
    write_dir(File.join(@source, 'Pending Statements'), { 'x.pdf' => 'pending' })

    File.write(File.join(@source, 'transactions.beancount'), <<~BEAN)
      2024-01-01 * "Opening" "Balance"
      2024-01-02 * "Coffee" "Narration"
      include "Amex_Aeromexico/Amex_Aeromexico_2412.beancount"
      include "AMEX/AMEX_2512.beancount"
      include "BBVA_TDC/BBVA_TDC_2601.beancount"
      include "Mystery/Mystery_2601.beancount"
    BEAN

    File.write(File.join(@source, 'moneys.beancount'), "; moneys\n")
    File.write(File.join(@source, 'balances.beancount'), "; balances\n")
    File.write(File.join(@source, 'transactions.beancount.bak'), 'backup')
    File.write(File.join(@source, 'transactions.beancount.bak.20260803_181058'), 'backup')
    File.write(File.join(@source, 'moneys.beancount.cache'), 'cache')
    File.write(File.join(@source, '.DS_Store'), 'ds')
  end

  def accounts_yaml
    <<~YAML
      AMEX:
        beancount_account: "Liabilities:Amex"
        openai_prompt_type: default
      AMEX Aeromexico:
        beancount_account: "Liabilities:AmexAeromexico"
        openai_prompt_type: default
      BBVA TDC:
        beancount_account: "Liabilities:BBVA"
        openai_prompt_type: default
    YAML
  end

  def build_synthetic_frijolero_dir
    File.write(File.join(@frijolero_dir, 'accounts.yaml'), accounts_yaml)
    File.write(File.join(@frijolero_dir, 'config.yaml'), "openai_api_key: sk-fake\n")

    detailers_dir = File.join(@frijolero_dir, 'detailers')
    write_dir(detailers_dir, {
                'amex.yaml' => "start_with: {}\n",
                'amex_aeromexico.yaml' => "start_with: {}\n",
                'bbva_tdc.yaml' => "start_with: {}\n",
                'orphan.yaml' => "start_with: {}\n"
              })

    write_dir(File.join(@frijolero_dir, 'prompts', 'default'), {
                'spec.json' => '{}', 'instructions.txt' => 'do it', 'schema.json' => '{}'
              })
    write_dir(File.join(@frijolero_dir, 'prompts', 'bbva'), {
                'spec.json' => '{}', 'instructions.txt' => 'do it', 'schema.json' => '{}'
              })
  end

  def write_dir(dir, files)
    files.each do |relative, content|
      path = File.join(dir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end
end
