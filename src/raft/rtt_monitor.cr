# Measures round-trip time to peers and auto-tunes heartbeat/election timeouts.
#
# Only the **leader** sends `Ping` probes and computes tuned values. After
# tuning, the leader distributes a `ConfigUpdate` RPC to all peers so the
# entire cluster uses consistent timeouts (per etcd best practices).
#
# Followers passively receive `ConfigUpdate` messages — they do not probe.
# All nodes respond to `Ping` with `Pong` regardless of role.
#
# Tuning formula (from etcd):
# - Heartbeat interval = ~1.5x median RTT (clamped to 10ms–5000ms)
# - Election timeout min = 10x median RTT
# - Election timeout max = 20x median RTT
#
# Enable via `Config#rtt_tuning = true`.
class Raft::RTTMonitor
  # :nodoc:
  LOGGER = ::Log.for("raft.rtt")
  # :nodoc:
  WINDOW_SIZE = 10
  # :nodoc:
  MIN_HEARTBEAT = 10
  # :nodoc:
  MAX_HEARTBEAT = 5000
  # :nodoc:
  MAX_ELECTION_TIMEOUT = 50000

  # Per-peer RTT sample storage.
  record PeerRTT, samples : Array(Float64) = Array(Float64).new(WINDOW_SIZE)

  def initialize(@node_id : String, @transport : Transport, @config : Config,
                 @is_leader : -> Bool)
    @sequence = 0_u64
    @pending = Hash(UInt64, {String, Time::Instant}).new
    @peer_rtts = Hash(String, PeerRTT).new
    @running = false
    @peers = [] of String
  end

  # Starts the background measurement fiber.
  def start(peers : Array(String)) : Nil
    @running = true
    @peers = peers
    peers.each { |peer_id| @peer_rtts[peer_id] = PeerRTT.new }
    spawn(name: "rtt-monitor-#{@node_id}") { run }
  end

  # Stops the measurement fiber.
  def stop : Nil
    @running = false
  end

  # Called by the node when a Pong is received. Records the RTT sample.
  def record_pong(from : String, sequence : UInt64) : Nil
    if pending = @pending.delete(sequence)
      peer_id, sent_at = pending
      return unless peer_id == from
      rtt_ms = (Time.instant - sent_at).total_milliseconds
      if peer = @peer_rtts[from]?
        peer.samples << rtt_ms
        peer.samples.shift if peer.samples.size > WINDOW_SIZE
      end
    end
  end

  # Returns current RTT statistics per peer.
  def rtt_stats : Hash(String, {min: Float64, avg: Float64, max: Float64})
    result = Hash(String, {min: Float64, avg: Float64, max: Float64}).new
    @peer_rtts.each do |peer_id, peer|
      next if peer.samples.empty?
      result[peer_id] = {
        min: peer.samples.min,
        avg: peer.samples.sum / peer.samples.size,
        max: peer.samples.max,
      }
    end
    result
  end

  private def run : Nil
    while @running
      sleep @config.rtt_probe_interval.seconds
      break unless @running

      # Only the leader probes and distributes config
      next unless @is_leader.call

      # Send ping to each peer
      @peers.each do |peer_id|
        @sequence += 1
        @pending[@sequence] = {peer_id, Time.instant}
        @transport.send(peer_id, RPC::Ping.new(sequence: @sequence))
      end

      # Wait for responses
      sleep 2.seconds
      break unless @running

      # Tune and distribute
      tune_and_distribute
    end
  rescue Channel::ClosedError
  end

  private def tune_and_distribute : Nil
    all_samples = Array(Float64).new
    @peer_rtts.each_value do |peer|
      all_samples.concat(peer.samples) unless peer.samples.empty?
    end

    return if all_samples.empty?

    all_samples.sort!
    median_rtt = all_samples[all_samples.size // 2]

    heartbeat = (median_rtt * 1.5).clamp(MIN_HEARTBEAT, MAX_HEARTBEAT).to_i
    # Election timeout must be at least 10x heartbeat (etcd recommendation)
    # with a 150ms floor to tolerate GC pauses and scheduling jitter
    election_min = Math.max(heartbeat * 10, 150).clamp(150, MAX_ELECTION_TIMEOUT).to_i
    election_max = Math.max(heartbeat * 20, 300).clamp(election_min, MAX_ELECTION_TIMEOUT).to_i

    if heartbeat != @config.heartbeat_interval ||
       election_min != @config.election_timeout_min ||
       election_max != @config.election_timeout_max
      # Apply locally
      @config.heartbeat_interval = heartbeat
      @config.election_timeout_min = election_min
      @config.election_timeout_max = election_max
      LOGGER.info {
        "Tuned timeouts: median_rtt=#{median_rtt.round(1)}ms " \
        "heartbeat=#{heartbeat}ms election=#{election_min}-#{election_max}ms"
      }

      # Distribute to all peers
      update = RPC::ConfigUpdate.new(
        heartbeat_interval: heartbeat,
        election_timeout_min: election_min,
        election_timeout_max: election_max,
      )
      @peers.each { |peer_id| @transport.send(peer_id, update) }
    end
  end
end
