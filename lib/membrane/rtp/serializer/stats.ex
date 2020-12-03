defmodule Membrane.RTP.Serializer.Stats do
  @moduledoc """
  Serializer stats that can be used for Sender Report(SR) generation
  """
  use Bunch.Access

  @enforce_keys [
    :clock_rate,
    :timestamp,
    :rtp_timestamp,
    :sender_packet_count,
    :sender_octet_count
  ]

  defstruct @enforce_keys

  @type t ::
          %__MODULE__{
            clock_rate: RTP.clock_rate_t(),
            timestamp: non_neg_integer(),
            rtp_timestamp: non_neg_integer(),
            sender_packet_count: non_neg_integer(),
            sender_octet_count: non_neg_integer()
          }
          | :no_stats
end
