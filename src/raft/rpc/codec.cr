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

    # Reads a TLV frame from *io* and returns the decoded RPC message.
    #
    # Raises `Raft::Error` on unexpected EOF or unknown type tag.
    def self.decode(io : IO) : Message
      tag_byte = io.read_byte
      raise Raft::Error.new("Unexpected EOF reading type tag") unless tag_byte
      type = Type.new(tag_byte)
      io.read_bytes(UInt32, FORMAT) # consume TLV length (fields are self-delimiting)
      decode_payload(type, io)
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

    private def self.decode_payload(type : Type, io : IO) : Message
      case type
      in .request_vote?
        RequestVote.new(
          term: io.read_bytes(UInt64, FORMAT),
          candidate_id: read_string(io),
          last_log_index: io.read_bytes(UInt64, FORMAT),
          last_log_term: io.read_bytes(UInt64, FORMAT),
        )
      in .request_vote_response?
        RequestVoteResponse.new(
          term: io.read_bytes(UInt64, FORMAT),
          vote_granted: read_bool(io),
        )
      in .append_entries?
        AppendEntries.new(
          term: io.read_bytes(UInt64, FORMAT),
          leader_id: read_string(io),
          prev_log_index: io.read_bytes(UInt64, FORMAT),
          prev_log_term: io.read_bytes(UInt64, FORMAT),
          entries: read_entries(io),
          leader_commit: io.read_bytes(UInt64, FORMAT),
        )
      in .append_entries_response?
        AppendEntriesResponse.new(
          term: io.read_bytes(UInt64, FORMAT),
          success: read_bool(io),
          match_index: io.read_bytes(UInt64, FORMAT),
        )
      in .install_snapshot?
        InstallSnapshot.new(
          term: io.read_bytes(UInt64, FORMAT),
          leader_id: read_string(io),
          last_included_index: io.read_bytes(UInt64, FORMAT),
          last_included_term: io.read_bytes(UInt64, FORMAT),
          offset: io.read_bytes(UInt64, FORMAT),
          data: read_bytes_field(io),
          done: read_bool(io),
        )
      in .install_snapshot_response?
        InstallSnapshotResponse.new(
          term: io.read_bytes(UInt64, FORMAT),
        )
      in .pre_vote?
        PreVote.new(
          term: io.read_bytes(UInt64, FORMAT),
          candidate_id: read_string(io),
          last_log_index: io.read_bytes(UInt64, FORMAT),
          last_log_term: io.read_bytes(UInt64, FORMAT),
        )
      in .pre_vote_response?
        PreVoteResponse.new(
          term: io.read_bytes(UInt64, FORMAT),
          vote_granted: read_bool(io),
        )
      in .handshake?
        hmac, nonce = if io.is_a?(IO::Memory)
                        pos = io.pos
                        io.pos += 64
                        {io.to_slice[pos, 32], io.to_slice[pos + 32, 32]}
                      else
                        h = Bytes.new(32)
                        io.read_fully(h)
                        n = Bytes.new(32)
                        io.read_fully(n)
                        {h, n}
                      end
        Handshake.new(hmac: hmac, nonce: nonce)
      in .error?
        ErrorMessage.new(message: read_string(io))
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

    # --- Decode primitives ---

    private def self.read_bool(io : IO) : Bool
      byte = io.read_byte
      raise Raft::Error.new("Unexpected EOF reading bool") unless byte
      byte != 0_u8
    end

    private def self.read_string(io : IO) : String
      len = io.read_bytes(UInt16, FORMAT).to_i
      return "" if len == 0
      String.new(len) do |buf|
        io.read_fully(Slice.new(buf, len))
        {len, len}
      end
    end

    private def self.read_bytes_field(io : IO) : Bytes
      len = io.read_bytes(UInt32, FORMAT).to_i
      return Bytes.empty if len == 0
      # Zero-copy: if reading from an in-memory buffer, slice directly
      # instead of allocating. Avoids per-entry allocation for AppendEntries
      # and per-chunk allocation for InstallSnapshot.
      if io.is_a?(IO::Memory)
        pos = io.pos
        io.pos += len
        io.to_slice[pos, len]
      else
        slice = Bytes.new(len)
        io.read_fully(slice)
        slice
      end
    end

    private def self.read_entries(io : IO) : Array(Log::Entry)
      count = io.read_bytes(UInt32, FORMAT)
      if io.is_a?(IO::Memory)
        # Fast path: read entry headers directly from buffer, zero-copy data
        buf = io.to_slice
        Array(Log::Entry).new(count.to_i) do
          hdr = buf[io.pos, ENTRY_HEADER_SIZE]
          io.pos += ENTRY_HEADER_SIZE
          index = FORMAT.decode(UInt64, hdr[0, 8])
          term = FORMAT.decode(UInt64, hdr[8, 8])
          entry_type = Log::EntryType.new(hdr[16])
          data_len = FORMAT.decode(UInt32, hdr[17, 4]).to_i
          data = if data_len > 0
                   pos = io.pos
                   io.pos += data_len
                   buf[pos, data_len]
                 else
                   Bytes.empty
                 end
          Log::Entry.new(index: index, term: term, entry_type: entry_type, data: data)
        end
      else
        Array(Log::Entry).new(count.to_i) do
          index = io.read_bytes(UInt64, FORMAT)
          term = io.read_bytes(UInt64, FORMAT)
          type_byte = io.read_byte
          raise Raft::Error.new("Unexpected EOF reading entry type") unless type_byte
          entry_type = Log::EntryType.new(type_byte)
          data = read_bytes_field(io)
          Log::Entry.new(index: index, term: term, entry_type: entry_type, data: data)
        end
      end
    end
  end
end
