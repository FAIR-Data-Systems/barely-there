#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'

# Module for parsing SPARQL query files with special annotation comments.
#
# This module provides tools to extract structured metadata from query files
# that use #+ decorator comments, while preserving the original SPARQL query.
#
# Designed to work well with grlc-style queries and custom documentation needs.
module QueryAnnotationParser
  # Main parser class responsible for extracting metadata and query content
  # from annotated SPARQL files.
  class Parser
    # Parses a single SPARQL query file and returns structured metadata.
    #
    # @param file_path [String] Path to the .rq or .sparql file
    #
    # @return [Hash] Metadata hash containing query information and annotations
    # @option return [String] 'query_id'          Query identifier (defaults to filename)
    # @option return [String, nil] 'title'        Human-readable title
    # @option return [String, nil] 'summary'      Short summary of the query
    # @option return [String, nil] 'description'  Detailed description
    # @option return [String, nil] 'endpoint'     SPARQL endpoint URL
    # @option return [Integer, nil] 'pagination'  Default pagination size
    # @option return [String, nil] 'method'       HTTP method (GET/POST)
    # @option return [Boolean, nil] 'endpoint_in_url'  Whether endpoint is embedded in URL
    # @option return [Array<String>] 'tags'       List of tags
    # @option return [Hash] 'defaults'            Default parameter values
    # @option return [Hash] 'enumerate'           Enumeration lists for parameters
    # @option return [Array<String>] 'variables'  Detected query parameters
    # @option return [Hash] 'variable_types'      Parameter name → normalized type
    # @option return [String] 'query'             The cleaned SPARQL query
    #
    # @example
    #   metadata = QueryAnnotationParser::Parser.parse("queries/countries.rq")
    #   puts metadata['title']
    def self.parse(file_path)
      content = File.read(file_path, encoding: 'UTF-8')
      lines = content.lines
      metadata = {
        'query_id' => File.basename(file_path, '.*'),
        'title' => nil,
        'summary' => nil,
        'description' => nil,
        'endpoint' => nil,
        'pagination' => nil,
        'method' => nil,
        'endpoint_in_url' => nil,
        'tags' => [],
        'defaults' => {},
        'enumerate' => {},
        'variables' => [],
        'variable_types' => {},
        'query' => ''
      }

      decorator_lines = []
      query_lines = []

      lines.each do |line|
        if line.strip.start_with?('#+')
          decorator_lines << line
        else
          query_lines << line
        end
      end

      # multi-line decorator parser
      parse_all_decorators(decorator_lines, metadata)
      metadata['query'] = query_lines.join("\n").strip

      # Extract grlc-style parameters (?_name_type)
      vars, types = extract_parameters(metadata['query'])
      metadata['variables'] = vars
      metadata['variable_types'] = types

      # Fallback query_id
      metadata['query_id'] = File.basename(file_path, '.*') if metadata['query_id'].nil? || metadata['query_id'].empty?

      warn "metadata for #{metadata['query_id']}: #{metadata.inspect}  "
      metadata
    end

    # ------------------------------------------------------------------
    # NEW parser that correctly handles tags, defaults, enumerate,
    # endpoint_in_url, and all simple key:value lines
    # ------------------------------------------------------------------
    #
    # @param decorator_lines [Array<String>] Lines starting with #+
    # @param metadata [Hash] The metadata hash to populate
    #
    # @note This is an internal method and subject to change.
    def self.parse_all_decorators(decorator_lines, metadata)
      current_key = nil
      current_list = nil

      decorator_lines.each do |line|
        clean = line.sub(/^#\+\s*/, '').strip
        next if clean.empty?

        # warn "Parsing decorator line: #{clean}  "

        # Section header like "tags:", "defaults:", "enumerate:"
        if clean.end_with?(':')
          key = clean.chomp(':').strip
          # warn "Found section header: #{key}  "

          case key
          when 'tags'
            metadata['tags'] = []
          when 'defaults'
            metadata['defaults'] = {}
          when 'enumerate'
            metadata['enumerate'] = {}
          end
          current_key = key
          current_list = nil
          next
        end
        # warn "Current key: #{current_key.inspect}, current list: #{current_list.inspect}  "
        # List item "- value" or "- key: value"
        if clean.start_with?('- ')
          item = clean.sub(/^- \s*/, '').strip
          case current_key
          when 'tags'
            metadata['tags'] << item
          when 'defaults'
            if item.include?(':')
              k, v = item.split(':', 2).map(&:strip)
              metadata['defaults'][k] = parse_value(v)
              # warn "→ Parsed default: #{k} → #{metadata['defaults'][k].inspect}  "
            end
          when 'enumerate'
            if item.include?(':') && item.end_with?(':')
              # "- country:" → start a new enumerate list
              enum_key = item.chomp(':').strip
              metadata['enumerate'][enum_key] ||= []
              current_list = metadata['enumerate'][enum_key]
            elsif current_list
              # subsequent "- value" lines belong to the current list
              current_list << parse_value(item)
            end
          end

        # Simple one-line key: value (query_id, title, endpoint, endpoint_in_url, etc.)
        elsif clean.include?(':')
          key, val = clean.split(':', 2).map(&:strip)
          metadata[key] = parse_value(val)
          current_key = nil
        end
      end
    end

    # Helper to turn "18", "true", "\"John\"", "False" into proper Ruby types.
    #
    # @param val_str [String, nil] The string value to parse
    # @return [Integer, Float, Boolean, String, nil] Parsed Ruby value
    def self.parse_value(val_str)
      return nil if val_str.nil? || val_str.empty?

      v = val_str.strip
      if (v.start_with?('"') && v.end_with?('"')) || (v.start_with?("'") && v.end_with?("'"))
        v[1..-2]
      elsif v.match?(/^\d+$/)
        v.to_i
      elsif v.match?(/^\d+\.\d+$/)
        v.to_f
      elsif v.downcase == 'true'
        true
      elsif v.downcase == 'false'
        false
      else
        v
      end
    end

    # Extracts grlc-style parameters from the query text.
    #
    # Recognizes patterns like ?_name_integer or ?__country_iri
    #
    # @param query_text [String] The SPARQL query
    # @return [Array] Two-element array: [variables, variable_types]
    def self.extract_parameters(query_text)
      variables = []
      variable_types = {}

      query_text.scan(/\?(__?)(\w+)_([\w:]+)\b/) do |_, name, type_suffix|
        next if name.empty?

        param_name = name
        variables << param_name unless variables.include?(param_name)
        variable_types[param_name] = normalize_type(type_suffix)
      end

      [variables.uniq, variable_types]
    end

    # Normalizes grlc-style type suffixes to standard types.
    #
    # @param suffix [String] The type suffix from the parameter
    # @return [String] Normalized type: 'iri', 'integer', 'float', 'boolean', 'date', or 'string'
    def self.normalize_type(suffix)
      case suffix.downcase
      when 'iri', 'uri' then 'iri'
      when 'integer', 'int' then 'integer'
      when 'float', 'double', 'decimal' then 'float'
      when 'boolean', 'bool' then 'boolean'
      when 'date', 'datetime' then 'date'
      else 'string'
      end
    end

    # Processes all .rq and .sparql files in a folder recursively.
    #
    # @param folder_path [String] Path to the folder containing query files
    # @return [Array<Hash>] Array of metadata hashes, one per query file
    # @raise [RuntimeError] if the folder does not exist
    def self.process_folder(folder_path)
      folder = Pathname.new(folder_path)
      raise "Folder not found: #{folder_path}" unless folder.directory?

      results = []
      Dir[folder.join('**/*.{rq,sparql}')].sort.each do |file|
        puts "Processing: #{File.basename(file)}"
        metadata = parse(file)
        results << metadata
      end
      results
    end
  end
end
