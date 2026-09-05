# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'

class PdfUploaderTest < Minitest::Test
  class FakeB2
    attr_reader :puts_calls

    def initialize(should_raise_for_key = nil)
      @should_raise_for_key = should_raise_for_key
      @puts_calls = []
    end

    def put(key, path, content_type: 'application/pdf')
      raise Frijolero::B2::Error.new('boom', status: 500) if @should_raise_for_key && key == @should_raise_for_key

      # Record the call
      @puts_calls << { key: key, path: path, content_type: content_type }
    end
  end

  def setup
    @source = Dir.mktmpdir
    @accounts_file = File.join(@source, 'accounts.yaml')
    write_accounts_yaml
    @out = StringIO.new
    @b2 = FakeB2.new
  end

  def teardown
    FileUtils.remove_entry(@source)
  end

  def write_accounts_yaml
    File.write(@accounts_file, <<~YAML)
      AMEX:
        beancount_account: "Liabilities:Amex"
        openai_prompt_type: default
      AMEX Aeromexico:
        beancount_account: "Liabilities:AmexAeromexico"
        openai_prompt_type: default
      BBVA:
        beancount_account: "Assets:BBVA"
        openai_prompt_type: default
    YAML
  end

  def test_plan_maps_files_to_b2_keys
    create_pdf('AMEX/pdf/AMEX_2508.pdf')
    create_pdf('AMEX_Aeromexico/pdf/Amex_Aeromexico_2412.pdf')

    uploader = Frijolero::PdfUploader.new(
      source: @source,
      accounts_file: @accounts_file,
      b2_client: @b2
    )

    plan = uploader.plan
    assert_equal 2, plan.size
    assert_equal(
      [
        ['AMEX/pdf/AMEX_2508.pdf', 'accounts/AMEX/AMEX 2508.pdf'],
        ['AMEX_Aeromexico/pdf/Amex_Aeromexico_2412.pdf', 'accounts/AMEX Aeromexico/AMEX Aeromexico 2412.pdf']
      ],
      plan
    )
  end

  def test_plan_skips_files_with_mismatched_prefix_and_dir
    # Directory is AMEX but prefix is BBVA - should not be in plan
    create_pdf('AMEX/pdf/BBVA_2508.pdf')

    uploader = Frijolero::PdfUploader.new(
      source: @source,
      accounts_file: @accounts_file,
      b2_client: @b2
    )

    plan = uploader.plan
    assert_empty plan
  end

  def test_plan_skips_files_with_unresolvable_dir
    # Directory "Mystery" doesn't resolve to any account key
    create_pdf('Mystery/pdf/Mystery_2601.pdf')

    uploader = Frijolero::PdfUploader.new(
      source: @source,
      accounts_file: @accounts_file,
      b2_client: @b2
    )

    plan = uploader.plan
    assert_empty plan
  end

  def test_plan_skips_files_with_unresolvable_prefix
    # Prefix "Unknown" doesn't resolve to any account key
    create_pdf('AMEX/pdf/Unknown_2508.pdf')

    uploader = Frijolero::PdfUploader.new(
      source: @source,
      accounts_file: @accounts_file,
      b2_client: @b2
    )

    plan = uploader.plan
    assert_empty plan
  end

  def test_plan_skips_files_without_yymm_suffix
    # File without YYMM pattern
    create_pdf('AMEX/pdf/scan.pdf')

    uploader = Frijolero::PdfUploader.new(
      source: @source,
      accounts_file: @accounts_file,
      b2_client: @b2
    )

    plan = uploader.plan
    assert_empty plan
  end

  def test_run_uploads_planned_files_and_returns_result
    create_pdf('AMEX/pdf/AMEX_2508.pdf')
    create_pdf('BBVA/pdf/BBVA_2601.pdf')

    uploader = Frijolero::PdfUploader.new(
      source: @source,
      accounts_file: @accounts_file,
      b2_client: @b2,
      out: @out
    )

    result = uploader.run

    assert_equal 2, result.uploaded.size
    assert_includes result.uploaded, 'accounts/AMEX/AMEX 2508.pdf'
    assert_includes result.uploaded, 'accounts/BBVA/BBVA 2601.pdf'
    assert_empty result.skipped

    # Check B2 put calls
    assert_equal 2, @b2.puts_calls.size
  end

  def test_run_prints_ok_for_each_upload
    create_pdf('AMEX/pdf/AMEX_2508.pdf')
    create_pdf('BBVA/pdf/BBVA_2601.pdf')

    uploader = Frijolero::PdfUploader.new(
      source: @source,
      accounts_file: @accounts_file,
      b2_client: @b2,
      out: @out
    )

    uploader.run

    output = @out.string
    assert_includes output, 'ok  accounts/AMEX/AMEX 2508.pdf'
    assert_includes output, 'ok  accounts/BBVA/BBVA 2601.pdf'
  end

  def test_run_catches_b2_error_and_continues
    create_pdf('AMEX/pdf/AMEX_2508.pdf')
    create_pdf('BBVA/pdf/BBVA_2601.pdf')

    # Make B2 raise for AMEX key
    @b2 = FakeB2.new('accounts/AMEX/AMEX 2508.pdf')

    uploader = Frijolero::PdfUploader.new(
      source: @source,
      accounts_file: @accounts_file,
      b2_client: @b2,
      out: @out
    )

    result = uploader.run

    # BBVA should be uploaded
    assert_includes result.uploaded, 'accounts/BBVA/BBVA 2601.pdf'
    assert_equal 1, result.uploaded.size

    # AMEX should be in skipped
    assert_equal 1, result.skipped.size
    assert_includes result.skipped[0], 'AMEX/pdf/AMEX_2508.pdf'
    assert_includes result.skipped[0], 'boom'

    # But BBVA should have been printed
    assert_includes @out.string, 'ok  accounts/BBVA/BBVA 2601.pdf'
  end

  def test_run_skips_unresolvable_files_without_uploading
    create_pdf('AMEX/pdf/AMEX_2508.pdf')
    create_pdf('Mystery/pdf/Mystery_2601.pdf')

    uploader = Frijolero::PdfUploader.new(
      source: @source,
      accounts_file: @accounts_file,
      b2_client: @b2,
      out: @out
    )

    result = uploader.run

    # Only AMEX should be uploaded
    assert_includes result.uploaded, 'accounts/AMEX/AMEX 2508.pdf'
    assert_equal 1, result.uploaded.size

    # Mystery should be absent (not in skipped, because it's not in plan)
    assert_empty result.skipped

    # Only one B2 put call
    assert_equal 1, @b2.puts_calls.size
  end

  def test_plan_returns_sorted_entries
    create_pdf('BBVA/pdf/BBVA_2601.pdf')
    create_pdf('AMEX/pdf/AMEX_2508.pdf')
    create_pdf('AMEX_Aeromexico/pdf/Amex_Aeromexico_2412.pdf')

    uploader = Frijolero::PdfUploader.new(
      source: @source,
      accounts_file: @accounts_file,
      b2_client: @b2
    )

    plan = uploader.plan

    # Paths should be sorted
    assert_equal(
      [
        ['AMEX/pdf/AMEX_2508.pdf', 'accounts/AMEX/AMEX 2508.pdf'],
        ['AMEX_Aeromexico/pdf/Amex_Aeromexico_2412.pdf', 'accounts/AMEX Aeromexico/AMEX Aeromexico 2412.pdf'],
        ['BBVA/pdf/BBVA_2601.pdf', 'accounts/BBVA/BBVA 2601.pdf']
      ],
      plan
    )
  end

  def test_script_dry_run_prints_plan_and_exits_zero
    create_pdf('AMEX/pdf/AMEX_2508.pdf')
    create_pdf('BBVA/pdf/BBVA_2601.pdf')

    script_path = File.expand_path("#{__dir__}/../script/upload_pdfs_to_b2")
    output, status = Open3.capture2e(
      'ruby', script_path, '--dry-run', @source, @accounts_file
    )

    assert_equal 0, status.exitstatus
    assert_includes output, 'AMEX/pdf/AMEX_2508.pdf → accounts/AMEX/AMEX 2508.pdf'
    assert_includes output, 'BBVA/pdf/BBVA_2601.pdf → accounts/BBVA/BBVA 2601.pdf'
  end

  private

  def create_pdf(path)
    dir = File.dirname(File.join(@source, path))
    FileUtils.mkdir_p(dir)
    File.write(File.join(@source, path), 'not a real pdf')
  end
end
