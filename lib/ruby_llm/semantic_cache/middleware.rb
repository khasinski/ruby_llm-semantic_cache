# frozen_string_literal: true

require "digest"

module RubyLLM
  module SemanticCache
    # Middleware wrapper for RubyLLM::Chat that automatically caches responses
    #
    # @example Basic usage
    #   chat = RubyLLM.chat(model: "gpt-5.2")
    #   cached_chat = RubyLLM::SemanticCache.wrap(chat)
    #   cached_chat.ask("What is 2+2?")  # First call - executes LLM
    #
    # @example With custom threshold
    #   cached_chat = RubyLLM::SemanticCache.wrap(chat, threshold: 0.95)
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

      attr_reader :chat

      # @param chat [RubyLLM::Chat] the chat instance to wrap
      # @param threshold [Float, nil] similarity threshold override
      # @param ttl [Integer, nil] TTL override in seconds
      # @param on_cache_hit [Proc, nil] callback when cache hit occurs, receives (chat, user_message, cached_response)
      # @param max_messages [Integer, :unlimited, false, nil] max conversation messages before skipping cache
      #   - Integer: skip cache after N messages (default: 1, only first message cached)
      #   - :unlimited or false: cache all messages regardless of conversation length
      #   - nil: use config default
      def initialize(chat, threshold: nil, ttl: nil, on_cache_hit: nil, max_messages: nil)
        @chat = chat
        @threshold = threshold
        @ttl = ttl
        @on_cache_hit = on_cache_hit
        @max_messages = max_messages
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

        # Skip caching for streaming (too complex to handle correctly)
        return @chat.ask(message, with: with, &block) if block_given?

        # Use cache for non-streaming
        cache_key = build_cache_key(message)

        cached = cache_lookup(cache_key)
        if cached
          handle_cache_hit(message, cached)
          return cached
        end

        # Execute the actual LLM call
        response = @chat.ask(message)

        # Cache the response
        store_in_cache(cache_key, response)
        RubyLLM::SemanticCache.record_miss!

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
        max = effective_max_messages
        return false if max.nil?

        # Count non-system messages in the conversation
        conversation_length = @chat.messages.count { |m| m.role != :system }
        conversation_length >= max
      end

      def effective_max_messages
        # Use instance setting if provided, otherwise config
        max = @max_messages.nil? ? RubyLLM::SemanticCache.config.max_messages : @max_messages

        # :unlimited or false means no limit
        return nil if max == :unlimited || max == false

        max
      end

      def build_cache_key(message)
        # Include model and system instructions in the cache key
        parts = []

        # Add model ID to ensure different models have separate cache entries
        model_id = @chat.model&.id || @chat.model
        parts << "[MODEL:#{model_id}]" if model_id

        # Add system instructions
        system_messages = @chat.messages.select { |m| m.role == :system }
        system_context = system_messages.map { |m| extract_text(m.content) }.join("\n")
        parts << "[SYSTEM]\n#{system_context}" unless system_context.empty?

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

        message = if role == :user
                    RubyLLM::Message.new(role: :user, content: content)
                  elsif original_message.is_a?(RubyLLM::Message)
                    original_message
                  else
                    RubyLLM::Message.new(role: role, content: content)
                  end

        @chat.messages << message if @chat.messages.respond_to?(:<<)
      end

      def cache_lookup(key)
        embedding = RubyLLM::SemanticCache.embedding_generator.generate(key)
        threshold = @threshold || RubyLLM::SemanticCache.config.similarity_threshold

        matches = RubyLLM::SemanticCache.vector_store.search(embedding, limit: 1)

        if matches.any? && matches.first[:similarity] >= threshold
          entry_data = RubyLLM::SemanticCache.cache_store.get(matches.first[:id])
          return nil unless entry_data

          RubyLLM::SemanticCache.record_hit!
          Serializer.deserialize(entry_data[:response])
        end
      end

      def store_in_cache(key, response)
        embedding = RubyLLM::SemanticCache.embedding_generator.generate(key)
        ttl = @ttl || RubyLLM::SemanticCache.config.ttl_seconds

        entry = Entry.new(
          query: key,
          response: Serializer.serialize(response),
          embedding: embedding,
          metadata: { model: @chat.model&.id }
        )

        RubyLLM::SemanticCache.vector_store.add(entry.id, embedding)
        RubyLLM::SemanticCache.cache_store.set(entry.id, entry.to_h, ttl: ttl)
      end
    end
  end
end
