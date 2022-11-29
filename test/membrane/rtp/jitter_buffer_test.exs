defmodule Membrane.RTP.JitterBufferTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.BufferFactory
  alias Membrane.RTP.JitterBuffer
  alias Membrane.RTP.JitterBuffer.{BufferStore, Record, State}

  @base_seq_number BufferFactory.base_seq_number()

  setup_all do
    buffer = BufferFactory.sample_buffer(@base_seq_number)

    state = %State{
      clock_rate: BufferFactory.clock_rate(),
      store: %BufferStore{},
      latency: 10 |> Membrane.Time.milliseconds()
    }

    [state: state, buffer: buffer]
  end

  describe "When JitterBuffer is in waiting state" do
    setup %{state: state} do
      [state: %{state | waiting?: true}]
    end

    test "start of stream starts timer that changes state", %{state: state} do
      assert {[], state} = JitterBuffer.handle_start_of_stream(:input, %{}, state)
      assert_receive message, (state.latency |> Membrane.Time.round_to_milliseconds()) + 5
      assert {[], final_state} = JitterBuffer.handle_info(message, %{}, state)
      assert final_state.waiting? == false
    end

    test "any new buffer is kept", %{state: state, buffer: buffer} do
      assert BufferStore.dump(state.store) == []
      assert {[], state} = JitterBuffer.handle_process(:input, buffer, nil, state)

      assert %State{store: store} = state
      assert {%Record{buffer: ^buffer}, new_store} = BufferStore.flush_one(store)
      assert BufferStore.dump(new_store) == []
    end
  end

  describe "When new buffer arrives when not waiting and already pushed some buffer" do
    setup %{state: state} do
      flush_index = @base_seq_number - 1
      store = %{state.store | flush_index: flush_index, highest_incoming_index: flush_index}
      [state: %{state | waiting?: false, store: store}]
    end

    test "outputs it immediately if it is in order", %{state: state, buffer: buffer} do
      assert {[buffer: {:output, ^buffer}], state} =
               JitterBuffer.handle_process(:input, buffer, nil, state)

      assert %JitterBuffer.State{store: store} = state
      assert BufferStore.dump(store) == []
    end

    test "refuses to add that packet when it comes too late", %{state: state} do
      late_buffer = BufferFactory.sample_buffer(@base_seq_number - 2)
      assert {[], new_state} = JitterBuffer.handle_process(:input, late_buffer, nil, state)
      assert new_state == state
    end

    test "adds it and when it fills the gap, returns all buffers in order", %{state: state} do
      first_buffer = BufferFactory.sample_buffer(@base_seq_number)
      second_buffer = BufferFactory.sample_buffer(@base_seq_number + 1)
      third_buffer = BufferFactory.sample_buffer(@base_seq_number + 2)

      flush_index = @base_seq_number - 1

      store = %BufferStore{
        state.store
        | flush_index: flush_index,
          highest_incoming_index: flush_index
      }

      store =
        with {:ok, store} <- BufferStore.insert_buffer(store, second_buffer),
             {:ok, store} <- BufferStore.insert_buffer(store, third_buffer) do
          store
        end

      state = %State{state | store: store}

      assert {commands, %State{store: result_store}} =
               JitterBuffer.handle_process(:input, first_buffer, nil, state)

      buffers = commands |> Keyword.get_values(:buffer) |> Enum.map(fn {:output, buf} -> buf end)

      assert [^first_buffer, ^second_buffer, ^third_buffer] = buffers
      assert BufferStore.dump(result_store) == []
    end
  end

  describe "When latency pasess without filling the gap, JitterBuffer" do
    test "outputs discontinuity and late buffer", %{state: state, buffer: buffer} do
      flush_index = @base_seq_number - 2

      store = %BufferStore{
        state.store
        | flush_index: flush_index,
          highest_incoming_index: flush_index
      }

      state = %{state | store: store, waiting?: false}

      assert {commands, state} = JitterBuffer.handle_process(:input, buffer, nil, state)
      assert commands |> Keyword.get(:buffer) == nil
      assert is_reference(state.max_latency_timer)
      assert_receive message, (state.latency |> Membrane.Time.round_to_milliseconds()) + 20

      assert {actions, _state} = JitterBuffer.handle_info(message, %{}, state)

      assert [event: event, buffer: buffer_action] = actions
      assert event == {:output, %Membrane.Event.Discontinuity{}}
      assert buffer_action == {:output, buffer}
    end
  end

  describe "When event arrives" do
    test "dumps store if event was end of stream", %{state: state, buffer: buffer} do
      flush_index = @base_seq_number - 2

      store = %BufferStore{
        state.store
        | flush_index: flush_index,
          highest_incoming_index: flush_index
      }

      {:ok, store} = BufferStore.insert_buffer(store, buffer)
      state = %{state | store: store}
      assert {actions, _state} = JitterBuffer.handle_end_of_stream(:input, nil, state)

      assert [event: event, buffer: buffer_action, end_of_stream: :output] = actions
      assert event == {:output, %Membrane.Event.Discontinuity{}}
      assert buffer_action == {:output, buffer}
    end
  end
end
