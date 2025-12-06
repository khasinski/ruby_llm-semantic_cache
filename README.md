# LLM::Cache

Semantic caching for Ruby LLM applications. Cache LLM responses based on **semantic similarity**, not exact string matching.

When a user asks "What's the capital of France?" and later asks "Tell me France's capital city", the cache recognizes these as semantically equivalent and returns the cached response.

## Features

- **Semantic matching** - Uses embeddings to find similar queries, not just exact matches
- **Cost savings** - Avoid redundant LLM API calls
- **Reduced latency** - Cached responses return in milliseconds
- **Multiple backends** - Redis or in-memory storage
- **RubyLLM middleware** - Wrap RubyLLM::Chat for transparent caching
- **Works with any LLM client** - RubyLLM, ruby-openai, or custom

## Installation

Add to your Gemfile:

```ruby
gem 'llm-cache'

# For Redis backend (optional)
gem 'neighbor-redis'
gem 'redis-client'
```

## Quick Start

```ruby
require 'llm/cache'
require 'ruby_llm'

# Configure (uses in-memory store by default)
LLM::Cache.configure do |config|
  config.similarity_threshold = 0.92  # How similar queries must be to match
end

# Wrap your LLM calls
response = LLM::Cache.fetch("What is the capital of France?") do
  RubyLLM.chat.ask("What is the capital of France?")
end

# Second call returns cached response (no API call)
response = LLM::Cache.fetch("Tell me France's capital") do
  RubyLLM.chat.ask("Tell me France's capital")  # Never executed!
end
```

## Configuration

```ruby
LLM::Cache.configure do |config|
  # Storage backends: :memory (default) or :redis
  config.vector_store = :redis
  config.cache_store = :redis

  # Redis connection
  config.redis_url = ENV["REDIS_URL"]

  # Embedding settings (for RubyLLM)
  config.embedding_model = "text-embedding-3-small"
  config.embedding_dimensions = 1536

  # Similarity threshold (0.0 to 1.0)
  # Higher = stricter matching, fewer cache hits
  # Lower = looser matching, more hits but risk of wrong matches
  config.similarity_threshold = 0.92

  # Cache TTL (nil = no expiration)
  config.ttl = 24 * 60 * 60  # 24 hours in seconds

  # Namespace (for multi-tenant apps)
  config.namespace = "my_app"

  # Custom embedding function (optional)
  config.embedding_fn = ->(text) {
    # Return array of floats
    MyEmbeddingService.embed(text)
  }
end
```

## Usage

### Basic Fetch

```ruby
response = LLM::Cache.fetch("What is Ruby?") do
  expensive_llm_call("What is Ruby?")
end
```

### With Options

```ruby
response = LLM::Cache.fetch(query, threshold: 0.95, ttl: 3600) do
  llm.ask(query)
end
```

### Manual Store

```ruby
LLM::Cache.store(
  query: "What is Ruby?",
  response: "Ruby is a dynamic programming language...",
  metadata: { model: "gpt-4", tokens: 150 }
)
```

### Search Similar

```ruby
matches = LLM::Cache.search("Tell me about Ruby", limit: 5)
# => [{ query: "What is Ruby?", response: "...", similarity: 0.94, metadata: {...} }, ...]
```

### Check Existence

```ruby
LLM::Cache.exists?("What is Ruby?")  # => true
```

### Delete Entry

```ruby
LLM::Cache.delete("What is Ruby?")
```

### Statistics

```ruby
LLM::Cache.stats
# => { hits: 150, misses: 20, hit_rate: 0.88, entries: 170 }
```

### Scoped Caches

```ruby
support_cache = LLM::Cache.new(namespace: "support")
sales_cache = LLM::Cache.new(namespace: "sales")

support_cache.fetch("How to reset password?") { ... }
sales_cache.fetch("What are pricing plans?") { ... }
```

## RubyLLM Middleware

For the cleanest integration with RubyLLM, use the middleware wrapper:

```ruby
require 'llm/cache'
require 'ruby_llm'

# Create a chat and wrap it with caching
chat = RubyLLM.chat(model: "gpt-4o")
cached_chat = LLM::Cache.wrap(chat)

# Use it like a normal chat - caching happens automatically
response = cached_chat.ask("What is Ruby?")
# => RubyLLM::Message with the answer

# Second identical query returns cached response instantly
response = cached_chat.ask("What is Ruby?")
# => Same RubyLLM::Message, no API call made
```

