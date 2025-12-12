# frozen_string_literal: true

require "securerandom"
require "time"

module LLMCache
  class Entry
    attr_reader :id, :query, :response, :embedding, :metadata, :created_at

    def initialize(query:, response:, embedding:, metadata: {}, id: nil, created_at: nil)
      @id = id || SecureRandom.uuid
      @query = query
      @response = response
      @embedding = embedding
      @metadata = metadata
      @created_at = created_at || Time.now
    end

    def to_h
      {
        id: @id,
        query: @query,
        response: @response,
        metadata: @metadata,
        created_at: @created_at.iso8601
      }
    end

    def self.from_h(hash)
      new(
        id: hash[:id] || hash["id"],
        query: hash[:query] || hash["query"],
        response: hash[:response] || hash["response"],
        embedding: hash[:embedding] || hash["embedding"],
        metadata: hash[:metadata] || hash["metadata"] || {},
        created_at: parse_time(hash[:created_at] || hash["created_at"])
      )
    end

    def self.parse_time(value)
      case value
      when Time then value
      when String then Time.parse(value)
      when nil then Time.now
      else value
      end
    end
  end
end
