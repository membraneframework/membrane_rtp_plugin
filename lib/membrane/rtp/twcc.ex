defmodule Membrane.RTP.TWCC do
  @moduledoc """
  The module defines an element responsible for recording transport-wide statistics of incoming packets.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RTP, RTCPEvent, Time}
  alias Membrane.RTCP.TransportFeedbackPacket

  require Bitwise

  # taken from Chromium SDP offer
  @sdp_extension_id 3

  @feedback_count_limit Bitwise.bsl(1, 8)
  @seq_number_limit Bitwise.bsl(1, 16)

  def_input_pad :input, demand_unit: :buffers, caps: RTP, availability: :on_request
  def_output_pad :output, caps: RTP, availability: :on_request

  def_options sender_ssrc: [
                spec: RTP.ssrc_t(),
                description: "Sender SSRC for generated feedback packets."
              ],
              report_interval: [
                spec: Membrane.Time.t(),
                description: "How often to generate feedback packets."
              ]

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            sender_ssrc: RTP.ssrc_t(),
            report_interval: Time.t(),
            base_seq_num: non_neg_integer(),
            max_seq_num: non_neg_integer(),
            seq_to_timestamp: %{non_neg_integer() => Time.t()},
            feedback_packet_count: non_neg_integer(),
            local_seq_num: non_neg_integer(),
            last_ssrc: RTP.ssrc_t()
          }

    @enforce_keys [:sender_ssrc, :report_interval]
    defstruct @enforce_keys ++
                [
                  base_seq_num: nil,
                  max_seq_num: nil,
                  seq_to_timestamp: %{},
                  feedback_packet_count: 0,
                  local_seq_num: 0,
                  last_ssrc: nil
                ]
  end

  @impl true
  def handle_init(opts) do
    {:ok, %State{sender_ssrc: opts.sender_ssrc, report_interval: opts.report_interval}}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, start_timer: {:report_timer, state.report_interval}}, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    {{:ok, stop_timer: :report_timer}, state}
  end

  @impl true
  def handle_demand(Pad.ref(:output, ssrc), size, :buffers, _ctx, state) do
    {{:ok, demand: {Pad.ref(:input, ssrc), size}}, state}
  end

  @impl true
  def handle_event(Pad.ref(:input, ssrc), event, _ctx, state) do
    {{:ok, event: {Pad.ref(:output, ssrc), event}}, state}
  end

  @impl true
  def handle_event(Pad.ref(:output, ssrc), event, _ctx, state) do
    {{:ok, event: {Pad.ref(:input, ssrc), event}}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(_direction, ssrc), _ctx, %State{last_ssrc: last_ssrc} = state) do
    if ssrc == last_ssrc do
      {:ok, %State{state | last_ssrc: nil}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_process(Pad.ref(:input, ssrc), %Buffer{metadata: metadata} = buffer, _ctx, state) do
    %State{
      base_seq_num: base_seq_num,
      max_seq_num: max_seq_num,
      seq_to_timestamp: seq_to_timestamp,
      local_seq_num: local_seq_num,
      last_ssrc: last_ssrc
    } = state

    arrival_ts = Time.monotonic_time()

    # TODO: match on ID proposed by membrane_webrtc_plugin in SDP offer
    <<_id::4, _len::4, seq_num::16, _padding::8>> = metadata.rtp.extension.data

    seq_num =
      if rollover?(seq_num, base_seq_num) do
        seq_num + @seq_number_limit
      else
        seq_num
      end

    # TODO: use ID proposed in browser's SDP offer (currently hardcoded to `@sdp_extension_id`)
    # TODO: consider moving sequence number tagging closer to the end of the pipeline
    header_extension = <<@sdp_extension_id::4, 1::4, local_seq_num::16, 0::8>>

    metadata =
      Bunch.Struct.put_in(
        metadata,
        [:rtp, :extension, :data],
        header_extension
      )

    state =
      Map.merge(state, %{
        base_seq_num: min(base_seq_num, seq_num) || seq_num,
        max_seq_num: max(max_seq_num, seq_num) || seq_num,
        seq_to_timestamp: Map.put(seq_to_timestamp, seq_num, arrival_ts),
        local_seq_num: rem(local_seq_num + 1, @seq_number_limit),
        last_ssrc: last_ssrc || ssrc
      })

    {{:ok, buffer: {Pad.ref(:output, ssrc), %Buffer{buffer | metadata: metadata}}}, state}
  end

  @impl true
  def handle_tick(:report_timer, _ctx, %State{base_seq_num: nil} = state), do: {:ok, state}

  @impl true
  def handle_tick(:report_timer, _ctx, state) do
    %State{
      base_seq_num: base_seq_num,
      max_seq_num: max_seq_num,
      feedback_packet_count: feedback_packet_count,
      sender_ssrc: sender_ssrc,
      last_ssrc: last_ssrc
    } = state

    {reference_time, receive_deltas} = make_receive_deltas(state)

    packet_status_count = max_seq_num - base_seq_num + 1

    payload = %TransportFeedbackPacket.TWCC{
      base_seq_num: base_seq_num,
      reference_time: reference_time,
      packet_status_count: packet_status_count,
      receive_deltas: receive_deltas,
      feedback_packet_count: feedback_packet_count
    }

    rtcp = %TransportFeedbackPacket{
      sender_ssrc: sender_ssrc,
      media_ssrc: last_ssrc,
      payload: payload
    }

    event = %RTCPEvent{rtcp: rtcp}

    state =
      Map.merge(state, %{
        base_seq_num: nil,
        max_seq_num: nil,
        seq_to_timestamp: %{},
        feedback_packet_count: rem(feedback_packet_count + 1, @feedback_count_limit)
      })

    {{:ok, event: {Pad.ref(:input, last_ssrc), event}}, state}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, ssrc), _ctx, state) do
    {{:ok, end_of_stream: Pad.ref(:output, ssrc)}, state}
  end

  defp rollover?(_new_seq, nil), do: false

  defp rollover?(new_seq, base_seq) do
    new_seq < base_seq and new_seq + (@seq_number_limit - base_seq) < base_seq - new_seq
  end

  defp make_receive_deltas(state) do
    %State{
      base_seq_num: base_seq_num,
      max_seq_num: max_seq_num,
      seq_to_timestamp: seq_to_timestamp
    } = state

    # reference time has to be divisible by 64
    # https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01#section-3.1
    reference_time =
      seq_to_timestamp
      |> Map.fetch!(base_seq_num)
      |> make_divisible_by_64ms()

    receive_deltas =
      base_seq_num..max_seq_num
      |> Enum.reduce({[], reference_time}, fn seq_num, {deltas, previous_timestamp} ->
        case Map.get(seq_to_timestamp, seq_num) do
          nil ->
            {[nil | deltas], previous_timestamp}

          timestamp ->
            delta = timestamp - previous_timestamp
            {[delta | deltas], timestamp}
        end
      end)
      |> elem(0)
      |> Enum.reverse()

    {reference_time, receive_deltas}
  end

  defp make_divisible_by_64ms(timestamp) do
    timestamp
    |> Time.as_milliseconds()
    |> Ratio.div(64)
    |> Ratio.floor()
    |> then(&(&1 * 64))
    |> Time.milliseconds()
  end
end
