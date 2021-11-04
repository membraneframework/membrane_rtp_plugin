defmodule Membrane.RTP.TransportWideTracer do
  @moduledoc """
  The module defines an element responsible for recording transport-wide statistics of incoming packets.
  """
  use Membrane.Filter

  alias Membrane.{RTP, RTCPEvent, Time}
  alias Membrane.RTCP.TransportWideFeedbackPacket

  def_input_pad :input, demand_unit: :buffers, caps: RTP, availability: :on_request
  def_output_pad :output, caps: RTP, availability: :on_request

  def_options origin_ssrc: [
                spec: RTP.ssrc_t(),
                description: """
                Origin SSRC for TWCC sender.
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
            media_ssrc: RTP.ssrc_t(),
            origin_ssrc: RTP.ssrc_t(),
            local_seq_num: non_neg_integer()
          }

    @enforce_keys [:origin_ssrc, :stats_interval]
    defstruct @enforce_keys ++
                [
                  base_seq_num: nil,
                  max_seq_num: nil,
                  seq_to_timestamp: %{},
                  feedback_packet_count: 0,
                  media_ssrc: nil,
                  local_seq_num: 1
                ]
  end

  @impl true
  def handle_init(opts) do
    {:ok, %State{origin_ssrc: opts.origin_ssrc, stats_interval: opts.stats_interval}}
  end

  @impl true
  def handle_caps(Pad.ref(:input, id), caps, _ctx, state) do
    {{:ok, caps: {Pad.ref(:output, id), caps}}, state}
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
  def handle_demand(Pad.ref(:output, id), size, :buffers, _ctx, state) do
    {{:ok, demand: {Pad.ref(:input, id), size}}, state}
  end

  @impl true
  def handle_event(Pad.ref(:input, id), event, _ctx, state) do
    {{:ok, event: {Pad.ref(:output, id), event}}, state}
  end

  @impl true
  def handle_event(Pad.ref(:output, id), event, _ctx, state) do
    {{:ok, event: {Pad.ref(:input, id), event}}, state}
  end

  @impl true
  def handle_process(Pad.ref(:input, id), %{metadata: metadata} = buffer, _ctx, state) do
    %State{
      base_seq_num: base_seq_num,
      max_seq_num: max_seq_num,
      seq_to_timestamp: seq_to_timestamp,
      local_seq_num: local_seq_num
    } = state

    <<_id::4, _len::4, seq_num::16, _padding::8>> = metadata.rtp.extension.data

    # TODO: use ID proposed in browser's SDP offer (currently hardcoded to 3)
    # TODO: move sequence number tagging closer to the end of the pipeline
    twcc_extension = %{metadata.rtp.extension | data: <<3::4, 1::4, local_seq_num::16, 0::8>>}

    arrival_ts = Time.vm_time()

    state =
      Map.merge(state, %{
        base_seq_num: min(base_seq_num, seq_num) || seq_num,
        max_seq_num: max(max_seq_num, seq_num) || seq_num,
        seq_to_timestamp: Map.put(seq_to_timestamp, seq_num, arrival_ts),
        media_ssrc: metadata.rtp.ssrc,
        local_seq_num: local_seq_num + 1
      })

    metadata = put_in(metadata, [:rtp, :extension], twcc_extension)

    {{:ok, buffer: {Pad.ref(:output, id), %{buffer | metadata: metadata}}}, state}
  end

  @impl true
  def handle_tick(:stats_timer, _ctx, %State{base_seq_num: nil} = state), do: {:ok, state}

  @impl true
  def handle_tick(:stats_timer, ctx, state) do
    stats =
      Map.take(state, [
        :base_seq_num,
        :max_seq_num,
        :feedback_packet_count,
        :seq_to_timestamp
      ])

    rtcp = %TransportWideFeedbackPacket{
      origin_ssrc: state.origin_ssrc,
      media_ssrc: state.media_ssrc,
      payload: struct!(TransportWideFeedbackPacket.TWCC, stats)
    }

    event = %RTCPEvent{rtcp: rtcp}

    state =
      Map.merge(state, %{
        base_seq_num: nil,
        max_seq_num: nil,
        seq_to_timestamp: %{},
        feedback_packet_count: state.feedback_packet_count + 1
      })

    {Membrane.Pad, _direction, any_id} =
      ctx.pads
      |> Map.keys()
      |> hd()

    {{:ok, event: {Pad.ref(:output, any_id), event}}, state}
  end
end
