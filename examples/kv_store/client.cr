require "http/client"
require "json"
require "uri"

# CLI client for the Raft KV store example.
#
# Usage:
#   bin/kv_client [--url URL] get <key>
#   bin/kv_client [--url URL] put <key> <value>
#   bin/kv_client [--url URL] delete <key>
#   bin/kv_client [--url URL] leader
#
# Default URL: http://127.0.0.1:8001
# Automatically follows 307 redirects to the current leader.

MAX_REDIRECTS = 3

def request(method : String, url : String, body : String? = nil, redirects = 0) : {Int32, String}
  if redirects > MAX_REDIRECTS
    return {0, "too many redirects"}
  end

  uri = URI.parse(url)
  host = uri.host || "127.0.0.1"
  port = uri.port || 8001

  client = HTTP::Client.new(host, port)
  client.connect_timeout = 5.seconds
  client.read_timeout = 10.seconds

  response = case method
             when "GET"    then client.get(uri.path || "/")
             when "PUT"    then client.put(uri.path || "/", body: body)
             when "DELETE" then client.delete(uri.path || "/")
             else               client.get(uri.path || "/")
             end

  if response.status_code == 307
    if location = response.headers["Location"]?
      return request(method, location, body, redirects + 1)
    end
  end

  {response.status_code, response.body}
ensure
  client.try(&.close)
end

# Parse arguments
base_url = "http://127.0.0.1:8001"
args = ARGV.dup
idx = args.index("--url")
if idx && idx + 1 < args.size
  base_url = args[idx + 1]
  args.delete_at(idx, 2)
end

command = args[0]?
unless command
  STDERR.puts "Usage: kv_client [--url URL] <get|put|delete|leader|status> [key] [value]"
  exit 1
end

case command
when "status"
  code, body = request("GET", "#{base_url}/_status")
  if code == 200
    json = JSON.parse(body)
    json.as_h.each do |key, value|
      puts "  #{key}: #{value}"
    end
  else
    STDERR.puts "Error #{code}: #{body}"
    exit 1
  end
when "leader"
  status, body = request("GET", "#{base_url}/_leader")
  case status
  when 204
    puts "This node is the leader"
  when 307
    puts "Leader at: #{body}"
  else
    puts "Status #{status}: #{body}"
  end
when "get"
  key = args[1]?
  unless key
    STDERR.puts "Usage: kv_client get <key>"
    exit 1
  end
  status, body = request("GET", "#{base_url}/#{key}")
  case status
  when 200
    puts body
  when 404
    STDERR.puts "Not found"
    exit 1
  else
    STDERR.puts "Error #{status}: #{body}"
    exit 1
  end
when "put"
  key = args[1]?
  value = args[2]?
  unless key && value
    STDERR.puts "Usage: kv_client put <key> <value>"
    exit 1
  end
  status, body = request("PUT", "#{base_url}/#{key}", value)
  case status
  when 201
    puts "Created"
  else
    STDERR.puts "Error #{status}: #{body}"
    exit 1
  end
when "delete"
  key = args[1]?
  unless key
    STDERR.puts "Usage: kv_client delete <key>"
    exit 1
  end
  status, body = request("DELETE", "#{base_url}/#{key}")
  case status
  when 204
    puts "Deleted"
  else
    STDERR.puts "Error #{status}: #{body}"
    exit 1
  end
else
  STDERR.puts "Unknown command: #{command}"
  STDERR.puts "Usage: kv_client [--url URL] <get|put|delete|leader|status> [key] [value]"
  exit 1
end
