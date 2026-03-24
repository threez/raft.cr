# :nodoc:
module Raft::Node::Follower
  private def handle_append_entries(msg : RPC::AppendEntries) : Nil
    if msg.term < @current_term
      send_append_response(msg.leader_id, false, 0_u64)
      return
    end

    @leader_id = msg.leader_id
    become_follower unless @role.follower?
    reset_election_timer

    if msg.prev_log_index > 0_u64
      prev_term = @log.term_at(msg.prev_log_index)
      if prev_term.nil? || prev_term != msg.prev_log_term
        send_append_response(msg.leader_id, false, 0_u64)
        return
      end
    end

    @log.append(msg.entries) unless msg.entries.empty?

    if msg.leader_commit > @commit_index
      last_new = msg.entries.empty? ? msg.prev_log_index : msg.entries.last.index
      @commit_index = Math.min(msg.leader_commit, last_new)
      apply_committed_entries
    end

    match = msg.entries.empty? ? msg.prev_log_index : msg.entries.last.index
    send_append_response(msg.leader_id, true, match)
  end

  private def handle_request_vote(msg : RPC::RequestVote) : Nil
    grant = false

    if msg.term >= @current_term
      if @voted_for.nil? || @voted_for == msg.candidate_id
        if log_up_to_date?(msg.last_log_term, msg.last_log_index)
          @voted_for = msg.candidate_id
          persist_state
          reset_election_timer
          grant = true
        end
      end
    end

    @transport.send(msg.candidate_id, RPC::RequestVoteResponse.new(
      term: @current_term,
      vote_granted: grant,
    ))
  end

  private def handle_pre_vote(msg : RPC::PreVote) : Nil
    # Pre-vote: grant if candidate's speculative term >= our term
    # AND candidate log is at least as up-to-date as ours.
    # Does NOT update voted_for or reset election timer.
    grant = msg.term >= @current_term && log_up_to_date?(msg.last_log_term, msg.last_log_index)

    @transport.send(msg.candidate_id, RPC::PreVoteResponse.new(
      term: @current_term,
      vote_granted: grant,
    ))
  end

  private def handle_install_snapshot(msg : RPC::InstallSnapshot) : Nil
    if msg.term < @current_term
      @transport.send(msg.leader_id, RPC::InstallSnapshotResponse.new(term: @current_term))
      return
    end

    @leader_id = msg.leader_id
    reset_election_timer

    # Multi-chunk snapshot support
    if msg.offset == 0_u64
      @snapshot_buffer = IO::Memory.new
    end

    if buffer = @snapshot_buffer
      buffer.write(msg.data)

      if msg.done?
        snapshot_data = buffer.to_slice.dup
        @snapshot_buffer = nil
        @state_machine.restore(IO::Memory.new(snapshot_data))
        @log.save_snapshot(msg.last_included_index, msg.last_included_term, snapshot_data)
        @last_applied = msg.last_included_index if msg.last_included_index > @last_applied
        @commit_index = msg.last_included_index if msg.last_included_index > @commit_index
        @metrics.snapshots_installed += 1
        LOGGER.info { "Node #{@id} installed snapshot (index=#{msg.last_included_index})" }
      end
    end

    @transport.send(msg.leader_id, RPC::InstallSnapshotResponse.new(term: @current_term))
  end

  private def log_up_to_date?(candidate_term : UInt64, candidate_index : UInt64) : Bool
    my_term = @log.last_term
    my_index = @log.last_index
    candidate_term > my_term || (candidate_term == my_term && candidate_index >= my_index)
  end

  private def send_append_response(leader_id : String, success : Bool, match_index : UInt64) : Nil
    @transport.send(leader_id, RPC::AppendEntriesResponse.new(
      term: @current_term,
      success: success,
      match_index: match_index,
    ))
  end
end
