#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate real test data using Ollama embeddings
# Usage: REDIS_URL=redis://localhost:6379 ruby examples/generate_test_data.rb

require "bundler/setup"
require "llm/cache"
require "json"
require "net/http"

# Ollama embedding function
def ollama_embed(text, model: "nomic-embed-text")
  uri = URI("http://localhost:11434/api/embeddings")
  http = Net::HTTP.new(uri.host, uri.port)

  request = Net::HTTP::Post.new(uri)
  request["Content-Type"] = "application/json"
  request.body = JSON.generate({ model: model, prompt: text })

  response = http.request(request)
  result = JSON.parse(response.body)
  result["embedding"]
end

# Sample Q&A data - diverse topics for semantic similarity testing
TEST_DATA = [
  # Programming questions
  {
    query: "How do I create a new Ruby class?",
    response: "To create a Ruby class, use the `class` keyword followed by the class name in CamelCase. Example:\n\nclass MyClass\n  def initialize(name)\n    @name = name\n  end\nend"
  },
  {
    query: "What is the syntax for defining a Ruby class?",
    response: "Ruby classes are defined using `class ClassName ... end`. Use `def initialize` for the constructor."
  },
  {
    query: "How do I define a method in Ruby?",
    response: 'Methods in Ruby are defined with `def method_name ... end`. Example:\n\ndef greet(name)\n  "Hello, #{name}!"\nend'
  },
  {
    query: "What's the difference between puts and print in Ruby?",
    response: "`puts` adds a newline after output, while `print` does not. Use `puts` for line-by-line output and `print` for inline output."
  },

  # Database questions
  {
    query: "How do I connect to PostgreSQL in Ruby?",
    response: "Use the `pg` gem: `require 'pg'` then `PG.connect(dbname: 'mydb')`. For Rails, configure database.yml."
  },
  {
    query: "What's the best way to connect Ruby to a Postgres database?",
    response: "The `pg` gem is the standard choice. Install with `gem install pg`, then use `PG::Connection.new` with your connection parameters."
  },
  {
    query: "How do I run a SQL query in Ruby?",
    response: "With the pg gem: `conn.exec('SELECT * FROM users')`. Always use parameterized queries: `conn.exec_params('SELECT * FROM users WHERE id = $1', [id])`"
  },

  # Web development
  {
    query: "How do I create a REST API in Ruby?",
    response: "Use Sinatra for simple APIs or Rails API mode for larger projects. Sinatra example:\n\nrequire 'sinatra'\nget '/users' do\n  User.all.to_json\nend"
  },
  {
    query: "What framework should I use for building web APIs in Ruby?",
    response: "For simple APIs, Sinatra is lightweight and fast. For complex applications, Rails API mode provides more structure. Grape is also popular for API-only projects."
  },

  # Testing
  {
    query: "How do I write tests in Ruby?",
    response: "Use RSpec or Minitest. RSpec example:\n\nRSpec.describe Calculator do\n  it 'adds numbers' do\n    expect(Calculator.add(2, 3)).to eq(5)\n  end\nend"
  },
  {
    query: "What's the best testing framework for Ruby?",
    response: "RSpec is the most popular choice with a rich DSL. Minitest is simpler and comes with Ruby. Both are excellent - RSpec for BDD style, Minitest for simplicity."
  },

  # General knowledge (different domain)
  {
    query: "What is the capital of France?",
    response: "The capital of France is Paris."
  },
  {
    query: "What city is the capital of France?",
    response: "Paris is the capital and largest city of France."
  },
  {
    query: "What is the weather like in Paris?",
    response: "Paris has a temperate oceanic climate with mild winters and warm summers. Expect occasional rain year-round."
  }
]

puts "Generating embeddings with Ollama (nomic-embed-text)..."
puts "This may take a moment...\n\n"

# Test Ollama connection
begin
  test_embedding = ollama_embed("test")
  puts "✓ Ollama connection successful (embedding dimension: #{test_embedding.length})"
rescue => e
  puts "✗ Failed to connect to Ollama: #{e.message}"
  puts "  Make sure Ollama is running: ollama serve"
  puts "  And the model is pulled: ollama pull nomic-embed-text"
  exit 1
end

# Configure LLM::Cache
LLM::Cache.configure do |config|
  config.embedding_fn = ->(text) { ollama_embed(text) }
  config.similarity_threshold = 0.85

  if ENV["REDIS_URL"]
    config.vector_store = :redis
    config.cache_store = :redis
    config.redis_url = ENV["REDIS_URL"]
    puts "✓ Using Redis backend"
  else
    puts "✓ Using Memory backend (set REDIS_URL for Redis)"
  end
end

LLM::Cache.clear!

puts "\nStoring test data..."
TEST_DATA.each_with_index do |item, i|
  LLM::Cache.store(
    query: item[:query],
    response: item[:response],
    metadata: { category: item[:query].include?("Ruby") ? "programming" : "general" }
  )
  print "."
end
puts " Done! (#{TEST_DATA.length} entries)\n\n"

# Test semantic search
puts "=" * 60
puts "Testing semantic similarity search"
puts "=" * 60

test_queries = [
  "How to make a class in Ruby?",
  "Ruby class definition syntax",
  "Connect Ruby to PostgreSQL database",
  "What's the capital city of France?",
  "Best Ruby test framework",
  "Building APIs with Ruby"
]

test_queries.each do |query|
  puts "\nQuery: \"#{query}\""
  results = LLM::Cache.search(query, limit: 3)

  if results.empty?
    puts "  No matches found"
  else
    results.each_with_index do |result, i|
      puts "  #{i + 1}. [#{(result[:similarity] * 100).round(1)}%] #{result[:query][0..60]}..."
    end
  end
end

puts "\n" + "=" * 60
puts "Cache statistics: #{LLM::Cache.stats}"
puts "=" * 60
