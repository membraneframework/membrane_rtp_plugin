defmodule Membrane.RTCP.ReportBlock do
  @moduledoc """
  Parses and constructs report blocks, which are parts of RTCP Sender and Receiver Reports
  defined in [RFC3550](https://tools.ietf.org/html/rfc3550#section-6.4)
  """
  defstruct [
    :ssrc,
    :fraction_lost,
    :packets_lost_total,
    :extended_s_l,
    :interarrival_jitter,
    :last_sr,
    :delay_last_sr
  ]

  @type t() :: %__MODULE__{
          ssrc: non_neg_integer(),
          fraction_lost: float(),
          packets_lost_total: non_neg_integer(),
          extended_s_l: non_neg_integer(),
          interarrival_jitter: non_neg_integer(),
          last_sr: non_neg_integer(),
          delay_last_sr: non_neg_integer()
        }

  # Used in both SR and RR
  # big_s_l == extended highest sequence number receiver (32 bits)
  @spec parse(binary()) :: [t()]
  def parse(blocks), do: parse(blocks, [])

  def to_binary(block) do
    %{
      ssrc: ssrc,
      fraction_lost: fraction_lost,
      packets_lost_total: packets_lost_total,
      extended_s_l: s_l,
      interarrival_jitter: interarrival_jitter,
      last_sr: last_sr,
      delay_last_sr: delay_last_sr
    } = block

    <<ssrc::32, fraction_lost::8, packets_lost_total::24, s_l::32, interarrival_jitter::32,
      last_sr::32, delay_last_sr::32>>
  end

  defp parse(<<>>, acc), do: acc

  defp parse(
         <<ssrc::32, fraction_lost::8, packets_lost_total::24, s_l::32, interarrival_jitter::32,
           last_sr::32, delay_last_sr::32, rest::binary>>,
         acc
       ) do
    data = %__MODULE__{
      ssrc: ssrc,
      fraction_lost: fraction_lost,
      packets_lost_total: packets_lost_total,
      extended_s_l: s_l,
      interarrival_jitter: interarrival_jitter,
      last_sr: last_sr,
      delay_last_sr: delay_last_sr
    }

    parse(rest, [data | acc])
  end
end
