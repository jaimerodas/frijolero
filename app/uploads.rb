# frozen_string_literal: true

require 'securerandom'
require 'fileutils'
require 'date'

module Frijolero
  # Upload a PDF, confirm the classification, enqueue the job.
  class App
    get '/upload' do
      erb :upload
    end

    post '/upload' do
      path = save_upload
      result = Classifier.new(client: self.class.client).classify(path)
      erb :confirm, locals: {
        token: File.basename(File.dirname(path)),
        filename: File.basename(path),
        result: result,
        accounts: Config.accounts.keys,
        overwrite: params[:overwrite] ? '1' : '0'
      }
    end

    post '/upload/confirm' do
      account, period, pdf_path, file_id, overwrite = validate_confirm!
      period_end = iso_date(params[:period_end])
      job = enqueue_statement(account: account, period: period, pdf_path: pdf_path,
                              file_id: file_id, overwrite: overwrite) do
        AccountConfig.record_cutoff(account, period_end) if period_end
      end
      redirect "/jobs/#{job.id}", 303
    end

    # Only the PDF, for a statement whose .beancount already exists. No OpenAI, no ledger,
    # no job: the put takes seconds, so it runs in the request.
    post '/upload/backup' do
      account, period = validate_account_and_period!
      pdf_path = validate_token!(params[:token])
      self.class.b2.put(Config.pdf_key(account, period), pdf_path)
      FileUtils.rm_rf(File.dirname(pdf_path))
      redirect "/accounts/#{Rack::Utils.escape_path(account)}", 303
    rescue B2::Error => e
      halt 502, "No se pudo guardar el PDF en B2: #{Rack::Utils.escape_html(e.message)}"
    end

    private

    # One directory per upload (named by a random token) so the original filename
    # survives, which is what lets Classifier's filename shortcut fire.
    def save_upload
      file = params[:pdf]
      name = upload_name(file)
      halt 422, 'Sube un PDF' unless name.match?(/\.pdf\z/i)

      dir = File.join(Config.incoming_dir, SecureRandom.hex(8))
      FileUtils.mkdir_p(dir)
      dest = File.join(dir, name)
      FileUtils.cp(file[:tempfile].path, dest)
      dest
    end

    # Rack leaves a plain multipart filename as BINARY; browsers send it as UTF-8.
    def upload_name(file)
      return '' unless file.is_a?(Hash)

      file[:filename].to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def validate_confirm!
      account, period = validate_account_and_period!
      [account, period, validate_token!(params[:token]), blank_to_nil(params[:file_id]), params[:overwrite] == '1']
    end

    def validate_account_and_period!
      halt 422, 'Cuenta inválida' unless Config.accounts.key?(params[:account])
      halt 422, 'Periodo inválido' unless params[:period].to_s.match?(/\A\d{4}\z/)

      [params[:account], params[:period]]
    end

    def validate_token!(token)
      halt 422, 'Token inválido' unless token.to_s.match?(/\A\h{16}\z/)

      dir = File.join(Config.incoming_dir, token)
      files = Dir.exist?(dir) ? Dir.children(dir) : []
      halt 422, 'Token inválido' unless files.size == 1

      File.join(dir, files.first)
    end

    def blank_to_nil(value)
      value.to_s.strip.empty? ? nil : value
    end

    # The printed period end is optional: the filename shortcut has none.
    def iso_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    # The collaborators are read here rather than inside the block: the block runs on
    # the worker thread, long after this request is gone.
    def enqueue_statement(account:, period:, pdf_path:, file_id:, overwrite:, &after)
      statement = Statement.new(pdf_path, client: self.class.client, b2: self.class.b2, account: account,
                                          period: period, file_id: file_id, overwrite: overwrite)
      run_job("#{account} #{period}", statement, File.dirname(pdf_path), &after)
    end

    # Pull before the work and push after it. The volume holds a clone, so a job that
    # writes without pulling first turns the next push into a conflict to untangle by
    # hand; a job that fails leaves the upload where it is, for a retry. The block
    # runs after a good statement and rides on the same commit.
    def run_job(label, statement, upload_dir)
      repo = self.class.repo
      self.class.jobs.push(label: label) do
        repo.pull
        status = statement.process
        raise "Statement terminó con #{status}" unless status == Statement::OK

        yield if block_given?
        repo.commit_and_push(label)
        FileUtils.rm_rf(upload_dir)
      end
    end
  end
end
