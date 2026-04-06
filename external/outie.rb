#!/usr/bin/env ruby
# frozen_string_literal: true

require 'sinatra'
require 'json'
require 'securerandom'
require 'openssl'
require 'fileutils'

configure do
  set :server, 'puma'
  set :bind, '0.0.0.0'
  set :port, ENV.fetch('PORT', 4567).to_i
  set :protection, except: :host_authorization
end

# Directory where pending and processing jobs are stored
QUEUE_DIR = ENV.fetch('QUEUE_DIR', '/data/queue')

# Directory where encrypted query results are stored
RESULTS_DIR = ENV.fetch('RESULTS_DIR', '/data/results')

# Debug - print ALL important variables
warn '=== Environment Debug ==='
warn "QUEUE_DIR = #{QUEUE_DIR.inspect}"
warn "RESULTS_DIR = #{RESULTS_DIR.inspect}"
warn "ENCRYPTION_KEY_HEX present = #{ENV['ENCRYPTION_KEY_HEX'] ? 'YES' : 'NO'}"
warn "AUTH_TOKEN = #{ENV['AUTH_TOKEN'] ? '*** (present)' : 'NOT SET'}"
warn "RESULT_FORMAT = #{ENV['RESULT_FORMAT'].inspect}"
warn '========================='

# AES-256-GCM encryption key derived from hex environment variable
ENCRYPTION_KEY = [ENV.fetch('ENCRYPTION_KEY_HEX')].pack('H*')

# Content-Type for query results (json or csv)
CONTENT_TYPE = ENV['RESULT_FORMAT'] == 'csv' ? 'text/csv' : 'application/sparql-results+json'

# Create required directories on startup
begin
  FileUtils.mkdir_p([QUEUE_DIR, RESULTS_DIR])
  warn "✓ Successfully created directories: #{QUEUE_DIR} and #{RESULTS_DIR}"
rescue Errno::EACCES => e
  warn "❌ Permission error creating directories: #{e.message}"
  warn ' Make sure the volume is mounted and the user has write access.'
  raise
end

# ============== AES-256-GCM helpers ==============

# Encrypts data using AES-256-GCM.
#
# @param data [String] Plaintext data to encrypt
# @return [String] Encrypted binary data (nonce + tag + ciphertext)
def encrypt(data)
  cipher = OpenSSL::Cipher.new('aes-256-gcm')
  cipher.encrypt
  cipher.key = ENCRYPTION_KEY
  nonce = cipher.random_iv
  ciphertext = cipher.update(data) + cipher.final
  tag = cipher.auth_tag
  nonce + tag + ciphertext
end

# Decrypts data previously encrypted with {#encrypt}.
#
# @param encrypted [String] Binary encrypted data (nonce + tag + ciphertext)
# @return [String] Decrypted plaintext
# @raise [OpenSSL::Cipher::CipherError] if decryption fails (wrong key, tampered data, etc.)
def decrypt(encrypted)
  cipher = OpenSSL::Cipher.new('aes-256-gcm')
  cipher.decrypt
  cipher.key = ENCRYPTION_KEY
  nonce = encrypted[0, 12]
  tag = encrypted[12, 16]
  ct = encrypted[28..]
  cipher.iv = nonce
  cipher.auth_tag = tag
  cipher.update(ct) + cipher.final
end

# ============== Security: Internal IP filtering for sensitive endpoints ==============

# Security filter applied to every request.
#
# - Internal endpoints (`/severance/queue/pull`, `/severance/jobs/*`, `/severance/available_queries`)
#   are only accessible from whitelisted IPs (default: localhost).
# - All other (user-facing) endpoints require a valid `Bearer` token if `AUTH_TOKEN` is set.
before do
  # === Internal calls from Innie (no auth required) ===
  internal_paths = ['/severance/queue/pull', '/severance/jobs/', '/severance/available_queries']
  if internal_paths.any? { |p| request.path_info.start_with?(p) }
    allowed_ips = (ENV['ALLOWED_INTERNAL_IPS'] || '127.0.0.1,::1,localhost').split(',').map(&:strip)
    client_ip = request.ip
    # Allow if client IP is in the list or it's localhost
    is_allowed = allowed_ips.include?(client_ip) ||
                 (allowed_ips.include?('localhost') && ['127.0.0.1', '::1'].include?(client_ip))
    halt 403, "Access denied from #{client_ip} - internal IP required" unless is_allowed
    # Internal call → bypass Bearer token check
    return
  end

  # === External/user-facing calls - require Bearer token ===
  if ENV['AUTH_TOKEN']
    auth_header = request.env['HTTP_AUTHORIZATION']
    expected = "Bearer #{ENV['AUTH_TOKEN']}"
    unless auth_header && auth_header.casecmp?(expected)
      warn "Auth failed. Received: #{auth_header.inspect} | Expected: #{expected}"
      halt 401, 'Unauthorized'
    end
  end
end

