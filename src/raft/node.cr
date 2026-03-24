require "log"

# A single Raft consensus node.
#
# Each node runs a single event-loop fiber that processes RPC messages,
# client requests, and timer events from a central inbox channel. State
# transitions (Follower → Candidate → Leader) happen on this fiber,
# eliminating the need for locks in the consensus core.
#
# ```
# node = Raft::Node.new(
#   id: "node-1",
#   peers: ["node-2", "node-3"],
#   state_machine: my_app,
#   transport: Raft::Transport::InMemory.new("node-1"),
#   log: Raft::Log.new,
# )
# node.start
# result = node.propose("command".to_slice)
# node.stop
# ```
class Raft::Node
  include Follower  # :nodoc:
  include Candidate # :nodoc:
  include Leader    # :nodoc:

  # :nodoc:
  LOGGER = ::Log.for("raft.node")

  # This node's unique identifier within the cluster.
  getter id : String
  # The current role of this node.
  getter role : Role
  # The ID of the node believed to be the current leader, or `nil` if unknown.
  getter leader_id : String?
  # Observable counters and state. See `Metrics`.
  getter metrics : Metrics

  # Returns the ID of the current leader, or `nil` if unknown.
  # Alias for `#leader_id`.
  def leader : String?
    @leader_id
  end

  @voted_for : String?
  @leader_id : String?
  @snapshot_buffer : IO::Memory?

  def initialize(@id : String, @peers : Array(String), @state_machine : StateMachine,
                 @transport : Transport, @log : Raft::Log, @config : Config = Config.new)
    @role = Role::Follower
    @current_term = 0_u64
    @voted_for = nil
    @commit_index = 0_u64
    @last_applied = 0_u64
    @leader_id = nil
    @inbox = Channel(NodeMessage).new(256)
    @rpc_inbox = Channel(RPC::Envelope).new(256)
    @running = false
    @election_epoch = 0_u64
    @heartbeat_epoch = 0_u64
    @replicators = Hash(String, Replicator).new
    @pending_requests = Array(PendingRequest).new
    @votes_received = Set(String).new
    @pre_votes_received = Set(String).new
    @next_index = Hash(String, UInt64).new
    @match_index = Hash(String, UInt64).new
    @snapshot_buffer = nil
    @last_snapshot_index = 0_u64
    @metrics = Metrics.new

    meta = @log.load_metadata
    @current_term = meta.current_term
    @voted_for = meta.voted_for
    @metrics.term = @current_term

    # Recover state from snapshot and/or log replay
    if snap = @log.load_snapshot
      snap_index, _snap_term, snap_data = snap
      @state_machine.restore(IO::Memory.new(snap_data))
      @last_applied = snap_index
      @commit_index = snap_index
      @last_snapshot_index = snap_index
    end
    if @log.last_index > @commit_index
      @commit_index = @log.last_index
      apply_committed_entries
    end
  end

  # Starts the node's event loop, transport, and election timer.
  #
  # Returns immediately — the consensus logic runs in background fibers.
  # Call `#stop` to shut down.
  def start : Nil
    return if @running
    @running = true
    @transport.start(@rpc_inbox)
    spawn_rpc_bridge
    reset_election_timer
    spawn_event_loop
    LOGGER.info { "Node #{@id} started" }
  end

  # Takes a snapshot of the current state machine and compacts the log.
  #
  # Called automatically when the number of applied entries since the last
  # snapshot exceeds `Config#snapshot_threshold`. Can also be called manually.
  def snapshot : Nil
    return if @last_applied == 0_u64
    return if @last_applied <= @last_snapshot_index
    data = @state_machine.snapshot
    @log.save_snapshot(@last_applied, @current_term, data)
    @last_snapshot_index = @last_applied
    @metrics.snapshots_installed += 1
    LOGGER.info { "Node #{@id} snapshot taken (index=#{@last_applied})" }
  end

  # Gracefully shuts down the node, stopping replicators and the transport.
  # Takes a final snapshot before stopping for fast recovery on restart.
  def stop : Nil
    return unless @running
    @running = false
    stop_replicators
    reject_pending_requests
    snapshot if @last_applied > @last_snapshot_index
    @transport.stop
    @inbox.close
    @rpc_inbox.close
    LOGGER.info { "Node #{@id} stopped" }
  end

  # Proposes a command to the cluster for replication.
  #
  # Blocks the calling fiber until the command is committed by a majority
  # and applied to the state machine. Returns the state machine's response.
  #
  # Raises `Error::NotLeader` if this node is not the current leader.
  # Raises `Error::Shutdown` if the node has been stopped.
  def propose(command : Bytes) : Bytes
    raise Error::Shutdown.new("Node is shut down") unless @running
    raise Error::NotLeader.new(@leader_id) unless @role.leader?

    ch = Channel(ClientResponse).new(1)
    @inbox.send(ClientRequest.new(command, ch))
    response = ch.receive
    raise Error::NotLeader.new(response.leader_hint) unless response.success?
    response.data
  end

  # Performs a linearizable read by confirming leadership via a quorum round,
  # then applying the read command directly to the state machine.
  #
  # Raises `Error::NotLeader` if this node is not the current leader.
  # Raises `Error::Shutdown` if the node has been stopped.
  def read(command : Bytes) : Bytes
    raise Error::Shutdown.new("Node is shut down") unless @running
    raise Error::NotLeader.new(@leader_id) unless @role.leader?

    propose(Bytes.empty)
    @state_machine.apply(command)
  end

  # Adds a new peer to the cluster.
  #
  # Appends a `Config` log entry with the updated peer list. The change
  # is applied immediately on the leader and replicated to followers.
  # Must be called on the leader node.
  #
  # Raises `Error::ConfigChange` if the peer already exists.
  # Raises `Error::NotLeader` if this node is not the leader.
  def add_peer(peer_id : String) : Nil
    raise Error::Shutdown.new("Node is shut down") unless @running
    raise Error::NotLeader.new(@leader_id) unless @role.leader?
    raise Error::ConfigChange.new("Peer #{peer_id} already exists") if @peers.includes?(peer_id)

    new_peers = @peers + [peer_id]
    data = encode_peers(new_peers)
    entry = Raft::Log::Entry.new(
      index: @log.last_index + 1,
      term: @current_term,
      entry_type: Raft::Log::EntryType::Config,
      data: data,
    )
    @log.append([entry])
    # Apply immediately on leader (peers update before commit for single-server changes)
    apply_config(new_peers)
    notify_replicators
  end

  # Removes a peer from the cluster.
  #
  # Appends a `Config` log entry with the updated peer list. Must be
  # called on the leader node.
  #
  # Raises `Error::ConfigChange` if the peer does not exist.
  # Raises `Error::NotLeader` if this node is not the leader.
  def remove_peer(peer_id : String) : Nil
    raise Error::Shutdown.new("Node is shut down") unless @running
    raise Error::NotLeader.new(@leader_id) unless @role.leader?
    raise Error::ConfigChange.new("Peer #{peer_id} not found") unless @peers.includes?(peer_id)

    new_peers = @peers.reject { |pid| pid == peer_id }
    data = encode_peers(new_peers)
    entry = Raft::Log::Entry.new(
      index: @log.last_index + 1,
      term: @current_term,
      entry_type: Raft::Log::EntryType::Config,
      data: data,
    )
    @log.append([entry])
    apply_config(new_peers)
    notify_replicators
  end

  private def spawn_rpc_bridge : Nil
    spawn do
      while @running
        begin
          msg = @rpc_inbox.receive
          @inbox.send(msg) if @running
        rescue Channel::ClosedError
          break
        end
      end
    end
  end

  private def spawn_event_loop : Nil
    spawn(name: "raft-node-#{@id}") do
      while @running
        begin
          msg = @inbox.receive
        rescue Channel::ClosedError
          break
        end

        unless msg.is_a?(ClientRequest)
          handle_message(msg)
          next
        end

        # Drain all queued ClientRequests into a batch. Non-client messages
        # (RPC envelopes, timer ticks) are deferred and processed first so
        # that a concurrent step-down causes the whole batch to be rejected
        # rather than appended under a stale term.
        batch = [msg] of ClientRequest
        deferred = [] of NodeMessage
        loop do
          select
          when next_msg = @inbox.receive
            if next_msg.is_a?(ClientRequest)
              batch << next_msg
            else
              deferred << next_msg
            end
          else
            break
          end
        end
        deferred.each { |deferred_msg| handle_message(deferred_msg) }
        handle_client_request_batch(batch)
      end
    end
  end

  private def handle_message(msg : NodeMessage) : Nil
    case msg
    when RPC::Envelope
      rpc = msg.message
      # PreVote/Handshake/Error messages should NOT trigger step-down
      unless rpc.is_a?(RPC::PreVote) || rpc.is_a?(RPC::PreVoteResponse) ||
             rpc.is_a?(RPC::Handshake) || rpc.is_a?(RPC::ErrorMessage)
        check_term(rpc)
      end
      dispatch_rpc(msg.from, rpc)
    when ClientRequest
      handle_client_request_batch([msg])
    when TimerTick
      handle_timer(msg)
    end
  end

  private def dispatch_rpc(from : String, msg : RPC::Message) : Nil
    case msg
    when RPC::AppendEntries           then handle_append_entries(msg)
    when RPC::AppendEntriesResponse   then handle_append_entries_response(from, msg)
    when RPC::RequestVote             then handle_request_vote(msg)
    when RPC::RequestVoteResponse     then handle_request_vote_response(from, msg)
    when RPC::InstallSnapshot         then handle_install_snapshot(msg)
    when RPC::InstallSnapshotResponse then nil
    when RPC::PreVote                 then handle_pre_vote(msg)
    when RPC::PreVoteResponse         then handle_pre_vote_response(from, msg)
    when RPC::Handshake               then nil # consumed during connection setup
    when RPC::ErrorMessage            then nil # consumed during connection setup
    end
  end

  private def check_term(msg : RPC::Message) : Nil
    term = msg.term
    if term > @current_term
      step_down(term)
    end
  end

  private def step_down(new_term : UInt64) : Nil
    LOGGER.debug { "Node #{@id} stepping down (term #{@current_term} → #{new_term})" }
    @current_term = new_term
    @voted_for = nil
    @leader_id = nil
    become_follower unless @role.follower?
    persist_state
    @metrics.term = @current_term
  end

  private def become_follower : Nil
    was_leader = @role.leader?
    @role = Role::Follower
    @metrics.role = "follower"
    if was_leader
      stop_replicators
      reject_pending_requests
      cancel_heartbeat_timer
    end
    reset_election_timer
  end

  private def persist_state : Nil
    @log.save_metadata(Raft::Log::Metadata.new(
      current_term: @current_term,
      voted_for: @voted_for,
    ))
  end

  private def apply_committed_entries : Nil
    return if @last_applied >= @commit_index

    entries = @log.slice(@last_applied + 1, @commit_index)
    op_indices = [] of UInt64
    op_commands = [] of Bytes

    flush = -> {
      return if op_commands.empty?
      results = @state_machine.apply_batch(op_commands)
      if @role.leader?
        op_indices.each_with_index { |idx, i| resolve_pending(idx, results[i]) }
      end
      op_indices.clear
      op_commands.clear
    }

    entries.each do |entry|
      @last_applied = entry.index
      @metrics.entries_applied += 1
      if entry.entry_type.op?
        op_indices << entry.index
        op_commands << entry.data
      elsif entry.entry_type.noop?
        flush.call
        resolve_pending(entry.index, Bytes.empty) if @role.leader?
      elsif entry.entry_type.config?
        flush.call
        new_peers = decode_peers(entry.data)
        apply_config(new_peers) unless @role.leader? # leader already applied on propose
      end
    end

    flush.call

    # Auto-snapshot when threshold is exceeded
    threshold = @config.snapshot_threshold
    if threshold > 0 && (@last_applied - @last_snapshot_index) >= threshold.to_u64
      snapshot
    end
  end

  private def apply_config(new_peers : Array(String)) : Nil
    @peers = new_peers
    LOGGER.info { "Node #{@id} config updated: peers=#{@peers}" }
    update_replicators_for_config if @role.leader?
  end

  private def encode_peers(peers : Array(String)) : Bytes
    io = IO::Memory.new
    io.write_bytes(peers.size.to_u32, IO::ByteFormat::BigEndian)
    peers.each do |peer_id|
      io.write_bytes(peer_id.bytesize.to_u16, IO::ByteFormat::BigEndian)
      io.write(peer_id.to_slice)
    end
    io.to_slice
  end

  private def decode_peers(data : Bytes) : Array(String)
    io = IO::Memory.new(data)
    count = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
    Array(String).new(count.to_i) do
      len = io.read_bytes(UInt16, IO::ByteFormat::BigEndian)
      buf = Bytes.new(len)
      io.read_fully(buf) if len > 0
      String.new(buf)
    end
  end

  private def reset_election_timer : Nil
    @election_epoch += 1
    epoch = @election_epoch
    spawn do
      ms = rand(@config.election_timeout_min..@config.election_timeout_max)
      sleep ms.milliseconds
      if @running && epoch == @election_epoch
        @inbox.send(TimerTick.new(TimerTick::Kind::Election, epoch)) rescue nil
      end
    end
  end

  private def cancel_election_timer : Nil
    @election_epoch += 1
  end

  private def handle_timer(tick : TimerTick) : Nil
    case tick.kind
    when .election?
      return unless tick.epoch == @election_epoch
      start_pre_vote if @role.follower? || @role.candidate?
    when .heartbeat?
      notify_replicators if @role.leader?
    end
  end
end
