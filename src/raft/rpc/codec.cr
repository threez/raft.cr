module Raft::RPC
  # TLV (Type-Length-Value) binary serialization for Raft RPC messages.
  #
  # Wire format: `[type: 1 byte][length: 4 bytes BigEndian][payload: N bytes]`
  #
  # Strings are length-prefixed with `UInt16 BE`, byte arrays with `UInt32 BE`,
  # booleans as a single byte (0 or 1), and integers as big-endian fixed-width.
  module Codec
    # :nodoc:
    FORMAT = IO::ByteFormat::BigEndian
    # :nodoc:
    ENTRY_HEADER_SIZE = 21 # 8 (index) + 8 (term) + 1 (type) + 4 (data_len)

    # Shared encode buffer — avoids allocating a new IO::Memory per encode.
    # Grows automatically for larger messages and retains capacity across calls.
    # Guarded by a mutex for safety under preview_mt (multi-threaded mode).
    @@encode_buf = IO::Memory.new(512)
    @@encode_mu = Mutex.new

    # Encodes an RPC message as a TLV frame and writes it to *io*.
    def self.encode(message : Message, io : IO) : Nil
      @@encode_mu.synchronize do
        @@encode_buf.clear
        encode_payload(message, @@encode_buf)
        bytes = @@encode_buf.to_slice

        io.write_byte(message.type.value)
        io.write_bytes(bytes.size.to_u32, FORMAT)
        io.write(bytes)
      end
    end

    # Encodes an RPC message and returns the TLV frame as `Bytes`.
    def self.encode(message : Message) : Bytes
      io = IO::Memory.new
      encode(message, io)
      io.to_slice
    end

    # Shared decode payload buffer — reused across calls, only grows when
    # a larger message arrives. Eliminates per-decode Bytes allocation.
    @@decode_payload = Bytes.new(512)

    # Reads a TLV frame from *io* and returns the decoded RPC message.
    #
    # Raises `Raft::Error` on unexpected EOF or unknown type tag.
    def self.decode(io : IO) : Message
      tag_byte = io.read_byte
      raise Raft::Error.new("Unexpected EOF reading type tag") unless tag_byte
      type = Type.new(tag_byte)
      length = io.read_bytes(UInt32, FORMAT).to_i
      if length > @@decode_payload.size
        @@decode_payload = Bytes.new(Math.max(length, @@decode_payload.size * 2))
      end
      buf = @@decode_payload[0, length]
      io.read_fully(buf) if length > 0
      decode_payload(type, IO::Memory.new(buf, writeable: false))
    end

    # --- Encode helpers ---

    private def self.encode_vote_fields(io : IO, msg) : Nil
      io.write_bytes(msg.term, FORMAT)
      write_string(io, msg.candidate_id)
      io.write_bytes(msg.last_log_index, FORMAT)
      io.write_bytes(msg.last_log_term, FORMAT)
    end

    private def self.encode_vote_response_fields(io : IO, msg) : Nil
      io.write_bytes(msg.term, FORMAT)
      write_bool(io, msg.vote_granted?)
    end

    private def self.encode_payload(msg : RequestVote, io : IO) : Nil
      encode_vote_fields(io, msg)
    end

    private def self.encode_payload(msg : RequestVoteResponse, io : IO) : Nil
      encode_vote_response_fields(io, msg)
    end

    private def self.encode_payload(msg : AppendEntries, io : IO) : Nil
      io.write_bytes(msg.term, FORMAT)
      write_string(io, msg.leader_id)
      io.write_bytes(msg.prev_log_index, FORMAT)
      io.write_bytes(msg.prev_log_term, FORMAT)
      write_entries(io, msg.entries)
      io.write_bytes(msg.leader_commit, FORMAT)
    end

    private def self.encode_payload(msg : AppendEntriesResponse, io : IO) : Nil
      io.write_bytes(msg.term, FORMAT)
      write_bool(io, msg.success?)
      io.write_bytes(msg.match_index, FORMAT)
    end

    private def self.encode_payload(msg : InstallSnapshot, io : IO) : Nil
      io.write_bytes(msg.term, FORMAT)
      write_string(io, msg.leader_id)
      io.write_bytes(msg.last_included_index, FORMAT)
      io.write_bytes(msg.last_included_term, FORMAT)
      io.write_bytes(msg.offset, FORMAT)
      write_bytes_field(io, msg.data)
      write_bool(io, msg.done?)
    end

    private def self.encode_payload(msg : InstallSnapshotResponse, io : IO) : Nil
      io.write_bytes(msg.term, FORMAT)
    end

    private def self.encode_payload(msg : PreVote, io : IO) : Nil
      encode_vote_fields(io, msg)
    end

    private def self.encode_payload(msg : PreVoteResponse, io : IO) : Nil
      encode_vote_response_fields(io, msg)
    end

    private def self.encode_payload(msg : Handshake, io : IO) : Nil
      io.write(msg.hmac)
      io.write(msg.nonce)
    end

    private def self.encode_payload(msg : ErrorMessage, io : IO) : Nil
      write_string(io, msg.message)
    end

    # --- Decode ---

    private def self.decode_payload(type : Type, io : IO::Memory) : Message
      buf = io.to_slice
      case type
      in .request_vote?
        RequestVote.new(
          term: read_uint64(buf, io),
          candidate_id: read_string(buf, io),
          last_log_index: read_uint64(buf, io),
          last_log_term: read_uint64(buf, io),
        )
      in .request_vote_response?
        RequestVoteResponse.new(
          term: read_uint64(buf, io),
          vote_granted: read_bool(buf, io),
        )
      in .append_entries?
        AppendEntries.new(
          term: read_uint64(buf, io),
          leader_id: read_string(buf, io),
          prev_log_index: read_uint64(buf, io),
          prev_log_term: read_uint64(buf, io),
          entries: read_entries(buf, io),
          leader_commit: read_uint64(buf, io),
        )
      in .append_entries_response?
        AppendEntriesResponse.new(
          term: read_uint64(buf, io),
          success: read_bool(buf, io),
          match_index: read_uint64(buf, io),
        )
      in .install_snapshot?
        InstallSnapshot.new(
          term: read_uint64(buf, io),
          leader_id: read_string(buf, io),
          last_included_index: read_uint64(buf, io),
          last_included_term: read_uint64(buf, io),
          offset: read_uint64(buf, io),
          data: read_bytes_field(buf, io),
          done: read_bool(buf, io),
        )
      in .install_snapshot_response?
        InstallSnapshotResponse.new(
          term: read_uint64(buf, io),
        )
      in .pre_vote?
        PreVote.new(
          term: read_uint64(buf, io),
          candidate_id: read_string(buf, io),
          last_log_index: read_uint64(buf, io),
          last_log_term: read_uint64(buf, io),
        )
      in .pre_vote_response?
        PreVoteResponse.new(
          term: read_uint64(buf, io),
          vote_granted: read_bool(buf, io),
        )
      in .handshake?
        pos = io.pos
        hmac = buf[pos, 32]
        nonce = buf[pos + 32, 32]
        io.pos += 64
        Handshake.new(hmac: hmac, nonce: nonce)
      in .error?
        ErrorMessage.new(message: read_string(buf, io))
      end
    end

    # --- Encode primitives ---

    private def self.write_string(io : IO, str : String) : Nil
      io.write_bytes(str.bytesize.to_u16, FORMAT)
      io.write(str.to_slice)
    end

    private def self.write_bool(io : IO, value : Bool) : Nil
      io.write_byte(value ? 1_u8 : 0_u8)
    end

    private def self.write_bytes_field(io : IO, data : Bytes) : Nil
      io.write_bytes(data.size.to_u32, FORMAT)
      io.write(data)
    end

    private def self.write_entries(io : IO, entries : Array(Log::Entry)) : Nil
      io.write_bytes(entries.size.to_u32, FORMAT)
      entries.each do |entry|
        io.write_bytes(entry.index, FORMAT)
        io.write_bytes(entry.term, FORMAT)
        io.write_byte(entry.entry_type.value)
        write_bytes_field(io, entry.data)
      end
    end

    # --- Decode primitives (direct buffer access) ---

    private def self.read_uint64(buf : Bytes, io : IO::Memory) : UInt64
      pos = io.pos
      io.pos += 8
      FORMAT.decode(UInt64, buf[pos, 8])
    end

    private def self.read_bool(buf : Bytes, io : IO::Memory) : Bool
      pos = io.pos
      io.pos += 1
      buf[pos] != 0_u8
    end

    private def self.read_string(buf : Bytes, io : IO::Memory) : String
      pos = io.pos
      len = FORMAT.decode(UInt16, buf[pos, 2]).to_i
      io.pos += 2
      return "" if len == 0
      String.new(len) do |str_buf|
        buf[io.pos, len].copy_to(Slice.new(str_buf, len))
        io.pos += len
        {len, len}
      end
    end

    # Zero-copy: slices directly into the payload buffer.
    private def self.read_bytes_field(buf : Bytes, io : IO::Memory) : Bytes
      pos = io.pos
      len = FORMAT.decode(UInt32, buf[pos, 4]).to_i
      io.pos += 4
      return Bytes.empty if len == 0
      data_pos = io.pos
      io.pos += len
      buf[data_pos, len]
    end

    # Zero-copy entries with direct header reads from the buffer.
    private def self.read_entries(buf : Bytes, io : IO::Memory) : Array(Log::Entry)
      pos = io.pos
      count = FORMAT.decode(UInt32, buf[pos, 4]).to_i
      io.pos += 4
      Array(Log::Entry).new(count) do
        hdr = buf[io.pos, ENTRY_HEADER_SIZE]
        io.pos += ENTRY_HEADER_SIZE
        index = FORMAT.decode(UInt64, hdr[0, 8])
        term = FORMAT.decode(UInt64, hdr[8, 8])
        entry_type = Log::EntryType.new(hdr[16])
        data_len = FORMAT.decode(UInt32, hdr[17, 4]).to_i
        data = if data_len > 0
                 data_pos = io.pos
                 io.pos += data_len
                 buf[data_pos, data_len]
               else
                 Bytes.empty
               end
        Log::Entry.new(index: index, term: term, entry_type: entry_type, data: data)
      end
    end
  end
end
