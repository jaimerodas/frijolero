# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'stringio'
require 'time'

module Frijolero
  # One queue, one worker thread, an append-only JSONL log. Nothing else.
  class Jobs
    Job = Struct.new(:id, :label, :status, :started_at, :finished_at, :error, :output, keyword_init: true) do
      def running? = status == 'running'
      def done? = %w[ok failed].include?(status)
    end

    INTERRUPTED_ERROR = 'interrumpido por un reinicio'

    def initialize(log_path:)
      @log_path = log_path
      @mutex = Mutex.new
      @queue = Queue.new
      @jobs = {}
      load_log
      recover_running_jobs
    end

    def push(label:, &body)
      job = Job.new(id: SecureRandom.hex(8), label: label, status: 'queued')
      @mutex.synchronize { @jobs[job.id] = job }
      log(job)
      @queue.push([job, body])
      job
    end

    def find(id)
      @mutex.synchronize { @jobs[id] }
    end

    def all
      @mutex.synchronize { @jobs.values.reverse }
    end

    def work_one
      job, body = @queue.pop
      run(job, body)
      job
    end

    def start
      @start ||= Thread.new { loop { work_one } }
    end

    private

    def run(job, body)
      job.status = 'running'
      job.started_at = Time.now.utc.iso8601
      log(job)
      job.output = +''
      run_body(job, body)
    ensure
      job.finished_at = Time.now.utc.iso8601
      log(job)
    end

    def run_body(job, body)
      with_ui_capture(job) { body.call(job) }
      job.status = 'ok'
    rescue StandardError => e
      job.status = 'failed'
      job.error = "#{e.class}: #{e.message}"
    end

    def with_ui_capture(job)
      old_sink = UI.sink
      old_auto_accept = UI.auto_accept
      UI.sink = StringIO.new(job.output)
      UI.auto_accept = true
      yield
    ensure
      UI.sink = old_sink
      UI.auto_accept = old_auto_accept
    end

    def log(job)
      @mutex.synchronize do
        FileUtils.mkdir_p(File.dirname(@log_path))
        File.open(@log_path, 'a') { |f| f.puts(JSON.generate(job.to_h.compact)) }
      end
    end

    def load_log
      return unless File.exist?(@log_path)

      File.foreach(@log_path) do |line|
        attrs = JSON.parse(line, symbolize_names: true)
        @jobs[attrs[:id]] = Job.new(**attrs)
      end
    end

    # A restart empties the in-memory queue, so a queued job is as lost as a running one.
    def recover_running_jobs
      @jobs.each_value do |job|
        next unless job.running? || job.status == 'queued'

        job.status = 'failed'
        job.error = INTERRUPTED_ERROR
        job.finished_at = Time.now.utc.iso8601
        log(job)
      end
    end
  end
end
