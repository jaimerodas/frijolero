# frozen_string_literal: true

require 'sinatra/base'
require_relative 'ledger_scope'

module Frijolero
  # The pages outside any ledger: Ledgers (/ and /ledgers/…), Admin (/admin/…),
  # PasskeysPage (/passkeys…) and ProfilePage (/profile…). Each is a middleware between
  # Login and LedgerScope, and passes every other path down. They have no current ledger,
  # so they must not read one: a page here names its ledger by id and checks its owner.
  # Their header is _bar.erb. Login has already put the user in env.
  class Page < Sinatra::Base
    set :views, App.views

    BUSY = 'Hay una corrida o una clasificación en curso. Espera a que termine y vuelve a intentarlo.'
    BUCKET_FAILED = 'No se pudieron borrar los PDF del bucket. Prueba otra vez.'

    helpers LocalTime
    helpers do
      def user = env['frijolero.user']

      def h(text) = Rack::Utils.escape_html(text.to_s)

      def head(title) = erb(:_head, layout: false, locals: { title: title, refresh: nil })

      def bar = erb(:_bar, layout: false)

      def connected?(ledger) = File.directory?(ledger.repo_dir)

      def origin(ledger) = connected?(ledger) ? LedgerRepo.for(ledger).origin : nil

      # 'Octubre 2026' for '2026-10'.
      def month_name(month) = "#{Period::MONTHS[month[5, 2].to_i - 1].capitalize} #{month[0, 4]}"

      # A job or a classification of the ledger that has not finished. A delete waits for
      # it, because a job writes to the bucket and to the ledger after its model call.
      def busy?(ledger)
        Ledger.with(ledger) { App.jobs.all.any? { !it.done? } || App.inbox.items.any? { !it.answer } }
      end

      def destroy_ledger(ledger) = Ledger.with(ledger) { Ledger.destroy(ledger, App.s3) }

      # One row per local month, newest first: the files, retries and cost of Usage.history,
      # and the failed jobs of the job log of each ledger. A deleted ledger takes its jobs.
      def usage_months(person)
        failed = failed_by_month(person)
        history = Usage.history(person.id).to_h { [it['month'], it] }
        (history.keys | failed.keys).sort.reverse.map do |month|
          { 'files' => 0, 'retries' => 0, 'micros' => 0, **history[month], 'month' => month,
            'failed' => failed.fetch(month, 0) }
        end
      end

      def failed_by_month(person)
        Ledger.owned_by(person.id).flat_map { |ledger| Ledger.with(ledger) { App.jobs.all } }
              .select { it.status == 'failed' && it.finished_at }
              .map { Time.iso8601(it.finished_at).localtime.strftime('%Y-%m') }.tally
      end
    end
  end
end
