# frozen_string_literal: true

require "digest"

module LLMCache
  # Middleware wrapper for RubyLLM::Chat that automatically caches responses
  #
  # @example Basic usage
  #   chat = RubyLLM.chat(model: "gpt-4o")
  #   cached_chat = LLMCache.wrap(chat)
  #   cached_chat.ask("What is 2+2?")  # First call - executes LLM
  #   cached_chat.ask("What is 2+2?")  # Second call - returns cached response
  #
  # @example With custom threshold
  #   cached_chat = LLMCache.wrap(chat, threshold: 0.95)
  #
  # @example With streaming caching
  #   cached_chat = LLMCache.wrap(chat, cache_streaming: true)
  #   cached_chat.ask("Hello") { |chunk| print chunk.content }
  #
  class Middleware
    # Methods to delegate directly to the wrapped chat (no caching)
    DELEGATED_METHODS = %i[
      model messages tools params headers schema
      with_instructions with_tool with_tools with_model
      with_temperature with_context with_params with_headers with_schema
      on_new_message on_end_message on_tool_call on_tool_result
      each reset_messages!
    ].freeze

    attr_reader :chat, :cache_instance

    # @param chat [RubyLLM::Chat] the chat instance to wrap
    # @param cache [LLMCache::Instance, nil] optional cache instance
    # @param threshold [Float, nil] similarity threshold override
    # @param ttl [Integer, nil] TTL override in seconds
    # @param include_history [Boolean] whether to include conversation history in cache key (default: true)
    # @param hash_history [Boolean] whether to hash conversation history instead of embedding full text (default: false)
    # @param on_cache_hit [Proc, nil] callback when cache hit occurs, receives (chat, user_message, cached_response)
    # @param cache_streaming [Boolean] whether to cache streaming responses (default: false)
    #   Use this to persist messages when using ActiveRecord persistence with RubyLLM.
    #   Example: ->(chat, msg, resp) { chat.messages.create!(role: :user, content: msg); chat.messages.create!(role: :assistant, content: resp.content) }
    # @param max_messages [Integer, nil] max conversation messages before skipping cache (nil = use config default)
    #   When conversation has more messages than this (excluding system), caching is bypassed entirely.
    def initialize(chat, cache: nil, threshold: nil, ttl: nil, include_history: true,
                   hash_history: false, on_cache_hit: nil, cache_streaming: false, max_messages: :not_set)
      @chat = chat
      @cache_instance = cache
      @threshold = threshold
      @ttl = ttl
      @include_history = include_history
      @hash_history = hash_history
      @on_cache_hit = on_cache_hit
      @cache_streaming = cache_streaming
      @max_messages_set = max_messages != :not_set
      @max_messages = max_messages == :not_set ? nil : max_messages
      @embedding_generator_mutex = Mutex.new
    end

    # Ask a question with automatic caching
    # @param message [String] the message to send
    # @param with [Object] attachments to include
    # @return [RubyLLM::Message] the response message
    def ask(message = nil, with: nil, &block)
      # Skip caching if message has attachments
      return @chat.ask(message, with: with, &block) if with

      # Skip caching for tool-enabled chats (responses may vary)
      return @chat.ask(message, with: with, &block) if @chat.tools.any?

      # Skip caching if conversation exceeds max_messages (excluding system messages)
      return @chat.ask(message, with: with, &block) if conversation_too_long?

      # Handle streaming requests
      if block_given?
        return @chat.ask(message, with: with, &block) unless @cache_streaming

        return ask_with_streaming_cache(message, &block)
      end

      # Use cache for non-streaming
      cache_key = build_cache_key(message)

      cached = cache_lookup(cache_key)
      if cached
        handle_cache_hit(message, cached)
        return cached
      end

      # Execute the actual LLM call
      response = instrument(:cache_miss, query: message) do
        @chat.ask(message)
      end

      # Cache the response
      store_in_cache(cache_key, response)

      response
    end

    alias say ask

    # Delegate other methods to the wrapped chat
    DELEGATED_METHODS.each do |method|
      define_method(method) do |*args, **kwargs, &block|
        result = @chat.send(method, *args, **kwargs, &block)
        # If the method returns the chat (for chaining), return self instead
        result.equal?(@chat) ? self : result
      end
    end

    private

    def conversation_too_long?
      # Use instance variable if explicitly set (even if nil), otherwise use config
      max = defined?(@max_messages_set) && @max_messages_set ? @max_messages : config.max_messages
      return false if max.nil?

      # Count non-system messages in the conversation
      conversation_length = @chat.messages.count { |m| m.role != :system }
      conversation_length >= max
    end

    def build_cache_key(message)
      # Include system instructions and optionally conversation history in the cache key
      parts = []

      # Add system instructions
      system_messages = @chat.messages.select { |m| m.role == :system }
      system_context = system_messages.map { |m| extract_text(m.content) }.join("\n")
      parts << "[SYSTEM]\n#{system_context}" unless system_context.empty?

      # Add conversation history (user and assistant messages) if enabled
      if @include_history
        conversation_messages = @chat.messages.reject { |m| m.role == :system }
        unless conversation_messages.empty?
          if @hash_history
            # Hash the conversation context for efficiency (exact match only for context)
            history_text = conversation_messages.map do |m|
              "#{m.role}:#{extract_text(m.content)}"
            end.join("|")
            history_hash = Digest::SHA256.hexdigest(history_text)[0, 16]
            parts << "[CONTEXT:#{history_hash}]"
          else
            # Full conversation history for semantic matching
            history = conversation_messages.map do |m|
              "[#{m.role.to_s.upcase}]\n#{extract_text(m.content)}"
            end.join("\n")
            parts << history
          end
        end
      end

      # Add current message
      parts << "[USER]\n#{message}"

      parts.join("\n---\n")
    end

    def extract_text(content)
      case content
      when String
        content
      when ->(c) { c.respond_to?(:text) }
        content.text
      else
        content.to_s
      end
    end

    def handle_cache_hit(user_message, cached_response)
      if @on_cache_hit
        # Let the callback handle persistence (for ActiveRecord-backed chats)
        @on_cache_hit.call(@chat, user_message, cached_response)
      else
        # Default: add to in-memory messages array for conversation continuity
        add_message_to_chat(:user, user_message)
        add_message_to_chat(:assistant, cached_response.content, cached_response)
      end
    end

    def add_message_to_chat(role, content, original_message = nil)
      return unless defined?(RubyLLM::Message)

      # Build message with same attributes as original if provided
      message = if original_message.is_a?(RubyLLM::Message)
                  original_message
                else
                  RubyLLM::Message.new(role: role, content: content)
                end

      # Add to chat's messages array if it responds to it
      if @chat.messages.respond_to?(:<<)
        # For user messages, create a new one
        if role == :user
          @chat.messages << RubyLLM::Message.new(role: :user, content: content)
        else
          @chat.messages << message
        end
      end
    end

    def cache_lookup(key)
      embedding = embedding_generator.generate(key)
      threshold = @threshold || config.similarity_threshold

      matches = vector_store.search(embedding, limit: 1)

      if matches.any? && matches.first[:similarity] >= threshold
        entry_data = cache_store_instance.get(matches.first[:id])
        return nil unless entry_data

        record_hit!
        result = deserialize_message(entry_data[:response])

        notify(:cache_hit, {
          query: key[0, 100],
          similarity: matches.first[:similarity],
          threshold: threshold
        })

        result
      else
        notify(:cache_lookup_miss, {
          query: key[0, 100],
          best_similarity: matches.any? ? matches.first[:similarity] : nil,
          threshold: threshold
        })

        nil
      end
    end

    def store_in_cache(key, response)
      record_miss!
      embedding = embedding_generator.generate(key)
      ttl = @ttl || config.ttl_seconds

      entry = Entry.new(
        query: key,
        response: serialize_message(response),
        embedding: embedding,
        metadata: { model: @chat.model&.id }
      )

      vector_store.add(entry.id, embedding)
      cache_store_instance.set(entry.id, entry.to_h, ttl: ttl)
    end

    def serialize_message(message)
      return LLMCache.send(:serialize_response, message) unless defined?(RubyLLM::Message)
      return LLMCache.send(:serialize_response, message) unless message.is_a?(RubyLLM::Message)

      {
        type: "rubyllm_message",
        value: {
          role: message.role,
          content: serialize_content(message.content),
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

    def serialize_content(content)
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

    def deserialize_message(data)
      return data unless data.is_a?(Hash)

      type = data[:type] || data["type"]
      value = data[:value] || data["value"]

      case type
      when "rubyllm_message"
        return value unless defined?(RubyLLM::Message)

        # Reconstruct the RubyLLM::Message
        content = deserialize_content(value[:content] || value["content"])
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
      else
        LLMCache.send(:deserialize_response, data)
      end
    end

    def deserialize_content(data)
      return data unless data.is_a?(Hash)

      type = data[:type] || data["type"]
      value = data[:value] || data["value"]

      case type
      when "string", "hash"
        value
      when "rubyllm_content"
        # Return as hash - RubyLLM::Message will handle it
        value
      else
        value
      end
    end

    def config
      @cache_instance ? @cache_instance.instance_variable_get(:@config) : LLMCache.config
    end

    def embedding_generator
      @embedding_generator_mutex.synchronize do
        @embedding_generator ||= Embedding.new(config)
      end
    end

    def ask_with_streaming_cache(message, &block)
      cache_key = build_cache_key(message)

      cached = cache_lookup(cache_key)
      if cached
        handle_cache_hit(message, cached)
        # Replay cached response as simulated chunks
        replay_cached_response(cached, &block)
        return cached
      end

      # Buffer streaming response for caching
      response = instrument(:cache_miss_streaming, query: message) do
        @chat.ask(message, &block)
      end

      # Cache the complete response
      store_in_cache(cache_key, response)

      response
    end

    def replay_cached_response(cached_response, &block)
      return unless block_given?

      content = cached_response.respond_to?(:content) ? cached_response.content : cached_response.to_s

      # Create a simple chunk-like object for replay
      chunk_class = Struct.new(:content)

      # Replay in reasonable chunks (simulate streaming)
      content.to_s.scan(/.{1,50}/m).each do |chunk_text|
        block.call(chunk_class.new(chunk_text))
      end
    end

    def instrument(event_name, payload = {})
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = yield

      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      payload[:duration] = duration

      notify(event_name, payload)

      result
    end

    def notify(event_name, payload)
      # Custom callback from config
      config.instrumentation_callback&.call(event_name, payload)

      # ActiveSupport::Notifications integration
      if defined?(ActiveSupport::Notifications)
        ActiveSupport::Notifications.instrument("#{event_name}.llm_cache", payload)
      end
    end

    def vector_store
      if @cache_instance
        @cache_instance.send(:vector_store)
      else
        LLMCache.send(:vector_store)
      end
    end

    def cache_store_instance
      if @cache_instance
        @cache_instance.send(:cache_store)
      else
        LLMCache.send(:cache_store)
      end
    end

    def record_hit!
      if @cache_instance
        @cache_instance.instance_variable_set(:@hits, @cache_instance.instance_variable_get(:@hits) + 1)
      else
        LLMCache.send(:record_hit!)
      end
    end

    def record_miss!
      if @cache_instance
        @cache_instance.instance_variable_set(:@misses, @cache_instance.instance_variable_get(:@misses) + 1)
      else
        LLMCache.send(:record_miss!)
      end
    end
  end
end
