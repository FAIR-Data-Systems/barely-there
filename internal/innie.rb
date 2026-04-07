#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'fileutils'
require_relative 'annotation_parser'

include QueryAnnotationParser

# External service URL (e.g. the UI / orchestrator service)
EXTERNAL_URL = ENV.fetch('EXTERNAL_URL')

# Triplestore SPARQL endpoint URL
TRIPLESTORE_URL = ENV.fetch('TRIPLESTORE_URL')

# Directory containing the .rq query files (usually mounted read-only)
QUERY_DIR = ENV.fetch('QUERY_DIR')

# How often to poll the external service for new jobs (in seconds)
POLL_INTERVAL = ENV.fetch('POLL_INTERVAL', 10).to_i

# Output format for SPARQL results: 'json' (default) or 'csv'
RESULT_FORMAT = ENV['RESULT_FORMAT'] == 'csv' ? 'csv' : 'json'

# Accept header sent to the triplestore
ACCEPT_HEADER = RESULT_FORMAT == 'csv' ? 'text/csv' : 'application/sparql-results+json'

# ------------------------------------------------------------------
# Helper: Escape value for safe insertion into SPARQL
# ------------------------------------------------------------------

# Replaces grlc-style parameters (`?_name_type` or `?__name_type`) in a SPARQL query
# with properly escaped and typed values from the provided bindings.
#
# @param query [String] The original SPARQL query text
# @param bindings [Hash] Parameter values (key => value)
# @param variable_types [Hash] Optional type information from the annotation parser
#                              (used to decide whether to treat a value as IRI)
#
# @return [String] The query with all parameters substituted
def substitute_grlc_bindings(query, bindings, variable_types = {})
  return query if bindings.nil? || bindings.empty?

  bindings.each do |k, v|
    next if v.nil?

    warn "Processing binding: #{k} => #{v.inspect}"
    warn "Variable types for #{k}: #{variable_types[k.to_s]}"
    # Determine if this variable is declared as iri
    is_iri = variable_types[k.to_s]&.downcase == 'iri'
    warn "Variable '#{k}' is declared as IRI: #{is_iri}"
    escaped_value = if is_iri
                      # Auto-wrap IRIs in < >
                      if v.to_s.strip.start_with?('<') && v.to_s.strip.end_with?('>')
                        v.to_s.strip
                      else
                        "<#{v.to_s.strip}>"
                      end
                    else
                      escape_for_sparql(v)
                    end
    warn "Escaped value for #{k}: #{escaped_value}"

    # Match both ?_key_type and ?__key_type
    pattern = /(?:\?__|\?_)#{Regexp.escape(k.to_s)}_[\w:]+/i
    query.gsub!(pattern) do |_match|
      escaped_value
    end

    warn "→ Substituted ?_#{k}_* → #{escaped_value}"
  end
  query
end

# Escapes a Ruby value for safe use inside a SPARQL query string.
#
# @param value [Object] The value to escape (String, Numeric, Boolean, etc.)
# @return [String] A properly quoted and escaped SPARQL literal
def escape_for_sparql(value)
  case value
  when TrueClass, FalseClass then value.to_s
  when Numeric then value.to_s
  when String
    escaped = value.gsub('\\', '\\\\').gsub('"', '\\"')
    "\"#{escaped}\""
  else
    "\"#{value.to_s.gsub('\\', '\\\\').gsub('"', '\\"')}\""
  end
end

# Placeholder for future query validation logic.
#
# @param _query [String] The SPARQL query to validate
# @return [Boolean] Currently always returns true
def validate_query(_query)
  true # ← stub – replace with real validation later
end

# ========================================================================
# ============================ MAIN LOOP =================================
# ========================================================================

