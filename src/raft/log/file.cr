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
  # Opens (or creates) a log in *data_dir*.
  #
  # See the class-level documentation for the file format and the *fsync* trade-off.
  def initialize(data_dir : String, fsync : Bool = true)
    Dir.mkdir_p(data_dir)
    @log_store = LogStore.new(::File.join(data_dir, "log.bin"), data_dir, fsync)
    @meta_store = MetaStore.new(::File.join(data_dir, "metadata.bin"), data_dir, fsync)
    @snap_store = SnapStore.new(::File.join(data_dir, "snapshot.bin"), data_dir, fsync)
  end

  def append(entry : Entry) : Nil
    @log_store.append(entry)
  end

  def append(entries : Array(Entry)) : Nil
    @log_store.append(entries)
  end

  def get(index : UInt64) : Entry?
    @log_store.get(index)
  end

  def last_index : UInt64
    @log_store.last_index
  end

  def last_term : UInt64
    @log_store.last_term
  end

  def term_at(index : UInt64) : UInt64?
    @log_store.term_at(index)
  end

  def truncate_from(index : UInt64) : Nil
    @log_store.truncate_from(index)
  end

  def slice(from : UInt64, to : UInt64) : Array(Entry)
    @log_store.slice(from, to)
  end

  def each_in_range(from : UInt64, to : UInt64, & : Entry ->) : Nil
    @log_store.each_in_range(from, to) { |entry| yield entry }
  end

  def save_metadata(meta : Metadata) : Nil
    @meta_store.save(meta)
  end

  def load_metadata : Metadata
    @meta_store.load
  end

  def save_snapshot(last_index : UInt64, last_term : UInt64, data : Bytes) : Nil
    @snap_store.save(last_index, last_term, data)
    @log_store.compact(last_index)
  end

  def load_snapshot : {UInt64, UInt64, Bytes}?
    @snap_store.load
  end

  def close : Nil
    @log_store.close
  end

  # --- Internal: Log entry storage ---

  # :nodoc:
  private class LogStore
    RECORD_HEADER_SIZE = 21
    FORMAT             = IO::ByteFormat::BigEndian

    getter last_index : UInt64
    getter last_term : UInt64

    def initialize(@path : String, @data_dir : String, @fsync : Bool)
      @offsets = Hash(UInt64, Int64).new
      @last_index = 0_u64
      @last_term = 0_u64
      @compacting = false
      ::File.touch(@path) unless ::File.exists?(@path)
      @writer = ::File.open(@path, "r+b")
      @reader = ::File.open(@path, "rb")
      rebuild_index
      @writer.seek(0, IO::Seek::End)
    end

    def append(entry : Entry) : Nil
      if @offsets.has_key?(entry.index)
        if read_term_at(entry.index) != entry.term
          truncate_from(entry.index)
        else
          return
        end
      end
      write_entry(entry)
      do_fsync
    end

    def append(entries : Array(Entry)) : Nil
      dirty = false
      entries.each do |entry|
        if @offsets.has_key?(entry.index)
          if read_term_at(entry.index) != entry.term
            truncate_from(entry.index)
          else
            next
          end
        end
        write_entry(entry)
        dirty = true
      end
      do_fsync if dirty
    end

    def get(index : UInt64) : Entry?
      offset = @offsets[index]?
      return nil unless offset
      read_entry_at(offset)
    end

    def term_at(index : UInt64) : UInt64?
      offset = @offsets[index]?
      return nil unless offset
      read_term_at_offset(offset)
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

    def truncate_from(index : UInt64) : Nil
      offset = @offsets[index]?
      return unless offset
      @writer.flush
      @writer.truncate(offset)
      LibC.fsync(@writer.fd) if @fsync
      @writer.seek(offset)
      @offsets.reject! { |idx, _| idx >= index }
      refresh_last_cached
    end

    def compact(up_to_index : UInt64) : Nil
      return if @compacting
      remaining = @offsets.keys.select { |idx| idx > up_to_index }.sort!
      return if remaining.empty? && @offsets.keys.all? { |idx| idx <= up_to_index }

      # Read entries while handles are still open
      entries = remaining.map { |idx| read_entry_at(@offsets[idx]) }

      # Remove compacted entries from the offset index immediately so
      # concurrent reads don't try to access them. The entries are still
      # in the file until rewrite, but get() will return nil for them.
      @offsets.reject! { |idx, _| idx <= up_to_index }

      # Run the file rewrite in a background fiber to avoid blocking
      # the event loop (fsync can take >100ms, causing election timeouts).
      @compacting = true
      spawn do
        @reader.close
        @writer.close

        tmp_path = @path + ".compact"
        new_offsets = Hash(UInt64, Int64).new
        ::File.open(tmp_path, "wb") do |file|
          entries.each do |entry|
            offset = file.pos
            file.write_bytes(entry.index, FORMAT)
            file.write_bytes(entry.term, FORMAT)
            file.write_byte(entry.entry_type.value)
            file.write_bytes(entry.data.size.to_u32, FORMAT)
            file.write(entry.data)
            new_offsets[entry.index] = offset.to_i64
          end
          if @fsync
            file.flush
            LibC.fsync(file.fd)
          end
        end

        ::File.rename(tmp_path, @path)
        fsync_dir if @fsync
        @offsets = new_offsets

        if entries.empty?
          @last_index = 0_u64
          @last_term = 0_u64
        else
          @last_index = entries.last.index
          @last_term = entries.last.term
        end

        @writer = ::File.open(@path, "r+b")
        @reader = ::File.open(@path, "rb")
        @writer.seek(0, IO::Seek::End)
      ensure
        @compacting = false
      end
    end

    def close : Nil
      @reader.close
      @writer.close
    end

    private def write_entry(entry : Entry) : Nil
      offset = @writer.pos
      @writer.write_bytes(entry.index, FORMAT)
      @writer.write_bytes(entry.term, FORMAT)
      @writer.write_byte(entry.entry_type.value)
      @writer.write_bytes(entry.data.size.to_u32, FORMAT)
      @writer.write(entry.data)
      @offsets[entry.index] = offset.to_i64
      @last_index = entry.index
      @last_term = entry.term
    end

    private def do_fsync : Nil
      @writer.flush
      LibC.fsync(@writer.fd) if @fsync
    end

    private def read_entry_at(offset : Int64) : Entry
      @reader.seek(offset)
      index = @reader.read_bytes(UInt64, FORMAT)
      term = @reader.read_bytes(UInt64, FORMAT)
      type_byte = @reader.read_byte || raise Error::LogCorrupted.new("Unexpected EOF reading entry type")
      entry_type = EntryType.new(type_byte)
      data_len = @reader.read_bytes(UInt32, FORMAT)
      data = Bytes.new(data_len)
      @reader.read_fully(data) if data_len > 0
      Entry.new(index: index, term: term, entry_type: entry_type, data: data)
    end

    private def read_term_at(index : UInt64) : UInt64
      read_term_at_offset(@offsets[index])
    end

    private def read_term_at_offset(offset : Int64) : UInt64
      @reader.seek(offset + 8)
      @reader.read_bytes(UInt64, FORMAT)
    end

    private def rebuild_index : Nil
      @offsets.clear
      @last_index = 0_u64
      @last_term = 0_u64

      file_size = ::File.size(@path)
      return if file_size == 0

      ::File.open(@path, "rb") do |file|
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

    private def refresh_last_cached : Nil
      if @offsets.empty?
        @last_index = 0_u64
        @last_term = 0_u64
      else
        max_idx = @offsets.keys.max
        @last_index = max_idx
        @last_term = read_term_at_offset(@offsets[max_idx])
      end
    end

    private def fsync_dir : Nil
      ::File.open(@data_dir, "r") do |dir|
        LibC.fsync(dir.fd)
      end
    end
  end

  # --- Internal: Metadata persistence ---

  # :nodoc:
  private class MetaStore
    FORMAT = IO::ByteFormat::BigEndian

    def initialize(@path : String, @data_dir : String, @fsync : Bool)
    end

    def save(meta : Metadata) : Nil
      Dir.mkdir_p(@data_dir) unless Dir.exists?(@data_dir)
      tmp_path = @path + ".tmp"
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
      ::File.rename(tmp_path, @path)
      fsync_dir if @fsync
    end

    def load : Metadata
      return Metadata.new(current_term: 0_u64, voted_for: nil) unless ::File.exists?(@path)
      ::File.open(@path, "rb") do |file|
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

    private def fsync_dir : Nil
      ::File.open(@data_dir, "r") do |dir|
        LibC.fsync(dir.fd)
      end
    end
  end

  # --- Internal: Snapshot persistence ---

  # :nodoc:
  private class SnapStore
    FORMAT = IO::ByteFormat::BigEndian

    def initialize(@path : String, @data_dir : String, @fsync : Bool)
    end

    def save(last_index : UInt64, last_term : UInt64, data : Bytes) : Nil
      tmp_path = @path + ".tmp"
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
      ::File.rename(tmp_path, @path)
      fsync_dir if @fsync
    end

    def load : {UInt64, UInt64, Bytes}?
      return nil unless ::File.exists?(@path)
      ::File.open(@path, "rb") do |file|
        last_idx = file.read_bytes(UInt64, FORMAT)
        last_trm = file.read_bytes(UInt64, FORMAT)
        data_len = file.read_bytes(UInt32, FORMAT)
        data = Bytes.new(data_len)
        file.read_fully(data) if data_len > 0
        {last_idx, last_trm, data}
      end
    end

    private def fsync_dir : Nil
      ::File.open(@data_dir, "r") do |dir|
        LibC.fsync(dir.fd)
      end
    end
  end
end
