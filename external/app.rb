require 'sinatra'
require 'json'
require 'securerandom'
require 'openssl'
require 'fileutils'

set :server, 'puma'
set :bind, '0.0.0.0'
set :port, ENV.fetch('PORT', 4567).to_i
set :protection, false
# set :protection, except: :host_authorization
# OR fully disable HostAuthorization while keeping others:
# set :protection, host_authorization: { permitted_hosts: ['fairdata.services', 'localhost'] }


QUEUE_DIR = ENV.fetch('QUEUE_DIR', '/data/queue')
RESULTS_DIR = ENV.fetch('RESULTS_DIR', '/data/results')
ENCRYPTION_KEY = [ENV.fetch('ENCRYPTION_KEY_HEX')].pack('H*')
CONTENT_TYPE = ENV['RESULT_FORMAT'] == 'csv' ? 'text/csv' : 'application/sparql-results+json'

FileUtils.mkdir_p([QUEUE_DIR, RESULTS_DIR])

# ============== Strong AES-256-GCM helpers ==============
def encrypt(data)
  cipher = OpenSSL::Cipher.new('aes-256-gcm')
  cipher.encrypt
  cipher.key = ENCRYPTION_KEY
  nonce = cipher.random_iv
  ciphertext = cipher.update(data) + cipher.final
  tag = cipher.auth_tag
  nonce + tag + ciphertext
end

def decrypt(encrypted)
  cipher = OpenSSL::Cipher.new('aes-256-gcm')
  cipher.decrypt
  cipher.key = ENCRYPTION_KEY
  nonce = encrypted[0, 12]
  tag   = encrypted[12, 16]
  ct    = encrypted[28..]
  cipher.iv = nonce
  cipher.auth_tag = tag
  cipher.update(ct) + cipher.final
end

# ============== Token stub (uncomment to enforce) ==============
before do
  if ENV['AUTH_TOKEN']
    halt 401 unless request.env['HTTP_AUTHORIZATION'] == "Bearer #{ENV['AUTH_TOKEN']}"
  end
end

# ============== Submit (POST or GET) ==============
post '/bthere/queries' do
  submit_job
end

get '/bthere/queries' do
  submit_job
end

def submit_job
  data = if request.content_type&.include?('json') || request.post?
           JSON.parse(request.body.read)
         else
           { 'query_id' => params['query_id'], 'bindings' => params.except('query_id') }
         end

  uuid = SecureRandom.uuid
  job = { query_id: data['query_id'], bindings: data['bindings'], submitted_at: Time.now.to_i }.to_json

  File.write("#{QUEUE_DIR}/#{uuid}.pending.json", job)

  status 201
  headers 'Location' => "#{request.base_url}/jobs/#{uuid}"
  body ''
end

# ============== Polling from gateway Hub ==============
get '/bthere/jobs/:uuid' do |uuid|
  pending = "#{QUEUE_DIR}/#{uuid}.pending.json"
  processing = "#{QUEUE_DIR}/#{uuid}.processing.json"
  result_file = "#{RESULTS_DIR}/#{uuid}.enc"

  if File.exist?(pending) || File.exist?(processing)
    status 202
    headers 'Retry-After' => '10'
    body '{"status":"processing"}'
  elsif File.exist?(result_file)
    data = decrypt(File.binread(result_file))
    content_type CONTENT_TYPE
    File.delete(result_file)          # delete after delivery 
    # cleanup of any leftover .processing
    File.delete(processing) if File.exist?(processing)
    body data
  else
    status 404
    body '{"error":"job not found"}'
  end
end

# ============== Internal results push ==============
post '/bthere/jobs/:uuid/result' do |uuid|
  body = request.body.read
  result_file = "#{RESULTS_DIR}/#{uuid}.enc"
  processing = "#{QUEUE_DIR}/#{uuid}.processing.json"

  File.binwrite(result_file, encrypt(body))
  File.delete(processing) if File.exist?(processing)

  status 200
  body ''
end

# ============== Called from Internal poll (one job at a time) ==============
get '/bthere/queue/pull' do
  pending_files = Dir["#{QUEUE_DIR}/*.pending.json"].sort
  if pending_files.empty?
    status 204
    body ''
  else
    file = pending_files.first
    uuid = File.basename(file, '.pending.json')
    job = File.read(file)
    File.rename(file, "#{QUEUE_DIR}/#{uuid}.processing.json")
    content_type 'application/json'
    body job
  end
end
