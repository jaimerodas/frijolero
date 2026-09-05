# frozen_string_literal: true

# Single mode: no `workers` call, so one process. PUMA_THREADS caps the pool.
threads 1, ENV.fetch('PUMA_THREADS', '3').to_i
port ENV.fetch('PORT', '9292')
environment ENV.fetch('RACK_ENV', 'production')
