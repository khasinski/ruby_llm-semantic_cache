# frozen_string_literal: true

module LLM
  module Cache
    class Configuration
      # Vector store backend: :redis, :postgresql, :memory
      attr_accessor :vector_store

      # Cache store backend: :redis, :postgresql, :memory
      attr_accessor :cache_store

      # Redis connection URL (if using Redis backend)
      attr_accessor :redis_url

      # Redis client instance (alternative to redis_url)
      attr_accessor :redis_client

      # Embedding model to use (default: text-embedding-3-small)
      attr_accessor :embedding_model

      # Embedding dimensions (default: 1536 for text-embedding-3-small)
      attr_accessor :embedding_dimensions

      # Similarity threshold (0.0 to 1.0)
      # Higher = stricter matching, fewer cache hits
      # Lower = looser matching, more cache hits but potential mismatches
      attr_accessor :similarity_threshold

      # TTL for cached entries in seconds (nil = no expiration)
      attr_accessor :ttl

      # Namespace for cache keys (useful for multi-tenant apps)
      attr_accessor :namespace

      # Custom embedding function (optional)
      # Should accept text and return array of floats
      attr_accessor :embedding_fn

      def initialize
        @vector_store = :memory
        @cache_store = :memory
        @redis_url = nil
        @redis_client = nil
        @embedding_model = "text-embedding-3-small"
        @embedding_dimensions = 1536
        @similarity_threshold = 0.92
        @ttl = nil
        @namespace = "llm_cache"
        @embedding_fn = nil
      end

      def ttl_seconds
        return nil if @ttl.nil?

        case @ttl
        when Numeric then @ttl.to_i
        when ->(t) { t.respond_to?(:to_i) } then @ttl.to_i
        else nil
        end
      end
    end
  end
end
