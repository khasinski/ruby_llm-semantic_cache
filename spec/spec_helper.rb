# frozen_string_literal: true

require "bundler/setup"
require "llm/cache"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Reset cache before each test
  config.before(:each) do
    LLM::Cache.reset!
    LLM::Cache.configure do |c|
      c.vector_store = :memory
      c.cache_store = :memory
    end
  end
end

# Helper to create fake embeddings for testing
module EmbeddingHelpers
  # Pre-defined embeddings for specific test phrases
  # These are designed to have predictable similarity relationships
  KNOWN_EMBEDDINGS = {
    # Ruby-related queries (similar to each other)
    "what is ruby?" => [0.9, 0.3, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0],
    "what is ruby" => [0.9, 0.3, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0],
    "tell me about ruby" => [0.85, 0.35, 0.15, 0.0, 0.0, 0.0, 0.0, 0.0],
    "what is ruby programming?" => [0.88, 0.32, 0.12, 0.05, 0.0, 0.0, 0.0, 0.0],
    "tell me about ruby programming" => [0.86, 0.34, 0.14, 0.04, 0.0, 0.0, 0.0, 0.0],
    "what is ruby programming" => [0.87, 0.33, 0.13, 0.045, 0.0, 0.0, 0.0, 0.0],

    # Python-related queries (similar to each other, different from Ruby)
    "what is python?" => [0.1, 0.9, 0.3, 0.0, 0.0, 0.0, 0.0, 0.0],
    "what is python" => [0.1, 0.9, 0.3, 0.0, 0.0, 0.0, 0.0, 0.0],

    # Pizza-related queries (completely different domain)
    "how do i make pizza?" => [0.0, 0.0, 0.0, 0.9, 0.3, 0.1, 0.0, 0.0],
    "how to make pizza?" => [0.0, 0.0, 0.0, 0.88, 0.32, 0.12, 0.0, 0.0],
    "how to make pizza" => [0.0, 0.0, 0.0, 0.88, 0.32, 0.12, 0.0, 0.0],

    # Programming general
    "programming" => [0.5, 0.5, 0.3, 0.0, 0.0, 0.0, 0.0, 0.0],

    # Unknown query
    "unknown query" => [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.9, 0.3],
  }.freeze

  # Generate a deterministic fake embedding based on text content
  def fake_embedding(text, dimensions: 8)
    normalized_text = text.downcase.strip

    # Check for known embeddings first
    if KNOWN_EMBEDDINGS.key?(normalized_text)
      return normalize_vector(KNOWN_EMBEDDINGS[normalized_text].dup)
    end

    # Fall back to hash-based embedding for unknown texts
    generate_hash_embedding(normalized_text, dimensions)
  end

  def generate_hash_embedding(text, dimensions)
    # Use hash to seed a deterministic embedding
    hash = text.chars.each_with_index.sum { |c, i| c.ord * (i + 1) }

    embedding = Array.new(dimensions) do |i|
      # Create a pseudo-random but deterministic value
      Math.sin(hash * (i + 1) * 0.1) * 0.5 + 0.5
    end

    normalize_vector(embedding)
  end

  def normalize_vector(vec)
    magnitude = Math.sqrt(vec.sum { |x| x * x })
    return vec if magnitude.zero?

    vec.map { |x| x / magnitude }
  end

  # Create a custom embedding function that uses our fake embeddings
  def setup_fake_embeddings(dimensions: 8)
    LLM::Cache.configure do |config|
      config.embedding_dimensions = dimensions
      config.embedding_fn = ->(text) { fake_embedding(text, dimensions: dimensions) }
    end
  end
end

RSpec.configure do |config|
  config.include EmbeddingHelpers
end
