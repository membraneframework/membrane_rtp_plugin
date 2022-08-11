defmodule Membrane.RTP.TWCCSender.ConnectionProber do
  @moduledoc """
  Filter responsible for injecting the stream with empty RTP packets that TWCC uses
  for connection probing.
  """

  use Membrane.Filter
  use Bitwise

  alias Membrane.{Buffer, Time, RTP}

  require Membrane.Logger


  @initial_burst_size 10
  @max_seq_num 65_536
  @history_size div(@max_seq_num, 2)
  @probe_size_in_bytes 1024

  @burst_interval Time.milliseconds(100)

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
    caps: RTP,
    demand_mode: :auto

  def_output_pad :output,
    availability: :always,
    caps: RTP,
    demand_mode: :auto

  @impl true
  def handle_init(opts),
    do:
      {:ok,
       opts
       |> Map.from_struct()
       |> Map.merge(%{seq_num_mapping: %{}, offset: 0, last_seq_num: nil, last_timestamp: 0})}

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    # we need to fix a sequence number only
    original_seqnum = buffer.metadata.rtp.sequence_number
    is_first_buffer? = is_nil(state.last_seq_num)

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

    {probes_action, state} =
      if is_first_buffer?, do: generate_probes(state, @initial_burst_size), else: {[], state}

    {{:ok, [forward: buffer] ++ probes_action}, state}
  end

  @impl true
  def handle_tick(:probes, ctx, state) when ctx.playback_state == :playing do
    Membrane.Logger.warn("Sending 1 probe")
    {actions, state} = generate_probes(state, 1)
    {{:ok, actions}, state}
  end

  @impl true
  def handle_tick(:probes, _ctx, state), do: {:ok, state}

  @impl true
  def handle_event(pad, event, ctx, state) do
    super(pad, event, ctx, state)
  end

  @impl true
  def handle_start_of_stream(:input, _ctx, state) do
    {{:ok, start_timer: {:probes, @burst_interval}}, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {{:ok, stop_timer: :probes, end_of_stream: :output}, state}
  end

  defp maintain_seq_num_mapping(state) do
    dist = fn seq_num -> rem(state.last_seq_num - seq_num + @max_seq_num, @max_seq_num) end

    Map.update!(state, :seq_num_mapping, fn mapping ->
      mapping
      |> Enum.drop_while(fn {seq_num, _mapped_seq_num} -> dist.(seq_num) <= @history_size end)
      |> Map.new()
    end)
  end

  # while generating entries, we do not take out of order transmissions into account
  defp generate_seq_num_mapping_entries(state, seq_num)
       when is_nil(state.last_seq_num) or
              rem(state.last_seq_num - seq_num + @max_seq_num, @max_seq_num) == 1,
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

  defp create_probe_payload() do
    zeros_size = 8 * (@probe_size_in_bytes - 3)
    <<0::size(zeros_size), @probe_size_in_bytes::24>>
  end

  defp generate_probes(state, amount) do
    buffers =
      for i <- 1..amount do
        seq_num = rem(state.last_seq_num + i + state.offset, @max_seq_num)

        buf = %Buffer{
          metadata: %{
            rtp: %{
              padding_flag: true,
              marker: false,
              csrcs: [],
              payload_type: state.payload_type,
              extensions: [],
              ssrc: state.ssrc,
              timestamp: state.last_timestamp,
              sequence_number: seq_num
            }
          },
          payload: create_probe_payload()
        }

        {:buffer, {:output, buf}}
      end

    state = Map.update!(state, :offset, &(&1 + amount))
    {buffers, state}
  end
end