# On startup: Push all query metadata to the external service (Outie)
# so the UI can list available queries and later request them by ID.
begin
  queries = QueryAnnotationParser::Parser.process_folder(QUERY_DIR)
  all_queries = {}
  # Build the final list that Outie expects
  available_queries = queries.map do |metadata|
    # Compute smart bindings from defaults + enumerate
    bindings = metadata['defaults'].dup || {}

    # If there are enumerated values, add them as arrays (for UI dropdowns)
    (metadata['enumerate'] || {}).each do |key, values|
      bindings[key] = values if values.is_a?(Array) && !values.empty?
    end

    queryhash = {
      'query_id' => metadata['query_id'],
      'title' => metadata['title'],
      'summary' => metadata['summary'],
      'description' => metadata['description'],
      'tags' => metadata['tags'],
      'variables' => metadata['variables'],
      'variable_types' => metadata['variable_types'],
      'examples' => bindings,
      'pagination' => metadata['pagination'],
      'method' => metadata['method'],
      'endpoint' => metadata['endpoint'],
      'endpoint_in_url' => metadata['endpoint_in_url']
    }.compact # remove nil keys

    all_queries[metadata['query_id']] = queryhash # for quick lookup later when processing jobs
    queryhash
  end

  # ONE single POST with the full list of available queries
  push_uri = URI("#{EXTERNAL_URL}/severance/available_queries")
  warn "Pushing #{available_queries.size} available queries to #{push_uri.inspect}..."
  push_req = Net::HTTP::Post.new(push_uri)
  push_req['Content-Type'] = 'application/json; charset=utf-8'
  push_req.body = JSON.generate(available_queries)

  http = Net::HTTP.new(push_uri.hostname, push_uri.port)
  http.use_ssl = (push_uri.scheme == 'https')
  res = http.request(push_req)

  if res.is_a?(Net::HTTPSuccess)
    warn "✓ Registered #{available_queries.size} queries"
    available_queries.each do |q|
      warn " • #{q['query_id']} (#{q['title'] || 'no title'})"
    end
  else
    warn "⚠ Failed to register queries: #{res.code} #{res.message}"
  end

  warn "Registration completed for #{available_queries.size} queries"
rescue StandardError => e
  warn "❌ Failed to push queries on startup: #{e.class} - #{e.message}"
end

# Main polling loop: continuously pull jobs from the external service,
# execute them against the triplestore, and push results back.
loop do
  poll_uri = URI("#{EXTERNAL_URL}/severance/queue/pull")
  warn "Polling for new jobs at #{poll_uri.inspect}..."
  http = Net::HTTP.new(poll_uri.hostname, poll_uri.port)
  http.use_ssl = (poll_uri.scheme == 'https')
  response = http.request(Net::HTTP::Get.new(poll_uri))

  if response.code == '204'
    sleep POLL_INTERVAL
    next
  end

  job = JSON.parse(response.body)
  uuid = job['uuid']
  raise 'No UUID in job response!' unless uuid

  query_id = job['query_id']
  bindings = job['bindings'] || {}

  query_path = "#{QUERY_DIR}/#{query_id}.rq"
  unless File.exist?(query_path)
    warn "Query file missing: #{query_path}"
    sleep POLL_INTERVAL
    next
  end

  query = File.read(query_path, encoding: 'UTF-8')
  warn "Found query #{query_id} (#{query_path})"
  warn "all_queries #{all_queries.inspect}"

  # === Bind grlc-style placeholders (?_key_type) ===
  query = substitute_grlc_bindings(query, bindings, all_queries[query_id]['variable_types'])
  warn "Final query after binding:\n#{query}"

  validate_query(query) # currently a no-op, but can be expanded with real validation logic later

  # === Execute against triplestore with authentication ===
  uri = URI(TRIPLESTORE_URL)
  warn "SPARQL endpoint: #{uri.inspect}"

  req = Net::HTTP::Post.new(uri)
  req['Accept'] = ACCEPT_HEADER
  req['Content-Type'] = 'application/sparql-query'
  req.body = query

  # Add Basic Authentication if credentials are provided
  if ENV['TRIPLESTORE_USER'] && ENV['TRIPLESTORE_PASS']
    req.basic_auth(ENV['TRIPLESTORE_USER'], ENV['TRIPLESTORE_PASS'])
    warn "Using Basic Auth for user: #{ENV['TRIPLESTORE_USER']}"
  else
    warn 'Warning: TRIPLESTORE_USER or TRIPLESTORE_PASS not set - running without authentication'
  end

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
    http.request(req)
  end

  warn "SPARQL SERVER: HTTP result status: #{res.code}"
  result_body = res.body.strip
  # === Push result back to External ===
  push_uri = URI("#{EXTERNAL_URL}/severance/jobs/#{uuid}/result")
  http = Net::HTTP.new(push_uri.hostname, push_uri.port)
  http.use_ssl = (push_uri.scheme == 'https')
  push_req = Net::HTTP::Post.new(push_uri)
  push_req['Content-Type'] = 'text/plain; charset=utf-8'
  push_req.body = result_body.force_encoding('UTF-8')

  push_res = http.request(push_req)
  warn "Job #{uuid} completed (push status: #{push_res.code})"
  puts "[#{Time.now}] Job #{uuid} for query #{query_id} finished"

  # Small delay before next poll
  sleep POLL_INTERVAL
end
