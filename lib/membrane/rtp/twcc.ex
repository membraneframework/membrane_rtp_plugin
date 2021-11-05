defmodule Membrane.RTP.TWCC do
  @moduledoc """
  The module defines an element responsible for recording transport-wide statistics of incoming packets.
  """
  use Membrane.Filter

  alias Membrane.{RTP, RTCPEvent, Time}
  alias Membrane.RTCP.TransportFeedbackPacket

  # taken from Chromium SDP offer
  @sdp_extension_id 3

  def_input_pad :input, demand_unit: :buffers, caps: RTP, availability: :on_request
  def_output_pad :output, caps: RTP, availability: :on_request

  def_options sender_ssrc: [
                spec: RTP.ssrc_t(),
                description: """
                Sender SSRC for TWCC element.
                """
              ],
              stats_interval: [
                default: Time.milliseconds(500),
                spec: Time.t(),
                description: """
                How often to generate TWCC statistics.
                """
              ]

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            stats_interval: Time.t(),
            base_seq_num: non_neg_integer(),
            max_seq_num: non_neg_integer(),
            seq_to_timestamp: %{non_neg_integer() => Time.t()},
            feedback_packet_count: non_neg_integer(),
            last_ssrc: RTP.ssrc_t(),
            sender_ssrc: RTP.ssrc_t(),
            local_seq_num: non_neg_integer()
          }

    @enforce_keys [:sender_ssrc, :stats_interval]
    defstruct @enforce_keys ++
                [
                  base_seq_num: nil,
                  max_seq_num: nil,
                  seq_to_timestamp: %{},
                  feedback_packet_count: 0,
                  last_ssrc: nil,
                  local_seq_num: 1
                ]
  end

  @impl true
  def handle_init(opts) do
    {:ok, %State{sender_ssrc: opts.sender_ssrc, stats_interval: opts.stats_interval}}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, start_timer: {:stats_timer, state.stats_interval}}, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, state) do
    {{:ok, stop_timer: :stats_timer}, state}
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
  def handle_process(Pad.ref(:input, ssrc), %{metadata: metadata} = buffer, _ctx, state) do
    %State{
      base_seq_num: base_seq_num,
      max_seq_num: max_seq_num,
      seq_to_timestamp: seq_to_timestamp,
      local_seq_num: local_seq_num
    } = state

    arrival_ts = Time.vm_time()
    # TODO: use ID proposed by us in our SDP offer
    <<_id::4, _len::4, seq_num::16, _padding::8>> = metadata.rtp.extension.data

    # TODO: use ID proposed in browser's SDP offer (currently hardcoded to `@sdp_extension_id`)
    # TODO: consider moving sequence number tagging closer to the end of the pipeline
    metadata =
      put_in(metadata, [:rtp, :extension], %{
        metadata.rtp.extension
        | data: <<@sdp_extension_id::4, 1::4, local_seq_num::16, 0::8>>
      })

    state =
      Map.merge(state, %{
        base_seq_num: min(base_seq_num, seq_num) || seq_num,
        max_seq_num: max(max_seq_num, seq_num) || seq_num,
        seq_to_timestamp: Map.put(seq_to_timestamp, seq_num, arrival_ts),
        last_ssrc: ssrc,
        local_seq_num: local_seq_num + 1
      })

    {{:ok, buffer: {Pad.ref(:output, ssrc), %{buffer | metadata: metadata}}}, state}
  end

  @impl true
  def handle_tick(:stats_timer, _ctx, %State{base_seq_num: nil} = state), do: {:ok, state}

  @impl true
  def handle_tick(:stats_timer, _ctx, state) do
    stats =
      Map.take(state, [
        :base_seq_num,
        :max_seq_num,
        :feedback_packet_count,
        :seq_to_timestamp
      ])

    rtcp = %TransportFeedbackPacket{
      sender_ssrc: state.sender_ssrc,
      media_ssrc: state.last_ssrc,
      payload: struct!(TransportFeedbackPacket.TWCC, stats)
    }

    event = %RTCPEvent{rtcp: rtcp}

    state =
      Map.merge(state, %{
        base_seq_num: nil,
        max_seq_num: nil,
        seq_to_timestamp: %{},
        feedback_packet_count: state.feedback_packet_count + 1
      })

    {{:ok, event: {Pad.ref(:input, state.last_ssrc), event}}, state}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, ssrc), _ctx, state) do
    {{:ok, end_of_stream: Pad.ref(:output, ssrc)}, state}
  end
end
