# frozen_string_literal: true

RSpec.describe "LLMCache Serialization" do
  # Use shared RubyLLM mock
  before(:all) do
    RubyLLMMock.setup!
  end

  before(:each) do
    LLMCache.reset_all!

    # Set up mock embedding function
    RubyLLMMock.embedding_fn = lambda { |text|
      srand(text.hash.abs)
      vec = Array.new(8) { rand }
      mag = Math.sqrt(vec.sum { |x| x * x })
      vec.map { |x| x / mag }
    }

    LLMCache.configure do |config|
      config.vector_store = :memory
      config.cache_store = :memory
      config.embedding_dimensions = 8
      config.similarity_threshold = 0.9
    end
    LLMCache.clear!
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
      result1 = LLMCache.fetch("Test query") { message }

      expect(result1).to be_a(RubyLLM::Message)
      expect(result1.content).to eq("Hello, world!")
      expect(result1.role).to eq(:assistant)
      expect(result1.model_id).to eq("gpt-4o")
      expect(result1.input_tokens).to eq(10)
      expect(result1.output_tokens).to eq(20)

      # Retrieve via fetch (cache hit)
      result2 = LLMCache.fetch("Test query") { raise "Should not execute" }

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

      LLMCache.store(
        query: "Tell me about Python",
        response: message
      )

      results = LLMCache.search("Tell me about Python", limit: 1)

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

      LLMCache.fetch("Weather query") { message }
      result = LLMCache.fetch("Weather query") { raise "Should not execute" }

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

      LLMCache.fetch("Token query") { message }
      result = LLMCache.fetch("Token query") { raise "Should not execute" }

      expect(result.input_tokens).to eq(100)
      expect(result.output_tokens).to eq(50)
      expect(result.cached_tokens).to eq(25)
      expect(result.cache_creation_tokens).to eq(10)
    end
  end

  describe "basic type serialization" do
    it "handles String responses" do
      result1 = LLMCache.fetch("String query") { "Simple string" }
      result2 = LLMCache.fetch("String query") { raise "Should not execute" }

      expect(result2).to eq("Simple string")
    end

    it "handles Hash responses" do
      hash = { key: "value", nested: { a: 1 } }

      result1 = LLMCache.fetch("Hash query") { hash }
      result2 = LLMCache.fetch("Hash query") { raise "Should not execute" }

      expect(result2).to eq(hash)
    end

    it "handles nil responses" do
      result1 = LLMCache.fetch("Nil query") { nil }
      result2 = LLMCache.fetch("Nil query") { raise "Should not execute" }

      expect(result2).to be_nil
    end

    it "handles objects with to_h" do
      obj = Struct.new(:name, :value).new("test", 42)

      result1 = LLMCache.fetch("Object query") { obj }
      result2 = LLMCache.fetch("Object query") { raise "Should not execute" }

      # Returns the hash representation
      expect(result2).to eq({ name: "test", value: 42 })
    end
  end
end
