defmodule Membrane.RTCP.ReceiverReportStats do
  @moduledoc """
  Module used to store receiver stats and generate ReceiverReports based on that data
  """

  alias Membrane.RTCP
  alias Membrane.RTCP.SenderReportPacket
  alias Membrane.Time

  require Bitwise

  @max_s24_val Bitwise.bsl(1, 23) - 1
  @min_s24_val -Bitwise.bsl(1, 23)

  @type t :: %__MODULE__{
          jitter: float(),
          transit: non_neg_integer() | nil,
          max_extended_seq_num: non_neg_integer(),
          received: non_neg_integer(),
          received_prior: non_neg_integer(),
          expected_prior: non_neg_integer()
        }

  @enforce_keys [:local_ssrc, :remote_ssrc, :clock_rate]
  defstruct @enforce_keys ++
              [
                jitter: 0.0,
                transit: nil,
                first_seq_num: 0,
                max_extended_seq_num: 0,
                received: 0,
                received_prior: 0,
                expected_prior: 0,
                last_sr_arrival_ts: nil,
                last_sr_wallclock_ts: 0
              ]

  def new(local, remote, clock_rate) do
    %__MODULE__{local_ssrc: local, remote_ssrc: remote, clock_rate: clock_rate}
  end

  @spec packet_arrived(t(), non_neg_integer()) :: t()
  def packet_arrived(%__MODULE__{first_seq_num: nil} = stats, extended_seq_num) do
    %__MODULE__{stats | first_seq_num: extended_seq_num}
    |> packet_arrived(extended_seq_num)
  end

  def packet_arrived(%__MODULE__{} = stats, extended_seq_num) do
    %__MODULE__{
      stats
      | received: stats.received + 1,
        max_extended_seq_num: max(extended_seq_num, stats.max_extended_seq_num)
    }

    # FIXME: Update jitter
  end

  @spec sr_arrived(t(), SenderReportPacket.t(), Time.t()) :: t()
  def sr_arrived(%__MODULE__{} = stats, %SenderReportPacket{} = sr, arrival_ts) do
    <<_wallclock_ts_upper_16_bits::16, wallclock_ts_middle_32_bits::32,
      _wallclock_ts_lower_16_bits::16>> =
      Time.to_ntp_timestamp(sr.sender_info.wallclock_timestamp)

    %__MODULE__{
      stats
      | last_sr_wallclock_ts: wallclock_ts_middle_32_bits,
        last_sr_arrival_ts: arrival_ts
    }
  end

  def generate_report(%__MODULE__{} = stats) do
    expected = stats.max_extended_seq_num - stats.first_seq_num + 1

    lost = max(expected - stats.received, 0)

    expected_interval = expected - stats.expected_prior
    received_interval = stats.received - stats.received_prior

    lost_interval = expected_interval - received_interval

    fraction_lost =
      if expected_interval == 0 || lost_interval <= 0 do
        0.0
      else
        lost_interval / expected_interval
      end

    total_lost =
      cond do
        lost > @max_s24_val -> @max_s24_val
        lost < @min_s24_val -> @min_s24_val
        true -> lost
      end

    stats = %__MODULE__{
      stats
      | expected_prior: expected,
        received_prior: stats.received
    }

    now = Time.vm_time()
    delay_since_sr = now - Map.get(stats, :last_sr_arrival_ts, now)

    report_block = %RTCP.ReportPacketBlock{
      ssrc: stats.remote_ssrc,
      fraction_lost: fraction_lost,
      total_lost: total_lost,
      highest_seq_num: stats.max_extended_seq_num,
      interarrival_jitter: trunc(stats.jitter),
      last_sr_timestamp: stats.last_sr_wallclock_ts,
      # delay_since_sr is expressed in 1/65536 seconds, see https://tools.ietf.org/html/rfc3550#section-6.4.1
      delay_since_sr: Time.to_seconds(65_536 * delay_since_sr)
    }

    packet = %RTCP.ReceiverReportPacket{ssrc: stats.local_ssrc, reports: [report_block]}
    {packet, stats}
  end

  defp update_jitter(%__MODULE__{} = stats, buffer_ts, arrival_ts) do
    last_jitter = stats.jitter
    last_transit = stats.transit

    # Algorithm from https://tools.ietf.org/html/rfc3550#appendix-A.8
    arrival = arrival_ts |> Time.as_seconds() |> Ratio.mult(stats.clock_rate) |> Ratio.trunc()
    transit = arrival - buffer_ts

    {jitter, transit} =
      if last_transit == nil do
        {last_jitter, transit}
      else
        d = abs(transit - last_transit)
        new_jitter = last_jitter + 1 / 16 * (d - last_jitter)

        {new_jitter, transit}
      end

    %__MODULE__{stats | jitter: jitter, transit: transit}
  end
end
