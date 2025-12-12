# frozen_string_literal: true

# Shared mock for RubyLLM classes used in testing
# This module provides test doubles that mimic RubyLLM's behavior
# without requiring the actual gem or making API calls.

module RubyLLMMock
  # Embedding function to use for tests (set via setup_embedding_mock!)
  class << self
    attr_accessor :embedding_fn
  end

  # Define mock classes
  def self.setup!
    return if defined?(RubyLLM) && defined?(RubyLLM::Message)

    # Define the module first
    Object.const_set(:RubyLLM, Module.new) unless defined?(RubyLLM)

    # Load the mock classes
    load_content_class
    load_message_class
    load_model_class
    load_chat_class
    load_embed_result_class
    load_embed_method
  end

  def self.load_content_class
    return if defined?(RubyLLM::Content)

    RubyLLM.const_set(:Content, Class.new do
      attr_reader :text, :attachments

      def initialize(text = nil, _attachments = nil)
        @text = text
        @attachments = []
      end

      def to_h
        { text: @text, attachments: @attachments }
      end
    end)
  end

  def self.load_message_class
    return if defined?(RubyLLM::Message)

    klass = Class.new do
      attr_reader :role, :model_id, :tool_calls, :tool_call_id,
                  :input_tokens, :output_tokens, :cached_tokens, :cache_creation_tokens

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
        if @raw_content.is_a?(RubyLLM::Content) && @raw_content.text && @raw_content.attachments.empty?
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
        when String then RubyLLM::Content.new(content)
        when Hash then content[:text] || content["text"]
        else content
        end
      end
    end

    # Set the constant after creating the class
    klass.const_set(:ROLES, %i[system user assistant tool].freeze)
    RubyLLM.const_set(:Message, klass)
  end

  def self.load_model_class
    return if defined?(RubyLLM::Model)

    RubyLLM.const_set(:Model, Class.new do
      attr_reader :id

      def initialize(id)
        @id = id
      end
    end)
  end

  def self.load_chat_class
    return if defined?(RubyLLM::Chat)

    RubyLLM.const_set(:Chat, Class.new do
      attr_reader :model, :messages, :tools

      def initialize(model: nil)
        @model = RubyLLM::Model.new(model || "gpt-4o")
        @messages = []
        @tools = {}
        @ask_responses = []
      end

      def ask(message = nil, with: nil, &block)
        # For testing, add user message to history
        @messages << RubyLLM::Message.new(role: :user, content: message) if message

        # If block given (streaming), simulate streaming
        if block_given?
          chunk = Struct.new(:content).new("chunk")
          block.call(chunk)
          return RubyLLM::Message.new(role: :assistant, content: "streamed response")
        end

        # Return next queued response or default
        response = @ask_responses.shift || RubyLLM::Message.new(
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
        @messages.unshift(RubyLLM::Message.new(role: :system, content: instructions))
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
    end)
  end

  def self.load_embed_result_class
    return if defined?(RubyLLM::EmbedResult)

    RubyLLM.const_set(:EmbedResult, Struct.new(:vectors, :model, :input_tokens, keyword_init: true))
  end

  def self.load_embed_method
    # Add the embed class method to RubyLLM module
    RubyLLM.define_singleton_method(:embed) do |text, model: nil|
      embedding_fn = RubyLLMMock.embedding_fn
      raise "RubyLLMMock.embedding_fn not set! Call setup_embedding_mock! first." unless embedding_fn

      vectors = if text.is_a?(Array)
                  text.map { |t| embedding_fn.call(t) }
                else
                  embedding_fn.call(text)
                end

      RubyLLM::EmbedResult.new(vectors: vectors, model: model, input_tokens: 10)
    end
  end

  def self.teardown!
    return unless defined?(RubyLLM)

    RubyLLM.send(:remove_const, :Chat) if defined?(RubyLLM::Chat)
    RubyLLM.send(:remove_const, :Model) if defined?(RubyLLM::Model)
    RubyLLM.send(:remove_const, :Message) if defined?(RubyLLM::Message)
    RubyLLM.send(:remove_const, :Content) if defined?(RubyLLM::Content)
    RubyLLM.send(:remove_const, :EmbedResult) if defined?(RubyLLM::EmbedResult)
    Object.send(:remove_const, :RubyLLM)
  end
end
