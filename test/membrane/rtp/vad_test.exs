defmodule Membrane.RTP.VADTest do
  use ExUnit.Case

  alias Membrane.RTP.VAD

  ExUnit.Case.register_attribute(__MODULE__, :clock_rate)
  ExUnit.Case.register_attribute(__MODULE__, :min_packet_num)
  ExUnit.Case.register_attribute(__MODULE__, :time_window)
  ExUnit.Case.register_attribute(__MODULE__, :vad_silence_time)
  ExUnit.Case.register_attribute(__MODULE__, :vad_threshold)

  defp get_attribute(ctx, attribute) do
    Map.get(ctx.registered, attribute) ||
      VAD.options()
      |> Keyword.fetch!(attribute)
      |> Keyword.fetch!(:default)
  end

  defp setup_vad_state(ctx) do
    {:ok, state} =
      VAD.handle_init(%{
        clock_rate: get_attribute(ctx, :clock_rate),
        min_packet_num: get_attribute(ctx, :min_packet_num),
        time_window: get_attribute(ctx, :time_window),
        vad_silence_time: get_attribute(ctx, :vad_silence_time),
        vad_threshold: get_attribute(ctx, :vad_threshold)
      })

    [state: state]
  end

  defp rtp_buffer(volume, timestamp) when volume in -127..0 do
    level = -volume
    data = <<16, 1::1, level::7, 0, 0>>

    rtp_metadata = %{
      csrcs: [],
      extension: %Membrane.RTP.Header.Extension{
        data: data,
        profile_specific: <<190, 222>>
      },
      has_padding?: false,
      marker: false,
      payload_type: 111,
      sequence_number: 16_503,
      ssrc: 1_464_407_876,
      timestamp: timestamp,
      total_header_size: 20
    }

    %Membrane.Buffer{metadata: %{rtp: rtp_metadata}, payload: <<>>}
  end

  defp iterate_for(buffers: buffer_count, volume: volume, initial: state) do
    original_timestamp = state.current_timestamp
    interval = 20
    time_delta = state.clock_rate / 1000 * interval

    Enum.reduce(1..buffer_count, state, fn index, state ->
      new_timestamp = original_timestamp + time_delta * index
      buffer = rtp_buffer(volume, new_timestamp)

      {{:ok, _}, new_state} = VAD.handle_process(:input, buffer, %{}, state)
      new_state
    end)
  end

  describe "handle_process" do
    setup :setup_vad_state

    test "keeps running totals for buffers within a specific time window", %{state: state} do
      buffer = rtp_buffer(-127, 1_201_851_607)

      {{:ok, [buffer: _]}, new_state} = VAD.handle_process(:input, buffer, %{}, state)

      assert %{
               audio_levels_count: 1,
               audio_levels_sum: -127,
               current_timestamp: 1_201_851_607,
               vad: :silence
             } = new_state

      buffer = rtp_buffer(-50, 1_201_852_567)

      {{:ok, [buffer: _]}, new_state} = VAD.handle_process(:input, buffer, %{}, new_state)

      assert %{
               audio_levels_count: 2,
               audio_levels_sum: -177,
               current_timestamp: 1_201_852_567,
               vad: :silence
             } = new_state
    end

    test "changes to :speech when ...", %{state: state} do
      original_timestamp = 1_201_851_607

      {{:ok, [buffer: _]}, state} =
        VAD.handle_process(:input, rtp_buffer(-127, original_timestamp), %{}, state)

      assert %{vad: :silence} = state

      new_state = iterate_for(buffers: 100, volume: 0, initial: state)
      assert %{vad: :speech} = new_state

      new_state = iterate_for(buffers: 5000, volume: 0, initial: state)
      assert %{audio_levels_count: 101, vad: :speech} = new_state

      new_state = iterate_for(buffers: 100, volume: -127, initial: state)
      assert %{audio_levels_count: 101, vad: :silence} = new_state
    end
  end
end
