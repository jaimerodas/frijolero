# frozen_string_literal: true

require_relative 'page'

module Frijolero
  # / and /ledgers/…: the user's ledgers and a new one. A new ledger is the template in a
  # repo of its own, or the person's own repo: a deploy key first, then a clone over SSH.
  # The ledger of a /ledgers/<id>/ path belongs to the user, or the answer is a 404.
  class Ledgers < Page
    # One ledger opens. An own repo that is not connected yet has no pages, so it shows
    # in the list, with the link to finish it.
    get '/' do
      ledgers = Ledger.owned_by(user.id)
      return new_ledger_page if ledgers.empty?

      redirect "/l/#{ledgers.first.id}/" if ledgers.one? && connected?(ledgers.first)
      erb :ledgers, locals: { ledgers: ledgers }
    end

    get('/ledgers/new') { new_ledger_page }

    post '/ledgers' do
      ledger = Ledger.create(owner_id: user.id, name: ledger_name)
      Ledger.lock(ledger.id) { NewLedger.prepare(ledger.repo_dir) } # a new directory: always main.beancount
      redirect "/l/#{ledger.id}/", 303
    end

    post '/ledgers/repo' do
      ledger = Ledger.create(owner_id: user.id, name: ledger_name)
      redirect "/ledgers/#{ledger.id}/connect", 303
    end

    get('/ledgers/:id/connect') { connect_page(unconnected_ledger) }

    post '/ledgers/:id/connect' do
      ledger = unconnected_ledger
      url = params[:url].to_s.strip
      Ledger.lock(ledger.id) do
        halt(*LedgerScope.not_found) if connected?(ledger) # a second click, after the first one connected it
        connect(ledger, url)
      end
      redirect "/l/#{ledger.id}/", 303
    rescue LedgerRepo::Error => e
      status 422
      connect_page(ledger, url: url, error: e.message)
    end

    helpers do
      def connected?(ledger) = File.directory?(ledger.repo_dir)

      def new_ledger_page(error: nil) = erb(:ledgers_new, locals: { error: error })

      # The page makes the deploy key the first time that it shows it.
      def connect_page(ledger, url: nil, error: nil)
        key = ledger.deploy_key
        Ledger.lock(ledger.id) { LedgerRepo.keygen(key) unless File.exist?(key) }
        erb :ledgers_connect, locals: { ledger: ledger, key: File.read("#{key}.pub").chomp, url: url, error: error }
      end

      def ledger_name
        name = params[:name].to_s.strip
        halt 422, new_ledger_page(error: 'Falta el nombre del ledger.') if name.empty?
        name
      end

      # Another user's ledger and an unknown id get the same 404, so a guess learns nothing.
      def unconnected_ledger
        ledger = Ledger.find(params[:id])
        halt(*LedgerScope.not_found) unless ledger&.owner_id == user.id && !connected?(ledger)
        ledger
      end
    end

    private

    # A failure after the clone removes it, so the person can try again: the connect
    # page is there only while repo/ is not. After the clone of an empty repo there is
    # no origin/main to pull, so this is a plain push, not commit_and_push.
    def connect(ledger, url)
      repo = LedgerRepo.clone(url, ledger.repo_dir, key: ledger.deploy_key)
      main = NewLedger.prepare(ledger.repo_dir)
      repo.git('push', '-u', 'origin', 'HEAD')
      Ledger.update(ledger.id, main_file: main, remote_url: url)
    rescue LedgerRepo::Error
      FileUtils.rm_rf(ledger.repo_dir)
      raise
    end
  end
end
