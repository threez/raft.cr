# :nodoc:
module Raft::Node::Candidate
  private def start_pre_vote : Nil
    @pre_votes_received = Set(String).new
    @pre_votes_received << @id # count self

    reset_election_timer

    @voters.each do |peer|
      @transport.send(peer, RPC::PreVote.new(
        term: @current_term + 1, # speculative next term, don't actually increment
        candidate_id: @id,
        last_log_index: @log.last_index,
        last_log_term: @log.last_term,
      ))
    end

    check_pre_vote_won
  end

  private def handle_pre_vote_response(from : String, msg : RPC::PreVoteResponse) : Nil
    return unless @role.follower? || @role.candidate?

    if msg.vote_granted?
      @pre_votes_received << from
      check_pre_vote_won
    end
  end

  private def check_pre_vote_won : Nil
    if @pre_votes_received.size >= quorum_size
      start_election
    end
  end

  private def start_election : Nil
    @role = Role::Candidate
    @current_term += 1
    @voted_for = @id
    @leader_id = nil
    persist_state

    LOGGER.info { "Node #{@id} starting election (term=#{@current_term})" }
    @metrics.elections_started += 1

    @votes_received = Set(String).new
    @votes_received << @id

    reset_election_timer

    @voters.each do |peer|
      @transport.send(peer, RPC::RequestVote.new(
        term: @current_term,
        candidate_id: @id,
        last_log_index: @log.last_index,
        last_log_term: @log.last_term,
      ))
    end

    check_election_won
  end

  private def handle_request_vote_response(from : String, msg : RPC::RequestVoteResponse) : Nil
    return unless @role.candidate?
    return unless msg.term == @current_term

    if msg.vote_granted?
      @votes_received << from
      check_election_won
    end
  end

  private def quorum_size : Int32
    total = @voters.size + 1 # voters + self
    if @config.active_passive? && total == 2
      1
    else
      total // 2 + 1
    end
  end

  private def check_election_won : Nil
    if @votes_received.size >= quorum_size
      LOGGER.info { "Node #{@id} elected leader (term=#{@current_term})" }
      @metrics.elections_won += 1
      become_leader_role
    end
  end
end