# Submits a new query job for asynchronous execution.
#
# Accepts either JSON body or form parameters.
#
# @return [201] with `Location` header pointing to the job status
# @return [400] if `query_id` is missing or empty
post '/severance/queries' do
  # Safely parse input whether it's JSON or form data
  data = if request.content_type&.include?('application/json')
           JSON.parse(request.body.read)
         else
           # For form-encoded or query params
           { 'query_id' => params['query_id'], 'bindings' => params.except('query_id') }
         end

  # Ensure we have a hash and extract query_id safely
  query_id = data.is_a?(Hash) ? data['query_id'] : nil
  halt 400, { error: 'query_id is required' }.to_json if query_id.nil? || query_id.to_s.strip.empty?

  uuid = SecureRandom.uuid
  job = {
    'query_id' => query_id.to_s.strip,
    'bindings' => (data.is_a?(Hash) ? data['bindings'] || {} : {}),
    'submitted_at' => Time.now.to_i
  }

  File.write("#{QUEUE_DIR}/#{uuid}.pending.json", JSON.generate(job))

  status 201
  headers 'Location' => "#{request.base_url}/severance/jobs/#{uuid}"
  body ''
end

# ============== Catalog: Receive and serve list of available queries ==============

# Receives the full list of available queries from Innie and saves it to disk.
#
# @return [200] on success with count
# @return [400] if JSON is invalid
# @return [500] on other errors
post '/severance/available_queries' do
  queries = JSON.parse(request.body.read)
  metadata_dir = ENV.fetch('METADATA_DIR', '/metadata')
  active_queries_path = "#{metadata_dir}/active_queries.json"

  File.write(active_queries_path, JSON.pretty_generate(queries))
  warn "✓ Received and saved #{queries.size} available queries to #{active_queries_path}"

  status 200
  content_type 'application/json'
  body({ success: true, count: queries.size }.to_json)
rescue JSON::ParserError => e
  warn "❌ Invalid JSON in /available_queries: #{e.message}"
  status 400
  content_type 'application/json'
  body({ error: 'Invalid JSON' }.to_json)
rescue StandardError => e
  warn "❌ Error saving available queries: #{e.message}"
  status 500
  content_type 'application/json'
  body({ error: 'Internal server error' }.to_json)
end

# Returns the current list of available queries (previously pushed by Innie).
get '/severance/available_queries' do
  metadata_dir = ENV.fetch('METADATA_DIR', '/metadata')
  active_queries_path = "#{metadata_dir}/active_queries.json"

  if File.exist?(active_queries_path)
    content_type 'application/json'
    File.read(active_queries_path)
  else
    status 404
    content_type 'application/json'
    body({ error: 'No queries available yet' }.to_json)
  end
end

# ============== Status / Result retrieval ==============

# Returns the status or result of a job.
#
# @param uuid [String] Job UUID
# @return [202] if still processing
# @return [200] with result (and deletes files) if completed
# @return [404] if job not found
get '/severance/jobs/:uuid' do |uuid|
  pending = "#{QUEUE_DIR}/#{uuid}.pending.json"
  processing = "#{QUEUE_DIR}/#{uuid}.processing.json"
  result_file = "#{RESULTS_DIR}/#{uuid}.enc"

  if File.exist?(pending) || File.exist?(processing)
    status 202
    headers 'Retry-After' => '10'
    body '{"status":"processing"}'
  elsif File.exist?(result_file)
    begin
      encrypted = File.binread(result_file)
      data = decrypt(encrypted)
      content_type CONTENT_TYPE
      File.delete(result_file)
      File.delete(processing) if File.exist?(processing)
      body data
    rescue OpenSSL::Cipher::CipherError => e
      warn "[ERROR] Decryption failed for #{uuid}: #{e.message}"
      status 500
      body 'Decryption error'
    rescue StandardError => e
      warn "[ERROR] Serving result #{uuid}: #{e.message}"
      status 500
      body 'Server error'
    end
  else
    status 404
    body '{"error":"not found"}'
  end
end

# ============== Internal: Push result from "Innie" ==============

# Receives the execution result from Innie and stores it encrypted.
#
# @param uuid [String] Job UUID
post '/severance/jobs/:uuid/result' do |uuid|
  body_content = request.body.read.force_encoding('UTF-8')
  result_file = "#{RESULTS_DIR}/#{uuid}.enc"
  processing = "#{QUEUE_DIR}/#{uuid}.processing.json"

  encrypted_data = encrypt(body_content)
  File.binwrite(result_file, encrypted_data)
  File.delete(processing) if File.exist?(processing)

  status 200
  body ''
end

# ============== Internal: Poll for next job ==============

# Internal endpoint used by Innie to pull the next pending job.
#
# Returns 204 No Content if queue is empty.
get '/severance/queue/pull' do
  pending_files = Dir["#{QUEUE_DIR}/*.pending.json"].sort
  if pending_files.empty?
    status 204
    body ''
  else
    file = pending_files.first
    uuid = File.basename(file, '.pending.json')
    job_json = File.read(file)

    # Move to processing
    File.rename(file, "#{QUEUE_DIR}/#{uuid}.processing.json")

    # Add uuid to the response
    job = JSON.parse(job_json)
    job['uuid'] = uuid

    content_type 'application/json'
    body JSON.generate(job)
  end
end

# Optional helper route - health check / info
get '/severance' do
  'Outie service ready. Use /severance/queries to submit jobs.'
end
