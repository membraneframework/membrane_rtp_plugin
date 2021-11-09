defmodule Membrane.RTP.TWCC do
  @moduledoc """
  The module defines an element responsible for recording transport-wide statistics of incoming packets.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RTP, RTCPEvent, Time}
  alias Membrane.RTCP.TransportFeedbackPacket
  alias __MODULE__.PacketInfoStore

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
    alias Membrane.RTP.TWCC.PacketInfoStore

    @type t :: %__MODULE__{
            sender_ssrc: RTP.ssrc_t(),
            report_interval: Time.t(),
            packet_info_store: PacketInfoStore.t(),
            feedback_packet_count: non_neg_integer(),
            local_seq_num: non_neg_integer(),
            last_ssrc: RTP.ssrc_t()
          }

    @enforce_keys [:sender_ssrc, :report_interval]
    defstruct @enforce_keys ++
                [
                  packet_info_store: %PacketInfoStore{},
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
    case ssrc do
      ^last_ssrc -> {:ok, %State{state | last_ssrc: nil}}
      _other_ssrc -> {:ok, state}
    end
  end

  @impl true
  def handle_process(Pad.ref(:input, ssrc), %Buffer{metadata: metadata} = buffer, _ctx, state) do
    %State{
      packet_info_store: store,
      local_seq_num: local_seq_num,
      last_ssrc: last_ssrc
    } = state

    # TODO: match on ID proposed by membrane_webrtc_plugin in SDP offer
    <<_id::4, _len::4, seq_num::16, _padding::8>> = metadata.rtp.extension.data

    store = PacketInfoStore.insert_packet_info(store, seq_num)

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
        packet_info_store: store,
        local_seq_num: rem(local_seq_num + 1, @seq_number_limit),
        last_ssrc: last_ssrc || ssrc
      })

    {{:ok, buffer: {Pad.ref(:output, ssrc), %Buffer{buffer | metadata: metadata}}}, state}
  end

  @impl true
  def handle_tick(:report_timer, _ctx, %State{packet_info_store: store} = state) do
    if PacketInfoStore.empty?(store) or state.last_ssrc == nil do
      {:ok, state}
    else
      event = make_rtcp_event(state)

      state =
        Map.merge(state, %{
          packet_info_store: %PacketInfoStore{},
          feedback_packet_count: rem(state.feedback_packet_count + 1, @feedback_count_limit)
        })

      {{:ok, event: {Pad.ref(:input, state.last_ssrc), event}}, state}
    end
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, ssrc), _ctx, state) do
    {{:ok, end_of_stream: Pad.ref(:output, ssrc)}, state}
  end

  defp make_rtcp_event(state) do
    %State{
      packet_info_store: store,
      feedback_packet_count: feedback_packet_count,
      sender_ssrc: sender_ssrc,
      last_ssrc: last_ssrc
    } = state

    stats =
      store
      |> PacketInfoStore.get_stats()
      |> Map.put(:feedback_packet_count, feedback_packet_count)

    %RTCPEvent{
      rtcp: %TransportFeedbackPacket{
        sender_ssrc: sender_ssrc,
        media_ssrc: last_ssrc,
        payload: struct!(TransportFeedbackPacket.TWCC, stats)
      }
    }
  end
end
