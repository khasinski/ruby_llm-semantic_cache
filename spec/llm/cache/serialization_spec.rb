# frozen_string_literal: true

RSpec.describe "LLM::Cache Serialization" do
  # Mock RubyLLM classes for testing
  before(:all) do
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
      end
    end
  end

  before(:each) do
    LLM::Cache.reset!
    LLM::Cache.configure do |config|
      config.vector_store = :memory
      config.cache_store = :memory
      config.embedding_dimensions = 8
      config.similarity_threshold = 0.9
      config.embedding_fn = lambda { |text|
        srand(text.hash.abs)
        vec = Array.new(8) { rand }
        mag = Math.sqrt(vec.sum { |x| x * x })
        vec.map { |x| x / mag }
      }
    end
    LLM::Cache.clear!
  end

  describe "RubyLLM::Message serialization" do
    it "serializes and deserializes Message objects via fetch" do
      message = RubyLLM::Message.new(
        role: :assistant,
        content: "Hello, world!",
        model_id: "gpt-4o",
        input_tokens: 10,
        output_tokens: 20
      )

      # Store via fetch
      result1 = LLM::Cache.fetch("Test query") { message }

      expect(result1).to be_a(RubyLLM::Message)
      expect(result1.content).to eq("Hello, world!")
      expect(result1.role).to eq(:assistant)
      expect(result1.model_id).to eq("gpt-4o")
      expect(result1.input_tokens).to eq(10)
      expect(result1.output_tokens).to eq(20)

      # Retrieve via fetch (cache hit)
      result2 = LLM::Cache.fetch("Test query") { raise "Should not execute" }

      expect(result2).to be_a(RubyLLM::Message)
      expect(result2.content).to eq("Hello, world!")
      expect(result2.role).to eq(:assistant)
    end

    it "serializes and deserializes Message via store/search" do
      message = RubyLLM::Message.new(
        role: :assistant,
        content: "Python is great",
        model_id: "gpt-4"
      )

      LLM::Cache.store(
        query: "Tell me about Python",
        response: message
      )

      results = LLM::Cache.search("Tell me about Python", limit: 1)

      expect(results).not_to be_empty
      expect(results.first[:response]).to be_a(RubyLLM::Message)
      expect(results.first[:response].content).to eq("Python is great")
    end

    it "handles Message with tool_calls" do
      tool_calls = { "call_123" => { name: "get_weather", arguments: { city: "NYC" } } }

      message = RubyLLM::Message.new(
        role: :assistant,
        content: "Let me check the weather",
        tool_calls: tool_calls
      )

      LLM::Cache.fetch("Weather query") { message }
      result = LLM::Cache.fetch("Weather query") { raise "Should not execute" }

      expect(result.tool_calls).to eq(tool_calls)
    end

    it "handles Message with all token fields" do
      message = RubyLLM::Message.new(
        role: :assistant,
        content: "Response",
        input_tokens: 100,
        output_tokens: 50,
        cached_tokens: 25,
        cache_creation_tokens: 10
      )

      LLM::Cache.fetch("Token query") { message }
      result = LLM::Cache.fetch("Token query") { raise "Should not execute" }

      expect(result.input_tokens).to eq(100)
      expect(result.output_tokens).to eq(50)
      expect(result.cached_tokens).to eq(25)
      expect(result.cache_creation_tokens).to eq(10)
    end
  end

  describe "basic type serialization" do
    it "handles String responses" do
      result1 = LLM::Cache.fetch("String query") { "Simple string" }
      result2 = LLM::Cache.fetch("String query") { raise "Should not execute" }

      expect(result2).to eq("Simple string")
    end

    it "handles Hash responses" do
      hash = { key: "value", nested: { a: 1 } }

      result1 = LLM::Cache.fetch("Hash query") { hash }
      result2 = LLM::Cache.fetch("Hash query") { raise "Should not execute" }

      expect(result2).to eq(hash)
    end

    it "handles nil responses" do
      result1 = LLM::Cache.fetch("Nil query") { nil }
      result2 = LLM::Cache.fetch("Nil query") { raise "Should not execute" }

      expect(result2).to be_nil
    end

    it "handles objects with to_h" do
      obj = Struct.new(:name, :value).new("test", 42)

      result1 = LLM::Cache.fetch("Object query") { obj }
      result2 = LLM::Cache.fetch("Object query") { raise "Should not execute" }

      # Returns the hash representation
      expect(result2).to eq({ name: "test", value: 42 })
    end
  end
end