### Context-Aware Caching

The middleware includes system instructions in the cache key, so different contexts get different cached responses:

```ruby
formal_chat = RubyLLM.chat.with_instructions("Be formal and professional")
casual_chat = RubyLLM.chat.with_instructions("Be casual and friendly")

cached_formal = LLM::Cache.wrap(formal_chat)
cached_casual = LLM::Cache.wrap(casual_chat)

# These are cached separately because of different system instructions
cached_formal.ask("Hello")  # Formal response
cached_casual.ask("Hello")  # Casual response
```

### Caching Behavior

The middleware automatically skips caching for:
- **Streaming requests** - When a block is given to `ask`
- **Requests with attachments** - Images, files, etc.
- **Tool-enabled chats** - When tools are registered (responses may vary)

```ruby
cached_chat = LLM::Cache.wrap(chat)

# Streaming - not cached
cached_chat.ask("Count to 10") { |chunk| print chunk.content }

# With attachments - not cached
cached_chat.ask("Describe this", with: image_path)

# With tools - not cached
chat_with_tools = RubyLLM.chat.with_tool(MyTool)
LLM::Cache.wrap(chat_with_tools).ask("Use the tool")
```

### Custom Threshold and TTL

```ruby
# Override defaults per-wrapper
cached_chat = LLM::Cache.wrap(chat, threshold: 0.95, ttl: 3600)
```

## Using with ruby-openai

```ruby
require 'llm/cache'
require 'openai'

client = OpenAI::Client.new

LLM::Cache.configure do |config|
  config.embedding_fn = ->(text) {
    response = client.embeddings(
      parameters: { model: "text-embedding-3-small", input: text }
    )
    response.dig("data", 0, "embedding")
  }
end

LLM::Cache.fetch("Explain quantum computing") do
  client.chat(parameters: {
    model: "gpt-4",
    messages: [{ role: "user", content: "Explain quantum computing" }]
  })
end
```

## Rails Integration

```ruby
# config/initializers/llm_cache.rb
LLM::Cache.configure do |config|
  config.vector_store = :redis
  config.cache_store = :redis
  config.redis_url = ENV["REDIS_URL"]
  config.similarity_threshold = 0.92
  config.ttl = 7.days.to_i
  config.namespace = Rails.env
end

# app/services/ai_assistant.rb
class AIAssistant
  def answer(question)
    LLM::Cache.fetch(question) do
      RubyLLM.chat.ask(question)
    end
  end
end
```

## Testing

Use the in-memory backend for tests:

```ruby
# spec/spec_helper.rb
RSpec.configure do |config|
  config.before(:each) do
    LLM::Cache.configure do |c|
      c.vector_store = :memory
      c.cache_store = :memory
      c.embedding_fn = ->(text) { Array.new(8) { rand } }  # Fake embeddings
    end
    LLM::Cache.clear!
  end
end
```

## Similarity Threshold Guide

| Threshold | Behavior |
|-----------|----------|
| 0.98-1.0 | Very strict, near-exact matches only |
| 0.92-0.97 | Balanced, catches paraphrases |
| 0.85-0.91 | Loose, higher hit rate but risk of mismatches |
| < 0.85 | Too loose, likely wrong answers |

Start with **0.92** and adjust based on your use case.

## Cost Analysis

Embedding generation has minimal cost compared to LLM calls:

```
Embedding: ~$0.00002 per 1K tokens (text-embedding-3-small)
GPT-4: ~$0.03 per 1K input tokens + $0.06 per 1K output tokens

For a 50-token query with 200-token response:
- Embedding: $0.000001
- GPT-4: $0.0135

Cache is cost-effective if hit rate > 0.01% (almost always worth it)
```

## Requirements

- Ruby >= 2.7.0
- Redis 7+ (for Redis backend with vector search)
- [neighbor-redis](https://github.com/ankane/neighbor-redis) (for Redis backend)
- [RubyLLM](https://github.com/crmne/ruby_llm) (for default embeddings)

## License

MIT License
