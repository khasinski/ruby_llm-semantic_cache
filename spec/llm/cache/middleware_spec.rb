# frozen_string_literal: true

RSpec.describe LLM::Cache::Middleware do
  # Mock RubyLLM classes for testing without requiring real RubyLLM
  before(:all) do
    # Define mock RubyLLM module and classes if not already defined
    unless defined?(RubyLLM)
      module RubyLLM
        class Content
          attr_reader :text, :attachments

          def initialize(text = nil, _attachments = nil)
            @text = text
            @attachments = []
          end

          def to_h
            { text: @text, attachments: @attachments }
          end
        end

        class Message
          ROLES = %i[system user assistant tool].freeze

          attr_reader :role, :model_id, :tool_calls, :tool_call_id,
                      :input_tokens, :output_tokens, :cached_tokens, :cache_creation_tokens
          attr_accessor :content

          def initialize(options = {})
            @role = options.fetch(:role).to_sym
            @raw_content = normalize_content(options.fetch(:content))
            @model_id = options[:model_id]
            @tool_calls = options[:tool_calls]
            @tool_call_id = options[:tool_call_id]
            @input_tokens = options[:input_tokens]
            @output_tokens = options[:output_tokens]
            @cached_tokens = options[:cached_tokens]
            @cache_creation_tokens = options[:cache_creation_tokens]
          end

          # Match RubyLLM's behavior - return text if Content with just text
          def content
            if @raw_content.is_a?(Content) && @raw_content.text && @raw_content.attachments.empty?
              @raw_content.text
            else
              @raw_content
            end
          end

          def content=(val)
            @raw_content = val
          end

          def to_h
            {
              role: role,
              content: content,
              model_id: model_id,
              tool_calls: tool_calls,
              tool_call_id: tool_call_id,
              input_tokens: input_tokens,
              output_tokens: output_tokens,
              cached_tokens: cached_tokens,
              cache_creation_tokens: cache_creation_tokens
            }.compact
          end

          private

          def normalize_content(content)
            case content
            when String then Content.new(content)
            when Hash then content[:text] || content["text"]
            else content
            end
          end
        end

        class Model
          attr_reader :id

          def initialize(id)
            @id = id
          end
        end

        class Chat
          attr_reader :model, :messages, :tools

          def initialize(model: nil)
            @model = Model.new(model || "gpt-4o")
            @messages = []
            @tools = {}
            @ask_responses = []
          end

          def ask(message = nil, with: nil, &block)
            # For testing, add user message to history
            @messages << Message.new(role: :user, content: message) if message

            # If block given (streaming), just call it
            if block_given?
              block.call("chunk")
              return Message.new(role: :assistant, content: "streamed response")
            end

            # Return next queued response or default
            response = @ask_responses.shift || Message.new(
              role: :assistant,
              content: "Default response for: #{message}",
              model_id: @model.id,
              input_tokens: 10,
              output_tokens: 20
            )
            @messages << response
            response
          end

          def with_instructions(instructions, replace: false)
            @messages = @messages.reject { |m| m.role == :system } if replace
            @messages.unshift(Message.new(role: :system, content: instructions))
            self
          end

          def with_tool(tool)
            @tools[tool.to_sym] = tool
            self
          end

          # For testing: queue up responses
          def queue_response(response)
            @ask_responses << response
          end
        end
      end
    end
  end

  before(:each) do
    LLM::Cache.reset_all!
    LLM::Cache.configure do |config|
      config.vector_store = :memory
      config.cache_store = :memory
      config.embedding_dimensions = 8
      config.similarity_threshold = 0.9
      config.embedding_fn = lambda { |text|
        # Use a truly deterministic hash (MD5) for consistent embeddings across runs
        require "digest"
        hash_value = Digest::MD5.hexdigest(text).to_i(16)
        srand(hash_value % (2**31))
        vec = Array.new(8) { rand }
        mag = Math.sqrt(vec.sum { |x| x * x })
        vec.map { |x| x / mag }
      }
    end
    LLM::Cache.clear!
  end

  describe ".wrap" do
    it "wraps a chat instance" do
      chat = RubyLLM::Chat.new(model: "gpt-4o")
      wrapped = LLM::Cache.wrap(chat)

      expect(wrapped).to be_a(LLM::Cache::Middleware)
      expect(wrapped.chat).to eq(chat)
    end

    it "accepts threshold override" do
      chat = RubyLLM::Chat.new
      wrapped = LLM::Cache.wrap(chat, threshold: 0.99)

      expect(wrapped.instance_variable_get(:@threshold)).to eq(0.99)
    end

    it "accepts ttl override" do
      chat = RubyLLM::Chat.new
      wrapped = LLM::Cache.wrap(chat, ttl: 3600)

      expect(wrapped.instance_variable_get(:@ttl)).to eq(3600)
    end
  end

  describe "#ask" do
    it "caches responses from first call" do
      chat = RubyLLM::Chat.new
      wrapped = LLM::Cache.wrap(chat)

      response1 = wrapped.ask("What is Ruby?")
      expect(response1).to be_a(RubyLLM::Message)
      expect(response1.role).to eq(:assistant)
    end

    it "returns cached response on subsequent identical calls" do
      chat = RubyLLM::Chat.new
      # Queue specific responses
      chat.queue_response(RubyLLM::Message.new(
        role: :assistant,
        content: "Ruby is a programming language",
        model_id: "gpt-4o",
        input_tokens: 5,
        output_tokens: 10
      ))
      chat.queue_response(RubyLLM::Message.new(
        role: :assistant,
        content: "This should not be returned",
        model_id: "gpt-4o"
      ))

      # Use include_history: false so repeated identical questions hit cache
      wrapped = LLM::Cache.wrap(chat, include_history: false)

      response1 = wrapped.ask("What is Ruby?")
      response2 = wrapped.ask("What is Ruby?")

      expect(response1.content).to include("Ruby")
      expect(response2.content).to eq(response1.content)
    end

    it "skips cache for streaming requests" do
      chat = RubyLLM::Chat.new
      wrapped = LLM::Cache.wrap(chat)

      chunks = []
      response = wrapped.ask("Stream this") { |chunk| chunks << chunk }

      expect(chunks).to eq(["chunk"])
      expect(response.content).to eq("streamed response")
    end

    it "skips cache for chats with tools" do
      chat = RubyLLM::Chat.new.with_tool(:my_tool)
      wrapped = LLM::Cache.wrap(chat)

      # Tools chats bypass cache entirely
      response = wrapped.ask("Use the tool")
      expect(response).to be_a(RubyLLM::Message)
    end

    it "tracks cache statistics" do
      chat = RubyLLM::Chat.new
      chat.queue_response(RubyLLM::Message.new(
        role: :assistant,
        content: "First response",
        model_id: "gpt-4o"
      ))

      # Use include_history: false so repeated identical questions hit cache
      wrapped = LLM::Cache.wrap(chat, include_history: false)

      wrapped.ask("Query 1")
      wrapped.ask("Query 1")  # Cache hit

      stats = LLM::Cache.stats
      expect(stats[:hits]).to eq(1)
      expect(stats[:misses]).to eq(1)
    end
  end

  describe "#say" do
    it "is an alias for ask" do
      chat = RubyLLM::Chat.new
      wrapped = LLM::Cache.wrap(chat)

      expect(wrapped.method(:say)).to eq(wrapped.method(:ask))
    end
  end

  describe "delegation" do
    it "delegates model to wrapped chat" do
      chat = RubyLLM::Chat.new(model: "gpt-4o")
      wrapped = LLM::Cache.wrap(chat)

      expect(wrapped.model.id).to eq("gpt-4o")
    end

    it "delegates messages to wrapped chat" do
      chat = RubyLLM::Chat.new
      wrapped = LLM::Cache.wrap(chat)

      expect(wrapped.messages).to eq([])
    end

    it "returns self for chainable methods" do
      chat = RubyLLM::Chat.new
      wrapped = LLM::Cache.wrap(chat)

      result = wrapped.with_instructions("Be helpful")
      expect(result).to eq(wrapped)
    end
  end

  describe "context-aware caching" do
    it "includes system instructions in cache key" do
      chat1 = RubyLLM::Chat.new.with_instructions("Be formal")
      chat1.queue_response(RubyLLM::Message.new(
        role: :assistant,
        content: "Formal response",
        model_id: "gpt-4o"
      ))

      chat2 = RubyLLM::Chat.new.with_instructions("Be casual")
      chat2.queue_response(RubyLLM::Message.new(
        role: :assistant,
        content: "Casual response",
        model_id: "gpt-4o"
      ))

      wrapped1 = LLM::Cache.wrap(chat1)
      wrapped2 = LLM::Cache.wrap(chat2)

      response1 = wrapped1.ask("Hello")
      response2 = wrapped2.ask("Hello")

      # Different system prompts = different cache keys = different responses
      expect(response1.content).to eq("Formal response")
      expect(response2.content).to eq("Casual response")
    end
  end

  describe "multi-turn conversation caching" do
    it "includes conversation history in cache key by default" do
      chat1 = RubyLLM::Chat.new
      chat1.queue_response(RubyLLM::Message.new(role: :assistant, content: "Ruby is a language", model_id: "gpt-4o"))
      chat1.queue_response(RubyLLM::Message.new(role: :assistant, content: "It was created by Matz", model_id: "gpt-4o"))

      chat2 = RubyLLM::Chat.new
      chat2.queue_response(RubyLLM::Message.new(role: :assistant, content: "Python is a language", model_id: "gpt-4o"))
      chat2.queue_response(RubyLLM::Message.new(role: :assistant, content: "Different follow-up", model_id: "gpt-4o"))

      wrapped1 = LLM::Cache.wrap(chat1)  # include_history: true by default
      wrapped2 = LLM::Cache.wrap(chat2)

      # First turn
      wrapped1.ask("What is Ruby?")
      wrapped2.ask("What is Python?")

      # Second turn - "Tell me more" has different context in each conversation
      response1 = wrapped1.ask("Tell me more")
      response2 = wrapped2.ask("Tell me more")

      # Different conversation history = different cache keys = different responses
      expect(response1.content).to eq("It was created by Matz")
      expect(response2.content).to eq("Different follow-up")
    end

    it "caches identical multi-turn conversations" do
      # First conversation
      chat1 = RubyLLM::Chat.new
      chat1.queue_response(RubyLLM::Message.new(role: :assistant, content: "Ruby is a language", model_id: "gpt-4o"))
      chat1.queue_response(RubyLLM::Message.new(role: :assistant, content: "Created by Matz", model_id: "gpt-4o"))

      # Second conversation - identical flow
      chat2 = RubyLLM::Chat.new
      chat2.queue_response(RubyLLM::Message.new(role: :assistant, content: "This should not be used", model_id: "gpt-4o"))
      chat2.queue_response(RubyLLM::Message.new(role: :assistant, content: "Neither should this", model_id: "gpt-4o"))

      wrapped1 = LLM::Cache.wrap(chat1)
      wrapped2 = LLM::Cache.wrap(chat2)

      # First conversation
      wrapped1.ask("What is Ruby?")
      response1 = wrapped1.ask("Who created it?")

      # Second conversation - same questions in same order should hit cache
      wrapped2.ask("What is Ruby?")  # Cache hit from chat1
      response2 = wrapped2.ask("Who created it?")  # Cache hit from chat1

      expect(response1.content).to eq("Created by Matz")
      expect(response2.content).to eq("Created by Matz")  # Cached response
    end

    it "adds cached response to chat messages for continuity" do
      chat = RubyLLM::Chat.new
      chat.queue_response(RubyLLM::Message.new(role: :assistant, content: "First answer", model_id: "gpt-4o"))

      wrapped = LLM::Cache.wrap(chat, include_history: false)

      # First call - cache miss
      wrapped.ask("Question 1")
      initial_message_count = chat.messages.length

      # Second call - cache hit, should still add messages
      wrapped.ask("Question 1")

      # Messages should include the cached response for conversation continuity
      expect(chat.messages.length).to eq(initial_message_count + 2)  # +1 user, +1 assistant
      expect(chat.messages.last.role).to eq(:assistant)
      expect(chat.messages.last.content).to eq("First answer")
    end

    it "can disable history with include_history: false" do
      chat = RubyLLM::Chat.new
      chat.queue_response(RubyLLM::Message.new(role: :assistant, content: "Answer 1", model_id: "gpt-4o"))
      chat.queue_response(RubyLLM::Message.new(role: :assistant, content: "Answer 2", model_id: "gpt-4o"))

      wrapped = LLM::Cache.wrap(chat, include_history: false)

      wrapped.ask("Question")
      response = wrapped.ask("Question")  # Same question, should hit cache

      # Without history, same question always hits cache regardless of prior turns
      expect(response.content).to eq("Answer 1")
    end
  end

  describe "on_cache_hit callback" do
    it "calls on_cache_hit callback on cache hit" do
      chat = RubyLLM::Chat.new
      chat.queue_response(RubyLLM::Message.new(role: :assistant, content: "Cached answer", model_id: "gpt-4o"))

      callback_calls = []
      on_hit = ->(c, msg, resp) { callback_calls << { chat: c, message: msg, response: resp } }

      wrapped = LLM::Cache.wrap(chat, include_history: false, on_cache_hit: on_hit)

      wrapped.ask("Question")  # Cache miss
      wrapped.ask("Question")  # Cache hit - should trigger callback

      expect(callback_calls.length).to eq(1)
      expect(callback_calls.first[:message]).to eq("Question")
      expect(callback_calls.first[:response].content).to eq("Cached answer")
      expect(callback_calls.first[:chat]).to eq(chat)
    end

    it "does not call on_cache_hit on cache miss" do
      chat = RubyLLM::Chat.new
      chat.queue_response(RubyLLM::Message.new(role: :assistant, content: "Answer", model_id: "gpt-4o"))

      callback_calls = []
      on_hit = ->(c, msg, resp) { callback_calls << { chat: c, message: msg, response: resp } }

      wrapped = LLM::Cache.wrap(chat, on_cache_hit: on_hit)

      wrapped.ask("Question")  # Cache miss

      expect(callback_calls).to be_empty
    end

    it "skips default message handling when on_cache_hit is provided" do
      chat = RubyLLM::Chat.new
      chat.queue_response(RubyLLM::Message.new(role: :assistant, content: "Answer", model_id: "gpt-4o"))

      # Custom callback that does nothing
      wrapped = LLM::Cache.wrap(chat, include_history: false, on_cache_hit: ->(_c, _m, _r) {})

      wrapped.ask("Question")  # Cache miss - adds to messages
      initial_count = chat.messages.length

      wrapped.ask("Question")  # Cache hit - callback does nothing, no messages added

      # Messages should NOT have been added since callback handles it
      expect(chat.messages.length).to eq(initial_count)
    end
  end
end
