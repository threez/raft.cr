require "benchmark"
require "file_utils"
require "../src/raft"

Log.setup(:none)

class BenchStateMachine < Raft::StateMachine
  def apply(command : Bytes) : Bytes
    command
  end

  def snapshot : Bytes
    Bytes.empty
  end

  def restore(io : IO) : Nil
  end
end
