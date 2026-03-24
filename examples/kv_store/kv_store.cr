require "../../src/raft"

# A simple key-value store backed by Raft consensus.
#
# Only PUT and DELETE go through Raft (mutations). GET reads directly from
# the local hash after leadership is confirmed by the node.
class KVStore < Raft::StateMachine
  PUT    = 0x01_u8
  DELETE = 0x02_u8

  def initialize
    @data = Hash(String, Bytes).new
  end

  # Reads a key from the local state. Returns nil if not found.
  def get(key : String) : Bytes?
    @data[key]?
  end

  def apply(command : Bytes) : Bytes
    return Bytes.empty if command.empty? # no-op (used by read confirmation)

    io = IO::Memory.new(command)
    op = io.read_byte.not_nil!
    key_len = io.read_bytes(UInt16, IO::ByteFormat::BigEndian)
    key = io.read_string(key_len)

    case op
    when PUT
      remaining = command.size - io.pos
      value = Bytes.new(remaining)
      io.read_fully(value) if remaining > 0
      @data[key] = value
      Bytes.empty
    when DELETE
      @data.delete(key)
      Bytes.empty
    else
      Bytes.empty
    end
  end

  def snapshot : Bytes
    io = IO::Memory.new
    @data.each do |key, value|
      io.write_bytes(key.bytesize.to_u16, IO::ByteFormat::BigEndian)
      io.write(key.to_slice)
      io.write_bytes(value.size.to_u32, IO::ByteFormat::BigEndian)
      io.write(value)
    end
    io.to_slice
  end

  def restore(io : IO) : Nil
    @data.clear
    while key_len = io.read_bytes?(UInt16, IO::ByteFormat::BigEndian)
      key = io.read_string(key_len)
      val_len = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      value = Bytes.new(val_len)
      io.read_fully(value) if val_len > 0
      @data[key] = value
    end
  end

  # Encodes a PUT command for use with `node.propose`.
  def self.encode_put(key : String, value : Bytes) : Bytes
    io = IO::Memory.new
    io.write_byte(PUT)
    io.write_bytes(key.bytesize.to_u16, IO::ByteFormat::BigEndian)
    io.write(key.to_slice)
    io.write(value)
    io.to_slice
  end

  # Encodes a DELETE command for use with `node.propose`.
  def self.encode_delete(key : String) : Bytes
    io = IO::Memory.new
    io.write_byte(DELETE)
    io.write_bytes(key.bytesize.to_u16, IO::ByteFormat::BigEndian)
    io.write(key.to_slice)
    io.to_slice
  end
end
