# frozen_string_literal: true

module LLMCache
  # Defined here to avoid circular dependency - Error is defined in llm_cache.rb
  # but configuration.rb is loaded first
  class ConfigurationError < StandardError; end

  class Configuration
    VALID_VECTOR_STORES = %i[memory redis].freeze
    VALID_CACHE_STORES = %i[memory redis].freeze

    # Vector store backend: :redis, :memory
    attr_accessor :vector_store

    # Cache store backend: :redis, :memory
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

    # Cache embeddings to avoid recomputing (default: true)
    attr_accessor :cache_embeddings

    # Instrumentation callback for metrics/observability
    # Called with event_name and payload hash
    attr_accessor :instrumentation_callback

    # Maximum conversation messages to cache (excluding system messages)
    # When conversation exceeds this, caching is skipped entirely
    # Default: 1 (only cache first user message, skip caching for follow-ups)
    attr_accessor :max_messages

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
      @cache_embeddings = true
      @instrumentation_callback = nil
      @max_messages = 1
    end

    def ttl_seconds
      return nil if @ttl.nil?

      case @ttl
      when Numeric then @ttl.to_i
      when ->(t) { t.respond_to?(:to_i) } then @ttl.to_i
      else nil
      end
    end

    # Validate the configuration and raise errors for invalid settings
    # @raise [ConfigurationError] if configuration is invalid
    def validate!
      validate_stores!
      validate_threshold!
      validate_dimensions!
      validate_redis_config!
      true
    end

    # Check if configuration is valid without raising
    # @return [Boolean]
    def valid?
      validate!
      true
    rescue ConfigurationError
      false
    end

    private

    def validate_stores!
      unless VALID_VECTOR_STORES.include?(@vector_store)
        raise ConfigurationError,
              "Invalid vector_store: #{@vector_store}. Valid options: #{VALID_VECTOR_STORES.join(', ')}"
      end

      unless VALID_CACHE_STORES.include?(@cache_store)
        raise ConfigurationError,
              "Invalid cache_store: #{@cache_store}. Valid options: #{VALID_CACHE_STORES.join(', ')}"
      end
    end

    def validate_threshold!
      unless @similarity_threshold.is_a?(Numeric) && (0.0..1.0).cover?(@similarity_threshold)
        raise ConfigurationError,
              "similarity_threshold must be a number between 0.0 and 1.0, got: #{@similarity_threshold.inspect}"
      end
    end

    def validate_dimensions!
      unless @embedding_dimensions.is_a?(Integer) && @embedding_dimensions.positive?
        raise ConfigurationError,
              "embedding_dimensions must be a positive integer, got: #{@embedding_dimensions.inspect}"
      end
    end

    def validate_redis_config!
      return unless @vector_store == :redis || @cache_store == :redis
      return if @redis_url || @redis_client

      raise ConfigurationError,
            "redis_url or redis_client required when using Redis backend"
    end
  end
end
