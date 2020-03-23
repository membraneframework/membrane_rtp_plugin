defmodule Membrane.RTCP.Report do
  @moduledoc """
  Parses and constructs RTCP Sender and Receiver Reports defined in
  [RFC3550](https://tools.ietf.org/html/rfc3550#section-6.4)
  """
  alias Membrane.RTCP
  alias Membrane.RTCP.ReportBlock

  defstruct [:ssrc, :reports, :sender_info]

  @type sender_info_t :: %{
          ntp_timestamp: non_neg_integer(),
          rtp_timestamp: non_neg_integer(),
          sender_packet_count: non_neg_integer(),
          sender_octet_count: non_neg_integer()
        }

  @type t :: %__MODULE__{
          ssrc: non_neg_integer(),
          reports: [ReportBlock.t()],
          sender_info: sender_info_t() | nil
        }

  def to_binary(report) do
    sender_info = sender_info_to_binary(report.sender_info)
    blocks = report.reports |> Enum.map(&ReportBlock.to_binary(&1)) |> Enum.join(<<>>)

    rc = report.reports |> length()
    pt = if report.sender_info == nil, do: 201, else: 200
    body = <<report.ssrc::32>> <> sender_info <> blocks
    length = RTCP.calc_length(body)

    header = <<2::2, 0::1, rc::5, pt::8, length::16>>
    header <> body
  end

  defp sender_info_to_binary(nil), do: <<>>

  defp sender_info_to_binary(sender_info) do
    # TODO NTP timestamp better encoding
    <<sender_info.ntp_timestamp::64, sender_info.rtp_timestamp::32,
      sender_info.sender_packet_count::32, sender_info.sender_octet_count::32>>
  end

  @spec parse(packet :: binary(), is_sender_info_present :: boolean()) :: {:ok, t()}
  def parse(<<ssrc::32, rest::binary>>, is_info_present) do
    {sender_info, blocks} = parse_sender_info(rest, is_info_present)
    reports = ReportBlock.parse(blocks)
    data = %__MODULE__{ssrc: ssrc, reports: reports, sender_info: sender_info}
    {:ok, data}
  end

  @spec parse_sender_info(binary(), boolean()) :: {sender_info_t(), binary()}
  defp parse_sender_info(
         <<ntp_time::64, rtp_time::32, packet_count::32, octet_count::32, rest::binary>>,
         true
       ) do
    info = %{
      ntp_timestamp: ntp_time,
      rtp_timestamp: rtp_time,
      sender_packet_count: packet_count,
      sender_octet_count: octet_count
    }

    {info, rest}
  end

  defp parse_sender_info(blocks, false), do: {nil, blocks}
end
