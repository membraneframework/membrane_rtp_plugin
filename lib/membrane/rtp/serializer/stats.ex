defmodule Membrane.RTP.Serializer.Stats do
  @moduledoc """
  JitterBuffer stats that can be used for Receiver report generation
  """

  @enforce_keys [:wallclock_timestamp, :rtp_timestamp, :sender_packet_count, :sender_octet_count]

  defstruct @enforce_keys

  @type t ::
          %__MODULE__{
            sender_packet_count: non_neg_integer(),
            sender_octet_count: non_neg_integer()
          }
          | :no_stats
end
