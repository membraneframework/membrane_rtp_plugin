defmodule Membrane.RTP.TWCCSender.ConnectionProber do
  @moduledoc """
  Filter responsible for injecting the stream with empty RTP packets that TWCC uses
  for connection probing.
  """

  use Membrane.Filter
  use Bitwise

  alias Membrane.{Buffer, Time, RemoteStream, RTP}

  @initial_burst_size 10
  @max_seq_num 1 <<< 16
  @history_size div(@max_seq_num, 2)

  @burst_interval Time.milliseconds(200)

  def_options ssrc: [
                spec: any(),
                description: """
                SSRC that will be attached to probe packet's metadata
                """
              ],
              payload_type: [
                spec: non_neg_integer(),
                description: """
                Payload type that will be attached to probe packet's metadata
                """
              ]

  def_input_pad :input,
    availability: :always,
    caps: :any,
    demand_mode: :auto

  def_output_pad :output,
    availability: :always,
    caps: {RemoteStream, content_format: RTP},
    demand_mode: :auto

  @impl true
  def handle_init(opts),
    do:
      {:ok,
       opts
       |> Map.from_struct()
       |> Map.merge(%{seq_num_mapping: %{}, offset: 0, last_seq_num: 0, last_timestamp: 0})}

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    buffers =
      for i <- 0..(@initial_burst_size - 1) do
        seq_num = rem(i, @max_seq_num)

        %Buffer{
          metadata: %{
            rtp: %{
              marker: false,
              csrcs: [],
              payload_type: state.payload_type,
              extensions: [],
              ssrc: state.ssrc,
              timestamp: state.last_timestamp,
              sequence_number: seq_num
            }
          },
          payload: <<>>
        }
      end

    {{:ok, caps: {:output, %RemoteStream{content_format: RTP}}, buffer: {:output, buffers}, start_timer: {:probes, @burst_interval}},
     %{state | offset: @initial_burst_size}}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state), do: {:ok, state}

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    # we need to fix a sequence number only
    original_seqnum = buffer.metadata.rtp.sequence_number

    {seq_num, seq_num_mapping} =
      Map.pop(
        state.seq_num_mapping,
        original_seqnum,
        rem(original_seqnum + state.offset, @max_seq_num)
      )

    buffer = put_in(buffer.metadata.rtp.sequence_number, seq_num)

    state =
      state
      |> Map.put(:seq_num_mapping, seq_num_mapping)
      |> generate_seq_num_mapping_entries(original_seqnum)
      |> Map.put(:last_seq_num, original_seqnum)
      |> Map.put(:last_timestamp, buffer.metadata.rtp.timestamp)
      |> maintain_seq_num_mapping()

    {{:ok, forward: buffer}, state}
  end

  @impl true
  def handle_tick(:probes, _ctx, state) do
    buffers =
      for i <- 1..@initial_burst_size do
        seq_num = rem(state.last_seq_num + i, @max_seq_num)

        %Buffer{
          metadata: %{
            rtp: %{
              marker: false,
              csrcs: [],
              payload_type: state.payload_type,
              extensions: [],
              ssrc: state.ssrc,
              timestamp: state.last_timestamp,
              sequence_number: seq_num
            }
          },
          payload: <<>>
        }
      end

    state = Map.update!(state, :offset, & &1 + @initial_burst_size)
    {{:ok, buffer: {:output, buffers}}, state}
  end

  @impl true
  def handle_event(pad, event, ctx, state) do
    super(pad, event, ctx, state)
  end

  defp maintain_seq_num_mapping(state) do
    value = rem(state.last_seq_num - @history_size + @max_seq_num, @max_seq_num)

    Map.update!(state, :seq_num_mapping, fn mapping ->
      mapping
      |> Enum.drop_while(&(&1 <= value))
      |> Map.new()
    end)
  end

  # while generating entries, we do not take out of order transmissions into account
  defp generate_seq_num_mapping_entries(state, seq_num)
       when rem(state.last_seq_num - seq_num + @max_seq_num, @max_seq_num) == 1,
       do: state

  defp generate_seq_num_mapping_entries(state, seq_num) do
    entries =
      Map.new(
        for i <- state.last_seq_num..seq_num do
          {i, rem(i + state.offset, @max_seq_num)}
        end
      )

    Map.update!(state, :seq_num_mapping, &Map.merge(&1, entries))
  end
end
