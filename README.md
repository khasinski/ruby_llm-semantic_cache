# RubyLLM::SemanticCache

Semantic caching for [RubyLLM](https://github.com/crmne/ruby_llm). Cache responses based on meaning, not exact strings.

```
"What's the capital of France?" → Cache MISS, call LLM
"What is France's capital?"     → Cache HIT (92% similar)
```

Embedding models cost ~1000x less than chat models, so every cache hit saves money.

## Installation

```ruby
gem 'ruby_llm-semantic_cache'
```

## Quick Start

```ruby
# Wrap any RubyLLM chat - caching is automatic
chat = RubyLLM::SemanticCache.wrap(RubyLLM.chat(model: "gpt-5.2"))
chat.ask("What is Ruby?")  # Calls API, caches response

# New conversation, same question = cache hit
chat2 = RubyLLM::SemanticCache.wrap(RubyLLM.chat(model: "gpt-5.2"))
chat2.ask("What is Ruby?")  # Returns cached response instantly
```

Or use the fetch API for one-off queries:

```ruby
response = RubyLLM::SemanticCache.fetch("What is Ruby?") do
  RubyLLM.chat.ask("What is Ruby?")
end
```

## How Caching Works

By default, only the **first message** of each conversation is cached. Follow-up messages go directly to the LLM because they depend on conversation context.

```ruby
chat = RubyLLM::SemanticCache.wrap(RubyLLM.chat)
chat.ask("What is Ruby?")     # Cached
chat.ask("Who created it?")   # NOT cached (context-dependent)
```

Cache keys include: **model + system prompt + message**. Different models or instructions = separate cache entries.

## Configuration

```ruby
RubyLLM::SemanticCache.configure do |config|
  # Storage (default: :memory, use :redis for production)
  config.vector_store = :redis
  config.cache_store = :redis
  config.redis_url = ENV["REDIS_URL"]

  # Similarity threshold: 0.92 = recommended, higher = stricter
  config.similarity_threshold = 0.92

  # Cache expiration (default: nil = never)
  config.ttl = 24 * 60 * 60

  # Embedding model
  config.embedding_model = "text-embedding-3-small"
  config.embedding_dimensions = 1536
end
```

## Wrapper Options

```ruby
RubyLLM::SemanticCache.wrap(chat,
  threshold: 0.95,         # Override similarity threshold
  ttl: 3600,               # Override TTL (seconds)
  max_messages: :unlimited # Cache all messages, not just first (default: 1)
  # Also accepts: false (same as :unlimited), or Integer for custom limit
  on_cache_hit: ->(chat, msg, resp) { log("Cache hit!") }
)
```

## Multi-Turn Caching

To cache entire conversation flows (not just first messages):

```ruby
chat = RubyLLM::SemanticCache.wrap(RubyLLM.chat, max_messages: :unlimited)

# Conversation 1
chat.ask("What is Ruby?")
chat.ask("Who created it?")

# Conversation 2 - identical flow hits cache
chat2 = RubyLLM::SemanticCache.wrap(RubyLLM.chat, max_messages: :unlimited)
chat2.ask("What is Ruby?")    # Cache HIT
chat2.ask("Who created it?")  # Cache HIT (same context)
```

## Rails Integration

```ruby
# config/initializers/semantic_cache.rb
RubyLLM::SemanticCache.configure do |config|
  config.vector_store = :redis
  config.cache_store = :redis
  config.redis_url = ENV["REDIS_URL"]
  config.namespace = Rails.env
end
```

## Additional APIs

```ruby
# Manual store
RubyLLM::SemanticCache.store(query: "What is Ruby?", response: message)

# Search similar
RubyLLM::SemanticCache.search("Tell me about Ruby", limit: 5)

# Check/delete
RubyLLM::SemanticCache.exists?("What is Ruby?")
RubyLLM::SemanticCache.delete("What is Ruby?")

# Stats
RubyLLM::SemanticCache.stats  # => { hits: 150, misses: 20, hit_rate: 0.88 }

# Scoped caches (for multi-tenant)
support = RubyLLM::SemanticCache::Scoped.new(namespace: "support")
sales = RubyLLM::SemanticCache::Scoped.new(namespace: "sales")
```

## Requirements

- Ruby >= 2.7
- [RubyLLM](https://github.com/crmne/ruby_llm) >= 1.0
- Redis 8+ with [neighbor-redis](https://github.com/ankane/neighbor-redis) (for production)

## License

MIT
