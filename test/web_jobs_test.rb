# frozen_string_literal: true

require 'test_helper'
require 'frijolero/web/jobs'

class WebJobsTest < Minitest::Test
  include TestHelpers

  def setup
    Frijolero::UI.sink = StringIO.new
  end

  def teardown
    Frijolero::UI.sink = $stdout
    Frijolero::UI.auto_accept = false
  end

  def log_path
    File.join(Dir.mktmpdir, 'jobs.jsonl')
  end

  def noop
    proc {}
  end

  def test_push_returns_queued_job_findable_by_id
    jobs = Frijolero::Web::Jobs.new(log_path: log_path)

    job = jobs.push(label: 'AMEX 2508', &noop)

    assert job.id
    assert_equal 'queued', job.status
    assert_equal 'AMEX 2508', job.label
    assert_equal job, jobs.find(job.id)
  end

  def test_work_one_runs_body_and_ends_ok
    jobs = Frijolero::Web::Jobs.new(log_path: log_path)
    jobs.push(label: 'AMEX 2508', &noop)

    job = jobs.work_one

    assert_equal 'ok', job.status
    assert job.started_at
    assert job.finished_at
  end

  def test_work_one_captures_ui_output_and_auto_accept
    jobs = Frijolero::Web::Jobs.new(log_path: log_path)
    jobs.push(label: 'AMEX 2508') { Frijolero::UI.puts 'hola' }

    job = jobs.work_one

    assert_includes job.output, 'hola'
    refute Frijolero::UI.auto_accept?
  end

  def test_work_one_marks_failed_body_without_raising
    jobs = Frijolero::Web::Jobs.new(log_path: log_path)
    jobs.push(label: 'AMEX 2508') { raise 'boom' }

    job = jobs.work_one

    assert_equal 'failed', job.status
    assert_equal 'RuntimeError: boom', job.error
  end

  def test_log_has_one_line_per_state_change_with_final_output
    path = log_path
    jobs = Frijolero::Web::Jobs.new(log_path: path)
    jobs.push(label: 'AMEX 2508') { Frijolero::UI.puts 'hola' }
    jobs.work_one

    lines = File.readlines(path).map { |l| JSON.parse(l) }

    statuses = lines.map { |l| l['status'] }
    assert_equal %w[queued running ok], statuses
    assert_includes lines.last['output'], 'hola'
  end

  def test_boot_recovery_marks_running_jobs_failed
    path = log_path
    File.write(path, "#{JSON.generate({ id: 'abc123', label: 'AMEX 2508', status: 'running' })}\n")

    jobs = Frijolero::Web::Jobs.new(log_path: path)

    job = jobs.find('abc123')
    assert_equal 'failed', job.status
    assert_equal 'interrumpido por un reinicio', job.error
    assert_equal 'AMEX 2508', job.label
    lines = File.readlines(path).map { |l| JSON.parse(l) }
    assert_equal 'failed', lines.last['status']
  end

  def test_all_returns_newest_first
    jobs = Frijolero::Web::Jobs.new(log_path: log_path)
    first = jobs.push(label: 'first', &noop)
    second = jobs.push(label: 'second', &noop)

    assert_equal [second, first], jobs.all
  end

  def test_start_processes_pushed_job_in_background
    jobs = Frijolero::Web::Jobs.new(log_path: log_path)
    job = jobs.push(label: 'AMEX 2508', &noop)
    thread = jobs.start

    20.times do
      break if job.done?

      sleep 0.05
    end

    assert_equal 'ok', job.status
  ensure
    thread&.kill
  end
end
