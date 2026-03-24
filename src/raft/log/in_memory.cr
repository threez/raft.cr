# In-memory log implementation for testing and development.
#
# All data is held in memory and lost when the process exits.
# This is the recommended implementation for unit and integration tests.
class Raft::Log::InMemory < Raft::Log
  def initialize
    @entries = Array(Entry).new
    @metadata = Metadata.new(current_term: 0_u64, voted_for: nil)
    @snapshot = nil.as({UInt64, UInt64, Bytes}?)
  end

  def append(entries : Array(Entry)) : Nil
    entries.each do |entry|
      pos = entry.index.to_i - 1
      if pos < @entries.size
        existing = @entries[pos]
        if existing.term != entry.term
          @entries = @entries[0, pos]
        elsif existing.term == entry.term
          next
        end
      end
      @entries << entry
    end
  end

  def get(index : UInt64) : Entry?
    pos = index.to_i - 1
    return nil if pos < 0 || pos >= @entries.size
    @entries[pos]
  end

  def last_index : UInt64
    @entries.empty? ? 0_u64 : @entries.last.index
  end

  def last_term : UInt64
    @entries.empty? ? 0_u64 : @entries.last.term
  end

  def term_at(index : UInt64) : UInt64?
    get(index).try(&.term)
  end

  def truncate_from(index : UInt64) : Nil
    keep = index.to_i - 1
    return if keep < 0
    if keep < @entries.size
      @entries = @entries[0, keep]
    end
  end

  def slice(from : UInt64, to : UInt64) : Array(Entry)
    result = Array(Entry).new
    from_pos = from.to_i - 1
    to_pos = to.to_i - 1
    return result if from_pos < 0

    from_pos.upto(to_pos) do |idx|
      break if idx >= @entries.size
      result << @entries[idx] if idx >= 0
    end
    result
  end

  def save_metadata(meta : Metadata) : Nil
    @metadata = meta
  end

  def load_metadata : Metadata
    @metadata
  end

  def save_snapshot(last_index : UInt64, last_term : UInt64, data : Bytes) : Nil
    @snapshot = {last_index, last_term, data}
    @entries.reject! { |entry| entry.index <= last_index }
  end

  def load_snapshot : {UInt64, UInt64, Bytes}?
    @snapshot
  end

  def close : Nil
  end
end
