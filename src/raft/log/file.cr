# On-disk log storage backend with crash recovery.
#
# Stores log entries in an append-only binary file (`log.bin`), metadata in
# `metadata.bin`, and snapshots in `snapshot.bin`. All multi-byte integers
# use big-endian encoding. Metadata and snapshot files are written atomically
# via tmp+rename.
#
# Entry record format: `[Index:8B][Term:8B][Type:1B][DataLen:4B][Data:NB]`
#
# By default every write is followed by an `fsync(2)` syscall so that entries
# are durable against power loss or kernel panics. Pass `fsync: false` to skip
# the syscall and rely on OS page-cache writeback instead — acceptable when an
# external restore path exists (replicated block storage, periodic backups, or
# a peer that always holds the full log).
#
# ```
# log = Raft::Log::File.new("/var/lib/raft/node-1")               # fsync on (default)
# log = Raft::Log::File.new("/var/lib/raft/node-1", fsync: false) # page-cache only
# ```
class Raft::Log::File < Raft::Log
  # :nodoc:
  RECORD_HEADER_SIZE = 21 # 8 (index) + 8 (term) + 1 (type) + 4 (data_len)
  # :nodoc:
  FORMAT = IO::ByteFormat::BigEndian

  # Creates a new file-backed log in the given *data_dir*.
  #
  # The directory is created if it doesn't exist. On startup, the log
  # file is scanned to rebuild the in-memory offset index.
  def initialize(@data_dir : String, @fsync : Bool = true)
    Dir.mkdir_p(@data_dir) unless Dir.exists?(@data_dir)
    @log_path = ::File.join(@data_dir, "log.bin")
    @meta_path = ::File.join(@data_dir, "metadata.bin")
    @snapshot_path = ::File.join(@data_dir, "snapshot.bin")
    @offsets = Hash(UInt64, Int64).new
    @last_index = 0_u64
    @last_term = 0_u64
    ::File.touch(@log_path) unless ::File.exists?(@log_path)
    @log_file = ::File.open(@log_path, "r+b")
    rebuild_index
    @log_file.seek(0, IO::Seek::End)
  end

  def append(entry : Entry) : Nil
    if @offsets.has_key?(entry.index)
      existing_term = read_term_at_offset(@offsets[entry.index])
      if existing_term != entry.term
        truncate_from(entry.index)
      else
        return
      end
    end
    write_entry(entry)
  end

  def append(entries : Array(Entry)) : Nil
    dirty = false
    entries.each do |entry|
      if @offsets.has_key?(entry.index)
        existing_term = read_term_at_offset(@offsets[entry.index])
        if existing_term != entry.term
          truncate_from(entry.index)
        else
          next
        end
      end
      write_entry(entry, sync: false)
      dirty = true
    end
    do_fsync if dirty
  end

  def get(index : UInt64) : Entry?
    offset = @offsets[index]?
    return nil unless offset
    read_entry_at(offset)
  end

  def last_index : UInt64
    @last_index
  end

  def last_term : UInt64
    @last_term
  end

  def term_at(index : UInt64) : UInt64?
    offset = @offsets[index]?
    return nil unless offset
    read_term_at_offset(offset)
  end

  def truncate_from(index : UInt64) : Nil
    offset = @offsets[index]?
    return unless offset
    @log_file.flush
    @log_file.truncate(offset)
    LibC.fsync(@log_file.fd) if @fsync
    @log_file.seek(offset)
    @offsets.reject! { |idx, _| idx >= index }
    update_last_cached
  end

  def slice(from : UInt64, to : UInt64) : Array(Entry)
    cap = (to - from + 1).to_i
    cap = 0 if cap < 0
    result = Array(Entry).new(cap)
    from.upto(to) do |idx|
      entry = get(idx)
      break unless entry
      result << entry
    end
    result
  end

  def each_in_range(from : UInt64, to : UInt64, & : Entry ->) : Nil
    from.upto(to) do |idx|
      entry = get(idx)
      break unless entry
      yield entry
    end
  end

  def save_metadata(meta : Metadata) : Nil
    tmp_path = @meta_path + ".tmp"
    ::File.open(tmp_path, "wb") do |file|
      file.write_bytes(meta.current_term, FORMAT)
      if voted = meta.voted_for
        file.write_bytes(voted.bytesize.to_u16, FORMAT)
        file.write(voted.to_slice)
      else
        file.write_bytes(0_u16, FORMAT)
      end
      if @fsync
        file.flush
        LibC.fsync(file.fd)
      end
    end
    ::File.rename(tmp_path, @meta_path)
    fsync_dir if @fsync
  end

  def load_metadata : Metadata
    return Metadata.new(current_term: 0_u64, voted_for: nil) unless ::File.exists?(@meta_path)
    ::File.open(@meta_path, "rb") do |file|
      term = file.read_bytes(UInt64, FORMAT)
      len = file.read_bytes(UInt16, FORMAT)
      voted_for = if len > 0
                    buf = Bytes.new(len)
                    file.read_fully(buf)
                    String.new(buf)
                  end
      Metadata.new(current_term: term, voted_for: voted_for)
    end
  end

  def save_snapshot(last_index : UInt64, last_term : UInt64, data : Bytes) : Nil
    tmp_path = @snapshot_path + ".tmp"
    ::File.open(tmp_path, "wb") do |file|
      file.write_bytes(last_index, FORMAT)
      file.write_bytes(last_term, FORMAT)
      file.write_bytes(data.size.to_u32, FORMAT)
      file.write(data)
      if @fsync
        file.flush
        LibC.fsync(file.fd)
      end
    end
    ::File.rename(tmp_path, @snapshot_path)
    fsync_dir if @fsync
    compact_log(last_index)
  end

  def load_snapshot : {UInt64, UInt64, Bytes}?
    return nil unless ::File.exists?(@snapshot_path)
    ::File.open(@snapshot_path, "rb") do |file|
      last_idx = file.read_bytes(UInt64, FORMAT)
      last_trm = file.read_bytes(UInt64, FORMAT)
      data_len = file.read_bytes(UInt32, FORMAT)
      data = Bytes.new(data_len)
      file.read_fully(data) if data_len > 0
      {last_idx, last_trm, data}
    end
  end

  def close : Nil
    @log_file.close
  end

  private def write_entry(entry : Entry, sync : Bool = true) : Nil
    offset = @log_file.pos
    @log_file.write_bytes(entry.index, FORMAT)
    @log_file.write_bytes(entry.term, FORMAT)
    @log_file.write_byte(entry.entry_type.value)
    @log_file.write_bytes(entry.data.size.to_u32, FORMAT)
    @log_file.write(entry.data)
    do_fsync if sync
    @offsets[entry.index] = offset.to_i64
    @last_index = entry.index
    @last_term = entry.term
  end

  private def do_fsync : Nil
    @log_file.flush
    LibC.fsync(@log_file.fd) if @fsync
  end

  private def read_entry_at(offset : Int64) : Entry
    ::File.open(@log_path, "rb") do |file|
      file.seek(offset)
      index = file.read_bytes(UInt64, FORMAT)
      term = file.read_bytes(UInt64, FORMAT)
      type_byte = file.read_byte || raise Error::LogCorrupted.new("Unexpected EOF reading entry type")
      entry_type = EntryType.new(type_byte)
      data_len = file.read_bytes(UInt32, FORMAT)
      data = Bytes.new(data_len)
      file.read_fully(data) if data_len > 0
      Entry.new(index: index, term: term, entry_type: entry_type, data: data)
    end
  end

  private def read_term_at_offset(offset : Int64) : UInt64
    ::File.open(@log_path, "rb") do |file|
      file.seek(offset + 8)
      file.read_bytes(UInt64, FORMAT)
    end
  end

  private def rebuild_index : Nil
    @offsets.clear
    @last_index = 0_u64
    @last_term = 0_u64

    file_size = ::File.size(@log_path)
    return if file_size == 0

    ::File.open(@log_path, "rb") do |file|
      while file.pos < file_size
        offset = file.pos
        remaining = file_size - file.pos
        break if remaining < RECORD_HEADER_SIZE

        begin
          index = file.read_bytes(UInt64, FORMAT)
          term = file.read_bytes(UInt64, FORMAT)
          file.read_byte || break
          data_len = file.read_bytes(UInt32, FORMAT)

          if file.pos + data_len > file_size
            break
          end

          file.seek(file.pos + data_len) if data_len > 0

          @offsets[index] = offset.to_i64
          @last_index = index
          @last_term = term
        rescue IO::EOFError
          break
        end
      end
    end
  end

  private def update_last_cached : Nil
    if @offsets.empty?
      @last_index = 0_u64
      @last_term = 0_u64
    else
      max_idx = @offsets.keys.max
      @last_index = max_idx
      entry = read_entry_at(@offsets[max_idx])
      @last_term = entry.term
    end
  end

  private def fsync_dir : Nil
    ::File.open(@data_dir, "r") do |dir|
      LibC.fsync(dir.fd)
    end
  end

  private def compact_log(up_to_index : UInt64) : Nil
    remaining_indices = @offsets.keys.select { |idx| idx > up_to_index }.sort!
    return if remaining_indices.empty? && @offsets.keys.all? { |idx| idx <= up_to_index }

    tmp_path = @log_path + ".compact"
    @log_file.close

    new_offsets = Hash(UInt64, Int64).new
    ::File.open(tmp_path, "wb") do |writer|
      remaining_indices.each do |idx|
        entry = read_entry_at(@offsets[idx])
        offset = writer.pos
        writer.write_bytes(entry.index, FORMAT)
        writer.write_bytes(entry.term, FORMAT)
        writer.write_byte(entry.entry_type.value)
        writer.write_bytes(entry.data.size.to_u32, FORMAT)
        writer.write(entry.data)
        new_offsets[entry.index] = offset.to_i64
      end
      if @fsync
        writer.flush
        LibC.fsync(writer.fd)
      end
    end

    ::File.rename(tmp_path, @log_path)
    fsync_dir if @fsync
    @offsets = new_offsets
    update_last_cached
    @log_file = ::File.open(@log_path, "r+b")
    @log_file.seek(0, IO::Seek::End)
  end
end
