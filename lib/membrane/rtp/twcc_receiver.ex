defmodule Membrane.RTP.TWCCReceiver do
  @moduledoc """
  The module defines an element responsible for recording transport-wide statistics of incoming packets
  and generating TWCC feedbacks.
  """
  use Membrane.Filter

  alias Membrane.{RTP, RTCPEvent, Time}
  alias Membrane.RTP.Header
  alias Membrane.RTCP.TransportFeedbackPacket
  alias __MODULE__.PacketInfoStore

  require Bitwise

  @feedback_count_limit Bitwise.bsl(1, 8)

  def_input_pad :input, caps: RTP, availability: :on_request, demand_mode: :auto
  def_output_pad :output, caps: RTP, availability: :on_request, demand_mode: :auto

  def_options twcc_id: [
                spec: 1..14,
                description: "ID of TWCC header extension."
              ],
              report_interval: [
                spec: Membrane.Time.t(),
                default: Membrane.Time.milliseconds(250),
                description: "How often to generate feedback packets."
              ],
              feedback_sender_ssrc: [
                spec: RTP.ssrc_t() | nil,
                default: nil,
                description:
                  "Sender SSRC for generated feedback packets (will be supplied by `RTP.SessionBin`)."
              ]

  defmodule State do
    @moduledoc false
    alias Membrane.RTP.TWCCReceiver.PacketInfoStore

    @type t :: %__MODULE__{
            twcc_id: 1..14,
            feedback_sender_ssrc: RTP.ssrc_t() | nil,
            report_interval: Time.t(),
            packet_info_store: PacketInfoStore.t(),
            feedback_packet_count: non_neg_integer(),
            media_ssrc: RTP.ssrc_t() | nil
          }

    @enforce_keys [:twcc_id, :report_interval, :feedback_sender_ssrc]
    defstruct @enforce_keys ++
                [
                  packet_info_store: %PacketInfoStore{},
                  feedback_packet_count: 0,
                  media_ssrc: nil
                ]
  end

  @impl true
  def handle_init(options) do
    {:ok, struct!(State, Map.from_struct(options))}
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
  def handle_caps(Pad.ref(:input, ssrc), caps, _ctx, state) do
    {{:ok, caps: {Pad.ref(:output, ssrc), caps}}, state}
  end

  @impl true
  def handle_event(Pad.ref(direction, ssrc), event, _ctx, state) do
    opposite_direction = if direction == :input, do: :output, else: :input
    {{:ok, event: {Pad.ref(opposite_direction, ssrc), event}}, state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(_direction, ssrc), _ctx, %State{media_ssrc: media_ssrc} = state) do
    if media_ssrc == ssrc do
      {:ok, %State{state | media_ssrc: nil}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_process(Pad.ref(:input, ssrc), buffer, _ctx, state) do
    {extension, buffer} = Header.Extension.pop(buffer, state.twcc_id)

    state =
      if extension != nil do
        <<seq_num::16>> = extension.data
        store = PacketInfoStore.insert_packet_info(state.packet_info_store, seq_num)

        %{state | packet_info_store: store, media_ssrc: state.media_ssrc || ssrc}
      else
        state
      end

    {{:ok, buffer: {Pad.ref(:output, ssrc), buffer}}, state}
  end

  @impl true
  def handle_tick(:report_timer, _ctx, %State{packet_info_store: store} = state) do
    if PacketInfoStore.empty?(store) or state.media_ssrc == nil do
      {:ok, state}
    else
      event = make_rtcp_event(state)

      state = %{
        state
        | packet_info_store: %PacketInfoStore{},
          feedback_packet_count: rem(state.feedback_packet_count + 1, @feedback_count_limit)
      }

      {{:ok, event: {Pad.ref(:input, state.media_ssrc), event}}, state}
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
      feedback_sender_ssrc: feedback_sender_ssrc,
      media_ssrc: media_ssrc
    } = state

    stats =
      store
      |> PacketInfoStore.get_stats()
      |> Map.put(:feedback_packet_count, feedback_packet_count)

    %RTCPEvent{
      rtcp: %TransportFeedbackPacket{
        sender_ssrc: feedback_sender_ssrc,
        media_ssrc: media_ssrc,
        payload: struct!(TransportFeedbackPacket.TWCC, stats)
      }
    }
  end
end
