# :nodoc:
module Raft::Node::Leader
  private def become_leader_role : Nil
    @role = Role::Leader
    @leader_id = @id
    cancel_election_timer

    next_idx = @log.last_index + 1
    @next_index = Hash(String, UInt64).new
    @match_index = Hash(String, UInt64).new
    @peers.each do |peer|
      @next_index[peer] = next_idx
      @match_index[peer] = 0_u64
    end

    append_noop_entry
    start_replicators
    start_heartbeat_timer
    @metrics.role = "leader"
  end

  private def append_noop_entry : Nil
    entry = Log::Entry.new(
      index: @log.last_index + 1,
      term: @current_term,
      entry_type: Log::EntryType::Noop,
    )
    @log.append(entry)
  end

  private def handle_client_request_batch(reqs : Array(ClientRequest)) : Nil
    unless @role.leader?
      reqs.each do |req|
        req.response_channel.send(ClientResponse.new(
          success: false,
          data: Bytes.empty,
          leader_hint: @leader_id,
        ))
      end
      return
    end

    @metrics.batches_processed += 1
    base_index = @log.last_index + 1
    entries = reqs.map_with_index do |req, i|
      Log::Entry.new(
        index: base_index + i.to_u64,
        term: @current_term,
        entry_type: Log::EntryType::Op,
        data: req.command,
      )
    end

    @log.append(entries)
    entries.each_with_index do |entry, i|
      @pending_requests << PendingRequest.new(entry.index, reqs[i].response_channel)
    end
    notify_replicators
  end

  private def handle_client_request(req : ClientRequest) : Nil
    handle_client_request_batch([req])
  end

  private def handle_append_entries_response(from : String, msg : RPC::AppendEntriesResponse) : Nil
    return unless @role.leader?

    if msg.success?
      if msg.match_index > (@match_index[from]? || 0_u64)
        @match_index[from] = msg.match_index
        @next_index[from] = msg.match_index + 1
        advance_commit_index
        @replicators[from]?.try(&.ack(true))
      end
    else
      current = @next_index[from]? || 1_u64
      @next_index[from] = Math.max(1_u64, current - 1)
      @replicators[from]?.try(&.ack(false))
    end
  end

  private def advance_commit_index : Nil
    # Collect match indices (leader implicitly matches its own last index)
    sorted = Array(UInt64).new(@match_index.size + 1)
    @match_index.each_value { |val| sorted << val }
    sorted << @log.last_index # self
    sorted.sort!

    # The quorum-replicated index is the value at position (n - quorum).
    # E.g. for 3 nodes, quorum=2, sorted=[0,5,10] → index 1 → 5
    quorum_idx = sorted.size - quorum_size
    new_commit = sorted[quorum_idx]

    if new_commit > @commit_index && @log.term_at(new_commit) == @current_term
      @commit_index = new_commit
      @metrics.commit_index = @commit_index
      apply_committed_entries
    end
  end

  private def resolve_pending(index : UInt64, result : Bytes) : Nil
    while req = @pending_requests.first?
      break if req.index > index
      @pending_requests.shift
      if req.index == index
        @metrics.proposals_committed += 1
        req.channel.send(ClientResponse.new(success: true, data: result))
      else
        req.channel.send(ClientResponse.new(success: false, data: Bytes.empty, leader_hint: @leader_id))
      end
    end
  end

  private def reject_pending_requests : Nil
    while req = @pending_requests.shift?
      req.channel.send(ClientResponse.new(success: false, data: Bytes.empty, leader_hint: @leader_id))
    end
  end

  private def start_replicators : Nil
    @peers.each do |peer|
      next if @replicators.has_key?(peer)
      replicator = Replicator.new(
        peer_id: peer,
        node_id: @id,
        transport: @transport,
        log: @log,
        current_term: @current_term,
        next_index: @next_index,
        commit_index: pointerof(@commit_index),
        config: @config,
      )
      @replicators[peer] = replicator
      replicator.start
    end
  end

  private def stop_replicators : Nil
    @replicators.each_value(&.stop)
    @replicators.clear
  end

  private def notify_replicators : Nil
    @replicators.each_value(&.notify)
  end

  private def update_replicators_for_config : Nil
    return unless @role.leader?

    # Stop replicators for removed peers
    removed = @replicators.keys - @peers
    removed.each do |peer_id|
      @replicators[peer_id]?.try(&.stop)
      @replicators.delete(peer_id)
      @next_index.delete(peer_id)
      @match_index.delete(peer_id)
    end

    # Start replicators for new peers
    next_idx = @log.last_index + 1
    @peers.each do |peer|
      unless @replicators.has_key?(peer)
        @next_index[peer] = next_idx
        @match_index[peer] = 0_u64
        replicator = Replicator.new(
          peer_id: peer,
          node_id: @id,
          transport: @transport,
          log: @log,
          current_term: @current_term,
          next_index: @next_index,
          commit_index: pointerof(@commit_index),
          config: @config,
        )
        @replicators[peer] = replicator
        replicator.start
      end
    end
  end

  private def start_heartbeat_timer : Nil
    cancel_heartbeat_timer
    @heartbeat_epoch += 1
    epoch = @heartbeat_epoch
    spawn do
      while @running && epoch == @heartbeat_epoch
        sleep @config.heartbeat_interval.milliseconds
        if @running && epoch == @heartbeat_epoch
          notify_replicators
        end
      end
    end
  end

  private def cancel_heartbeat_timer : Nil
    @heartbeat_epoch += 1
  end
end
