# frozen_string_literal: true

require_relative "llm_cache/version"
require_relative "llm_cache/configuration"
require_relative "llm_cache/entry"
require_relative "llm_cache/embedding"
require_relative "llm_cache/vector_stores/base"
require_relative "llm_cache/vector_stores/memory"
require_relative "llm_cache/cache_stores/base"
require_relative "llm_cache/cache_stores/memory"
require_relative "llm_cache/middleware"

module LLMCache
  class Error < StandardError; end
  class NotFoundError < Error; end

  class << self
    # Configure the cache
    # @yield [Configuration] the configuration object
    def configure
      yield(config)
      reset! # Reset stores when configuration changes
    end

    # Get the current configuration
    # @return [Configuration]
    def config
      @config ||= Configuration.new
    end

    # Fetch a cached response or execute the block and cache the result
    # @param query [String] the query to cache
    # @param threshold [Float] similarity threshold (overrides config)
    # @param ttl [Integer] time-to-live in seconds (overrides config)
    # @return the cached or computed response
    def fetch(query, threshold: nil, ttl: nil, &block)
      raise ArgumentError, "Block required" unless block_given?

      threshold ||= config.similarity_threshold
      ttl ||= config.ttl_seconds

      # Generate embedding for the query
      embedding = embedding_generator.generate(query)

      # Search for similar cached queries
      matches = vector_store.search(embedding, limit: 1)

      if matches.any? && matches.first[:similarity] >= threshold
        # Cache hit
        record_hit!
        entry_data = cache_store.get(matches.first[:id])

        if entry_data
          return deserialize_response(entry_data[:response])
        end
      end

      # Cache miss - execute block
      record_miss!
      response = block.call

      # Store in cache
      store(query: query, response: response, embedding: embedding, ttl: ttl)

      response
    end

    # Store a response in the cache
    # @param query [String] the query
    # @param response the response to cache
    # @param embedding [Array<Float>] pre-computed embedding (optional)
    # @param metadata [Hash] additional metadata
    # @param ttl [Integer] time-to-live in seconds
    # @return [Entry] the created entry
    def store(query:, response:, embedding: nil, metadata: {}, ttl: nil)
      embedding ||= embedding_generator.generate(query)
      ttl ||= config.ttl_seconds

      entry = Entry.new(
        query: query,
        response: serialize_response(response),
        embedding: embedding,
        metadata: metadata
      )

      vector_store.add(entry.id, embedding)
      cache_store.set(entry.id, entry.to_h, ttl: ttl)

      entry
    end

    # Search for similar cached queries
    # @param query [String] the query to search for
    # @param limit [Integer] maximum number of results
    # @return [Array<Hash>] matching entries with similarity scores
    def search(query, limit: 5)
      embedding = embedding_generator.generate(query)
      matches = vector_store.search(embedding, limit: limit)

      matches.filter_map do |match|
        entry_data = cache_store.get(match[:id])
        next unless entry_data

        {
          query: entry_data[:query],
          response: deserialize_response(entry_data[:response]),
          similarity: match[:similarity],
          metadata: entry_data[:metadata]
        }
      end
    end

    # Check if a similar query exists in the cache
    # @param query [String] the query to check
    # @param threshold [Float] similarity threshold
    # @return [Boolean]
    def exists?(query, threshold: nil)
      threshold ||= config.similarity_threshold
      embedding = embedding_generator.generate(query)
      matches = vector_store.search(embedding, limit: 1)
      matches.any? && matches.first[:similarity] >= threshold
    end

    # Delete a cached entry by query
    # @param query [String] the query to delete
    # @param threshold [Float] similarity threshold for matching
    # @return [Boolean] true if an entry was deleted
    def delete(query, threshold: nil)
      threshold ||= config.similarity_threshold
      embedding = embedding_generator.generate(query)
      matches = vector_store.search(embedding, limit: 1)

      return false unless matches.any? && matches.first[:similarity] >= threshold

      id = matches.first[:id]
      vector_store.delete(id)
      cache_store.delete(id)
      true
    end

    # Clear all cached entries
    def clear!
      vector_store.clear!
      cache_store.clear!
      embedding_generator.clear_cache! if embedding_generator.respond_to?(:clear_cache!)
      reset_stats!
    end

    # Invalidate all cache entries similar to the given query
    # @param query [String] the query to match against
    # @param threshold [Float] similarity threshold (defaults to config)
    # @param limit [Integer] maximum entries to invalidate
    # @return [Integer] number of entries invalidated
    def invalidate(query, threshold: nil, limit: 100)
      threshold ||= config.similarity_threshold
      embedding = embedding_generator.generate(query)
      matches = vector_store.search(embedding, limit: limit)

      count = 0
      matches.each do |match|
        next unless match[:similarity] >= threshold

        vector_store.delete(match[:id])
        cache_store.delete(match[:id])
        count += 1
      end

      count
    end

    # Invalidate cache entries matching a pattern in query text
    # @param pattern [Regexp, String] pattern to match against cached queries
    # @return [Integer] number of entries invalidated
    def invalidate_matching(pattern)
      pattern = Regexp.new(pattern) if pattern.is_a?(String)

      # This requires iterating through all entries - use sparingly
      count = 0
      cache_store.each do |id, entry_data|
        query = entry_data[:query] || entry_data["query"]
        next unless query&.match?(pattern)

        vector_store.delete(id)
        cache_store.delete(id)
        count += 1
      end

      count
    end

    # Get cache statistics
    # @return [Hash] cache statistics
    def stats
      {
        hits: @hits || 0,
        misses: @misses || 0,
        hit_rate: hit_rate,
        entries: cache_store.size
      }
    end

    # Reset the cache stores (clears stores but preserves configuration)
    def reset!
      @embedding_generator = nil
      @vector_store = nil
      @cache_store = nil
      reset_stats!
    end

    # Fully reset including configuration (useful for testing)
    def reset_all!
      @config = nil
      reset!
    end

    # Create a new cache instance with a specific namespace
    # @param namespace [String] the namespace
    # @return [Instance] a scoped cache instance
    def new(namespace:)
      Instance.new(namespace: namespace)
    end

    # Wrap a RubyLLM::Chat instance with caching middleware
    # @param chat [RubyLLM::Chat] the chat instance to wrap
    # @param threshold [Float, nil] similarity threshold override
    # @param ttl [Integer, nil] TTL override in seconds
    # @param include_history [Boolean] include conversation history in cache key (default: true)
    # @param hash_history [Boolean] hash conversation history instead of embedding full text (default: false)
    # @param on_cache_hit [Proc, nil] callback for cache hits, receives (chat, user_message, cached_response)
    # @param cache_streaming [Boolean] whether to cache streaming responses (default: false)
    # @param max_messages [Integer, nil] max conversation messages before skipping cache (nil = use config)
    # @return [Middleware] the wrapped chat
    def wrap(chat, threshold: nil, ttl: nil, include_history: true, hash_history: false,
             on_cache_hit: nil, cache_streaming: false, max_messages: nil)
      Middleware.new(
        chat,
        threshold: threshold,
        ttl: ttl,
        include_history: include_history,
        hash_history: hash_history,
        on_cache_hit: on_cache_hit,
        cache_streaming: cache_streaming,
        max_messages: max_messages
      )
    end

    private

    def embedding_generator
      @embedding_generator ||= Embedding.new(config)
    end

    def vector_store
      @vector_store ||= build_vector_store
    end

    def cache_store
      @cache_store ||= build_cache_store
    end

    def build_vector_store
      case config.vector_store
      when :memory
        VectorStores::Memory.new(config)
      when :redis
        require_relative "llm_cache/vector_stores/redis"
        VectorStores::Redis.new(config)
      else
        raise Error, "Unknown vector store: #{config.vector_store}"
      end
    end

    def build_cache_store
      case config.cache_store
      when :memory
        CacheStores::Memory.new(config)
      when :redis
        require_relative "llm_cache/cache_stores/redis"
        CacheStores::Redis.new(config)
      else
        raise Error, "Unknown cache store: #{config.cache_store}"
      end
    end

    def serialize_response(response)
      # Handle RubyLLM::Message specially for full reconstruction
      if defined?(RubyLLM::Message) && response.is_a?(RubyLLM::Message)
        return serialize_rubyllm_message(response)
      end

      case response
      when String
        { type: "string", value: response }
      when Hash
        { type: "hash", value: response }
      when NilClass
        { type: "nil", value: nil }
      else
        if response.respond_to?(:to_h)
          { type: "object", class: response.class.name, value: response.to_h }
        else
          { type: "string", value: response.to_s }
        end
      end
    end

    def serialize_rubyllm_message(message)
      {
        type: "rubyllm_message",
        value: {
          role: message.role,
          content: serialize_rubyllm_content(message.content),
          model_id: message.model_id,
          tool_calls: message.tool_calls,
          tool_call_id: message.tool_call_id,
          input_tokens: message.input_tokens,
          output_tokens: message.output_tokens,
          cached_tokens: message.cached_tokens,
          cache_creation_tokens: message.cache_creation_tokens
        }.compact
      }
    end

    def serialize_rubyllm_content(content)
      case content
      when String
        { type: "string", value: content }
      when Hash
        { type: "hash", value: content }
      when ->(c) { defined?(RubyLLM::Content) && c.is_a?(RubyLLM::Content) }
        { type: "rubyllm_content", value: content.to_h }
      else
        { type: "string", value: content.to_s }
      end
    end

    def deserialize_response(data)
      return data unless data.is_a?(Hash)

      type = data[:type] || data["type"]
      value = data[:value] || data["value"]

      case type
      when "rubyllm_message"
        deserialize_rubyllm_message(value)
      when "string", "hash", "object"
        value
      when "nil"
        nil
      else
        value
      end
    end

    def deserialize_rubyllm_message(value)
      return value unless defined?(RubyLLM::Message)

      content = deserialize_rubyllm_content(value[:content] || value["content"])
      RubyLLM::Message.new(
        role: (value[:role] || value["role"]).to_sym,
        content: content,
        model_id: value[:model_id] || value["model_id"],
        tool_calls: value[:tool_calls] || value["tool_calls"],
        tool_call_id: value[:tool_call_id] || value["tool_call_id"],
        input_tokens: value[:input_tokens] || value["input_tokens"],
        output_tokens: value[:output_tokens] || value["output_tokens"],
        cached_tokens: value[:cached_tokens] || value["cached_tokens"],
        cache_creation_tokens: value[:cache_creation_tokens] || value["cache_creation_tokens"]
      )
    end

    def deserialize_rubyllm_content(data)
      return data unless data.is_a?(Hash)

      type = data[:type] || data["type"]
      value = data[:value] || data["value"]

      case type
      when "string", "hash"
        value
      when "rubyllm_content"
        # Return as hash - RubyLLM::Message normalizes it
        value
      else
        value
      end
    end

    def record_hit!
      @hits = (@hits || 0) + 1
    end

    def record_miss!
      @misses = (@misses || 0) + 1
    end

    def hit_rate
      total = (@hits || 0) + (@misses || 0)
      return 0.0 if total.zero?

      (@hits || 0).to_f / total
    end

    def reset_stats!
      @hits = 0
      @misses = 0
    end
  end

  # Scoped cache instance with its own namespace
  class Instance
    def initialize(namespace:)
      @namespace = namespace
      @config = Configuration.new.tap do |c|
        c.namespace = namespace
      end
      @embedding_generator = nil
      @vector_store = nil
      @cache_store = nil
      @hits = 0
      @misses = 0
    end

    def configure
      yield(@config)
      reset!
    end

    def fetch(query, threshold: nil, ttl: nil, &block)
      raise ArgumentError, "Block required" unless block_given?

      threshold ||= @config.similarity_threshold
      ttl ||= @config.ttl_seconds

      embedding = embedding_generator.generate(query)
      matches = vector_store.search(embedding, limit: 1)

      if matches.any? && matches.first[:similarity] >= threshold
        @hits += 1
        entry_data = cache_store.get(matches.first[:id])
        return deserialize_response(entry_data[:response]) if entry_data
      end

      @misses += 1
      response = block.call
      store(query: query, response: response, embedding: embedding, ttl: ttl)
      response
    end

    def store(query:, response:, embedding: nil, metadata: {}, ttl: nil)
      embedding ||= embedding_generator.generate(query)
      ttl ||= @config.ttl_seconds

      entry = Entry.new(
        query: query,
        response: serialize_response(response),
        embedding: embedding,
        metadata: metadata
      )

      vector_store.add(entry.id, embedding)
      cache_store.set(entry.id, entry.to_h, ttl: ttl)
      entry
    end

    def search(query, limit: 5)
      embedding = embedding_generator.generate(query)
      matches = vector_store.search(embedding, limit: limit)

      matches.filter_map do |match|
        entry_data = cache_store.get(match[:id])
        next unless entry_data

        {
          query: entry_data[:query],
          response: deserialize_response(entry_data[:response]),
          similarity: match[:similarity],
          metadata: entry_data[:metadata]
        }
      end
    end

    def exists?(query, threshold: nil)
      threshold ||= @config.similarity_threshold
      embedding = embedding_generator.generate(query)
      matches = vector_store.search(embedding, limit: 1)
      matches.any? && matches.first[:similarity] >= threshold
    end

    def clear!
      vector_store.clear!
      cache_store.clear!
      @hits = 0
      @misses = 0
    end

    def stats
      {
        hits: @hits,
        misses: @misses,
        hit_rate: (@hits + @misses).zero? ? 0.0 : @hits.to_f / (@hits + @misses),
        entries: cache_store.size
      }
    end

    private

    def reset!
      @embedding_generator = nil
      @vector_store = nil
      @cache_store = nil
    end

    def embedding_generator
      @embedding_generator ||= Embedding.new(@config)
    end

    def vector_store
      @vector_store ||= build_vector_store
    end

    def cache_store
      @cache_store ||= build_cache_store
    end

    def build_vector_store
      case @config.vector_store
      when :memory
        VectorStores::Memory.new(@config)
      when :redis
        require_relative "llm_cache/vector_stores/redis"
        VectorStores::Redis.new(@config)
      else
        raise Error, "Unknown vector store: #{@config.vector_store}"
      end
    end

    def build_cache_store
      case @config.cache_store
      when :memory
        CacheStores::Memory.new(@config)
      when :redis
        require_relative "llm_cache/cache_stores/redis"
        CacheStores::Redis.new(@config)
      else
        raise Error, "Unknown cache store: #{@config.cache_store}"
      end
    end

    def serialize_response(response)
      LLMCache.send(:serialize_response, response)
    end

    def deserialize_response(data)
      LLMCache.send(:deserialize_response, data)
    end
  end
end
