# Per-peer log replication fiber with pipelined AppendEntries.
#
# Each replicator runs in its own fiber and sends `AppendEntries` RPCs to a
# single follower. It maintains an optimistic `@pipeline_next_index` cursor
# that can run ahead of the confirmed `@next_index`, allowing up to
# `Config#max_inflight_rpcs` batches to be in-flight simultaneously. The
# leader event loop signals each ack back via `#ack` so the replicator can
# send the next batch without waiting for the heartbeat timeout.
#
# When the follower is too far behind, the replicator sends the snapshot in
# chunks via `InstallSnapshot` and resets the pipeline cursor.
class Raft::Node::Replicator
  def initialize(@peer_id : String, @node_id : String, @transport : Transport,
                 @log : Log, @current_term : UInt64,
                 @next_index : Hash(String, UInt64),
                 @commit_index : Pointer(UInt64),
                 @config : Config)
    @notify_channel = Channel(Nil).new(1)
    @ack_channel = Channel(Bool).new(@config.max_inflight_rpcs)
    @pipeline_next_index = 1_u64
    @inflight = 0
    @running = false
  end

  def start : Nil
    @running = true
    spawn(name: "replicator-#{@peer_id}") { run }
  end

  def stop : Nil
    @running = false
    @notify_channel.close
    @ack_channel.close
  end

  def notify : Nil
    select
    when @notify_channel.send(nil)
    else
    end
  end

  # Called by the leader event loop after each `AppendEntriesResponse`.
  # *success* false resets the pipeline cursor to the last confirmed position.
  def ack(success : Bool) : Nil
    select
    when @ack_channel.send(success)
    else # channel full — replicator will reset on next loop iteration
    end
  end

  private def run : Nil
    @pipeline_next_index = @next_index[@peer_id]? || 1_u64
    @inflight = 0
    awaiting_snapshot_ack = false

    while @running
      confirmed_next = @next_index[@peer_id]? || 1_u64

      # Check if follower is behind the snapshot
      if !awaiting_snapshot_ack
        if snapshot = @log.load_snapshot
          snap_index, snap_term, snap_data = snapshot
          if confirmed_next <= snap_index
            send_snapshot(snap_index, snap_term, snap_data)
            @next_index[@peer_id] = snap_index + 1
            @pipeline_next_index = snap_index + 1
            @inflight = 0
            awaiting_snapshot_ack = true
          end
        end
      end

      # Keep pipeline cursor in sync — advances on success acks, resets on failure
      @pipeline_next_index = confirmed_next if @pipeline_next_index < confirmed_next

      last_idx = @log.last_index
      if @pipeline_next_index <= last_idx
        # Send pipelined batches until the pipeline is full or all entries are sent
        while @inflight < @config.max_inflight_rpcs && @pipeline_next_index <= last_idx
          send_pipeline_batch
          @inflight += 1
        end
      elsif @inflight == 0
        # Nothing in-flight and no new entries — send a periodic heartbeat
        send_heartbeat
      end

      select
      when @notify_channel.receive
      when result = @ack_channel.receive
        @inflight = {@inflight - 1, 0}.max
        if result
          awaiting_snapshot_ack = false
        else
          # Failure: reset pipeline to confirmed position; any remaining in-flight
          # RPCs will also fail, and their acks decrement from 0 (clamped by max above)
          @pipeline_next_index = @next_index[@peer_id]? || 1_u64
          @inflight = 0
        end
      when timeout(@config.heartbeat_interval.milliseconds)
        awaiting_snapshot_ack = false # timeout expired, allow retry
      end
    end
  rescue Channel::ClosedError
  end

  # Send one pipelined batch starting at @pipeline_next_index and advance the cursor.
  private def send_pipeline_batch : Nil
    prev_idx = @pipeline_next_index > 1 ? @pipeline_next_index - 1 : 0_u64
    prev_term = prev_idx > 0 ? (@log.term_at(prev_idx) || 0_u64) : 0_u64
    last_idx = @log.last_index
    entries_end = Math.min(last_idx, @pipeline_next_index + @config.max_entries_per_rpc.to_u64 - 1)
    entries = @log.slice(@pipeline_next_index, entries_end)

    @transport.send(@peer_id, RPC::AppendEntries.new(
      term: @current_term,
      leader_id: @node_id,
      prev_log_index: prev_idx,
      prev_log_term: prev_term,
      entries: entries,
      leader_commit: @commit_index.value,
    ))
    @pipeline_next_index = entries.last.index + 1 unless entries.empty?
  end

  # Send an empty AppendEntries heartbeat anchored to the confirmed next_index.
  private def send_heartbeat : Nil
    confirmed_next = @next_index[@peer_id]? || 1_u64
    prev_idx = confirmed_next > 1 ? confirmed_next - 1 : 0_u64
    prev_term = prev_idx > 0 ? (@log.term_at(prev_idx) || 0_u64) : 0_u64

    @transport.send(@peer_id, RPC::AppendEntries.new(
      term: @current_term,
      leader_id: @node_id,
      prev_log_index: prev_idx,
      prev_log_term: prev_term,
      entries: [] of Log::Entry,
      leader_commit: @commit_index.value,
    ))
  end

  private def send_snapshot(last_index : UInt64, last_term : UInt64, data : Bytes) : Nil
    chunk_size = @config.snapshot_chunk_size
    offset = 0_u64

    while offset < data.size
      remaining = data.size - offset
      chunk_len = Math.min(remaining, chunk_size)
      chunk = data[offset, chunk_len]
      is_done = (offset + chunk_len) >= data.size

      msg = RPC::InstallSnapshot.new(
        term: @current_term,
        leader_id: @node_id,
        last_included_index: last_index,
        last_included_term: last_term,
        offset: offset,
        data: chunk,
        done: is_done,
      )

      @transport.send(@peer_id, msg)
      offset += chunk_len

      # Small yield to avoid blocking the scheduler
      Fiber.yield unless is_done
    end

    # Handle case of empty snapshot data
    if data.empty?
      msg = RPC::InstallSnapshot.new(
        term: @current_term,
        leader_id: @node_id,
        last_included_index: last_index,
        last_included_term: last_term,
        offset: 0_u64,
        data: Bytes.empty,
        done: true,
      )
      @transport.send(@peer_id, msg)
    end
  end
end
